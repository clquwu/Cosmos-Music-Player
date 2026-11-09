import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appCoordinator: AppCoordinator
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
            .preferredColorScheme(settings.appearance.colorScheme)
            .accentColor(settings.backgroundColorChoice.color)
            .modifier(LifecycleModifier(
                appCoordinator: appCoordinator,
                libraryIndexer: libraryIndexer,
                refreshTimer: $refreshTimer,
                showTutorial: $showTutorial,
                libraryCount: tracks.count,
                onRefresh: refreshLibrary,
                onScanProgress: appendNewTracks
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
            // Not before the tutorial is done: a first launch has enough to read.
            .modifier(SupportPromptModifier(
                isReady: appCoordinator.isInitialized && !showTutorial && !TutorialViewModel.shouldShowTutorial()
            ))
    }

    private var mainContent: some View {
        RootTabView(
            tracks: tracks,
            showSettings: $showSettings,
            onRefresh: performRefresh,
            onManualSync: performManualSync
        )
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LibraryNeedsRefresh"))) { _ in
            Task {
                await refreshLibrary()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cosmosSettingsDidChange)) { _ in
            settings = DeleteSettings.load()
        }
    }

    @Sendable private func refreshLibrary() async {
        do {
            let allTracks = try await Task.detached(priority: .userInitiated) {
                try DatabaseManager.shared.getAllTracks()
            }.value

            // Deliberately unfiltered. TrackListView applies the CarPlay
            // format filter itself, and it observes the route; baking the
            // filter into this @State froze whatever the route happened to be
            // at the last library refresh.
            tracks = allTracks
        } catch {
            print("Failed to refresh library: \(error)")
        }
    }

    /// While a scan runs: adds the songs it has found since the last update
    /// instead of reading the whole library again. Re-reading 20,000 rows
    /// (90-180 ms) and handing every view a new copy of all of them, every
    /// 2 s for the length of a scan, had become the slowest part of it. The
    /// scan only adds rows as it goes; whatever it updates or removes is
    /// picked up by the full reload when it ends.
    @Sendable private func appendNewTracks() async {
        let newest = tracks.lazy.compactMap(\.id).max() ?? 0
        do {
            let added = try await Task.detached(priority: .utility) {
                try DatabaseManager.shared.getTracks(newerThan: newest)
            }.value
            guard !added.isEmpty else { return }
            // Something else may have reloaded meanwhile.
            let known = Set(tracks.lazy.compactMap(\.id))
            let fresh = added.filter { $0.id.map { !known.contains($0) } ?? false }
            guard !fresh.isEmpty else { return }
            tracks = fresh + tracks
        } catch {
            print("Failed to add newly found songs: \(error)")
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
    /// Songs in the library when a scan starts: sets how often it updates.
    let libraryCount: Int
    let onRefresh: @Sendable () async -> Void
    let onScanProgress: @Sendable () async -> Void
    @State private var hasPendingIndexRefresh = false

    /// How often a running scan shows the songs it has found: every 2 s for
    /// a small library, up to every 10 s from 10,000 songs. Each update hands
    /// every list a new copy of the library, and with a big one that work -
    /// not the new rows - is what the scan was waiting on.
    private var scanRefreshInterval: TimeInterval {
        min(10, max(2, Double(libraryCount) / 1000))
    }

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
                    refreshTimer = Timer.scheduledTimer(withTimeInterval: scanRefreshInterval, repeats: true) { _ in
                        Task { @MainActor in
                            guard hasPendingIndexRefresh,
                                  // Nobody sees the list in the background;
                                  // the reload at the end of the scan covers it.
                                  UIApplication.shared.applicationState != .background else { return }
                            hasPendingIndexRefresh = false
                            await onScanProgress()
                        }
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
                .onReceive(NotificationCenter.default.publisher(for: .cosmosSettingsDidChange)) { _ in
                    settings = DeleteSettings.load()
                }

    }
}

#Preview {
    ContentView()
        .environmentObject(AppCoordinator.shared)
}
