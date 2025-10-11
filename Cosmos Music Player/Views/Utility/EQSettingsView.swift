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

            // Manual 16-Band Presets
            Section(Localized.manualEQPresets) {
                if !eqManager.availablePresets.filter({ $0.presetType == .manual }).isEmpty {
                    ForEach(eqManager.availablePresets.filter { $0.presetType == .manual }) { preset in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name)
                                    .font(.headline)

                                Text(Localized.manual16BandEQ)
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

                Button(Localized.createManual16BandEQ) {
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
    @State private var createError: String?

    var body: some View {
        NavigationView {
            Form {
                Section(Localized.presetName) {
                    TextField(Localized.enterPresetName, text: $presetName)
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
                        Text(Localized.manual16BandDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text(Localized.adjustBandsAfterCreation)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle(Localized.createManual16BandEQ)
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
                let preset = try await eqManager.createManual16BandPreset(name: presetName)

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
    @State private var bandGains: [Double] = []
    @State private var isLoading = true

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
                        Text(preset.name)
                            .font(.headline)
                    }

                    Section(Localized.frequencyBands) {
                        ForEach(0..<min(bandGains.count, EQManager.manual16BandFrequencies.count), id: \.self) { index in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(formatFrequency(EQManager.manual16BandFrequencies[index]))
                                        .font(.subheadline)
                                        .foregroundColor(.primary)
                                        .frame(width: 80, alignment: .leading)

                                    Spacer()

                                    Text("\(bandGains[index], specifier: "%.1f")dB")
                                        .font(.subheadline.monospacedDigit())
                                        .foregroundColor(bandGains[index] > 0 ? .green : bandGains[index] < 0 ? .red : .secondary)
                                        .frame(width: 60, alignment: .trailing)
                                }

                                Slider(value: $bandGains[index], in: -12...12, step: 0.5)
                                    .tint(.blue)
                            }
                            .padding(.vertical, 4)
                        }
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
            }
        }
    }

    private func loadBands() {
        Task {
            do {
                let bands = try await eqManager.databaseManager.getBands(for: preset)
                let sortedBands = bands.sorted { $0.bandIndex < $1.bandIndex }

                await MainActor.run {
                    bandGains = sortedBands.map { $0.gain }

                    // Ensure we have exactly 16 bands
                    while bandGains.count < 16 {
                        bandGains.append(0.0)
                    }

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
                try await eqManager.updatePresetGains(
                    preset,
                    frequencies: EQManager.manual16BandFrequencies,
                    gains: bandGains
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
