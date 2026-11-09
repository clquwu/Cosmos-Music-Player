import Accelerate
import AVFoundation
import BackgroundTasks
import Foundation
import GRDB
import SFBAudioEngine
import UIKit

// MARK: - Analysis

/// What ten seconds from the middle of a song say about how it sounds.
struct AudioAnalysis: Sendable, Equatable {
    /// Loudness, 0 quiet ... 1 loud: the excerpt's RMS level on the same
    /// scale as `MusicFeatures.energy`'s ReplayGain loudness.
    var energy: Double
    /// 0 dark ... 1 bright: the spectral centroid, on a log scale.
    var brightness: Double
    /// BPM, only when the onsets repeat clearly enough to trust it.
    var tempo: Double?
}

/// Listens to a song on the device, cheaply: ten seconds from the middle,
/// mixed down to mono at 11 kHz, then three numbers with Accelerate -
/// loudness (RMS), brightness (spectral centroid) and a tempo estimate
/// (the autocorrelation of an onset envelope). A few milliseconds of maths;
/// decoding the excerpt is most of the cost.
///
/// For songs whose tags say nothing about their sound: tags always win
/// (`MusicFeatures.energy`), this only fills in where they are missing.
enum AudioAnalyzer {
    static let sampleRate = 11_025.0
    static let excerptSeconds = 10.0
    /// 1024-point FFT, a new frame every 256 samples: about 43 onset frames
    /// a second, fine enough to tell 120 BPM from 125.
    private static let frameSize = 1024
    private static let hop = 256

    /// Formats AVAudioFile reads natively; everything else (FLAC, Opus,
    /// Ogg, DSD, APE, WavPack...) goes through SFBAudioEngine's decoders,
    /// as playback does.
    private static let avFoundationExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "mp4", "aac", "alac", "wav", "wave", "aif", "aiff", "aifc", "caf"
    ]

    /// Nil when the file cannot be decoded or is silent in the middle.
    nonisolated static func analyze(url: URL) -> AudioAnalysis? {
        guard let samples = excerpt(of: url) else { return nil }
        return analyze(samples: samples)
    }

    // MARK: Decoding

    /// The excerpt, mono, at `sampleRate`.
    nonisolated static func excerpt(of url: URL) -> [Float]? {
        let ext = url.pathExtension.lowercased()
        if avFoundationExtensions.contains(ext) {
            return avFoundationExcerpt(url) ?? decoderExcerpt(url)
        }
        return decoderExcerpt(url)
    }

    private static func excerptRange(length: Int64, rate: Double) -> (start: Int64, count: Int64) {
        let wanted = Int64(rate * excerptSeconds)
        guard length > wanted else { return (0, max(length, 0)) }
        return (length / 2 - wanted / 2, wanted)
    }

    nonisolated private static func avFoundationExcerpt(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false) else { return nil }
        let format = file.processingFormat
        guard format.sampleRate > 0, file.length > 0 else { return nil }
        let range = excerptRange(length: file.length, rate: format.sampleRate)
        guard range.count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(range.count)) else { return nil }
        file.framePosition = range.start
        guard (try? file.read(into: buffer, frameCount: AVAudioFrameCount(range.count))) != nil else { return nil }
        return mono(buffer)
    }

    nonisolated private static func decoderExcerpt(_ url: URL) -> [Float]? {
        let ext = url.pathExtension.lowercased()
        let decoder: any PCMDecoding
        do {
            if AudioDecoder.handlesPaths(withExtension: ext) {
                decoder = try AudioDecoder(url: url)
            } else if DSDDecoder.handlesPaths(withExtension: ext) {
                // PCM, never DoP: this is maths on samples, not a DAC.
                decoder = try DSDPCMDecoder(decoder: DSDDecoder(url: url))
            } else {
                return nil
            }
            try decoder.open()
        } catch {
            return nil
        }
        defer { try? decoder.close() }
        let format = decoder.processingFormat
        guard format.sampleRate > 0 else { return nil }
        // Length unknown (some Ogg streams): the opening seconds will do.
        let length = decoder.length > 0 ? decoder.length : Int64(format.sampleRate * excerptSeconds)
        var range = excerptRange(length: length, rate: format.sampleRate)
        if range.start > 0, !decoder.supportsSeeking || (try? decoder.seek(to: range.start)) == nil {
            range.start = 0
        }
        guard range.count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(range.count)),
              (try? decoder.decode(into: buffer, length: AVAudioFrameCount(range.count))) != nil else { return nil }
        return mono(buffer)
    }

    /// Down to one channel at `sampleRate`, as plain floats. AVAudioConverter
    /// takes whatever the decoder hands out - integer, float, any channel
    /// count, DSD's 352.8 kHz - so each decoder needs no case of its own.
    nonisolated private static func mono(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard buffer.frameLength > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: buffer.format, to: target) else { return nil }
        converter.downmix = true
        // The lowest quality resampler is the fastest, and what is measured
        // here (level, centroid, onsets) does not hear its small aliasing.
        converter.sampleRateConverterQuality = AVAudioQuality.min.rawValue
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * sampleRate / buffer.format.sampleRate) + 2048
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0, let data = output.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }

    // MARK: Measuring

    /// The three numbers from a mono excerpt at `sampleRate`. Nil for an
    /// excerpt too short or silent to say anything.
    nonisolated static func analyze(samples: [Float]) -> AudioAnalysis? {
        guard samples.count >= Int(sampleRate * 3) else { return nil }

        // Loudness. Mapped like ReplayGain's loudness in MusicFeatures.energy
        // (-18 LUFS calm ... -6 loud), a little wider at the quiet end: an
        // unweighted RMS of a song's middle reads a few dB under its LUFS.
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        guard rms > 0.000_3 else { return nil }
        let level = 20 * log10(Double(rms))
        let energy = min(max((level + 20) / 14, 0), 1)

        guard let spectral = spectralFrames(samples) else { return nil }
        // 400 Hz (a bass-heavy or muffled mix) ... 2.4 kHz (bright, cymbals
        // and air) - the top of what an 11 kHz excerpt can hold - on a log
        // scale, as pitch is heard.
        let brightness = min(max(log2(max(spectral.centroid, 1) / 400) / log2(6), 0), 1)
        return AudioAnalysis(energy: energy, brightness: brightness, tempo: tempo(fromFlux: spectral.flux))
    }

    /// One pass of FFTs over the excerpt: the loudness-weighted mean
    /// spectral centroid in Hz, and the spectral flux - how much louder each
    /// frequency got since the frame before, summed - per frame, which peaks
    /// where notes start.
    nonisolated private static func spectralFrames(_ samples: [Float]) -> (centroid: Double, flux: [Float])? {
        let n = frameSize
        let half = n / 2
        let log2n = vDSP_Length(log2(Double(n)))
        guard samples.count > n, let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var bins = [Float](repeating: 0, count: half)
        var ramp: Float = 0
        var step: Float = 1
        vDSP_vramp(&ramp, &step, &bins, 1, vDSP_Length(half))

        var frame = [Float](repeating: 0, count: n)
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)
        var compressed = [Float](repeating: 0, count: half)
        var previous = [Float](repeating: 0, count: half)
        var difference = [Float](repeating: 0, count: half)
        var flux: [Float] = []
        flux.reserveCapacity((samples.count - n) / hop + 1)
        var centroidSum = 0.0
        var weightSum = 0.0
        var count = Int32(half)
        var zero: Float = 0
        var scale: Float = 100

        var start = 0
        while start + n <= samples.count {
            samples.withUnsafeBufferPointer { pointer in
                vDSP_vmul(pointer.baseAddress! + start, 1, window, 1, &frame, 1, vDSP_Length(n))
            }
            real.withUnsafeMutableBufferPointer { realPointer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                    var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                    frame.withUnsafeBufferPointer { framePointer in
                        framePointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
                }
            }
            // Bin 0 holds DC and Nyquist packed together: neither is music.
            magnitudes[0] = 0

            var total: Float = 0
            vDSP_sve(magnitudes, 1, &total, vDSP_Length(half))
            if total > 0 {
                var weighted: Float = 0
                vDSP_dotpr(magnitudes, 1, bins, 1, &weighted, vDSP_Length(half))
                centroidSum += Double(weighted / total) * Double(total)
                weightSum += Double(total)
            }

            // log(1 + 100 x): quiet partials count, the loudest do not drown
            // everything - the usual compression before onset detection.
            vDSP_vsmul(magnitudes, 1, &scale, &compressed, 1, vDSP_Length(half))
            vvlog1pf(&compressed, compressed, &count)
            vDSP_vsub(previous, 1, compressed, 1, &difference, 1, vDSP_Length(half))
            vDSP_vthr(difference, 1, &zero, &difference, 1, vDSP_Length(half))
            var rise: Float = 0
            vDSP_sve(difference, 1, &rise, vDSP_Length(half))
            flux.append(start == 0 ? 0 : rise)
            swap(&previous, &compressed)
            start += hop
        }
        guard weightSum > 0 else { return nil }
        let centroid = centroidSum / weightSum * sampleRate / Double(n)
        return (centroid, flux)
    }

    /// The beat period the onsets repeat at most clearly, 60...200 BPM, by
    /// autocorrelation, leaning toward 120 as tempo trackers do (a log-
    /// Gaussian prior) so a song is not read at half or double its tempo.
    /// Nil unless the peak stands well out: ambient, rubato and spoken
    /// tracks have onsets but no beat.
    nonisolated static func tempo(fromFlux flux: [Float]) -> Double? {
        let framesPerSecond = sampleRate / Double(hop)
        let minLag = Int((60 * framesPerSecond / 200).rounded(.down))
        let maxLag = Int((60 * framesPerSecond / 60).rounded(.up))
        guard flux.count > maxLag * 4 else { return nil }

        // Onsets against their surroundings: a local mean over about a third
        // of a second taken off, negatives dropped, so a crescendo is not a beat.
        let radius = 7
        var envelope = [Float](repeating: 0, count: flux.count)
        var running: Float = 0
        var window = 0
        for index in 0..<min(radius, flux.count) { running += flux[index]; window += 1 }
        for index in flux.indices {
            let enter = index + radius
            if enter < flux.count { running += flux[enter]; window += 1 }
            let leave = index - radius - 1
            if leave >= 0 { running -= flux[leave]; window -= 1 }
            envelope[index] = max(flux[index] - running / Float(max(window, 1)), 0)
        }
        var zeroLag: Float = 0
        vDSP_dotpr(envelope, 1, envelope, 1, &zeroLag, vDSP_Length(envelope.count))
        guard zeroLag > 0 else { return nil }
        zeroLag /= Float(envelope.count)

        var correlation: [Int: Double] = [:]
        envelope.withUnsafeBufferPointer { pointer in
            for lag in max(minLag - 1, 1)...(maxLag + 1) {
                var sum: Float = 0
                let length = envelope.count - lag
                vDSP_dotpr(pointer.baseAddress!, 1, pointer.baseAddress! + lag, 1, &sum, vDSP_Length(length))
                correlation[lag] = Double(sum / Float(length) / zeroLag)
            }
        }
        func bpm(_ lag: Double) -> Double { 60 * framesPerSecond / lag }
        var best: (lag: Int, score: Double)?
        var mean = 0.0
        for lag in minLag...maxLag {
            let value = correlation[lag] ?? 0
            mean += value
            let octaves = log2(bpm(Double(lag)) / 120)
            let score = value * exp(-0.5 * pow(octaves / 0.9, 2))
            if best == nil || score > best!.score { best = (lag, score) }
        }
        mean /= Double(maxLag - minLag + 1)
        guard let best, let peak = correlation[best.lag], peak >= 0.12, mean > 0, peak >= mean * 1.4 else { return nil }
        // Between whole frames: a parabola through the peak and its neighbours.
        let before = correlation[best.lag - 1] ?? peak
        let after = correlation[best.lag + 1] ?? peak
        let curvature = before - 2 * peak + after
        let offset = curvature < 0 ? min(max(0.5 * (before - after) / curvature, -0.5), 0.5) : 0
        let tempo = bpm(Double(best.lag) + offset)
        return (60...200).contains(tempo) ? (tempo * 10).rounded() / 10 : nil
    }
}

// MARK: - Database

extension DatabaseManager {
    struct AnalysisCandidate: Sendable {
        let id: Int64
        let stableId: String
        let path: String
        let modificationDate: Int64?
    }

    /// Songs not analysed yet, in row order after `id`: the cursor lets a
    /// run walk past files it had to leave (iCloud placeholders) without
    /// meeting them again, and a later run start over and find them.
    func tracksAwaitingAnalysis(after id: Int64, limit: Int) throws -> [AnalysisCandidate] {
        try read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, stable_id, path, modification_date FROM track
                    WHERE analyzed_at IS NULL AND id > ? ORDER BY id LIMIT ?
                    """,
                arguments: [id, limit]
            ).map { row in
                AnalysisCandidate(id: row["id"], stableId: row["stable_id"], path: row["path"], modificationDate: row["modification_date"])
            }
        }
    }

    /// Stores what was heard - or, with nil, that the file could not be
    /// heard, so it is not tried again until it changes. Only while the row
    /// still describes the file that was analysed: a rescan that replaced it
    /// meanwhile wins.
    func storeAnalysis(_ analysis: AudioAnalysis?, stableId: String, modificationDate: Int64?) throws {
        try write { db in
            try db.execute(
                sql: """
                    UPDATE track SET analyzed_energy = ?, analyzed_brightness = ?, analyzed_tempo = ?, analyzed_at = ?
                    WHERE stable_id = ? AND modification_date IS ?
                    """,
                arguments: [analysis?.energy, analysis?.brightness, analysis?.tempo, Int64(Date().timeIntervalSince1970),
                            stableId, modificationDate]
            )
        }
    }

    /// Songs analysed (heard or found unreadable), with a usable result, and in all.
    func analysisProgress() throws -> (analyzed: Int, heard: Int, total: Int) {
        try read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(analyzed_at) AS analyzed, COUNT(analyzed_energy) AS heard, COUNT(*) AS total FROM track
                """)
            return (row?["analyzed"] ?? 0, row?["heard"] ?? 0, row?["total"] ?? 0)
        }
    }
}

// MARK: - Scheduling

/// Runs the analysis when it costs the listener nothing: as a background
/// processing task iOS starts while the device charges (overnight, mostly),
/// 200 songs a run, picking up where the last run stopped; and, a few songs
/// at a time, while the app is open, idle and charging.
///
/// Never in the way of playback: it pauses while a song loads or the queue
/// advances, stops for a library scan, runs at background priority, skips
/// files that are not on the device (an iCloud placeholder is never
/// downloaded for this) and does nothing in Low Power Mode or when hot.
@MainActor
final class AudioAnalysisScheduler {
    static let shared = AudioAnalysisScheduler()

    /// Also listed under BGTaskSchedulerPermittedIdentifiers in Info.plist.
    nonisolated static let taskIdentifier = "dev.clq.Cosmos-Music-Player.audioAnalysis"
    static let backgroundBatch = 200
    static let trickleBatch = 12

    private var batchTask: Task<Int, Never>?
    private var trickleTask: Task<Void, Never>?
    /// Identifies the trickle `trickleTask` currently holds.
    private var trickleToken: UUID?
    private var observers: [NSObjectProtocol] = []

    private init() {}

    var isRunning: Bool { batchTask != nil }

    /// From didFinishLaunching: iOS requires the handler registered before
    /// launch completes.
    func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: .main) { task in
            guard let task = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let box = BackgroundTaskBox(task)
            MainActor.assumeIsolated { AudioAnalysisScheduler.shared.run(box) }
        }
    }

    /// Watches for the moments a foreground trickle may run, and asks for a
    /// background run whenever the app goes to the background.
    func start() {
        guard observers.isEmpty else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        let center = NotificationCenter.default
        for name in [UIApplication.didBecomeActiveNotification, UIDevice.batteryStateDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AudioAnalysisScheduler.shared.trickleIfIdle() }
            })
        }
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                AudioAnalysisScheduler.shared.trickleTask?.cancel()
                AudioAnalysisScheduler.shared.trickleTask = nil
                AudioAnalysisScheduler.shared.schedule()
            }
        })
        #if DEBUG
        // -cosmosDebugAnalyze N: one batch of N songs at launch, timed, for
        // measuring the analysis on a simulator or device.
        let debugCount = UserDefaults.standard.integer(forKey: "cosmosDebugAnalyze")
        if debugCount > 0 {
            Task {
                try? await Task.sleep(for: .seconds(5))
                _ = await AudioAnalysisScheduler.shared.runBatch(limit: debugCount, foreground: false)
            }
            return
        }
        #endif
        trickleIfIdle()
    }

    /// Asks iOS for a background run while there are songs left to analyse.
    func schedule() {
        Task.detached(priority: .background) {
            guard let pending = try? DatabaseManager.shared.tracksAwaitingAnalysis(after: 0, limit: 1), !pending.isEmpty else { return }
            let request = BGProcessingTaskRequest(identifier: AudioAnalysisScheduler.taskIdentifier)
            request.requiresExternalPower = true
            request.requiresNetworkConnectivity = false
            request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                print("⚠️ Audio analysis: could not schedule a background run: \(error)")
            }
        }
    }

    private func run(_ box: BackgroundTaskBox) {
        // The app is in the background, where the database is suspended
        // whenever nothing plays; this run needs it until it ends.
        DatabaseSuspensionCoordinator.shared.beginHold()
        let work = Task { await self.runBatch(limit: Self.backgroundBatch, foreground: false) }
        // Exactly once, whichever comes first: the batch ending, or iOS
        // taking the time back.
        let finish: @MainActor (String) -> Void = { outcome in
            guard !box.isFinished else { return }
            box.isFinished = true
            DatabaseSuspensionCoordinator.shared.endHold()
            print("🎚️ Audio analysis: background run \(outcome)")
            // More to do, or cut short: ask for the next run.
            self.schedule()
            box.task.setTaskCompleted(success: true)
        }
        box.task.expirationHandler = {
            // Cancelling stops the batch between songs (runBatch forwards
            // it to its loop), but the song being decoded can take seconds
            // more. Release the database hold and complete now rather than
            // after it: still holding either when the time is up is what
            // gets the app killed (watchdog / 0xdead10cc). A store attempted
            // after this simply fails and the song is analysed next run.
            work.cancel()
            if Thread.isMainThread {
                MainActor.assumeIsolated { finish("expired") }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { finish("expired") } }
            }
        }
        Task {
            let done = await work.value
            finish("analysed \(done) song(s)")
        }
    }

    /// Whether the device has the energy to spare: plugged in, not saving
    /// power, not hot.
    private var deviceAllows: Bool {
        let battery = UIDevice.current.batteryState
        return (battery == .charging || battery == .full)
            && !ProcessInfo.processInfo.isLowPowerModeEnabled
            && ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue
    }

    /// A few songs at a time while the app is open and idle on the charger,
    /// a pause between batches; stops as soon as any of that changes.
    private func trickleIfIdle() {
        guard trickleTask == nil, deviceAllows, UIApplication.shared.applicationState == .active else { return }
        // Going to the background cancels and clears this task; becoming
        // active again can start a new one before the cancelled one winds
        // down. Its defer must not clear its successor, or a third trickle
        // would start alongside it.
        let token = UUID()
        trickleToken = token
        trickleTask = Task { [weak self] in
            defer {
                if let self, self.trickleToken == token {
                    self.trickleTask = nil
                    self.trickleToken = nil
                }
            }
            while !Task.isCancelled {
                // Let launch, a scan or the song just started settle first.
                try? await Task.sleep(for: .seconds(20))
                guard let self, !Task.isCancelled, self.deviceAllows,
                      UIApplication.shared.applicationState == .active,
                      !PlayerEngine.shared.keepsDatabaseActive else { return }
                let done = await self.runBatch(limit: Self.trickleBatch, foreground: true)
                if done == 0 { return }
            }
        }
    }

    /// Analyses up to `limit` songs, one at a time off the main thread, and
    /// returns how many it stored. Stops when cancelled, when a scan starts,
    /// or - in the foreground - when playback starts or the charger goes.
    func runBatch(limit: Int, foreground: Bool) async -> Int {
        while let current = batchTask {
            if !current.isCancelled {
                return await withTaskCancellationHandler {
                    await current.value
                } onCancel: {
                    current.cancel()
                }
            }
            // A cancelled batch (the last background run expired, the
            // trickle stopped) only winds down to its next song boundary.
            // Joining it handed a fresh background run that batch's early
            // "0 done" - the run ended at once and the time iOS granted went
            // unused. Let it finish, then start a batch of our own.
            _ = await current.value
            if batchTask == current { batchTask = nil }
            if Task.isCancelled { return 0 }
        }
        let task = Task { () -> Int in
            var done = 0
            var cursor: Int64 = 0
            #if DEBUG
            var timings: [Double] = []
            #endif
            batch: while done < limit {
                let after = cursor
                let page = (try? await Task.detached(priority: .background) {
                    try DatabaseManager.shared.tracksAwaitingAnalysis(after: after, limit: 50)
                }.value) ?? []
                guard !page.isEmpty else { break }
                for candidate in page {
                    cursor = candidate.id
                    guard await self.mayContinue(foreground: foreground) else { break batch }
                    let file = await Self.readAccess(for: candidate)
                    // Not on the device: an iCloud placeholder or a moved
                    // file. Left for a later run - never downloaded for this.
                    guard await Task.detached(priority: .background, operation: { CloudDownloadManager.isLocallyResident(file.url) }).value else {
                        file.relinquish()
                        continue
                    }
                    let state = Perf.begin("Audio analysis")
                    let started = ContinuousClock.now
                    let url = file.url
                    let (analysis, readable) = await Task.detached(priority: .background) { () -> (AudioAnalysis?, Bool) in
                        if let analysis = AudioAnalyzer.analyze(url: url) { return (analysis, true) }
                        // Undecodable, or only unreadable for now - a locked
                        // device's data protection, a revoked bookmark. Only
                        // a file whose bytes can be read is marked as tried.
                        let handle = try? FileHandle(forReadingFrom: url)
                        let readable = (try? handle?.read(upToCount: 1))??.isEmpty == false
                        try? handle?.close()
                        return (nil, readable)
                    }.value
                    let elapsed = ContinuousClock.now - started
                    Perf.end("Audio analysis", state)
                    file.relinquish()
                    guard readable else { continue }
                    // Cancelled while decoding: the background run may already
                    // have released the database hold.
                    if Task.isCancelled { break batch }
                    #if DEBUG
                    timings.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
                    let tempoText = analysis?.tempo.map { String(format: "%.0f", $0) } ?? "-"
                    print("🎚️ \(url.lastPathComponent): \(analysis.map { String(format: "energy %.2f · brightness %.2f · tempo %@", $0.energy, $0.brightness, tempoText) } ?? "unreadable") in \(elapsed)")
                    #endif
                    _ = elapsed
                    let stored: Bool = await Task.detached(priority: .background) {
                        (try? DatabaseManager.shared.storeAnalysis(analysis, stableId: candidate.stableId, modificationDate: candidate.modificationDate)) != nil
                    }.value
                    if stored { done += 1 }
                    if done >= limit { break batch }
                }
            }
            #if DEBUG
            if !timings.isEmpty {
                let sorted = timings.sorted()
                print(String(format: "🎚️ Audio analysis: %d songs, mean %.1f ms, median %.1f ms, max %.1f ms",
                             sorted.count, sorted.reduce(0, +) / Double(sorted.count), sorted[sorted.count / 2], sorted.last ?? 0))
            }
            #endif
            return done
        }
        batchTask = task
        // The loop is its own unstructured Task, so cancelling the caller
        // (the background run's expiration, the trickle stopping on entering
        // the background) never reached it: it went on analysing, and
        // holding the database, after iOS had asked it to stop.
        let done = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        // A newer batch may have taken the slot after this one was cancelled.
        if batchTask == task { batchTask = nil }
        return done
    }

    /// Between two songs: whether to go on, waiting out a track load or
    /// queue advance - the moments playback cannot afford a busy disk.
    private func mayContinue(foreground: Bool) async -> Bool {
        if Task.isCancelled || LibraryIndexer.shared.isIndexing { return false }
        if ProcessInfo.processInfo.isLowPowerModeEnabled
            || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue { return false }
        let player = PlayerEngine.shared
        if foreground {
            return deviceAllows && !player.keepsDatabaseActive && UIApplication.shared.applicationState == .active
        }
        var waited = 0
        while player.keepsDatabaseActive && !player.isPlaying {
            guard waited < 50, !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        // Music playing: leave the audio thread room between songs.
        if player.isPlaying { try? await Task.sleep(for: .milliseconds(250)) }
        return !Task.isCancelled
    }

    /// The file, opened through its security-scoped bookmark when it lives
    /// outside the app (as ArtworkManager reads covers): read-only, a stale
    /// bookmark simply falls back to the stored path.
    private static func readAccess(for candidate: DatabaseManager.AnalysisCandidate) async -> ScopedRead {
        let stored = DatabaseManager.localFileURL(forStoredPath: candidate.path)
        guard let bookmark = try? await ExternalBookmarkStore.shared.bookmarkData(for: candidate.stableId) else {
            return ScopedRead(url: stored, scoped: false)
        }
        var isStale = false
        guard let resolved = try? URL(resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale),
              !isStale else {
            return ScopedRead(url: stored, scoped: false)
        }
        return ScopedRead(url: resolved, scoped: resolved.startAccessingSecurityScopedResource())
    }

    private struct ScopedRead {
        let url: URL
        let scoped: Bool
        func relinquish() { if scoped { url.stopAccessingSecurityScopedResource() } }
    }
}

/// BGProcessingTask is not Sendable; it is only touched on the main queue
/// (the handler is registered with `using: .main`, and the expiration handler
/// hops there before completing it).
private final class BackgroundTaskBox: @unchecked Sendable {
    let task: BGProcessingTask
    /// Main queue only.
    var isFinished = false
    init(_ task: BGProcessingTask) { self.task = task }
}
