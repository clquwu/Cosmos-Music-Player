//
//  SFBAudioEngineManager.swift
//  Cosmos Music Player
//
//  Manages SFBAudioEngine playback for Opus, Vorbis, and DSD formats
//

import Foundation
import AVFoundation
import AudioToolbox
import SFBAudioEngine
import UIKit
import CarPlay

private struct AVAudioUnitEQBox: @unchecked Sendable {
    let node: AVAudioUnitEQ
}

/// Whether CarPlay is connected, published on its own.
///
/// The library list screens filter out Opus/Vorbis/DSD while the car is
/// connected, so they have to be invalidated when that changes - but observing
/// `SFBAudioEngineManager` for it invalidated them on *every* publication that
/// class makes, and `currentTime` is written by a 0.1s timer for the whole of
/// SFB playback. Ten times a second each of those views re-evaluated its body,
/// which for a track list means re-hashing, re-filtering and re-sorting the
/// entire library on the main thread.
///
/// Kept in step by `SFBAudioEngineManager.isCarPlayEnvironment`'s `didSet`,
/// which is the single writer of that flag.
@MainActor
final class CarPlayRouteState: ObservableObject {
    static let shared = CarPlayRouteState()

    @Published fileprivate(set) var isConnected = false

    private init() {}
}

private final class WeakAudioPlayerBox: @unchecked Sendable {
    weak var value: AudioPlayer?

    init(_ value: AudioPlayer) {
        self.value = value
    }
}

/// Carries a decoder that was built and opened off the main actor back to it.
///
/// `@unchecked` for the same reason the box above is: neither `PCMDecoding` nor
/// `SFBTrack` is Sendable, but this instance is created inside one detached
/// task, handed to exactly one awaiting caller, and never touched by the task
/// again - so there is no concurrent access to check.
private struct PreparedDecoder: @unchecked Sendable {
    let track: SFBTrack
    let decoder: PCMDecoding
    /// The decoder's actual delivery mode. This must be derived from its runtime
    /// type because SFBTrack may safely fall back from requested DoP to PCM.
    let usesDoP: Bool
}

@MainActor
class SFBAudioEngineManager: NSObject, ObservableObject, AudioPlayer.Delegate {
    static let shared = SFBAudioEngineManager()

    private var audioPlayer: AudioPlayer?
    private var currentTrack: SFBTrack?
    private var updateTimer: Timer?
    private var eqAttachmentFailed = false

    // MARK: - Gapless playback support
    //
    // Previously this was three unused properties (`nextTrackURL`,
    // `onTrackNearingEnd`, `hasTriggeredNearEnd`): nothing ever wrote them, so
    // every Opus/Vorbis/DSD transition went stop -> full load -> play and the
    // formats that most often come from a continuous recording were the only
    // ones that gapped. SFBAudioPlayer queues decoders natively, so hand it the
    // successor instead and let `nowPlayingChanged` tell us when it took over.

    /// A successor already handed to SFBAudioPlayer, with the properties the
    /// promotion needs. They are captured at enqueue time because reading them
    /// costs a synchronous TagLib pass, which must not happen on the audio
    /// transition.
    private struct GaplessNext {
        let url: URL
        let decoder: PCMDecoding
        let track: SFBTrack
    }

    private var gaplessNext: GaplessNext?

    /// Whether a successor is queued behind the current decoder. Callers use
    /// this to suppress their own end-of-track detection: the player renders
    /// straight through the boundary, so a position-based check would fire a
    /// spurious advance right as the transition happens.
    var hasGaplessNextQueued: Bool { gaplessNext != nil }

    /// Invoked on the main actor once SFBAudioPlayer has moved on to the
    /// enqueued successor. Carries the URL that was enqueued.
    var onGaplessTrackStarted: ((URL) -> Void)?

        nonisolated private func configureDefaultSFBBands(for equalizer: AVAudioUnitEQ) {
            let numberOfBands = equalizer.bands.count
            let minFreq = 20.0
            let maxFreq = 20000.0

            for i in 0..<numberOfBands {
                let band = equalizer.bands[i]
                let frequency = minFreq * pow(maxFreq / minFreq, Double(i) / Double(numberOfBands - 1))
                band.frequency = Float(frequency)
                band.gain = 0.0
                band.bandwidth = 1.0
                band.filterType = .parametric
                band.bypass = false
            }
        }

    private func cleanupEqualizer() {
        if let equalizer = sfbEqualizer {
            audioPlayer?.modifyProcessingGraph { [weak self] engine in
                guard let self else { return }
                if engine.attachedNodes.contains(equalizer) {
                    self.removeEqualizer(equalizer, from: engine)
                }
            }
        }
        sfbEqualizer = nil
    }

    nonisolated private func removeEqualizer(_ equalizer: AVAudioUnitEQ, from engine: AVAudioEngine) {
        guard engine.attachedNodes.contains(equalizer) else {
            print("ℹ️ EQ node already detached")
            return
        }

        let mixerConnection = engine.inputConnectionPoint(for: engine.mainMixerNode, inputBus: 0)
        let isEQFeedingMixer = mixerConnection?.node === equalizer

        let upstreamConnection = engine.inputConnectionPoint(for: equalizer, inputBus: 0)
        let upstreamNode = upstreamConnection?.node

        if isEQFeedingMixer, let upstreamNode {
            let upstreamBus = upstreamConnection?.bus ?? 0
            let reconnectFormat = upstreamNode.outputFormat(forBus: upstreamBus)

            engine.disconnectNodeInput(engine.mainMixerNode)
            engine.disconnectNodeOutput(equalizer)
            engine.disconnectNodeInput(equalizer)
            engine.detach(equalizer)

            engine.connect(upstreamNode, to: engine.mainMixerNode, format: reconnectFormat)
            print("🔗 Restored \(upstreamNode) → mainMixerNode after EQ removal")
        } else {
            engine.disconnectNodeOutput(equalizer)
            engine.disconnectNodeInput(equalizer)
            engine.detach(equalizer)
            print("🧹 Removed SFBAudioEngine EQ (no upstream reconnection needed)")
        }
    }

    private func attachEqualizerToEngine(with format: AVAudioFormat?, retryCount: Int = 0) {
        guard let player = audioPlayer else { return }

        // Skip EQ if not enabled by user
        guard eqManager.isEnabled else {
            print("ℹ️ EQ not enabled by user - skipping attachment")
            return
        }

        // Skip EQ if previous attachment failed (prevents repeated crashes)
        if eqAttachmentFailed {
            print("⚠️ EQ attachment previously failed - skipping to prevent crash")
            return
        }

        let maxRetries = 3
        let eqEnabled = eqManager.isEnabled
        let globalGain = Float(eqManager.globalGain)

        guard formatSupportsSFBEQ(format) else {
            print("⚠️ SFBAudioEngine EQ not supported for format: \(format?.description ?? "nil")")
            player.modifyProcessingGraph { [weak self] engine in
                guard let self else { return }
                if let existing = engine.attachedNodes.compactMap({ $0 as? AVAudioUnitEQ }).first {
                    self.removeEqualizer(existing, from: engine)
                }
            }
            Task { @MainActor [weak self] in self?.sfbEqualizer = nil }
            return
        }

        player.modifyProcessingGraph { [weak self] engine in
            guard let self else { return }

            var equalizer = self.sfbEqualizer

            if equalizer == nil {
                equalizer = engine.attachedNodes.compactMap { $0 as? AVAudioUnitEQ }.first
            }

            if equalizer == nil {
                let newEQ = AVAudioUnitEQ(numberOfBands: 16)
                newEQ.globalGain = globalGain
                newEQ.bypass = !eqEnabled
                self.configureDefaultSFBBands(for: newEQ)
                engine.attach(newEQ)
                equalizer = newEQ
                print("✅ EQ node attached via modifyProcessingGraph")
            } else if let eq = equalizer, !engine.attachedNodes.contains(where: { $0 === eq }) {
                engine.attach(eq)
                print("✅ Reattached existing SFBAudioEngine EQ node")
            }

            guard let equalizer else { return }

            let eqBox = AVAudioUnitEQBox(node: equalizer)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sfbEqualizer = eqBox.node
                self.applySFBEQSettings()
            }

            let eqConnectedToMain = engine.outputConnectionPoints(for: equalizer, outputBus: 0)
                .contains(where: { $0.node === engine.mainMixerNode })

            if eqConnectedToMain {
                print("🎛️ SFBAudioEngine EQ already present in graph")
                return
            }

            if let connection = engine.inputConnectionPoint(for: engine.mainMixerNode, inputBus: 0),
               let upstreamNode = connection.node,
               upstreamNode !== equalizer {
                let bus = connection.bus
                // Prefer the node's actual render format - the decoder format can
                // differ from what the player node outputs, and a mismatched
                // connect throws
                let nodeFormat = upstreamNode.outputFormat(forBus: bus)
                let connectFormat = nodeFormat.sampleRate > 0 ? nodeFormat : format
                engine.disconnectNodeInput(engine.mainMixerNode)

                // Try to connect - if it fails, mark EQ as failed
                do {
                    try ObjCExceptionCatcher.tryCatch({
                        engine.connect(equalizer, to: engine.mainMixerNode, format: connectFormat)
                        engine.connect(upstreamNode, to: equalizer, format: connectFormat)
                    })
                } catch {
                    print("❌ EQ connection failed in attachEqualizerToEngine: \(error.localizedDescription)")
                    // CRITICAL: the mixer input was already disconnected above.
                    // Restore the original connection or ALL SFB playback
                    // (Opus/Vorbis/DSD) stays silent (issue #75).
                    try? ObjCExceptionCatcher.tryCatch({
                        engine.disconnectNodeOutput(equalizer)
                        engine.connect(upstreamNode, to: engine.mainMixerNode, format: nodeFormat.sampleRate > 0 ? nodeFormat : nil)
                    })
                    print("🔗 Restored direct connection after EQ failure")
                    Task { @MainActor [weak self] in
                        self?.eqAttachmentFailed = true
                    }
                    return
                }

                print("🔗 Inserted EQ between \(upstreamNode) and mainMixerNode")
                return
            }

            let fallbackNode = engine.attachedNodes.first(where: { node in
                if node === equalizer || node === engine.mainMixerNode || node === engine.outputNode { return false }
                let className = String(describing: type(of: node))
                return className.contains("SFBAudioPlayerNode") || node is AVAudioPlayerNode
            })

            if let sourceNode = fallbackNode {
                let nodeFormat = sourceNode.outputFormat(forBus: 0)
                let connectFormat = nodeFormat.sampleRate > 0 ? nodeFormat : format
                engine.disconnectNodeInput(engine.mainMixerNode)
                engine.disconnectNodeOutput(sourceNode)

                // Try to connect - if it fails, mark EQ as failed
                do {
                    try ObjCExceptionCatcher.tryCatch({
                        engine.connect(sourceNode, to: equalizer, format: connectFormat)
                        engine.connect(equalizer, to: engine.mainMixerNode, format: connectFormat)
                    })
                } catch {
                    print("❌ EQ connection failed (fallback): \(error.localizedDescription)")
                    // CRITICAL: restore the direct connection or SFB playback
                    // stays silent (issue #75)
                    try? ObjCExceptionCatcher.tryCatch({
                        engine.disconnectNodeOutput(equalizer)
                        engine.connect(sourceNode, to: engine.mainMixerNode, format: nodeFormat.sampleRate > 0 ? nodeFormat : nil)
                    })
                    print("🔗 Restored direct connection after EQ failure (fallback)")
                    Task { @MainActor [weak self] in
                        self?.eqAttachmentFailed = true
                    }
                    return
                }

                print("🔗 Inserted EQ between \(sourceNode) and mainMixerNode (fallback)")
                return
            }

            print("⚠️ Unable to locate upstream node for SFBAudioEngine EQ insertion")

            if retryCount < maxRetries {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    guard let self else { return }
                    self.attachEqualizerToEngine(with: format, retryCount: retryCount + 1)
                }
            }
        }
    }

    // Store decoder properties for seeking when AudioFile properties are unavailable
    private var decoderFrameLength: Int64 = 0
    private var decoderSampleRate: Double = 0
    private var loadedDecoder: PCMDecoding?
    private var loadedDecoderIsDSD = false
    private var loadedDecoderUsesDoP = false
    /// Files whose exact DoP carrier rate the *current* route would not accept.
    /// `load()` builds a PCM decoder for these instead of loading a DoP one
    /// that play() is only going to reject again. Cleared whenever the output
    /// route changes, so plugging in a real DAC re-enables DoP immediately.
    private var doPRefusedPaths: Set<String> = []
    private var hasConfiguredSessionForLoadedDecoder = false
    private var hasReportedEndOfAudio = true

    // EQ integration for SFBAudioEngine (native approach following wiki)
    let eqManager = EQManager.shared
    private var sfbEqualizer: AVAudioUnitEQ?

    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0

    /// Called exactly once when SFBAudioEngine reaches the end of all queued
    /// audio. PlayerEngine owns queue advancement; the manager only reports the
    /// event so it also works while PlayerEngine's foreground UI timer is off.
    var onPlaybackEnded: (() -> Void)?
    /// A decoder/renderer failure for the current track. Queue advancement is
    /// intentionally not reported as a normal end in this case.
    var onPlaybackFailed: ((Error) -> Void)?
    /// Fired when the player reports playing while its position stands still -
    /// see `noteObservedPlaybackTime`. Distinct from `onPlaybackFailed`: the
    /// decoder is fine, the render graph is not, so the caller should rebuild
    /// rather than tell the user the track is unplayable.
    var onPlaybackStalled: (() -> Void)?
    private var lastObservedPlaybackTime: TimeInterval = -1
    private var lastPlaybackAdvanceAt = Date()
    private static let stallDetectionWindow: TimeInterval = 1.5

    // CarPlay environment detection
    @Published var isCarPlayEnvironment = false {
        didSet {
            // Mirror into the route-only observable the list screens watch.
            // See CarPlayRouteState for why they must not observe this class.
            guard CarPlayRouteState.shared.isConnected != isCarPlayEnvironment else { return }
            CarPlayRouteState.shared.isConnected = isCarPlayEnvironment
        }
    }

    private override init() {
        super.init()
        isCarPlayEnvironment = Self.detectCarPlay()
        CarPlayRouteState.shared.isConnected = isCarPlayEnvironment
        print("🔄 SFBAudioEngine Manager initialized - CarPlay: \(isCarPlayEnvironment)")
    }

    /// Detects if the app is running in a CarPlay environment
    private static func detectCarPlay() -> Bool {
        carPlaySceneIsConnected() || carAudioRouteIsActive()
    }

    /// A CarPlay template scene is connected. The scene exists before
    /// AVAudioSession necessarily exposes a `.carAudio` route, which is why it
    /// is checked at all - but it also outlives its own disconnect callback,
    /// which is why `handleCarPlayDisconnected()` has to skip it.
    private static func carPlaySceneIsConnected() -> Bool {
        if #available(iOS 13.0, *) {
            for scene in UIApplication.shared.connectedScenes {
                if scene is CPTemplateApplicationScene
                    || scene.session.role == .carTemplateApplication {
                    print("🚗 CarPlay scene detected: \(scene)")
                    return true
                }
            }
        }
        return false
    }

    /// The audio session is actually routed to the car.
    private static func carAudioRouteIsActive() -> Bool {
        let audioSession = AVAudioSession.sharedInstance()
        let currentRoute = audioSession.currentRoute
        print("🎧 Current audio route: \(currentRoute.outputs.map { "\($0.portName) (\($0.portType))" }.joined(separator: ", "))")

        for output in currentRoute.outputs {
            if output.portType == .carAudio {
                print("🚗 CarPlay audio route detected: \(output.portName)")
                return true
            }
        }

        return false
    }

    /// The published flag is updated from scene/route callbacks, but those
    /// callbacks can still be queued behind a decoder continuation. Consult the
    /// live route as well at each load/play safety boundary.
    private var carPlayIsActiveNow: Bool {
        isCarPlayEnvironment || Self.carAudioRouteIsActive()
    }

    /// Re-check CarPlay status (call when audio route changes)
    func updateCarPlayStatus() {
        let wasCarPlay = isCarPlayEnvironment
        isCarPlayEnvironment = Self.detectCarPlay()

        if wasCarPlay != isCarPlayEnvironment {
            if isCarPlayEnvironment {
                print("🚗 Switched to CarPlay - stopping SFBAudioEngine")
                stop()
                cleanupEqualizer()
                audioPlayer = nil
            } else {
                print("📱 Switched from CarPlay - SFBAudioEngine available again")
            }
        }
    }

    /// The error `play()` raises when the route refused the DoP carrier rate
    /// and the track should be reloaded as PCM. Distinct from a genuine DoP
    /// failure on a real DAC, which stays fatal.
    static func isDoPFallbackRequired(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "SFBAudioEngineManager" && nsError.code == 8
    }

    /// A new output route gets a fresh answer on whether it can carry DoP.
    func clearDoPRefusals() {
        guard !doPRefusedPaths.isEmpty else { return }
        doPRefusedPaths.removeAll()
        print("🎵 Output route changed - DoP will be attempted again")
    }

    /// Force the CarPlay flag off when the template scene reports that it has
    /// disconnected.
    ///
    /// Re-detecting here is unreliable: the scene is usually still present in
    /// `connectedScenes` while this callback runs, so `detectCarPlay()` answers
    /// true. If the route change had already fired before scene teardown, both
    /// checks saw CarPlay and the flag latched on - leaving SFBAudioEngine
    /// refused and Opus/Vorbis/DSD hidden from every list.
    ///
    /// So the scene half of the detection is skipped - but only that half. The
    /// audio route is still consulted, because forcing the flag off outright
    /// opened a window until the delayed re-check in which a car that was
    /// still the active output looked like a phone: the format filters lifted
    /// and `load()` would hand an Opus/Vorbis/DSD track to SFBAudioEngine,
    /// which is exactly what the CarPlay guard exists to prevent. The delayed
    /// re-check remains for the opposite ordering, where the route has not yet
    /// caught up with the scene.
    func handleCarPlayDisconnected() {
        let routeIsStillCarPlay = Self.carAudioRouteIsActive()

        if isCarPlayEnvironment && !routeIsStillCarPlay {
            print("📱 CarPlay scene disconnected - SFBAudioEngine available again")
        } else if routeIsStillCarPlay {
            print("🚗 CarPlay scene disconnected but the car is still the audio route - staying in CarPlay mode")
        }
        isCarPlayEnvironment = routeIsStillCarPlay

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.updateCarPlayStatus()
        }
    }

    private func setupAudioPlayer() {
        guard audioPlayer == nil else { return }

        // Don't initialize SFBAudioEngine in CarPlay environment
        if carPlayIsActiveNow {
            print("🚗 Skipping SFBAudioEngine setup - running in CarPlay")
            return
        }

        // Try to create AudioPlayer
        audioPlayer = AudioPlayer()

        // Verify player was created successfully
        guard audioPlayer != nil else {
            print("⚠️ SFBAudioEngine AudioPlayer creation returned nil")
            return
        }

        audioPlayer?.delegate = self
        print("🔄 SFBAudioEngine AudioPlayer initialized successfully")
    }

    /// Rebuilds the player after mediaserverd has been restarted. SFBAudioEngine
    /// owns its own AVAudioEngine, and that one dies with the rest, so reusing
    /// the existing AudioPlayer after a reset plays silence.
    func rebuildAfterMediaServicesReset() {
        print("🔄 Rebuilding SFBAudioEngine AudioPlayer after media services reset")
        updateTimer?.invalidate()
        updateTimer = nil
        isPlaying = false
        loadedDecoder = nil
        gaplessNext = nil
        hasConfiguredSessionForLoadedDecoder = false
        hasReportedEndOfAudio = true
        resetAudioPlayer()
    }

    private func resetAudioPlayer() {
        gaplessNext = nil
        audioPlayer?.stop()
        cleanupEqualizer()
        // eqAttachmentFailed was never cleared anywhere, so a single transient
        // graph error disabled EQ for the rest of the app's life.
        eqAttachmentFailed = false
        audioPlayer = nil
        audioPlayer = AudioPlayer()
        audioPlayer?.delegate = self
        print("🔄 SFBAudioEngine AudioPlayer reset")
    }

    nonisolated private func formatSupportsSFBEQ(_ format: AVAudioFormat?) -> Bool {
        guard let format else { return true }
        let streamDescription = format.streamDescription.pointee
        let isLinearPCM = streamDescription.mFormatID == kAudioFormatLinearPCM
        let isFloat = (streamDescription.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        return isLinearPCM && isFloat && streamDescription.mBitsPerChannel == 32
    }

    // MARK: - Playback Control

    /// Prepares a decoder without starting audio. Call `play()` explicitly once
    /// the caller has decided whether the requested operation should autoplay.
    func load(url: URL) async throws {
        print("🚀 SFBAudioEngine.load called for: \(url.lastPathComponent)")
        try Task.checkCancellation()

        // Each track gets a fresh attempt at the EQ graph; the previous
        // track's format may simply have been unsupported.
        eqAttachmentFailed = false

        // Don't use SFBAudioEngine in CarPlay environment
        if carPlayIsActiveNow {
            print("🚗 CarPlay detected - refusing to load with SFBAudioEngine")
            throw NSError(domain: "SFBAudioEngine", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "SFBAudioEngine unavailable in CarPlay - using native playback"
            ])
        }

        // Ensure AudioPlayer is initialized (deferred from init for CarPlay compatibility)
        setupAudioPlayer()

        // If AudioPlayer failed to initialize, throw error to fall back to native playback
        guard audioPlayer != nil else {
            throw NSError(domain: "SFBAudioEngine", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "SFBAudioEngine unavailable - AudioPlayer initialization failed"
            ])
        }

        // Stop any current playback and cleanup
        hasReportedEndOfAudio = true
        gaplessNext = nil
        audioPlayer?.stop()
        cleanupEqualizer()
        loadedDecoder = nil
        hasConfiguredSessionForLoadedDecoder = false
        updateTimer?.invalidate()
        updateTimer = nil
        isPlaying = false
        currentTime = 0
        try Task.checkCancellation()

        print("🔍 SFBAudioEngine attempting to load: \(url.lastPathComponent)")

        // Check user's DSD playback preference
        let settings = DeleteSettings.load()
        let isDSDFile = url.pathExtension.lowercased() == "dsf" || url.pathExtension.lowercased() == "dff"

        var enableDoP: Bool
        if isDSDFile {
            switch settings.dsdPlaybackMode {
            case .auto:
                // AVAudioSession tells us that an output is USB/line-out, but it
                // exposes no capability bit for the DoP 0x05/0xFA markers. A
                // normal USB interface accepts the carrier as PCM and renders it
                // as full-scale noise, so Auto must never guess on the user's
                // behalf. The explicit .dop setting remains the opt-in override.
                enableDoP = false
                print("🎵 DSD file detected, Auto mode: using safe PCM conversion")
            case .pcm:
                // Always use PCM conversion
                enableDoP = false
                print("🎵 DSD file detected, PCM mode: Will convert to PCM")
            case .dop:
                // Always use DoP
                enableDoP = true
                print("🎵 DSD file detected, DoP mode: Will use DoP encoding")
            }

            // Decide against DoP here rather than letting play() throw. The
            // route gate is a safety check, not a reason to refuse the track:
            // over the speaker or Bluetooth, "always DoP" should still play the
            // song as converted PCM. Throwing instead meant choosing DoP in
            // Settings silently made every DSD file unplayable away from a DAC.
            if enableDoP && !routeCanCarryDoP() {
                let ports = AVAudioSession.sharedInstance().currentRoute.outputs
                    .map { $0.portType.rawValue }
                print("🎵 Route \(ports) cannot carry DoP - converting to PCM instead")
                enableDoP = false
            }

            // This route already refused the exact carrier rate for this file
            // (see play()). Build the PCM decoder now rather than loading a DoP
            // decoder that is only going to be rejected again.
            if enableDoP && doPRefusedPaths.contains(url.standardizedFileURL.path) {
                print("🎵 Route previously refused the DoP carrier rate for \(url.lastPathComponent) - converting to PCM")
                enableDoP = false
            }
        } else {
            enableDoP = false
        }

        print("🔍 Preparing decoder for: \(url.lastPathComponent), requestedDoP: \(enableDoP)")
        try Task.checkCancellation()

        // Property reads, decoder construction and decoder.open() are all
        // synchronous file work. Prepare the complete unit off the main actor;
        // doing only SFBTrack.init off-actor still left header reads capable of
        // freezing the player UI.
        let prepared = try await Task.detached(priority: .userInitiated) { () -> PreparedDecoder? in
            let track = SFBTrack(url: url)
            try Task.checkCancellation()
            guard let decoder = try track.decoder(enableDoP: enableDoP) else { return nil }
            try decoder.open()
            try Task.checkCancellation()
            return PreparedDecoder(
                track: track,
                decoder: decoder,
                usesDoP: decoder is DoPDecoder
            )
        }.value
        try Task.checkCancellation()

        guard let prepared else {
            print("❌ No decoder available for: \(url.lastPathComponent)")
            throw NSError(domain: "SFBAudioEngineManager", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Unsupported audio format"
            ])
        }

        let track = prepared.track
        let decoder = prepared.decoder
        let decoderUsesDoP = prepared.usesDoP

        // CarPlay may have connected while the decoder was being opened off the
        // main actor. The route notification tears down AudioPlayer, but the DSD
        // setup below would otherwise create it again and leave SFB active on a
        // route where it is deliberately unsupported.
        if carPlayIsActiveNow {
            try? decoder.close()
            throw NSError(domain: "SFBAudioEngine", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "SFBAudioEngine unavailable in CarPlay - using native playback"
            ])
        }

        // The mode requested before preparation is not authoritative: a DoP
        // request may have fallen back to PCM. Derive the truth from the
        // decoder and apply the safety gate again after the asynchronous work,
        // since the output route may also have changed while it was opening.
        if decoderUsesDoP && !routeCanCarryDoP() {
            try? decoder.close()
            throw NSError(
                domain: "SFBAudioEngineManager",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "The current audio route cannot carry the prepared DoP stream safely"]
            )
        }

        currentTrack = track
        duration = track.duration
        print("📊 Track duration: \(duration) seconds")
        print("🔧 Decoder created and opened successfully; actualDoP=\(decoderUsesDoP)")
        print("🔧 Decoder format: \(decoder.processingFormat)")
        print("🔧 Decoder sample rate: \(decoder.processingFormat.sampleRate)")
        print("🔧 Decoder channel count: \(decoder.processingFormat.channelCount)")

        // Also try to get source format for comparison
        let sourceFormat = decoder.sourceFormat
        print("🔧 Source format: \(sourceFormat)")
        print("🔧 Source sample rate: \(sourceFormat.sampleRate)")
        print("🔧 Source channel count: \(sourceFormat.channelCount)")

        // Validate decoder properties before proceeding
        let decoderSampleRate = decoder.processingFormat.sampleRate
        let decoderChannelCount = decoder.processingFormat.channelCount

        guard decoderSampleRate > 0, decoderChannelCount > 0 else {
            let error = NSError(
                domain: "SFBAudioEngineManager",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "Decoder opened without a valid processing format",
                    NSLocalizedFailureReasonErrorKey: "sampleRate=\(decoderSampleRate), channels=\(decoderChannelCount)"
                ]
            )
            print("❌ \(error.localizedDescription): \(error.localizedFailureReason ?? "unknown format")")
            throw error
        }

        print("✅ Valid decoder properties: sampleRate=\(decoderSampleRate), channels=\(decoderChannelCount)")
        self.decoderSampleRate = decoderSampleRate

        // Store decoder properties for seeking when AudioFile properties are unavailable
        decoderFrameLength = decoder.length
        print("🔄 Stored decoder properties: frameLength=\(decoderFrameLength), sampleRate=\(self.decoderSampleRate)")

        // Update duration from decoder if it wasn't available from AudioFile and we have valid properties
        if duration == 0 && decoderFrameLength > 0 && self.decoderSampleRate > 0 {
            duration = Double(decoderFrameLength) / self.decoderSampleRate
            print("🔄 Updated duration from decoder: \(duration)s")
        }

        if isDSDFile {
            print("🔄 Resetting AudioPlayer for DSD file to prevent state issues")
            resetAudioPlayer()
        } else if audioPlayer?.isPlaying == true {
            print("🔄 Stopping existing playback before starting new track")
            audioPlayer?.stop()
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        // Enqueue only. SFBAudioPlayer exposes a real prepare/enqueue API, so a
        // load no longer needs to render a frame and then race to pause it.
        print("🎵 Preparing SFBAudioEngine decoder...")
        try Task.checkCancellation()
        do {
            guard let player = audioPlayer else {
                throw NSError(domain: "SFBAudioEngine", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "AudioPlayer not initialized"
                ])
            }
            try player.enqueue(decoder, immediate: true)
            loadedDecoder = decoder
            loadedDecoderIsDSD = isDSDFile
            loadedDecoderUsesDoP = decoderUsesDoP
            hasConfiguredSessionForLoadedDecoder = false
            hasReportedEndOfAudio = false

            // Decoder activation happens off-thread. Waiting briefly for the
            // ready state makes a preserved-position seek reliable before the
            // caller starts playback, without ever producing audible output.
            //
            // A `while` rather than `for … where`: the `where` form skips the
            // body once the player is ready but keeps iterating to the end of
            // the range, which reads as an early exit and is not one. Giving up
            // after the budget is deliberate - the decoder is enqueued either
            // way, and play() is what actually has to succeed.
            var readinessAttemptsRemaining = 100
            while !player.isReady, readinessAttemptsRemaining > 0 {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 10_000_000)
                readinessAttemptsRemaining -= 1
            }

            // The readiness wait is another suspension point at which CarPlay
            // can take over. Do not report a decoder as loaded after the route
            // handler has invalidated its player.
            guard !carPlayIsActiveNow, audioPlayer === player else {
                stop()
                throw NSError(domain: "SFBAudioEngine", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "SFBAudioEngine unavailable in CarPlay - using native playback"
                ])
            }

            print("✅ SFBAudioEngine decoder prepared successfully")
        } catch {
            print("❌ Failed to prepare SFBAudioEngine decoder: \(error)")
            // Let PlayerEngine handle error processing and user feedback
            throw error
        }

        print("✅ SFBAudioEngine loaded without playback: \(url.lastPathComponent)")
    }

    /// Hands the next track to SFBAudioPlayer so it renders straight on from
    /// the current one. Returns whether it was accepted.
    ///
    /// Deliberately conservative - it declines rather than risking the
    /// transition whenever anything about the successor is not a plain
    /// continuation of what is already playing:
    ///
    /// - DSD on either side. The session is configured for one specific DoP
    ///   carrier rate (or one PCM conversion rate) immediately before play,
    ///   and a gapless hand-off cannot reconfigure it mid-render.
    /// - A format SFBAudioPlayer itself says will not be gapless. That check
    ///   (`formatWillBeGaplessIfEnqueued`) is the library's own answer to
    ///   whether the processing graph can continue without a rebuild, so it is
    ///   the right gate rather than a rate/channel comparison of our own.
    ///
    /// A refusal is not an error: the caller simply falls back to the ordinary
    /// stop/load/play transition it has always used.
    @discardableResult
    func enqueueGaplessNext(url: URL) async throws -> Bool {
        guard let player = audioPlayer, loadedDecoder != nil else { return false }
        guard !carPlayIsActiveNow else { return false }
        guard gaplessNext == nil else { return false }

        // DSD is never continued gaplessly - see above.
        guard !loadedDecoderIsDSD else { return false }
        let ext = url.pathExtension.lowercased()
        guard ext != "dsf", ext != "dff" else { return false }

        // The current decoder must still be the one rendering, or we would be
        // queueing behind a track that is already on its way out.
        guard player.isPlaying || player.isPaused else { return false }

        try Task.checkCancellation()

        // Reading properties, building the decoder AND opening it are all
        // synchronous file work, so all three happen off the main actor.
        // `decoder.open()` in particular reads the file's headers; leaving it
        // here stalled the main thread on the one path whose whole purpose is
        // to make a track boundary seamless.
        let prepared = try await Task.detached(priority: .utility) { () -> PreparedDecoder? in
            let track = SFBTrack(url: url)
            try Task.checkCancellation()
            guard let decoder = try track.decoder(enableDoP: false) else { return nil }
            try decoder.open()
            return PreparedDecoder(track: track, decoder: decoder, usesDoP: decoder is DoPDecoder)
        }.value
        try Task.checkCancellation()

        guard let prepared else { return false }
        let track = prepared.track
        let decoder = prepared.decoder

        // Re-check the preconditions that could have changed while the decoder
        // was being opened off-actor. Enqueueing behind a player that has since
        // stopped, or on top of a successor another pass already queued, would
        // leak a decoder and desync `gaplessNext` from the player's own queue.
        guard self.audioPlayer === player,
              gaplessNext == nil,
              loadedDecoder != nil,
              !carPlayIsActiveNow,
              player.isPlaying || player.isPaused else {
            return false
        }

        guard decoder.processingFormat.sampleRate > 0,
              decoder.processingFormat.channelCount > 0 else {
            print("ℹ️ Gapless candidate opened without a valid format: \(url.lastPathComponent)")
            return false
        }

        guard player.formatWillBeGaplessIfEnqueued(decoder.processingFormat) else {
            print("ℹ️ SFBAudioPlayer says \(url.lastPathComponent) will not be gapless - using a normal transition")
            return false
        }

        try player.enqueue(decoder, immediate: false)
        gaplessNext = GaplessNext(url: url, decoder: decoder, track: track)
        print("✅ Enqueued gapless successor on SFBAudioEngine: \(url.lastPathComponent)")
        return true
    }

    /// Takes back a successor that has been queued but not started. Only the
    /// queued decoders are dropped; the one currently rendering is untouched.
    func clearGaplessNext() {
        guard let next = gaplessNext else { return }

        // ...which is exactly why the successor has to be checked first.
        // SFBAudioPlayer switches decoders on the audio thread and reports it
        // through `nowPlayingChanged`, which only reaches this actor a hop
        // later - so a queue edit landing in that window found `gaplessNext`
        // still set for a decoder that was already rendering. `clearQueue()`
        // empties `queuedDecoders_` alone and cannot recall an active one, so
        // dropping the record here left the new track playing while
        // `currentTrack`, `duration`, `decoderFrameLength` and
        // `decoderSampleRate` all still described the old one: the position
        // counter, the scrubber and the fallback end detector were measured
        // against the wrong length, and the promotion callback that keeps
        // PlayerEngine's queue index in step never fired at all.
        //
        // The audio cannot be taken back, so adopt it instead of pretending it
        // did not happen.
        if let nowPlaying = audioPlayer?.nowPlaying,
           ObjectIdentifier(nowPlaying as AnyObject) == ObjectIdentifier(next.decoder as AnyObject) {
            print("↪️ Gapless successor is already rendering - promoting it instead of dropping it")
            promoteGaplessNext(next)
            return
        }

        gaplessNext = nil
        audioPlayer?.clearQueue()
        print("♻️ Dropped the queued SFBAudioEngine successor")
    }

    /// Adopts the successor as the loaded track once the player has switched to
    /// it. Everything here is bookkeeping - the audio has already moved on.
    private func promoteGaplessNext(_ next: GaplessNext) {
        gaplessNext = nil

        loadedDecoder = next.decoder
        loadedDecoderIsDSD = false
        loadedDecoderUsesDoP = false
        // The successor is rendering through the session the current track
        // established, and `formatWillBeGaplessIfEnqueued` is exactly the
        // guarantee that it did not need changing. Re-running the DoP/rate
        // configuration here would deactivate a live session mid-track.
        hasConfiguredSessionForLoadedDecoder = true

        currentTrack = next.track
        duration = next.track.duration
        decoderFrameLength = next.track.frameLength
        decoderSampleRate = next.track.sampleRate > 0
            ? next.track.sampleRate
            : next.decoder.processingFormat.sampleRate
        currentTime = 0
        hasReportedEndOfAudio = false

        print("⏭️ SFBAudioEngine continued gaplessly into: \(next.url.lastPathComponent)")
        onGaplessTrackStarted?(next.url)
    }

    func play() throws {
        // Final fail-closed check. A route transition can occur after load()
        // returns but before PlayerEngine asks this manager to start rendering.
        guard !carPlayIsActiveNow else {
            throw NSError(domain: "SFBAudioEngine", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "SFBAudioEngine unavailable in CarPlay - using native playback"
            ])
        }

        if let player = audioPlayer {
            // Already rendering: adopt it and touch nothing.
            //
            // SFBAudioPlayer installs its own AVAudioSession interruption
            // observer and resumes itself on `.ended`. Our `.ended` handler
            // runs a main-actor hop later, by which point the player can
            // already be playing, and everything below is then either
            // redundant or fatal:
            //
            //  - configureAudioSessionForDecoder() deactivates and reactivates
            //    the session underneath a live render graph, to apply a
            //    preferred rate the hardware has already settled on.
            //  - AudioPlayer::play() starts the engine while the player's own
            //    `wasPlaying` flag is still set, tripping
            //        Assertion failed: (!(didStartEngine && wasPlaying))
            //    in AudioPlayer.mm - which aborts the process, not the call.
            //
            // Same rule stopEngineForInterruption() documents for the pause
            // side: never touch this player's engine behind its back.
            if player.isPlaying {
                print("▶️ SFBAudioEngine had already resumed itself - adopting its state")
                isPlaying = true
                hasReportedEndOfAudio = false
                resetPlaybackStallDetection()
                startUpdateTimer()
                return
            }

            if !hasConfiguredSessionForLoadedDecoder, let decoder = loadedDecoder {
                let actualSampleRate = decoderSampleRate
                print("🔍 Configuring loaded decoder at \(actualSampleRate)Hz before playback")
                do {
                    try configureAudioSessionForDecoder(
                        decoder: decoder,
                        isDSD: loadedDecoderIsDSD,
                        enableDoP: loadedDecoderUsesDoP
                    )
                    hasConfiguredSessionForLoadedDecoder = true
                } catch {
                    // Leave the flag clear so the next play()/resume retries.
                    // Setting it unconditionally meant one failed sample-rate,
                    // buffer or category call was accepted for the life of the
                    // loaded track: DoP or the matched rate never came back
                    // until the track was reloaded from scratch.
                    print("⚠️ Audio session configuration failed - will retry on next play: \(error)")
                    // PCM can still be converted by the system at its current
                    // hardware rate. DoP cannot: rendering it after a route or
                    // exact-rate failure produces digital noise, so the DoP
                    // decoder that is loaded must not be played.
                    if loadedDecoderUsesDoP {
                        // But refusing the carrier rate is not a reason to
                        // refuse the song. Unless the route is a *proven* DAC -
                        // where a rate failure really does mean "this DSD
                        // stream cannot be delivered here" and the user asked
                        // for bit-exact playback - remember the refusal and ask
                        // the caller to reload. load() consults
                        // `doPRefusedPaths` and builds a PCM decoder instead,
                        // which is a genuine format change rather than the old
                        // fallback's "keep the DoP stream, just move the
                        // carrier rate" - that produced noise.
                        if let url = currentTrack?.url, !routeLikelyHasExternalDAC() {
                            doPRefusedPaths.insert(url.standardizedFileURL.path)
                            throw NSError(
                                domain: "SFBAudioEngineManager",
                                code: 8,
                                userInfo: [
                                    NSLocalizedDescriptionKey: "The route refused the DoP carrier rate - reload as PCM",
                                    NSUnderlyingErrorKey: error
                                ]
                            )
                        }
                        throw error
                    }
                }
            }

            // Reactivate audio session when resuming
            do {
                let audioSession = AVAudioSession.sharedInstance()
                try audioSession.setActive(true)
                print("✅ Audio session reactivated on resume")
            } catch {
                print("⚠️ Failed to reactivate audio session on resume: \(error)")
                throw error
            }

            if player.isPaused {
                guard player.resume() else {
                    throw NSError(domain: "SFBAudioEngineManager", code: 5, userInfo: [
                        NSLocalizedDescriptionKey: "SFBAudioEngine could not resume playback"
                    ])
                }
            } else {
                try player.play()
            }
            isPlaying = true
            hasReportedEndOfAudio = false
            resetPlaybackStallDetection()
            startUpdateTimer()
            if let decoder = loadedDecoder {
                attachEqualizerToEngine(with: decoder.processingFormat)
            }
            print("▶️ SFBAudioEngine resumed playback")
        } else {
            throw NSError(domain: "SFBAudioEngineManager", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "AudioPlayer not initialized"
            ])
        }
    }

    func pause() {
        print("⏸️ SFBAudioEngineManager.pause() called")

        // Pause the audio player
        audioPlayer?.pause()
        isPlaying = false
        resetPlaybackStallDetection()
        updateTimer?.invalidate()

        // Do NOT deactivate the session here. PlayerEngine.pause() deliberately
        // keeps it active for the native backend, and deactivating with
        // .notifyOthersOnDeactivation made pausing an Opus/Vorbis/DSD track
        // behave differently from pausing a FLAC: on Bluetooth and other
        // external routes it tore the route down and invited another app to
        // take over, and resuming then paid for a fresh route negotiation.
        // Control Centre state comes from MPNowPlayingInfoCenter.playbackState,
        // which PlayerEngine updates, not from the session's active flag.
        print("✅ SFBAudioEngineManager paused")
    }

    /// Pause playback for an audio session interruption (alarm, phone call).
    /// SFBAudioPlayer observes AVAudioSessionInterruptionNotification itself:
    /// it pauses on .began and restarts its engine on .ended. Never stop or
    /// start the engine behind its back - SFBAudioPlayer asserts that the
    /// engine's run state matches its cached flag, and the system has
    /// already stopped the engine by the time the notification arrives, so
    /// doing so aborts the app (App Store crash group on 1.2.2).
    func stopEngineForInterruption() {
        resetPlaybackStallDetection()

        // `stop()`, not `pause()`.
        //
        // SFBAudioPlayer's pause() keeps its AVAudioEngine running so it can
        // resume instantly, and a running engine holds the Bluetooth channel.
        // That is why a Waze alert configured to speak "as a phone call" could
        // never acquire the hands-free channel while an Opus or DSD track was
        // loaded - the prompt was aborted before a word came out - while the
        // same alert worked over FLAC, where the native path fully stops its
        // engine on `.began`.
        //
        // This is the player's own public API, not us stopping its engine
        // behind its back, so its internal run-state flags stay consistent and
        // the AudioPlayer.mm assertion is not at risk.
        //
        // The decoder queue does not survive stop(), so the resume has to
        // reload: `hasLoadedDecoder` reports that, and PlayerEngine's play path
        // falls through to its reload-and-seek branch when it is false.
        audioPlayer?.stop()
        isPlaying = false
        updateTimer?.invalidate()
        updateTimer = nil
        loadedDecoder = nil
        gaplessNext = nil
        hasConfiguredSessionForLoadedDecoder = false
        // Suppress the end-of-audio the teardown itself may report.
        hasReportedEndOfAudio = true
        // `currentTime` is deliberately left alone. PlayerEngine captured the
        // position before calling this and restores it afterwards; zeroing it
        // here would race that and resume the track from the beginning.
        print("⏸️ SFBAudioEngine stopped for interruption - resume will reload")
    }

    /// Whether a decoder is loaded and ready to render.
    ///
    /// False after `stopEngineForInterruption()`, which releases the engine
    /// entirely so another app can take the route.
    var hasLoadedDecoder: Bool { loadedDecoder != nil }

    func stop() {
        hasReportedEndOfAudio = true
        gaplessNext = nil
        audioPlayer?.stop()
        isPlaying = false
        currentTime = 0
        currentTrack = nil
        decoderFrameLength = 0
        decoderSampleRate = 0
        loadedDecoder = nil
        loadedDecoderIsDSD = false
        loadedDecoderUsesDoP = false
        hasConfiguredSessionForLoadedDecoder = false
        updateTimer?.invalidate()
        updateTimer = nil
        cleanupEqualizer()
    }

    func seek(to time: TimeInterval) throws {
        guard let player = audioPlayer, let track = currentTrack else {
            print("❌ No audio player or track available for seeking")
            throw NSError(domain: "SFBAudioEngineManager", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "No audio player available"
            ])
        }

        print("🔍 SFBAudioEngine seeking to: \(time)s (duration: \(duration)s)")

        // For DSD files, try time-based seeking only (frame seeking can cause issues)
        let fileExtension = track.url.pathExtension.lowercased()
        let isDSDFile = fileExtension == "dsf" || fileExtension == "dff"

        if isDSDFile {
            print("🔍 DSD file detected - trying time-based seeking only")
            guard player.seek(time: time) else {
                print("❌ DSD seeking failed: \(time)s")
                throw seekRejected(time)
            }
            currentTime = time
            print("✅ DSD file seeked to time: \(time)s")
            return
        }

        // Calculate frame position based on time and sample rate for non-DSD files
        // Use decoder properties if track properties are unavailable (common for M4A files)
        let useSampleRate = track.sampleRate > 0 ? track.sampleRate : decoderSampleRate
        let useTotalFrames = track.frameLength > 0 ? track.frameLength : decoderFrameLength

        if useSampleRate > 0 && duration > 0 && time <= duration && useTotalFrames > 0 {
            let framePosition = Int64(time * useSampleRate)

            // Ensure we don't seek past the end of the file
            let safeFramePosition = min(framePosition, max(0, useTotalFrames - 1))

            print("🔍 Seeking to frame: \(safeFramePosition) of \(useTotalFrames) (time: \(time)s, sampleRate: \(useSampleRate))")

            // Try frame-based seeking first (most precise)
            if player.seek(frame: AVAudioFramePosition(safeFramePosition)) {
                currentTime = time
                print("✅ SFBAudioEngine seeked to frame: \(safeFramePosition)")
                return
            }

            // Frame seeking failed, try time-based seeking
            if player.seek(time: time) {
                currentTime = time
                print("✅ SFBAudioEngine seeked to time: \(time)s (frame seek failed)")
                return
            }

            // Both were refused, so the decoder has not moved. currentTime must
            // NOT be advanced here: reporting a seek that did not happen made
            // PlayerEngine log success and push the new position to the
            // scrubber and the CarPlay/lock-screen timeline, which then snapped
            // back to the real position on the next poll.
            print("❌ Both frame and time seeking failed: \(time)s")
            throw seekRejected(time)
        }

        // No usable sample rate or frame count - time-based seeking is the only
        // thing left to try, and its result still has to be honest.
        guard player.seek(time: time) else {
            print("❌ Time-only seeking failed: \(time)s")
            throw seekRejected(time)
        }
        currentTime = time
        print("✅ SFBAudioEngine seeked by time (no frame information): \(time)s")
    }

    /// The decoder refused to move. Distinct from code 4 ("no player at all"):
    /// callers must not publish `time` as the new position either way.
    private func seekRejected(_ time: TimeInterval) -> NSError {
        NSError(domain: "SFBAudioEngineManager", code: 5, userInfo: [
            NSLocalizedDescriptionKey: "Seek to \(time)s was rejected by the decoder"
        ])
    }

    // MARK: - Timer Management

    private func startUpdateTimer() {
        updateTimer?.invalidate()
        // .common mode, not the default one: a plain scheduledTimer stops
        // firing while a scroll view is tracking, which used to strand the
        // position counter every time the user flicked through a list.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updatePlaybackPosition()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
    }

    /// Watches for "playing, but standing still".
    ///
    /// `AudioPlayer.isPlaying` describes the player's intent, not whether audio
    /// is reaching the speakers. After a Bluetooth navigation prompt the player
    /// can resume itself onto the 16kHz mono hands-free graph, and if the car
    /// returns to A2DP without a second configuration change reaching it, the
    /// graph stays wired for a route that is gone: `isPlaying` is true,
    /// `currentTime` never moves, and nothing else notices. Only a position
    /// that fails to advance can distinguish that from real playback.
    private func noteObservedPlaybackTime(_ playerTime: TimeInterval) {
        // A queued successor legitimately holds the position still across the
        // boundary, and a paused player is not expected to advance.
        guard isPlaying, gaplessNext == nil else {
            lastObservedPlaybackTime = playerTime
            lastPlaybackAdvanceAt = Date()
            return
        }

        if abs(playerTime - lastObservedPlaybackTime) > 0.001 {
            lastObservedPlaybackTime = playerTime
            lastPlaybackAdvanceAt = Date()
            return
        }

        let stalledFor = Date().timeIntervalSince(lastPlaybackAdvanceAt)
        guard stalledFor >= Self.stallDetectionWindow else { return }

        // Re-arm before reporting so a recovery that takes a moment cannot
        // retrigger this on every subsequent tick.
        lastPlaybackAdvanceAt = Date()
        print("⚠️ SFBAudioEngine claims to be playing but the position has not moved for \(String(format: "%.1f", stalledFor))s")
        onPlaybackStalled?()
    }

    /// Forgets the stall window - call whenever the transport legitimately
    /// changes, so a fresh start is never judged against an old observation.
    private func resetPlaybackStallDetection() {
        lastObservedPlaybackTime = -1
        lastPlaybackAdvanceAt = Date()
    }

    private func updatePlaybackPosition() {
        if isPlaying, let player = audioPlayer {
            // Ask the player where it actually is. This used to add exactly
            // 0.1 per timer callback, so the reported position was a guess
            // that drifted from the audio whenever the timer was starved,
            // ignored the real decode rate, and drove PlayerEngine's
            // end-of-track detection - which is why Opus/Vorbis/DSD tracks
            // scrubbed inaccurately and advanced late.
            if let playerTime = player.currentTime {
                currentTime = duration > 0 ? min(playerTime, duration) : playerTime
                noteObservedPlaybackTime(playerTime)
            } else if currentTime < duration || duration <= 0 {
                // Position unknown (some decoders cannot report it); fall back
                // to advancing by the timer interval so the UI still moves.
                currentTime += 0.1
                if duration > 0 { currentTime = min(currentTime, duration) }
            }

            // Log position every 10 seconds for debugging
            if Int(currentTime * 10) % 100 == 0 {
                print("🎵 SFBAudioEngine position: \(currentTime)/\(duration)")
            }

            if duration > 0 && currentTime >= duration {
                reportEndOfAudioIfNeeded()
            }
        }
    }

    private func reportEndOfAudioIfNeeded() {
        guard !hasReportedEndOfAudio else { return }
        // A queued successor means the player renders straight through this
        // boundary; `nowPlayingChanged` advances instead. Reporting an end here
        // would make PlayerEngine tear the player down and reload the very
        // track that is about to start on its own.
        guard gaplessNext == nil else { return }
        hasReportedEndOfAudio = true
        print("🏁 SFBAudioEngine track completed: \(currentTime)/\(duration)")
        isPlaying = false
        updateTimer?.invalidate()
        updateTimer = nil
        onPlaybackEnded?()
    }

    private func reportCurrentPlaybackFailure(_ error: Error) {
        // Do not discard an abort merely because endOfAudio won the delegate
        // callback race and set this latch first. The decoder identity check in
        // decodingAborted still proves that this is the currently loaded item;
        // surfacing the failure then prevents the queued end handler from
        // silently advancing it as a successful track.
        hasReportedEndOfAudio = true
        gaplessNext = nil
        isPlaying = false
        updateTimer?.invalidate()
        updateTimer = nil
        onPlaybackFailed?(error)
    }

    // MARK: - EQ Support

    /// Returns whether EQ is supported for this playback engine
    static func supportsEQ() -> Bool {
        return true
    }

    /// Update EQ settings from EQManager (applies to native SFBAudioEngine EQ)
    func updateEQSettings() {
        // Enabling EQ during an already-playing track used to do nothing at
        // all: attachEqualizerToEngine only runs at load time and bails unless
        // EQ was already on, so no node existed, and applySFBEQSettings
        // returns immediately when sfbEqualizer is nil. Attach it now instead.
        if eqManager.isEnabled, sfbEqualizer == nil, let decoder = loadedDecoder {
            // An explicit user toggle is a good reason to retry a previously
            // failed attachment.
            eqAttachmentFailed = false
            attachEqualizerToEngine(with: decoder.processingFormat)
            return
        }

        applySFBEQSettings()
    }

    private func configureSFBEQBands(_ equalizer: AVAudioUnitEQ) {
        // Apply frequency-specific gains from EQManager
        let eqFrequencies = eqManager.currentEQFrequencies
        let eqGains = eqManager.currentEQGains
        let eqBandwidths = eqManager.currentEQBandwidths

        if !eqFrequencies.isEmpty && !eqGains.isEmpty {
            // Use EQManager's exact frequencies and gains
            let availableBands = equalizer.bands.count
            let inputBandCount = min(eqFrequencies.count, eqGains.count)

            if inputBandCount <= availableBands {
                // Direct mapping - use exactly what we have
                for i in 0..<inputBandCount {
                    let band = equalizer.bands[i]
                    band.frequency = Float(eqFrequencies[i])
                    band.gain = Float(eqGains[i])
                    let bandwidth = i < eqBandwidths.count ? eqBandwidths[i] : 1.0
                    band.bandwidth = Float(max(0.05, min(5.0, bandwidth)))
                    band.filterType = .parametric
                    band.bypass = false
                }

                // Bypass remaining bands
                for i in inputBandCount..<availableBands {
                    equalizer.bands[i].bypass = true
                }

                print("🎛️ Direct mapping: Using all \(inputBandCount) EQ bands")
            } else {
                // More input bands than available - group and average
                print("🔄 Reducing \(inputBandCount) bands to \(availableBands) bands")

                let bandsPerGroup = Double(inputBandCount) / Double(availableBands)

                for i in 0..<availableBands {
                    // Calculate the range of input bands for this output band
                    let startIndex = Int(Double(i) * bandsPerGroup)
                    let endIndex = min(Int(Double(i + 1) * bandsPerGroup), inputBandCount)

                    // Average the frequencies and gains for this group
                    var avgFrequency = 0.0
                    var avgGain = 0.0
                    var avgBandwidth = 0.0
                    var groupSize = 0

                    for j in startIndex..<endIndex {
                        if j < eqFrequencies.count && j < eqGains.count {
                            avgFrequency += eqFrequencies[j]
                            avgGain += eqGains[j]
                            avgBandwidth += j < eqBandwidths.count ? eqBandwidths[j] : 1.0
                            groupSize += 1
                        }
                    }

                    if groupSize > 0 {
                        avgFrequency /= Double(groupSize)
                        avgGain /= Double(groupSize)
                        avgBandwidth /= Double(groupSize)
                    }

                    let band = equalizer.bands[i]
                    band.frequency = Float(avgFrequency)
                    band.gain = Float(avgGain)
                    band.bandwidth = Float(max(0.05, min(5.0, avgBandwidth)))
                    band.filterType = .parametric
                    band.bypass = false

                    print("  Band \(i): \(Int(avgFrequency))Hz, \(String(format: "%.1f", avgGain))dB (avg of \(groupSize) bands)")
                }

                print("✅ Applied frequency grouping and averaging")
            }
        } else {
            // No EQ data - configure with default geometric spacing
            let minFreq = 20.0
            let maxFreq = 20000.0
            let bandCount = equalizer.bands.count

            for i in 0..<bandCount {
                let band = equalizer.bands[i]
                let frequency = minFreq * pow(maxFreq / minFreq, Double(i) / Double(bandCount - 1))

                band.frequency = Float(frequency)
                band.gain = 0.0
                band.bandwidth = 1.0
                band.filterType = .parametric
                band.bypass = false
            }

            print("🎛️ Configured \(bandCount) SFBAudioEngine EQ bands with default frequencies")
        }
    }

    private func applySFBEQSettings() {
        guard let equalizer = sfbEqualizer else {
            print("⚠️ No SFBAudioEngine equalizer to update")
            return
        }

        // Apply enabled state
        equalizer.bypass = !eqManager.isEnabled

        // Apply global gain
        equalizer.globalGain = Float(eqManager.globalGain)

        // Reconfigure bands with current EQ settings
        configureSFBEQBands(equalizer)

        print("🎛️ SFBAudioEngine EQ updated: enabled=\(eqManager.isEnabled), globalGain=\(eqManager.globalGain)dB")
    }

    // MARK: - Format Support Check

    static func canHandle(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()

        // Route all formats except WAV, FLAC, MP3, M4A, and AAC to SFBAudioEngine
        // M4A and AAC should be handled natively by AVAudioEngine for better compatibility
        let nativeFormats = ["wav", "flac", "mp3", "m4a", "aac"]
        let basicCanHandle = !nativeFormats.contains(ext)

        // For DSD files, let PlayerEngine handle the detailed sample rate validation
        // since it depends on whether we're using DoP or PCM conversion
        if basicCanHandle && (ext == "dsf" || ext == "dff") {
            print("🔍 SFBAudioEngine.canHandle(\(url.lastPathComponent)): ext=\(ext), canHandle=true (DSD - validation deferred to PlayerEngine)")
            return true
        }

        print("🔍 SFBAudioEngine.canHandle(\(url.lastPathComponent)): ext=\(ext), canHandle=\(basicCanHandle)")
        return basicCanHandle
    }

    // MARK: - Audio Session Management

    /// Applies a decoder's preferred rate and buffer, tolerating a refusal.
    ///
    /// At the end of an interruption the session frequently will not deactivate
    /// - our own paused SFBAudioPlayer still holds audio objects and the route
    /// has only just come back - so `setActive(false)` does not take effect and
    /// the property setters then run against a live session and answer paramErr
    /// (-50). Letting that throw abandoned the entire configuration: the caller
    /// never set `hasConfiguredSessionForLoadedDecoder`, every later resume
    /// repeated the identical failure, and the preferred rate was never applied
    /// at all - so a 48kHz Opus track played resampled through 44.1kHz hardware
    /// for the rest of its duration after a single navigation prompt.
    ///
    /// A refused preference costs quality, not playback: SFBAudioPlayer's graph
    /// converts to whatever the hardware runs at. So it must not cost playback
    /// either, and it must not be silent about it.
    ///
    /// Deliberately NOT used by the DoP branch, where an unachieved rate is
    /// genuinely fatal and has to keep throwing.
    ///
    /// - Returns: whether the hardware ended up at the requested rate.
    @discardableResult
    private func applyPreferredOutputFormat(
        _ audioSession: AVAudioSession,
        sampleRate: Double,
        bufferDuration: TimeInterval
    ) throws -> Bool {
        do {
            try audioSession.setActive(false)
        } catch {
            print("ℹ️ Audio session would not deactivate - applying preferences in place: \(error)")
        }

        do {
            try audioSession.setPreferredSampleRate(sampleRate)
            try audioSession.setPreferredIOBufferDuration(bufferDuration)
        } catch {
            print("⚠️ Audio session refused the preferred rate/buffer: \(error)")
        }

        try audioSession.setActive(true)

        let achieved = abs(audioSession.sampleRate - sampleRate) < 1.0
        if !achieved {
            print("🔊 Hardware stayed at \(audioSession.sampleRate)Hz for a \(sampleRate)Hz decoder - SFBAudioEngine will resample")
        }
        return achieved
    }

    /// Configure audio session to match decoder's exact requirements (critical for DoP)
    func configureAudioSessionForDecoder(decoder: PCMDecoding, isDSD: Bool, enableDoP: Bool) throws {
        let audioSession = AVAudioSession.sharedInstance()
        let decoderSampleRate = decoder.processingFormat.sampleRate

        print("🎵 Configuring audio session for decoder: sampleRate=\(decoderSampleRate)Hz, isDSD=\(isDSD), enableDoP=\(enableDoP)")

        // Check if we can avoid changing sample rate to prevent buffer underruns
        // Based on SFBAudioEngine issues #347 and #503, frequent rate changes cause problems.
        // Ask the session what the hardware is actually running at. This used
        // to compare against a cached `lastConfiguredSampleRate` that only this
        // class ever wrote, so native playback moving the hardware in between
        // (Opus 48k → 96k FLAC → the same Opus) left the cache agreeing with
        // the decoder while the hardware sat somewhere else entirely, and the
        // reconfiguration this guard skipped was the one that mattered.
        if !isDSD, abs(audioSession.sampleRate - decoderSampleRate) < 1.0 {
            // Skipping the deactivate/reconfigure/reactivate cycle must not
            // also skip establishing the category. Nothing else on the SFB
            // path sets it - PlayerEngine calls ensureAudioSessionSetup() only
            // from its native branch, and play() returns from the SFB branch
            // before reaching it - so on a cold launch whose first track is
            // Opus (always 48kHz, which matches the idle hardware rate, so
            // this return is always taken) the session stayed at the default
            // .soloAmbient: silenced by the Ring/Silent switch and stopped
            // when the screen locks.
            if audioSession.category != .playback {
                try audioSession.setCategory(.playback, mode: .default, options: [.allowBluetoothA2DP])
                print("✅ Set .playback category without disturbing the hardware rate")
            }
            print("🔄 Skipping audio session reconfiguration - hardware already at \(audioSession.sampleRate)Hz")
            return
        }

        if isDSD && enableDoP {
            // For DSD over DoP, session sample rate MUST exactly match decoder output
            print("🎵 Configuring audio session for DSD over DoP - EXACT rate matching required")

            guard routeCanCarryDoP() else {
                throw NSError(
                    domain: "SFBAudioEngineManager",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "The current audio route cannot carry DoP safely"]
                )
            }

            // Log current session state before changes
            print("🔍 Current session state - Rate: \(audioSession.sampleRate)Hz, Buffer: \(audioSession.ioBufferDuration)s")

            // Do not advertise lossy/wireless routes while emitting a
            // bit-exact DoP stream.
            try audioSession.setCategory(.playback, mode: .default, options: [])
            print("✅ Audio session category set for DoP")

            // CRITICAL: Deactivate session first as recommended by SFBAudioEngine wiki
            try audioSession.setActive(false)
            print("✅ Audio session deactivated")

            // DoP has no compatible fallback rate. The PCM carrier must match
            // the decoder output exactly.
            var targetSampleRate = decoderSampleRate

            // If the decoder reports 0.0 (invalid), use CORRECT DoP rate calculation from GitHub issue #185
            // DoP sample rate = DSD sample rate / 16
            if decoderSampleRate <= 0 {
                print("⚠️ Decoder reports invalid sample rate (\(decoderSampleRate)Hz), using DSD rate calculation")
                if let track = currentTrack {
                    let originalRate = track.sampleRate
                    if originalRate > 0 {
                        targetSampleRate = originalRate / 16.0  // Correct DoP formula from GitHub issue #185
                        print("🔄 DSD rate calculation: \(originalRate)Hz ÷ 16 = \(targetSampleRate)Hz (DoP)")
                        print("🔄 Track properties: sampleRate=\(track.sampleRate), frameLength=\(track.frameLength), duration=\(track.duration)")
                    } else {
                        targetSampleRate = 176400 // Default to DSD64 DoP rate
                        print("🔄 Track also has invalid rate, using default DoP rate: \(targetSampleRate)Hz")
                    }
                } else {
                    targetSampleRate = 176400 // Default to DSD64 DoP rate
                    print("🔄 No track available, using default DoP rate: \(targetSampleRate)Hz")
                }
            } else {
                targetSampleRate = decoderSampleRate
                print("✅ Using decoder sample rate: \(decoderSampleRate)Hz")
            }

            print("🎵 Setting preferred sample rate: \(targetSampleRate)Hz")

            try audioSession.setPreferredSampleRate(targetSampleRate)
            print("✅ Preferred sample rate requested: \(targetSampleRate)Hz")

            // Use larger, more stable buffer to prevent ring buffer underruns
            // Based on SFBAudioEngine issues #347 and #503, smaller buffers can cause underruns
            do {
                try audioSession.setPreferredIOBufferDuration(0.040) // 40ms buffer for stability
                print("✅ Buffer duration set: 40ms for ring buffer stability")
            } catch {
                print("⚠️ Failed to set buffer duration: \(error)")
                // Try progressively larger buffers for stability
                let fallbackBuffers: [Double] = [0.030, 0.023, 0.020]
                for buffer in fallbackBuffers {
                    do {
                        try audioSession.setPreferredIOBufferDuration(buffer)
                        print("✅ Fallback buffer duration set: \(Int(buffer * 1000))ms")
                        break
                    } catch {
                        print("⚠️ Fallback buffer \(Int(buffer * 1000))ms failed: \(error)")
                    }
                }
            }

            // Reactivate with new settings
            try audioSession.setActive(true, options: [])
            print("✅ Audio session reactivated with new DoP settings")

            // Log final session state after all changes
            print("🎵 DSD DoP audio session configured:")
            print("  📊 Requested sample rate: \(targetSampleRate)Hz")
            print("  📊 Actual session rate: \(audioSession.sampleRate)Hz")
            print("  📊 Buffer duration: \(audioSession.ioBufferDuration)s")
            print("  📊 Category: \(audioSession.category)")
            print("  📊 Mode: \(audioSession.mode)")

            guard abs(audioSession.sampleRate - targetSampleRate) < 1.0 else {
                throw NSError(
                    domain: "SFBAudioEngineManager",
                    code: 7,
                    userInfo: [
                        NSLocalizedDescriptionKey: "The audio route did not accept the exact DoP carrier rate",
                        NSLocalizedFailureReasonErrorKey: "requested=\(targetSampleRate), actual=\(audioSession.sampleRate)"
                    ]
                )
            }
            print("✅ Hardware rate exactly matches the DoP carrier")

        } else if isDSD && !enableDoP {
            // For DSD to PCM conversion, use appropriate sample rate
            print("🎵 Configuring audio session for DSD PCM conversion")

            // No .allowAirPlay: playback rejects it with paramErr (-50). See
            // PlayerEngine.setupAudioSessionCategory.
            try audioSession.setCategory(.playback, mode: .default, options: [.allowBluetoothA2DP])

            // For DSD PCM, use the decoder's output rate. Best-effort: a
            // refusal here downgrades quality, not playback.
            try applyPreferredOutputFormat(
                audioSession,
                sampleRate: decoderSampleRate,
                bufferDuration: 0.040 // 40ms buffer for ring buffer stability
            )

            print("🎵 DSD PCM audio session configured: requested=\(decoderSampleRate)Hz, actual=\(audioSession.sampleRate)Hz")
        } else {
            // For non-DSD files, use standard configuration but still match decoder rate
            try audioSession.setCategory(.playback, mode: .default, options: [.allowBluetoothA2DP])

            try applyPreferredOutputFormat(
                audioSession,
                sampleRate: decoderSampleRate,
                bufferDuration: 0.040 // 40ms buffer for ring buffer stability
            )

            print("🔊 Standard audio session configured: requested=\(decoderSampleRate)Hz, actual=\(audioSession.sampleRate)Hz")
        }
    }

    // MARK: - DAC Detection

    /// Wired transports on which an explicit DoP request may be attempted.
    /// AVAudioSession still cannot prove the attached device understands DoP,
    /// so Auto mode never enables it from the port type alone. Keeping this as
    /// an allowlist is essential: an unknown, mixed or newly-added route must
    /// fall back to PCM rather than receiving a DoP carrier by default.
    private static let externalDACPortTypes: Set<AVAudioSession.Port> = [
        .usbAudio, .lineOut
    ]

    /// Devices that report `.headphones` but definitely are not DACs. Checked
    /// first, so a product name that happens to contain a brand substring
    /// cannot promote a dongle or a pair of earbuds.
    private static let nonDACPortNameMarkers = [
        "macbook", "imac", "mac mini", "mac pro", "mac studio",
        "carplay", "car play", "android auto", "computer", "pc", "laptop",
        "earpods", "airpods", "headset", "earphones", "apple headphones",
        "lightning to 3.5", "usb-c to 3.5"
    ]

    /// Dedicated audio hardware that iOS commonly enumerates as `.headphones`
    /// when connected over Lightning or USB-C.
    private static let dacBrandMarkers = [
        "fosi", "topping", "ifi", "audioquest", "chord", "schiit", "jds", "fiio",
        "denafrips", "ps audio", "mcintosh", "cambridge", "marantz", "denon",
        "smsl", "aune", "gustard", "matrix", "burson", "lehmann", "benchmark",
        "mojo", "hugo", "questyle", "cayin", "astell", "kann", "dx"
    ]

    /// Whether a `.headphones` port is recognisably a real DAC.
    ///
    /// The explicit-DoP safety gate uses this positive identification for a
    /// `.headphones` route: that port type also describes ordinary analogue
    /// dongles, which would render the DoP carrier as noise. Keep the test
    /// conservative: a recognised brand, or an explicit DAC/DSD marker in the
    /// name. Auto mode never relies on device-name heuristics.
    private static func headphonePortIsKnownDAC(_ portName: String) -> Bool {
        let name = portName.lowercased()

        guard !nonDACPortNameMarkers.contains(where: { name.contains($0) }) else {
            return false
        }

        if dacBrandMarkers.contains(where: { name.contains($0) }) {
            return true
        }

        // Explicit markers only. Generic words like "amp" or "hi-res" appear in
        // ordinary marketing names and are not evidence of a DoP-capable DAC.
        return name.contains(" dac") || name.contains("dac ")
            || name.contains("-dac") || name.contains("dac-")
            || name.contains("dsd")
            || name.contains("headphone amplifier")
    }

    /// Whether the current route may be handed a DoP stream at all.
    ///
    /// Deny by default: the carrier is ordinary PCM whose low bits are markers,
    /// so an unknown route that resamples, re-encodes or mixes it can turn it
    /// into full-scale noise. USB/line-out routes retain the explicit user's
    /// DoP choice; a `.headphones` route is accepted only when it is positively
    /// identifiable as a DAC. Auto always selects PCM because the system has no
    /// reliable DoP capability query.
    private func routeCanCarryDoP() -> Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard !outputs.isEmpty else { return false }
        return outputs.allSatisfy { output in
            if Self.externalDACPortTypes.contains(output.portType) {
                return true
            }
            return output.portType == .headphones
                && Self.headphonePortIsKnownDAC(output.portName)
        }
    }

    /// Whether the route looks like external converter hardware. This is not a
    /// DoP capability test and must never be used to enable DoP automatically.
    private func routeLikelyHasExternalDAC() -> Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard !outputs.isEmpty else { return false }
        return outputs.allSatisfy { output in
            if Self.externalDACPortTypes.contains(output.portType) {
                return true
            }
            // A Lightning/USB-C DAC is enumerated as .headphones, so the port
            // type alone cannot answer this. Fall back to recognising the
            // device by name, as this check did before the port lists were
            // tightened.
            return output.portType == .headphones
                && Self.headphonePortIsKnownDAC(output.portName)
        }
    }

    // MARK: - AudioPlayer.Delegate

    nonisolated func audioPlayer(_ audioPlayer: AudioPlayer, nowPlayingChanged nowPlaying: PCMDecoding?) {
        let audioPlayerBox = WeakAudioPlayerBox(audioPlayer)
        // Identity only, as an ObjectIdentifier: the decoder itself is not
        // Sendable, and `gaplessNext` holds a strong reference for the whole
        // window, so the address cannot be recycled underneath the comparison.
        let nowPlayingID = nowPlaying.map { ObjectIdentifier($0 as AnyObject) }
        Task { @MainActor [weak self] in
            guard let self,
                  let audioPlayer = audioPlayerBox.value,
                  self.audioPlayer === audioPlayer,
                  let next = self.gaplessNext,
                  let nowPlayingID,
                  ObjectIdentifier(next.decoder as AnyObject) == nowPlayingID else { return }
            self.promoteGaplessNext(next)
        }
    }

    nonisolated func audioPlayerEndOfAudio(_ audioPlayer: AudioPlayer) {
        let audioPlayerBox = WeakAudioPlayerBox(audioPlayer)
        Task { @MainActor [weak self] in
            guard let self,
                  let audioPlayer = audioPlayerBox.value,
                  self.audioPlayer === audioPlayer,
                  self.isPlaying else { return }
            // Rendering is over for everything the player had, so a successor
            // still sitting in `gaplessNext` never started - its decode failed,
            // or the queue was cleared underneath it. Drop it before reporting:
            // it otherwise suppresses every end-of-track path there is and
            // playback stops silently with no advance.
            if self.gaplessNext != nil {
                print("⚠️ End of audio with a successor still queued - it never started")
                self.gaplessNext = nil
            }
            self.reportEndOfAudioIfNeeded()
        }
    }

    nonisolated func audioPlayer(
        _ audioPlayer: AudioPlayer,
        decodingAborted decoder: PCMDecoding,
        error: Error,
        framesRendered: AVAudioFramePosition
    ) {
        let audioPlayerBox = WeakAudioPlayerBox(audioPlayer)
        let abortedID = ObjectIdentifier(decoder as AnyObject)
        Task { @MainActor [weak self] in
            guard let self,
                  let audioPlayer = audioPlayerBox.value,
                  self.audioPlayer === audioPlayer else { return }

            if let next = self.gaplessNext,
               ObjectIdentifier(next.decoder as AnyObject) == abortedID {
                // The queued successor cannot play. Forget it so the ordinary
                // end-of-track detection is live again for the current track.
                print("⚠️ Queued gapless successor aborted decoding: \(error)")
                self.gaplessNext = nil
                return
            }

            guard let loadedDecoder = self.loadedDecoder,
                  ObjectIdentifier(loadedDecoder as AnyObject) == abortedID else { return }
            print("❌ Current SFBAudioEngine decoder aborted after \(framesRendered) frames: \(error)")
            self.reportCurrentPlaybackFailure(error)
        }
    }

    /// Asynchronous errors from SFBAudioPlayer are NOT all fatal.
    ///
    /// This callback carries decoder-state failures, but also engine restart
    /// and audio-session activation failures, which SFBAudioEngine recovers
    /// from on its own - a route change or the end of an interruption produces
    /// them routinely. Treating every one as a dead track stopped playback and
    /// showed an error for something the user would never have noticed.
    ///
    /// So this only decides that the track is dead if rendering has actually
    /// stopped. The grace period matters: the error is delivered from the
    /// failing operation, before the player has settled either way.
    /// `decodingAborted` remains the authoritative fatal path and is unchanged.
    nonisolated func audioPlayer(_ audioPlayer: AudioPlayer, encounteredError error: Error) {
        let audioPlayerBox = WeakAudioPlayerBox(audioPlayer)
        Task { @MainActor [weak self] in
            guard let self,
                  let audioPlayer = audioPlayerBox.value,
                  self.audioPlayer === audioPlayer,
                  self.loadedDecoder != nil,
                  self.isPlaying else { return }

            print("⚠️ SFBAudioEngine reported an asynchronous error: \(error)")

            let decoderAtError = self.loadedDecoder
            try? await Task.sleep(for: .milliseconds(400))

            guard self.audioPlayer === audioPlayer,
                  self.isPlaying,
                  let currentDecoder = self.loadedDecoder,
                  let decoderAtError,
                  ObjectIdentifier(currentDecoder as AnyObject) == ObjectIdentifier(decoderAtError as AnyObject),
                  !self.hasReportedEndOfAudio else { return }

            guard !audioPlayer.isPlaying, !audioPlayer.isPaused else {
                print("↩️ SFBAudioEngine recovered on its own - keeping playback")
                return
            }

            print("❌ SFBAudioEngine did not recover from: \(error)")
            self.reportCurrentPlaybackFailure(error)
        }
    }

    nonisolated func audioPlayer(_ audioPlayer: AudioPlayer, reconfigureProcessingGraph engine: AVAudioEngine, with format: AVAudioFormat) -> AVAudioNode {
        print("🔄 SFBAudioEngine processing graph reconfiguration for format: \(format)")
        print("🔍 Engine state - isRunning: \(engine.isRunning), attachedNodes: \(engine.attachedNodes.count)")

        // We can't access MainActor properties from nonisolated context
        // So we always skip EQ in this delegate method and rely on attachEqualizerToEngine instead
        // This prevents crashes and keeps the delegate method simple
        print("ℹ️ Skipping EQ in delegate - EQ will be attached via attachEqualizerToEngine if enabled")
        return engine.mainMixerNode
    }

    // MARK: - Background/Foreground Optimization

    func optimizeForBackground() async {
        print("🔒 Optimizing SFBAudioEngine for background/lock screen")

        // Increase buffer size significantly for background stability
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setPreferredIOBufferDuration(0.100) // 100ms buffer for lock screen
            print("✅ Increased buffer to 100ms for lock screen stability")
        } catch {
            print("⚠️ Failed to increase buffer for background: \(error)")
        }

        // Reduce processing load by temporarily disabling EQ if possible
        if let equalizer = sfbEqualizer {
            equalizer.bypass = true
            print("✅ Temporarily bypassed EQ for background stability")
        }
    }

    func optimizeForForeground() async {
        print("🔓 Restoring SFBAudioEngine for foreground")

        // Restore normal buffer size
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setPreferredIOBufferDuration(0.040) // Back to 40ms
            print("✅ Restored buffer to 40ms for foreground")
        } catch {
            print("⚠️ Failed to restore buffer for foreground: \(error)")
        }

        // Re-enable EQ based on current settings
        if let equalizer = sfbEqualizer {
            equalizer.bypass = !eqManager.isEnabled
            print("✅ Restored EQ bypass state for foreground")
        }
    }

}
