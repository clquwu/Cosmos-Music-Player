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

@MainActor
class PlayerEngine: NSObject, ObservableObject {
    static let shared = PlayerEngine()
    
    @Published var currentTrack: Track?
    @Published var isPlaying = false
    @Published var playbackTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var playbackState: PlaybackState = .stopped
    @Published var playbackQueue: [Track] = []
    @Published var currentIndex = 0
    @Published var isRepeating = false
    @Published var isShuffled = false
    @Published var isLoopingSong = false
    
    private var originalQueue: [Track] = []
    
    // Generation token to prevent stale completion handlers from firing
    private var scheduleGeneration: UInt64 = 0
    
    private var seekTimeOffset: TimeInterval = 0
    
    private lazy var audioEngine = AVAudioEngine()
    private lazy var playerNode = AVAudioPlayerNode()
    private var audioFile: AVAudioFile?
    private var playbackTimer: Timer?
    
    private var isLoadingTrack = false
    private var currentLoadTask: Task<Void, Error>?
    private var hasRestoredState = false
    private var hasSetupAudioEngine = false
    private var hasSetupAudioSession = false
    private var hasSetupRemoteCommands = false
    private nonisolated(unsafe) var hasSetupAudioSessionNotifications = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var backgroundCheckTimer: Timer?
    
    // Artwork caching
    private var cachedArtwork: MPMediaItemArtwork?
    private var cachedArtworkTrackId: String?
    
    private let databaseManager = DatabaseManager.shared
    private let cloudDownloadManager = CloudDownloadManager.shared
    
    // System volume integration
    private var silentPlayer: AVAudioPlayer?
    private nonisolated(unsafe) var volumeCheckTimer: Timer?
    private var lastKnownVolume: Float = -1
    private var isUserChangingVolume = false
    private var lastVolumeChangeTime: Date = Date()
    private var rapidChangeDetected = false

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
        // Don't set up volume control immediately - wait until we actually need it
        // setupBasicVolumeControl()
        setupPeriodicStateSaving()
    }
    
    private func ensureAudioEngineSetup() {
        guard !hasSetupAudioEngine else { return }
        hasSetupAudioEngine = true
        setupAudioEngine()
    }
    
    private func setupAudioEngine() {
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: nil)
        audioEngine.connect(audioEngine.mainMixerNode,
                            to: audioEngine.outputNode,
                            format: audioEngine.mainMixerNode.outputFormat(forBus: 0))
        
        // CRITICAL: Prepare the engine to guarantee render loop activity
        audioEngine.prepare()
        
        // Don't start the engine here - wait until we actually need to play
        print("✅ Audio engine configured and prepared with explicit output connection")
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
        // Handle audio session interruptions (calls, other apps, etc.)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        
        // Handle route changes (headphones disconnected, etc.)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        
        // CRITICAL for iOS 18: Listen for media services reset
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMediaServicesReset),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: nil
        )
        
        // Listen for memory pressure warnings
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }
    
    @objc private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        switch type {
        case .began:
            print("🚫 Audio session interruption began - pausing playback")
            if isPlaying {
                pause()
            }
            // Stop audio engine during interruption
            audioEngine.stop()
        case .ended:
            print("✅ Audio session interruption ended - restarting audio engine")
            // Restart audio engine after interruption
            do {
                try audioEngine.start()
                print("✅ Audio engine restarted after interruption")
            } catch {
                print("❌ Failed to restart audio engine: \(error)")
            }
            // Don't auto-resume - let user decide when to resume
        @unknown default:
            break
        }
    }
    
    @objc private func handleAudioSessionRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }
        
        switch reason {
        case .oldDeviceUnavailable:
            // Headphones were unplugged or similar
            print("🎧 Audio device disconnected - pausing playback")
            if isPlaying {
                pause()
            }
        default:
            break
        }
    }
    
    @objc private func handleMediaServicesReset(_ notification: Notification) {
        print("🔄 Media services were reset - need to recreate audio engine and nodes")
        
        Task { @MainActor in
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
    }
    
    @objc private func handleMemoryWarning(_ notification: Notification) {
        print("⚠️ Memory warning received - cleaning up audio resources")
        
        Task { @MainActor in
            // Clear cached artwork to free memory
            cachedArtwork = nil
            cachedArtworkTrackId = nil
            
            // If not currently playing, stop audio engine to free resources
            if !isPlaying {
                audioEngine.stop()
                print("🛑 Stopped audio engine due to memory pressure")
            }
            
            // Force garbage collection of any retained buffers
            playerNode.stop()
            
            print("🧹 Cleaned up audio resources due to memory warning")
        }
    }
    
    private func setupBasicVolumeControl() {
        print("🎛️ Setting up basic volume control...")
        
        // Delay the initial sync slightly to ensure audio session is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.syncWithSystemVolume()
        }
        
        // Start monitoring system volume changes
        startVolumeTimer()
        
        print("✅ Basic volume control enabled")
    }
    
    private func setupSilentPlayer() {
        // Create a silent audio file to play (required for accurate volume monitoring)
        guard let silenceURL = Bundle.main.url(forResource: "silence", withExtension: "mp3") else {
            // If no silence file, create one programmatically
            createSilenceFile()
            return
        }
        
        do {
            silentPlayer = try AVAudioPlayer(contentsOf: silenceURL)
            silentPlayer?.volume = 0.0
            silentPlayer?.numberOfLoops = -1  // Loop indefinitely
            silentPlayer?.prepareToPlay()
            print("🔇 Silent player created for volume monitoring")
        } catch {
            print("❌ Failed to create silent player: \(error)")
            createSilenceFile()
        }
    }
    
    private func createSilenceFile() {
        // Generate a tiny bit of silence programmatically
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buffer.frameLength = 1024
        
        // Buffer is already silent (zero-filled by default)
        
        do {
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("silence.caf")
            let audioFile = try AVAudioFile(forWriting: tempURL, settings: format.settings)
            try audioFile.write(from: buffer)
            
            silentPlayer = try AVAudioPlayer(contentsOf: tempURL)
            silentPlayer?.volume = 0.01  // Very low but not zero
            silentPlayer?.numberOfLoops = -1
            silentPlayer?.prepareToPlay()
            print("🔇 Generated silent player for volume monitoring")
        } catch {
            print("❌ Failed to create programmatic silence: \(error)")
        }
    }
    
    private func syncWithSystemVolume() {
        // Only sync if audio session has been set up
        guard hasSetupAudioSession else {
            print("🔊 Deferring volume sync until audio session is set up")
            return
        }
        
        let systemVolume = AVAudioSession.sharedInstance().outputVolume
        print("🔊 Syncing with system volume: \(Int(systemVolume * 100))%")
        updateAudioEngineVolume(to: systemVolume)
        
        // Set the baseline for timer-based monitoring
        lastKnownVolume = systemVolume
        
        // Don't start silent playback here - only when we actually need volume monitoring during playback
        // silentPlayer?.play() - removed to prevent interrupting other apps on launch
    }
    
    // Removed MPVolumeView methods - using native system volume HUD instead
    
    private func setupVolumeMonitoring() {
        // Monitor system volume notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleVolumeNotification),
            name: NSNotification.Name("AVSystemController_SystemVolumeDidChangeNotification"),
            object: nil
        )
        
        // Also monitor AVAudioSession outputVolume
        let session = AVAudioSession.sharedInstance()
        session.addObserver(self, forKeyPath: "outputVolume", options: [.new], context: nil)
        
        // Start timer-based volume checking as fallback
        startVolumeTimer()
        
        print("📢 Volume monitoring enabled with timer fallback")
    }
    
    private func startVolumeTimer() {
        volumeCheckTimer?.invalidate()
        volumeCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkVolumeChange()
            }
        }
        print("⏰ Volume check timer started (200ms intervals)")
    }
    
    private func checkVolumeChange() {
        // Only check volume if audio session has been set up
        guard hasSetupAudioSession else { return }
        
        let currentVolume = AVAudioSession.sharedInstance().outputVolume
        
        if lastKnownVolume != currentVolume {
            if lastKnownVolume >= 0 {
                // Simply sync audio engine to system volume
                audioEngine.mainMixerNode.outputVolume = currentVolume
            }
            lastKnownVolume = currentVolume
        }
    }
    
    @objc private func handleVolumeNotification(_ notification: Notification) {
        print("📢 Received volume notification: \(notification.name)")
        print("📢 Notification userInfo: \(notification.userInfo ?? [:])")
        
        if let volume = notification.userInfo?["AVSystemController_AudioVolumeNotificationParameter"] as? Float {
            print("🔊 Volume notification: \(Int(volume * 100))%")
            updateAudioEngineVolume(to: volume)
        } else {
            print("⚠️ No volume parameter in notification")
        }
    }
    
    nonisolated override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        print("📢 KVO observer called for keyPath: \(keyPath ?? "nil")")
        print("📢 Change: \(change ?? [:])")
        
        if keyPath == "outputVolume" {
            if let volume = change?[.newKey] as? Float {
                print("🔊 AVAudioSession volume changed: \(Int(volume * 100))%")
                Task { @MainActor in
                    updateAudioEngineVolume(to: volume)
                }
            } else {
                print("⚠️ No volume value in KVO change")
            }
        }
    }
    
    private func updateAudioEngineVolume(to volume: Float) {
        audioEngine.mainMixerNode.outputVolume = volume
        print("🔊 Audio engine volume updated to: \(Int(volume * 100))%")
    }
    
    private func ensureRemoteCommandsSetup() {
        guard !hasSetupRemoteCommands else { return }
        hasSetupRemoteCommands = true
        setupRemoteCommands()
    }
    
    private func setupRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()
        
        cc.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        
        cc.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
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
            Task { @MainActor in await self.seek(to: e.positionTime) }
            return .success
        }
        
        // Enable all commands initially
        cc.playCommand.isEnabled = true
        cc.pauseCommand.isEnabled = true
        cc.nextTrackCommand.isEnabled = true
        cc.previousTrackCommand.isEnabled = true
        cc.changePlaybackPositionCommand.isEnabled = true
    }
    
    // MARK: - Audio Session Management
    
    private func setupAudioSessionCategory() throws {
        let s = AVAudioSession.sharedInstance()
        
        // For background audio, avoid mixWithOthers - be the primary audio app
        let options: AVAudioSession.CategoryOptions = [.allowAirPlay, .allowBluetooth, .allowBluetoothA2DP]
        
        try s.setCategory(.playback, mode: .default, options: options)
        
        // iOS 18 Fix: Set preferred I/O buffer duration
        try s.setPreferredIOBufferDuration(0.023) // 23ms buffer - good balance for iOS 18
        
        print("🎧 Audio session category configured for primary playback (no mixWithOthers)")
    }
    
    private func activateAudioSession() throws {
        let s = AVAudioSession.sharedInstance()
        
        print("🎧 Audio session state - Category: \(s.category), Other audio: \(s.isOtherAudioPlaying)")
        
        // Set category first if needed
        try setupAudioSessionCategory()
        
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
        
        // Create fresh instances
        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        
        // Set up the graph again
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: nil)
        
        // Reset flags
        hasSetupAudioEngine = false
        hasSetupAudioSession = false
        hasSetupRemoteCommands = false
        hasSetupAudioSessionNotifications = false
        
        print("✅ Audio engine recreated successfully")
    }
    
    
    
    // MARK: - Playback Control
    
    func loadTrack(_ track: Track, preservePlaybackTime: Bool = false) async {
        print("📀 loadTrack called for: \(track.title) (format: \(track.path.hasSuffix(".mp3") ? "MP3" : "FLAC"))")
        
        // Cancel any ongoing load operation
        currentLoadTask?.cancel()
        
        // Prevent concurrent loading
        guard !isLoadingTrack else {
            print("⚠️ Already loading track, skipping: \(track.title)")
            return
        }
        
        isLoadingTrack = true
        print("🔄 Starting load process for: \(track.title)")
        
        // Stop current playback and clean up
        await cleanupCurrentPlayback(resetTime: !preservePlaybackTime)
        
        // Clear cached artwork when loading new track
        cachedArtwork = nil
        cachedArtworkTrackId = nil
        
        
        currentTrack = track
        playbackState = .loading
        
        // Volume control already set up in init
        
        do {
            let url = URL(fileURLWithPath: track.path)
            
            try await cloudDownloadManager.ensureLocal(url)
            
            // Remove file protection to prevent background stalls
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.none],
                                                   ofItemAtPath: url.path)
            
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw PlayerError.fileNotFound
            }
            
            // Use NSFileCoordinator for iCloud files (same pattern as metadata parsing)
            audioFile = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .background).async {
                    var error: NSError?
                    let coordinator = NSFileCoordinator()
                    
                    coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &error) { (readingURL) in
                        do {
                            // Create fresh URL to avoid stale metadata
                            let freshURL = URL(fileURLWithPath: readingURL.path)
                            print("🎵 Loading audio file via NSFileCoordinator: \(freshURL.lastPathComponent)")
                            
                            // Check if file actually exists at path
                            guard FileManager.default.fileExists(atPath: freshURL.path) else {
                                continuation.resume(throwing: PlayerError.fileNotFound)
                                return
                            }
                            
                            let audioFile = try AVAudioFile(forReading: freshURL)
                            print("✅ AVAudioFile loaded successfully for playback: \(freshURL.lastPathComponent)")
                            continuation.resume(returning: audioFile)
                        } catch {
                            print("❌ Failed to load AVAudioFile via NSFileCoordinator: \(error)")
                            continuation.resume(throwing: error)
                        }
                    }
                    
                    if let error = error {
                        print("❌ NSFileCoordinator error in PlayerEngine: \(error)")
                        continuation.resume(throwing: error)
                    }
                }
            }
            
            guard let audioFile = audioFile else {
                throw PlayerError.invalidAudioFile
            }
            
            duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
            if !preservePlaybackTime {
                playbackTime = 0
            }
            
            await configureAudioSession(for: audioFile.processingFormat)
            
            updateNowPlayingInfo()
            
            playbackState = .stopped
            isLoadingTrack = false
            
        } catch {
            print("Failed to load track: \(error)")
            playbackState = .stopped
            isLoadingTrack = false
            audioFile = nil
        }
    }
    
    func play() {
        print("▶️ play() called - state: \(playbackState), loading: \(isLoadingTrack), audioFile: \(audioFile != nil)")
        
        // If no audio file is loaded but we have a current track, load it first
        if audioFile == nil && currentTrack != nil && !isLoadingTrack {
            Task {
                await ensurePlayerStateRestored()
                // After loading, try to play again
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
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
        
        // Set up audio engine only when needed (FIRST)
        ensureAudioEngineSetup()
        
        
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
            // Check if audio is scheduled - if not, we need to schedule it (happens after paused skip)
            if !playerNode.isPlaying && playbackTime == 0 {
                print("🔄 Paused after skip - need to schedule audio before playing")
                // Fall through to the main scheduling logic below
            } else {
                // Normal resume from pause
                // Ensure audio engine is running when resuming from pause
                if !audioEngine.isRunning {
                    do {
                        try audioEngine.start()
                        print("✅ Audio engine started when resuming from pause")
                    } catch {
                        print("❌ Failed to start audio engine when resuming: \(error)")
                        return
                    }
                }
                
                playerNode.play()
                isPlaying = true
                playbackState = .playing
                startPlaybackTimer()
                startBackgroundMonitoring()
                
                updateNowPlayingInfo()
                return
            }
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
        
        // Preserve current seek offset and playback time when resuming
        let currentPosition = playbackTime
        let startFrame = AVAudioFramePosition(currentPosition * audioFile.processingFormat.sampleRate)
        
        // Schedule appropriate segment based on current position
        if startFrame > 0 && startFrame < audioFile.length {
            // Continue from current position
            seekTimeOffset = currentPosition
            scheduleSegment(from: startFrame, file: audioFile)
            print("✅ Resuming playback from \(currentPosition)s (frame: \(startFrame))")
        } else {
            // Start from beginning - but only reset if we're actually at the beginning
            if playbackTime > 1.0 {
                // We're not actually at the beginning, so preserve current position
                let startFrame2 = AVAudioFramePosition(playbackTime * audioFile.processingFormat.sampleRate)
                seekTimeOffset = playbackTime
                scheduleSegment(from: startFrame2, file: audioFile)
                print("✅ Resuming playback from current position: \(playbackTime)s")
            } else {
                // Actually starting from beginning
                seekTimeOffset = 0
                playbackTime = 0
                scheduleSegment(from: 0, file: audioFile)
                print("✅ Starting playback from beginning")
            }
        }
        
        print("✅ Audio segment scheduled successfully")
        
        // Ensure audio engine is running before playing
        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
                print("✅ Audio engine started before playback")
            } catch {
                print("❌ Failed to start audio engine: \(error)")
                return
            }
        }
        
        // Set up audio session notifications only when needed
        ensureAudioSessionNotificationsSetup()
        
        // Set up remote commands only when needed
        ensureRemoteCommandsSetup()
        
        // Set up volume control if not already done
        if volumeCheckTimer == nil {
            setupBasicVolumeControl()
        }
        
        // Session is already activated before engine start
        
        playerNode.play()
        isPlaying = true
        playbackState = .playing
        startPlaybackTimer()
        
        // Audio session lifecycle now handles background execution
        
        // Update Now Playing info AFTER setting playing state to show correct state
        updateNowPlayingInfo()
        
        print("✅ Playback started and control center claimed")
    }
    
    func pause() {
        playerNode.pause()
        isPlaying = false
        playbackState = .paused
        stopPlaybackTimer()
        endBackgroundMonitoring()
        // Keep audio session active during pause for background audio continuation
        // Do NOT deactivate the audio session here - that would allow the system to kill the app
        // Keep audio engine running to maintain background audio eligibility
        
        // Keep audio session active and audio engine running for background continuation
        print("🔄 Keeping audio session and engine active during pause for background audio")
        
        // Update Now Playing info when paused
        updateNowPlayingInfo()
        
        // Save state when pausing
        savePlayerState()
    }
    
    @inline(__always)
    private func cancelPendingCompletions() {
        scheduleGeneration &+= 1
    }
    
    func stop() {
        cancelPendingCompletions()
        playerNode.stop()
        isPlaying = false
        playbackState = .stopped
        playbackTime = 0
        stopPlaybackTimer()
        endBackgroundMonitoring()
        
        // Audio session deactivation will handle background execution cleanup
        
        // Clear Now Playing info when stopped
        updateNowPlayingInfo()
        
        
        // Clear remote command targets to remove from control center
        if hasSetupRemoteCommands {
            let commandCenter = MPRemoteCommandCenter.shared()
            commandCenter.playCommand.removeTarget(nil)
            commandCenter.pauseCommand.removeTarget(nil)
            commandCenter.nextTrackCommand.removeTarget(nil)
            commandCenter.previousTrackCommand.removeTarget(nil)
            commandCenter.changePlaybackPositionCommand.removeTarget(nil)
            hasSetupRemoteCommands = false
            print("🎛️ Remote commands cleared from control center")
        }
        
        // Deactivate audio session to allow other apps to play
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            print("🎧 Audio session deactivated - allowing other apps to play")
        } catch {
            print("Failed to deactivate audio session: \(error)")
        }
        
        // Save state when stopping
        savePlayerState()
    }
    
    private func cleanupCurrentPlayback(resetTime: Bool = false) async {
        print("🧹 Cleaning up current playback")
        
        // Stop timer first
        stopPlaybackTimer()
        
        // Stop player node
        playerNode.stop()
        
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
        
        // Ensure audio engine is set up before seeking
        ensureAudioEngineSetup()
        
        cancelPendingCompletions()
        playerNode.stop()
        
        scheduleSegment(from: framePosition, file: audioFile)
        
        // Update seek offset and playback time
        seekTimeOffset = time
        playbackTime = time
        
        if wasPlaying {
            playerNode.play()
            isPlaying = true
            playbackState = .playing
            startPlaybackTimer()
        }
        
        print("✅ Seek completed")
    }
    
    // MARK: - Audio Scheduling Helper
    
    private func scheduleSegment(from startFrame: AVAudioFramePosition, file: AVAudioFile) {
        let remaining = file.length - startFrame
        guard remaining > 0 else { return }
        
        // Schedule WITHOUT any completion handler
        playerNode.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: AVAudioFrameCount(remaining),
            at: nil,
            completionHandler: nil
        )
        
        // Start background monitoring when we schedule a segment
        startBackgroundMonitoring()
    }
    
    private func startBackgroundMonitoring() {
        // Begin a background task to keep the app alive
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackgroundMonitoring()
        }
        
        // Start a timer that works in background
        backgroundCheckTimer?.invalidate()
        backgroundCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkIfTrackEnded()
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
    
    @MainActor
    private func checkIfTrackEnded() {
        // Check if audio has finished playing
        guard isPlaying else { return }
        
        // Check if player node has stopped naturally (reached end)
        if !playerNode.isPlaying && audioFile != nil {
            // Track has ended
            Task { @MainActor in
                await handleTrackEnd()
            }
        }
        
        // Alternative check: position-based
        if let audioFile = audioFile {
            if let nodeTime = playerNode.lastRenderTime,
               let playerTime = playerNode.playerTime(forNodeTime: nodeTime) {
                let nodePlaybackTime = Double(playerTime.sampleTime) / audioFile.processingFormat.sampleRate
                let currentTime = seekTimeOffset + nodePlaybackTime
                
                if currentTime >= duration - 0.2 && duration > 0 {
                    // Track is ending
                    isPlaying = false // Prevent multiple triggers
                    Task { @MainActor in
                        await handleTrackEnd()
                    }
                }
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
        
        // Save original queue for shuffle functionality
        originalQueue = playbackQueue
        
        normalizeIndexAndTrack()
        
        await loadTrack(track)
        
        // Auto-play immediately after loading completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.play()
        }
    }
    
    func nextTrack(autoplay: Bool? = nil) async {
        guard !playbackQueue.isEmpty, !isLoadingTrack else { return }
        normalizeIndexAndTrack()
        let shouldAutoplay = autoplay ?? isPlaying
        
        currentIndex = (currentIndex + 1) % playbackQueue.count
        let next = playbackQueue[currentIndex]
        await loadTrack(next, preservePlaybackTime: false)
        
        if shouldAutoplay {
            DispatchQueue.main.async { [weak self] in
                self?.play()
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
                self.updateNowPlayingInfo()
            }
        }
    }
    
    func previousTrack(autoplay: Bool? = nil) async {
        guard !playbackQueue.isEmpty, !isLoadingTrack else { return }
        normalizeIndexAndTrack()
        
        let wasPlaying = autoplay ?? isPlaying
        
        if playbackTime > 3.0 {
            await seek(to: 0)
            if !wasPlaying {
                await MainActor.run {
                    isPlaying = false
                    playbackState = .paused
                    updateNowPlayingInfo()
                }
            }
            return
        }
        
        currentIndex = currentIndex > 0 ? currentIndex - 1 : playbackQueue.count - 1
        let prev = playbackQueue[currentIndex]
        await loadTrack(prev, preservePlaybackTime: false)
        
        if wasPlaying {
            await MainActor.run {
                play()
            }
        } else {
            await MainActor.run {
                cancelPendingCompletions()
                playerNode.stop()
                isPlaying = false
                playbackState = .paused
                seekTimeOffset = 0
                playbackTime = 0
                updateNowPlayingInfo()
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
            originalQueue = playbackQueue
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
        
        // Find current track in original queue
        if let currentTrack = self.currentTrack,
           let originalIndex = originalQueue.firstIndex(where: { $0.stableId == currentTrack.stableId }) {
            playbackQueue = originalQueue
            currentIndex = originalIndex
            print("🔀 Original queue restored, current track at index \(originalIndex)")
        }
        
        normalizeIndexAndTrack()
    }
    
    // MARK: - Audio Session Configuration
    
    private func configureAudioSession(for format: AVAudioFormat) async {
        do {
            let session = AVAudioSession.sharedInstance()
            
            if let sampleRate = currentTrack?.sampleRate {
                try session.setPreferredSampleRate(Double(sampleRate))
            }
            
            // Don't activate session here - only activate when actually playing
            // try session.setActive(true) - removed to prevent interrupting other apps during track loading
            
            print("Configured audio session preferences - Sample Rate: \(session.sampleRate)")
            
        } catch {
            print("Failed to configure audio session: \(error)")
        }
    }
    
    // MARK: - Timer and Updates
    
    func startPlaybackTimer() {
        stopPlaybackTimer()
        
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.updatePlaybackTime()
            }
        }
    }
    
    private func updatePlaybackTime() async {
        guard let audioFile = audioFile,
              let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            return
        }
        
        // Add seek offset to handle scheduleSegment from non-zero positions
        let nodePlaybackTime = Double(playerTime.sampleTime) / audioFile.processingFormat.sampleRate
        playbackTime = seekTimeOffset + nodePlaybackTime
        
        // Remove this duplicate detection - it's handled by checkIfTrackEnded()
        /* DELETE THIS BLOCK:
         if isPlaying && playbackTime >= duration - 0.1 && duration > 0 {
         isPlaying = false
         await handleTrackEnd()
         }
         */
        
        // Update Now Playing info every few seconds to keep Lock Screen current
        if Int(playbackTime) % 3 == 0 {
            updateNowPlayingInfo()
        }
    }
    
    private func handleTrackEnd() async {
        guard !isLoadingTrack else { return }
        
        if isLoopingSong, let t = currentTrack {
            await loadTrack(t)
            play()
            return
        }
        
        if currentIndex < playbackQueue.count - 1 {
            currentIndex = (currentIndex + 1) % playbackQueue.count
            let next = playbackQueue[currentIndex]
            await loadTrack(next, preservePlaybackTime: false)
            play()
            return
        }
        
        if isRepeating, !playbackQueue.isEmpty {
            currentIndex = 0
            currentTrack = playbackQueue[0]
            await loadTrack(playbackQueue[0])
            play()
            return
        }
        
        stop()
    }

    
    func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }
    
    // MARK: - Now Playing Info
    
    private func updateNowPlayingInfo() {
        guard let track = currentTrack else {
            // Clear now playing info if no track
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        
        // Keep info during .loading to avoid visual reset
        if playbackState == .stopped && !isPlaying {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = track.title
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = playbackTime
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        
        if playbackQueue.indices.contains(currentIndex) {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = currentIndex
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = playbackQueue.count
        } else {
            info.removeValue(forKey: MPNowPlayingInfoPropertyPlaybackQueueIndex)
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = playbackQueue.count
        }
        
        // Audio format info (shows in some iOS versions)
        if let sampleRate = track.sampleRate {
            info[MPMediaItemPropertyComments] = "Hi-Res \(sampleRate/1000)kHz"
        }
        
        do {
            // Artist info
            if let artistId = track.artistId,
               let artist = try databaseManager.read({ db in
                   try Artist.fetchOne(db, key: artistId)
               }) {
                info[MPMediaItemPropertyArtist] = artist.name
            }
            
            // Album info
            if let albumId = track.albumId,
               let album = try databaseManager.read({ db in
                   try Album.fetchOne(db, key: albumId)
               }) {
                info[MPMediaItemPropertyAlbumTitle] = album.title
            }
        } catch {
            print("Failed to fetch artist/album info: \(error)")
        }
        
        // Track number
        if let trackNo = track.trackNo {
            info[MPMediaItemPropertyAlbumTrackNumber] = trackNo
        }
        
        // Handle artwork efficiently
        if track.hasEmbeddedArt {
            // Check if we already have cached artwork for this track
            if let cachedArtwork = cachedArtwork,
               cachedArtworkTrackId == track.stableId {
                // Use cached artwork
                info[MPMediaItemPropertyArtwork] = cachedArtwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            } else {
                // Load artwork asynchronously and cache it
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info // Set basic info immediately
                Task {
                    await loadAndCacheArtwork(track: track)
                }
            }
        } else {
            // No embedded artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }
    
    private func loadAndCacheArtwork(track: Track) async {
        guard track.hasEmbeddedArt else { return }
        
        do {
            // Ensure file is local first
            let url = URL(fileURLWithPath: track.path)
            try await cloudDownloadManager.ensureLocal(url)
            
            // Load artwork using NSFileCoordinator with proper async handling
            let artwork = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MPMediaItemArtwork?, Error>) in
                DispatchQueue.global(qos: .background).async {
                    var coordinatorError: NSError?
                    let coordinator = NSFileCoordinator()
                    
                    coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinatorError) { (readingURL) in
                        do {
                            let freshURL = URL(fileURLWithPath: readingURL.path)
                            print("🎵 Loading artwork from: \(freshURL.lastPathComponent)")
                            
                            // Check if file actually exists at path
                            guard FileManager.default.fileExists(atPath: freshURL.path) else {
                                print("❌ Artwork file not found at path: \(freshURL.path)")
                                continuation.resume(returning: nil)
                                return
                            }
                            
                            // For FLAC files, try multiple approaches
                            let fileExtension = freshURL.pathExtension.lowercased()
                            
                            if fileExtension == "flac" {
                                // First try with AVAsset (works for some FLAC files)
                                if let artwork = self.loadArtworkFromAVAsset(url: freshURL) {
                                    print("✅ Loaded FLAC artwork via AVAsset")
                                    continuation.resume(returning: artwork)
                                    return
                                }
                                
                                // If AVAsset fails, try direct FLAC metadata reading
                                if let artwork = self.loadArtworkFromFLACMetadata(url: freshURL) {
                                    print("✅ Loaded FLAC artwork via direct metadata reading")
                                    continuation.resume(returning: artwork)
                                    return
                                }
                                
                                print("⚠️ No artwork found in FLAC file: \(freshURL.lastPathComponent)")
                                continuation.resume(returning: nil)
                            } else {
                                // For MP3/M4A files, use AVAsset
                                if let artwork = self.loadArtworkFromAVAsset(url: freshURL) {
                                    print("✅ Loaded artwork via AVAsset for: \(freshURL.lastPathComponent)")
                                    continuation.resume(returning: artwork)
                                } else {
                                    print("⚠️ No artwork found in file: \(freshURL.lastPathComponent)")
                                    continuation.resume(returning: nil)
                                }
                            }
                            
                        } catch {
                            print("❌ Error loading artwork: \(error)")
                            continuation.resume(throwing: error)
                        }
                    }
                    
                    if let error = coordinatorError {
                        print("❌ NSFileCoordinator error loading artwork: \(error)")
                        continuation.resume(throwing: error)
                    }
                }
            }
            
            // Cache the artwork and update now playing info
            await MainActor.run {
                if let artwork = artwork {
                    // Cache the artwork
                    self.cachedArtwork = artwork
                    self.cachedArtworkTrackId = track.stableId
                    
                    // Update now playing info with cached artwork
                    self.updateNowPlayingInfoWithCachedArtwork()
                    print("🎨 Cached and updated artwork for: \(track.title)")
                } else {
                    print("🎨 No artwork to cache for: \(track.title)")
                }
            }
            
        } catch {
            print("❌ Failed to load artwork for caching: \(error)")
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
                    
                    let artwork = MPMediaItemArtwork(boundsSize: processedImage.size) { size in
                        return processedImage
                    }
                    
                    return artwork
                }
            }
            
            print("⚠️ No artwork found in AVAsset metadata")
            return nil
            
        } catch {
            print("❌ AVAsset artwork loading failed: \(error)")
            return nil
        }
    }
    
    private nonisolated func loadArtworkFromFLACMetadata(url: URL) -> MPMediaItemArtwork? {
        do {
            // Read FLAC file directly to extract embedded artwork
            let data = try Data(contentsOf: url)
            
            // Look for FLAC PICTURE metadata block
            if let artwork = extractFLACPictureBlock(from: data) {
                print("🎨 Found artwork in FLAC PICTURE block")
                
                let processedImage = self.cropToSquareIfNeeded(image: artwork)
                
                let mpArtwork = MPMediaItemArtwork(boundsSize: processedImage.size) { size in
                    return processedImage
                }
                
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
    
    // MARK: - State Persistence
    
    func savePlayerState() {
        guard let currentTrack = currentTrack else {
            print("🚫 No current track to save state for")
            return
        }
        
        let playerState: [String: Any] = [
            "currentTrackStableId": currentTrack.stableId,
            "playbackTime": playbackTime,
            "isPlaying": false, // Always save as paused to prevent auto-play on launch
            "queueTrackIds": playbackQueue.map { $0.stableId },
            "currentIndex": currentIndex,
            "isRepeating": isRepeating,
            "isShuffled": isShuffled,
            "isLoopingSong": isLoopingSong,
            "originalQueueTrackIds": originalQueue.map { $0.stableId },
            "lastSavedAt": Date()
        ]
        
        UserDefaults.standard.set(playerState, forKey: "CosmosPlayerState")
        UserDefaults.standard.synchronize()
        print("✅ Player state saved to UserDefaults (offline, per-device)")
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
            
            let queueTracks = try DatabaseManager.shared.read { db in
                try queueTrackIds.compactMap { stableId in
                    try Track.filter(Column("stable_id") == stableId).fetchOne(db)
                }
            }
            
            let originalQueueTracks = try DatabaseManager.shared.read { db in
                try originalQueueTrackIds.compactMap { stableId in
                    try Track.filter(Column("stable_id") == stableId).fetchOne(db)
                }
            }
            
            // Restore UI state only - no audio loading
            await MainActor.run {
                self.playbackQueue = queueTracks.isEmpty ? [restoredTrack] : queueTracks
                self.originalQueue = originalQueueTracks.isEmpty ? [restoredTrack] : originalQueueTracks
                
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
            
            let queueTracks = try DatabaseManager.shared.read { db in
                try queueTrackIds.compactMap { stableId in
                    try Track.filter(Column("stable_id") == stableId).fetchOne(db)
                }
            }
            
            let originalQueueTracks = try DatabaseManager.shared.read { db in
                try originalQueueTrackIds.compactMap { stableId in
                    try Track.filter(Column("stable_id") == stableId).fetchOne(db)
                }
            }
            
            // Restore player state
            await MainActor.run {
                self.playbackQueue = queueTracks.isEmpty ? [restoredTrack] : queueTracks
                self.originalQueue = originalQueueTracks.isEmpty ? [restoredTrack] : originalQueueTracks
                
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
        
        NotificationCenter.default.removeObserver(self)
        volumeCheckTimer?.invalidate()
        
        
        // Remove KVO observer only if it was set up
        if hasSetupAudioSessionNotifications {
            AVAudioSession.sharedInstance().removeObserver(self, forKeyPath: "outputVolume")
        }
    }
}

enum PlayerError: Error {
    case fileNotFound
    case invalidAudioFile
    case audioEngineError
    case configurationError
}
