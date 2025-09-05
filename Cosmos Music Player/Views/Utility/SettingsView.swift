import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var deleteSettings = DeleteSettings.load()
    
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
                
                
                Section(Localized.information) {
                    HStack {
                        Text(Localized.version)
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text(Localized.appName)
                        Spacer()
                        Text(Localized.cosmosMusicPlayer)
                            .foregroundColor(.secondary)
                    }
                    
                    Button(action: {
                        if let url = URL(string: "https://github.com/clquwu/Cosmos-Music-Player") {
                            UIApplication.shared.open(url)
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
                    }
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
        }
    }
}

#Preview {
    SettingsView()
}