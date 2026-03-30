import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var deleteSettings = DeleteSettings.load()
    @State private var showLibraryFolderPicker = false
    
    var body: some View {
        NavigationView {
            Form {
                Section(Localized.appearance) {
                    Toggle(Localized.minimalistLibraryIcons, isOn: $deleteSettings.minimalistIcons)
                        .onChange(of: deleteSettings.minimalistIcons) { _, _ in
                            deleteSettings.save()
                        }
                    
                    Text(Localized.useSimpleIcons)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Toggle(Localized.forceDarkMode, isOn: $deleteSettings.forceDarkMode)
                        .onChange(of: deleteSettings.forceDarkMode) { _, _ in
                            deleteSettings.save()
                        }
                    
                    Text(Localized.overrideSystemAppearance)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    VStack(alignment: .leading, spacing: 12) {
                        Text(Localized.backgroundColor)
                            .font(.headline)
                        
                        LazyVGrid(columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible()),
                            GridItem(.flexible()),
                            GridItem(.flexible())
                        ], spacing: 16) {
                            ForEach(BackgroundColor.allCases, id: \.self) { color in
                                Button(action: {
                                    deleteSettings.backgroundColorChoice = color
                                    deleteSettings.save()
                                    NotificationCenter.default.post(name: NSNotification.Name("BackgroundColorChanged"), object: nil)
                                }) {
                                    ZStack {
                                        Circle()
                                            .fill(color.color)
                                            .frame(width: 44, height: 44)
                                            .overlay(
                                                Circle()
                                                    .stroke(deleteSettings.backgroundColorChoice == color ? Color.primary : Color.clear, lineWidth: 3)
                                            )
                                        
                                        if deleteSettings.backgroundColorChoice == color {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 16, weight: .bold))
                                                .foregroundColor(.white)
                                        }
                                    }
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                    }
                    
                    Text(Localized.chooseColorTheme)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                
                Section(Localized.audioSettings) {
                    NavigationLink(destination: EQSettingsView()) {
                        HStack {
                            Image(systemName: "slider.horizontal.3")
                                .foregroundColor(.blue)
                                .font(.system(size: 20))
                            Text(Localized.graphicEqualizer)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(Localized.dsdPlaybackMode)
                            .font(.headline)

                        Text(Localized.dsdPlaybackModeDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Picker("", selection: $deleteSettings.dsdPlaybackMode) {
                            ForEach(DSDPlaybackMode.allCases, id: \.self) { mode in
                                VStack(alignment: .leading) {
                                    Text(mode.displayName)
                                        .font(.body)
                                }
                                .tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: deleteSettings.dsdPlaybackMode) { _, _ in
                            deleteSettings.save()
                        }

                        Text(deleteSettings.dsdPlaybackMode.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 4)
                    }
                    .padding(.vertical, 4)
                }

                Section(Localized.librarySection) {
                    Toggle(Localized.removeFromLibraryOnly, isOn: $deleteSettings.deleteFromLibraryOnly)
                        .onChange(of: deleteSettings.deleteFromLibraryOnly) { _, _ in
                            deleteSettings.save()
                        }

                    Text(Localized.removeFromLibraryOnlyDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    Toggle(Localized.useCustomLibraryFolder, isOn: $deleteSettings.useCustomAppFolder)
                        .onChange(of: deleteSettings.useCustomAppFolder) { _, newValue in
                            if !newValue {
                                var s = deleteSettings
                                s.customAppFolderBookmarkData = nil
                                s.customAppFolderDisplayPath = nil
                                s.alsoScanSandboxDocuments = false
                                deleteSettings = s
                            }
                            deleteSettings.save()
                            StateManager.shared.invalidateCustomFolderAccess()
                            NotificationCenter.default.post(name: NSNotification.Name("LibraryNeedsRefresh"), object: nil)
                        }

                    if deleteSettings.useCustomAppFolder {
                        Button {
                            showLibraryFolderPicker = true
                        } label: {
                            HStack {
                                Text(Localized.chooseLibraryFolder)
                                Spacer()
                                Image(systemName: "folder")
                                    .foregroundColor(.secondary)
                            }
                        }

                        if let path = deleteSettings.customAppFolderDisplayPath, !path.isEmpty {
                            Text(path)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text(Localized.noLibraryFolderSelected)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Toggle(Localized.alsoScanAppDocuments, isOn: $deleteSettings.alsoScanSandboxDocuments)
                            .onChange(of: deleteSettings.alsoScanSandboxDocuments) { _, _ in
                                deleteSettings.save()
                                NotificationCenter.default.post(name: NSNotification.Name("LibraryNeedsRefresh"), object: nil)
                            }

                        Text(Localized.alsoScanAppDocumentsDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Button(Localized.resetDefaultLibraryFolder) {
                            var s = deleteSettings
                            s.useCustomAppFolder = false
                            s.customAppFolderBookmarkData = nil
                            s.customAppFolderDisplayPath = nil
                            s.alsoScanSandboxDocuments = false
                            deleteSettings = s
                            deleteSettings.save()
                            StateManager.shared.invalidateCustomFolderAccess()
                            NotificationCenter.default.post(name: NSNotification.Name("LibraryNeedsRefresh"), object: nil)
                        }
                        .foregroundColor(.red)
                    }

                    Text(Localized.libraryFolderFooter)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } header: {
                    Text(Localized.libraryAndDataFolder)
                }

                Section {
                    ForEach($deleteSettings.homeSections) { $section in
                        HStack {
                            Image(systemName: section.id.icon)
                                .foregroundColor(.secondary)
                                .frame(width: 24)

                            Toggle(section.id.displayName, isOn: $section.isVisible)
                                .onChange(of: section.isVisible) { _, _ in
                                    deleteSettings.save()
                                }
                        }
                    }
                    .onMove { source, destination in
                        deleteSettings.homeSections.move(fromOffsets: source, toOffset: destination)
                        deleteSettings.save()
                    }

                    Text(Localized.chooseVisibleSections)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } header: {
                    HStack {
                        Text(Localized.homeSections)
                        Spacer()
                        EditButton()
                            .font(.caption)
                    }
                }

                Section(Localized.information) {
                    HStack {
                        Text(Localized.version)
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text(Localized.appName)
                        Spacer()
                        Text(Localized.cosmosMusicPlayer)
                            .foregroundColor(.secondary)
                    }
                    
                    Button(action: {
                        print("🔗 GitHub repository button tapped")
                        if let url = URL(string: "https://github.com/clquwu/Cosmos-Music-Player") {
                            print("🔗 Opening URL: \(url)")
                            UIApplication.shared.open(url)
                        } else {
                            print("❌ Invalid GitHub URL")
                        }
                    }) {
                        HStack {
                            Text(Localized.githubRepository)
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundColor(.secondary)
                                .font(.system(size: 16))
                        }
                        .contentShape(Rectangle()) // Make entire area tappable
                    }
                    .buttonStyle(PlainButtonStyle()) // Remove default button styling that might interfere
                }
            }
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 100)
            }
            .navigationTitle(Localized.settings)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(Localized.done) {
                        dismiss()
                    }
                }
            }
            .fileImporter(
                isPresented: $showLibraryFolderPicker,
                allowedContentTypes: [UTType.folder],
                allowsMultipleSelection: false
            ) { result in
                Task { @MainActor in
                    switch result {
                    case .success(let urls):
                        guard let url = urls.first else { return }
                        let didAccess = url.startAccessingSecurityScopedResource()
                        defer {
                            if didAccess { url.stopAccessingSecurityScopedResource() }
                        }
                        do {
                            let data = try SecurityScopedFolderBookmark.bookmarkData(for: url)
                            var s = deleteSettings
                            s.customAppFolderBookmarkData = data
                            s.customAppFolderDisplayPath = url.path
                            s.useCustomAppFolder = true
                            deleteSettings = s
                            deleteSettings.save()
                            StateManager.shared.invalidateCustomFolderAccess()
                            NotificationCenter.default.post(name: NSNotification.Name("LibraryNeedsRefresh"), object: nil)
                        } catch {
                            print("⚠️ Failed to save library folder bookmark: \(error)")
                        }
                    case .failure(let error):
                        print("⚠️ Library folder picker failed: \(error)")
                    }
                }
            }
        }
    }
}

#Preview {
    SettingsView()
}
