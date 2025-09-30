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

private struct AVAudioUnitEQBox: @unchecked Sendable {
    let node: AVAudioUnitEQ
}

@MainActor
class SFBAudioEngineManager: NSObject, ObservableObject, AudioPlayer.Delegate {
    static let shared = SFBAudioEngineManager()

    private var audioPlayer: AudioPlayer?
    private var currentTrack: SFBTrack?
    private var updateTimer: Timer?

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
            audioPlayer?.withEngine { [weak self] engine in
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
        
        let maxRetries = 3
        let eqEnabled = eqManager.isEnabled
        let globalGain = Float(eqManager.globalGain)
        
        guard formatSupportsSFBEQ(format) else {
            print("⚠️ SFBAudioEngine EQ not supported for format: \(format?.description ?? "nil")")
            player.withEngine { [weak self] engine in
                guard let self else { return }
                if let existing = engine.attachedNodes.compactMap({ $0 as? AVAudioUnitEQ }).first {
                    self.removeEqualizer(existing, from: engine)
                }
            }
            Task { @MainActor [weak self] in self?.sfbEqualizer = nil }
            return
        }
        
        player.withEngine { [weak self] engine in
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
                print("✅ EQ node attached via withEngine")
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
                let connectFormat = format ?? upstreamNode.outputFormat(forBus: bus)
                engine.disconnectNodeInput(engine.mainMixerNode)
                engine.connect(equalizer, to: engine.mainMixerNode, format: connectFormat)
                engine.connect(upstreamNode, to: equalizer, format: connectFormat)
                print("🔗 Inserted EQ between \(upstreamNode) and mainMixerNode")
                return
            }
            
            let fallbackNode = engine.attachedNodes.first(where: { node in
                if node === equalizer || node === engine.mainMixerNode || node === engine.outputNode { return false }
                let className = String(describing: type(of: node))
                return className.contains("SFBAudioPlayerNode") || node is AVAudioPlayerNode
            })
            
            if let sourceNode = fallbackNode {
                let connectFormat = format ?? sourceNode.outputFormat(forBus: 0)
                engine.disconnectNodeInput(engine.mainMixerNode)
                engine.disconnectNodeOutput(sourceNode)
                engine.connect(sourceNode, to: equalizer, format: connectFormat)
                engine.connect(equalizer, to: engine.mainMixerNode, format: connectFormat)
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

    // EQ integration for SFBAudioEngine (native approach following wiki)
    let eqManager = EQManager.shared
    private var sfbEqualizer: AVAudioUnitEQ?
    // Track last sample rate to avoid unnecessary changes
    private var lastConfiguredSampleRate: Double = 0

    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0

    private override init() {
        super.init()
        setupAudioPlayer()
    }

    private func setupAudioPlayer() {
        audioPlayer = AudioPlayer()
        audioPlayer?.delegate = self
        print("🔄 SFBAudioEngine AudioPlayer initialized")
    }

    private func resetAudioPlayer() {
        audioPlayer?.stop()
        cleanupEqualizer()
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

    func loadAndPlay(url: URL) async throws {
        print("🚀 SFBAudioEngine.loadAndPlay called for: \(url.lastPathComponent)")

        // Stop any current playback and cleanup
        audioPlayer?.stop()
        cleanupEqualizer()

        print("🔍 SFBAudioEngine attempting to load: \(url.lastPathComponent)")

        // Create track and get properties/metadata first to get sample rate
        print("🔍 Creating SFBTrack for: \(url.lastPathComponent)")
        let track = SFBTrack(url: url)
        currentTrack = track

        // Set duration from track
        duration = track.duration
        print("📊 Track duration: \(duration) seconds")

        // Check if we should use DoP for external audio devices
        let hasExternalDAC = await checkForExternalDAC()
        let isDSDFile = url.pathExtension.lowercased() == "dsf" || url.pathExtension.lowercased() == "dff"

        if isDSDFile {
            print("🎵 DSD file detected, DAC present: \(hasExternalDAC)")
            if hasExternalDAC {
                print("🎵 Will attempt DoP encoding for external DAC")
            } else {
                print("🎵 Will use PCM conversion for internal audio")
            }
        }

        print("🔍 Getting decoder for: \(url.lastPathComponent), enableDoP: \(hasExternalDAC)")

        guard let decoder = try track.decoder(enableDoP: hasExternalDAC) else {
            print("❌ No decoder available for: \(url.lastPathComponent)")
            throw NSError(domain: "SFBAudioEngineManager", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Unsupported audio format"
            ])
        }

        print("🔧 Decoder created successfully")

        // Try to open the decoder to ensure format properties are available
        do {
            try decoder.open()
            print("🔧 Decoder opened successfully")
        } catch {
            print("⚠️ Failed to open decoder: \(error)")
            // Continue anyway - some decoders might work without explicit opening
        }

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

        // Also check source format as fallback
        let sourceSampleRate = sourceFormat.sampleRate
        let sourceChannelCount = sourceFormat.channelCount

        // Use source format if processing format is invalid
        let finalSampleRate = decoderSampleRate > 0 ? decoderSampleRate : sourceSampleRate
        let finalChannelCount = decoderChannelCount > 0 ? decoderChannelCount : sourceChannelCount

        // Log the format properties but don't fail immediately - let SFBAudioEngine try to play
        if finalSampleRate <= 0 || finalChannelCount <= 0 {
            print("⚠️ Decoder format properties unavailable: processing(sampleRate=\(decoderSampleRate), channels=\(decoderChannelCount)), source(sampleRate=\(sourceSampleRate), channels=\(sourceChannelCount))")
            print("🔄 Proceeding with playback - SFBAudioEngine may handle format internally")

            // Use default values for configuration
            self.decoderSampleRate = 48000 // Default sample rate
        } else {
            print("✅ Valid decoder properties: sampleRate=\(finalSampleRate), channels=\(finalChannelCount)")
            self.decoderSampleRate = finalSampleRate
        }

        // Store decoder properties for seeking when AudioFile properties are unavailable
        decoderFrameLength = decoder.length
        print("🔄 Stored decoder properties: frameLength=\(decoderFrameLength), sampleRate=\(self.decoderSampleRate)")

        // Update duration from decoder if it wasn't available from AudioFile and we have valid properties
        if duration == 0 && decoderFrameLength > 0 && self.decoderSampleRate > 0 {
            duration = Double(decoderFrameLength) / self.decoderSampleRate
            print("🔄 Updated duration from decoder: \(duration)s")
        }

        // CRITICAL: Configure audio session AFTER decoder creation and BEFORE playback
        // Use the determined sample rate for accurate configuration
        let actualSampleRate = self.decoderSampleRate
        print("🔍 Using determined sample rate: \(actualSampleRate)Hz")

        do {
            try configureAudioSessionForDecoder(decoder: decoder, isDSD: isDSDFile, enableDoP: hasExternalDAC)
        } catch {
            print("⚠️ Audio session configuration had warnings (ignoring): \(error)")
        }
        
        if isDSDFile {
            print("🔄 Resetting AudioPlayer for DSD file to prevent state issues")
            resetAudioPlayer()
        } else if audioPlayer?.isPlaying == true {
            print("🔄 Stopping existing playback before starting new track")
            audioPlayer?.stop()
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        // Start playback with proper error handling
        print("🎵 Starting SFBAudioEngine playback...")
        do {
            try audioPlayer?.play(decoder)
            isPlaying = true
            startUpdateTimer()
            attachEqualizerToEngine(with: decoder.processingFormat)
            print("✅ SFBAudioEngine playback started successfully")
        } catch {
            print("❌ Failed to start SFBAudioEngine playback: \(error)")
            // Let PlayerEngine handle error processing and user feedback
            throw error
        }

        print("✅ SFBAudioEngine started playback: \(url.lastPathComponent)")
        print("🎵 SFBAudioEngine loadAndPlay completed successfully")
    }

    func play() throws {
        if let player = audioPlayer {
            // Reactivate audio session when resuming
            do {
                let audioSession = AVAudioSession.sharedInstance()
                try audioSession.setActive(true)
                print("✅ Audio session reactivated on resume")
            } catch {
                print("⚠️ Failed to reactivate audio session on resume: \(error)")
            }

            try player.play()
            isPlaying = true
            startUpdateTimer()
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
        updateTimer?.invalidate()

        // Deactivate audio session to ensure system knows audio is paused
        // This should fix Control Center button state issues
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            print("✅ Audio session deactivated on pause")
        } catch {
            print("⚠️ Failed to deactivate audio session on pause: \(error)")
        }

        print("✅ SFBAudioEngineManager paused")
    }

    func stop() {
        audioPlayer?.stop()
        isPlaying = false
        currentTime = 0
        currentTrack = nil
        decoderFrameLength = 0
        decoderSampleRate = 0
        updateTimer?.invalidate()
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
            let timeSeekResult = audioPlayer?.seek(time: time) ?? false
            if timeSeekResult {
                currentTime = time
                print("✅ DSD file seeked to time: \(time)s")
            } else {
                currentTime = time
                print("⚠️ DSD seeking failed, updated currentTime only")
            }
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

            // Try to seek to the calculated frame position
            do {
                // Use SFBAudioEngine's AudioPlayer seek methods with correct API
                if let audioPlayer = player as? AudioPlayer {
                    // Try frame-based seeking first (most precise)
                    let seekResult = audioPlayer.seek(frame: AVAudioFramePosition(safeFramePosition))
                    if seekResult {
                        currentTime = time
                        print("✅ SFBAudioEngine seeked to frame: \(safeFramePosition)")
                    } else {
                        // Frame seeking failed, try time-based seeking
                        let timeSeekResult = audioPlayer.seek(time: time)
                        if timeSeekResult {
                            currentTime = time
                            print("✅ SFBAudioEngine seeked to time: \(time)s (frame seek failed)")
                        } else {
                            // Both methods failed, fallback to manual time update
                            currentTime = time
                            print("⚠️ Both frame and time seeking failed, updated currentTime only")
                        }
                    }
                } else {
                    // Fallback: just update current time (for formats that don't support seeking)
                    currentTime = time
                    print("⚠️ AudioPlayer not available, updated currentTime only")
                }
            }
        } else {
            // Fallback when we don't have proper duration/sampleRate
            currentTime = time
            print("⚠️ No sample rate or duration, using time-only seeking")
        }
    }

    // MARK: - Timer Management

    private func startUpdateTimer() {
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updatePlaybackPosition()
            }
        }
    }

    private func updatePlaybackPosition() {
        if isPlaying, let player = audioPlayer {
            // Get actual playback position from SFBAudioEngine
            // Use decoder properties for accurate position calculation
            let useSampleRate = currentTrack?.sampleRate ?? decoderSampleRate
            _ = currentTrack?.frameLength ?? decoderFrameLength

            if useSampleRate > 0 {
                // Try to get actual frame position from the audio player
                // Note: SFBAudioEngine might not expose current frame directly,
                // so we'll use our stored currentTime but validate against actual playback

                // For now, increment time but validate against duration
                currentTime += 0.1

                // Ensure we don't exceed the actual track duration
                if duration > 0 && currentTime > duration {
                    currentTime = duration
                }
            } else {
                // Fallback to simple time increment
                currentTime += 0.1
            }

            // Log position every 10 seconds for debugging
            if Int(currentTime * 10) % 100 == 0 {
                print("🎵 SFBAudioEngine position: \(currentTime)/\(duration)")
            }

            if duration > 0 && currentTime >= duration {
                print("🏁 SFBAudioEngine track completed: \(currentTime)/\(duration)")
                // Track completion will be handled by PlayerEngine
                isPlaying = false
                updateTimer?.invalidate()
            }
        }
    }

    // MARK: - EQ Support

    /// Returns whether EQ is supported for this playback engine
    static func supportsEQ() -> Bool {
        return true
    }

    /// Update EQ settings from EQManager (applies to native SFBAudioEngine EQ)
    func updateEQSettings() {
        applySFBEQSettings()
    }

    private func configureSFBEQBands(_ equalizer: AVAudioUnitEQ) {
        // Apply frequency-specific gains from EQManager
        let eqFrequencies = eqManager.currentEQFrequencies
        let eqGains = eqManager.currentEQGains

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
                    band.bandwidth = 1.0
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
                    var groupSize = 0

                    for j in startIndex..<endIndex {
                        if j < eqFrequencies.count && j < eqGains.count {
                            avgFrequency += eqFrequencies[j]
                            avgGain += eqGains[j]
                            groupSize += 1
                        }
                    }

                    if groupSize > 0 {
                        avgFrequency /= Double(groupSize)
                        avgGain /= Double(groupSize)
                    }

                    let band = equalizer.bands[i]
                    band.frequency = Float(avgFrequency)
                    band.gain = Float(avgGain)
                    band.bandwidth = 1.0
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

    /// Configure audio session to match decoder's exact requirements (critical for DoP)
    func configureAudioSessionForDecoder(decoder: PCMDecoding, isDSD: Bool, enableDoP: Bool) throws {
        let audioSession = AVAudioSession.sharedInstance()
        let decoderSampleRate = decoder.processingFormat.sampleRate

        print("🎵 Configuring audio session for decoder: sampleRate=\(decoderSampleRate)Hz, isDSD=\(isDSD), enableDoP=\(enableDoP)")

        // Check if we can avoid changing sample rate to prevent buffer underruns
        // Based on SFBAudioEngine issues #347 and #503, frequent rate changes cause problems
        if abs(lastConfiguredSampleRate - decoderSampleRate) < 1.0 && !isDSD {
            print("🔄 Skipping audio session reconfiguration - sample rate unchanged (\(decoderSampleRate)Hz)")
            return
        }

        if isDSD && enableDoP {
            // For DSD over DoP, session sample rate MUST exactly match decoder output
            print("🎵 Configuring audio session for DSD over DoP - EXACT rate matching required")

            // Log current session state before changes
            print("🔍 Current session state - Rate: \(audioSession.sampleRate)Hz, Buffer: \(audioSession.ioBufferDuration)s")

            // For DSD DoP on iOS, ensure proper audio routing
            do {
                try audioSession.setCategory(.playback, mode: .default,
                                           options: [.allowBluetoothA2DP, .allowAirPlay])
                print("✅ Audio session category set for DoP")
            } catch {
                print("⚠️ Category setting failed (continuing): \(error)")
                // Continue anyway - category might already be correct
            }

            // CRITICAL: Deactivate session first as recommended by SFBAudioEngine wiki
            do {
                try audioSession.setActive(false)
                print("✅ Audio session deactivated")
            } catch {
                print("⚠️ Session deactivation failed (continuing): \(error)")
                // Continue anyway - session might already be inactive
            }

            // For DoP on iOS, we need to be more careful about sample rates
            // Some iOS devices/DACs don't support the exact DoP rates, so try fallbacks
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

            // Try to set the target sample rate with better iOS compatibility
            var finalSampleRate = targetSampleRate
            do {
                try audioSession.setPreferredSampleRate(targetSampleRate)
                print("✅ Sample rate set successfully: \(targetSampleRate)Hz")
            } catch {
                print("⚠️ Failed to set preferred rate \(targetSampleRate)Hz: \(error)")
                // Try fallback rates that are more commonly supported on iOS
                // For DoP, prefer rates that can handle the DoP encoding properly
                let fallbackRates: [Double] = [176400, 88200, 96000, 48000, 44100]
                var success = false
                for rate in fallbackRates {
                    do {
                        try audioSession.setPreferredSampleRate(rate)
                        print("✅ Fallback rate set: \(rate)Hz")
                        finalSampleRate = rate
                        success = true
                        break
                    } catch {
                        print("⚠️ Fallback rate \(rate)Hz also failed: \(error)")
                    }
                }
                if !success {
                    print("⚠️ All sample rate attempts failed, using current session rate")
                    finalSampleRate = audioSession.sampleRate
                }
            }

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
            do {
                try audioSession.setActive(true)
                print("✅ Audio session reactivated with new DoP settings")
            } catch {
                print("⚠️ Session reactivation failed: \(error)")
                // This is more critical - try to activate anyway
                do {
                    try audioSession.setActive(true, options: [])
                    print("✅ Audio session activated with fallback options")
                } catch {
                    print("❌ Could not activate audio session: \(error)")
                    throw error
                }
            }

            // Log final session state after all changes
            print("🎵 DSD DoP audio session configured:")
            print("  📊 Requested sample rate: \(targetSampleRate)Hz")
            print("  📊 Actual session rate: \(audioSession.sampleRate)Hz")
            print("  📊 Buffer duration: \(audioSession.ioBufferDuration)s")
            print("  📊 Category: \(audioSession.category)")
            print("  📊 Mode: \(audioSession.mode)")

            // Verify the sample rate was actually set correctly
            // Compare against final rate that was successfully set
            if abs(audioSession.sampleRate - finalSampleRate) > 1.0 {
                print("⚠️ WARNING: Audio session sample rate (\(audioSession.sampleRate)Hz) does not match set rate (\(finalSampleRate)Hz)")
                print("⚠️ This may cause DoP playback issues")
            } else {
                print("✅ Sample rates match final rate - DoP should work correctly")
            }

            lastConfiguredSampleRate = audioSession.sampleRate

        } else if isDSD && !enableDoP {
            // For DSD to PCM conversion, use appropriate sample rate
            print("🎵 Configuring audio session for DSD PCM conversion")

            try audioSession.setCategory(.playback, mode: .default, options: [.allowBluetoothA2DP, .allowAirPlay])

            // Deactivate first
            try audioSession.setActive(false)

            // For DSD PCM, use the decoder's output rate
            try audioSession.setPreferredSampleRate(decoderSampleRate)
            try audioSession.setPreferredIOBufferDuration(0.040) // 40ms buffer for ring buffer stability

            try audioSession.setActive(true)

            print("🎵 DSD PCM audio session configured: requested=\(decoderSampleRate)Hz, actual=\(audioSession.sampleRate)Hz")
            lastConfiguredSampleRate = audioSession.sampleRate

        } else {
            // For non-DSD files, use standard configuration but still match decoder rate
            try audioSession.setCategory(.playback, mode: .default, options: [.allowBluetoothA2DP])

            try audioSession.setActive(false)
            try audioSession.setPreferredSampleRate(decoderSampleRate)
            try audioSession.setPreferredIOBufferDuration(0.040) // 40ms buffer for ring buffer stability
            try audioSession.setActive(true)

            print("🔊 Standard audio session configured: requested=\(decoderSampleRate)Hz, actual=\(audioSession.sampleRate)Hz")
            lastConfiguredSampleRate = audioSession.sampleRate
        }
    }

    // MARK: - DAC Detection

    private func checkForExternalDAC() async -> Bool {
        let audioSession = AVAudioSession.sharedInstance()
        let currentRoute = audioSession.currentRoute

        print("🔍 Checking iOS audio route for external DAC...")

        // Check all audio outputs for iOS-specific DAC detection
        for output in currentRoute.outputs {
            print("🔍 Audio output: \(output.portName) (type: \(output.portType.rawValue))")

            // Consider various external audio devices as potential DACs on iOS
            switch output.portType {
            case .usbAudio:
                print("🎵 Found USB DAC: \(output.portName)")
                return true
            case .headphones:
                // On iOS, many DACs appear as headphones when connected via Lightning/USB-C adapters
                let portNameLower = output.portName.lowercased()

                // EXCLUDE computers and CarPlay - these are NOT DACs
                let excludedDevices = ["macbook", "imac", "mac mini", "mac pro", "mac studio",
                                     "carplay", "car play", "android auto", "computer", "pc", "laptop"]
                for excludedDevice in excludedDevices {
                    if portNameLower.contains(excludedDevice) {
                        print("🚫 Excluding non-DAC device: \(output.portName)")
                        return false
                    }
                }

                // Check for known DAC brands (dedicated audio equipment)
                let dacBrands = ["fosi", "topping", "ifi", "audioquest", "chord", "schiit", "jds", "fiio",
                               "denafrips", "ps audio", "mcintosh", "cambridge", "marantz", "denon",
                               "yamaha", "sony", "sennheiser", "beyerdynamic", "focal", "hifiman", "audeze",
                               "smsl", "aune", "gustard", "matrix", "burson", "lehmann", "benchmark"]
                for brand in dacBrands {
                    if portNameLower.contains(brand) {
                        print("🎵 Found recognized DAC brand: \(output.portName)")
                        return true
                    }
                }

                // Check for explicit DAC keywords (be more specific)
                let dacKeywords = ["dac", "amplifier", "amp", "dsd", "hi-res", "hires", "headphone amp"]
                for keyword in dacKeywords {
                    if portNameLower.contains(keyword) {
                        print("🎵 Found DAC device by keyword: \(output.portName)")
                        return true
                    }
                }

                // Check for dedicated audio adapters (not generic computer connections)
                if (portNameLower.contains("lightning") || portNameLower.contains("usb-c")) &&
                   !portNameLower.contains("computer") && !portNameLower.contains("mac") {
                    print("🎵 Found potential DAC via adapter: \(output.portName)")
                    return true
                }
                break
            case .lineOut:
                print("🎵 Found line out (potential DAC): \(output.portName)")
                return true
            case .bluetoothA2DP:
                // High-end Bluetooth devices that may support better audio quality
                let bluetoothKeywords = ["ldac", "aptx", "dsd", "hi-res", "hires"]
                let portNameLower = output.portName.lowercased()
                for keyword in bluetoothKeywords {
                    if portNameLower.contains(keyword) {
                        print("🎵 Found high-quality Bluetooth DAC: \(output.portName)")
                        return true
                    }
                }
                break
            default:
                // Check for any port that's not the built-in speaker/receiver
                if output.portType != .builtInSpeaker && output.portType != .builtInReceiver {
                    print("🔍 Found non-built-in audio device: \(output.portName)")
                    // For iOS, be more conservative - only treat as DAC if name suggests it
                    let portNameLower = output.portName.lowercased()
                    if portNameLower.contains("dac") || portNameLower.contains("external") {
                        print("🎵 Found external DAC device: \(output.portName)")
                        return true
                    }
                }
                break
            }
        }

        // Also check inputs for USB audio interfaces (less common on iOS but possible)
        for input in currentRoute.inputs {
            if input.portType == .usbAudio {
                print("🎵 Found USB audio interface: \(input.portName)")
                return true
            }
        }

        print("🔍 No external DAC detected on iOS - using internal audio with PCM conversion")
        return false
    }

    // MARK: - AudioPlayer.Delegate

    nonisolated func audioPlayer(_ audioPlayer: AudioPlayer, reconfigureProcessingGraph engine: AVAudioEngine, with format: AVAudioFormat) -> AVAudioNode {
        print("🔄 SFBAudioEngine processing graph reconfiguration for format: \(format)")
        print("🔍 Engine state - isRunning: \(engine.isRunning), attachedNodes: \(engine.attachedNodes.count)")
        
        guard formatSupportsSFBEQ(format) else {
            print("⚠️ SFBAudioEngine EQ not supported during reconfiguration (format: \(format))")
            if let existing = engine.attachedNodes.compactMap({ $0 as? AVAudioUnitEQ }).first {
                removeEqualizer(existing, from: engine)
            }
            Task { @MainActor [weak self] in
                self?.sfbEqualizer = nil
            }
            return engine.mainMixerNode
        }
        
        let equalizer: AVAudioUnitEQ
        if let existing = engine.attachedNodes.compactMap({ $0 as? AVAudioUnitEQ }).first {
            equalizer = existing
            print("🎛️ Reusing existing SFBAudioEngine EQ node")
        } else {
            let newEQ = AVAudioUnitEQ(numberOfBands: 16)
            newEQ.globalGain = 0.0
            newEQ.bypass = false
            configureDefaultSFBBands(for: newEQ)
            engine.attach(newEQ)
            equalizer = newEQ
            print("🎛️ Created new SFBAudioEngine EQ during reconfiguration")
        }
        
        engine.disconnectNodeOutput(equalizer)
        engine.connect(equalizer, to: engine.mainMixerNode, format: format)
        print("🔗 Connected EQ -> MainMixer during reconfiguration")
        
        let eqBox = AVAudioUnitEQBox(node: equalizer)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.sfbEqualizer = eqBox.node
            self.applySFBEQSettings()
            print("🎛️ Applied EQManager settings to SFBAudioEngine EQ")
        }
        
        return equalizer
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
