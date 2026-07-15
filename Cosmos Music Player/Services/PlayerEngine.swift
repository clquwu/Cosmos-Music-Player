//  PlayerEngine.swift
//  Cosmos Music Player
//
//  Audio playback engine using AVAudioEngine for high-resolution FLAC playback
//
import Foundation
import AVFoundation
import Combine
import MediaPlayer
import UIKit
import GRDB
import SFBAudioEngine
import WidgetKit

/// Holds the fast-changing playback position so that only views showing the
/// progress bar/time labels re-render at the 10Hz timer rate. Observing
/// PlayerEngine itself must not subscribe views to these updates.
@MainActor
final class PlaybackProgress: ObservableObject {
    @Published var playbackTime: TimeInterval = 0
}

@MainActor
class PlayerEngine: NSObject, ObservableObject {
    static let shared = PlayerEngine()

    @Published var currentTrack: Track?
    @Published var isPlaying = false
    let progress = PlaybackProgress()
    var playbackTime: TimeInterval {
        get { progress.playbackTime }
        set { progress.playbackTime = newValue }
    }
    @Published var duration: TimeInterval = 0
    @Published var playbackState: PlaybackState = .stopped
    @Published var playbackQueue: [Track] = []
    @Published var currentIndex = 0
    @Published var isRepeating = false
    @Published var isShuffled = false
    @Published var isLoopingSong = false

    private var originalQueue: [String] = []
    private let maxPersistedQueueSize = 2000

    // Generation token to prevent stale completion handlers from firing
    private var scheduleGeneration: UInt64 = 0

    private var seekTimeOffset: TimeInterval = 0
    private var lastSampleRate: Double = 0

    private lazy var audioEngine = AVAudioEngine()
    private lazy var playerNode = AVAudioPlayerNode()
    private var audioFile: AVAudioFile?
    private var playbackStrategy: PlaybackRouter.PlaybackStrategy?
    private var playbackTimer: Timer?

    // Gapless playback support
    private var nextAudioFile: AVAudioFile?
    private var nextTrack: Track?
    private var nextTrackIndex: Int?
    private var isPreloadingNext = false
    private var gaplessScheduled = false
    private var preloadNextTask: Task<Void, Never>?
    private var nodeTimelineStartSampleTime: AVAudioFramePosition = 0
    private var nextTimelineStartSampleTime: AVAudioFramePosition?
    private var engineConfigurationRecoveryTask: Task<Void, Never>?
    // NotificationCenter may invoke audio callbacks on Core Audio's private
    // queues. Keep block-observer tokens so every callback can explicitly hop
    // to MainActor before it touches player state.
    private nonisolated(unsafe) var notificationObservers: [NSObjectProtocol] = []

    // SFBAudioEngine integration
    private lazy var sfbAudioManager = SFBAudioEngineManager.shared
    private var usingSFBEngine = false
    var isUsingSFBEngine: Bool { usingSFBEngine }
    // EQ integration
    let eqManager = EQManager.shared

    private var isLoadingTrack = false
    private var currentLoadTask: Task<Bool, Never>?
    private var loadGeneration: UInt64 = 0
    private var hasRestoredState = false
    private var hasSetupAudioEngine = false
    private var hasSetupAudioSession = false
    private var hasSetupSiriBackgroundSession = false
    private(set) var isAudioSessionInterrupted = false
    private var wasPlayingBeforeInterruption = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private(set) var isInBackground = false
    private var hasSetupRemoteCommands = false
    private nonisolated(unsafe) var hasSetupAudioSessionNotifications = false
    private var backgroundCheckTimer: Timer?

    // Artwork caching
    private var cachedArtwork: MPMediaItemArtwork?
    private var cachedArtworkTrackId: String?
    private var artworkLoadTask: Task<Void, Never>?
    private var artworkLoadTaskTrackId: String?
    private var cachedNowPlayingArtistTrackId: String?
    private var cachedNowPlayingArtistName: String?

    // Security-scoped resource tracking for external files
    private var currentSecurityScopedURL: URL?

    private let databaseManager = DatabaseManager.shared
    private let cloudDownloadManager = CloudDownloadManager.shared

    // Enhanced Control Center synchronization (replaces MPNowPlayingSession approach)

    // Silent keepalive used only while explicitly paused in the background.
    // System output volume is already applied by iOS; polling outputVolume and
    // mirroring it onto the mixer caused synchronous audio-session XPC calls on
    // the main thread and effectively applied volume twice.
    private var pausedSilentPlayer: AVAudioPlayer?

    enum PlaybackState {
        case stopped
        case playing
        case paused
        case loading
    }

    private override init() {
        super.init()
        // Don't set up audio engine immediately - defer until first playback
        // setupAudioEngine()
        // Don't set up audio session immediately - defer until first playback
        // setupAudioSession()
        // Don't set up audio session notifications immediately - defer until first playback
        // setupAudioSessionNotifications()
        // Don't set up remote commands immediately - defer until first playback
        // setupRemoteCommands()
        setupPeriodicStateSaving()
    }

    private func ensureAudioEngineSetup(with format: AVAudioFormat? = nil) {
        if !hasSetupAudioEngine {
            hasSetupAudioEngine = true
            setupAudioEngine(with: format)
            if let format = format {
                lastSampleRate = format.sampleRate
            }
        } else if let format = format {
            // Check if sample rate has changed - if so, force reconfiguration
            if abs(format.sampleRate - lastSampleRate) > 0.1 {
                print("📊 Sample rate changed from \(lastSampleRate)Hz to \(format.sampleRate)Hz - forcing reconfiguration")
                reconfigureAudioEngineForNewFormat(format)
                lastSampleRate = format.sampleRate

                // Reset timing state completely when sample rate changes
                seekTimeOffset = 0
                playbackTime = 0
                lastControlCenterUpdate = 0

                // Stop and restart playback timer to ensure proper timing with new sample rate
                stopPlaybackTimer()
                if isPlaying {
                    startPlaybackTimer()
                }
                print("🔄 Reset timing state and timer for new sample rate")
            }
        }
    }

    private func reconfigureAudioEngineForNewFormat(_ format: AVAudioFormat) {
        // Force reconfiguration for new sample rate - stop engine if needed
        let wasRunning = audioEngine.isRunning
        if wasRunning {
            audioEngine.stop()
            print("🛑 Stopped audio engine for reconfiguration")
        }
        print("🔧 Reconfiguring audio engine for new format: \(format.sampleRate)Hz")
        // Disconnect all nodes to rebuild the graph
        audioEngine.disconnectNodeInput(audioEngine.mainMixerNode)
        audioEngine.disconnectNodeInput(playerNode)
        // Reconnect with EQ: playerNode -> EQ -> mainMixerNode
        eqManager.insertEQIntoAudioGraph(between: playerNode, and: audioEngine.mainMixerNode, format: format)
        audioEngine.prepare()
        print("✅ Audio engine reconfigured with EQ for sample rate: \(format.sampleRate)Hz")
        // Restart engine if it was running
        if wasRunning {
            do {
                try audioEngine.start()
                print("▶️ Restarted audio engine after reconfiguration")
            } catch {
                print("❌ Failed to restart audio engine: \(error)")
            }
        }
    }

    private func setupAudioEngine(with format: AVAudioFormat? = nil) {
        audioEngine.attach(playerNode)
        // Set up EQ manager with the audio engine
        eqManager.setAudioEngine(audioEngine)
        // Connect playerNode -> EQ -> mainMixerNode. AVAudioEngine owns the
        // mainMixerNode -> outputNode connection and negotiates that format
        // with the current hardware route. Supplying the mixer's format to the
        // output node can raise an Objective-C exception when CarPlay is fixed
        // at a different sample rate from the source file.
        eqManager.insertEQIntoAudioGraph(between: playerNode, and: audioEngine.mainMixerNode, format: format)
        // CRITICAL: Prepare the engine to guarantee render loop activity
        audioEngine.prepare()
        // Don't start the engine here - wait until we actually need to play
        print("✅ Audio engine configured and prepared with EQ integration, format: \(format?.description ?? "auto")")
    }


    private func ensureAudioSessionSetup() {
        guard !hasSetupAudioSession else { return }
        hasSetupAudioSession = true

        do {
            try setupAudioSessionCategory()
        } catch {
            print("Failed to setup audio session category: \(error)")
            // Continue anyway - we'll try to handle this when actually playing
        }
    }

    private func ensureAudioSessionNotificationsSetup() {
        guard !hasSetupAudioSessionNotifications else { return }
        hasSetupAudioSessionNotifications = true
        setupAudioSessionNotifications()
    }

    private func setupAudioSessionNotifications() {
        // Audio-session notifications are not guaranteed to arrive on the
        // main queue. An Objective-C selector targeting this @MainActor class
        // traps in _dispatch_assert_queue_fail before Swift can hop actors.
        let interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: nil
        ) { @Sendable [weak self] notification in
            guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else {
                return
            }
            let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor [weak self] in
                self?.processAudioSessionInterruption(
                    typeValue: typeValue,
                    optionsValue: optionsValue
                )
            }
        }
        notificationObservers.append(interruptionObserver)

        let routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { @Sendable [weak self] notification in
            guard let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
                return
            }
            Task { @MainActor [weak self] in
                self?.processAudioSessionRouteChange(reason: reason)
            }
        }
        notificationObservers.append(routeObserver)

        let mediaServicesObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: nil
        ) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.processMediaServicesReset()
            }
        }
        notificationObservers.append(mediaServicesObserver)

        // AVAudioEngine stops itself when the system reconfigures the audio
        // hardware (CarPlay mixing in nav prompts, sample rate changes, Siri
        // chimes). Without handling this, playback goes silent.
        // Do not use a selector here. PlayerEngine is @MainActor, so Swift adds
        // a main-executor check to its Objective-C entry thunk. AVAudioEngine
        // posts this notification on its private `engine` queue, which traps in
        // _dispatch_assert_queue_fail before a selector method can hop actors.
        let engineConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: nil
        ) { @Sendable [weak self] notification in
            guard let changedEngine = notification.object as? AVAudioEngine else { return }
            let changedEngineID = ObjectIdentifier(changedEngine)
            Task { @MainActor [weak self] in
                self?.processEngineConfigurationChange(changedEngineID)
            }
        }
        notificationObservers.append(engineConfigurationObserver)

        // Listen for memory pressure warnings
        let memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.processMemoryWarning()
            }
        }
        notificationObservers.append(memoryWarningObserver)
    }

    private func processAudioSessionInterruption(typeValue: UInt, optionsValue: UInt?) {
        guard let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            print("🚫 Audio session interruption began - pausing playback")
            isAudioSessionInterrupted = true

            // Save current playback position before interruption
            let savedPosition = playbackTime
            let wasPlaying = isPlaying
            wasPlayingBeforeInterruption = wasPlaying

            if isPlaying {
                if usingSFBEngine {
                    // Stop the SFBAudioEngine's internal AVAudioEngine completely
                    // so it releases the audio hardware for the alarm/call
                    sfbAudioManager.stopEngineForInterruption()
                    isPlaying = false
                    playbackState = .paused
                    stopPlaybackTimer()
                    updateNowPlayingInfoEnhanced()
                } else {
                    // Stop native AVAudioEngine completely (not just pause)
                    audioEngine.stop()
                    isPlaying = false
                    playbackState = .paused
                    stopPlaybackTimer()
                    updateNowPlayingInfoEnhanced()
                }
            }

            // Also stop any silent background players that hold audio hardware
            stopSilentPlaybackForPause()

            // NOTE: Do NOT deactivate the audio session here. The system has
            // already interrupted it, and explicitly deactivating makes iOS
            // treat us as no longer interested - the .ended notification
            // (with .shouldResume) is then never delivered if the app gets
            // suspended, leaving playback paused forever (e.g. on CarPlay
            // after a nav prompt or phone call).

            // Restore the saved position (pause() may have updated it)
            playbackTime = savedPosition
            print("💾 Saved playback position: \(savedPosition)s (was playing: \(wasPlaying))")

        case .ended:
            print("✅ Audio session interruption ended")
            isAudioSessionInterrupted = false
            print("💾 Will restore to position: \(playbackTime)s when playback resumes")

            // Re-activate our audio session now that the interruption is over
            do {
                try AVAudioSession.sharedInstance().setActive(true, options: [])
                print("🔊 Audio session re-activated after interruption")
            } catch {
                print("⚠️ Failed to re-activate audio session: \(error)")
            }

            // Restart the audio engine so it's ready for playback resume.
            // SFBAudioPlayer restarts its own engine when the interruption
            // ends (and play() starts it if that failed) - touching it here
            // trips its engine-state assertion, so only the native engine is
            // restarted manually.
            if !usingSFBEngine {
                do {
                    try audioEngine.start()
                    print("🔊 Native AVAudioEngine restarted after interruption")
                } catch {
                    print("⚠️ Failed to restart native AVAudioEngine: \(error)")
                }
            }

            // Check if we should resume playback
            let shouldResume: Bool
            if let optionsValue {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                shouldResume = options.contains(.shouldResume)
                print("🔍 Interruption options: shouldResume = \(shouldResume)")
            } else {
                shouldResume = false
                print("🔍 No interruption options - will not auto-resume")
            }

            // Only auto-resume if:
            // 1. The system tells us to (e.g., after a Siri interruption)
            // 2. The user was actually playing before the interruption (not manually paused)
            if shouldResume && wasPlayingBeforeInterruption && playbackState == .paused {
                print("▶️ Auto-resuming playback after interruption (was playing before)")
                play()
            } else {
                print("⏸️ Not auto-resuming - user must manually resume")

                // Ensure playback state is correct but keep position saved
                isPlaying = false
                playbackState = .paused
                updateNowPlayingInfoEnhanced()
            }

        @unknown default:
            break
        }
    }

    private func processAudioSessionRouteChange(reason: AVAudioSession.RouteChangeReason) {
        // Update CarPlay status when route changes
        sfbAudioManager.updateCarPlayStatus()

        switch reason {
        case .oldDeviceUnavailable:
            // Only pause if audio would now blast from the built-in speaker.
            // Wireless CarPlay briefly flaps to the Bluetooth phone-call
            // channel (Siri, nav voice) and back - that also reports
            // .oldDeviceUnavailable, but the audio stays on the car, and
            // pausing there is wrong.
            let currentOutputs = AVAudioSession.sharedInstance().currentRoute.outputs
            let fellBackToSpeaker = currentOutputs.isEmpty || currentOutputs.contains { $0.portType == .builtInSpeaker }
            if fellBackToSpeaker {
                print("🎧 Audio device disconnected (fell back to speaker) - pausing playback")
                if isPlaying {
                    pause()
                }
            } else {
                print("🎧 Route changed but still on external output (\(currentOutputs.map { $0.portType.rawValue })) - continuing")
            }
        default:
            break
        }
    }

    private func processMediaServicesReset() async {
        print("🔄 Media services were reset - need to recreate audio engine and nodes")

        // Stop current playback
        let wasPlaying = isPlaying
        let currentTime = playbackTime
        let currentTrackCopy = currentTrack

        // Clean up current audio engine and nodes
        await cleanupAudioEngineForReset()

        // Recreate audio engine and nodes
        recreateAudioEngine()

        // Reactivate audio session after reset
        try? activateAudioSession()

        // Restore playback if needed
        if let track = currentTrackCopy {
            await loadTrack(track, preservePlaybackTime: true)
            if wasPlaying {
                playbackTime = currentTime
                play()
            }
        }
    }

    private func processEngineConfigurationChange(_ changedEngineID: ObjectIdentifier) {
        // Only react to our own engine - SFBAudioEngine manages its own.
        guard changedEngineID == ObjectIdentifier(audioEngine) else { return }
        guard !usingSFBEngine else { return }

        // Interruptions have their own began/ended recovery path.
        guard isPlaying, !isAudioSessionInterrupted else { return }

        // CarPlay can emit several configuration notifications while its
        // route settles. Coalesce them so we never stop/start/schedule the
        // same player node concurrently.
        guard engineConfigurationRecoveryTask == nil else { return }
        let recoveryLoadGeneration = loadGeneration
        let recoveryTrackID = currentTrack?.stableId
        engineConfigurationRecoveryTask = Task { @MainActor [weak self] in
            defer { self?.engineConfigurationRecoveryTask = nil }
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }

            guard let self,
                  self.isPlaying,
                  !self.isLoadingTrack,
                  !self.isAudioSessionInterrupted,
                  !self.usingSFBEngine,
                  self.loadGeneration == recoveryLoadGeneration,
                  self.currentTrack?.stableId == recoveryTrackID else { return }

            let resumeTime = self.nowPlayingElapsedTime()
            self.playbackTime = resumeTime
            print("🔧 Audio engine configuration changed - restarting playback at \(resumeTime)s")

            // The engine has already stopped; go through the resume path so
            // the segment is scheduled once at the preserved position.
            self.isPlaying = false
            self.playbackState = .paused
            self.stopPlaybackTimer()
            self.play()
        }
    }

    private func cancelEngineConfigurationRecovery() {
        engineConfigurationRecoveryTask?.cancel()
        engineConfigurationRecoveryTask = nil
    }

    private func processMemoryWarning() {
        print("⚠️ Memory warning received - cleaning up audio resources")

        // Clear cached artwork to free memory
        cachedArtwork = nil
        cachedArtworkTrackId = nil

        // Don't touch the audio engine if we're currently loading or playing
        // Stopping during a load causes the load to fail on large files
        if !isPlaying && !isLoadingTrack {
            audioEngine.stop()
            playerNode.stop()
            print("🛑 Stopped audio engine due to memory pressure")
        }

        print("🧹 Cleaned up audio resources due to memory warning")
    }

    private func ensureRemoteCommandsSetup() {
        guard !hasSetupRemoteCommands else { return }
        hasSetupRemoteCommands = true
        setupRemoteCommands()
    }

    private func setupRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()

        // Play command handler - will be called from Control Center
        cc.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                print("🎛️ Play command from Control Center")
                self?.play()
            }
            return .success
        }

        // Pause command handler - will be called from Control Center
        cc.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                print("🎛️ Pause command from Control Center")
                self?.pause(fromControlCenter: true)
            }
            return .success
        }

        cc.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                let shouldAutoplay = self?.isPlaying ?? false
                await self?.nextTrack(autoplay: shouldAutoplay)
            }
            return .success
        }

        cc.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                let shouldAutoplay = self?.isPlaying ?? false
                await self?.previousTrack(autoplay: shouldAutoplay)
            }
            return .success
        }

        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }

            // Perform seek synchronously for CarPlay
            let positionTime = e.positionTime
            print("🎯 CarPlay seek request to: \(positionTime)s")

            Task { @MainActor in
                await self.seek(to: positionTime)
                print("✅ Seek completed to: \(positionTime)s")
            }

            return .success
        }

        // Toggle play/pause command (for headphone button and other accessories)
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                if self?.isPlaying == true {
                    self?.pause(fromControlCenter: true)
                } else {
                    self?.play()
                }
            }
            return .success
        }

        // Enable all commands initially
        cc.playCommand.isEnabled = true
        cc.pauseCommand.isEnabled = true
        cc.nextTrackCommand.isEnabled = true
        cc.previousTrackCommand.isEnabled = true
        cc.changePlaybackPositionCommand.isEnabled = true
        cc.togglePlayPauseCommand.isEnabled = true

        // Enable seeking in CarPlay
        cc.changePlaybackPositionCommand.isEnabled = true
        print("✅ CarPlay seek command enabled")
    }

    // MARK: - Widget Integration

    func updateWidgetData() {
        guard let track = currentTrack else {
            WidgetDataManager.shared.clearCurrentTrack()
            return
        }

        Task {
            // Get artwork
            let artwork = await ArtworkManager.shared.getArtwork(for: track)
            let artworkData = artwork?.pngData()

            // Get artist name
            let artistName: String
            if let artistId = track.artistId,
               let artist = try? DatabaseManager.shared.read({ db in
                   try Artist.fetchOne(db, key: artistId)
               }) {
                artistName = artist.name
            } else {
                artistName = Localized.unknownArtist
            }

            // Get theme color
            let settings = DeleteSettings.load()
            let colorHex = settings.backgroundColorChoice.color.toHex()

            let widgetData = WidgetTrackData(
                trackId: track.stableId,
                title: track.title,
                artist: artistName,
                isPlaying: isPlaying,
                backgroundColorHex: colorHex
            )

            WidgetDataManager.shared.saveCurrentTrack(widgetData, artworkData: artworkData)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }


    // Enhanced manual approach with better Control Center synchronization
    private func updateNowPlayingInfoEnhanced() {
        guard let track = currentTrack else {
            // Clear Now Playing info if no track
            DispatchQueue.main.async {
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
                print("🎛️ Cleared Control Center - no track loaded")
            }
            return
        }

        let currentTime = nowPlayingElapsedTime()

        // Create comprehensive Now Playing info
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyPlaybackQueueCount: playbackQueue.count
        ]

        // Add queue position
        if playbackQueue.indices.contains(currentIndex) {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = currentIndex
        }

        if let artistName = cachedArtistName(for: track) {
            info[MPMediaItemPropertyArtist] = artistName
        }

        // Add track number
        if let trackNo = track.trackNo {
            info[MPMediaItemPropertyAlbumTrackNumber] = trackNo
        }

        // Add cached artwork
        if let cachedArtwork = cachedArtwork, cachedArtworkTrackId == track.stableId {
            info[MPMediaItemPropertyArtwork] = cachedArtwork
            print("🎨 Added cached artwork to Now Playing info for: \(track.title)")
        } else {
            print("⚠️ No cached artwork available for: \(track.title) (cached: \(cachedArtwork != nil), trackId match: \(cachedArtworkTrackId == track.stableId))")
        }

        // Update with explicit synchronization
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Re-attach artwork at write time: the artwork loader may have
            // finished between building `info` above and this block running,
            // and writing the stale artwork-less dictionary would wipe the
            // artwork it already set (lock screen loses the cover).
            var info = info
            if info[MPMediaItemPropertyArtwork] == nil,
               let cachedArtwork = self.cachedArtwork,
               self.cachedArtworkTrackId == track.stableId {
                info[MPMediaItemPropertyArtwork] = cachedArtwork
            }

            // Update Now Playing Info
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info

            // Trigger CarPlay Now Playing button update
            MPNowPlayingInfoCenter.default().playbackState = self.isPlaying ? .playing : .paused

            // Notify CarPlay delegate of state change
            NotificationCenter.default.post(name: NSNotification.Name("PlayerStateChanged"), object: nil)

            print("🎛️ Enhanced Control Center update - playing: \(self.isPlaying)")
            print("🎛️ Title: \(track.title), Time: \(currentTime)")
        }

        if cachedArtworkTrackId != track.stableId,
           artworkLoadTaskTrackId != track.stableId {
            artworkLoadTask?.cancel()
            artworkLoadTaskTrackId = track.stableId
            artworkLoadTask = Task { [weak self] in
                await self?.loadAndCacheArtwork(track: track)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if self.artworkLoadTaskTrackId == track.stableId {
                        self.artworkLoadTask = nil
                    }
                }
            }
        }
    }

    // MARK: - Audio Session Management

    private func setupAudioSessionCategory() throws {
        let s = AVAudioSession.sharedInstance()
        let isCarPlayEnvironment = sfbAudioManager.isCarPlayEnvironment
            || s.currentRoute.outputs.contains { $0.portType == .carAudio }

        // For background audio, avoid mixWithOthers - be the primary audio app
        let options: AVAudioSession.CategoryOptions = [.allowAirPlay, .allowBluetoothA2DP]

        // A connected CarPlay scene can own the session before `.carAudio`
        // appears in currentRoute. If the category is already playback, keep
        // CarPlay's mode/options instead of forcing another live reconfigure.
        if s.category != .playback || (!isCarPlayEnvironment && s.mode != .default) {
            try s.setCategory(.playback, mode: .default, options: options)
        }

        // CarPlay owns the hardware I/O settings for its active route. Asking to
        // change the buffer while that route is active fails with paramErr (-50)
        // and can trigger an unnecessary mediaserverd reconfiguration.
        if !isCarPlayEnvironment {
            try s.setPreferredIOBufferDuration(0.023) // 23ms buffer - good balance for iOS 18
        }

        print("🎧 Audio session category configured for primary playback (no mixWithOthers)")
    }

    private func activateAudioSession() throws {
        let s = AVAudioSession.sharedInstance()
        let isCarPlayEnvironment = sfbAudioManager.isCarPlayEnvironment
            || s.currentRoute.outputs.contains { $0.portType == .carAudio }

        print("🎧 Audio session state - Category: \(s.category), Other audio: \(s.isOtherAudioPlaying)")

        // Changing category/options on an already configured CarPlay session
        // forces another hardware route rebuild. Configure only when the
        // session is not already in the mode we need.
        if s.category != .playback || (!isCarPlayEnvironment && s.mode != .default) {
            try setupAudioSessionCategory()
        }

        // Always try to activate (iOS manages the actual state)
        try s.setActive(true, options: [])
        print("🎧 Audio session activation attempted successfully")

        UIApplication.shared.beginReceivingRemoteControlEvents()
        print("🎧 Remote control events enabled")
    }

    // MARK: - iOS 18 Audio Engine Reset Management

    private func cleanupAudioEngineForReset() async {
        print("🧹 Cleaning up audio engine for reset")

        // Stop all audio activity
        playerNode.stop()
        audioEngine.stop()

        // Remove all connections
        audioEngine.detach(playerNode)

        // Clear any scheduled buffers
        playerNode.reset()

        print("✅ Audio engine cleanup complete")
    }

    private func recreateAudioEngine() {
        print("🔄 Recreating audio engine and nodes")
        // Create detached instances. setupAudioEngine is the single owner of
        // node attachment and graph wiring; attaching here and then clearing
        // hasSetupAudioEngine made the next load attach the same node twice.
        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        eqManager.setAudioEngine(nil)
        // Reset flags
        hasSetupAudioEngine = false
        lastSampleRate = 0
        hasSetupAudioSession = false
        hasSetupRemoteCommands = false
        hasSetupAudioSessionNotifications = false
        print("✅ Audio engine recreated successfully with EQ")
    }



    // MARK: - Playback Control

    @discardableResult
    func loadTrack(_ track: Track, preservePlaybackTime: Bool = false) async -> Bool {
        // A song chosen on the phone or CarPlay supersedes any delayed route
        // recovery. Otherwise the 150 ms recovery for the old route can wake
        // after the new selection and reschedule the wrong playback state.
        cancelEngineConfigurationRecovery()
        loadGeneration &+= 1
        let generation = loadGeneration

        currentLoadTask?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            return await self.performLoadTrack(track, preservePlaybackTime: preservePlaybackTime, generation: generation)
        }
        currentLoadTask = task

        let loaded = await task.value
        if loadGeneration == generation {
            currentLoadTask = nil
        }
        return loaded
    }

    private func isCurrentLoad(_ generation: UInt64) -> Bool {
        loadGeneration == generation && !Task.isCancelled
    }

    private func performLoadTrack(_ track: Track, preservePlaybackTime: Bool, generation: UInt64) async -> Bool {
        // Determine actual format from file extension
        let url = URL(fileURLWithPath: track.path)
        let formatInfo = PlaybackRouter.getFormatInfo(for: url)
        print("📀 loadTrack called for: \(track.title) (format: \(formatInfo.format))")

        isLoadingTrack = true
        print("🔄 Starting load process for: \(track.title)")

        // Stop current playback and clean up
        await cleanupCurrentPlayback(resetTime: !preservePlaybackTime)
        guard isCurrentLoad(generation) else { return false }
        if nextTrack?.stableId != track.stableId {
            clearPreloadedNext()
        }

        // Reset timing state when loading a new track to ensure clean state for new sample rate
        if !preservePlaybackTime {
            seekTimeOffset = 0
            playbackTime = 0
            lastControlCenterUpdate = 0
        }

        nodeTimelineStartSampleTime = 0

        resetNowPlayingCachesForTrackChange()

        currentTrack = track
        playbackState = .loading

        // Volume control already set up in init

        do {
            // Stop accessing previous security-scoped resource if any
            if let previousURL = currentSecurityScopedURL {
                previousURL.stopAccessingSecurityScopedResource()
                currentSecurityScopedURL = nil
                print("🔓 Stopped accessing previous security-scoped resource")
            }

            // Check if this is an external file with a bookmark (file may have moved)
            var url: URL

            if let resolvedURL = await LibraryIndexer.shared.resolveBookmarkForTrack(track) {
                guard isCurrentLoad(generation) else { return false }

                // Bookmark found and resolved - use the current location
                print("📍 Using resolved bookmark location: \(resolvedURL.path)")
                url = resolvedURL

                // Start accessing security-scoped resource for external files
                guard url.startAccessingSecurityScopedResource() else {
                    print("❌ Failed to start accessing security-scoped resource")
                    throw PlayerError.fileNotFound
                }

                // Store URL to stop access later
                currentSecurityScopedURL = url
                print("🔐 Started accessing security-scoped resource for external file")
            } else {
                // No bookmark - use path from database
                url = URL(fileURLWithPath: track.path)
            }

            try await cloudDownloadManager.ensureLocal(url)
            guard isCurrentLoad(generation) else { return false }

            // Remove file protection to prevent background stalls
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.none],
                                                   ofItemAtPath: url.path)

            guard FileManager.default.fileExists(atPath: url.path) else {
                throw PlayerError.fileNotFound
            }

            // Remember whether the PREVIOUS track played through SFBAudioEngine -
            // the session/engine reset below is only needed for that switch
            let wasUsingSFBEngine = usingSFBEngine

            // Check if SFBAudioEngine can handle this format
            if SFBAudioEngineManager.canHandle(url: url) {
                print("🚀 PlayerEngine delegating to SFBAudioEngine: \(url.lastPathComponent)")

                do {
                    try Task.checkCancellation()
                    // Delegate to SFBAudioEngine for Opus, Vorbis, DSD
                    try await sfbAudioManager.loadAndPlay(url: url)
                    guard isCurrentLoad(generation) else {
                        sfbAudioManager.stop()
                        return false
                    }
                    usingSFBEngine = true

                    // Note: SFBAudioEngine now handles its own native EQ setup

                    // Sync duration from SFB engine
                    duration = sfbAudioManager.duration
                    isPlaying = sfbAudioManager.isPlaying
                    print("🔄 PlayerEngine duration synced from SFBAudioEngine: \(duration)s")

                    print("✅ Delegated to SFBAudioEngine: \(url.lastPathComponent)")
                } catch {
                    print("❌ SFBAudioEngine delegation failed: \(error)")

                    // Check if this is a DSD sample rate issue - if so, try native fallback
                    if let nsError = error as NSError?,
                       ((nsError.domain == "SFBAudioEngineManager" && nsError.code == 1001) ||
                        (nsError.domain == "org.sbooth.AudioEngine.DSDDecoder" && nsError.code == 2)),
                       url.pathExtension.lowercased() == "dff" || url.pathExtension.lowercased() == "dsf" {

                        print("💡 Attempting native playback fallback for DSD file with unsupported sample rate")

                        // Force native playback for this DSD file
                        usingSFBEngine = false

                        let loadedAudioFile = try await openNativeAudioFile(at: url, qos: .background)
                        guard isCurrentLoad(generation) else { return false }
                        audioFile = loadedAudioFile
                        print("✅ DSD file loaded successfully with native AVAudioFile fallback")
                    } else {
                        // For other SFBAudioEngine errors (like AudioPlayer init failure), rethrow
                        print("❌ SFBAudioEngine failed and no fallback available for this file type")
                        throw error
                    }
                }
            } else {
                // Use your existing native implementation for FLAC, MP3, WAV, AAC
                usingSFBEngine = false

                if let preloadedAudioFile = takePreloadedAudioFile(for: track) {
                    audioFile = preloadedAudioFile
                    print("⚡ Using preloaded native audio file: \(url.lastPathComponent)")
                } else {
                    let loadedAudioFile = try await openNativeAudioFile(at: url, qos: .userInitiated)
                    guard isCurrentLoad(generation) else { return false }
                    audioFile = loadedAudioFile
                }

                guard let audioFile = audioFile else {
                    throw PlayerError.invalidAudioFile
                }

                duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
            }

            guard isCurrentLoad(generation) else { return false }

            // Handle SFBAudioEngine specific setup
            if usingSFBEngine {
                if !preservePlaybackTime {
                    playbackTime = 0
                }
                // Audio session already configured in SFBAudioEngineManager.loadAndPlay()
                // Don't call configureAudioSession() again to avoid overriding DoP settings
            } else {
                // Native setup (already handled above)
                if !preservePlaybackTime {
                    playbackTime = 0
                }

                // Reset session/engine ONLY when switching from SFBAudioEngine
                // (DoP/DSD config is incompatible with native AVAudioEngine).
                // Running these on every native track change meant 5 blocking
                // XPC calls plus a full engine rebuild per song - the main
                // source of UI freezes when starting a song.
                if wasUsingSFBEngine {
                    await resetAudioSessionForNative()
                    resetAudioEngineForNative()
                }

                // Activate the final route before building the graph. In a
                // CarPlay launch, the inactive session can still report the
                // phone speaker's format; constructing against that format and
                // then activating CarPlay can crash AVAudioEngine.
                ensureAudioSessionSetup()
                do {
                    try activateAudioSession()
                } catch {
                    print("⚠️ Could not activate native audio session before graph setup: \(error)")
                }

                await configureAudioSession(for: audioFile!.processingFormat)
                ensureAudioEngineSetup(with: audioFile!.processingFormat)
            }

            guard isCurrentLoad(generation) else { return false }

            // Ensure remote commands are set up for Control Center
            ensureRemoteCommandsSetup()

            // Force immediate Control Center update with new track info and reset timing
            lastControlCenterUpdate = 0
            updateNowPlayingInfoEnhanced()

            playbackState = usingSFBEngine && isPlaying ? .playing : .stopped
            if usingSFBEngine && isPlaying {
                startPlaybackTimer()
                updateWidgetData()
            }
            isLoadingTrack = false
            return true

        } catch is CancellationError {
            if isCurrentLoad(generation) {
                playbackState = .stopped
                isLoadingTrack = false
                audioFile = nil
            }
            return false
        } catch {
            print("Failed to load track: \(error)")
            if isCurrentLoad(generation) {
                playbackState = .stopped
                isLoadingTrack = false
                audioFile = nil
            }
            return false
        }
    }

    private func openNativeAudioFile(at url: URL, qos: DispatchQoS.QoSClass = .userInitiated) async throws -> AVAudioFile {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: qos).async {
                do {
                    print("🎵 Loading native audio file: \(url.lastPathComponent)")

                    let fileExtension = url.pathExtension.lowercased()
                    if fileExtension == "dsf" || fileExtension == "dff" {
                        print("⚠️ DSD file rejected by SFBAudioEngine - may be due to sample rate or format incompatibility")

                        let dsdError = NSError(domain: "PlayerEngine", code: 3001, userInfo: [
                            NSLocalizedDescriptionKey: "DSD file not supported",
                            NSLocalizedFailureReasonErrorKey: "This DSD file has a sample rate that is too high for playback.",
                            NSLocalizedRecoverySuggestionErrorKey: "Try converting this DSD file to a lower sample rate (DSD64) or to a PCM format like FLAC."
                        ])
                        continuation.resume(throwing: dsdError)
                        return
                    }

                    guard FileManager.default.fileExists(atPath: url.path) else {
                        continuation.resume(throwing: PlayerError.fileNotFound)
                        return
                    }

                    let audioFile = try AVAudioFile(forReading: url)
                    print("✅ Native AVAudioFile loaded successfully: \(url.lastPathComponent)")
                    continuation.resume(returning: audioFile)
                } catch {
                    print("❌ Failed to load native AVAudioFile: \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func takePreloadedAudioFile(for track: Track) -> AVAudioFile? {
        guard nextTrack?.stableId == track.stableId, let preloaded = nextAudioFile else {
            return nil
        }

        nextAudioFile = nil
        nextTrack = nil
        nextTrackIndex = nil
        preloadNextTask = nil
        isPreloadingNext = false
        gaplessScheduled = false
        return preloaded
    }

    private func clearPreloadedNext() {
        preloadNextTask?.cancel()
        preloadNextTask = nil
        nextAudioFile = nil
        nextTrack = nil
        nextTrackIndex = nil
        isPreloadingNext = false
        gaplessScheduled = false
        nextTimelineStartSampleTime = nil
    }

    func play() {
        print("▶️ play() called - state: \(playbackState), loading: \(isLoadingTrack), usingSFBEngine: \(usingSFBEngine)")

        // Delegate to SFBAudioEngine if it's handling this track
        if usingSFBEngine {
            do {
                try sfbAudioManager.play()
                isPlaying = true
                playbackState = .playing
                startPlaybackTimer()
                print("✅ SFBAudioEngine resumed playback")
                updateNowPlayingInfoEnhanced()
                updateWidgetData()
                return
            } catch {
                print("❌ Failed to play with SFBAudioEngine: \(error)")
                return
            }
        }

        // If no audio file is loaded but we have a current track, load it first
        if audioFile == nil && currentTrack != nil && !isLoadingTrack {
            Task {
                var loaded = true
                // If state was already restored but audioFile is nil (e.g., after interruption),
                // we need to reload the current track with preserved position
                if hasRestoredState {
                    print("🔄 Reloading track after interruption, preserving position: \(playbackTime)s")
                    let savedPosition = playbackTime
                    loaded = await loadTrack(currentTrack!, preservePlaybackTime: true)

                    // Restore position after reload
                    if loaded && savedPosition > 0 {
                        await seek(to: savedPosition)
                        print("✅ Restored position after reload: \(savedPosition)s")
                    }
                } else {
                    // First-time state restoration
                    await ensurePlayerStateRestored()
                }

                // After loading, try to play again
                if loaded {
                    self.play()
                }
            }
            return
        }

        guard let audioFile = audioFile,
              playbackState != .loading,
              !isLoadingTrack else {
            print("⚠️ Cannot play: audioFile=\(audioFile != nil), state=\(playbackState), loading=\(isLoadingTrack)")
            return
        }

        // Set up audio engine only when needed (FIRST) with file's format
        // For new tracks, always ensure proper format configuration
        ensureAudioEngineSetup(with: audioFile.processingFormat)

        // Ensure basic audio session setup first
        ensureAudioSessionSetup()

        // CRITICAL: Activate audio session BEFORE starting engine (iOS 18 fix)
        do {
            try activateAudioSession()
        } catch {
            print("❌ Session activate failed: \(error)")
            // Try to continue anyway - might still work
        }

        if playbackState == .paused {
            print("▶️ Resuming from pause at position: \(playbackTime)s")

            // When resuming from pause, we need to re-schedule audio from the correct position
            // instead of just continuing the engine, because the timing may have drifted
            cancelPendingCompletions()
            playerNode.stop()

            // Re-schedule from the stored pause position
            // Note: audioFile is already unwrapped from the guard statement above

            // CRITICAL: Update seekTimeOffset to match the resume position
            // This ensures time calculation (seekTimeOffset + nodePlaybackTime) is correct
            seekTimeOffset = playbackTime
            nodeTimelineStartSampleTime = 0

            let framePosition = AVAudioFramePosition(playbackTime * audioFile.processingFormat.sampleRate)

            // IMPORTANT: Ensure audio engine is running BEFORE scheduling
            do {
                if !audioEngine.isRunning {
                    try audioEngine.start()
                    print("✅ Started audio engine before scheduling (resume)")
                }
            } catch {
                print("❌ Failed to start audio engine when resuming: \(error)")
                return
            }

            scheduleSegment(from: framePosition, file: audioFile, track: currentTrack, trackIndex: currentIndex)

            playerNode.play()
            isPlaying = true
            playbackState = .playing
            startPlaybackTimer()

            // End paused state monitoring and start regular playing monitoring
            stopSilentPlaybackForPause()
            endBackgroundMonitoring()
            startBackgroundMonitoring()

            print("✅ Resumed playback from position: \(playbackTime)s")

            // Update Now Playing info with enhanced approach
            updateNowPlayingInfoEnhanced()
            updateWidgetData()
            preloadAndScheduleNextIfNeeded()
            return
        }

        cancelPendingCompletions()
        playerNode.stop()

        print("🔊 Audio format - Sample Rate: \(audioFile.processingFormat.sampleRate), Channels: \(audioFile.processingFormat.channelCount)")
        print("🔊 Audio file length: \(audioFile.length) frames")

        // Check if the file length is reasonable
        guard audioFile.length > 0 && audioFile.length < 1_000_000_000 else {
            print("❌ Invalid audio file length: \(audioFile.length)")
            return
        }

        // IMPORTANT: Ensure audio engine is running BEFORE scheduling
        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
                print("✅ Audio engine started before scheduling")
            } catch {
                print("❌ Failed to start audio engine: \(error)")
                return
            }
        }

        // Preserve current seek offset and playback time when resuming
        let currentPosition = playbackTime
        let startFrame = AVAudioFramePosition(currentPosition * audioFile.processingFormat.sampleRate)

        // Schedule appropriate segment based on current position
            if startFrame > 0 && startFrame < audioFile.length {
                // Continue from current position
                seekTimeOffset = currentPosition
                nodeTimelineStartSampleTime = 0
                scheduleSegment(from: startFrame, file: audioFile, track: currentTrack, trackIndex: currentIndex)
                print("✅ Resuming playback from \(currentPosition)s (frame: \(startFrame))")
            } else {
                // Start from beginning - but only reset if we're actually at the beginning
                if playbackTime > 1.0 {
                    // We're not actually at the beginning, so preserve current position
                    let startFrame2 = AVAudioFramePosition(playbackTime * audioFile.processingFormat.sampleRate)
                    seekTimeOffset = playbackTime
                    nodeTimelineStartSampleTime = 0
                    scheduleSegment(from: startFrame2, file: audioFile, track: currentTrack, trackIndex: currentIndex)
                    print("✅ Resuming playback from current position: \(playbackTime)s")
                } else {
                    // Actually starting from beginning
                    seekTimeOffset = 0
                    playbackTime = 0
                    nodeTimelineStartSampleTime = 0
                    scheduleSegment(from: 0, file: audioFile, track: currentTrack, trackIndex: currentIndex)
                    print("✅ Starting playback from beginning")
                }
            }

        print("✅ Audio segment scheduled successfully")

        // Set up audio session notifications only when needed
        ensureAudioSessionNotificationsSetup()

        // Set up remote commands only when needed
        ensureRemoteCommandsSetup()

        playerNode.play()
        isPlaying = true
        playbackState = .playing
        startPlaybackTimer()

        // Update Now Playing info with enhanced approach
        updateNowPlayingInfoEnhanced()
        updateWidgetData()
        preloadAndScheduleNextIfNeeded()

        print("✅ Playback started and control center claimed")
    }

    func pause(fromControlCenter: Bool = false) {
        print("⏸️ pause() called - usingSFBEngine: \(usingSFBEngine)")

        // Delegate to SFBAudioEngine if it's handling this track
        if usingSFBEngine {
            sfbAudioManager.pause()
            isPlaying = false
            playbackState = .paused
            stopPlaybackTimer()
            print("✅ SFBAudioEngine paused")
            updateNowPlayingInfoEnhanced()
            updateWidgetData()
            return
        }

        // Capture current playback position before pausing
        if audioFile != nil {
            let currentPosition = currentTimeForCurrentNativeFile()

            print("🔄 Pausing at position: \(currentPosition)s (from Control Center: \(fromControlCenter))")

            // Store the exact pause position
            playbackTime = currentPosition
            seekTimeOffset = currentPosition
        }

        // Use AVAudioEngine.pause() instead of playerNode.pause()
        audioEngine.pause()

        // Update state
        isPlaying = false
        playbackState = .paused
        stopPlaybackTimer()

        print("🔄 Paused audio engine - stored position: \(playbackTime)s")

        // Update Now Playing info with enhanced approach
        updateNowPlayingInfoEnhanced()
        updateWidgetData()

        // Only start silent audio if paused from within the app, not from Control Center
        // This prevents Control Center button state confusion
        if !fromControlCenter {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                if self?.playbackState == .paused {
                    self?.startSilentPlaybackForPause()
                }
            }
        }

        // Save state when pausing
        savePlayerState()
    }

    @inline(__always)
    private func cancelPendingCompletions() {
        scheduleGeneration &+= 1
        gaplessScheduled = false
        nextTimelineStartSampleTime = nil
    }

    func stop() {
        cancelEngineConfigurationRecovery()
        cancelPendingCompletions()
        clearPreloadedNext()
        playerNode.stop()
        isPlaying = false
        playbackState = .stopped
        playbackTime = 0

        // Stop accessing security-scoped resource if any
        if let securedURL = currentSecurityScopedURL {
            securedURL.stopAccessingSecurityScopedResource()
            currentSecurityScopedURL = nil
            print("🔓 Stopped accessing security-scoped resource on stop")
        }
        stopPlaybackTimer()

        // Stop all background monitoring and silent playback
        stopSilentPlaybackForPause()
        endBackgroundMonitoring()

        // Update Now Playing info to show stopped state (but keep track info)
        updateNowPlayingInfoEnhanced()

        // Don't clear remote commands during track transitions - keep Control Center connected
        // Remote commands should only be cleared when the app is truly shutting down
        print("🎛️ Keeping remote commands connected for Control Center")

        // Don't deactivate audio session during track transitions - keep Control Center connected
        // Audio session should stay active to maintain Control Center connection
        // Only deactivate when the app is truly backgrounded or user explicitly stops playback
        print("🎧 Keeping audio session active to maintain Control Center connection")

        // Save state when stopping
        savePlayerState()
    }

    private func cleanupCurrentPlayback(resetTime: Bool = false) async {
        print("🧹 Cleaning up current playback")

        cancelEngineConfigurationRecovery()
        // Stopping AVAudioPlayerNode invokes outstanding completion handlers.
        // Invalidate them first so an old phone/CarPlay selection cannot be
        // mistaken for a natural track end while the replacement loads.
        cancelPendingCompletions()

        // Stop accessing security-scoped resource if any
        if let securedURL = currentSecurityScopedURL {
            securedURL.stopAccessingSecurityScopedResource()
            currentSecurityScopedURL = nil
            print("🔓 Stopped accessing security-scoped resource during cleanup")
        }

        // Stop timer first
        stopPlaybackTimer()

        // Stop appropriate audio engine
        if usingSFBEngine {
            print("🛑 Stopping SFBAudioEngine")
            sfbAudioManager.stop()
        } else {
            // Stop player node
            playerNode.stop()
        }

        // NEVER deactivate session during cleanup - this causes 30-second suspension on iOS 18

        // Reset state
        isPlaying = false
        if resetTime { playbackTime = 0 }        // was unconditional

        // Keep audio engine running for next playback
        // Don't stop the engine here as it causes the error message

        // Give the audio engine a moment to clean up
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
    }

    func seek(to time: TimeInterval) async {
        print("⏪ seek(to: \(time)) called - usingSFBEngine: \(usingSFBEngine)")
        clearPreloadedNext()

        // Delegate to SFBAudioEngine if it's handling this track
        if usingSFBEngine {
            do {
                try sfbAudioManager.seek(to: time)
                playbackTime = time
                print("✅ SFBAudioEngine seeked to: \(time)s")
                updateNowPlayingInfoEnhanced()
                return
            } catch {
                print("❌ Failed to seek with SFBAudioEngine: \(error)")
                return
            }
        }

        // If no audio file is loaded but we have a current track, load it first
        if audioFile == nil && currentTrack != nil && !isLoadingTrack {
            await ensurePlayerStateRestored()
        }

        guard let audioFile = audioFile,
              !isLoadingTrack else {
            print("⚠️ Cannot seek: audioFile=\(audioFile != nil), loading=\(isLoadingTrack)")
            return
        }

        let framePosition = AVAudioFramePosition(time * audioFile.processingFormat.sampleRate)
        let wasPlaying = isPlaying

        // Ensure framePosition is valid
        guard framePosition >= 0 && framePosition < audioFile.length else {
            print("❌ Invalid seek position: \(framePosition), file length: \(audioFile.length)")
            return
        }

        print("🔍 Seeking to: \(time)s (frame: \(framePosition))")

        // Ensure audio engine is set up before seeking with file's format
        ensureAudioEngineSetup(with: audioFile.processingFormat)

        // Ensure audio engine is running before scheduling
        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
                print("✅ Started audio engine before scheduling (seek)")
            } catch {
                print("❌ Failed to start audio engine during seek: \(error)")
                return
            }
        }

        cancelPendingCompletions()
        playerNode.stop()

        // Update seek offset and playback time
        seekTimeOffset = time
        playbackTime = time
        nodeTimelineStartSampleTime = 0
        scheduleSegment(from: framePosition, file: audioFile, track: currentTrack, trackIndex: currentIndex)

        if wasPlaying {
            playerNode.play()
            isPlaying = true
            playbackState = .playing
            startPlaybackTimer()

            // Update Now Playing info after seek
            updateNowPlayingInfoEnhanced()
            preloadAndScheduleNextIfNeeded()
        } else {
            // Update position even when paused
            updateNowPlayingInfoEnhanced()
        }

        print("✅ Seek completed")
    }

    private func startSilentPlaybackForPause() {
        // Create a very quiet, looping audio player to maintain background execution
        guard pausedSilentPlayer == nil else {
            if pausedSilentPlayer?.isPlaying == false {
                pausedSilentPlayer?.play()
            }
            return
        }

        do {
            // Create a tiny silent buffer programmatically
            let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)! // 0.1 seconds at 44.1kHz
            buffer.frameLength = 4410

            // Buffer is already silent (zero-filled by default)

            // Write to temporary file
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("pause_silence.caf")
            let audioFile = try AVAudioFile(forWriting: tempURL, settings: format.settings)
            try audioFile.write(from: buffer)

            // Create player with very low volume
            pausedSilentPlayer = try AVAudioPlayer(contentsOf: tempURL)
            pausedSilentPlayer?.volume = 0.001  // Nearly silent
            pausedSilentPlayer?.numberOfLoops = -1  // Loop indefinitely
            pausedSilentPlayer?.prepareToPlay()
            pausedSilentPlayer?.play()

            print("🔇 Started silent playback to maintain background execution during pause")

        } catch {
            print("❌ Failed to create silent player for pause: \(error)")
            // Fallback to the original method
            maintainAudioSessionForBackground()
        }
    }

    // MARK: - SFBAudioEngine Integration
    // SFBAudioEngine now handles playback directly via SFBAudioEngineManager


    // MARK: - Audio Scheduling Helper

    @discardableResult
    private func scheduleSegment(from startFrame: AVAudioFramePosition, file: AVAudioFile, track: Track? = nil, trackIndex: Int? = nil) -> Bool {
        // Safety check: Ensure audio engine is running
        guard audioEngine.isRunning else {
            print("❌ Cannot schedule segment: audio engine is not running")
            return false
        }

        // Validate startFrame is within bounds
        guard startFrame >= 0 && startFrame < file.length else {
            print("❌ Invalid startFrame: \(startFrame), file length: \(file.length)")
            return false
        }

        let remaining = file.length - startFrame
        guard remaining > 0 else {
            print("❌ No remaining frames to schedule: startFrame=\(startFrame), length=\(file.length)")
            return false
        }

        // Validate that frameCount doesn't overflow AVAudioFrameCount
        guard remaining <= AVAudioFrameCount.max else {
            print("❌ Remaining frames exceed AVAudioFrameCount.max: \(remaining)")
            return false
        }

        let scheduledGeneration = scheduleGeneration
        let scheduledTrackId = track?.stableId
        let scheduledIndex = trackIndex

        playerNode.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: AVAudioFrameCount(remaining),
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                await self?.handleScheduledSegmentFinished(
                    generation: scheduledGeneration,
                    trackStableId: scheduledTrackId,
                    trackIndex: scheduledIndex
                )
            }
        }

        print("✅ Successfully scheduled segment: startFrame=\(startFrame), frameCount=\(remaining)")

        // Start background monitoring when we schedule a segment
        startBackgroundMonitoring()
        return true
    }

    private func nextPlayableIndexForPreload() -> Int? {
        guard !playbackQueue.isEmpty, !isLoopingSong else { return nil }
        if currentIndex < playbackQueue.count - 1 {
            return currentIndex + 1
        }
        if isRepeating {
            return 0
        }
        return nil
    }

    private func canGaplesslySchedule(_ currentFile: AVAudioFile, with nextFile: AVAudioFile) -> Bool {
        let currentFormat = currentFile.processingFormat
        let nextFormat = nextFile.processingFormat
        return abs(currentFormat.sampleRate - nextFormat.sampleRate) < 0.1
            && currentFormat.channelCount == nextFormat.channelCount
            && currentFormat.commonFormat == nextFormat.commonFormat
            && currentFormat.isInterleaved == nextFormat.isInterleaved
    }

    private func preloadAndScheduleNextIfNeeded() {
        guard !usingSFBEngine,
              isPlaying,
              audioFile != nil,
              let nextIndex = nextPlayableIndexForPreload(),
              playbackQueue.indices.contains(nextIndex) else {
            return
        }

        let candidate = playbackQueue[nextIndex]

        if nextTrack?.stableId == candidate.stableId {
            scheduleGaplessNextIfPossible()
            return
        }

        clearPreloadedNext()

        let preloadGeneration = loadGeneration
        isPreloadingNext = true
        preloadNextTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let url = URL(fileURLWithPath: candidate.path)

            guard !SFBAudioEngineManager.canHandle(url: url) else {
                self.isPreloadingNext = false
                return
            }

            // Avoid holding security-scoped resources for a future track.
            guard await LibraryIndexer.shared.resolveBookmarkForTrack(candidate) == nil else {
                self.isPreloadingNext = false
                return
            }

            do {
                try await self.cloudDownloadManager.ensureLocal(url)
                try Task.checkCancellation()

                let file = try await self.openNativeAudioFile(at: url, qos: .utility)
                try Task.checkCancellation()

                guard self.loadGeneration == preloadGeneration,
                      self.playbackQueue.indices.contains(nextIndex),
                      self.playbackQueue[nextIndex].stableId == candidate.stableId else {
                    return
                }

                self.nextAudioFile = file
                self.nextTrack = candidate
                self.nextTrackIndex = nextIndex
                self.isPreloadingNext = false
                self.scheduleGaplessNextIfPossible()
            } catch is CancellationError {
                self.isPreloadingNext = false
            } catch {
                self.isPreloadingNext = false
                print("⚠️ Failed to preload next track for gapless playback: \(error)")
            }
        }
    }

    private func scheduleGaplessNextIfPossible() {
        guard !gaplessScheduled,
              !usingSFBEngine,
              isPlaying,
              audioEngine.isRunning,
              let currentFile = audioFile,
              let nextFile = nextAudioFile,
              let nextTrack,
              let nextTrackIndex else {
            return
        }

        guard canGaplesslySchedule(currentFile, with: nextFile) else {
            print("ℹ️ Next track format differs; using normal transition instead of gapless")
            return
        }

        let currentStartFrame = AVAudioFramePosition(seekTimeOffset * currentFile.processingFormat.sampleRate)
        let remainingFrames = max(0, currentFile.length - currentStartFrame)
        guard remainingFrames > 0 else { return }

        let scheduled = scheduleSegment(from: 0, file: nextFile, track: nextTrack, trackIndex: nextTrackIndex)
        guard scheduled else { return }

        nextTimelineStartSampleTime = nodeTimelineStartSampleTime + remainingFrames
        gaplessScheduled = true
        print("✅ Gapless next track scheduled: \(nextTrack.title)")
    }

    private func promoteGaplessNextIfAvailable() -> Bool {
        guard gaplessScheduled,
              let nextFile = nextAudioFile,
              let next = nextTrack,
              let nextIndex = nextTrackIndex,
              playbackQueue.indices.contains(nextIndex) else {
            return false
        }

        currentIndex = nextIndex
        currentTrack = next
        audioFile = nextFile
        duration = Double(nextFile.length) / nextFile.processingFormat.sampleRate
        seekTimeOffset = 0
        nodeTimelineStartSampleTime = nextTimelineStartSampleTime ?? currentNodeSampleTime() ?? 0
        playbackTime = currentTimeForCurrentNativeFile()
        playbackState = .playing
        isPlaying = true

        nextAudioFile = nil
        nextTrack = nil
        nextTrackIndex = nil
        nextTimelineStartSampleTime = nil
        gaplessScheduled = false
        isPreloadingNext = false

        resetNowPlayingCachesForTrackChange()
        lastControlCenterUpdate = 0
        updateNowPlayingInfoEnhanced()
        updateWidgetData()
        preloadAndScheduleNextIfNeeded()
        return true
    }

    private func currentNodeSampleTime() -> AVAudioFramePosition? {
        // playerTime(forNodeTime:) raises an ObjC exception - not nil - when
        // the node is detached or the engine is torn down mid-query (App Store
        // crash group spanning 1.0.6-1.2.2), so check attachment and engine
        // state before asking.
        guard audioEngine.attachedNodes.contains(playerNode),
              audioEngine.isRunning,
              let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            return nil
        }
        return playerTime.sampleTime
    }

    private func currentTimeForCurrentNativeFile() -> TimeInterval {
        guard let audioFile = audioFile,
              let currentSampleTime = currentNodeSampleTime() else {
            return playbackTime
        }

        let relativeSampleTime = max(0, currentSampleTime - nodeTimelineStartSampleTime)
        let time = seekTimeOffset + Double(relativeSampleTime) / audioFile.processingFormat.sampleRate
        return min(max(time, 0), duration)
    }

    private func handleScheduledSegmentFinished(generation: UInt64, trackStableId: String?, trackIndex: Int?) async {
        guard generation == scheduleGeneration,
              isPlaying,
              !usingSFBEngine else {
            return
        }

        if let trackStableId, trackStableId != currentTrack?.stableId {
            return
        }

        if promoteGaplessNextIfAvailable() {
            return
        }

        await handleTrackEnd()
    }

    private func startBackgroundMonitoring() {
        // Only create a background task if we don't already have one
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
                print("🚨 Background task expiring during playback")
                Task { @MainActor in
                    self?.endBackgroundMonitoring()
                }
            }
        }

        // Start a timer that works in background
        backgroundCheckTimer?.invalidate()
        backgroundCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkIfTrackEnded()
            }
        }
    }

    private func endBackgroundMonitoring() {
        backgroundCheckTimer?.invalidate()
        backgroundCheckTimer = nil

        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private func stopSilentPlaybackForPause() {
        pausedSilentPlayer?.stop()
        pausedSilentPlayer = nil
        print("🔇 Stopped silent playback for pause")
    }

    private func maintainAudioSessionForBackground() {
        // Keep the audio session active to prevent app termination
        Task { @MainActor in
            do {
                // Don't re-grab the audio session during an interruption (alarm, phone call)
                // This would prevent the alarm from ringing properly
                guard !isAudioSessionInterrupted else {
                    print("🎧 Audio session interrupted, not maintaining session")
                    return
                }

                let session = AVAudioSession.sharedInstance()

                // Only maintain session if we're not already active
                guard !session.isOtherAudioPlaying else {
                    print("🎧 Other audio playing, not maintaining session")
                    return
                }

                // Don't change category if already correct - this prevents the error
                if session.category != .playback {
                    try session.setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetoothA2DP])
                }

                // Only activate if not already active
                if !session.secondaryAudioShouldBeSilencedHint {
                    try session.setActive(true, options: [])
                    print("🎧 Audio session maintained during pause to prevent termination")
                } else {
                    print("🎧 Audio session already active during pause")
                }

            } catch {
                print("❌ Failed to maintain audio session during pause: \(error)")
                // Don't try to maintain session if it fails - let the app handle it naturally
            }
        }
    }

    private func checkIfTrackEnded() async {
        // Check if audio has finished playing
        guard isPlaying else { return }

        // Skip native player checks when using SFBAudioEngine
        guard !usingSFBEngine else { return }

        // Check if player node has stopped naturally (reached end).
        // A stopped *engine* (config change, interruption) also makes the node
        // report not-playing - only treat it as track end while the engine runs.
        if audioEngine.isRunning && !playerNode.isPlaying && audioFile != nil {
            // Track has ended
            if promoteGaplessNextIfAvailable() {
                return
            }
            await handleTrackEnd()
            return
        }

        // Alternative check: position-based
        if audioFile != nil {
            let currentTime = currentTimeForCurrentNativeFile()

            if currentTime >= duration - 0.2 && duration > 0 {
                guard !gaplessScheduled else { return }
                // Track is ending
                isPlaying = false // Prevent multiple triggers
                await handleTrackEnd()
            }
        }
    }

    // MARK: - Index Normalization Helper

    private func normalizeIndexAndTrack() {
        if playbackQueue.isEmpty {
            currentIndex = 0
            currentTrack = nil
            return
        }

        if let ct = currentTrack,
           let idx = playbackQueue.firstIndex(where: { $0.stableId == ct.stableId }) {
            currentIndex = idx
        } else {
            currentIndex = max(0, min(currentIndex, playbackQueue.count - 1))
            currentTrack = playbackQueue[currentIndex]
        }
    }

    // MARK: - Queue Management

    func playTrack(_ track: Track, queue: [Track] = []) async {
        print("🎵 Playing track: \(track.title)")

        // Restore player state on first interaction if not already done
        await ensurePlayerStateRestored()

        playbackQueue = queue.isEmpty ? [track] : queue
        currentIndex = playbackQueue.firstIndex(where: { $0.stableId == track.stableId }) ?? 0

        // Explicitly set the current track to ensure UI synchronization
        currentTrack = track

        // Save original queue for shuffle functionality
        originalQueue = playbackQueue.map { $0.stableId }

        normalizeIndexAndTrack()

        let loaded = await loadTrack(track)
        guard loaded else { return }

        if usingSFBEngine && isPlaying {
            playbackState = .playing
            startPlaybackTimer()
            updateNowPlayingInfoEnhanced()
            updateWidgetData()
        } else {
            play()
        }
    }

    func nextTrack(autoplay: Bool? = nil) async {
        guard !playbackQueue.isEmpty else { return }
        normalizeIndexAndTrack()
        let shouldAutoplay = autoplay ?? isPlaying

        currentIndex = (currentIndex + 1) % playbackQueue.count
        let next = playbackQueue[currentIndex]
        let loaded = await loadTrack(next, preservePlaybackTime: false)
        guard loaded else { return }

        if shouldAutoplay {
            if usingSFBEngine && isPlaying {
                playbackState = .playing
                startPlaybackTimer()
            } else {
                play()
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.cancelPendingCompletions()
                self.playerNode.stop()
                self.isPlaying = false
                self.playbackState = .paused
                self.seekTimeOffset = 0
                self.playbackTime = 0
                self.updateNowPlayingInfoEnhanced()
                self.updateWidgetData()
            }
        }
    }

    func previousTrack(autoplay: Bool? = nil) async {
        guard !playbackQueue.isEmpty else { return }
        normalizeIndexAndTrack()

        let wasPlaying = autoplay ?? isPlaying

        if playbackTime > 3.0 {
            await seek(to: 0)
            if !wasPlaying {
                await MainActor.run {
                    isPlaying = false
                    playbackState = .paused
                    updateNowPlayingInfoEnhanced()
                    updateWidgetData()
                }
            }
            return
        }

        currentIndex = currentIndex > 0 ? currentIndex - 1 : playbackQueue.count - 1
        let prev = playbackQueue[currentIndex]
        let loaded = await loadTrack(prev, preservePlaybackTime: false)
        guard loaded else { return }

        if wasPlaying {
            await MainActor.run {
                if usingSFBEngine && isPlaying {
                    playbackState = .playing
                    startPlaybackTimer()
                } else {
                    play()
                }
            }
        } else {
            await MainActor.run {
                cancelPendingCompletions()
                playerNode.stop()
                isPlaying = false
                playbackState = .paused
                seekTimeOffset = 0
                playbackTime = 0
                updateNowPlayingInfoEnhanced()
                updateWidgetData()
            }
        }
    }

    func addToQueue(_ track: Track) {
        playbackQueue.append(track)
    }

    func insertNext(_ track: Track) {
        let insertIndex = currentIndex + 1
        playbackQueue.insert(track, at: min(insertIndex, playbackQueue.count))
    }

    func cycleLoopMode() {
        if !isRepeating && !isLoopingSong {
            // Off → Queue Loop
            isRepeating = true
            isLoopingSong = false
            print("🔁 Queue loop mode: ON")
        } else if isRepeating && !isLoopingSong {
            // Queue Loop → Song Loop
            isRepeating = false
            isLoopingSong = true
            print("🔂 Song loop mode: ON")
        } else {
            // Song Loop → Off
            isRepeating = false
            isLoopingSong = false
            print("🚫 Loop mode: OFF")
        }
    }

    func toggleShuffle() {
        isShuffled.toggle()
        print("🔀 Shuffle mode: \(isShuffled ? "ON" : "OFF")")

        if isShuffled {
            // Save original order and shuffle the queue
            originalQueue = playbackQueue.map { $0.stableId }
            shuffleQueue()
        } else {
            // Restore original order
            restoreOriginalQueue()
        }

        normalizeIndexAndTrack()
    }

    private func shuffleQueue() {
        guard !playbackQueue.isEmpty else { return }
        normalizeIndexAndTrack()
        let anchor = playbackQueue[currentIndex]
        var rest = playbackQueue
        rest.remove(at: currentIndex)
        rest.shuffle()
        playbackQueue = [anchor] + rest
        currentIndex = 0

        print("🔀 Queue shuffled, current track remains at index 0")
    }

    private func restoreOriginalQueue() {
        guard !originalQueue.isEmpty else { return }

        do {
            let restoredQueue = try databaseManager.getTracksByStableIdsPreservingOrder(originalQueue)
            guard !restoredQueue.isEmpty else { return }

            // Find current track in original queue
            if let currentTrack = self.currentTrack,
               let originalIndex = restoredQueue.firstIndex(where: { $0.stableId == currentTrack.stableId }) {
                playbackQueue = restoredQueue
                currentIndex = originalIndex
                print("🔀 Original queue restored, current track at index \(originalIndex)")
            } else {
                playbackQueue = restoredQueue
                currentIndex = min(currentIndex, max(0, restoredQueue.count - 1))
            }
        } catch {
            print("❌ Failed to restore original queue: \(error)")
        }

        normalizeIndexAndTrack()
    }

    // MARK: - Audio Session Configuration

    /// Reset AVAudioEngine to clean state when switching from SFBAudioEngine
    private func resetAudioEngineForNative() {
        print("🔄 Resetting AVAudioEngine for native playback")

        // Stop and reset the audio engine completely
        if audioEngine.isRunning {
            audioEngine.stop()
            print("✅ AVAudioEngine stopped")
        }

        // Reset player node
        if playerNode.isPlaying {
            playerNode.stop()
        }

        // Replace the complete graph with detached instances. This transition
        // is hit when CarPlay takes over while SFBAudioEngine was playing.
        // setupAudioEngine will attach each node exactly once after the
        // CarPlay route and its hardware format have settled.
        eqManager.setAudioEngine(nil)
        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()

        // Reset setup flag to force proper reconnection
        hasSetupAudioEngine = false
        lastSampleRate = 0

        print("✅ AVAudioEngine reset complete for native playback")
    }

    /// Reset audio session to standard configuration when switching from SFBAudioEngine
    private func resetAudioSessionForNative() async {
        // AVAudioSession calls are blocking XPC round-trips to mediaserverd -
        // run them off the main thread so the UI never freezes
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let session = AVAudioSession.sharedInstance()

                    print("🔄 Resetting audio session for native playback after SFBAudioEngine")

                    // Deactivate first to clear any SFBAudioEngine DoP/DSD configuration
                    try session.setActive(false)

                    // Set standard category for native playback
                    try session.setCategory(.playback, mode: .default, options: [.allowBluetoothA2DP])

                    // Reset to standard sample rate and buffer for native AVAudioEngine
                    try session.setPreferredSampleRate(44100) // Start with standard rate
                    try session.setPreferredIOBufferDuration(0.020) // 20ms buffer for native

                    // Reactivate with new settings
                    try session.setActive(true)
                    print("✅ Audio session reset and reactivated for native playback")

                } catch {
                    print("⚠️ Audio session reset failed (continuing): \(error)")
                    // Continue anyway - the next configureAudioSession call will fix it
                }
                continuation.resume()
            }
        }
    }

    private func configureAudioSession(for format: AVAudioFormat) async {
        let targetSampleRate = currentTrack?.sampleRate
        let carPlaySceneIsActive = sfbAudioManager.isCarPlayEnvironment
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let session = AVAudioSession.sharedInstance()
                    let isCarPlayEnvironment = carPlaySceneIsActive
                        || session.currentRoute.outputs.contains { $0.portType == .carAudio }

                    // Only touch the session when the rate actually changes -
                    // setPreferredSampleRate + setActive are blocking XPC calls
                    // and can force an audio hardware reconfiguration
                    if !isCarPlayEnvironment,
                       let sampleRate = targetSampleRate,
                       abs(session.sampleRate - Double(sampleRate)) > 1.0 {
                        try session.setPreferredSampleRate(Double(sampleRate))
                        // CRITICAL: Must activate session for sample rate change to take effect
                        try session.setActive(true)
                    } else if isCarPlayEnvironment {
                        // CarPlay owns the hardware sample rate (commonly 48 kHz).
                        // AVAudioEngine performs the conversion from the file
                        // rate; requesting 44.1/96/192 kHz here can tear down
                        // the live route and crash while starting playback.
                        print("🚗 Keeping CarPlay hardware sample rate: \(session.sampleRate)")
                    }

                    print("Configured audio session - session rate: \(session.sampleRate), file rate: \(format.sampleRate)")

                } catch {
                    print("Failed to configure audio session: \(error)")
                }
                continuation.resume()
            }
        }
    }

    // MARK: - Timer and Updates

    func startPlaybackTimer() {
        // Don't start the high-frequency UI timer in background — it causes
        // SwiftUI view redraws that spike CPU and trigger the iOS watchdog.
        // Background track-end detection is handled by backgroundCheckTimer instead.
        if isInBackground {
            print("🔄 Skipping playback timer start - app is in background")
            return
        }

        let appState = UIApplication.shared.applicationState
        if hasSetupSiriBackgroundSession && appState == .background {
            print("🔄 Skipping playback timer start - Siri background mode active")
            return
        }

        stopPlaybackTimer()

        // Four UI updates per second are smooth enough for elapsed-time labels
        // and avoid flooding SwiftUI's list/layout pipeline. Audio timing comes
        // from the render timeline, not from this timer.
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.updatePlaybackTime()
            }
        }
    }

    private var lastControlCenterUpdate: TimeInterval = 0

    private func updatePlaybackTime() async {
        // Handle SFBAudioEngine timing
        if usingSFBEngine {
            playbackTime = sfbAudioManager.currentTime

            // Check for completion
            if playbackTime >= duration && duration > 0 {
                await handleTrackEnd()
            }
            if abs(playbackTime - lastControlCenterUpdate) >= 0.5 {
                lastControlCenterUpdate = playbackTime
                updateNowPlayingElapsedTime()
            }
            return
        }

        guard audioFile != nil,
              audioEngine.attachedNodes.contains(playerNode),
              audioEngine.isRunning,
              playerNode.lastRenderTime != nil else {
            return
        }
        let calculatedTime = currentTimeForCurrentNativeFile()

        // Only update playback time if we're actually playing (prevents drift during pause/resume)
        if isPlaying {
            playbackTime = calculatedTime
        }

        // Remove this duplicate detection - it's handled by checkIfTrackEnded()
        /* DELETE THIS BLOCK:
         if isPlaying && playbackTime >= duration - 0.1 && duration > 0 {
         isPlaying = false
         await handleTrackEnd()
         }
         */

        // Update Control Center more frequently for better synchronization - every 0.5 seconds instead of 2 seconds
        // This ensures smooth time display in Control Center regardless of sample rate changes
        if abs(playbackTime - lastControlCenterUpdate) >= 0.5 {
            lastControlCenterUpdate = playbackTime
            updateNowPlayingElapsedTime()
        }
    }

    private func handleTrackEnd() async {
        guard !isLoadingTrack else { return }

        if promoteGaplessNextIfAvailable() {
            return
        }

        if isLoopingSong, let t = currentTrack {
            let loaded = await loadTrack(t)
            if loaded { play() }
            return
        }

        if currentIndex < playbackQueue.count - 1 {
            currentIndex = (currentIndex + 1) % playbackQueue.count
            let next = playbackQueue[currentIndex]
            let loaded = await loadTrack(next, preservePlaybackTime: false)
            if loaded {
                if usingSFBEngine && isPlaying {
                    playbackState = .playing
                    startPlaybackTimer()
                } else {
                    play()
                }
            }
            return
        }

        if isRepeating, !playbackQueue.isEmpty {
            currentIndex = 0
            currentTrack = playbackQueue[0]
            let loaded = await loadTrack(playbackQueue[0])
            if loaded {
                if usingSFBEngine && isPlaying {
                    playbackState = .playing
                    startPlaybackTimer()
                } else {
                    play()
                }
            }
            return
        }

        stop()
    }


    func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    /// Stop all high-frequency UI timers when entering background to prevent
    /// SwiftUI redraws from spiking CPU and triggering the iOS watchdog kill.
    func suspendUITimersForBackground() {
        isInBackground = true
        stopPlaybackTimer()
        print("⏸️ Suspended UI timers for background")
    }

    /// Restart UI timers when returning to foreground.
    func resumeUITimersForForeground() {
        isInBackground = false
        if isPlaying {
            startPlaybackTimer()
        }
        print("▶️ Resumed UI timers for foreground")
    }

    // MARK: - Now Playing Info

    private func resetNowPlayingCachesForTrackChange() {
        cachedArtwork = nil
        cachedArtworkTrackId = nil
        artworkLoadTask?.cancel()
        artworkLoadTask = nil
        artworkLoadTaskTrackId = nil
        cachedNowPlayingArtistTrackId = nil
        cachedNowPlayingArtistName = nil
    }

    private func nowPlayingElapsedTime() -> TimeInterval {
        if usingSFBEngine {
            return sfbAudioManager.currentTime
        }
        return currentTimeForCurrentNativeFile()
    }

    private func cachedArtistName(for track: Track) -> String? {
        if cachedNowPlayingArtistTrackId == track.stableId {
            return cachedNowPlayingArtistName
        }

        let artistName: String?
        do {
            artistName = try databaseManager.getArtistDisplayName(
                forTrackStableId: track.stableId,
                fallbackArtistId: track.artistId
            )
        } catch {
            print("Failed to fetch metadata: \(error)")
            artistName = nil
        }

        cachedNowPlayingArtistTrackId = track.stableId
        cachedNowPlayingArtistName = artistName
        return artistName
    }

    private func updateNowPlayingElapsedTime() {
        guard currentTrack != nil else { return }

        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = nowPlayingElapsedTime()
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    private func loadAndCacheArtwork(track: Track) async {
        // Always try ArtworkManager cache first — avoids re-parsing large files
        if let uiImage = await ArtworkManager.shared.getArtwork(for: track) {
            await MainActor.run {
                let artwork = self.convertUIImageToMPMediaItemArtwork(uiImage)
                self.cachedArtwork = artwork
                self.cachedArtworkTrackId = track.stableId
                self.updateNowPlayingInfoWithCachedArtwork()
                print("🎨 Cached artwork from ArtworkManager for: \(track.title)")
            }
            return
        }

        // No cached artwork — only then fall back to file parsing
        guard track.hasEmbeddedArt else {
            // Mark this track so we don't keep retrying
            await MainActor.run {
                self.cachedArtworkTrackId = track.stableId
            }
            return
        }

        do {
            let url = URL(fileURLWithPath: track.path)
            try await cloudDownloadManager.ensureLocal(url)

            let artwork: MPMediaItemArtwork? = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let fileExtension = url.pathExtension.lowercased()
                    print("🎵 Loading artwork from file: \(url.lastPathComponent)")

                    if fileExtension == "dsf" || fileExtension == "dff" {
                        if let art = self.loadArtworkFromSFBAudioEngine(url: url) ?? self.loadArtworkFromDSDFile(url: url) {
                            continuation.resume(returning: art)
                        } else {
                            continuation.resume(returning: nil)
                        }
                    } else if fileExtension == "flac" {
                        if let art = self.loadArtworkFromAVAsset(url: url) ?? self.loadArtworkFromFLACMetadata(url: url) {
                            continuation.resume(returning: art)
                        } else {
                            continuation.resume(returning: nil)
                        }
                    } else {
                        continuation.resume(returning: self.loadArtworkFromAVAsset(url: url))
                    }
                }
            }

            await MainActor.run {
                if let artwork = artwork {
                    self.cachedArtwork = artwork
                    self.cachedArtworkTrackId = track.stableId
                    self.updateNowPlayingInfoWithCachedArtwork()
                    print("🎨 Cached artwork from file for: \(track.title)")
                } else {
                    // Mark as attempted so we don't retry
                    self.cachedArtworkTrackId = track.stableId
                    print("🎨 No artwork found for: \(track.title)")
                }
            }

        } catch {
            print("❌ Failed to load artwork for caching: \(error)")
            // Mark as attempted so we don't keep retrying and crashing on large files
            await MainActor.run {
                self.cachedArtworkTrackId = track.stableId
            }
        }
    }

    private nonisolated func loadArtworkFromAVAsset(url: URL) -> MPMediaItemArtwork? {
        do {
            let asset = AVAsset(url: url)

            // Use synchronous metadata loading for compatibility
            let commonMetadata = asset.commonMetadata

            for metadataItem in commonMetadata {
                if metadataItem.commonKey == .commonKeyArtwork,
                   let data = metadataItem.dataValue,
                   let originalImage = UIImage(data: data) {

                    print("🎨 Found artwork in AVAsset metadata (size: \(Int(originalImage.size.width))x\(Int(originalImage.size.height)))")

                    // Crop to square if width is significantly larger than height
                    let processedImage = self.cropToSquareIfNeeded(image: originalImage)

                    // Render before handing the image to MediaRemote. A custom
                    // request handler may be invoked on MediaRemote's private
                    // queue, where an actor-inherited Swift closure traps.
                    let targetSize = CGSize(width: 1024, height: 1024)
                    let artworkImage = self.resizeImage(processedImage, to: targetSize)
                    let artwork = self.makeMediaItemArtwork(from: artworkImage)

                    return artwork
                }
            }

            print("⚠️ No artwork found in AVAsset metadata")
            return nil

        }
    }

    private nonisolated func loadArtworkFromFLACMetadata(url: URL) -> MPMediaItemArtwork? {
        do {
            // Read FLAC file directly to extract embedded artwork
            let data = try Data(contentsOf: url, options: .mappedIfSafe)

            // Look for FLAC PICTURE metadata block
            if let artwork = extractFLACPictureBlock(from: data) {
                print("🎨 Found artwork in FLAC PICTURE block")

                let processedImage = self.cropToSquareIfNeeded(image: artwork)

                let mpArtwork = self.makeMediaItemArtwork(from: processedImage)

                return mpArtwork
            }

            print("⚠️ No PICTURE block found in FLAC file")
            return nil

        } catch {
            print("❌ Direct FLAC metadata reading failed: \(error)")
            return nil
        }
    }

    private nonisolated func extractFLACPictureBlock(from data: Data) -> UIImage? {
        // FLAC file format: 4-byte signature "fLaC" followed by metadata blocks

        guard data.count > 4 else { return nil }

        // Check for FLAC signature
        let signature = data.subdata(in: 0..<4)
        guard signature == Data([0x66, 0x4C, 0x61, 0x43]) else { // "fLaC"
            print("⚠️ Invalid FLAC signature")
            return nil
        }

        var offset = 4

        // Parse metadata blocks
        while offset < data.count - 4 {
            // Read metadata block header (4 bytes)
            let blockHeader = data.subdata(in: offset..<(offset + 4))

            let isLastBlock = (blockHeader[0] & 0x80) != 0
            let blockType = blockHeader[0] & 0x7F

            // Block length (24-bit big-endian)
            let blockLength = Int(blockHeader[1]) << 16 | Int(blockHeader[2]) << 8 | Int(blockHeader[3])

            offset += 4

            // Check if this is a PICTURE block (type 6)
            if blockType == 6 {
                print("🖼️ Found FLAC PICTURE block at offset \(offset), length: \(blockLength)")

                guard offset + blockLength <= data.count else {
                    print("❌ PICTURE block extends beyond file")
                    break
                }

                let pictureBlockData = data.subdata(in: offset..<(offset + blockLength))

                if let image = parseFLACPictureBlock(data: pictureBlockData) {
                    return image
                }
            }

            // Move to next block
            offset += blockLength

            if isLastBlock {
                break
            }
        }

        return nil
    }

    private nonisolated func parseFLACPictureBlock(data: Data) -> UIImage? {
        guard data.count >= 32 else { return nil }

        var offset = 0

        // Picture type (4 bytes) - skip
        offset += 4

        // MIME type length (4 bytes, big-endian)
        let mimeTypeLength = Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
        offset += 4

        guard offset + mimeTypeLength <= data.count else { return nil }

        // MIME type string - skip
        offset += mimeTypeLength

        // Description length (4 bytes, big-endian)
        guard offset + 4 <= data.count else { return nil }
        let descriptionLength = Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
        offset += 4

        // Description string - skip
        offset += descriptionLength

        // Width (4 bytes) - skip
        offset += 4
        // Height (4 bytes) - skip
        offset += 4
        // Color depth (4 bytes) - skip
        offset += 4
        // Number of colors (4 bytes) - skip
        offset += 4

        // Picture data length (4 bytes, big-endian)
        guard offset + 4 <= data.count else { return nil }
        let pictureDataLength = Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
        offset += 4

        // Picture data
        guard offset + pictureDataLength <= data.count else { return nil }
        let pictureData = data.subdata(in: offset..<(offset + pictureDataLength))

        // Create UIImage from picture data
        return UIImage(data: pictureData)
    }

    private func updateNowPlayingInfoWithCachedArtwork() {
        guard let track = currentTrack,
              let cachedArtwork = cachedArtwork,
              cachedArtworkTrackId == track.stableId else { return }

        // Get current now playing info and add artwork
        var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        nowPlayingInfo[MPMediaItemPropertyArtwork] = cachedArtwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    private nonisolated func convertUIImageToMPMediaItemArtwork(_ image: UIImage) -> MPMediaItemArtwork? {
        return makeMediaItemArtwork(from: image)
    }

    /// Uses MediaPlayer's image-backed initializer so MediaRemote never calls
    /// back into an app-owned Swift closure from its private artwork queue.
    private nonisolated func makeMediaItemArtwork(from image: UIImage) -> MPMediaItemArtwork {
        return MPMediaItemArtwork(image: image)
    }

    private nonisolated func loadArtworkFromSFBAudioEngine(url: URL) -> MPMediaItemArtwork? {
        do {
            // Try to use SFBAudioEngine to extract artwork
            let audioFile = try SFBAudioEngine.AudioFile(readingPropertiesAndMetadataFrom: url)
            let metadata = audioFile.metadata

            // SFBAudioEngine AudioMetadata doesn't expose raw artwork data directly
            // The current SFBAudioEngine API doesn't provide easy access to embedded artwork
            // We'll need to use the direct file parsing method instead
            print("🔍 SFBAudioEngine metadata available but artwork extraction not directly supported")
            print("🔍 Metadata - Title: \(metadata.title ?? "nil"), Artist: \(metadata.artist ?? "nil")")

            return nil
        } catch {
            print("⚠️ SFBAudioEngine artwork extraction failed: \(error)")
            return nil
        }
    }

    private nonisolated func loadArtworkFromDSDFile(url: URL) -> MPMediaItemArtwork? {
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let fileExtension = url.pathExtension.lowercased()

            // For DSF files, try ID3v2 APIC frame extraction first
            if fileExtension == "dsf" {
                if let image = extractDSFArtworkFromID3(data: data, filename: url.lastPathComponent) {
                    print("🎨 Extracted artwork from DSF ID3v2 APIC frame")
                    let processedImage = self.cropToSquareIfNeeded(image: image)
                    return self.makeMediaItemArtwork(from: processedImage)
                }
            }

            // Fallback to binary signature search for both DSF and DFF files
            print("⚠️ No ID3v2 artwork found, searching for binary signatures in: \(url.lastPathComponent)")

            // Image signatures to look for
            let jpegSignature = Data([0xFF, 0xD8, 0xFF])
            let pngSignature = Data([0x89, 0x50, 0x4E, 0x47])

            // Search for embedded images in DSD files
            let searchRange = 0..<min(data.count, 2097152) // Search first 2MB

            // Look for JPEG images
            if let jpegRange = data.range(of: jpegSignature, in: searchRange) {
                // Try to extract JPEG starting from found position
                let startOffset = jpegRange.lowerBound

                // Look for JPEG end marker (FF D9)
                let jpegEndSignature = Data([0xFF, 0xD9])
                if let endRange = data.range(of: jpegEndSignature, in: startOffset..<min(data.count, startOffset + 1048576)) {
                    let endOffset = endRange.upperBound
                    let imageData = data.subdata(in: startOffset..<endOffset)

                    if let image = UIImage(data: imageData) {
                        print("🎨 Extracted JPEG artwork from DSD file (binary search)")
                        let processedImage = self.cropToSquareIfNeeded(image: image)
                        return self.makeMediaItemArtwork(from: processedImage)
                    }
                }
            }

            // Look for PNG images
            if let pngRange = data.range(of: pngSignature, in: searchRange) {
                // Try to extract PNG starting from found position
                let startOffset = pngRange.lowerBound

                // PNG files end with IEND chunk (49 45 4E 44)
                let pngEndSignature = Data([0x49, 0x45, 0x4E, 0x44])
                if let endRange = data.range(of: pngEndSignature, in: startOffset..<min(data.count, startOffset + 1048576)) {
                    let endOffset = endRange.upperBound + 4 // Include CRC after IEND
                    let imageData = data.subdata(in: startOffset..<min(endOffset, data.count))

                    if let image = UIImage(data: imageData) {
                        print("🎨 Extracted PNG artwork from DSD file (binary search)")
                        let processedImage = self.cropToSquareIfNeeded(image: image)
                        return self.makeMediaItemArtwork(from: processedImage)
                    }
                }
            }

            return nil
        } catch {
            print("⚠️ Direct DSD artwork extraction failed: \(error)")
            return nil
        }
    }

    private nonisolated func cropToSquareIfNeeded(image: UIImage) -> UIImage {
        let width = image.size.width
        let height = image.size.height

        // If the image is already square or taller than wide, return as-is
        if width <= height {
            return image
        }

        // If width is more than 20% larger than height, crop to square
        let aspectRatio = width / height
        if aspectRatio > 1.2 {
            print("🖼️ Cropping wide artwork (aspect ratio: \(String(format: "%.2f", aspectRatio))) to square")

            // Calculate the square size (use height as the dimension)
            let squareSize = height

            // Calculate the crop rect (center the crop horizontally)
            let xOffset = (width - squareSize) / 2
            let cropRect = CGRect(x: xOffset, y: 0, width: squareSize, height: squareSize)

            // Perform the crop
            guard let cgImage = image.cgImage?.cropping(to: cropRect) else {
                print("⚠️ Failed to crop image, returning original")
                return image
            }

            return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
        }

        // Return original if aspect ratio is acceptable
        return image
    }

    private nonisolated func resizeImage(_ image: UIImage, to size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    // Extract artwork from DSF file using ID3v2 APIC frames
    private nonisolated func extractDSFArtworkFromID3(data: Data, filename: String) -> UIImage? {
        // Validate DSF signature: 'D', 'S', 'D', ' ' (includes 1 space)
        guard data.count >= 28,
              data[0] == 0x44, data[1] == 0x53, data[2] == 0x44, data[3] == 0x20 else {
            print("⚠️ Invalid DSF signature in: \(filename)")
            return nil
        }

        // Read metadata pointer from DSF header (little-endian at offset 20)
        let metadataPointer = readLittleEndianUInt64(from: data, offset: 20)

        guard metadataPointer > 0 && metadataPointer < data.count else {
            print("⚠️ No metadata pointer in DSF file: \(filename)")
            return nil
        }

        let metadataOffset = Int(metadataPointer)

        // Check for ID3v2 signature at metadata pointer
        guard data.count >= metadataOffset + 10,
              data[metadataOffset] == 0x49, // 'I'
              data[metadataOffset + 1] == 0x44, // 'D'
              data[metadataOffset + 2] == 0x33 else { // '3'
            print("⚠️ No ID3v2 tag found at metadata pointer in: \(filename)")
            return nil
        }

        print("🏷️ Found ID3v2 tag in DSF file: \(filename)")

        let id3Data = data.subdata(in: metadataOffset..<data.count)
        return extractArtworkFromID3v2(data: id3Data, filename: filename)
    }

    // Extract artwork from ID3v2 APIC frame
    private nonisolated func extractArtworkFromID3v2(data: Data, filename: String) -> UIImage? {
        guard data.count >= 10 else { return nil }

        // Read ID3v2 header
        let majorVersion = data[3]
        let tagSize = Int((UInt32(data[6]) << 21) | (UInt32(data[7]) << 14) | (UInt32(data[8]) << 7) | UInt32(data[9]))

        print("🏷️ Searching for APIC frame in ID3v2.\(majorVersion) tag, size: \(tagSize) bytes")

        // Parse frames to find APIC (attached picture)
        var offset = 10
        let endOffset = min(data.count, 10 + tagSize)

        while offset < endOffset - 10 {
            // Read frame header (10 bytes for v2.3/v2.4)
            let frameId = String(data: data.subdata(in: offset..<offset+4), encoding: .ascii) ?? ""

            let frameSize: Int
            if majorVersion >= 4 {
                // ID3v2.4 uses synchsafe integers for frame size
                frameSize = Int((UInt32(data[offset+4]) << 21) | (UInt32(data[offset+5]) << 14) | (UInt32(data[offset+6]) << 7) | UInt32(data[offset+7]))
            } else {
                // ID3v2.3 uses regular 32-bit big-endian integer
                frameSize = Int((UInt32(data[offset+4]) << 24) | (UInt32(data[offset+5]) << 16) | (UInt32(data[offset+6]) << 8) | UInt32(data[offset+7]))
            }

            // Move to frame data
            offset += 10

            guard frameSize > 0 && offset + frameSize <= endOffset else {
                break
            }

            if frameId == "APIC" {
                print("🎨 Found APIC frame in \(filename), size: \(frameSize) bytes")

                let frameData = data.subdata(in: offset..<offset+frameSize)

                // Parse APIC frame structure:
                // [Encoding] [MIME type] [Picture type] [Description] [Picture data]
                var frameOffset = 1 // Skip encoding byte

                // Skip MIME type (null-terminated string)
                while frameOffset < frameData.count && frameData[frameOffset] != 0 {
                    frameOffset += 1
                }
                frameOffset += 1 // Skip null terminator

                // Skip picture type (1 byte)
                frameOffset += 1

                // Skip description (null-terminated string, encoding-dependent)
                let encoding = frameData[0]
                if encoding == 1 || encoding == 2 { // UTF-16
                    // Look for double null bytes
                    while frameOffset < frameData.count - 1 && !(frameData[frameOffset] == 0 && frameData[frameOffset + 1] == 0) {
                        frameOffset += 1
                    }
                    frameOffset += 2 // Skip double null
                } else {
                    // Single byte encoding
                    while frameOffset < frameData.count && frameData[frameOffset] != 0 {
                        frameOffset += 1
                    }
                    frameOffset += 1 // Skip null terminator
                }

                // Extract image data
                guard frameOffset < frameData.count else {
                    print("⚠️ Invalid APIC frame structure in: \(filename)")
                    break
                }

                let imageData = frameData.subdata(in: frameOffset..<frameData.count)

                if let image = UIImage(data: imageData) {
                    print("✅ Successfully extracted artwork from ID3v2 APIC frame: \(filename)")
                    return image
                } else {
                    print("⚠️ Could not create UIImage from APIC data in: \(filename)")
                }
            }

            offset += frameSize
        }

        print("⚠️ No APIC frame found in ID3v2 tag: \(filename)")
        return nil
    }

    // Safe byte reading helper for DSF format (little-endian)
    private nonisolated func readLittleEndianUInt64(from data: Data, offset: Int) -> UInt64 {
        guard offset >= 0 && offset + 8 <= data.count else {
            print("⚠️ Invalid byte access in player: offset=\(offset), dataSize=\(data.count)")
            return 0
        }

        let byte0 = UInt64(data[offset])
        let byte1 = UInt64(data[offset + 1]) << 8
        let byte2 = UInt64(data[offset + 2]) << 16
        let byte3 = UInt64(data[offset + 3]) << 24
        let byte4 = UInt64(data[offset + 4]) << 32
        let byte5 = UInt64(data[offset + 5]) << 40
        let byte6 = UInt64(data[offset + 6]) << 48
        let byte7 = UInt64(data[offset + 7]) << 56

        return byte0 | byte1 | byte2 | byte3 | byte4 | byte5 | byte6 | byte7
    }


    // MARK: - State Persistence

    func setupBackgroundSessionForSiri() {
        // When Siri launches the app, it bypasses normal lifecycle events
        // This method manually sets up the background session that would normally
        // happen via handleWillResignActive() and handleDidEnterBackground()

        print("🎤 Setting up background session for Siri-initiated playback")

        // Check app state to confirm we're in background
        let appState = UIApplication.shared.applicationState
        print("🎤 App state: \(appState == .background ? "background" : appState == .inactive ? "inactive" : "active")")

        // Mark that we've set up Siri background session
        hasSetupSiriBackgroundSession = true

        // Set up audio session for background (same as handleWillResignActive)
        // But don't re-grab if interrupted by alarm/call
        guard !isAudioSessionInterrupted else {
            print("🎧 Audio session interrupted (alarm/call) - skipping Siri background session keepalive")
            return
        }
        do {
            // Don't call setCategory here - changing category/options on a live
            // session forces a hardware reconfiguration that stops playback
            try AVAudioSession.sharedInstance().setActive(true, options: [])
            print("🎧 Session keepalive on resign active - success")
        } catch {
            print("❌ Session keepalive on resign active failed: \(error)")
        }

        // Background diagnostic and state saving (same as handleDidEnterBackground)
        let backgroundTime = UIApplication.shared.backgroundTimeRemaining
        print("🔍 DIAGNOSTIC - backgroundTimeRemaining: \(backgroundTime)")

        // Stop all UI timers since we're in background
        suspendUITimersForBackground()

        // Save player state
        savePlayerState()
    }

    func savePlayerState() {
        guard let currentTrack = currentTrack else {
            print("🚫 No current track to save state for")
            return
        }

        let playbackQueueTrackIds = playbackQueue.map { $0.stableId }
        let (cappedQueueTrackIds, cappedCurrentIndex) = cappedTrackIdsForPersistence(
            playbackQueueTrackIds,
            currentIndex: currentIndex
        )
        let originalQueueCurrentIndex = originalQueue.firstIndex(of: currentTrack.stableId) ?? 0
        let (cappedOriginalQueueTrackIds, _) = cappedTrackIdsForPersistence(
            originalQueue,
            currentIndex: originalQueueCurrentIndex
        )

        let playerState: [String: Any] = [
            "currentTrackStableId": currentTrack.stableId,
            "playbackTime": playbackTime,
            "isPlaying": false, // Always save as paused to prevent auto-play on launch
            "queueTrackIds": cappedQueueTrackIds,
            "currentIndex": cappedCurrentIndex,
            "isRepeating": isRepeating,
            "isShuffled": isShuffled,
            "isLoopingSong": isLoopingSong,
            "originalQueueTrackIds": cappedOriginalQueueTrackIds,
            "lastSavedAt": Date()
        ]

        UserDefaults.standard.set(playerState, forKey: "CosmosPlayerState")
        UserDefaults.standard.synchronize()
        print("✅ Player state saved to UserDefaults (offline, per-device)")
    }

    private func cappedTrackIdsForPersistence(_ trackIds: [String], currentIndex: Int) -> ([String], Int) {
        guard !trackIds.isEmpty else { return ([], 0) }
        guard trackIds.count > maxPersistedQueueSize else {
            let safeIndex = max(0, min(currentIndex, trackIds.count - 1))
            return (trackIds, safeIndex)
        }

        let halfWindow = maxPersistedQueueSize / 2
        var start = max(0, currentIndex - halfWindow)
        var end = min(trackIds.count, start + maxPersistedQueueSize)
        start = max(0, end - maxPersistedQueueSize)

        let cappedTrackIds = Array(trackIds[start..<end])
        let adjustedIndex = max(0, min(currentIndex - start, cappedTrackIds.count - 1))
        return (cappedTrackIds, adjustedIndex)
    }

    private func ensurePlayerStateRestored() async {
        guard !hasRestoredState else { return }
        hasRestoredState = true

        // Only load the audio file if we have a current track from UI restoration
        if let currentTrack = currentTrack {
            print("🔄 Loading audio for restored track: \(currentTrack.title)")
            let savedPosition = playbackTime // Save the position before loadTrack
            await loadTrack(currentTrack, preservePlaybackTime: true)

            // Restore the playback position after loading (if position was saved)
            if savedPosition > 0 {
                print("🔄 Seeking to restored position: \(savedPosition)s")
                await seek(to: savedPosition)
                print("✅ Restored position: \(savedPosition)s")
            }
        }
    }

    func restoreUIStateOnly() async {
        guard let playerStateDict = UserDefaults.standard.dictionary(forKey: "CosmosPlayerState") else {
            print("📭 No saved player state found in UserDefaults")
            return
        }

        guard let lastSavedAt = playerStateDict["lastSavedAt"] as? Date else {
            print("🚫 Invalid saved state format")
            return
        }

        print("🔄 Restoring UI state only from \(lastSavedAt)")

        // Don't restore if the saved state is too old (more than 7 days)
        let daysSinceLastSave = Date().timeIntervalSince(lastSavedAt) / (24 * 60 * 60)
        if daysSinceLastSave > 7 {
            print("⏰ Saved state is too old (\(Int(daysSinceLastSave)) days), skipping restore")
            return
        }

        // Find the current track by stable ID
        guard let currentTrackStableId = playerStateDict["currentTrackStableId"] as? String else {
            print("🚫 No current track in saved state")
            return
        }

        do {
            let track = try DatabaseManager.shared.read { db in
                try Track.filter(Column("stable_id") == currentTrackStableId).fetchOne(db)
            }

            guard let restoredTrack = track else {
                print("🚫 Could not find saved track with ID: \(currentTrackStableId)")
                return
            }

            // Restore queue by finding tracks with stable IDs
            let queueTrackIds = playerStateDict["queueTrackIds"] as? [String] ?? []
            let originalQueueTrackIds = playerStateDict["originalQueueTrackIds"] as? [String] ?? []

            let queueTracks = try DatabaseManager.shared.getTracksByStableIdsPreservingOrder(queueTrackIds)
            let originalQueueTracks = try DatabaseManager.shared.getTracksByStableIdsPreservingOrder(originalQueueTrackIds)

            // Restore UI state only - no audio loading
            await MainActor.run {
                self.playbackQueue = queueTracks.isEmpty ? [restoredTrack] : queueTracks
                self.originalQueue = originalQueueTracks.isEmpty ? [restoredTrack.stableId] : originalQueueTracks.map { $0.stableId }

                let savedIndex = playerStateDict["currentIndex"] as? Int ?? 0
                self.currentIndex = max(0, min(savedIndex, self.playbackQueue.count - 1))

                self.isRepeating = playerStateDict["isRepeating"] as? Bool ?? false
                self.isShuffled = playerStateDict["isShuffled"] as? Bool ?? false
                self.isLoopingSong = playerStateDict["isLoopingSong"] as? Bool ?? false
                self.currentTrack = restoredTrack

                // Validate restored state consistency
                if self.isLoopingSong && self.playbackQueue.count == 1 {
                    print("✅ Loop song mode validated with single track queue")
                } else if self.isLoopingSong {
                    print("⚠️ Loop song mode with multi-track queue - this is fine")
                }

                // Additional validation for shuffle state
                if !self.isShuffled {
                    // When not shuffled, ensure currentIndex points to the actual currentTrack
                    if let currentTrack = self.currentTrack,
                       self.currentIndex < self.playbackQueue.count,
                       self.playbackQueue[self.currentIndex].stableId != currentTrack.stableId {
                        // Find the correct index for the current track
                        if let correctIndex = self.playbackQueue.firstIndex(where: { $0.stableId == currentTrack.stableId }) {
                            print("⚠️ Fixed currentIndex from \(self.currentIndex) to \(correctIndex) for non-shuffled queue")
                            self.currentIndex = correctIndex
                        } else {
                            print("⚠️ Current track not found in queue, resetting to index 0")
                            self.currentIndex = 0
                        }
                    }
                }

                // Set saved position for UI display
                let savedTime = playerStateDict["playbackTime"] as? TimeInterval ?? 0
                self.playbackTime = savedTime

                // Set duration from track metadata for UI display
                if let durationMs = restoredTrack.durationMs {
                    self.duration = Double(durationMs) / 1000.0 // Convert ms to seconds
                } else {
                    self.duration = 0
                }

                // Set playback state to stopped so it doesn't show as playing
                self.playbackState = .stopped
                self.isPlaying = false

                print("✅ UI state restored - track: \(restoredTrack.title), position: \(savedTime)s, duration: \(self.duration)s (no audio loaded)")

                // Normalize index and track after restoration
                self.normalizeIndexAndTrack()
            }

        } catch {
            print("❌ Failed to restore UI state: \(error)")
        }
    }

    func restorePlayerState() async {
        guard let playerStateDict = UserDefaults.standard.dictionary(forKey: "CosmosPlayerState") else {
            print("📭 No saved player state found in UserDefaults")
            return
        }

        guard let lastSavedAt = playerStateDict["lastSavedAt"] as? Date else {
            print("🚫 Invalid saved state format")
            return
        }

        print("🔄 Restoring player state from \(lastSavedAt)")

        // Don't restore if the saved state is too old (more than 7 days)
        let daysSinceLastSave = Date().timeIntervalSince(lastSavedAt) / (24 * 60 * 60)
        if daysSinceLastSave > 7 {
            print("⏰ Saved state is too old (\(Int(daysSinceLastSave)) days), skipping restore")
            return
        }

        // Find the current track by stable ID
        guard let currentTrackStableId = playerStateDict["currentTrackStableId"] as? String else {
            print("🚫 No current track in saved state")
            return
        }

        do {
            let track = try DatabaseManager.shared.read { db in
                try Track.filter(Column("stable_id") == currentTrackStableId).fetchOne(db)
            }

            guard let restoredTrack = track else {
                print("🚫 Could not find saved track with ID: \(currentTrackStableId)")
                return
            }

            // Restore queue by finding tracks with stable IDs
            let queueTrackIds = playerStateDict["queueTrackIds"] as? [String] ?? []
            let originalQueueTrackIds = playerStateDict["originalQueueTrackIds"] as? [String] ?? []

            let queueTracks = try DatabaseManager.shared.getTracksByStableIdsPreservingOrder(queueTrackIds)
            let originalQueueTracks = try DatabaseManager.shared.getTracksByStableIdsPreservingOrder(originalQueueTrackIds)

            // Restore player state
            await MainActor.run {
                self.playbackQueue = queueTracks.isEmpty ? [restoredTrack] : queueTracks
                self.originalQueue = originalQueueTracks.isEmpty ? [restoredTrack.stableId] : originalQueueTracks.map { $0.stableId }

                let savedIndex = playerStateDict["currentIndex"] as? Int ?? 0
                self.currentIndex = max(0, min(savedIndex, self.playbackQueue.count - 1))

                self.isRepeating = playerStateDict["isRepeating"] as? Bool ?? false
                self.isShuffled = playerStateDict["isShuffled"] as? Bool ?? false
                self.isLoopingSong = playerStateDict["isLoopingSong"] as? Bool ?? false
                self.currentTrack = restoredTrack

                print("✅ Restored state: queue=\(self.playbackQueue.count) tracks, index=\(self.currentIndex), loop=\(self.isLoopingSong)")

                // Additional validation for shuffle state
                if !self.isShuffled {
                    // When not shuffled, ensure currentIndex points to the actual currentTrack
                    if let currentTrack = self.currentTrack,
                       self.currentIndex < self.playbackQueue.count,
                       self.playbackQueue[self.currentIndex].stableId != currentTrack.stableId {
                        // Find the correct index for the current track
                        if let correctIndex = self.playbackQueue.firstIndex(where: { $0.stableId == currentTrack.stableId }) {
                            print("⚠️ Fixed currentIndex from \(self.currentIndex) to \(correctIndex) for non-shuffled queue")
                            self.currentIndex = correctIndex
                        } else {
                            print("⚠️ Current track not found in queue, resetting to index 0")
                            self.currentIndex = 0
                        }
                    }
                }
            }

            await MainActor.run { self.normalizeIndexAndTrack() }

            await MainActor.run {
                // Set saved position before loading track
                let savedTime = playerStateDict["playbackTime"] as? TimeInterval ?? 0
                self.playbackTime = savedTime
            }

            // Load the track and preserve the saved position
            await loadTrack(restoredTrack, preservePlaybackTime: true)

            // Seek to the saved position after loading
            let savedTime = playerStateDict["playbackTime"] as? TimeInterval ?? 0
            if savedTime > 0 {
                await seek(to: savedTime)
                print("🔄 Seeked to restored position: \(savedTime)s")
            }

            print("✅ Player state restored from UserDefaults - track: \(restoredTrack.title), position: \(savedTime)s")

        } catch {
            print("❌ Failed to restore player state: \(error)")
        }
    }

    private func setupPeriodicStateSaving() {
        // Save state every 30 seconds while playing, and on important events
        Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                if self?.isPlaying == true && self?.currentTrack != nil {
                    self?.savePlayerState()
                }
            }
        }
    }

    deinit {
        // Note: Cannot access main actor properties or methods in deinit
        // State saving is handled by app lifecycle notifications instead

        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
enum PlayerError: Error {
    case fileNotFound
    case invalidAudioFile
    case audioEngineError
    case configurationError
}
