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

                // Preset Selection
                Section(Localized.importedPresets) {
                    if !eqManager.availablePresets.isEmpty {
                        ForEach(eqManager.availablePresets) { preset in
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
                do {
                    let content = try String(contentsOf: url)
                    let finalPresetName = presetName.isEmpty ? url.deletingPathExtension().lastPathComponent : presetName

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
