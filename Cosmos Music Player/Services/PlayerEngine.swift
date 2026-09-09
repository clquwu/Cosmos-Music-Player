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
    @Published var isPlaying = false {
        didSet {
            DatabaseSuspensionCoordinator.shared.setPlaybackActivityActive(keepsDatabaseActive)
        }
    }
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
    /// Why the selected track is not playing, when the reason is something the
    /// user can act on. `playbackState` alone was not enough: no view reads it,
    /// so a track that could not be fetched simply sat there doing nothing.
    /// Cleared by the next selection or successful load.
    @Published var playbackErrorMessage: String?

    private var originalQueue: [String] = []
    private let maxPersistedQueueSize = 2000

    // Generation token to prevent stale completion handlers from firing
    private var scheduleGeneration: UInt64 = 0

    private var seekTimeOffset: TimeInterval = 0
    private var lastSampleRate: Double = 0

    private lazy var audioEngine = AVAudioEngine()
    private lazy var playerNode = AVAudioPlayerNode()
    private var audioFile: AVAudioFile?
    private var playbackTimer: Timer?

    // Gapless playback support
    private var nextAudioFile: AVAudioFile?
    private var nextTrack: Track?
    private var nextTrackIndex: Int?
    private var isPreloadingNext = false
    private var gaplessScheduled = false
    private var preloadNextTask: Task<Void, Never>?
    /// The SFBAudioEngine equivalent of nextTrack/nextTrackIndex above. Kept
    /// separate because the successor lives inside SFBAudioPlayer's own decoder
    /// queue rather than in an AVAudioFile of ours.
    private var sfbNextTrack: Track?
    private var sfbNextTrackIndex: Int?
    private var sfbPreloadNextTask: Task<Void, Never>?
    private var sfbPreloadGeneration: UInt64 = 0
    private var nodeTimelineStartSampleTime: AVAudioFramePosition = 0
    private var nextTimelineStartSampleTime: AVAudioFramePosition?
    private var engineConfigurationRecoveryTask: Task<Void, Never>?
    private var outputRouteRecoveryTask: Task<Void, Never>?
    private var outputRouteRecoveryGeneration: UInt64 = 0
    private var isRecoveringOutputRoute = false
    /// A route event that arrived while a recovery was already running. The
    /// recovery does a full SFB reload, so that window is easily a second
    /// wide, and the event landing inside it is usually the one describing the
    /// settled route - dropping it left the DSD output safety gate evaluated
    /// against the route the hardware was leaving.
    private var hasPendingOutputRouteRecovery = false
    /// The output ports as of the last route notification, so
    /// .routeConfigurationChange and .newDeviceAvailable can be told apart from
    /// a real device swap. Starts nil so the first event always counts.
    private var lastOutputRouteFingerprint: Set<String>?
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

    /// How long a load may wait inline for an iCloud file before it hands the
    /// track to `schedulePendingCloudPlayback`. Long enough for a file that is
    /// nearly there, short enough that the user is not left in silence.
    private static let inlineCloudDownloadTimeout: TimeInterval = 3
    /// How long the parked wait tolerates no progress at all before telling the
    /// user the download has stalled.
    ///
    /// "No progress" now means neither a higher published percentage nor any
    /// new bytes on disk (see `CloudDownloadManager.DownloadProgressMarker`),
    /// which is a far more reliable signal than the percentage alone - but a
    /// provider can still go a while between visible increments, so this sits
    /// at the manager's own default rather than the 30s it used to use.
    private static let pendingCloudStallTimeout: TimeInterval = 45
    /// The total budget for one selection's cloud wait, retries included.
    ///
    /// `pendingCloudStallTimeout` bounds a single `waitUntilLocal` call, but
    /// the transient-failure branch re-arms the whole wait, and each re-arm
    /// starts a fresh stall clock. When the ubiquitous status flaps - ready to
    /// `waitUntilLocal`, still pending to the decoder open a moment later -
    /// that cycle repeats indefinitely with the transport pinned at `.loading`
    /// and no message. This deadline is carried across every retry so the
    /// selection always resolves one way or the other.
    private static let pendingCloudRetryBudget: TimeInterval = 180

    private var isLoadingTrack = false {
        didSet {
            DatabaseSuspensionCoordinator.shared.setPlaybackActivityActive(keepsDatabaseActive)
        }
    }
    /// Set when the last load failed only because an iCloud download had not
    /// landed. The track is fine and will play shortly, so the auto-advance
    /// must not treat it as unplayable and wander off to another song.
    private var lastLoadFailureWasTransient = false
    /// Latches for the whole of an end-of-track transition.
    ///
    /// `handleTrackEnd()` used to guard on `isLoadingTrack` alone, but
    /// `loadTrack` sets that flag inside a child task, so it is still false
    /// across the first main-actor hop. Three paths reach handleTrackEnd for
    /// the same track end - the .dataPlayedBack completion handler, the 0.5s
    /// backgroundCheckTimer's node-stopped check (which never cleared
    /// isPlaying) and its position-based check - and two of them landing in
    /// that gap advanced the queue twice, skipping a song.
    private var isAdvancingTrack = false {
        didSet {
            DatabaseSuspensionCoordinator.shared.setPlaybackActivityActive(keepsDatabaseActive)
        }
    }
    /// Database access remains part of active playback while a decoder is being
    /// replaced or the queue is advancing. `isPlaying` alone deliberately goes
    /// false during cleanup, but suspending GRDB in that gap aborts path repairs,
    /// play-count writes and any other transition work.
    var keepsDatabaseActive: Bool {
        isPlaying || isLoadingTrack || isAdvancingTrack
    }
    private var currentLoadTask: Task<Bool, Never>?
    private var loadGeneration: UInt64 = 0
    /// True from the moment `loadTrack` is entered until its load settles.
    ///
    /// `isLoadingTrack` alone is not enough for the transport entry points.
    /// It is set inside `performLoadTrack`, which runs in a child task, so it
    /// is still false across the first main-actor hop - and during that hop
    /// `usingSFBEngine`/`audioFile` still describe the decoder that
    /// `cleanupCurrentPlayback` is about to tear down. A Play, Seek or remote
    /// command landing there acted on a backend that no longer had anything
    /// loaded: `SFBAudioEngineManager.play()` skips its session setup when
    /// `loadedDecoder` is nil and starts the engine anyway, so the transport
    /// reported Playing over silence.
    private var isLoadInFlight: Bool {
        isLoadingTrack || currentLoadTask != nil
    }
    /// Identifies the latest user-visible transport decision. Unlike
    /// loadGeneration, this spans an entire queue walk, so a cancelled load
    /// cannot let its stale caller continue through a newly-selected queue.
    private var playbackIntentGeneration: UInt64 = 0
    /// A cloud-only selection remains selected while iCloud materialises it.
    /// The generation prevents an older download from starting after the user
    /// has selected, stopped, or paused something else.
    private var pendingCloudPlaybackTask: Task<Void, Never>?
    private var pendingCloudPlaybackGeneration: UInt64 = 0
    /// Whether the pending cloud wait should start playing when its bytes
    /// land. Mutable so `pause()` can demote a wait rather than cancel it.
    private var pendingCloudPlaybackShouldAutoplay = false
    private var hasRestoredState = false
    private var hasSetupAudioEngine = false
    /// Set when AVAudioEngine reported a configuration change at a moment we
    /// could not act on - paused, or mid-interruption. The graph then describes
    /// hardware that is gone, and `start()` answers success before stopping
    /// itself again, so the next playback attempt skips straight to rebuilding.
    /// See `processEngineConfigurationChange` and
    /// `startEngineAndScheduleSegment`.
    private var nativeGraphNeedsReconfiguration = false
    /// When we last rebuilt the graph ourselves. AVAudioEngine posts a
    /// configuration change for our own reconnects, and without this the
    /// repair re-triggers itself - see `processEngineConfigurationChange`.
    private var lastSelfInducedGraphRebuildAt: Date?
    private static let selfInducedConfigurationChangeWindow: TimeInterval = 0.5
    /// When the last stalled-SFB rebuild ran, so a rebuild that stalls again
    /// cannot spin. See `recoverStalledSFBPlayback()`.
    private var lastStalledSFBRecoveryAt: Date?
    private static let stalledSFBRecoveryCooldown: TimeInterval = 10
    private var hasSetupAudioSession = false
    private var hasSetupSiriBackgroundSession = false
    private(set) var isAudioSessionInterrupted = false
    /// True only when nothing is loaded, loading, or paused mid-track - i.e.
    /// when it is genuinely safe to hand the audio session to another app.
    var canReleaseAudioSession: Bool {
        currentTrack == nil && !isLoadingTrack && !isPlaying
    }
    private var wasPlayingBeforeInterruption = false
    /// A load or explicit Play request that reached `play()` while the session
    /// was interrupted. It may resume only when the matching `.ended` event
    /// carries `.shouldResume`; until then no engine or session is touched.
    private var playWasDeferredByInterruption = false
    /// Set when the output device disappears (headphones unplugged, Bluetooth
    /// disconnected). This survives interruption ordering and asynchronous
    /// track loads. iOS 17+ reports an unplug as an *interruption* whose .ended
    /// carries .shouldResume, while other routes report only a route change, so
    /// scoping the latch to one interruption lets either ordering resume into
    /// speaker.
    ///
    /// It is NOT scoped to an explicit playback request either, which is what
    /// it used to be. `.oldDeviceUnavailable` fires for transient flaps as well
    /// as real unplugs - a navigation prompt over Bluetooth or CarPlay drops
    /// the music route for a moment, and `currentRoute.outputs` can read *empty*
    /// mid-transition, which this reads as "fell back to speaker". Latching on
    /// that event with nothing but a user tap to release it meant one Waze
    /// instruction blocked every automatic resume for the rest of the session:
    /// not just that interruption's, but end-of-track advances and route
    /// recoveries too. See `refreshOutputDeviceAvailability()`.
    private var outputDeviceBecameUnavailable = false
    /// The bounded wait for the route to settle after an interruption ended.
    /// See `resumeWhenOutputRouteSettles()`. Never started from a route
    /// notification - only from `.ended`, once the interrupting app is done.
    private var outputRouteSettleResumeTask: Task<Void, Never>?
    private static let routeSettleResumeAttempts = 6
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// Coalesces widget publishes so rapid transport taps do not queue one
    /// artwork re-encode each.
    private var widgetUpdateTask: Task<Void, Never>?
    /// Orders widget writes against each other - see updateWidgetData().
    private var widgetUpdateSequence: UInt64 = 0
    /// The track whose cover is currently in the App Group container, so a
    /// play/pause of the same track skips the encode and the file write.
    private var lastWidgetArtworkTrackId: String?
    /// Held so `deinit` can remove it. Deliberately NOT in
    /// `notificationObservers`: that array is emptied and rebuilt by
    /// `setupAudioSessionNotifications()` on every media-services reset, which
    /// would drop this observer and never register it again.
    ///
    /// `nonisolated(unsafe)` for the same reason that array is - `deinit` is
    /// nonisolated and cannot touch main-actor state. Only `init` writes it.
    private nonisolated(unsafe) var artworkChangedObserver: NSObjectProtocol?
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
    private var cachedNowPlayingAlbumTrackId: String?
    private var cachedNowPlayingAlbumName: String?

    // Security-scoped resource tracking for external files
    private var currentSecurityScopedURL: URL?
    /// Bookmark resolution can change a path-derived stable ID while an
    /// asynchronous playback operation still holds the original Track value.
    /// Keep the migration chain so those operations can distinguish the same
    /// moved track from a genuinely superseded selection.
    private var resolvedBookmarkIdentityAliases: [String: String] = [:]

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
        sfbAudioManager.onPlaybackEnded = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.handleSFBPlaybackEnded()
            }
        }
        sfbAudioManager.onPlaybackFailed = { [weak self] error in
            self?.handleSFBPlaybackFailure(error)
        }
        sfbAudioManager.onPlaybackStalled = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.recoverStalledSFBPlayback()
            }
        }
        sfbAudioManager.onGaplessTrackStarted = { [weak self] url in
            self?.promoteSFBGaplessTrack(url)
        }
        // AVAudioUnitEQ cannot change its band count, so a preset with more
        // bands than the live node needs the node replaced. Only this class
        // can do that safely: it owns the engine and has to re-schedule the
        // playing track around the swap.
        eqManager.onNativeEQGraphRebuildNeeded = { [weak self] in
            self?.rebuildNativeEQGraph()
        }
        // The widget's copy of the cover is skipped for a track it already
        // holds - see updateWidgetData(). Artwork that arrives *after* that
        // decision was made has to reopen it.
        artworkChangedObserver = NotificationCenter.default.addObserver(
            forName: ArtworkManager.artworkChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let stableId = note.userInfo?["trackStableId"] as? String else { return }
            // Registered on .main, so this already runs on the main thread -
            // but the closure itself is nonisolated.
            MainActor.assumeIsolated {
                self?.handleArtworkChanged(forTrack: stableId)
            }
        }
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

    /// Starts the native engine and schedules `file` from `startFrame`,
    /// escalating through a graph rebuild and a full engine recreation until
    /// audio is actually queued.
    ///
    /// Starting and scheduling cannot be separated here. `AVAudioEngine.start()`
    /// returns without throwing, answers `isRunning == true`, and then stops
    /// itself an instant later when its graph does not match the output
    /// hardware - so a check straight after `start()` sees a running engine and
    /// `scheduleSegment()` two statements later sees a stopped one. Whether a
    /// segment got scheduled is the only trustworthy signal.
    ///
    /// This is what a Bluetooth navigation prompt does to us. With Waze's "use
    /// sound as a phone call" setting the car moves A2DP -> HFP for the alert
    /// and back, so the output hardware format changes twice while our engine
    /// is stopped by the interruption, leaving the graph wired for a format
    /// that no longer exists. `ensureAudioEngineSetup(with:)` cannot catch it:
    /// it compares the *file's* sample rate against the last one it saw, and
    /// the file never changed. Only the hardware did.
    ///
    /// - Returns: whether a segment is now scheduled on the player node.
    private func startEngineAndScheduleSegment(
        from startFrame: AVAudioFramePosition,
        file: AVAudioFile,
        context: String
    ) -> Bool {
        let format = file.processingFormat

        // A configuration change we could not act on when it arrived means the
        // first attempt is certain to fail. Skip it rather than paying for a
        // start/schedule round trip that already lost.
        var firstAttempt = 0
        if nativeGraphNeedsReconfiguration {
            print("♻️ \(context): graph was marked stale by a configuration change")
            firstAttempt = 1
        }
        nativeGraphNeedsReconfiguration = false

        for attempt in firstAttempt..<3 {
            switch attempt {
            case 1:
                print("♻️ \(context): rewiring the audio graph for the current route")
                reconfigureAudioEngineForNewFormat(format)
            case 2:
                // A rebuilt graph on the same engine can inherit the stale
                // hardware negotiation. A fresh AVAudioEngine cannot.
                print("♻️ \(context): recreating the audio engine for the current route")
                resetAudioEngineForNative()
                ensureAudioEngineSetup(with: format)
            default:
                break
            }

            if !audioEngine.isRunning {
                do {
                    try audioEngine.start()
                } catch {
                    print("⚠️ \(context): audio engine start threw on attempt \(attempt + 1): \(error)")
                    continue
                }
            }

            if scheduleSegment(
                from: startFrame,
                file: file,
                track: currentTrack,
                trackIndex: currentIndex
            ) {
                if attempt > 0 {
                    print("✅ \(context): audio scheduled after \(attempt + 1) attempts")
                }
                return true
            }
        }

        print("❌ \(context): could not get the audio engine running on this route")
        return false
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
        // Stamped before the restart below, so the notification that restart
        // provokes falls inside the window.
        lastSelfInducedGraphRebuildAt = Date()
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

    /// Replaces the EQ node with one sized for the preset that was just
    /// selected, keeping the current track playing across the swap.
    ///
    /// Attaching and detaching nodes on a running engine is not safe, so this
    /// follows the same shape as reconfigureAudioEngineForNewFormat(): stop the
    /// engine, rebuild, then re-schedule the remainder of the current file from
    /// where it actually was. Stopping the engine drops everything already
    /// handed to the player node, including a gapless successor, so that
    /// bookkeeping has to be dropped with it.
    private func rebuildNativeEQGraph() {
        guard eqManager.nativeEQNodeNeedsRebuild else { return }

        // SFBAudioEngine owns its own graph and its own 16-band EQ, so nothing
        // is rendering through our engine - but it may still be left running
        // with nothing scheduled, and attaching or detaching nodes on a running
        // engine is not safe. Stop it first; ensureAudioEngineSetup()/play()
        // start it again, and switching back to native playback rebuilds the
        // whole graph through resetAudioEngineForNative() anyway.
        guard !usingSFBEngine, hasSetupAudioEngine else {
            if audioEngine.isRunning {
                audioEngine.stop()
            }
            eqManager.rebuildNativeEQNode()
            audioEngine.prepare()
            return
        }

        let resumeTime = currentTimeForCurrentNativeFile()
        let wasPlaying = isPlaying
        let file = audioFile

        cancelPendingCompletions()
        clearPreloadedNext()
        playerNode.stop()

        let wasRunning = audioEngine.isRunning
        if wasRunning {
            audioEngine.stop()
        }

        eqManager.rebuildNativeEQNode()
        audioEngine.prepare()

        guard let file else {
            // Nothing loaded - the next play() builds its own schedule.
            return
        }

        // playerNode.stop() rewound the node's timeline, so re-base exactly as
        // the resume-from-pause path does.
        seekTimeOffset = resumeTime
        playbackTime = resumeTime
        nodeTimelineStartSampleTime = 0

        guard wasPlaying else {
            // Leave it paused at the same position; play() re-schedules from
            // seekTimeOffset.
            isPlaying = false
            if playbackState == .playing { playbackState = .paused }
            updateNowPlayingInfoEnhanced()
            return
        }

        do {
            try audioEngine.start()
        } catch {
            print("❌ Failed to restart audio engine after EQ rebuild: \(error)")
            isPlaying = false
            playbackState = .paused
            updateNowPlayingInfoEnhanced()
            return
        }

        let frame = AVAudioFramePosition(resumeTime * file.processingFormat.sampleRate)
        guard frame >= 0,
              frame < file.length,
              scheduleSegment(from: frame, file: file, track: currentTrack, trackIndex: currentIndex) else {
            // Every path out of here must leave playback recoverable - the node
            // has already been stopped. play() restarts from seekTimeOffset.
            print("♻️ Re-scheduling after EQ rebuild failed - restarting from \(resumeTime)s")
            isPlaying = false
            playbackState = .paused
            continuePlaybackAfterAutomaticAction()
            return
        }

        playerNode.play()
        isPlaying = true
        playbackState = .playing
        startPlaybackTimer()
        updateNowPlayingInfoEnhanced()
        preloadAndScheduleNextIfNeeded()
        print("✅ Rebuilt the EQ node and resumed at \(resumeTime)s")
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
        // Building the graph is a configuration change of our own making too.
        lastSelfInducedGraphRebuildAt = Date()
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
        // Drop any previous registration first. recreateAudioEngine() clears
        // hasSetupAudioSessionNotifications after a media services reset, and
        // this is a singleton whose deinit never runs, so without this every
        // reset left another live set of observers behind. Two interruption
        // handlers is not merely wasteful: the second .began sees isPlaying
        // already false and overwrites wasPlayingBeforeInterruption, which
        // silently disables auto-resume after calls and nav prompts.
        removeAudioSessionNotifications()

        // Seed the route fingerprint from the route as it stands right now.
        // It starts nil, and processAudioSessionRouteChange reads "no recorded
        // route" as "the outputs changed" - so the first notification after
        // these observers go live always looked like a device swap. That is
        // now the worst possible moment for a false positive: these are
        // installed by performLoadTrack, immediately before playback starts,
        // and on the SFBAudioEngine path a swap triggers a full
        // stop/reload/seek - an audible gap plus a dropped gapless successor -
        // on a route that had not changed at all.
        lastOutputRouteFingerprint = currentOutputRouteFingerprint()

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
            // Apple's documented pattern for .oldDeviceUnavailable is to read
            // the PREVIOUS route out of the user-info dictionary and ask what
            // was removed, rather than inferring it from what is connected now.
            // Reduced to raw port types here because AVAudioSessionRouteDescription
            // is not Sendable and this closure is not main-actor isolated.
            let previousOutputs = Set(
                (notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey]
                    as? AVAudioSessionRouteDescription)?
                    .outputs.map(\.portType.rawValue) ?? []
            )
            Task { @MainActor [weak self] in
                self?.processAudioSessionRouteChange(
                    reason: reason,
                    previousOutputPortTypes: previousOutputs
                )
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

    private nonisolated func removeAudioSessionNotifications() {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()
    }

    private func processAudioSessionInterruption(typeValue: UInt, optionsValue: UInt?) {
        guard let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            print("🚫 Interruption began - playing=\(isPlaying) state=\(playbackState) route=\(AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue).joined(separator: ","))")
            // A second `.began` can arrive before the matching `.ended`: Waze
            // issues alerts back to back, and each A2DP -> HFP -> A2DP swap can
            // carry an interruption of its own. Only the FIRST `.began` of such
            // a chain saw the transport as the user left it - by the second we
            // have already paused ourselves, so `isPlaying` reads false.
            //
            // Recording that would overwrite "the user was playing" with false
            // and the `.ended` at the end of the chain then refuses to resume:
            //     🚫 Interruption began - playing=true  state=playing
            //     🚫 Interruption began - playing=false state=paused
            //     ✅ Interruption ended - wasPlaying=false
            //     ⏸️ Not auto-resuming - user must manually resume
            // which is one nav instruction silencing music until it is started
            // by hand. So the intent flags are captured once per chain.
            let isNestedInterruption = isAudioSessionInterrupted
            isAudioSessionInterrupted = true
            if !isNestedInterruption {
                playWasDeferredByInterruption = false
            }
            // Whatever is interrupting us now owns the route. A resume still
            // waiting on the previous interruption's route must not fire on top
            // of it - that is what cut a navigation prompt off mid-sentence.
            cancelOutputRouteSettleResume()

            // Save current playback position before interruption.
            // Prefer the live render position, but do not count on it: iOS has
            // usually stopped the engine by the time this notification is
            // delivered, in which case nowPlayingElapsedTime() falls back to
            // the cached playbackTime. That cached value is kept fresh in the
            // background by backgroundCheckTimer (see checkIfTrackEnded) -
            // without that refresh it froze at whatever it held when the app
            // was backgrounded, and resuming rewound the track.
            let wasPlaying = isPlaying
            let savedPosition = wasPlaying ? nowPlayingElapsedTime() : playbackTime
            if !isNestedInterruption {
                wasPlayingBeforeInterruption = wasPlaying
            }

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
            print("✅ Interruption ended - deviceLostLatched=\(outputDeviceBecameUnavailable) wasPlaying=\(wasPlayingBeforeInterruption) state=\(playbackState) route=\(AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue).joined(separator: ","))")
            isAudioSessionInterrupted = false
            print("💾 Will restore to position: \(playbackTime)s when playback resumes")

            // NOTE: the session is deliberately NOT re-activated here. This
            // ran before shouldResume/wasPlayingBeforeInterruption/headphone
            // removal were even consulted, so a Cosmos that was manually
            // paused reclaimed a non-mixing .playback session at the end of
            // every call or alarm and interrupted whatever else had started.
            // Both resume paths activate the session themselves - the native
            // one through play() -> activateAudioSession(), the SFB one
            // through SFBAudioEngineManager.play() - so nothing is lost.

            // NOTE: the native engine is deliberately NOT restarted here.
            // play() starts it itself, right before it re-schedules the audio
            // segment. Starting it here was actively harmful: after a plain
            // pause the player node is still "playing", so start() resumed it
            // behind our back - audio came out of the speaker while isPlaying
            // stayed false and the timeline sat frozen. It also risked starting
            // the engine on a route that had not finished settling, which
            // rendered silence.

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
            // 3. The output device did not disappear. Unplugging headphones is
            //    delivered as an interruption on iOS 17+, and its .ended still
            //    carries .shouldResume - honouring it would blast the track out
            //    of the built-in speaker, which is exactly what the user is
            //    trying to avoid by unplugging.
            // The route may have settled back while the prompt was ending, so
            // re-read the latch before consulting it.
            refreshOutputDeviceAvailability()

            // Deliberately without an `!outputDeviceBecameUnavailable` term.
            // continuePlaybackAfterAutomaticAction() applies that check itself,
            // and only it can record the refusal so a route that comes back a
            // moment later can honour the resume this interruption asked for.
            let resumeAllowed = shouldResume
                && (wasPlayingBeforeInterruption || playWasDeferredByInterruption)
                && playbackState == .paused

            // Consume only interruption-owned flags. The route-loss latch must
            // survive both notification orderings and any load still in flight;
            // a later explicit playback request is what clears it.
            wasPlayingBeforeInterruption = false
            playWasDeferredByInterruption = false

            if resumeAllowed {
                print("▶️ Resuming playback that was active or deferred by the interruption")
                if outputDeviceBecameUnavailable {
                    // The route has not settled yet. Do not give up on the
                    // resume - a navigation prompt's flap looks exactly like an
                    // unplug at this instant and only looks different a moment
                    // later.
                    resumeWhenOutputRouteSettles()
                } else {
                    continuePlaybackAfterAutomaticAction()
                }
            } else {
                print("⏸️ Not auto-resuming - user must manually resume")

                // Ensure playback state is correct but keep position saved
                isPlaying = false
                playbackState = .paused
                updateNowPlayingInfoEnhanced()

                if usingSFBEngine {
                    // SFBAudioPlayer observes the interruption itself and
                    // restarts on .shouldResume with no idea that the output
                    // device disappeared - which is exactly how an unplug
                    // arrives on iOS 17+. Its observer may run after this one,
                    // so re-assert the pause on the next hop instead of inline.
                    // stopEngineForInterruption() rather than pause() because
                    // pause() also deactivates the session.
                    Task { @MainActor [weak self] in
                        guard let self, self.usingSFBEngine, !self.isPlaying else { return }
                        self.sfbAudioManager.stopEngineForInterruption()
                        self.updateNowPlayingInfoEnhanced()
                    }
                } else if audioEngine.isRunning {
                    // Normally the native engine was stopped in `.began`. This
                    // is a final safety net for a start that raced the event or
                    // was initiated by an older build/path while interrupted.
                    audioEngine.pause()
                }
            }

        @unknown default:
            break
        }
    }

    /// Identifies the current set of output ports, so a route notification can
    /// be checked against what is actually connected rather than trusted on its
    /// reason code alone.
    private func currentOutputRouteFingerprint() -> Set<String> {
        Set(
            AVAudioSession.sharedInstance().currentRoute.outputs.map {
                "\($0.portType.rawValue)|\($0.uid)"
            }
        )
    }

    /// Whether the session is on the built-in speaker right now - the state a
    /// real unplug leaves behind. An empty output list counts: mid-transition
    /// the route can read as nothing at all, and there is certainly nowhere
    /// safe to play in that instant.
    private func currentRouteIsSpeakerFallback() -> Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outputs.isEmpty || outputs.contains { $0.portType == .builtInSpeaker }
    }

    /// Re-reads `outputDeviceBecameUnavailable` against the route as it stands
    /// now, rather than trusting the event that set it.
    ///
    /// This is the difference between an unplug and a flap, and it can only be
    /// answered once the route has settled: after an unplug the speaker is
    /// still the output, while after a navigation prompt the car is back.
    ///
    /// It ONLY lifts the block. It deliberately does not start playback, even
    /// though it knows a resume was refused moments ago: this runs from a route
    /// notification, and a navigation app's route flap happens when its prompt
    /// *starts*, not when it ends. Resuming here activated a non-mixing
    /// `.playback` session on top of Waze mid-sentence and cut the alert off.
    /// Only `.ended` knows the other app has finished; see
    /// `resumeWhenOutputRouteSettles()`.
    private func refreshOutputDeviceAvailability() {
        guard outputDeviceBecameUnavailable, !currentRouteIsSpeakerFallback() else { return }

        print("🎧 Output device is back - lifting the automatic-playback block")
        outputDeviceBecameUnavailable = false
    }

    /// Waits briefly for the output route to settle, then performs the resume
    /// an interruption asked for.
    ///
    /// `.ended` can arrive while the route is still mid-transition, reading as
    /// the built-in speaker or as nothing at all, which
    /// `playRespectingOutputRoute()` correctly refuses. The other app has
    /// finished by then, so re-checking shortly afterwards is safe - unlike
    /// reacting to the route notification itself, which lands while it is still
    /// talking. Bounded, and abandoned the moment anything supersedes it.
    private func resumeWhenOutputRouteSettles() {
        outputRouteSettleResumeTask?.cancel()

        let expectedIntent = playbackIntentGeneration
        outputRouteSettleResumeTask = Task { @MainActor [weak self] in
            for _ in 0..<Self.routeSettleResumeAttempts {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }

                guard let self,
                      self.playbackIntentGeneration == expectedIntent,
                      !self.isAudioSessionInterrupted,
                      !self.isPlaying,
                      self.playbackState == .paused,
                      self.currentTrack != nil else { return }

                self.refreshOutputDeviceAvailability()
                guard !self.outputDeviceBecameUnavailable else { continue }

                print("▶️ Output route settled after the interruption - resuming")
                self.continuePlaybackAfterAutomaticAction()
                return
            }
            print("🎧 Output route never came back after the interruption - staying paused")
        }
    }

    /// Port types that mean "playing out loud on the device itself" - i.e. what
    /// an unplug leaves behind, and never something a user chose to route to.
    private static let speakerLikePortTypes: Set<String> = [
        AVAudioSession.Port.builtInSpeaker.rawValue,
        AVAudioSession.Port.builtInReceiver.rawValue
    ]

    private func processAudioSessionRouteChange(
        reason: AVAudioSession.RouteChangeReason,
        previousOutputPortTypes: Set<String> = []
    ) {
        handleCarPlayStatusChange()

        let outputFingerprint = currentOutputRouteFingerprint()
        print("""
            🎧 Route change: reason=\(reason.rawValue) \
            interrupted=\(isAudioSessionInterrupted) playing=\(isPlaying) \
            deviceLostLatched=\(outputDeviceBecameUnavailable)
            🎧   previous=\(previousOutputPortTypes.sorted().joined(separator: ",")) \
            current=\(AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue).joined(separator: ","))
            🎧   fingerprintWas=\(lastOutputRouteFingerprint?.sorted().joined(separator: ",") ?? "nil") \
            fingerprintNow=\(outputFingerprint.sorted().joined(separator: ","))
            """)

        // While another app owns the session, the route churn IS that app's
        // transition - not something for us to repair.
        //
        // Waze's "use sound as a phone call" setting, which Tesla owners need,
        // moves the car from A2DP to the Bluetooth hands-free channel for the
        // duration of the alert and back afterwards. That arrives here as
        // .oldDeviceUnavailable (A2DP gone) and later .newDeviceAvailable, with
        // the outputs reading empty in between. Every reaction we have is
        // harmful in that window: latching "the device disappeared", pausing
        // again, and above all scheduling a recovery that reconfigures and
        // reactivates a non-mixing .playback session - which takes the route
        // back off the prompt and silences it.
        //
        // The fingerprint is still recorded, so the switch back to A2DP after
        // `.ended` is correctly seen as a change and gets its recovery then.
        guard !isAudioSessionInterrupted else {
            print("🎧 Route change during an interruption - deferring to the interrupting app")
            lastOutputRouteFingerprint = outputFingerprint
            return
        }

        // If a previous event latched "the output device is gone" and the
        // device is demonstrably back, release it.
        refreshOutputDeviceAvailability()

        let outputActuallyChanged = outputFingerprint != lastOutputRouteFingerprint
        if outputActuallyChanged {
            // A different route gets a fresh answer on DoP: the one that
            // refused a carrier rate may just have been replaced by a DAC.
            sfbAudioManager.clearDoPRefusals()
        }
        // Deliberately NOT recorded for every notification. An unhandled reason
        // (.categoryChange, .override, .wakeFromSleep) that happens to carry a
        // new output would otherwise absorb the change, and the
        // .routeConfigurationChange that follows it would then look like a
        // no-op and skip the recovery that was actually needed.
        func rememberOutputRoute() {
            lastOutputRouteFingerprint = outputFingerprint
        }

        var shouldReconfigureOutput = false
        switch reason {
        case .oldDeviceUnavailable:
            // Only pause if audio would now blast from the built-in speaker.
            // Wireless CarPlay briefly flaps to the Bluetooth phone-call
            // channel (Siri, nav voice) and back - that also reports
            // .oldDeviceUnavailable, but the audio stays on the car, and
            // pausing there is wrong.
            let currentOutputs = AVAudioSession.sharedInstance().currentRoute.outputs
            // Both halves are needed, and neither is sufficient alone.
            //
            // Apple's sample reads the previous route to establish what was
            // actually removed; without that test, a transition that never had
            // an external output to lose still looked like an unplug. But the
            // previous route cannot tell an unplug from a navigation prompt
            // momentarily dropping the music route either - both report the car
            // or the headphones as "previous" - so where we ended up matters
            // too. `refreshOutputDeviceAvailability()` re-reads that second
            // half once the route has settled, which is the only moment it is
            // trustworthy.
            let lostAnExternalOutput = previousOutputPortTypes.isEmpty
                || previousOutputPortTypes.contains { !Self.speakerLikePortTypes.contains($0) }
            let fellBackToSpeaker = lostAnExternalOutput && currentRouteIsSpeakerFallback()
            if fellBackToSpeaker {
                print("🎧 Audio device disconnected (fell back to speaker) - pausing playback")
                // Record this even when playback is already stopped. On iOS 17+
                // the unplug arrives as an interruption whose .began has
                // already paused us, so `isPlaying` is false by the time we get
                // here - but .ended is still coming with .shouldResume and must
                // not be honoured.
                outputDeviceBecameUnavailable = true
                if isPlaying {
                    pause()
                }
            } else {
                print("🎧 Route changed but still on external output (\(currentOutputs.map { $0.portType.rawValue })) - continuing")
            }
            rememberOutputRoute()
            shouldReconfigureOutput = true
        case .newDeviceAvailable, .routeConfigurationChange:
            // Only when the outputs really changed. On the SFBAudioEngine path
            // the recovery is a full stop/reload/seek - an audible gap that
            // also drops the queued gapless successor - and these two reasons
            // fire for a great deal more than a device swap: a Bluetooth codec
            // renegotiation, another app touching the session, and the
            // recovery's own configureAudioSessionForDecoder() setting a new
            // preferred rate, which could feed itself.
            rememberOutputRoute()
            shouldReconfigureOutput = outputActuallyChanged
            if !outputActuallyChanged {
                print("🎧 Route event (\(reason.rawValue)) with unchanged outputs - not rebuilding playback")
            }
        default:
            break
        }

        if shouldReconfigureOutput {
            scheduleOutputRouteRecovery()
        }
    }

    /// Route notifications arrive before the new hardware format has settled
    /// and often arrive in bursts. Coalesce them, then rebuild SFB playback so
    /// the DSD output safety gate is evaluated for the new output and the native
    /// file's preferred rate is re-applied for AVAudioEngine playback.
    private func scheduleOutputRouteRecovery() {
        guard !isRecoveringOutputRoute else {
            hasPendingOutputRouteRecovery = true
            return
        }

        outputRouteRecoveryGeneration &+= 1
        let recoveryGeneration = outputRouteRecoveryGeneration
        let expectedLoadGeneration = loadGeneration
        let expectedTrackID = currentTrack?.stableId
        let expectedPlaybackIntentGeneration = playbackIntentGeneration

        outputRouteRecoveryTask?.cancel()
        outputRouteRecoveryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }

            guard let self,
                  self.outputRouteRecoveryGeneration == recoveryGeneration,
                  !self.isLoadingTrack,
                  !self.isAudioSessionInterrupted,
                  self.loadGeneration == expectedLoadGeneration,
                  self.playbackIntentGeneration == expectedPlaybackIntentGeneration,
                  self.playbackIdentity(self.currentTrack?.stableId, matches: expectedTrackID) else { return }

            self.isRecoveringOutputRoute = true
            defer {
                self.isRecoveringOutputRoute = false
                if self.outputRouteRecoveryGeneration == recoveryGeneration {
                    self.outputRouteRecoveryTask = nil
                }
                // Run once more for whatever arrived while this pass was busy.
                // Safe to re-enter: the flag is only ever set while a recovery
                // owns it, and the fresh pass debounces for 200ms of its own.
                if self.hasPendingOutputRouteRecovery {
                    self.hasPendingOutputRouteRecovery = false
                    self.scheduleOutputRouteRecovery()
                }
            }

            if self.usingSFBEngine, let track = self.currentTrack {
                let resumeTime = self.nowPlayingElapsedTime()
                let wasPlaying = self.isPlaying
                let previousState = self.playbackState
                print("🎧 Rebuilding SFB playback for the settled output route at \(resumeTime)s")

                let loaded = await self.loadTrack(
                    track,
                    preservePlaybackTime: true,
                    cancelOutputRouteRecovery: false
                )
                guard loaded else {
                    if self.outputRouteRecoveryGeneration == recoveryGeneration,
                       self.playbackIntentGeneration == expectedPlaybackIntentGeneration,
                       self.playbackIdentity(self.currentTrack?.stableId, matches: expectedTrackID),
                       self.lastLoadFailureWasTransient {
                        self.schedulePendingCloudPlayback(track, autoplay: wasPlaying)
                    }
                    return
                }
                guard self.outputRouteRecoveryGeneration == recoveryGeneration,
                      self.playbackIntentGeneration == expectedPlaybackIntentGeneration,
                      self.playbackIdentity(self.currentTrack?.stableId, matches: expectedTrackID) else { return }

                if resumeTime > 0 {
                    await self.seek(to: min(resumeTime, self.duration))
                }

                guard self.outputRouteRecoveryGeneration == recoveryGeneration,
                      self.playbackIntentGeneration == expectedPlaybackIntentGeneration,
                      self.playbackIdentity(self.currentTrack?.stableId, matches: expectedTrackID) else { return }

                if wasPlaying {
                    self.continuePlaybackAfterAutomaticAction()
                } else {
                    self.isPlaying = false
                    self.playbackState = previousState == .stopped ? .stopped : .paused
                    self.updateNowPlayingInfoEnhanced()
                    self.updateWidgetData()
                }
            } else if let file = self.audioFile, self.isPlaying {
                // Only while we are actually rendering. configureAudioSession()
                // ends in setPreferredSampleRate + setActive(true), and this
                // runs 200ms after a route change - which on a navigation
                // prompt is while the other app is still speaking. Claiming a
                // non-mixing .playback session there cuts the alert off, and
                // there is nothing to reapply the rate for: play() configures
                // the route itself before it schedules anything.
                print("🎧 Reapplying native sample rate for the settled output route")
                await self.configureAudioSession(for: file.processingFormat)
            }
        }
    }

    /// SFBAudioEngineManager tears its player down the moment CarPlay
    /// connects, because SFBAudioEngine is not used on that route. Nothing
    /// told PlayerEngine, so it went on reporting the track as playing: the
    /// lock screen showed a frozen position and the transport did nothing
    /// until another track was picked. Reflect what actually happened.
    func handleCarPlayStatusChange() {
        sfbAudioManager.updateCarPlayStatus()
        handleCarPlayTakeoverIfNeeded()
    }

    private func handleCarPlayTakeoverIfNeeded() {
        guard sfbAudioManager.isCarPlayEnvironment,
              usingSFBEngine else { return }

        print("🚗 CarPlay took over while SFBAudioEngine was playing - playback has stopped")
        let strandedTrack = currentTrack
        usingSFBEngine = false
        audioFile = nil
        isPlaying = false
        playbackState = .paused
        stopPlaybackTimer()
        endBackgroundMonitoring()
        // This track cannot come back while CarPlay is connected: a later
        // play() routes it to SFBAudioEngine again, which refuses CarPlay, and
        // there is no native fallback for these formats. Without a message the
        // user is left with a track still on screen, mid-song silence, and a
        // Play button that does nothing. Selecting a native-format track,
        // advancing, or unplugging still recovers the player.
        if let strandedTrack {
            playbackErrorMessage = loadFailureMessage(for: strandedTrack)
        }
        updateNowPlayingInfoEnhanced()
        updateWidgetData()
    }

    private func processMediaServicesReset() async {
        print("🔄 Media services were reset - need to recreate audio engine and nodes")

        // A media-services reset invalidates both engines. Preserve the user's
        // selection and position, but never preserve an active transport: Apple
        // requires playback to remain stopped until a new user action.
        let stateBeforeReset = playbackState
        let currentTime = nowPlayingElapsedTime()
        let currentTrackCopy = currentTrack
        let wasUsingSFBEngine = usingSFBEngine
        let recoveryIntentGeneration = playbackIntentGeneration
        let recoveryTrackID = currentTrackCopy?.stableId

        // Clean up current audio engine and nodes
        await cleanupAudioEngineForReset()
        isPlaying = false
        stopPlaybackTimer()
        endBackgroundMonitoring()

        // SFBAudioEngine owns its own AVAudioEngine, and mediaserverd taking
        // everything down leaves that one dead too. Reloading the track below
        // reuses the existing AudioPlayer, so it has to be rebuilt first.
        if wasUsingSFBEngine {
            sfbAudioManager.rebuildAfterMediaServicesReset()
        }

        // Recreate audio engine and nodes
        recreateAudioEngine()

        // Rebuild the decoder if possible, without claiming an output route.
        // The lock-screen/app Play command activates the session and starts the
        // appropriate engine later.
        if let track = currentTrackCopy {
            guard playbackIntentGeneration == recoveryIntentGeneration,
                  playbackIdentity(currentTrack?.stableId, matches: recoveryTrackID) else {
                // The old SFBAudioPlayer was destroyed above. Make a later
                // explicit play reload it instead of trying to resume an empty
                // replacement player.
                if wasUsingSFBEngine {
                    usingSFBEngine = false
                    audioFile = nil
                }
                return
            }

            let loaded = await loadTrack(
                track,
                preservePlaybackTime: true,
                configureOutputRoute: false
            )
            guard loaded else {
                if playbackIntentGeneration == recoveryIntentGeneration,
                   playbackIdentity(currentTrack?.stableId, matches: recoveryTrackID),
                   lastLoadFailureWasTransient {
                    schedulePendingCloudPlayback(track, autoplay: false)
                }
                return
            }

            guard playbackIntentGeneration == recoveryIntentGeneration,
                  playbackIdentity(currentTrack?.stableId, matches: recoveryTrackID) else { return }

            var restoredTime = currentTime
            if currentTime > 0, usingSFBEngine {
                // SFBAudioPlayer can reposition an enqueued decoder without
                // activating its AVAudioSession. The native backend only needs
                // its offsets restored; play() schedules from them after the
                // user explicitly resumes.
                do {
                    try sfbAudioManager.seek(to: min(currentTime, duration))
                } catch {
                    restoredTime = sfbAudioManager.currentTime
                    print("⚠️ Could not restore SFB position after media reset: \(error)")
                }
            }

            guard playbackIntentGeneration == recoveryIntentGeneration,
                  playbackIdentity(currentTrack?.stableId, matches: recoveryTrackID) else { return }

            seekTimeOffset = restoredTime
            playbackTime = restoredTime
            nodeTimelineStartSampleTime = 0
            isPlaying = false
            switch stateBeforeReset {
            case .stopped:
                playbackState = .stopped
            case .playing, .paused, .loading:
                playbackState = .paused
            }
            updateNowPlayingInfoEnhanced()
            updateWidgetData()
        }
    }

    private func processEngineConfigurationChange(_ changedEngineID: ObjectIdentifier) {
        // Only react to our own engine - SFBAudioEngine manages its own.
        guard changedEngineID == ObjectIdentifier(audioEngine) else { return }

        // Ignore the notification our own rebuild just caused.
        //
        // reconfigureAudioEngineForNewFormat() stops the engine, reconnects
        // playerNode -> EQ -> mixer and starts it again, and AVAudioEngine
        // posts a configuration change for exactly that. Treating it as
        // external damage makes the repair re-trigger itself: rebuild ->
        // notification -> "graph is stale" -> rebuild, restarting playback
        // every fraction of a second. The window is a timestamp rather than a
        // flag because the notification arrives on the engine's own queue and
        // only reaches this actor after the synchronous rebuild has returned.
        if let lastRebuild = lastSelfInducedGraphRebuildAt,
           Date().timeIntervalSince(lastRebuild) < Self.selfInducedConfigurationChangeWindow {
            print("🔧 Ignoring the configuration change our own graph rebuild caused")
            return
        }

        // Record it whatever else happens. The graph is now wired for hardware
        // that may no longer exist, and that is true regardless of whether we
        // are in a position to rebuild right now.
        nativeGraphNeedsReconfiguration = true

        guard !usingSFBEngine else { return }

        // Interruptions have their own began/ended recovery path.
        guard isPlaying, !isAudioSessionInterrupted else {
            // Nothing to restart while paused, and touching the route during an
            // interruption fights the app that owns it - so this cannot be
            // repaired here. But it must not be forgotten either: dropping the
            // notification outright is what left the graph describing the route
            // a navigation prompt had replaced, so the resume afterwards found
            // an engine that reported a successful start and then stopped
            // itself. SFBAudioPlayer reconnects its own mixer -> output here;
            // the flag above is how the native path catches up at resume.
            print("🔧 Audio engine configuration changed while idle - graph marked stale")
            return
        }

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
                  self.playbackIdentity(self.currentTrack?.stableId, matches: recoveryTrackID) else { return }

            let resumeTime = self.nowPlayingElapsedTime()
            self.playbackTime = resumeTime
            print("🔧 Audio engine configuration changed - restarting playback at \(resumeTime)s")

            // The engine has already stopped; go through the resume path so
            // the segment is scheduled once at the preserved position.
            self.isPlaying = false
            self.playbackState = .paused
            self.stopPlaybackTimer()
            self.continuePlaybackAfterAutomaticAction()
        }
    }

    private func cancelEngineConfigurationRecovery() {
        engineConfigurationRecoveryTask?.cancel()
        engineConfigurationRecoveryTask = nil
    }

    private func cancelOutputRouteSettleResume() {
        outputRouteSettleResumeTask?.cancel()
        outputRouteSettleResumeTask = nil
    }

    private func cancelOutputRouteRecovery() {
        outputRouteRecoveryGeneration &+= 1
        outputRouteRecoveryTask?.cancel()
        outputRouteRecoveryTask = nil
        isRecoveringOutputRoute = false
        // An explicit selection supersedes the route work entirely; a stale
        // pending flag must not re-arm a recovery behind it.
        hasPendingOutputRouteRecovery = false
    }

    private func processMemoryWarning() {
        print("⚠️ Memory warning received - cleaning up audio resources")

        // Clear cached artwork to free memory
        cachedArtwork = nil
        cachedArtworkTrackId = nil

        // Don't touch the audio engine if we're currently loading or playing
        // Stopping during a load causes the load to fail on large files
        if !isPlaying && !isLoadingTrack {
            // The preloaded next track is a whole open AVAudioFile.
            clearPreloadedNext()

            if usingSFBEngine {
                // SFBAudioEngine owns its own AVAudioEngine and keeps the
                // decoder open; this handler released neither. Clearing
                // usingSFBEngine/audioFile makes the next play() take its
                // reload branch, which restores the saved position.
                sfbAudioManager.stop()
                usingSFBEngine = false
                audioFile = nil
                print("🛑 Released SFBAudioEngine player due to memory pressure")
            } else {
                audioEngine.stop()
                playerNode.stop()
                print("🛑 Stopped audio engine due to memory pressure")
            }
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

        // Same reason as the notification observers: recreateAudioEngine()
        // clears hasSetupRemoteCommands, and MPRemoteCommand only ever adds
        // targets. A second registration made one Control Center "next" skip
        // two tracks.
        let commands: [MPRemoteCommand] = [
            cc.playCommand,
            cc.pauseCommand,
            cc.nextTrackCommand,
            cc.previousTrackCommand,
            cc.changePlaybackPositionCommand,
            cc.togglePlayPauseCommand
        ]
        for command in commands {
            command.removeTarget(nil)
        }

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

            let positionTime = e.positionTime
            print("🎯 CarPlay seek request to: \(positionTime)s")

            // A non-finite or negative position is the one thing that can be
            // judged without touching main-actor state, so reject it here.
            guard positionTime.isFinite, positionTime >= 0 else {
                return .commandFailed
            }

            // The seek itself has to hop to the main actor, so its result
            // cannot reach this return - the handler is deliberately NOT
            // assumed to be main-actor isolated (see the audio-session
            // observers: assuming it traps before Swift can hop). `.success`
            // here means "request accepted", not "position reached"; seek()
            // republishes the real position through
            // updateNowPlayingInfoEnhanced() on every refusal, which is what
            // actually stops the CarPlay/lock-screen scrubber from sitting at
            // a position the audio never reached.
            Task { @MainActor in
                if await self.seek(to: positionTime) {
                    print("✅ Seek completed to: \(positionTime)s")
                } else {
                    print("❌ Seek to \(positionTime)s was refused - position republished")
                }
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

    /// Reopens the artwork decision for the track that is currently showing.
    ///
    /// `lastWidgetArtworkTrackId` records that the shared image file is already
    /// correct for this track, which is only true for as long as the track's
    /// artwork does not change. It can: the scan extracts a cover for the first
    /// time, or re-extracts one after the file was retagged. That is especially
    /// likely for a track played during the very first scan, where the artwork
    /// lookup can legitimately answer nil and the widget then held that answer
    /// for as long as the track stayed selected.
    private func handleArtworkChanged(forTrack stableId: String) {
        guard currentTrack?.stableId == stableId,
              lastWidgetArtworkTrackId == stableId else {
            return
        }
        lastWidgetArtworkTrackId = nil
        updateWidgetData()
    }

    /// Publishes the transport state to the home-screen widget.
    ///
    /// Called from every state change there is - play, pause, stop, each track
    /// change, gapless promotion, CarPlay takeover, route recovery - so it has
    /// to be cheap. It was not: `PlayerEngine` is `@MainActor`, so the bare
    /// `Task` here inherited main-actor isolation and encoded the 1024px cover
    /// to PNG, read the artist from the database, wrote several megabytes into
    /// the App Group container and called `synchronize()`, all on the main
    /// thread - and it did the whole thing again on every pause and resume of
    /// the track already being displayed.
    func updateWidgetData() {
        // Stamped here, on the main actor, because this is the only place the
        // order of these updates is real. Cancelling `widgetUpdateTask` cannot
        // stop a detached save that has already begun executing - a detached
        // task does not inherit its parent's cancellation - so a clear and a
        // save can reach the App Group container in either order. The stamp
        // lets WidgetDataManager drop whichever one is stale.
        widgetUpdateSequence &+= 1
        let sequence = widgetUpdateSequence

        guard let track = currentTrack else {
            widgetUpdateTask?.cancel()
            widgetUpdateTask = nil
            lastWidgetArtworkTrackId = nil
            let manager = WidgetDataManager.shared
            Task.detached(priority: .utility) {
                manager.clearCurrentTrack(sequence: sequence)
                await MainActor.run { WidgetCenter.shared.reloadAllTimelines() }
            }
            return
        }

        // Read everything main-actor-bound up front, then hand plain values to
        // a detached task. cachedArtistName is the same memoised lookup the
        // lock screen uses, so the widget can no longer disagree with it.
        let artistName = cachedArtistName(for: track) ?? Localized.unknownArtist
        let colorHex = DeleteSettings.load().backgroundColorChoice.color.toHex()
        let widgetData = WidgetTrackData(
            trackId: track.stableId,
            title: track.title,
            artist: artistName,
            isPlaying: isPlaying,
            backgroundColorHex: colorHex
        )
        let needsArtwork = lastWidgetArtworkTrackId != track.stableId

        // Rapid transport taps coalesce onto the newest state rather than
        // queueing a re-encode each.
        widgetUpdateTask?.cancel()
        widgetUpdateTask = Task { @MainActor [weak self] in
            var artworkUpdate: WidgetDataManager.ArtworkUpdate = .unchanged

            if needsArtwork {
                let artwork = await ArtworkManager.shared.getArtwork(for: track)
                guard !Task.isCancelled else { return }

                // JPEG rather than PNG: the shared file is already named .jpg,
                // the widget decodes by content and not by extension, and
                // encoding a photographic cover losslessly cost both the time
                // and roughly ten times the bytes.
                let encoded: Data? = await Task.detached(priority: .utility) {
                    artwork?.jpegData(compressionQuality: 0.85)
                }.value
                guard !Task.isCancelled else { return }

                artworkUpdate = encoded.map { .replace($0) } ?? .clear
            }

            let manager = WidgetDataManager.shared
            let payload = widgetData
            let update = artworkUpdate
            await Task.detached(priority: .utility) {
                manager.saveCurrentTrack(payload, artwork: update, sequence: sequence)
            }.value

            // Only claim the cover is on disk once it actually is. Recording it
            // before the write meant a cancelled update left the flag asserting
            // an image that was never saved, and the next same-track update
            // then took the `.unchanged` path and left the previous track's
            // cover on the widget.
            //
            // `.clear` counts as up to date too: the shared file now correctly
            // represents this track, which simply has no cover. Resetting the
            // flag to nil made every later play/pause of that track re-run the
            // artwork lookup and the encode - exactly the work the flag exists
            // to avoid, on the tracks where it can never pay off.
            switch update {
            case .replace, .clear:
                self?.lastWidgetArtworkTrackId = track.stableId
            case .unchanged:
                break
            }

            guard !Task.isCancelled else { return }

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

        if let albumName = cachedAlbumName(for: track) {
            info[MPMediaItemPropertyAlbumTitle] = albumName
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

        // For background audio, avoid mixWithOthers - be the primary audio app.
        //
        // Deliberately WITHOUT .allowAirPlay. That option exists to switch
        // AirPlay on for `.playAndRecord`, where it is off by default; the
        // playback category already routes to AirPlay and rejects the option
        // outright with paramErr (-50). Because the call fails, the option
        // never appears in `categoryOptions` afterwards either - so a guard
        // that waits for it to show up can never be satisfied, and every
        // attempt re-submits the same rejected call. A2DP is likewise implicit
        // here and kept only because it is harmless and long-standing.
        let options: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP]

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
        //
        // Best-effort, deliberately not `try`: a category call the system
        // refuses must never stop us activating a session that is already
        // usable. When this propagated, one paramErr meant `setActive` below
        // was never reached at all - so Play did nothing, silently, for every
        // track for the whole session, on both engines.
        if s.category != .playback || (!isCarPlayEnvironment && s.mode != .default) {
            do {
                try setupAudioSessionCategory()
            } catch {
                print("⚠️ Could not reconfigure audio session category: \(error)")
            }
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

        // An SFB-only session installs the reset observer without ever building
        // the native graph. Avoid instantiating lazy native objects merely to
        // call methods whose AVAudioNode attachment preconditions are not met.
        guard hasSetupAudioEngine,
              audioEngine.attachedNodes.contains(playerNode) else {
            print("⏭️ Native audio graph was never attached - nothing to clean up")
            return
        }

        // Stop all audio activity
        playerNode.stop()
        audioEngine.stop()

        // Remove all connections
        audioEngine.detach(playerNode)

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
        nativeGraphNeedsReconfiguration = false
        lastSampleRate = 0
        hasSetupAudioSession = false
        hasSetupRemoteCommands = false
        hasSetupAudioSessionNotifications = false
        print("✅ Audio engine recreated successfully with EQ")
    }



    // MARK: - Playback Control

    @discardableResult
    func loadTrack(
        _ track: Track,
        preservePlaybackTime: Bool = false,
        configureOutputRoute: Bool = true,
        cancelOutputRouteRecovery: Bool = true,
        cancelPendingCloudRetry: Bool = true
    ) async -> Bool {
        // Observe route loss for the entire asynchronous load. Installing these
        // only after the decoder opened missed an unplug during first-ever
        // playback and then baselined the speaker route as if nothing changed.
        ensureAudioSessionNotificationsSetup()

        // A song chosen on the phone or CarPlay supersedes any delayed route
        // recovery. Otherwise the 150 ms recovery for the old route can wake
        // after the new selection and reschedule the wrong playback state.
        cancelEngineConfigurationRecovery()
        if cancelOutputRouteRecovery {
            self.cancelOutputRouteRecovery()
        }
        if cancelPendingCloudRetry {
            cancelPendingCloudPlayback()
        }
        lastLoadFailureWasTransient = false
        playbackErrorMessage = nil
        loadGeneration &+= 1
        let generation = loadGeneration

        currentLoadTask?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            return await self.performLoadTrack(
                track,
                preservePlaybackTime: preservePlaybackTime,
                configureOutputRoute: configureOutputRoute,
                generation: generation
            )
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

    @discardableResult
    private func beginPlaybackIntent(cancelActiveLoad: Bool = false) -> UInt64 {
        playbackIntentGeneration &+= 1
        // Migrations only need to bridge asynchronous work owned by the
        // previous intent. Dropping them here prevents a future file imported
        // at the old path-derived ID from being mistaken for the moved track.
        resolvedBookmarkIdentityAliases.removeAll(keepingCapacity: true)

        if cancelActiveLoad, currentLoadTask != nil || isLoadingTrack {
            loadGeneration &+= 1
            currentLoadTask?.cancel()
            currentLoadTask = nil
            isLoadingTrack = false

            if let securedURL = currentSecurityScopedURL {
                securedURL.stopAccessingSecurityScopedResource()
                currentSecurityScopedURL = nil
            }
            sfbAudioManager.stop()
            usingSFBEngine = false
            audioFile = nil
            lastLoadFailureWasTransient = false
        }

        return playbackIntentGeneration
    }

    /// Stop, then say why. `stop()` is what leaves the transport clean, but it
    /// also runs through `updateNowPlayingInfoEnhanced()`, so the message has
    /// to be set afterwards to survive.
    private func stopAndReportPlaybackFailure(_ message: String) {
        stop()
        playbackErrorMessage = message
    }

    /// Why `track` would not load, in the user's words.
    ///
    /// A format that needs SFBAudioEngine cannot play while CarPlay is
    /// connected - `SFBAudioEngineManager.load` refuses it by design and
    /// `performLoadTrack` has no native fallback - so the generic
    /// "moved or removed" message is actively misleading there. It is also the
    /// only failure the user can act on without leaving the car: pick a
    /// native-format track, or play this one from the phone.
    private func loadFailureMessage(for track: Track) -> String {
        guard isRefusedByCurrentRoute(track) else {
            return Localized.playbackTrackUnavailable
        }
        return Localized.playbackFormatNeedsPhone
    }

    /// Whether the current output route cannot play this track at all, for a
    /// reason that is knowable from the path alone.
    ///
    /// Only CarPlay qualifies: `SFBAudioEngineManager.load` refuses outright
    /// there and `performLoadTrack` has no native fallback for those formats,
    /// so the load is guaranteed to fail. Shared with
    /// `loadFirstPlayableTrack`, which skips such a track rather than paying
    /// for a load it knows will be refused, so the pre-check and the message
    /// that explains the refusal cannot drift apart.
    private func isRefusedByCurrentRoute(_ track: Track) -> Bool {
        sfbAudioManager.isCarPlayEnvironment
            && SFBAudioEngineManager.canHandle(url: URL(fileURLWithPath: track.path))
    }

    /// Surface a failure the user can act on, and leave the transport in a
    /// state they can recover from.
    private func reportPlaybackFailure(_ message: String) {
        playbackErrorMessage = message
        isPlaying = false
        playbackState = .stopped
        stopPlaybackTimer()
        endBackgroundMonitoring()
        updateNowPlayingInfoEnhanced()
        updateWidgetData()
    }

    private func cancelPendingCloudPlayback() {
        pendingCloudPlaybackGeneration &+= 1
        pendingCloudPlaybackTask?.cancel()
        pendingCloudPlaybackTask = nil
    }

    private func canonicalPlaybackStableId(_ stableId: String) -> String {
        var candidate = stableId
        var visited = Set<String>()

        while visited.insert(candidate).inserted,
              let replacement = resolvedBookmarkIdentityAliases[candidate],
              replacement != candidate {
            candidate = replacement
        }

        return candidate
    }

    /// Compares identities across any bookmark-driven path migrations that
    /// happened after an asynchronous caller captured its Track value.
    private func playbackIdentity(_ lhs: String?, matches rhs: String?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return canonicalPlaybackStableId(lhs) == canonicalPlaybackStableId(rhs)
    }

    /// Returns the live Track value, including its migrated path and stable ID,
    /// only while the original request still represents the selected queue row.
    private func selectedTrackForPendingCloudPlayback(_ requestedTrack: Track) -> Track? {
        guard let selectedTrack = currentTrack,
              playbackQueue.indices.contains(currentIndex),
              playbackIdentity(selectedTrack.stableId, matches: requestedTrack.stableId),
              playbackIdentity(playbackQueue[currentIndex].stableId, matches: requestedTrack.stableId) else {
            return nil
        }
        return selectedTrack
    }

    /// Leave a cloud-only track selected and resume the user's requested state
    /// as soon as its bytes land. A newer transport action cancels this task,
    /// so an old download can never steal playback later.
    ///
    /// - Parameter deadline: when this selection's wait must give up, retries
    ///   included. `nil` starts a fresh budget; the transient re-arm below
    ///   passes its own deadline through so the retries stay bounded.
    private func schedulePendingCloudPlayback(
        _ requestedTrack: Track,
        autoplay: Bool,
        deadline: Date? = nil
    ) {
        // An older load may finish after a newer selection. It must not cancel
        // the newer selection's pending retry merely because both returned
        // false around the same time.
        guard let track = selectedTrackForPendingCloudPlayback(requestedTrack) else { return }

        let retryDeadline = deadline
            ?? Date().addingTimeInterval(Self.pendingCloudRetryBudget)
        // A single wait never outlives the shared budget, so the last one to
        // run reports the stall rather than being cut short by the check below.
        let remaining = retryDeadline.timeIntervalSinceNow
        guard remaining > 0 else {
            print("⌛️ Gave up waiting for iCloud playback: \(track.title)")
            cancelPendingCloudPlayback()
            reportPlaybackFailure(Localized.playbackDownloadStalled)
            return
        }
        let stallTimeout = min(Self.pendingCloudStallTimeout, remaining)

        cancelPendingCloudPlayback()
        pendingCloudPlaybackGeneration &+= 1
        let pendingGeneration = pendingCloudPlaybackGeneration
        // Read at completion rather than captured, so pause() can demote the
        // wait to "load it, don't start it" instead of throwing it away.
        pendingCloudPlaybackShouldAutoplay = autoplay
        let url = URL(fileURLWithPath: track.path)

        isPlaying = false
        playbackState = .loading
        stopPlaybackTimer()
        endBackgroundMonitoring()
        updateNowPlayingInfoEnhanced()
        updateWidgetData()

        print("⏳ Waiting for iCloud download before playing: \(track.title)")
        pendingCloudPlaybackTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await self.cloudDownloadManager.waitUntilLocal(
                    url,
                    stallTimeout: stallTimeout
                )
                guard self.pendingCloudPlaybackGeneration == pendingGeneration,
                      self.selectedTrackForPendingCloudPlayback(track) != nil else {
                    return
                }

                let loaded = await self.loadTrack(
                    track,
                    preservePlaybackTime: false,
                    cancelPendingCloudRetry: false
                )
                guard self.pendingCloudPlaybackGeneration == pendingGeneration,
                      self.selectedTrackForPendingCloudPlayback(track) != nil else {
                    return
                }

                if loaded {
                    print("✅ iCloud track is ready: \(track.title)")
                    if self.pendingCloudPlaybackShouldAutoplay {
                        self.startPlaybackAfterAdvance()
                    } else {
                        self.markLoadedTrackPaused()
                    }
                } else if self.lastLoadFailureWasTransient {
                    // The ubiquitous status can briefly move back to pending
                    // between the readiness check and decoder open. Re-arm the
                    // cancellable wait instead of abandoning the selection -
                    // under the SAME deadline, so a status that keeps flapping
                    // cannot retry for ever.
                    self.schedulePendingCloudPlayback(
                        track,
                        autoplay: self.pendingCloudPlaybackShouldAutoplay,
                        deadline: retryDeadline
                    )
                    return
                } else {
                    self.reportPlaybackFailure(Localized.playbackTrackUnavailable)
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.pendingCloudPlaybackGeneration == pendingGeneration,
                      self.selectedTrackForPendingCloudPlayback(track) != nil else {
                    return
                }
                print("❌ Could not finish iCloud playback download: \(error)")
                // A stalled download is the common case here, and it is the one
                // that used to hang in .loading indefinitely.
                let message: String
                if case CloudDownloadError.downloadStalled = error {
                    message = Localized.playbackDownloadStalled
                } else {
                    message = Localized.playbackTrackUnavailable
                }
                self.reportPlaybackFailure(message)
            }

            if self.pendingCloudPlaybackGeneration == pendingGeneration {
                self.pendingCloudPlaybackTask = nil
            }
        }
    }

    private func performLoadTrack(
        _ track: Track,
        preservePlaybackTime: Bool,
        configureOutputRoute: Bool,
        generation: UInt64
    ) async -> Bool {
        // Determine actual format from file extension
        let url = URL(fileURLWithPath: track.path)
        // The extension, not a container inspection: this only names the format
        // in a log line, and reading headers here would run synchronously on the
        // main actor before ensureLocal - enough to stall on an iCloud
        // placeholder.
        print("📀 loadTrack called for: \(track.title) (format: \(url.pathExtension.uppercased()))")

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

                // Bookmark resolution may migrate a moved file's path-derived
                // stable ID. Keep every in-memory occurrence on the same key
                // immediately; otherwise this load succeeds but a repeat,
                // queue advance, shuffle restore, or favourite lookup in the
                // same session still uses the removed bookmark/database key.
                adoptResolvedBookmarkIdentity(for: track, at: resolvedURL)

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

            // Deliberately a short wait, not ensureLocal's 20s default. Anything
            // slower than this belongs to schedulePendingCloudPlayback, which
            // parks the selection in .loading, shows progress, keeps waiting
            // and reports a stall - whereas every second spent here is silent,
            // with the transport frozen on the previous track. Between the two
            // waits an unreachable file used to take well over a minute to say
            // anything at all.
            try await cloudDownloadManager.ensureLocal(
                url,
                downloadTimeout: Self.inlineCloudDownloadTimeout
            )
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

                // The counterpart of resetAudioEngineForNative() below. Only
                // playerNode was stopped for this transition, so our engine
                // kept its I/O running with nothing scheduled - and while the
                // process still has running audio objects,
                // AVAudioSession.setActive(false) answers `isBusy`. That is
                // exactly the call SFBAudioEngineManager makes before applying
                // the decoder's rate: for PCM the failure is swallowed and the
                // hardware keeps the previous track's rate, and for DoP it
                // propagates as the "route refused the carrier rate" path,
                // which records the file in doPRefusedPaths and permanently
                // downgrades it to PCM on this route.
                stopNativeEngineForSFBHandover()

                do {
                    try Task.checkCancellation()
                    // Prepare SFBAudioEngine for Opus, Vorbis, DSD. Loading is
                    // intentionally silent; the caller decides whether to play.
                    try await sfbAudioManager.load(url: url)
                    guard isCurrentLoad(generation) else {
                        sfbAudioManager.stop()
                        return false
                    }
                    usingSFBEngine = true
                    audioFile = nil

                    // Note: SFBAudioEngine now handles its own native EQ setup

                    // Sync duration from SFB engine
                    duration = sfbAudioManager.duration
                    isPlaying = false
                    print("🔄 PlayerEngine duration synced from SFBAudioEngine: \(duration)s")

                    print("✅ Delegated to SFBAudioEngine: \(url.lastPathComponent)")
                } catch {
                    print("❌ SFBAudioEngine delegation failed: \(error)")

                    // There is deliberately no "native fallback" for DSD here
                    // any more. AVAudioFile cannot read DSF/DFF at all, so
                    // openNativeAudioFile rejected them in its very first
                    // branch: the fallback could never succeed, it only turned
                    // one error into a more confusing one, and it never
                    // recomputed `duration` (which would have been left at the
                    // previous track's value). It also missed the most common
                    // DSD failure - decoder construction returning nil, which
                    // surfaces as manager code 1, not 1001.
                    print("❌ SFBAudioEngine failed and no fallback exists for this file type")
                    throw error
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
                // SFBAudioEngineManager configures its exact decoder session
                // immediately before play, so a silent load does not claim audio.
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
                    if !configureOutputRoute || isAudioSessionInterrupted {
                        // Deactivation/reactivation here would fight the app
                        // that owns the route. The next permitted play
                        // establishes the native category again.
                        hasSetupAudioSession = false
                    } else {
                        await resetAudioSessionForNative()
                    }
                    resetAudioEngineForNative()
                }

                if !configureOutputRoute || isAudioSessionInterrupted {
                    // Loading metadata/decoder state is harmless, but claiming
                    // the route or starting a graph is not. `play()` finishes
                    // setup only after the system permits it and the user asks.
                    hasSetupAudioSession = false
                    print("⏸️ Native decoder loaded without claiming the output route")
                } else {
                    // Activate the final route before building the graph. In a
                    // CarPlay launch, the inactive session can still report the
                    // phone speaker's format; constructing against that format and
                    // then activating CarPlay can crash AVAudioEngine.
                    ensureAudioSessionSetup()
                    var routeIsActive = true
                    do {
                        try activateAudioSession()
                    } catch {
                        print("⚠️ Could not activate native audio session before graph setup: \(error)")
                        routeIsActive = false
                        hasSetupAudioSession = false
                    }

                    if routeIsActive {
                        await configureAudioSession(for: audioFile!.processingFormat)
                        ensureAudioEngineSetup(with: audioFile!.processingFormat)
                    } else {
                        // Keep the decoder loaded, but do not construct a graph
                        // from a stale/inactive route. play() retries activation
                        // and performs setup after the system grants the route.
                        print("⏸️ Native decoder loaded without an active route - deferring engine setup")
                    }
                }
            }

            guard isCurrentLoad(generation) else { return false }

            // Ensure remote commands are set up for Control Center
            ensureRemoteCommandsSetup()

            // ...and the session observers. These used to be installed only by
            // the native cold-start branch of play(), so a session that went
            // straight to an Opus/Vorbis/DSD track had no route-change or
            // media-reset handling at all - unplugging headphones did not
            // pause, because nothing was listening for .oldDeviceUnavailable.
            ensureAudioSessionNotificationsSetup()

            // Force immediate Control Center update with new track info and reset timing
            lastControlCenterUpdate = 0
            updateNowPlayingInfoEnhanced()

            // Always idle here. A load never starts audio on either backend -
            // `cleanupCurrentPlayback` clears `isPlaying` on the way in and
            // `SFBAudioEngineManager.load()` enqueues its decoder silently -
            // so the caller decides what happens next. This used to be
            // `usingSFBEngine && isPlaying ? .playing : .stopped`, from when
            // the manager still exposed `loadAndPlay(url:)`.
            playbackState = .stopped
            isLoadingTrack = false
            return true

        } catch is CancellationError {
            if isCurrentLoad(generation) {
                sfbAudioManager.stop()
                usingSFBEngine = false
                playbackState = .stopped
                isLoadingTrack = false
                audioFile = nil
            }
            return false
        } catch {
            print("Failed to load track: \(error)")
            if isCurrentLoad(generation) {
                // Remember WHY, so the auto-advance can tell a track that will
                // never play from one whose bytes are simply still arriving.
                if case CloudDownloadError.downloadPending = error {
                    lastLoadFailureWasTransient = true
                }
                sfbAudioManager.stop()
                usingSFBEngine = false
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
        clearSFBGaplessNext()
        preloadNextTask?.cancel()
        preloadNextTask = nil
        nextAudioFile = nil
        nextTrack = nil
        nextTrackIndex = nil
        isPreloadingNext = false
        gaplessScheduled = false
        nextTimelineStartSampleTime = nil
    }

    /// Drops a gapless next segment that has already been handed to the player
    /// node.
    ///
    /// Clearing the preload references is not enough once `gaplessScheduled` is
    /// set: the next track's audio is physically queued behind the current one
    /// inside AVAudioPlayerNode and will play regardless of what the queue now
    /// says. The only way to take it back is to stop the node and re-schedule
    /// the current track's remainder from where it actually is, which is what
    /// the resume-from-pause and seek paths already do.
    private func invalidateGaplessSchedule() {
        guard gaplessScheduled else {
            clearPreloadedNext()
            return
        }

        print("♻️ Dropping already-scheduled gapless next track")

        guard !usingSFBEngine, let file = audioFile else {
            clearPreloadedNext()
            return
        }

        let resumeTime = currentTimeForCurrentNativeFile()
        let wasPlaying = isPlaying

        clearPreloadedNext()
        cancelPendingCompletions()
        playerNode.stop()

        // playerNode.stop() rewinds the node's own timeline, so the offset
        // bookkeeping has to be re-based exactly as the resume path does it.
        seekTimeOffset = resumeTime
        playbackTime = resumeTime
        nodeTimelineStartSampleTime = 0

        // The node has already been stopped, so every path out of here must
        // leave playback in a state the user can recover from. Bailing out
        // silently left a "playing" track with no audio and no way back.
        let frame = AVAudioFramePosition(resumeTime * file.processingFormat.sampleRate)

        guard audioEngine.isRunning,
              frame >= 0,
              frame < file.length,
              scheduleSegment(from: frame, file: file, track: currentTrack, trackIndex: currentIndex) else {
            if wasPlaying {
                // play() restarts the engine and re-schedules from
                // seekTimeOffset, which was re-based above.
                print("♻️ Re-scheduling failed - restarting playback from \(resumeTime)s")
                continuePlaybackAfterAutomaticAction()
            }
            return
        }

        if wasPlaying {
            playerNode.play()
        }
    }

    /// Call after anything changes which track should play next: the queue's
    /// contents, its order, or the loop mode.
    ///
    /// Gapless playback hands the successor to the player node several seconds
    /// early. Nothing used to revisit that decision, so "Play Next", a
    /// drag-reorder, a swipe-delete, turning song-loop on, or toggling shuffle
    /// all left the *old* successor's audio queued: it played anyway while
    /// currentIndex advanced to whatever now sat at the stored index.
    /// Variant for a removal: the tracks also have to leave the un-shuffled
    /// order, or turning shuffle off rebuilds the queue from a snapshot that
    /// still contains them and resurrects what the user just deleted.
    func queueDidRemoveTracks(_ removedTrackIds: [String]) {
        if !removedTrackIds.isEmpty {
            // One entry per removed row, not every row carrying that id. The
            // queue deliberately allows the same song more than once (see
            // normalizeIndexAndTrack), so deleting the second A in [A, B, A, C]
            // used to drop BOTH A's from the un-shuffled order: turning shuffle
            // off then rebuilt a queue with no A at all, and if A was playing,
            // restoreOriginalQueue could no longer find the current track and
            // fell back to a clamped index.
            var pendingRemovals: [String: Int] = [:]
            for stableId in removedTrackIds {
                pendingRemovals[stableId, default: 0] += 1
            }

            var remaining: [String] = []
            remaining.reserveCapacity(originalQueue.count)
            for stableId in originalQueue {
                if let count = pendingRemovals[stableId], count > 0 {
                    pendingRemovals[stableId] = count - 1
                    continue
                }
                remaining.append(stableId)
            }
            originalQueue = remaining
        }
        queueDidChange()
    }

    func queueDidChange() {
        if usingSFBEngine {
            sfbQueueDidChange()
            return
        }

        let expectedIndex = nextPlayableIndexForPreload()
        let expectedTrackId: String? = expectedIndex.flatMap {
            playbackQueue.indices.contains($0) ? playbackQueue[$0].stableId : nil
        }

        if nextTrack != nil {
            if nextTrackIndex == expectedIndex, nextTrack?.stableId == expectedTrackId {
                return
            }
            invalidateGaplessSchedule()
        } else if isPreloadingNext {
            // An in-flight preload was started against the old ordering.
            clearPreloadedNext()
        }

        preloadAndScheduleNextIfNeeded()
    }

    /// Same contract as queueDidChange() for the SFBAudioEngine path: anything
    /// that changes which track should play next has to revisit a successor
    /// that was already handed to SFBAudioPlayer, or the old one plays anyway
    /// while currentIndex advances to whatever now sits at the stored index.
    private func sfbQueueDidChange() {
        let expectedIndex = nextPlayableIndexForPreload()
        let expectedTrackId: String? = expectedIndex.flatMap {
            playbackQueue.indices.contains($0) ? playbackQueue[$0].stableId : nil
        }

        if sfbNextTrack != nil || sfbAudioManager.hasGaplessNextQueued {
            if sfbNextTrackIndex == expectedIndex, sfbNextTrack?.stableId == expectedTrackId {
                return
            }
            clearSFBGaplessNext()
        } else if sfbPreloadNextTask != nil {
            // An in-flight enqueue was started against the old ordering.
            clearSFBGaplessNext()
        }

        preloadAndScheduleNextIfNeeded()
    }

    /// Checks whether the interruption this engine believes it is under is
    /// still actually happening, and clears the latch when it is not.
    ///
    /// `isAudioSessionInterrupted` is raised by a `.began` notification and
    /// lowered only by the matching `.ended`. That `.ended` is not guaranteed:
    /// iOS does not deliver it to an app that stayed suspended for the whole
    /// interruption, and Siri and some alarms never send one at all. The latch
    /// then survived for the rest of the process and every Play - any track,
    /// either engine - deferred silently forever, with an app restart the only
    /// way out. The track had loaded fine; nothing said why it would not start.
    ///
    /// Activating the session is the only reliable test. It fails while another
    /// app genuinely holds a non-mixable session and succeeds once it does not,
    /// which is exactly the question being asked. Deliberately the bare
    /// `setActive` rather than `activateAudioSession()`: this is a probe, and it
    /// must not reconfigure the category out from under SFBAudioEngine, which
    /// sets up its own session moments later.
    private func reclaimSessionAfterMissedInterruptionEnd() {
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch {
            print("⏸️ Audio session is still genuinely interrupted: \(error)")
            return
        }

        print("✅ Interruption was already over - clearing a stale playback deferral")
        isAudioSessionInterrupted = false
        wasPlayingBeforeInterruption = false
        playWasDeferredByInterruption = false
    }

    func play() {
        // A fresh Play command is the one unambiguous signal that the user now
        // accepts the current route, including the built-in speaker. Automatic
        // continuations use the private entry point below and cannot clear an
        // unplug that happened while their decoder was loading.
        // It also supersedes media-reset recovery: if Play arrives while the
        // decoder is being rebuilt, that explicit request owns the final
        // transport state instead of the recovery path forcing it back to pause.
        beginPlaybackIntent()
        outputDeviceBecameUnavailable = false
        // This request supersedes any resume that was waiting on the route.
        cancelOutputRouteSettleResume()
        playRespectingOutputRoute()
    }

    private func continuePlaybackAfterAutomaticAction() {
        playRespectingOutputRoute()
    }

    private func playRespectingOutputRoute() {
        print("▶️ play() called - state: \(playbackState), loading: \(isLoadingTrack), usingSFBEngine: \(usingSFBEngine)")

        // The latch records an event; the route answers whether it still holds.
        refreshOutputDeviceAvailability()

        guard !outputDeviceBecameUnavailable else {
            print("🎧 Refusing automatic playback after the output device disappeared")
            pendingCloudPlaybackShouldAutoplay = false
            isPlaying = false
            playbackState = .paused
            stopPlaybackTimer()
            endBackgroundMonitoring()
            updateNowPlayingInfoEnhanced()
            updateWidgetData()
            return
        }

        // The interruption latch is only ever cleared by a matching `.ended`,
        // so verify it before obeying it - see reclaimSessionAfterMissedInterruptionEnd.
        if isAudioSessionInterrupted {
            reclaimSessionAfterMissedInterruptionEnd()
        }

        guard !isAudioSessionInterrupted else {
            // A decoder may finish loading while a call, alarm, or Siri owns the
            // session. Remember the requested autoplay, but do not activate the
            // session or start either engine until `.ended` explicitly permits
            // resumption.
            if currentTrack != nil || isLoadingTrack {
                playWasDeferredByInterruption = true
                isPlaying = false
                playbackState = .paused
                stopPlaybackTimer()
                endBackgroundMonitoring()
                updateNowPlayingInfoEnhanced()
                updateWidgetData()
            }
            print("⏸️ Deferring Play until the audio-session interruption ends")
            return
        }

        // Delegate to SFBAudioEngine if it's handling this track.
        //
        // Only while it actually is. `usingSFBEngine` is not cleared until the
        // replacement decoder is chosen, so during a load it still names a
        // player whose decoder cleanupCurrentPlayback has already released -
        // see isLoadInFlight. The deferred-load branch below owns this case.
        // `hasLoadedDecoder` matters as much as the flag: an interruption now
        // fully stops SFBAudioPlayer so the interrupting app can have the
        // route, which discards its decoder queue. Falling through to the
        // reload-and-seek branch below is exactly the right recovery.
        if usingSFBEngine, !isLoadInFlight, sfbAudioManager.hasLoadedDecoder {
            do {
                try sfbAudioManager.play()
                isPlaying = true
                playbackState = .playing
                startPlaybackTimer()
                startBackgroundMonitoring()
                print("✅ SFBAudioEngine resumed playback")
                updateNowPlayingInfoEnhanced()
                updateWidgetData()
                return
            } catch {
                print("❌ Failed to play with SFBAudioEngine: \(error)")

                // The route would not take this file's exact DoP carrier rate,
                // and it is not a proven DAC. The song is fine - only the
                // bit-exact delivery is impossible - so reload it as PCM rather
                // than reporting a DSD track the user cannot play. The manager
                // has recorded the refusal, so this load builds a PCM decoder.
                if SFBAudioEngineManager.isDoPFallbackRequired(error),
                   let track = currentTrack {
                    print("🎵 Reloading \(track.title) as PCM - the route refused the DoP carrier rate")
                    let resumeTime = playbackTime
                    let expectedIntent = playbackIntentGeneration
                    isPlaying = false
                    playbackState = .loading
                    updateNowPlayingInfoEnhanced()
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let loaded = await self.loadTrack(track, preservePlaybackTime: true)
                        guard self.playbackIntentGeneration == expectedIntent,
                              self.playbackIdentity(self.currentTrack?.stableId, matches: track.stableId) else { return }
                        guard loaded else {
                            self.reportPlaybackFailure(self.loadFailureMessage(for: track))
                            return
                        }
                        if resumeTime > 0 {
                            await self.seek(to: min(resumeTime, self.duration))
                            guard self.playbackIntentGeneration == expectedIntent,
                                  self.playbackIdentity(self.currentTrack?.stableId, matches: track.stableId) else { return }
                        }
                        self.continuePlaybackAfterAutomaticAction()
                    }
                    return
                }

                // Leave a coherent, recoverable state. Returning without
                // touching anything left the transport showing whatever it had
                // before - typically "playing", over silence.
                isPlaying = false
                playbackState = .paused
                stopPlaybackTimer()
                endBackgroundMonitoring()
                // ...and say so. Silence here is the same dead-Play-button as
                // the reload path below: the decoder is loaded, so nothing
                // retries and nothing explains why the transport went nowhere.
                // Deliberately NOT reportPlaybackFailure(): the decoder is
                // still loaded and another play() can succeed (a DoP session
                // that lost its exact rate retries on the next attempt), so
                // .paused is the honest state, not .stopped.
                if let track = currentTrack {
                    playbackErrorMessage = loadFailureMessage(for: track)
                }
                updateNowPlayingInfoEnhanced()
                updateWidgetData()
                return
            }
        }

        // If no audio file is loaded but we have a current track, load it first
        // Reached either with nothing loaded at all, or on the SFB path after an
        // interruption released its decoder. Both want the same thing: reload
        // the current track at its saved position and start it.
        if audioFile == nil && currentTrack != nil && !isLoadInFlight {
            let expectedPlaybackIntentGeneration = playbackIntentGeneration
            Task {
                guard let trackToLoad = self.currentTrack else { return }
                var loaded = true
                // If state was already restored but audioFile is nil (e.g., after interruption),
                // we need to reload the current track with preserved position
                if hasRestoredState {
                    print("🔄 Reloading track after interruption, preserving position: \(playbackTime)s")
                    let savedPosition = playbackTime
                    loaded = await loadTrack(trackToLoad, preservePlaybackTime: true)

                    // Restore position after reload
                    if loaded && savedPosition > 0 {
                        await seek(to: savedPosition)
                        print("✅ Restored position after reload: \(savedPosition)s")
                    }
                } else {
                    // First-time state restoration
                    await ensurePlayerStateRestored()
                    loaded = self.audioFile != nil || self.usingSFBEngine
                }

                // pause() deliberately lets the decoder finish loading, but it
                // changes the playback intent. Keep the useful loaded state
                // without letting this older Play request override the pause.
                // A different selection also changes the intent; in that case
                // its own load owns the transport state, so leave it untouched.
                guard self.playbackIntentGeneration == expectedPlaybackIntentGeneration else {
                    if loaded,
                       !self.isPlaying,
                       self.playbackIdentity(self.currentTrack?.stableId, matches: trackToLoad.stableId) {
                        self.isPlaying = false
                        self.playbackState = .paused
                        self.stopPlaybackTimer()
                        self.endBackgroundMonitoring()
                        self.updateNowPlayingInfoEnhanced()
                        self.updateWidgetData()
                    }
                    return
                }

                // After loading, try to play again
                if loaded {
                    self.continuePlaybackAfterAutomaticAction()
                } else if self.lastLoadFailureWasTransient {
                    self.schedulePendingCloudPlayback(trackToLoad, autoplay: true)
                } else {
                    // A hard failure here used to fall off the end of the
                    // Task: performLoadTrack leaves playbackState at .stopped
                    // with the track still selected and no message, so the
                    // Play button did nothing at all, said nothing, and did
                    // the same on every subsequent tap - loadTrack clears
                    // playbackErrorMessage on entry, so even a message left by
                    // an earlier path was wiped. Every sibling load path
                    // (playTrack, nextTrack, previousTrack, handleTrackEnd)
                    // already reports; this one was missed.
                    self.reportPlaybackFailure(self.loadFailureMessage(for: trackToLoad))
                }
            }
            return
        }

        // A load is still running, so there is nothing to start yet.
        //
        // Falling through to the guard below and returning was wrong whenever
        // the load had been paused mid-flight: `pause()` advances
        // `playbackIntentGeneration` precisely so an in-flight load cannot
        // start audio when it lands, and this call had no way to take that
        // back - it can neither start the decoder now nor tell the load's
        // caller that the user has changed their mind. The result was a track
        // that finished loading and then sat paused, with the Play button
        // apparently doing nothing until it was tapped a second time.
        //
        // Record the request by waiting on the load itself, then re-enter
        // play() once it has landed. The guards on the far side make this a
        // no-op if anything superseded the request in the meantime.
        if isLoadInFlight, let requestedTrack = currentTrack, let loadTask = currentLoadTask {
            let expectedIntent = playbackIntentGeneration
            print("▶️ Play requested during a load - will start \(requestedTrack.title) when it lands")
            Task { @MainActor [weak self] in
                _ = await loadTask.value
                guard let self,
                      // No newer pause, stop or selection since this request.
                      self.playbackIntentGeneration == expectedIntent,
                      self.playbackIdentity(self.currentTrack?.stableId, matches: requestedTrack.stableId),
                      !self.isLoadingTrack,
                      // The load's own caller may already have started it.
                      !self.isPlaying,
                      self.usingSFBEngine || self.audioFile != nil else { return }
                self.continuePlaybackAfterAutomaticAction()
            }
            return
        }

        guard let audioFile = audioFile,
              playbackState != .loading,
              !isLoadInFlight else {
            print("⚠️ Cannot play: audioFile=\(audioFile != nil), state=\(playbackState), loading=\(isLoadInFlight)")
            return
        }

        // Establish and activate the final output route before building a graph
        // that may have been deliberately deferred by an interruption.
        ensureAudioSessionSetup()

        do {
            try activateAudioSession()
        } catch {
            print("❌ Session activate failed: \(error)")
            // Never continue into AVAudioEngine with a route the system refused
            // to give us. That can report Playing over silence, or begin later
            // when an interruption ends even though the UI was marked paused.
            reportPlaybackFailure(Localized.playbackAudioUnavailable)
            return
        }

        // Set up audio engine only after session activation, using the format of
        // the route that is actually active now.
        ensureAudioEngineSetup(with: audioFile.processingFormat)

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

            guard startEngineAndScheduleSegment(
                from: framePosition,
                file: audioFile,
                context: "resume"
            ) else {
                // `.paused`, not `.stopped`. The decoder is loaded and the
                // position is preserved, so this is recoverable - and `.ended`
                // will only auto-resume from `.paused`. Reporting `.stopped`
                // here meant one failed resume locked out every later one: the
                // next navigation prompt saw `wasPlaying=false state=stopped`
                // and refused, for the rest of the session.
                print("❌ Nothing scheduled while resuming - staying paused so a later resume can retry")
                isPlaying = false
                playbackState = .paused
                stopPlaybackTimer()
                endBackgroundMonitoring()
                updateNowPlayingInfoEnhanced()
                updateWidgetData()
                return
            }

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

        // Only a non-positive length is actually invalid. The old upper bound
        // of 1e9 frames rejected perfectly good files as "invalid": about 87
        // minutes at 192kHz, 2.9 hours at 96kHz, 6.3 hours at 44.1kHz - i.e.
        // long classical recordings, concert rips and audiobooks. The real
        // ceiling is AVAudioFrameCount (UInt32), which scheduleSegment checks.
        guard audioFile.length > 0 else {
            print("❌ Invalid audio file length: \(audioFile.length)")
            return
        }

        // Decide where to start, then let startEngineAndScheduleSegment() own
        // both the engine and the scheduling - see its note on why they cannot
        // be separated.
        let currentPosition = playbackTime
        let firstFrame = AVAudioFramePosition(currentPosition * audioFile.processingFormat.sampleRate)

        let startFrame: AVAudioFramePosition
        if firstFrame > 0 && firstFrame < audioFile.length {
            // Continue from current position
            seekTimeOffset = currentPosition
            startFrame = firstFrame
            print("✅ Resuming playback from \(currentPosition)s (frame: \(firstFrame))")
        } else if playbackTime > 1.0 {
            // Past the beginning but outside the file's bounds - preserve the
            // position rather than silently restarting the track.
            seekTimeOffset = playbackTime
            startFrame = AVAudioFramePosition(playbackTime * audioFile.processingFormat.sampleRate)
            print("✅ Resuming playback from current position: \(playbackTime)s")
        } else {
            // Actually starting from beginning
            seekTimeOffset = 0
            playbackTime = 0
            startFrame = 0
            print("✅ Starting playback from beginning")
        }
        nodeTimelineStartSampleTime = 0

        let scheduled = startEngineAndScheduleSegment(
            from: startFrame,
            file: audioFile,
            context: "start"
        )

        // Starting the node with nothing scheduled reports "playing" over
        // silence for ever. scheduleSegment is the only place that enforces
        // the AVAudioFrameCount ceiling, so honour its answer.
        guard scheduled else {
            print("❌ Nothing scheduled - refusing to start the player node")
            playbackState = .stopped
            return
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
        // A manual pause during an interruption must cancel both forms of
        // automatic resume; otherwise `.ended(.shouldResume)` overrides the
        // user's transport decision.
        wasPlayingBeforeInterruption = false
        playWasDeferredByInterruption = false
        // Bump the intent so anything already in flight will not start audio
        // when it finishes, but do NOT tear the load down. Pause means "don't
        // play", not "forget what I selected": `cancelActiveLoad: true` here
        // stopped SFBAudioEngine and nilled audioFile/usingSFBEngine, so a
        // lock-screen pause during a load left nothing to resume.
        beginPlaybackIntent()
        cancelEngineConfigurationRecovery()
        cancelOutputRouteRecovery()
        cancelOutputRouteSettleResume()
        // Likewise the iCloud wait: demote it to "load it, don't start it"
        // rather than abandoning a download the user is still waiting on. The
        // selection stays, and Play works the moment the bytes land.
        pendingCloudPlaybackShouldAutoplay = false

        // Delegate to SFBAudioEngine if it's handling this track
        if usingSFBEngine {
            sfbAudioManager.pause()
            isPlaying = false
            playbackState = .paused
            stopPlaybackTimer()
            // Let the app suspend while paused - see the note in the native
            // pause path below.
            stopSilentPlaybackForPause()
            endBackgroundMonitoring()
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

        // Release everything that keeps the process awake. A paused player has
        // no reason to stay resident: the lock screen and Control Center are
        // driven by MPRemoteCommandCenter + MPNowPlayingInfoCenter, and iOS
        // resumes us to service a remote command. Previously we looped a
        // near-silent buffer here purely to dodge suspension, which pinned the
        // audio route awake indefinitely and kept every timer below alive -
        // the app effectively never slept after a pause.
        stopSilentPlaybackForPause()
        endBackgroundMonitoring()

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
        wasPlayingBeforeInterruption = false
        playWasDeferredByInterruption = false
        beginPlaybackIntent(cancelActiveLoad: true)
        cancelEngineConfigurationRecovery()
        cancelOutputRouteRecovery()
        cancelOutputRouteSettleResume()
        cancelPendingCloudPlayback()
        cancelPendingCompletions()
        clearPreloadedNext()
        if usingSFBEngine {
            sfbAudioManager.stop()
            usingSFBEngine = false
            audioFile = nil
        } else {
            playerNode.stop()
        }
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
        // ...and the widget with it. Every other terminal state - pause(),
        // markLoadedTrackPaused(), reportPlaybackFailure() - publishes both,
        // and stop() is no longer a rare path: nextTrack() ends here whenever
        // Next is pressed on the last track with repeat off, and so does
        // stopAndReportPlaybackFailure(). Without this the widget was left
        // asserting the last track was still playing.
        updateWidgetData()

        // Don't clear remote commands during track transitions - keep Control Center connected
        // Remote commands should only be cleared when the app is truly shutting down
        print("🎛️ Keeping remote commands connected for Control Center")

        // stop() is a terminal transport path (including natural queue end),
        // not the cleanup used between tracks. Hand audio focus back now so
        // the app Cosmos interrupted can resume. Keeping Now Playing metadata
        // and remote commands does not require an active audio session.
        releaseAudioSessionAfterTerminalStop()

        // Save state when stopping
        savePlayerState()
    }

    private func releaseAudioSessionAfterTerminalStop() {
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
            hasSetupAudioSession = false
            print("🎧 Released audio session after terminal stop")
        } catch {
            // Keep the transport stopped even if mediaserverd is temporarily
            // unavailable. A later activation always retries setup.
            hasSetupAudioSession = false
            print("⚠️ Could not release audio session after terminal stop: \(error)")
        }
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
        } else if hasSetupAudioEngine,
                  audioEngine.attachedNodes.contains(playerNode) {
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

    /// - Returns: whether the audio actually moved. Callers that publish a
    ///   position - the scrubber, the CarPlay/lock-screen timeline - must not
    ///   assume it did: a refused seek leaves the decoder where it was.
    @discardableResult
    func seek(to time: TimeInterval) async -> Bool {
        print("⏪ seek(to: \(time)) called - usingSFBEngine: \(usingSFBEngine)")
        // NOTE: the preloaded/scheduled next track is deliberately NOT dropped
        // here. This used to be the first line of the method, above every
        // validity guard, so a seek that was then refused - scrubbing to the
        // very end of a track, which lands past the last frame - cleared
        // gaplessScheduled and nextTrack while the successor's audio was still
        // physically queued inside AVAudioPlayerNode. It played anyway, and
        // because promoteGaplessNextIfAvailable() no longer recognised it,
        // handleTrackEnd() then loaded the same track again from scratch: the
        // next song audibly started twice. A refused seek changes nothing, so
        // the arm must survive it; the accepted path clears it below, right
        // where playerNode.stop() physically takes the audio back.

        // Delegate to SFBAudioEngine if it's handling this track - and, as in
        // play(), only while it still is. Seeking a player whose decoder the
        // in-flight load has already released cannot move any audio; refusing
        // below republishes the real position instead of reporting a seek that
        // did not happen.
        if usingSFBEngine, !isLoadInFlight, sfbAudioManager.hasLoadedDecoder {
            do {
                try sfbAudioManager.seek(to: time)
                playbackTime = time
                print("✅ SFBAudioEngine seeked to: \(time)s")
                updateNowPlayingInfoEnhanced()
                return true
            } catch {
                print("❌ Failed to seek with SFBAudioEngine: \(error)")
                // The decoder did not move, so republish where it actually is.
                // Otherwise the scrubber and the CarPlay/lock-screen timeline
                // sit at a position the audio never reached until the next
                // position poll drags them back.
                playbackTime = sfbAudioManager.currentTime
                updateNowPlayingInfoEnhanced()
                return false
            }
        }

        // Nothing is loaded but a track is still selected. That is not only
        // the cold-launch case it was written for: a CarPlay takeover and the
        // memory-warning cleanup both release the decoder and leave the
        // selection in place, long after hasRestoredState was set - and
        // ensurePlayerStateRestored() is a one-shot that returns immediately
        // once it is. The guard below then dropped the seek silently, so the
        // scrubber and the CarPlay/lock-screen timeline were inert until
        // playback happened to be started some other way. Reload for real.
        if !usingSFBEngine, audioFile == nil, !isLoadInFlight, let track = currentTrack {
            if hasRestoredState {
                print("🔄 Nothing loaded for \(track.title) - reloading before seeking")
                guard await loadTrack(track, preservePlaybackTime: true) else {
                    if lastLoadFailureWasTransient {
                        // autoplay: false - a scrub is not a request to start.
                        schedulePendingCloudPlayback(track, autoplay: false)
                    } else {
                        reportPlaybackFailure(loadFailureMessage(for: track))
                    }
                    return false
                }
                // The reload may have landed on the other backend (an SFB
                // format that is playable again now CarPlay is gone), so route
                // this seek through the whole method rather than falling into
                // the native path below.
                return await seek(to: time)
            }
            await ensurePlayerStateRestored()
            if usingSFBEngine { return await seek(to: time) }
        }

        guard let audioFile = audioFile,
              !isLoadInFlight else {
            print("⚠️ Cannot seek: audioFile=\(audioFile != nil), loading=\(isLoadInFlight)")
            // The decoder did not move - and during a load `audioFile` can
            // still be the previous track's. Republish where playback actually
            // is so the scrubber and the CarPlay/lock-screen timeline do not
            // sit at a position nothing reached.
            updateNowPlayingInfoEnhanced()
            return false
        }

        let framePosition = AVAudioFramePosition(time * audioFile.processingFormat.sampleRate)
        let wasPlaying = isPlaying

        // Ensure framePosition is valid
        guard framePosition >= 0 && framePosition < audioFile.length else {
            print("❌ Invalid seek position: \(framePosition), file length: \(audioFile.length)")
            // The decoder has not moved, so republish where it actually is -
            // same reason as the SFBAudioEngine refusal above.
            updateNowPlayingInfoEnhanced()
            return false
        }

        print("🔍 Seeking to: \(time)s (frame: \(framePosition))")

        // Ensure audio engine is set up before seeking with file's format
        ensureAudioEngineSetup(with: audioFile.processingFormat)

        cancelPendingCompletions()
        playerNode.stop()
        // The node has now dropped every scheduled segment, including any
        // gapless successor, so the bookkeeping can safely follow it.
        clearPreloadedNext()

        // Update seek offset and playback time
        seekTimeOffset = time
        playbackTime = time
        nodeTimelineStartSampleTime = 0
        guard startEngineAndScheduleSegment(
            from: framePosition,
            file: audioFile,
            context: "seek"
        ) else {
            print("❌ Seek could not schedule audio - refusing to report playback")
            isPlaying = false
            // Same reasoning as the resume path: the decoder is still loaded,
            // so `.paused` keeps this recoverable by an interruption end.
            playbackState = .paused
            stopPlaybackTimer()
            endBackgroundMonitoring()
            updateNowPlayingInfoEnhanced()
            updateWidgetData()
            return false
        }

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
        return true
    }

    // NOTE: startSilentPlaybackForPause() used to live here. It looped a
    // near-silent buffer forever (numberOfLoops = -1) so the process would not
    // be suspended while paused. That defeated the whole point of pausing: the
    // audio route stayed powered and the app kept running indefinitely. Pausing
    // now simply lets the app suspend. Playback control while suspended is
    // handled by MPRemoteCommandCenter, which iOS resumes us to service.
    // stopSilentPlaybackForPause() is retained so a player left running by a
    // previously-installed build is torn down on the next pause/stop.

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

        let scheduledGeneration = scheduleGeneration
        let scheduledTrackId = track?.stableId
        let scheduledIndex = trackIndex

        // AVAudioFrameCount is UInt32, but AVAudioFile.length is Int64. Queue
        // consecutive chunks so multi-hour high-rate files are not rejected
        // merely because their remaining frame count exceeds UInt32.max.
        var chunkStart = startFrame
        var chunkCount = 0
        while chunkStart < file.length {
            let framesLeft = file.length - chunkStart
            let framesInChunk = AVAudioFrameCount(
                min(framesLeft, AVAudioFramePosition(AVAudioFrameCount.max))
            )
            let isFinalChunk = chunkStart + AVAudioFramePosition(framesInChunk) >= file.length

            playerNode.scheduleSegment(
                file,
                startingFrame: chunkStart,
                frameCount: framesInChunk,
                at: nil,
                completionCallbackType: .dataPlayedBack
            ) { [weak self] _ in
                guard isFinalChunk, let self else { return }
                Task { @MainActor [weak self] in
                    await self?.handleScheduledSegmentFinished(
                        generation: scheduledGeneration,
                        trackStableId: scheduledTrackId,
                        trackIndex: scheduledIndex
                    )
                }
            }

            chunkStart += AVAudioFramePosition(framesInChunk)
            chunkCount += 1
        }

        print("✅ Successfully scheduled audio: startFrame=\(startFrame), frameCount=\(remaining), chunks=\(chunkCount)")

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

    /// Whether the successor's bytes are already on the device - and, when they
    /// are not, asks iCloud to start materialising them.
    ///
    /// Both preload paths refuse to arm gapless playback for a file that is not
    /// local, which is correct: decoding one that is still arriving competes
    /// with the track being played. But leaving the fetch until the transition
    /// meant every boundary on an optimised-storage library paid the load's own
    /// `inlineCloudDownloadTimeout` of silence and then dropped into the parked
    /// `.loading` state. Requesting it here - `downloadTimeout: 0` only asks and
    /// returns, it never waits - means the file is usually resident by the time
    /// the boundary arrives, so the ordinary transition succeeds inline.
    ///
    /// Skipped in Low Power Mode, where speculative network work is precisely
    /// what the user has asked the device not to do.
    ///
    /// The residency check runs off the main actor: `isDownloaded` is
    /// `@MainActor` and does synchronous `resourceValues` I/O plus logging, and
    /// this is called once per track change on both backends.
    private func successorIsLocal(_ url: URL) async -> Bool {
        let isResident = await Task.detached(priority: .utility) {
            CloudDownloadManager.isLocallyResident(url)
        }.value
        guard !isResident else { return true }

        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { return false }
        // try? on purpose: a cloud-only successor answers .downloadPending,
        // which is the expected outcome and not an error worth propagating.
        try? await cloudDownloadManager.ensureLocal(url, downloadTimeout: 0)
        return false
    }

    private func preloadAndScheduleNextIfNeeded() {
        if usingSFBEngine {
            preloadAndEnqueueSFBNextIfNeeded()
            return
        }

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

            // Avoid holding security-scoped resources for a future track. If
            // resolving the bookmark migrated a moved file's identity, adopt
            // it now even though this speculative preload will not open it.
            if let resolvedURL = await LibraryIndexer.shared.resolveBookmarkForTrack(candidate) {
                self.adoptResolvedBookmarkIdentity(for: candidate, at: resolvedURL)
                self.isPreloadingNext = false
                return
            }

            // Never *waits* on a fetch - decoding a file that is still arriving
            // would compete with the track actually playing, and this used to
            // call ensureLocal() with its default 20s timeout, which waits. But
            // the request is started here rather than left to the transition;
            // see successorIsLocal().
            guard await self.successorIsLocal(url) else {
                self.isPreloadingNext = false
                return
            }

            do {
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

    /// The SFBAudioEngine counterpart of preloadAndScheduleNextIfNeeded().
    /// Hands the successor to SFBAudioPlayer's decoder queue so Opus/Vorbis
    /// albums run together the way FLAC and MP3 ones already do.
    private func preloadAndEnqueueSFBNextIfNeeded() {
        guard usingSFBEngine,
              isPlaying,
              sfbPreloadNextTask == nil,
              !sfbAudioManager.hasGaplessNextQueued,
              let nextIndex = nextPlayableIndexForPreload(),
              playbackQueue.indices.contains(nextIndex) else {
            return
        }

        let candidate = playbackQueue[nextIndex]
        let url = URL(fileURLWithPath: candidate.path)

        // Only another SFB-native track can continue on the same player; a
        // FLAC or MP3 successor belongs to AVAudioEngine and needs the normal
        // transition.
        guard SFBAudioEngineManager.canHandle(url: url) else { return }

        let preloadGeneration = loadGeneration
        sfbPreloadGeneration &+= 1
        let taskGeneration = sfbPreloadGeneration
        sfbPreloadNextTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                // Only release the handle if it is still this task's. A
                // cancelled run finishes after its replacement has started.
                if self.sfbPreloadGeneration == taskGeneration {
                    self.sfbPreloadNextTask = nil
                }
            }

            // Never hold a security-scoped resource open for a track that is
            // only a candidate - same rule as the native preload. Still adopt
            // any path-derived ID migration performed by bookmark resolution.
            if let resolvedURL = await LibraryIndexer.shared.resolveBookmarkForTrack(candidate) {
                self.adoptResolvedBookmarkIdentity(for: candidate, at: resolvedURL)
                return
            }

            // Never waits on a fetch - same rule as the native preload - but
            // does start the request. See successorIsLocal().
            guard await self.successorIsLocal(url) else { return }

            do {
                let enqueued = try await self.sfbAudioManager.enqueueGaplessNext(url: url)
                guard enqueued else { return }

                guard self.loadGeneration == preloadGeneration,
                      self.playbackQueue.indices.contains(nextIndex),
                      self.playbackQueue[nextIndex].stableId == candidate.stableId else {
                    self.sfbAudioManager.clearGaplessNext()
                    return
                }

                self.sfbNextTrack = candidate
                self.sfbNextTrackIndex = nextIndex
            } catch is CancellationError {
                self.sfbAudioManager.clearGaplessNext()
            } catch {
                print("ℹ️ Could not enqueue an SFBAudioEngine successor: \(error)")
                self.sfbAudioManager.clearGaplessNext()
            }
        }
    }

    /// Adopts the successor SFBAudioPlayer has just started rendering. No audio
    /// work happens here - the transition has already occurred.
    private func promoteSFBGaplessTrack(_ url: URL) {
        guard usingSFBEngine else { return }

        // Prefer the exact queue slot that was enqueued, for the same reason
        // promoteGaplessNextIfAvailable() does: the same song may sit in the
        // queue more than once, and resolving by identity alone would snap the
        // second A in [A, B, A, C] back to index 0.
        let resolvedIndex: Int?
        if let next = sfbNextTrack {
            let scheduledIndex = sfbNextTrackIndex.flatMap { index in
                playbackQueue.indices.contains(index)
                    && playbackQueue[index].stableId == next.stableId ? index : nil
            }
            resolvedIndex = scheduledIndex
                ?? playbackQueue.firstIndex { $0.stableId == next.stableId }
        } else {
            resolvedIndex = playbackQueue.firstIndex { $0.path == url.path }
        }

        guard let index = resolvedIndex, playbackQueue.indices.contains(index) else {
            // The queue moved out from under the transition. The audio is
            // already playing, so leave it be rather than fighting it.
            print("⚠️ Gapless successor is no longer in the queue - leaving the index alone")
            sfbNextTrack = nil
            sfbNextTrackIndex = nil
            return
        }

        currentIndex = index
        currentTrack = playbackQueue[index]
        sfbNextTrack = nil
        sfbNextTrackIndex = nil

        duration = sfbAudioManager.duration
        playbackTime = 0
        seekTimeOffset = 0
        // Follow the player rather than asserting: a pause landing on the
        // boundary still lets the already-rendered frames roll into the
        // successor, and claiming "playing" there would desync the transport.
        if sfbAudioManager.isPlaying {
            isPlaying = true
            playbackState = .playing
        }

        resetNowPlayingCachesForTrackChange()
        lastControlCenterUpdate = 0
        updateNowPlayingInfoEnhanced()
        updateWidgetData()

        // Chain into the one after it.
        preloadAndScheduleNextIfNeeded()
    }

    /// Drops both the queued decoder and our bookkeeping for it.
    private func clearSFBGaplessNext() {
        sfbPreloadGeneration &+= 1
        sfbPreloadNextTask?.cancel()
        sfbPreloadNextTask = nil
        // Asked BEFORE our own record is dropped. If the successor has already
        // started rendering, clearGaplessNext() promotes it rather than
        // dropping it, and promoteSFBGaplessTrack() needs sfbNextTrackIndex to
        // resolve the exact queue slot - resolving by identity alone picks the
        // first copy of a song that appears more than once. The promotion
        // clears both fields itself, so the assignments below stay correct
        // either way.
        sfbAudioManager.clearGaplessNext()
        sfbNextTrack = nil
        sfbNextTrackIndex = nil
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
              let next = nextTrack else {
            return false
        }

        // Prefer the exact queue slot that was scheduled. The same track may
        // appear more than once, so resolving by stableId first would snap the
        // second A in [A, B, A, C] back to index 0 and advance to B again. If
        // the queue was edited after scheduling, only trust the captured index
        // while it still contains the scheduled track, then fall back to
        // locating that track in the edited queue.
        let scheduledIndex = nextTrackIndex.flatMap { index in
            playbackQueue.indices.contains(index)
                && playbackQueue[index].stableId == next.stableId ? index : nil
        }
        let resolvedIndex = scheduledIndex
            ?? playbackQueue.firstIndex { $0.stableId == next.stableId }
            ?? currentIndex

        currentIndex = resolvedIndex
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
              !isAdvancingTrack,
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
                    // Release only the expiring task assertion. The check timer
                    // must survive it: the `audio` background mode keeps us
                    // running well past this ~30s deadline, and that timer is
                    // the only thing maintaining playbackTime (and detecting
                    // track ends) while backgrounded. Invalidating it here left
                    // the position frozen for the rest of the track, so an
                    // interruption resumed from a stale offset.
                    self?.endBackgroundTaskAssertion()
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
        endBackgroundTaskAssertion()
    }

    private func endBackgroundTaskAssertion() {
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

    // NOTE: maintainAudioSessionForBackground() used to live here. It force-
    // reactivated the audio session while paused "to prevent termination" -
    // the same keep-alive anti-pattern as the silent player, and its only
    // caller was that player's error path. Being suspended while paused is the
    // correct outcome, so it has been removed rather than left to be re-wired.

    private func checkIfTrackEnded() async {
        // Check if audio has finished playing. An end-of-track transition
        // already in flight owns the queue until it settles - this timer must
        // not promote or advance underneath it.
        guard isPlaying, !isAdvancingTrack, !isLoadingTrack else { return }

        if usingSFBEngine {
            playbackTime = sfbAudioManager.currentTime
            // With a successor queued the player renders straight through the
            // boundary and reports the change through nowPlayingChanged.
            // Advancing here instead would tear the player down and reload the
            // track that is about to start on its own.
            guard !sfbAudioManager.hasGaplessNextQueued else { return }
            if !sfbAudioManager.isPlaying || (duration > 0 && playbackTime >= duration) {
                await handleSFBPlaybackEnded()
            }
            return
        }

        // Keep the cached position fresh from the render timeline. This timer
        // is the only thing maintaining playbackTime while backgrounded - the
        // 0.25s UI timer is deliberately not started there - and the cached
        // value is what an interruption resumes from: by the time
        // AVAudioSession delivers .began, iOS has already stopped the engine,
        // so currentTimeForCurrentNativeFile() can no longer read the node and
        // falls back to playbackTime. Without this refresh that value is frozen
        // at whatever it held when the app was backgrounded, and a nav prompt
        // (Waze, Maps) or a call rewinds the track on resume - back to 0 if the
        // app was backgrounded soon after playback started.
        if audioFile != nil, audioEngine.isRunning {
            playbackTime = currentTimeForCurrentNativeFile()
        }

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

            // Only a genuinely finished track. This used to fire at
            // duration - 0.2, and handleTrackEnd() -> loadTrack ->
            // cleanupCurrentPlayback stops the player node, which discards the
            // audio still sitting in it: the last 200ms of every track without
            // a gapless successor - the last track in the queue, or one whose
            // successor made canGaplesslySchedule refuse on format - was cut.
            // Both real detectors (the .dataPlayedBack completion handler and
            // the node-stopped check above) already catch a natural end; this
            // is only the fallback for when neither is delivered, so it needs
            // no margin beyond a float-comparison epsilon.
            if currentTime >= duration - 0.02 && duration > 0 {
                guard !gaplessScheduled else { return }
                // isAdvancingTrack, set synchronously by handleTrackEnd, prevents
                // duplicate triggers. Keep isPlaying true until that transition
                // owns the database and cleanup publishes the transport change.
                await handleTrackEnd()
            }
        }
    }

    private func handleSFBPlaybackEnded() async {
        guard usingSFBEngine, isPlaying, !isLoadingTrack else { return }
        guard !sfbAudioManager.hasGaplessNextQueued else { return }

        playbackTime = sfbAudioManager.currentTime
        stopPlaybackTimer()
        endBackgroundMonitoring()
        // Keep the published playing state until handleTrackEnd has installed
        // its transition guard. Otherwise the database coordinator can suspend
        // between this await and the next track's bookmark/path migration.
        await handleTrackEnd()
    }

    /// Rebuilds SFBAudioEngine playback that is running but producing nothing.
    ///
    /// `AudioPlayer.isPlaying` is intent, not output. After a Bluetooth
    /// navigation prompt the player can resume itself onto the hands-free
    /// graph (16kHz mono) and stay wired to it after the car has returned to
    /// A2DP, at which point it renders into a route that no longer exists: the
    /// transport says playing, the lock screen says playing, and the position
    /// never moves. Reloading the decoder re-establishes the graph against the
    /// route that actually exists - the SFB equivalent of what
    /// `startEngineAndScheduleSegment()` does for the native engine.
    private func recoverStalledSFBPlayback() async {
        guard usingSFBEngine,
              isPlaying,
              !isLoadInFlight,
              !isAdvancingTrack,
              !isAudioSessionInterrupted,
              let track = currentTrack else { return }

        // A rebuild that stalls again must not spin. One attempt per window;
        // if it does not take, playback stays where it is and the user can
        // start it again by hand.
        if let last = lastStalledSFBRecoveryAt,
           Date().timeIntervalSince(last) < Self.stalledSFBRecoveryCooldown {
            return
        }
        lastStalledSFBRecoveryAt = Date()

        let resumeTime = playbackTime
        let intentGeneration = playbackIntentGeneration
        print("♻️ Rebuilding stalled SFBAudioEngine playback for \(track.title) at \(resumeTime)s")

        let loaded = await loadTrack(track, preservePlaybackTime: true)
        guard playbackIntentGeneration == intentGeneration,
              playbackIdentity(currentTrack?.stableId, matches: track.stableId) else { return }
        guard loaded else {
            reportPlaybackFailure(loadFailureMessage(for: track))
            return
        }

        if resumeTime > 0 {
            await seek(to: min(resumeTime, duration))
            guard playbackIntentGeneration == intentGeneration,
                  playbackIdentity(currentTrack?.stableId, matches: track.stableId) else { return }
        }
        continuePlaybackAfterAutomaticAction()
    }

    private func handleSFBPlaybackFailure(_ error: Error) {
        guard usingSFBEngine else { return }

        print("❌ Current SFBAudioEngine decoder failed: \(error)")
        beginPlaybackIntent(cancelActiveLoad: true)
        cancelEngineConfigurationRecovery()
        cancelOutputRouteRecovery()
        cancelOutputRouteSettleResume()
        cancelPendingCloudPlayback()
        sfbAudioManager.stop()
        usingSFBEngine = false
        audioFile = nil
        reportPlaybackFailure(Localized.playbackTrackUnavailable)
    }

    // MARK: - Index Normalization Helper

    /// Loads `startIndex`, and if it will not play, walks the queue in `step`
    /// direction looking for something that will. Returns the terminal result,
    /// leaving `currentIndex` on the track that loaded or is still downloading.
    ///
    /// Every automatic advance used to be `guard loaded else { return }`, so a
    /// single unplayable entry ended playback outright with no message: a file
    /// that went missing, one iCloud has not materialised, or - on CarPlay,
    /// where SFBAudioEngine is refused - any Opus/Vorbis/DSD track, which a
    /// queue built on the phone before plugging in still contains.
    private enum QueueLoadResult {
        case loaded
        case pendingDownload
        case exhausted
        case superseded
    }

    private func loadFirstPlayableTrack(
        from startIndex: Int,
        step: Int,
        wraps: Bool,
        autoplayWhenDownloadCompletes: Bool,
        intentGeneration: UInt64
    ) async -> QueueLoadResult {
        guard playbackIntentGeneration == intentGeneration else { return .superseded }
        guard !playbackQueue.isEmpty else { return .exhausted }

        var candidate = startIndex
        var attempts = 0
        // Bounded by the queue as it was when the walk began. The live queue is
        // re-read every iteration (below), so this is only a loop guard.
        //
        // `count` rather than `count - 1` on purpose: when `wraps` is true the
        // walk is allowed to come back around to the track it started from and
        // load it again. That is the right answer for queue loop - if every
        // other entry is unplayable, a looping queue containing one playable
        // song should play that song - and it is the only thing that keeps a
        // single-track repeat-all queue working at all. It is never reached
        // with repeat off, because the walk then stops at the end instead of
        // wrapping.
        let limit = playbackQueue.count

        while attempts < limit {
            guard playbackIntentGeneration == intentGeneration else { return .superseded }

            // Deliberately NOT a snapshot taken before the loop. `loadTrack`
            // suspends, and a queue edit during that suspension does not bump
            // playbackIntentGeneration - so a stale copy could pick a row that
            // had since been removed or reordered, and assign `currentIndex` a
            // position that no longer holds it.
            guard !playbackQueue.isEmpty else { return .exhausted }

            if !playbackQueue.indices.contains(candidate) {
                guard wraps else { break }
                candidate = step < 0 ? playbackQueue.count - 1 : 0
            }

            let track = playbackQueue[candidate]

            // Refused before the load rather than by it. Every rejected
            // candidate otherwise costs a full `loadTrack`: a
            // `cleanupCurrentPlayback` including its 10ms settle, a published
            // transport change, and a round trip into SFBAudioEngineManager -
            // and on CarPlay every Opus/Vorbis/DSD entry of a queue built on
            // the phone fails for one reason that the path already answers. A
            // long queue of them took tens of seconds to reach a track that
            // was playable the whole time. The walk still continues, so a
            // playable track further along is found exactly as before;
            // `currentIndex` is deliberately not moved onto a candidate that
            // was never attempted.
            if isRefusedByCurrentRoute(track) {
                print("⏭️ Skipping \(track.title) - its format cannot play on this route")
                candidate += step
                attempts += 1
                continue
            }

            currentIndex = candidate

            if await loadTrack(track, preservePlaybackTime: false) {
                guard playbackIntentGeneration == intentGeneration else {
                    // The track loaded, but something changed the transport's
                    // mind while it did. If that something was a pause - which
                    // is what a headphone unplug becomes, via
                    // processAudioSessionRouteChange -> pause() - then nothing
                    // else is going to touch the transport, and performLoadTrack
                    // has just left it at .stopped with no message: playback
                    // ends mid-album instead of pausing on the track that was
                    // loaded. Only claim it when this load is still the one
                    // that matters; a newer selection owns its own state.
                    if playbackIdentity(currentTrack?.stableId, matches: track.stableId),
                       !isLoadingTrack,
                       usingSFBEngine || audioFile != nil {
                        markLoadedTrackPaused()
                    }
                    return .superseded
                }
                // The queue may have been edited while the load ran. Re-point
                // at wherever this track actually is now, rather than leaving
                // currentIndex on a row that has moved or gone.
                if !(playbackQueue.indices.contains(currentIndex)
                     && playbackIdentity(playbackQueue[currentIndex].stableId, matches: track.stableId)) {
                    normalizeIndexAndTrack()
                }
                return .loaded
            }

            // loadTrack yields. A newer play/pause/next/stop may have replaced
            // the queue and reset the shared failure flag while this caller was
            // suspended. Never read either after it has been superseded.
            guard playbackIntentGeneration == intentGeneration else { return .superseded }

            // A pending iCloud download is not "unplayable". Skipping past it
            // would silently play a different song than the one the queue says
            // is next - and on a library that is not fully downloaded it would
            // skip a long run of them. Stop on this track instead; it stays
            // selected and plays once its bytes land.
            if lastLoadFailureWasTransient {
                schedulePendingCloudPlayback(
                    track,
                    autoplay: autoplayWhenDownloadCompletes
                )
                return .pendingDownload
            }

            print("⏭️ Skipping unplayable track: \(track.title)")
            candidate += step
            attempts += 1
        }

        print("⛔️ No playable track left in the queue")
        return .exhausted
    }

    /// Shared tail of an automatic advance.
    ///
    /// Just `play()`. It used to branch on `usingSFBEngine && isPlaying` to
    /// adopt playback the load had already started, which was real while
    /// SFBAudioEngineManager exposed `loadAndPlay(url:)`. Loading is silent on
    /// both backends now, so every caller reaches here with the transport
    /// idle and the branch could never be taken.
    private func startPlaybackAfterAdvance() {
        continuePlaybackAfterAutomaticAction()
    }

    /// Mirrors a bookmark-driven stable-ID migration into the transport's
    /// in-memory state. The database and bookmark store are already migrated
    /// by LibraryIndexer; this closes the remaining same-session window where
    /// the queue, shuffle snapshot, or current track could keep the old key.
    private func adoptResolvedBookmarkIdentity(for original: Track, at resolvedURL: URL) {
        let resolvedStableId = DatabaseManager.generatePathStableId(forPath: resolvedURL.path)
        guard original.stableId != resolvedStableId || original.path != resolvedURL.path else {
            return
        }

        if original.stableId != resolvedStableId {
            resolvedBookmarkIdentityAliases[original.stableId] = resolvedStableId
        }

        var resolvedTrack = (try? databaseManager.getTrack(byStableId: resolvedStableId)) ?? original
        resolvedTrack.stableId = resolvedStableId
        resolvedTrack.path = resolvedURL.path

        for index in playbackQueue.indices where playbackQueue[index].stableId == original.stableId {
            playbackQueue[index] = resolvedTrack
        }
        originalQueue = originalQueue.map {
            $0 == original.stableId ? resolvedStableId : $0
        }

        if currentTrack?.stableId == original.stableId {
            currentTrack = resolvedTrack
        }
        if nextTrack?.stableId == original.stableId {
            nextTrack = resolvedTrack
        }
        if sfbNextTrack?.stableId == original.stableId {
            sfbNextTrack = resolvedTrack
        }

        print("🔁 Adopted resolved bookmark identity in playback state: \(original.stableId) -> \(resolvedStableId)")
    }

    private func normalizeIndexAndTrack() {
        if playbackQueue.isEmpty {
            currentIndex = 0
            currentTrack = nil
            return
        }

        if let ct = currentTrack {
            // Prefer the index we are already on when it still holds this
            // track. The queue deliberately allows the same song more than
            // once, and always snapping to firstIndex(where:) meant that from
            // the second A in [A, B, A, C], Next normalised back to index 0
            // and played B instead of C.
            if playbackQueue.indices.contains(currentIndex),
               playbackQueue[currentIndex].stableId == ct.stableId {
                return
            }

            if let idx = playbackQueue.firstIndex(where: { $0.stableId == ct.stableId }) {
                currentIndex = idx
                return
            }
        }

        currentIndex = max(0, min(currentIndex, playbackQueue.count - 1))
        currentTrack = playbackQueue[currentIndex]
    }

    // MARK: - Queue Management

    func playTrack(_ track: Track, queue: [Track] = []) async {
        await playTrack(track, queue: queue, preferredIndex: nil)
    }

    /// Starts an exact occurrence from a queue that can contain duplicate
    /// stable IDs. A stable-ID lookup alone always selects the first copy.
    func playTrack(at index: Int, in queue: [Track]) async {
        guard queue.indices.contains(index) else { return }
        await playTrack(queue[index], queue: queue, preferredIndex: index)
    }

    private func playTrack(
        _ track: Track,
        queue: [Track],
        preferredIndex: Int?
    ) async {
        print("🎵 Playing track: \(track.title)")
        outputDeviceBecameUnavailable = false
        cancelOutputRouteSettleResume()
        let intentGeneration = beginPlaybackIntent()

        // An explicit selection replaces the restored queue, so loading the old
        // restored track first only adds latency (and used to audibly start an
        // SFB track). Mark restoration consumed and load the selected song once.
        hasRestoredState = true

        playbackQueue = queue.isEmpty ? [track] : queue
        if let preferredIndex,
           playbackQueue.indices.contains(preferredIndex),
           playbackQueue[preferredIndex].stableId == track.stableId {
            currentIndex = preferredIndex
        } else {
            currentIndex = playbackQueue.firstIndex(where: { $0.stableId == track.stableId }) ?? 0
        }

        // Explicitly set the current track to ensure UI synchronization
        currentTrack = track

        // Save original queue for shuffle functionality. Captured before the
        // shuffle below, so turning shuffle off restores the list order.
        originalQueue = playbackQueue.map { $0.stableId }

        normalizeIndexAndTrack()

        // Honour a shuffle toggle that is already on - it survives launches
        // (savePlayerState persists isShuffled). This used to replace the
        // queue in list order while the shuffle button stayed lit, and because
        // originalQueue was that same sequential snapshot, pressing shuffle
        // off "restored" the order it was already in: the button looked
        // broken, and the only way to actually shuffle was to toggle it off
        // and on again. shuffleQueue() keeps the chosen track as the anchor,
        // so the song the user tapped is still the one that plays.
        if isShuffled, playbackQueue.count > 1 {
            shuffleQueue()
        }

        let loaded = await loadTrack(track)
        guard playbackIntentGeneration == intentGeneration else { return }
        guard loaded else {
            if lastLoadFailureWasTransient {
                schedulePendingCloudPlayback(track, autoplay: true)
            } else {
                // A hard failure on a song the user explicitly tapped used to
                // do nothing at all: performLoadTrack left playbackState at
                // .stopped with the track still selected and no message, so a
                // file that had been moved outside the app - or any
                // Opus/Vorbis/DSD track while CarPlay is connected, which
                // SFBAudioEngineManager refuses to load - simply did not play
                // and never said why.
                reportPlaybackFailure(Localized.playbackTrackUnavailable)
            }
            return
        }

        // See startPlaybackAfterAdvance(): the load left the transport idle, so
        // there is never anything already playing to adopt here.
        continuePlaybackAfterAutomaticAction()
    }

    /// Select an exact queue occurrence. Keeping this inside PlayerEngine lets
    /// a cloud-only row wait and autoplay when ready without the view treating
    /// that normal pending state as an unplayable track and skipping it.
    func playQueueTrack(at index: Int) async {
        guard playbackQueue.indices.contains(index) else { return }
        outputDeviceBecameUnavailable = false
        cancelOutputRouteSettleResume()
        let intentGeneration = beginPlaybackIntent()

        currentIndex = index
        let track = playbackQueue[index]
        currentTrack = track

        let loaded = await loadTrack(track, preservePlaybackTime: false)
        guard playbackIntentGeneration == intentGeneration else { return }

        if loaded {
            startPlaybackAfterAdvance()
        } else if lastLoadFailureWasTransient {
            schedulePendingCloudPlayback(track, autoplay: true)
        } else {
            // This is an explicit queue-row selection. A hard failure should
            // stay on that row and explain the problem, not silently turn the
            // tap into a request to play a different song.
            reportPlaybackFailure(loadFailureMessage(for: track))
        }
    }

    func nextTrack(autoplay: Bool? = nil) async {
        guard !playbackQueue.isEmpty else { return }
        let intentGeneration = beginPlaybackIntent()
        normalizeIndexAndTrack()
        let shouldAutoplay = autoplay ?? isPlaying

        // Stop at the end of the queue unless queue loop is on, matching what
        // happens when a track finishes on its own. This used to wrap with an
        // unconditional modulo, so pressing Next on the last track restarted
        // the queue even with repeat off. Song loop is deliberately not
        // consulted: it repeats the current track, and asking for the next one
        // is asking to leave it.
        if currentIndex >= playbackQueue.count - 1 && !isRepeating {
            print("⏭️ End of queue reached with repeat off - stopping")
            stop()
            return
        }

        let startIndex = (currentIndex + 1) % playbackQueue.count
        let result = await loadFirstPlayableTrack(
            from: startIndex,
            step: 1,
            wraps: isRepeating,
            autoplayWhenDownloadCompletes: shouldAutoplay,
            intentGeneration: intentGeneration
        )

        switch result {
        case .loaded:
            guard playbackIntentGeneration == intentGeneration else { return }
        case .pendingDownload, .superseded:
            return
        case .exhausted:
            guard playbackIntentGeneration == intentGeneration else { return }
            // Every remaining entry refused to load. This is not the ordinary
            // end of the queue - that is handled above - so say so rather than
            // stopping silently.
            stopAndReportPlaybackFailure(Localized.playbackTrackUnavailable)
            return
        }

        if shouldAutoplay {
            startPlaybackAfterAdvance()
        } else {
            markLoadedTrackPaused()
        }
    }

    func previousTrack(autoplay: Bool? = nil) async {
        guard !playbackQueue.isEmpty else { return }
        let intentGeneration = beginPlaybackIntent()
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

        // Only wrap to the end of the queue when queue loop is on. nextTrack
        // deliberately stops at the end with repeat off, so wrapping here
        // regardless meant Previous on the first track jumped to the last one.
        if currentIndex == 0 && !isRepeating {
            await seek(to: 0)
            if !wasPlaying {
                isPlaying = false
                playbackState = .paused
                updateNowPlayingInfoEnhanced()
                updateWidgetData()
            }
            return
        }

        let startIndex = currentIndex > 0 ? currentIndex - 1 : playbackQueue.count - 1
        let result = await loadFirstPlayableTrack(
            from: startIndex,
            step: -1,
            wraps: isRepeating,
            autoplayWhenDownloadCompletes: wasPlaying,
            intentGeneration: intentGeneration
        )

        switch result {
        case .loaded:
            guard playbackIntentGeneration == intentGeneration else { return }
        case .pendingDownload, .superseded:
            return
        case .exhausted:
            guard playbackIntentGeneration == intentGeneration else { return }
            // Every remaining entry refused to load. This is not the ordinary
            // end of the queue - that is handled above - so say so rather than
            // stopping silently.
            stopAndReportPlaybackFailure(Localized.playbackTrackUnavailable)
            return
        }

        if wasPlaying {
            startPlaybackAfterAdvance()
        } else {
            markLoadedTrackPaused()
        }
    }

    private func markLoadedTrackPaused() {
        cancelPendingCompletions()
        if !usingSFBEngine {
            playerNode.stop()
        }
        isPlaying = false
        playbackState = .paused
        seekTimeOffset = 0
        playbackTime = 0
        stopPlaybackTimer()
        endBackgroundMonitoring()
        updateNowPlayingInfoEnhanced()
        updateWidgetData()
    }

    func addToQueue(_ track: Track) {
        playbackQueue.append(track)
        originalQueue.append(track.stableId)
        queueDidChange()
    }

    func insertNext(_ track: Track) {
        let previousOriginalCount = originalQueue.count
        let insertIndex = min(currentIndex + 1, playbackQueue.count)
        playbackQueue.insert(track, at: insertIndex)

        // Keep the un-shuffled order in step, or turning shuffle off would
        // rebuild the queue from a snapshot taken before this insert and drop
        // the track the user just queued.
        if !isShuffled,
           playbackQueue.count == previousOriginalCount + 1,
           insertIndex <= previousOriginalCount {
            // Not shuffled, so the two lists are parallel and the row's own
            // position is the anchor. firstIndex(of:) below picks the FIRST
            // copy of the current song, which is the wrong one whenever the
            // same track sits in the queue more than once: "Play Next" from
            // the second A in [A, B, A, C] queued the new track after the
            // first A, so turning shuffle off moved it somewhere the user
            // never asked for.
            originalQueue.insert(track.stableId, at: insertIndex)
        } else if let anchor = originalQueue.firstIndex(of: currentTrack?.stableId ?? "") {
            // Shuffled: the two orders do not correspond position for
            // position, so the occurrence genuinely cannot be identified.
            // Anchoring on the first copy at least keeps it adjacent.
            originalQueue.insert(track.stableId, at: min(anchor + 1, originalQueue.count))
        } else {
            originalQueue.append(track.stableId)
        }
        queueDidChange()
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

        // Song loop must take back an already-scheduled successor, or the next
        // track plays instead of the current one repeating.
        queueDidChange()
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
        queueDidChange()
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

    /// Hands the audio hardware back before SFBAudioEngine takes over.
    ///
    /// Deliberately only stops - the graph itself is left wired, so returning
    /// to a native track just starts it again. The full teardown belongs to
    /// resetAudioEngineForNative(), which runs on the opposite transition.
    private func stopNativeEngineForSFBHandover() {
        guard hasSetupAudioEngine else { return }

        if playerNode.isPlaying {
            playerNode.stop()
        }
        if audioEngine.isRunning {
            audioEngine.stop()
            print("🛑 Stopped the native audio engine before handing over to SFBAudioEngine")
        }
    }

    /// Reset AVAudioEngine to clean state when switching from SFBAudioEngine
    private func resetAudioEngineForNative() {
        print("🔄 Resetting AVAudioEngine for native playback")

        // SFBAudioEngine may be the first backend used in this process, in
        // which case the lazy native node has never been attached.
        if hasSetupAudioEngine {
            if audioEngine.isRunning {
                audioEngine.stop()
                print("✅ AVAudioEngine stopped")
            }
            if audioEngine.attachedNodes.contains(playerNode), playerNode.isPlaying {
                playerNode.stop()
            }
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
        // Prefer the rate the decoder actually produces. The database column is
        // only a fallback: it is nil on rows whose metadata parse never yielded
        // one - so nothing was configured at all and the hardware silently kept
        // whatever the last track set (often the 44.1kHz that
        // resetAudioSessionForNative asks for, under a 96/192kHz file) - and it
        // is 0 for the filename-only parser, which made this call
        // setPreferredSampleRate(0) into a swallowed error.
        let targetSampleRate: Double? = {
            if format.sampleRate > 0 { return format.sampleRate }
            if let stored = currentTrack?.sampleRate, stored > 0 { return Double(stored) }
            return nil
        }()
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
                       abs(session.sampleRate - sampleRate) > 1.0 {
                        try session.setPreferredSampleRate(sampleRate)
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

            // Check for completion - but see checkIfTrackEnded(): a queued
            // gapless successor owns this transition.
            if isPlaying, playbackTime >= duration, duration > 0,
               !sfbAudioManager.hasGaplessNextQueued {
                await handleSFBPlaybackEnded()
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
        guard !isLoadingTrack, !isAdvancingTrack else { return }
        isAdvancingTrack = true
        defer { isAdvancingTrack = false }
        let intentGeneration = playbackIntentGeneration

        if promoteGaplessNextIfAvailable() {
            return
        }

        if isLoopingSong, let t = currentTrack {
            let loaded = await loadTrack(t)
            guard playbackIntentGeneration == intentGeneration else { return }

            if loaded {
                continuePlaybackAfterAutomaticAction()
            } else if lastLoadFailureWasTransient {
                schedulePendingCloudPlayback(t, autoplay: true)
            } else {
                print("⛔️ Looped track is no longer playable - stopping")
                stopAndReportPlaybackFailure(Localized.playbackTrackUnavailable)
            }
            return
        }

        if currentIndex < playbackQueue.count - 1 {
            let result = await loadFirstPlayableTrack(
                from: currentIndex + 1,
                step: 1,
                wraps: isRepeating,
                autoplayWhenDownloadCompletes: true,
                intentGeneration: intentGeneration
            )

            switch result {
            case .loaded:
                guard playbackIntentGeneration == intentGeneration else { return }
                startPlaybackAfterAdvance()
            case .exhausted:
                guard playbackIntentGeneration == intentGeneration else { return }
                // Nothing left in the queue would load, which is a failure
                // rather than a natural end - report it instead of just
                // falling silent mid-album.
                stopAndReportPlaybackFailure(Localized.playbackTrackUnavailable)
            case .pendingDownload, .superseded:
                break
            }
            return
        }

        if isRepeating, !playbackQueue.isEmpty {
            let result = await loadFirstPlayableTrack(
                from: 0,
                step: 1,
                wraps: true,
                autoplayWhenDownloadCompletes: true,
                intentGeneration: intentGeneration
            )

            switch result {
            case .loaded:
                guard playbackIntentGeneration == intentGeneration else { return }
                startPlaybackAfterAdvance()
            case .exhausted:
                guard playbackIntentGeneration == intentGeneration else { return }
                // Nothing left in the queue would load, which is a failure
                // rather than a natural end - report it instead of just
                // falling silent mid-album.
                stopAndReportPlaybackFailure(Localized.playbackTrackUnavailable)
            case .pendingDownload, .superseded:
                break
            }
            return
        }

        guard playbackIntentGeneration == intentGeneration else { return }
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
        cachedNowPlayingAlbumTrackId = nil
        cachedNowPlayingAlbumName = nil
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

    /// The lock screen and CarPlay's Now Playing template both show an album
    /// line; nothing ever populated MPMediaItemPropertyAlbumTitle, so it was
    /// always blank.
    private func cachedAlbumName(for track: Track) -> String? {
        if cachedNowPlayingAlbumTrackId == track.stableId {
            return cachedNowPlayingAlbumName
        }

        var albumName: String?
        if let albumId = track.albumId {
            albumName = try? databaseManager.read { db in
                try Album.fetchOne(db, key: albumId)?.title
            }
        }

        cachedNowPlayingAlbumTrackId = track.stableId
        cachedNowPlayingAlbumName = albumName
        return albumName
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
            // Artwork is cosmetic: request the download but do not sit waiting
            // on it. The track's own load already waits where it matters.
            try await cloudDownloadManager.ensureLocal(url, downloadTimeout: 0)

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

        // Siri and App Intents can invoke this while the app is already open.
        // Only mark the UI as backgrounded when UIKit says it really is;
        // otherwise startPlaybackTimer() remains disabled until an unrelated
        // background/foreground round trip.
        if appState == .background {
            suspendUITimersForBackground()
        } else {
            resumeUITimersForForeground()
        }

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

        // Same reason as the interruption handler: playbackTime is only
        // refreshed by the foreground UI timer, so while backgrounded it goes
        // stale. Persist the live render position instead, or a track playing
        // with the screen locked is restored minutes behind where it actually is.
        let positionToPersist = isPlaying ? nowPlayingElapsedTime() : playbackTime

        let playerState: [String: Any] = [
            "currentTrackStableId": currentTrack.stableId,
            "playbackTime": positionToPersist,
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
        guard !hasRestoredState else {
            print("⏭️ Player state already restored or replaced by an explicit selection")
            return
        }
        let expectedPlaybackIntentGeneration = playbackIntentGeneration

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
                // Database reads may take long enough for Siri, CarPlay or the UI
                // to install a newer selection. Restoration must never overwrite
                // that intent when it finally reaches the main actor again.
                guard !self.hasRestoredState,
                      self.playbackIntentGeneration == expectedPlaybackIntentGeneration else {
                    print("⏭️ Saved player state was superseded while it was being read")
                    return
                }
                self.hasRestoredState = true

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
        if let artworkChangedObserver {
            NotificationCenter.default.removeObserver(artworkChangedObserver)
        }
    }
}
enum PlayerError: Error {
    case fileNotFound
    case invalidAudioFile
    case audioEngineError
    case configurationError
}
