//
//  EQSettingsView.swift
//  Cosmos Music Player
//
//  Graphic equalizer settings and management UI
//

import SwiftUI

struct EQSettingsView: View {
    @StateObject private var eqManager = EQManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showingImport = false
    @State private var showingCreateManual = false
    @State private var showingEditManual = false

    var body: some View {
        NavigationView {
            formContent
        }
    }

    private var formContent: some View {
        Form {
            // EQ Enable/Disable
            Section {
                Toggle(Localized.enableEqualizer, isOn: $eqManager.isEnabled)
                    .tint(.blue)
            } footer: {
                Text(Localized.enableDisableEqDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Manual Parametric Presets
            Section(Localized.manualEQPresets) {
                if !eqManager.availablePresets.filter({ $0.presetType == .manual }).isEmpty {
                    ForEach(eqManager.availablePresets.filter { $0.presetType == .manual }) { preset in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name)
                                    .font(.headline)

                                Text("Manual Parametric EQ")
                                    .font(.caption)
                                    .foregroundColor(.green)
                            }

                            Spacer()

                            if eqManager.currentPreset?.id == preset.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.blue)
                                    .font(.system(size: 20))
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            eqManager.currentPreset = preset
                            showingEditManual = true
                        }
                        .swipeActions(edge: .trailing) {
                            Button(Localized.eqDelete, role: .destructive) {
                                deletePreset(preset)
                            }

                            Button(Localized.eqEdit) {
                                eqManager.currentPreset = preset
                                showingEditManual = true
                            }
                            .tint(.green)

                            Button(Localized.eqExport) {
                                exportPreset(preset)
                            }
                            .tint(.blue)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Localized.noManualPresetsCreated)
                            .foregroundColor(.secondary)
                            .italic()

                        Text(Localized.createManualEQDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Button("Create Manual EQ") {
                    showingCreateManual = true
                }
                .foregroundColor(.green)
            }

            // Imported GraphicEQ Presets
            Section(Localized.importedPresets) {
                if !eqManager.availablePresets.filter({ $0.presetType == .imported }).isEmpty {
                    ForEach(eqManager.availablePresets.filter { $0.presetType == .imported }) { preset in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name)
                                    .font(.headline)

                                Text(Localized.importedGraphicEQ)
                                    .font(.caption)
                                    .foregroundColor(.blue)
                            }

                            Spacer()

                            if eqManager.currentPreset?.id == preset.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.blue)
                                    .font(.system(size: 20))
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            eqManager.currentPreset = preset
                        }
                        .swipeActions(edge: .trailing) {
                            Button(Localized.eqDelete, role: .destructive) {
                                deletePreset(preset)
                            }

                            Button(Localized.eqExport) {
                                exportPreset(preset)
                            }
                            .tint(.blue)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Localized.noPresetsImported)
                            .foregroundColor(.secondary)
                            .italic()

                        Text(Localized.importGraphicEQDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Button(Localized.importGraphicEQFile) {
                    showingImport = true
                }
                .foregroundColor(.blue)
            }

            // Global Gain (only show when EQ is enabled)
            if eqManager.isEnabled {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(Localized.globalGain)
                            Spacer()
                            Text("\(eqManager.globalGain, specifier: "%.1f")dB")
                                .foregroundColor(.secondary)
                        }

                        Slider(value: $eqManager.globalGain, in: -30...30, step: 0.5)
                            .tint(.blue)
                    }
                } header: {
                    Text(Localized.globalSettings)
                } footer: {
                    Text(Localized.globalGainDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Info Section
            Section(Localized.aboutGraphicEQFormat) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(Localized.importGraphicEQFormatDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("GraphicEQ: 20 -7.9; 21 -7.8; 22 -8.0; ...")
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(Color(.systemGray6))
                        .cornerRadius(4)

                    Text(Localized.frequencyGainPairDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle(Localized.equalizer)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingImport) {
            GraphicEQImportView()
        }
        .sheet(isPresented: $showingCreateManual) {
            CreateManualEQView()
        }
        .sheet(isPresented: $showingEditManual) {
            if let preset = eqManager.currentPreset, preset.presetType == .manual {
                ManualEQEditorView(preset: preset)
            }
        }
    }

    // MARK: - Helper Methods

    private func deletePreset(_ preset: EQPreset) {
        Task {
            do {
                try await eqManager.deletePreset(preset)
            } catch {
                print("❌ \(Localized.failedToDelete): \(error)")
            }
        }
    }

    private func exportPreset(_ preset: EQPreset) {
        Task {
            do {
                let graphicEQString = try await eqManager.exportPreset(preset)
                await MainActor.run {
                    let activityVC = UIActivityViewController(activityItems: [graphicEQString], applicationActivities: nil)
                    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                       let rootViewController = windowScene.windows.first?.rootViewController {
                        rootViewController.present(activityVC, animated: true)
                    }
                }
            } catch {
                print("❌ \(Localized.failedToExport): \(error)")
            }
        }
    }
}

// MARK: - Create Manual EQ View

struct CreateManualEQView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var eqManager = EQManager.shared

    @State private var presetName = ""
    @State private var bandCount = 0
    @State private var createError: String?

    var body: some View {
        NavigationView {
            Form {
                Section(Localized.presetName) {
                    TextField(Localized.enterPresetName, text: $presetName)
                }

                Section("Bands") {
                    Stepper(value: $bandCount, in: 0...16) {
                        Text("\(bandCount) / 16")
                    }
                }

                if let error = createError {
                    Section(Localized.eqError) {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }

                Section(Localized.presetInfo) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Create a parametric EQ preset with up to 16 fully editable bands.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text("You can edit frequency, gain, and Q for every band after creation.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Create Manual EQ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(Localized.eqCancel) {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(Localized.eqCreate) {
                        createPreset()
                    }
                    .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func createPreset() {
        Task {
            do {
                let preset = try await eqManager.createManualParametricPreset(name: presetName, bandCount: bandCount)

                await MainActor.run {
                    eqManager.currentPreset = preset
                    createError = nil
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    createError = Localized.failedToCreate(error.localizedDescription)
                }
            }
        }
    }
}

// MARK: - Manual EQ Editor View

struct ManualEQEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var eqManager = EQManager.shared

    let preset: EQPreset
    @State private var bandFrequencies: [Double] = []
    @State private var bandGains: [Double] = []
    @State private var bandBandwidths: [Double] = []
    @State private var selectedBandIndex: Int? = nil
    @State private var isLoading = true

    private let minFrequency = 20.0
    private let maxFrequency = 20_000.0
    private let minGain = -18.0
    private let maxGain = 18.0
    private let maxBands = 16

    private var editableBandCount: Int {
        min(bandFrequencies.count, min(bandGains.count, bandBandwidths.count))
    }

    var body: some View {
        NavigationView {
            if isLoading {
                ProgressView()
                    .onAppear {
                        loadBands()
                    }
            } else {
                Form {
                    Section {
                        HStack {
                            Text(preset.name)
                                .font(.headline)
                            Spacer()
                            Text("\(editableBandCount) / \(maxBands) bands")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Section("Parametric Editor") {
                        ParametricEQGraphView(
                            frequencies: $bandFrequencies,
                            gains: $bandGains,
                            selectedBandIndex: $selectedBandIndex,
                            minFrequency: minFrequency,
                            maxFrequency: maxFrequency,
                            minGain: minGain,
                            maxGain: maxGain
                        )
                        .frame(height: 260)

                        HStack {
                            Button("Add Band") {
                                addBand()
                            }
                            .disabled(editableBandCount >= maxBands)
                            .buttonStyle(.bordered)

                            Button("Remove Band") {
                                removeSelectedBand()
                            }
                            .disabled(editableBandCount == 0)
                            .buttonStyle(.bordered)
                        }
                    }

                    if let selectedBandIndex, selectedBandIndex < editableBandCount {
                        Section("Selected Band") {
                            Text("Band \(selectedBandIndex + 1)")
                                .font(.headline)

                            HStack {
                                Text("Frequency")
                                Spacer()
                                Text(formatFrequency(bandFrequencies[selectedBandIndex]))
                                    .foregroundColor(.secondary)
                            }
                            Slider(
                                value: Binding(
                                    get: { logFrequencyValue(for: bandFrequencies[selectedBandIndex]) },
                                    set: { bandFrequencies[selectedBandIndex] = frequency(fromLogValue: $0).rounded(toPlaces: 1) }
                                ),
                                in: log10(minFrequency)...log10(maxFrequency)
                            )
                            .tint(.orange)

                            HStack {
                                Text("Gain")
                                Spacer()
                                Text("\(bandGains[selectedBandIndex], specifier: "%.1f") dB")
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: $bandGains[selectedBandIndex], in: minGain...maxGain, step: 0.1)
                                .tint(.blue)

                            HStack {
                                Text("Q")
                                Spacer()
                                Text("\(qFactor(fromBandwidth: bandBandwidths[selectedBandIndex]), specifier: "%.2f")")
                                    .foregroundColor(.secondary)
                            }
                            Slider(
                                value: Binding(
                                    get: { qFactor(fromBandwidth: bandBandwidths[selectedBandIndex]) },
                                    set: { bandBandwidths[selectedBandIndex] = bandwidth(fromQFactor: $0) }
                                ),
                                in: 0.10...10.0,
                                step: 0.01
                            )
                            .tint(.purple)
                        }
                    }

                    Section {
                        Button(Localized.resetToFlat) { resetToFlat() }
                    }
                }
                .navigationTitle(Localized.editEqualizer)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(Localized.eqCancel) {
                            dismiss()
                        }
                    }

                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(Localized.eqSave) {
                            saveChanges()
                        }
                    }
                }
                .onChange(of: editableBandCount) { newCount in
                    if newCount == 0 {
                        selectedBandIndex = nil
                    } else if let selectedBandIndex, selectedBandIndex >= newCount {
                        self.selectedBandIndex = newCount - 1
                    }
                }
            }
        }
    }

    private func loadBands() {
        Task {
            do {
                let bands = try await eqManager.databaseManager.getBands(for: preset)
                let sortedBands = bands.sorted { $0.bandIndex < $1.bandIndex }
                let targetBandCount = sortedBands.count

                await MainActor.run {
                    bandFrequencies = []
                    bandGains = []
                    bandBandwidths = []

                    for index in 0..<targetBandCount {
                        let defaultFrequency = defaultFrequencies(for: targetBandCount)[index]

                        if index < sortedBands.count {
                            bandFrequencies.append(max(minFrequency, min(maxFrequency, sortedBands[index].frequency)))
                            bandGains.append(sortedBands[index].gain)
                            bandBandwidths.append(max(0.05, min(5.0, sortedBands[index].bandwidth)))
                        } else {
                            bandFrequencies.append(defaultFrequency)
                            bandGains.append(0.0)
                            bandBandwidths.append(1.0)
                        }
                    }

                    selectedBandIndex = editableBandCount > 0 ? 0 : nil
                    isLoading = false
                }
            } catch {
                print("❌ Failed to load bands: \(error)")
                await MainActor.run {
                    isLoading = false
                }
            }
        }
    }

    private func saveChanges() {
        Task {
            do {
                let sortedBands = (0..<editableBandCount)
                    .map { index in
                        (
                            frequency: bandFrequencies[index],
                            gain: bandGains[index],
                            bandwidth: bandBandwidths[index]
                        )
                    }
                    .sorted { $0.frequency < $1.frequency }

                try await eqManager.updatePresetBands(
                    preset,
                    frequencies: sortedBands.map { $0.frequency },
                    gains: sortedBands.map { $0.gain },
                    bandwidths: sortedBands.map { $0.bandwidth }
                )

                await MainActor.run {
                    dismiss()
                }
            } catch {
                print("❌ Failed to save changes: \(error)")
            }
        }
    }

    private func formatFrequency(_ freq: Double) -> String {
        if freq >= 1000 {
            return String(format: "%.1fkHz", freq / 1000)
        } else {
            return String(format: "%.0fHz", freq)
        }
    }

    private func defaultFrequencies(for totalBands: Int) -> [Double] {
        EQManager.defaultParametricFrequencies(for: totalBands)
    }

    private func qFactor(fromBandwidth bandwidth: Double) -> Double {
        let clampedBandwidth = max(0.05, min(5.0, bandwidth))
        let twoPowBandwidth = pow(2.0, clampedBandwidth)
        let denominator = max(twoPowBandwidth - 1.0, 0.0001)
        let q = sqrt(twoPowBandwidth) / denominator
        return max(0.1, min(10.0, q))
    }

    private func bandwidth(fromQFactor qFactor: Double) -> Double {
        let q = max(0.1, min(10.0, qFactor))
        let reciprocal = 1.0 / (2.0 * q)
        let sqrtTerm = sqrt(1.0 + (1.0 / (4.0 * q * q)))
        let denominator = max(sqrtTerm - reciprocal, 0.0001)
        let bandwidth = log2((sqrtTerm + reciprocal) / denominator)
        guard bandwidth.isFinite else { return 1.0 }
        return max(0.05, min(5.0, bandwidth))
    }

    private func logFrequencyValue(for frequency: Double) -> Double {
        let clampedFrequency = max(minFrequency, min(maxFrequency, frequency))
        return log10(clampedFrequency)
    }

    private func frequency(fromLogValue logValue: Double) -> Double {
        let clampedLogValue = max(log10(minFrequency), min(log10(maxFrequency), logValue))
        return pow(10, clampedLogValue)
    }

    private func resetToFlat() {
        let defaults = defaultFrequencies(for: editableBandCount)
        for index in 0..<editableBandCount {
            bandFrequencies[index] = defaults[index]
            bandGains[index] = 0.0
            bandBandwidths[index] = 1.0
        }
    }

    private func addBand() {
        guard editableBandCount < maxBands else { return }

        let newFrequency: Double
        if let selectedBandIndex, bandFrequencies.indices.contains(selectedBandIndex), selectedBandIndex < editableBandCount - 1 {
            newFrequency = sqrt(bandFrequencies[selectedBandIndex] * bandFrequencies[selectedBandIndex + 1])
        } else if let lastFrequency = bandFrequencies.last {
            newFrequency = min(maxFrequency, lastFrequency * 1.5)
        } else {
            newFrequency = 1000.0
        }

        bandFrequencies.append(max(minFrequency, min(maxFrequency, newFrequency)))
        bandGains.append(0.0)
        bandBandwidths.append(1.0)

        selectedBandIndex = bandFrequencies.count - 1
    }

    private func removeSelectedBand() {
        guard editableBandCount > 0 else { return }
        let indexToRemove: Int
        if let selectedBandIndex, selectedBandIndex >= 0, selectedBandIndex < editableBandCount {
            indexToRemove = selectedBandIndex
        } else {
            indexToRemove = editableBandCount - 1
        }

        bandFrequencies.remove(at: indexToRemove)
        bandGains.remove(at: indexToRemove)
        bandBandwidths.remove(at: indexToRemove)

        if editableBandCount == 0 {
            self.selectedBandIndex = nil
        } else {
            self.selectedBandIndex = min(indexToRemove, editableBandCount - 1)
        }
    }
}

private struct ParametricEQGraphView: View {
    @Binding var frequencies: [Double]
    @Binding var gains: [Double]
    @Binding var selectedBandIndex: Int?

    let minFrequency: Double
    let maxFrequency: Double
    let minGain: Double
    let maxGain: Double

    var body: some View {
        GeometryReader { geometry in
            let plotRect = CGRect(
                x: 12,
                y: 12,
                width: max(geometry.size.width - 24, 1),
                height: max(geometry.size.height - 24, 1)
            )
            let points = frequencies.enumerated()
                .map { index, frequency in
                    (
                        index: index,
                        point: point(forFrequency: frequency, gain: gains[safe: index] ?? 0.0, in: plotRect)
                    )
                }
                .sorted { $0.point.x < $1.point.x }

            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemBackground))

                Path { path in
                    for tick in 0...6 {
                        let ratio = CGFloat(tick) / 6.0
                        let y = plotRect.minY + ratio * plotRect.height
                        path.move(to: CGPoint(x: plotRect.minX, y: y))
                        path.addLine(to: CGPoint(x: plotRect.maxX, y: y))
                    }
                }
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)

                Path { path in
                    guard let firstPoint = points.first?.point else { return }
                    path.move(to: firstPoint)
                    for point in points.dropFirst() {
                        path.addLine(to: point.point)
                    }
                }
                .stroke(Color.blue.opacity(0.85), lineWidth: 2)

                ForEach(points, id: \.index) { item in
                    Circle()
                        .fill(selectedBandIndex == item.index ? Color.orange : Color.blue)
                        .frame(width: selectedBandIndex == item.index ? 14 : 12, height: selectedBandIndex == item.index ? 14 : 12)
                        .position(item.point)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    selectedBandIndex = item.index
                                    frequencies[item.index] = frequency(forX: value.location.x, in: plotRect)
                                    gains[item.index] = gain(forY: value.location.y, in: plotRect)
                                }
                        )
                        .onTapGesture {
                            selectedBandIndex = item.index
                        }
                }
            }
        }
    }

    private func point(forFrequency frequency: Double, gain: Double, in plotRect: CGRect) -> CGPoint {
        let clampedFrequency = max(minFrequency, min(maxFrequency, frequency))
        let clampedGain = max(minGain, min(maxGain, gain))

        let xRatio = (log10(clampedFrequency) - log10(minFrequency)) / (log10(maxFrequency) - log10(minFrequency))
        let yRatio = (maxGain - clampedGain) / (maxGain - minGain)

        return CGPoint(
            x: plotRect.minX + CGFloat(xRatio) * plotRect.width,
            y: plotRect.minY + CGFloat(yRatio) * plotRect.height
        )
    }

    private func frequency(forX x: CGFloat, in plotRect: CGRect) -> Double {
        let clampedX = max(plotRect.minX, min(plotRect.maxX, x))
        let ratio = Double((clampedX - plotRect.minX) / plotRect.width)
        let logFrequency = log10(minFrequency) + ratio * (log10(maxFrequency) - log10(minFrequency))
        return pow(10, logFrequency)
    }

    private func gain(forY y: CGFloat, in plotRect: CGRect) -> Double {
        let clampedY = max(plotRect.minY, min(plotRect.maxY, y))
        let ratio = Double((clampedY - plotRect.minY) / plotRect.height)
        return maxGain - ratio * (maxGain - minGain)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}

// MARK: - GraphicEQ Import View

struct GraphicEQImportView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var eqManager = EQManager.shared

    @State private var showingDocumentPicker = false
    @State private var presetName = ""
    @State private var importError: String?
    @State private var showingTextImport = false
    @State private var textContent = ""

    var body: some View {
        NavigationView {
            Form {
                Section(Localized.presetName) {
                    TextField(Localized.enterPresetName, text: $presetName)
                }

                Section(Localized.importMethods) {
                    Button(Localized.importFromTxtFile) {
                        showingDocumentPicker = true
                    }
                    .foregroundColor(.blue)

                    Button(Localized.pasteGraphicEQText) {
                        showingTextImport = true
                    }
                    .foregroundColor(.blue)
                }

                if let error = importError {
                    Section(Localized.eqError) {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }

                Section(Localized.formatInfo) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Localized.expectedGraphicEQFormat)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text("GraphicEQ: 20 -7.9; 21 -7.9; 22 -8.0; 23 -8.0; ...")
                            .font(.caption2.monospaced())
                            .foregroundColor(.secondary)
                            .padding(8)
                            .background(Color(.systemGray6))
                            .cornerRadius(4)

                        Text(Localized.frequencyGainPair)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle(Localized.importGraphicEQ)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(Localized.eqCancel) {
                        dismiss()
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showingDocumentPicker,
            allowedContentTypes: [.plainText],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .sheet(isPresented: $showingTextImport) {
            TextImportView(
                textContent: $textContent,
                presetName: presetName.isEmpty ? "Imported Preset" : presetName,
                onImport: handleTextImport
            )
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            Task {
                guard url.startAccessingSecurityScopedResource() else {
                    await MainActor.run {
                        importError = Localized.fileImportFailed("Unable to access the selected file.")
                    }
                    return
                }
                defer { url.stopAccessingSecurityScopedResource() }

                do {
                    let content = try String(contentsOf: url, encoding: .utf8)
                    let finalPresetName = presetName.isEmpty
                    ? url.deletingPathExtension().lastPathComponent
                    : presetName

                    let preset = try await eqManager.importGraphicEQPreset(from: content, name: finalPresetName)

                    await MainActor.run {
                        eqManager.currentPreset = preset
                        importError = nil
                        dismiss()
                    }
                } catch {
                    await MainActor.run {
                        importError = Localized.failedToImport(error.localizedDescription)
                    }
                }
            }

        case .failure(let error):
            importError = Localized.fileImportFailed(error.localizedDescription)
        }
    }

    private func handleTextImport(_ content: String, name: String) {
        Task {
            do {
                let preset = try await eqManager.importGraphicEQPreset(from: content, name: name)

                await MainActor.run {
                    eqManager.currentPreset = preset
                    importError = nil
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    importError = Localized.failedToImport(error.localizedDescription)
                }
            }
        }
    }
}

// MARK: - Text Import View

struct TextImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var textContent: String
    let presetName: String
    let onImport: (String, String) -> Void

    var body: some View {
        NavigationView {
            Form {
                Section(Localized.pasteGraphicEQTextSection) {
                    TextEditor(text: $textContent)
                        .frame(minHeight: 200)
                        .font(.caption.monospaced())
                }

                Section(Localized.example) {
                    Text("GraphicEQ: 20 -7.9; 21 -7.9; 22 -8.0; ...")
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle(Localized.pasteGraphicEQ)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(Localized.eqCancel) {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(Localized.eqImport) {
                        onImport(textContent, presetName)
                        dismiss()
                    }
                    .disabled(textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
