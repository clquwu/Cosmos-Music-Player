import SwiftUI

struct InitializationView: View {
    @StateObject private var libraryIndexer = LibraryIndexer.shared
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var settings = DeleteSettings.load()
    
    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            
            VStack(spacing: 8) {
                Text(statusMessage)
                    .font(.headline)
                
                if libraryIndexer.isIndexing {
                    VStack(spacing: 8) {
                        Text(Localized.foundTracks(libraryIndexer.tracksFound))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        // Current file being processed
                        if !libraryIndexer.currentlyProcessing.isEmpty {
                            VStack(spacing: 4) {
                                Text(Localized.processingColon)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                Text(libraryIndexer.currentlyProcessing)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(settings.backgroundColorChoice.color)
                                    .lineLimit(1)
                                    .frame(maxWidth: 250)
                            }
                        }
                        
                        // Progress bar and percentage
                        HStack {
                            Text(Localized.percentComplete(Int(libraryIndexer.indexingProgress * 100)))
                                .font(.caption)
                                .foregroundColor(settings.backgroundColorChoice.color)
                                .frame(width: 35, alignment: .leading)
                            
                            ProgressView(value: libraryIndexer.indexingProgress)
                                .frame(maxWidth: 200)
                        }
                        
                        // Queued files
                        if !libraryIndexer.queuedFiles.isEmpty {
                            VStack(spacing: 2) {
                                Text(Localized.waitingColon)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                
                                ForEach(libraryIndexer.queuedFiles.prefix(3), id: \.self) { fileName in
                                    Text(fileName)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .frame(maxWidth: 250)
                                }
                                
                                if libraryIndexer.queuedFiles.count > 3 {
                                    Text(Localized.andMore(libraryIndexer.queuedFiles.count - 3))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(radius: 10)
    }
    
    private var statusMessage: String {
        switch appCoordinator.iCloudStatus {
        case .available:
            return "Setting up your iCloud music library..."
        case .offline:
            return "Setting up your offline music library..."
        default:
            return "Setting up your local music library..."
        }
    }
}

struct OfflineStatusView: View {
    @Environment(\.openURL) private var openURL
    @State private var isExpanded = false
    
    var body: some View {
        HStack {
            Image(systemName: "wifi.slash")
                .foregroundColor(.orange)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(Localized.offlineMode)
                    .font(.caption)
                    .fontWeight(.medium)
                
                if isExpanded {
                    Text(Localized.offlineModeMessage)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            Button(Localized.settings) {
                openSettings()
            }
            .font(.caption)
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        }
        .padding(.horizontal)
    }
    
    private func openSettings() {
        if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
            openURL(settingsURL)
        }
    }
}

struct ErrorView: View {
    let error: Error
    @Environment(\.openURL) private var openURL
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 60))
                .foregroundColor(.red)
            
            VStack(spacing: 12) {
                Text(Localized.icloudConnectionRequired)
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text(errorMessage)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            
            VStack(spacing: 12) {
                Button(Localized.openSettings) {
                    openSettings()
                }
                .buttonStyle(.borderedProminent)
                
                Button(Localized.retry) {
                    retryInitialization()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(radius: 10)
        .frame(maxWidth: 300)
    }
    
    private var errorMessage: String {
        if let appError = error as? AppCoordinatorError {
            return appError.localizedDescription
        }
        return error.localizedDescription
    }
    
    private func openSettings() {
        if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
            openURL(settingsURL)
        }
    }
    
    private func retryInitialization() {
        Task {
            await AppCoordinator.shared.initialize()
        }
    }
}