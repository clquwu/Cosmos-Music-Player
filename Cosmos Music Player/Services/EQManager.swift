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

    // We'll use dynamic frequencies based on imported GraphicEQ files
    private var eqFrequencies: [Double] = []
    private var eqGains: [Double] = []

    private let databaseManager = DatabaseManager.shared
    private var audioEngine: AVAudioEngine?
    private var eqNode: AVAudioUnitEQ?

    private init() {
        loadSettings()
        loadPresets()
    }

    // MARK: - Audio Engine Integration

    func setAudioEngine(_ engine: AVAudioEngine?) {
        audioEngine = engine
        setupEQNode()
    }

    private func setupEQNode() {
        guard let audioEngine = audioEngine else { return }

        // iOS supports up to ~48 bands for AVAudioUnitEQ
        // Using more may cause issues - limit to safe maximum
        let maxSafeBands = 16
        let requestedBands = !eqFrequencies.isEmpty ? min(eqFrequencies.count, maxSafeBands) : maxSafeBands

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

        // Apply current settings if enabled
        if isEnabled {
            applyEQSettings()
        }
    }

    func insertEQIntoAudioGraph(between inputNode: AVAudioNode, and outputNode: AVAudioNode, format: AVAudioFormat?) {
        guard let audioEngine = audioEngine, let eqNode = eqNode else { return }

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
                band.bandwidth = 1.0
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

                let band = eqNode.bands[i]
                band.frequency = Float(avgFrequency)
                band.gain = Float(avgGain)
                band.bandwidth = 1.0
                band.filterType = .parametric
                band.bypass = false

                print("  Band \(i): \(avgFrequency.rounded(toPlaces: 1))Hz, \(avgGain.rounded(toPlaces: 1))dB (avg of \(groupSize) bands: \(startIndex)-\(endIndex-1))")
            }

            print("✅ Applied frequency grouping and averaging (\(bandsPerGroup.rounded(toPlaces: 1)) bands per group)")
        }
    }

    private func applyEQSettings() {
        guard let eqNode = eqNode else { return }

        if !isEnabled || currentPreset == nil {
            // Bypass EQ if disabled or no preset
            eqNode.bands.forEach { $0.bypass = true }
            eqNode.globalGain = 0.0  // Reset global gain when disabled
            print("🚫 EQ disabled - all bands bypassed")
            return
        }

        guard let preset = currentPreset else { return }

        Task {
            do {
                let bands = try await loadBands(for: preset)
                let sortedBands = bands.sorted { $0.bandIndex < $1.bandIndex }

                await MainActor.run {
                    // Update internal frequency and gain arrays
                    let newFrequencies = sortedBands.map { $0.frequency }
                    let newGains = sortedBands.map { $0.gain }

                    // Always just reconfigure existing node - avoid recreation to prevent track skipping
                    self.eqFrequencies = newFrequencies
                    self.eqGains = newGains
                    self.configureEQBands()

                    print("✅ Reconfigured existing EQ node with \(newFrequencies.count) input bands")
                }

                applyGlobalGain()
                print("✅ Applied EQ preset: \(preset.name)")

            } catch {
                print("❌ Failed to apply EQ settings: \(error)")
            }
        }
    }

    private func applyGlobalGain() {
        guard let eqNode = eqNode else { return }

        // Apply global gain to all bands
        let globalGainFloat = Float(globalGain)
        eqNode.globalGain = globalGainFloat
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

    func createPreset(name: String, frequencies: [Double], gains: [Double]) async throws -> EQPreset {
        let currentTime = Int64(Date().timeIntervalSince1970)

        let preset = EQPreset(
            name: name,
            isBuiltIn: false,
            isActive: false,
            createdAt: currentTime,
            updatedAt: currentTime
        )

        let savedPreset = try await databaseManager.saveEQPreset(preset)

        // Create bands for the preset
        let bandCount = min(frequencies.count, gains.count)
        for index in 0..<bandCount {
            let band = EQBand(
                presetId: savedPreset.id!,
                frequency: frequencies[index],
                gain: gains[index],
                bandwidth: 1.0,
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

    func updatePresetGains(_ preset: EQPreset, frequencies: [Double], gains: [Double]) async throws {
        let currentTime = Int64(Date().timeIntervalSince1970)

        // Update preset timestamp
        var updatedPreset = preset
        updatedPreset.updatedAt = currentTime
        _ = try await databaseManager.saveEQPreset(updatedPreset)

        // Clear existing bands and create new ones
        // Note: This is a simplified approach. In a production app, you might want to update existing bands instead
        let bandCount = min(frequencies.count, gains.count)
        for index in 0..<bandCount {
            let band = EQBand(
                presetId: preset.id!,
                frequency: frequencies[index],
                gain: gains[index],
                bandwidth: 1.0,
                bandIndex: index
            )
            try await databaseManager.saveEQBand(band)
        }

        // If this is the current preset, apply changes immediately
        await MainActor.run {
            if self.currentPreset?.id == preset.id {
                self.applyEQSettings()
            }
        }
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

    func importGraphicEQPreset(from content: String, name: String) async throws -> EQPreset {
        // Parse GraphicEQ format
        let (frequencies, gains) = try parseGraphicEQString(content)

        // Validate we have data
        guard !frequencies.isEmpty && frequencies.count == gains.count else {
            throw EQError.invalidImportData
        }

        return try await createPreset(name: name, frequencies: frequencies, gains: gains)
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
