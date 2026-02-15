import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @StateObject private var playerEngine = PlayerEngine.shared
    @StateObject private var libraryIndexer = LibraryIndexer.shared
    
    @State private var tracks: [Track] = []
    @State private var selectedTab = 0
    @State private var refreshTimer: Timer?
    @State private var showTutorial = false
    @State private var showPlaylistManagement = false
    @State private var showSettings = false
    @State private var settings = DeleteSettings.load()
    
    var body: some View {
        mainContent
            .background(.clear)
            .preferredColorScheme(settings.forceDarkMode ? .dark : nil)
            .accentColor(settings.backgroundColorChoice.color)
            .modifier(LifecycleModifier(
                appCoordinator: appCoordinator,
                libraryIndexer: libraryIndexer,
                refreshTimer: $refreshTimer,
                showTutorial: $showTutorial,
                onRefresh: refreshLibrary
            ))
            .modifier(OverlayModifier(
                appCoordinator: appCoordinator
            ))
            .modifier(SheetModifier(
                appCoordinator: appCoordinator,
                showTutorial: $showTutorial,
                showPlaylistManagement: $showPlaylistManagement,
                showSettings: $showSettings
            ))
    }
    
    private var mainContent: some View {
        LibraryView(
            tracks: tracks, 
            showTutorial: $showTutorial, 
            showPlaylistManagement: $showPlaylistManagement, 
            showSettings: $showSettings,
            onRefresh: performRefresh,
            onManualSync: performManualSync
        )
        .safeAreaInset(edge: .bottom) {
            MiniPlayerView()
                .background(.clear)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LibraryNeedsRefresh"))) { _ in
            Task {
                await refreshLibrary()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            settings = DeleteSettings.load()
        }
    }
    
    @Sendable private func refreshLibrary() async {
        do {
            let allTracks = try appCoordinator.getAllTracks()

            // Filter out incompatible formats when connected to CarPlay
            if SFBAudioEngineManager.shared.isCarPlayEnvironment {
                tracks = allTracks.filter { track in
                    let ext = URL(fileURLWithPath: track.path).pathExtension.lowercased()
                    let incompatibleFormats = ["ogg", "opus", "dsf", "dff"]
                    return !incompatibleFormats.contains(ext)
                }
                print("🚗 CarPlay: Filtered \(allTracks.count - tracks.count) incompatible tracks")
            } else {
                tracks = allTracks
            }
        } catch {
            print("Failed to refresh library: \(error)")
        }
    }
    
    @Sendable private func performManualSync() async -> (before: Int, after: Int) {
        let trackCountBefore = tracks.count
        await appCoordinator.manualSync()
        
        // Wait for indexer to finish processing if it's currently running
        while libraryIndexer.isIndexing {
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }
        
        await refreshLibrary()
        let trackCountAfter = tracks.count
        return (before: trackCountBefore, after: trackCountAfter)
    }
    
    @Sendable private func performRefresh() async -> (before: Int, after: Int) {
        let trackCountBefore = tracks.count
        
        // Wait for indexer to finish processing if it's currently running
        while libraryIndexer.isIndexing {
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }
        
        await refreshLibrary()
        let trackCountAfter = tracks.count
        return (before: trackCountBefore, after: trackCountAfter)
    }
    
}

struct LifecycleModifier: ViewModifier {
    let appCoordinator: AppCoordinator
    let libraryIndexer: LibraryIndexer
    @Binding var refreshTimer: Timer?
    @Binding var showTutorial: Bool
    let onRefresh: @Sendable () async -> Void
    @State private var hasPendingIndexRefresh = false
    
    func body(content: Content) -> some View {
        content
            .task {
                if appCoordinator.isInitialized {
                    await onRefresh()
                    if TutorialViewModel.shouldShowTutorial() {
                        showTutorial = true
                    }
                }
            }
            .onChange(of: appCoordinator.isInitialized) { _, isInitialized in
                if isInitialized {
                    Task {
                        await onRefresh()
                        if TutorialViewModel.shouldShowTutorial() {
                            showTutorial = true
                        }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TrackFound"))) { _ in
                if libraryIndexer.isIndexing {
                    hasPendingIndexRefresh = true
                } else {
                    Task { await onRefresh() }
                }
            }
            .onChange(of: libraryIndexer.isIndexing) { _, isIndexing in
                if isIndexing {
                    refreshTimer?.invalidate()
                    refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                        guard hasPendingIndexRefresh else { return }
                        hasPendingIndexRefresh = false
                        Task { await onRefresh() }
                    }
                } else {
                    refreshTimer?.invalidate()
                    refreshTimer = nil
                    hasPendingIndexRefresh = false
                    Task { await onRefresh() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                // Save player state when app goes to background
                appCoordinator.playerEngine.savePlayerState()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                // Save player state when app is terminated
                appCoordinator.playerEngine.savePlayerState()
            }
    }
}

struct OverlayModifier: ViewModifier {
    let appCoordinator: AppCoordinator
    
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if appCoordinator.isInitialized && appCoordinator.iCloudStatus == .offline {
                    OfflineStatusView()
                        .padding(.top)
                }
            }
    }
}

struct SheetModifier: ViewModifier {
    let appCoordinator: AppCoordinator
    @Binding var showTutorial: Bool
    @Binding var showPlaylistManagement: Bool
    @Binding var showSettings: Bool
    @State private var settings = DeleteSettings.load()
    
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showTutorial) {
                TutorialView(onComplete: {
                    showTutorial = false
                })
                .accentColor(settings.backgroundColorChoice.color)
            }
            .sheet(isPresented: $showPlaylistManagement) {
                PlaylistManagementView()
                    .accentColor(settings.backgroundColorChoice.color)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .accentColor(settings.backgroundColorChoice.color)
            }
            .alert(Localized.libraryOutOfSync, isPresented: .init(
                get: { appCoordinator.showSyncAlert },
                set: { appCoordinator.showSyncAlert = $0 }
            )) {
                Button(Localized.ok) {
                    appCoordinator.showSyncAlert = false
                }
                } message: {
                    Text(Localized.librarySyncMessage)
                }
                .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                    settings = DeleteSettings.load()
                }
        
    }
}

#Preview {
    ContentView()
        .environmentObject(AppCoordinator.shared)
}
