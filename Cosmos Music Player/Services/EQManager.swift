//
//  EQManager.swift
//  Cosmos Music Player
//
//  Graphic equalizer management service
//

import Foundation
import AVFoundation
import GRDB

// Helper extension for rounding doubles
extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}

@MainActor
class EQManager: ObservableObject {
    static let shared = EQManager()

    @Published var isEnabled: Bool = false {
        didSet {
            if isEnabled != oldValue {
                applyEQSettings()
                saveSettings()
            }
        }
    }

    @Published var currentPreset: EQPreset? {
        didSet {
            if currentPreset?.id != oldValue?.id {
                applyEQSettings()
                saveSettings()
            }
        }
    }

    @Published var globalGain: Double = 0.0 {
        didSet {
            if abs(globalGain - oldValue) > 0.01 {
                applyGlobalGain()
                saveSettings()
            }
        }
    }

    @Published var availablePresets: [EQPreset] = []

    // Runtime EQ data used by both AVAudioEngine and SFBAudioEngine backends
    private var eqFrequencies: [Double] = []
    private var eqGains: [Double] = []
    private var eqBandwidths: [Double] = []

    // Public getters for SFBAudioEngine integration
    var currentEQFrequencies: [Double] { eqFrequencies }
    var currentEQGains: [Double] { eqGains }
    var currentEQBandwidths: [Double] { eqBandwidths }

    let databaseManager = DatabaseManager.shared
    private var audioEngine: AVAudioEngine?
    private var eqNode: AVAudioUnitEQ?

    /// Where the live node sits in the native graph, remembered so a rebuilt
    /// node can be put back exactly where the old one was.
    private var eqGraphInputNode: AVAudioNode?
    private var eqGraphOutputNode: AVAudioNode?
    private var eqGraphFormat: AVAudioFormat?

    /// AVAudioUnitEQ's band count is fixed at construction, so PlayerEngine
    /// has to stop the engine, let us swap the node, and re-schedule the
    /// playing track around it. Set by PlayerEngine; see
    /// `nativeEQNodeNeedsRebuild`.
    var onNativeEQGraphRebuildNeeded: (() -> Void)?

    /// iOS supports more, but AVAudioUnitEQ becomes unreliable well before
    /// its documented ceiling - keep the same safe cap everywhere.
    private static let maxSafeBands = 16

    private init() {
        loadSettings()
        loadPresets()
    }

    // MARK: - Audio Engine Integration

    func setAudioEngine(_ engine: AVAudioEngine?) {
        audioEngine = engine
        // The old node belonged to the old engine; its recorded insertion
        // points are meaningless against a replacement graph.
        eqGraphInputNode = nil
        eqGraphOutputNode = nil
        eqGraphFormat = nil
        setupEQNode()
    }

    /// How many bands the node should have for the preset currently loaded.
    private var desiredBandCount: Int {
        eqFrequencies.isEmpty
            ? Self.maxSafeBands
            : min(eqFrequencies.count, Self.maxSafeBands)
    }

    /// True when the live node is too small for the current preset.
    ///
    /// The node is built once, sized for whatever preset happened to be loaded
    /// at the time - which is the preset active on the session's first native
    /// playback, or 16 bands when EQ was off. `configureEQBands()` then had to
    /// squeeze every later preset into that fixed count, and its
    /// more-bands-than-slots branch *averages* neighbouring bands together: a
    /// 10-band preset selected after a 5-band one was silently played as five
    /// smeared bands for the rest of the session while the UI drew the real
    /// curve.
    ///
    /// Deliberately one-directional. Fewer input bands than slots is already
    /// handled correctly - `configureEQBands()` maps them one-to-one and
    /// bypasses the remainder - so shrinking the node would be pure churn on
    /// a live audio graph. And because the target is capped at
    /// `maxSafeBands`, a 31-band preset asks for 16 and is satisfied by a
    /// 16-band node; it is still averaged down to 16, which is the iOS limit
    /// rather than a bug.
    var nativeEQNodeNeedsRebuild: Bool {
        guard let eqNode, !eqFrequencies.isEmpty else { return false }
        return desiredBandCount > eqNode.bands.count
    }

    /// Swaps in a node sized for the current preset and restores its place in
    /// the graph. The caller must have stopped the engine first - PlayerEngine
    /// does that in `rebuildNativeEQGraph()`, which also re-schedules the
    /// playing track afterwards.
    func rebuildNativeEQNode() {
        guard audioEngine != nil, eqNode != nil else { return }

        let input = eqGraphInputNode
        let output = eqGraphOutputNode
        let format = eqGraphFormat

        setupEQNode()

        // setupEQNode() only attaches. Without this the graph is left with the
        // player node wired to nothing and playback goes silent.
        if let input, let output {
            insertEQIntoAudioGraph(between: input, and: output, format: format)
        }
    }

    private func setupEQNode() {
        guard let audioEngine = audioEngine else { return }

        // Detach whatever was there before. Every call used to build and
        // attach another node without removing the previous one, so repeated
        // setup left orphans attached to the engine.
        if let previousNode = eqNode {
            if audioEngine.attachedNodes.contains(previousNode) {
                audioEngine.disconnectNodeOutput(previousNode)
                audioEngine.disconnectNodeInput(previousNode)
                audioEngine.detach(previousNode)
            }
            eqNode = nil
        }

        let maxSafeBands = Self.maxSafeBands
        let requestedBands = desiredBandCount

        print("🎛️ Original bands: \(eqFrequencies.count), requesting: \(requestedBands) (limited to \(maxSafeBands))")

        eqNode = AVAudioUnitEQ(numberOfBands: requestedBands)
        guard let eqNode = eqNode else { return }

        let actualBands = eqNode.bands.count
        print("🎛️ Requested \(requestedBands) bands for GraphicEQ preset, iOS created \(actualBands) bands")

        // Configure bands if we have frequency data
        if !eqFrequencies.isEmpty {
            configureEQBands()
            if eqFrequencies.count > maxSafeBands {
                print("⚠️ GraphicEQ preset has \(eqFrequencies.count) bands, reduced to \(actualBands) bands (iOS limit)")
            } else {
                print("✅ Using \(actualBands) bands from GraphicEQ preset")
            }
        } else {
            // Default configuration for empty presets
            for i in 0..<actualBands {
                let band = eqNode.bands[i]
                band.frequency = Float(1000 * pow(2.0, Double(i - actualBands/2)))
                band.gain = 0.0
                band.bandwidth = 1.0
                band.filterType = .parametric
                band.bypass = true
            }
        }

        // Attach the EQ node
        audioEngine.attach(eqNode)

        print("✅ EQ node created with \(actualBands) bands")

        // Reconcile the brand-new node with `isEnabled`. Neither half of this
        // is implied by the band configuration above:
        //
        // - A fresh AVAudioUnitEQ starts at globalGain 0, and only
        //   applyGlobalGain() ever writes the preamp. Skipping applyEQSettings()
        //   below therefore lost the saved preamp on every rebuild that already
        //   had band data - most visibly on the Opus/DSD -> FLAC transition,
        //   which rebuilds the whole graph through resetAudioEngineForNative().
        // - configureEQBands() un-bypasses whatever it maps regardless of the
        //   toggle, so a node built while EQ is switched off used to come up
        //   audibly applying the last preset.
        //
        // Set the node directly rather than calling applyGlobalGain(): that
        // also pokes SFBAudioEngineManager, which has nothing to do with
        // building the native graph.
        if isEnabled {
            eqNode.globalGain = Float(globalGain)
        } else {
            // Disabling EQ disables the preamp with it - same as applyEQSettings().
            eqNode.globalGain = 0.0
            eqNode.bands.forEach { $0.bypass = true }
        }

        // Only reach for the database when we have no band data yet. Calling
        // this unconditionally made every rebuild re-load the preset it was
        // just rebuilt for - the branch above has already configured the node
        // from the bands we hold.
        if isEnabled && eqFrequencies.isEmpty {
            applyEQSettings()
        }
    }

    func insertEQIntoAudioGraph(between inputNode: AVAudioNode, and outputNode: AVAudioNode, format: AVAudioFormat?) {
        guard let audioEngine = audioEngine, let eqNode = eqNode else { return }

        // Remembered so a band-count rebuild can put the replacement node back
        // in the same place without PlayerEngine having to describe the graph
        // again.
        eqGraphInputNode = inputNode
        eqGraphOutputNode = outputNode
        eqGraphFormat = format

        // Disconnect existing connection
        audioEngine.disconnectNodeInput(outputNode)

        // Connect: input -> EQ -> output
        audioEngine.connect(inputNode, to: eqNode, format: format)
        audioEngine.connect(eqNode, to: outputNode, format: format)

        print("✅ EQ node inserted between \(inputNode) and \(outputNode)")
    }

    // Expose this for PlayerEngine to use when reconfiguring
    var currentEQNode: AVAudioUnitEQ? {
        return eqNode
    }

    private func configureEQBands() {
        guard let eqNode = eqNode, !eqFrequencies.isEmpty else { return }

        let availableBands = eqNode.bands.count
        let inputBandCount = eqFrequencies.count

        if inputBandCount <= availableBands {
            // Direct mapping - use exactly what we have
            for i in 0..<inputBandCount {
                let band = eqNode.bands[i]
                band.frequency = Float(eqFrequencies[i])
                band.gain = i < eqGains.count ? Float(eqGains[i]) : 0.0
                let bandwidth = i < eqBandwidths.count ? eqBandwidths[i] : 1.0
                band.bandwidth = Float(max(0.05, min(5.0, bandwidth)))
                band.filterType = .parametric
                band.bypass = false
            }

            // Bypass remaining bands
            for i in inputBandCount..<availableBands {
                eqNode.bands[i].bypass = true
            }

            print("✅ Direct mapping: Using all \(inputBandCount) bands")
        } else {
            // More input bands than available - group and average multiple bands
            print("🔄 Reducing \(inputBandCount) bands to \(availableBands) bands using frequency grouping and averaging")

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

                let band = eqNode.bands[i]
                band.frequency = Float(avgFrequency)
                band.gain = Float(avgGain)
                band.bandwidth = Float(max(0.05, min(5.0, avgBandwidth)))
                band.filterType = .parametric
                band.bypass = false

                print("  Band \(i): \(avgFrequency.rounded(toPlaces: 1))Hz, \(avgGain.rounded(toPlaces: 1))dB (avg of \(groupSize) bands: \(startIndex)-\(endIndex-1))")
            }

            print("✅ Applied frequency grouping and averaging (\(bandsPerGroup.rounded(toPlaces: 1)) bands per group)")
        }
    }

    private func applyEQSettings() {
        let eqNode = self.eqNode
        
        if !isEnabled || currentPreset == nil {
            eqNode?.bands.forEach { $0.bypass = true }
            eqNode?.globalGain = 0.0
            
            SFBAudioEngineManager.shared.updateEQSettings()
            print("🚫 EQ disabled - all bands bypassed")
            return
        }
        
        guard let preset = currentPreset else {
            SFBAudioEngineManager.shared.updateEQSettings()
            return
        }
        
        Task {
            do {
                let bands = try await loadBands(for: preset)
                let sortedBands = bands.sorted { $0.bandIndex < $1.bandIndex }
                
                await MainActor.run {
                    let newFrequencies = sortedBands.map { $0.frequency }
                    let newGains = sortedBands.map { $0.gain }
                    let newBandwidths = sortedBands.map { max(0.05, min(5.0, $0.bandwidth)) }
                    
                    self.eqFrequencies = newFrequencies
                    self.eqGains = newGains
                    self.eqBandwidths = newBandwidths

                    if self.eqNode == nil {
                        print("ℹ️ Stored \(newFrequencies.count) EQ bands for SFBAudioEngine")
                    } else if self.nativeEQNodeNeedsRebuild {
                        // Too few slots for this preset. Reconfiguring in place
                        // would average neighbouring bands together and quietly
                        // play a coarser curve than the one on screen, so ask
                        // PlayerEngine to swap the node instead.
                        print("🎛️ EQ node has \(self.eqNode?.bands.count ?? 0) bands but the preset needs \(self.desiredBandCount) - rebuilding")
                        if let rebuild = self.onNativeEQGraphRebuildNeeded {
                            rebuild()
                        } else {
                            // No engine owner registered; the node is not in a
                            // live graph, so swapping it here is safe.
                            self.rebuildNativeEQNode()
                        }
                    } else {
                        self.configureEQBands()
                        print("✅ Reconfigured existing EQ node with \(newFrequencies.count) input bands")
                    }
                }
                
                applyGlobalGain()
                print("✅ Applied EQ preset: \(preset.name)")
            } catch {
                print("❌ Failed to apply EQ settings: \(error)")
            }
        }
    }

    private func applyGlobalGain() {
        let globalGainFloat = Float(globalGain)
        eqNode?.globalGain = globalGainFloat
        
        SFBAudioEngineManager.shared.updateEQSettings()
    }



    // MARK: - Preset Management

    func loadPresets() {
        Task {
            do {
                let presets = try await databaseManager.getAllEQPresets()
                await MainActor.run {
                    self.availablePresets = presets
                }
            } catch {
                print("❌ Failed to load EQ presets: \(error)")
            }
        }
    }

    static func defaultParametricFrequencies(for bandCount: Int) -> [Double] {
        let clampedBandCount = max(0, min(16, bandCount))
        guard clampedBandCount > 0 else { return [] }
        guard clampedBandCount > 1 else { return [1000.0] }

        let minFrequency = 20.0
        let maxFrequency = 20_000.0
        return (0..<clampedBandCount).map { index in
            minFrequency * pow(maxFrequency / minFrequency, Double(index) / Double(clampedBandCount - 1))
        }
    }

    func createPreset(
        name: String,
        frequencies: [Double],
        gains: [Double],
        bandwidths: [Double]? = nil,
        type: EQPresetType = .imported
    ) async throws -> EQPreset {
        let currentTime = Int64(Date().timeIntervalSince1970)

        let preset = EQPreset(
            name: name,
            isBuiltIn: false,
            isActive: false,
            presetType: type,
            createdAt: currentTime,
            updatedAt: currentTime
        )

        let savedPreset = try await databaseManager.saveEQPreset(preset)

        // Create bands for the preset
        let bandCount = min(frequencies.count, gains.count)
        let bandwidthValues = bandwidths ?? Array(repeating: 1.0, count: bandCount)
        for index in 0..<bandCount {
            let band = EQBand(
                presetId: savedPreset.id!,
                frequency: frequencies[index],
                gain: gains[index],
                bandwidth: index < bandwidthValues.count ? max(0.05, min(5.0, bandwidthValues[index])) : 1.0,
                bandIndex: index
            )
            try await databaseManager.saveEQBand(band)
        }

        await MainActor.run {
            self.loadPresets()
        }

        return savedPreset
    }

    func deletePreset(_ preset: EQPreset) async throws {
        guard !preset.isBuiltIn else {
            throw EQError.cannotDeleteBuiltInPreset
        }

        try await databaseManager.deleteEQPreset(preset)

        await MainActor.run {
            if self.currentPreset?.id == preset.id {
                self.currentPreset = nil
            }
            self.loadPresets()
        }
    }

    func updatePresetBands(_ preset: EQPreset, frequencies: [Double], gains: [Double], bandwidths: [Double]) async throws {
        let currentTime = Int64(Date().timeIntervalSince1970)

        try await databaseManager.write { db in
            // Update preset timestamp
            var updatedPreset = preset
            updatedPreset.updatedAt = currentTime
            try updatedPreset.update(db)

            // Delete existing bands for this preset
            try db.execute(sql: "DELETE FROM eq_band WHERE preset_id = ?", arguments: [preset.id!])

            // Insert new bands
            let bandCount = min(min(frequencies.count, gains.count), bandwidths.count)
            for index in 0..<bandCount {
                var band = EQBand(
                    presetId: preset.id!,
                    frequency: frequencies[index],
                    gain: gains[index],
                    bandwidth: max(0.05, min(5.0, bandwidths[index])),
                    bandIndex: index
                )
                try band.insert(db)
            }
        }

        // If this is the current preset, apply changes immediately
        await MainActor.run {
            if self.currentPreset?.id == preset.id {
                self.applyEQSettings()
            }
        }
    }

    func updatePresetGains(_ preset: EQPreset, frequencies: [Double], gains: [Double]) async throws {
        let bandwidths = Array(repeating: 1.0, count: min(frequencies.count, gains.count))
        try await updatePresetBands(preset, frequencies: frequencies, gains: gains, bandwidths: bandwidths)
    }

    private func loadBands(for preset: EQPreset) async throws -> [EQBand] {
        return try await databaseManager.getBands(for: preset)
    }

    // MARK: - Settings Persistence

    private func loadSettings() {
        Task {
            do {
                if let settings = try await databaseManager.getEQSettings() {
                    await MainActor.run {
                        self.isEnabled = settings.isEnabled
                        self.globalGain = settings.globalGain
                        if let activePresetId = settings.activePresetId {
                            // Load the active preset
                            Task {
                                if let preset = try? await self.databaseManager.getEQPreset(id: activePresetId) {
                                    await MainActor.run {
                                        self.currentPreset = preset
                                    }
                                }
                            }
                        }
                    }
                } else {
                    // Create default settings
                    let defaultSettings = EQSettings(
                        isEnabled: false,
                        activePresetId: nil,
                        globalGain: 0.0,
                        updatedAt: Int64(Date().timeIntervalSince1970)
                    )
                    try await databaseManager.saveEQSettings(defaultSettings)
                }
            } catch {
                print("❌ Failed to load EQ settings: \(error)")
            }
        }
    }

    private func saveSettings() {
        Task {
            do {
                let settings = EQSettings(
                    isEnabled: self.isEnabled,
                    activePresetId: self.currentPreset?.id,
                    globalGain: self.globalGain,
                    updatedAt: Int64(Date().timeIntervalSince1970)
                )
                try await databaseManager.saveEQSettings(settings)
            } catch {
                print("❌ Failed to save EQ settings: \(error)")
            }
        }
    }

    // MARK: - GraphicEQ Import

    // MARK: - Import/Export

    func exportPreset(_ preset: EQPreset) async throws -> String {
        let bands = try await loadBands(for: preset)
        let sortedBands = bands.sorted { $0.bandIndex < $1.bandIndex }

        // Create GraphicEQ format string
        var graphicEQString = "GraphicEQ: "
        let bandStrings = sortedBands.map { band in
            "\(Int(band.frequency)) \(band.gain)"
        }
        graphicEQString += bandStrings.joined(separator: "; ")

        return graphicEQString
    }

    func createManualParametricPreset(name: String, bandCount: Int) async throws -> EQPreset {
        let frequencies = EQManager.defaultParametricFrequencies(for: bandCount)
        let gains = Array(repeating: 0.0, count: frequencies.count)
        let bandwidths = Array(repeating: 1.0, count: frequencies.count)

        return try await createPreset(
            name: name,
            frequencies: frequencies,
            gains: gains,
            bandwidths: bandwidths,
            type: .manual
        )
    }

    func createManual16BandPreset(name: String) async throws -> EQPreset {
        return try await createManualParametricPreset(name: name, bandCount: 16)
    }

    func importGraphicEQPreset(from content: String, name: String) async throws -> EQPreset {
        // Parse GraphicEQ format
        let (frequencies, gains) = try parseGraphicEQString(content)

        // Validate we have data
        guard !frequencies.isEmpty && frequencies.count == gains.count else {
            throw EQError.invalidImportData
        }

        return try await createPreset(name: name, frequencies: frequencies, gains: gains, type: .imported)
    }

    private func parseGraphicEQString(_ content: String) throws -> ([Double], [Double]) {
        // Find the GraphicEQ line
        let lines = content.components(separatedBy: .newlines)
        guard let graphicEQLine = lines.first(where: { $0.contains("GraphicEQ:") }) else {
            throw EQError.invalidGraphicEQFormat
        }

        // Extract the data part after "GraphicEQ:"
        guard let colonIndex = graphicEQLine.firstIndex(of: ":") else {
            throw EQError.invalidGraphicEQFormat
        }

        let dataString = String(graphicEQLine[graphicEQLine.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)

        // Parse frequency-gain pairs separated by semicolons
        let pairs = dataString.components(separatedBy: ";")

        var frequencies: [Double] = []
        var gains: [Double] = []

        for pair in pairs {
            let trimmedPair = pair.trimmingCharacters(in: .whitespaces)
            let components = trimmedPair.components(separatedBy: .whitespaces)

            guard components.count >= 2,
                  let frequency = Double(components[0]),
                  let gain = Double(components[1]) else {
                continue
            }

            frequencies.append(frequency)
            gains.append(gain)
        }

        guard !frequencies.isEmpty else {
            throw EQError.invalidGraphicEQFormat
        }

        return (frequencies, gains)
    }
}

// MARK: - Errors

enum EQError: Error, LocalizedError {
    case cannotDeleteBuiltInPreset
    case invalidImportData
    case invalidGraphicEQFormat
    case presetNotFound

    var errorDescription: String? {
        switch self {
        case .cannotDeleteBuiltInPreset:
            return "Cannot delete built-in presets"
        case .invalidImportData:
            return "Invalid preset import data"
        case .invalidGraphicEQFormat:
            return "Invalid GraphicEQ format. Expected format: 'GraphicEQ: freq1 gain1; freq2 gain2; ...'"
        case .presetNotFound:
            return "Preset not found"
        }
    }
}
