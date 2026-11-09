import SwiftUI
import GRDB
import UniformTypeIdentifiers
import Combine

// MARK: - Responsive Font Helper
extension View {
    func responsiveLibraryTitleFont() -> some View {
        self.font(.title)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .fontWeight(.bold)
    }

    func responsiveSectionTitleFont() -> some View {
        self.font(.title2)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .fontWeight(.semibold)
    }
}

/// The Library tab: the home screen the app has always opened on. The rows,
/// their order and which ones show are still the user's Home Screen setting;
/// what changed is the chrome around them (a system large title and toolbar
/// instead of a hand-built header) and a Recently Added shelf underneath.
struct LibraryView: View {
    let tracks: [Track]
    @Binding var showSettings: Bool
    let onRefresh: () async -> (before: Int, after: Int)
    let onManualSync: (() async -> (before: Int, after: Int))?
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @StateObject private var libraryIndexer = LibraryIndexer.shared
    @ObservedObject private var theme = ThemeStore.shared
    @ObservedObject private var router = AppRouter.shared
    @State private var settings = DeleteSettings.load()
    @State private var isRefreshing = false
    @State private var showSyncToast = false
    @State private var syncToastMessage = ""
    @State private var syncToastIcon = "checkmark.circle.fill"
    @State private var syncToastColor = Color.green
    @State private var newTracksFoundCount = 0
    @State private var syncCompleted = false
    @State private var showMusicPicker = false
    @State private var showFolderPicker = false
    @State private var folderOutcome: LinkedFolderImporter.Outcome?
    @State private var filter: LibraryFilter = .all
    @AppStorage("cosmos.library.gridLayout.v2") private var usesGridOnPhone = false
    /// iPad and the open Duo start with covers, several to a row: the user
    /// found the one-column list too small there. Remembered apart from the
    /// phone's choice, which stays a list by default.
    @AppStorage("cosmos.library.gridLayout.wide") private var usesGridWide = true
    @State private var gridWidth: CGFloat = 0
    /// Before release-year sorting there was only this switch; it still
    /// decides the order until the listener picks one in the new menu.
    @AppStorage("cosmos.library.sortAlphabetical") private var sortsAlphabetically = false
    @AppStorage("cosmos.library.sort") private var sortRaw = ""
    @State private var likedCount = 0
    @State private var playlistItems: [PlaylistEntry] = []
    @State private var albumItems: [AlbumEntry] = []
    @State private var artistItems: [ArtistEntry] = []
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    enum LibraryFilter: Hashable {
        case all, playlists, albums, artists
    }

    enum LibrarySort: String {
        case recents, nameAZ
        /// Albums only; playlists and artists keep the recent order.
        case releaseOldest, releaseNewest

        var isByRelease: Bool { self == .releaseOldest || self == .releaseNewest }
    }

    private var sort: LibrarySort {
        LibrarySort(rawValue: sortRaw) ?? (sortsAlphabetically ? .nameAZ : .recents)
    }

    /// Release year means something only where albums are listed.
    private var offersReleaseSort: Bool { filter == .all || filter == .albums }

    struct PlaylistEntry: Identifiable {
        let playlist: Playlist
        let tracks: [Track]
        var id: Int64 { playlist.id ?? -1 }
    }

    struct AlbumEntry: Identifiable {
        let album: Album
        let artworkTrack: Track?
        let artistName: String?
        /// The newest song's id: albums sort by when they arrived.
        let addedOrder: Int64
        var id: Int64 { album.id ?? -1 }
    }

    struct ArtistEntry: Identifiable {
        let artist: Artist
        let artworkTrack: Track?
        let songCount: Int
        var id: Int64 { artist.id ?? -1 }
    }

    // Helper function to show sync feedback
    private func showSyncFeedback(trackCountBefore: Int, trackCountAfter: Int) {
        let trackDifference = trackCountAfter - trackCountBefore

        // Set appropriate message and icon based on changes
        if trackDifference > 0 {
            // New tracks added
            syncToastIcon = "plus.circle.fill"
            syncToastColor = .green
            if trackDifference == 1 {
                syncToastMessage = NSLocalizedString("sync_one_new_track", value: "1 new song found", comment: "")
            } else {
                syncToastMessage = String(format: NSLocalizedString("sync_multiple_new_tracks", value: "%d new songs found", comment: ""), trackDifference)
            }
        } else if trackDifference < 0 {
            // Tracks removed
            let deletedCount = abs(trackDifference)
            syncToastIcon = "minus.circle.fill"
            syncToastColor = .orange
            if deletedCount == 1 {
                syncToastMessage = NSLocalizedString("sync_one_track_deleted", value: "1 song removed", comment: "")
            } else {
                syncToastMessage = String(format: NSLocalizedString("sync_multiple_tracks_deleted", value: "%d songs removed", comment: ""), deletedCount)
            }
        } else {
            // No changes - but check if we tracked any during sync
            if newTracksFoundCount > 0 {
                syncToastIcon = "plus.circle.fill"
                syncToastColor = .green
                if newTracksFoundCount == 1 {
                    syncToastMessage = NSLocalizedString("sync_one_new_track", value: "1 new song found", comment: "")
                } else {
                    syncToastMessage = String(format: NSLocalizedString("sync_multiple_new_tracks", value: "%d new songs found", comment: ""), newTracksFoundCount)
                }
            } else {
                syncToastIcon = "checkmark.circle.fill"
                syncToastColor = .blue
                syncToastMessage = NSLocalizedString("sync_no_changes", value: "Library is up to date", comment: "")
            }
        }

        presentToast()

        // Reset tracking variables
        newTracksFoundCount = 0
        syncCompleted = false
    }

    private func presentToast() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showSyncToast = true
        }
        // VoiceOver users would otherwise never learn the outcome.
        UIAccessibility.post(notification: .announcement, argument: syncToastMessage)

        // Auto-hide toast after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation(.easeInOut(duration: 0.3)) {
                showSyncToast = false
            }
        }
    }

    private func importMusicFiles(_ urls: [URL]) {
        Task {
            var addedCount = 0
            var skippedCount = 0

            for url in urls {
                // Reject network URLs
                if let scheme = url.scheme?.lowercased(), ["http", "https", "ftp", "sftp"].contains(scheme) {
                    print("❌ Rejected network URL: \(url.absoluteString)")
                    continue
                }

                // Start accessing security-scoped resource
                guard url.startAccessingSecurityScopedResource() else {
                    print("Failed to access security scoped resource for: \(url.lastPathComponent)")
                    continue
                }

                defer {
                    url.stopAccessingSecurityScopedResource()
                }

                do {
                    // Create bookmark data for persistent access
                    let bookmarkData = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)

                    // Store bookmark data for this file
                    await storeBookmarkData(bookmarkData, for: url)

                    // Process the file directly from its original location
                    let imported = await libraryIndexer.processExternalFile(url, allowExcludedReimport: true)
                    if imported {
                        addedCount += 1
                        print("✅ Imported and bookmarked file from original location: \(url.lastPathComponent)")
                    } else {
                        skippedCount += 1
                        print("⏭️ Skipped import (already exists/excluded/error): \(url.lastPathComponent)")
                    }

                } catch {
                    print("Failed to create bookmark for \(url.lastPathComponent): \(error)")

                    // Still try to process the file even if bookmark creation fails
                    let imported = await libraryIndexer.processExternalFile(url, allowExcludedReimport: true)
                    if imported {
                        addedCount += 1
                        print("✅ Imported file from original location (no bookmark): \(url.lastPathComponent)")
                    } else {
                        skippedCount += 1
                        print("⏭️ Skipped import (already exists/excluded/error): \(url.lastPathComponent)")
                    }
                }
            }

            // Show feedback
            await MainActor.run {
                if addedCount > 0 || skippedCount > 0 {
                    syncToastIcon = "plus.circle.fill"
                    syncToastColor = .green
                    if skippedCount == 0 {
                        syncToastMessage = Localized.importedSongCount(addedCount)
                    } else if addedCount == 0 {
                        syncToastIcon = "info.circle.fill"
                        syncToastColor = .blue
                        syncToastMessage = Localized.songsAlreadyInLibrary(skippedCount)
                    } else {
                        syncToastMessage = Localized.importSummary(imported: addedCount, skipped: skippedCount)
                    }

                    presentToast()
                }
            }

            // Trigger library refresh to update UI
            if addedCount > 0, let onManualSync = onManualSync {
                _ = await onManualSync()
            }
        }
    }

    /// Links a folder from Files. Success is a toast, like an import; a
    /// refusal or a no-op is an alert saying why.
    private func linkFolder(_ url: URL) {
        Task {
            let outcome = await LinkedFolderImporter.link(url)
            if case .added = outcome {
                syncToastIcon = "folder.fill.badge.plus"
                syncToastColor = .green
                syncToastMessage = outcome.message
                presentToast()
            } else {
                folderOutcome = outcome
            }
        }
    }

    private func storeBookmarkData(_ bookmarkData: Data, for url: URL) async {
        do {
            await DatabaseManager.shared.waitForExternalBookmarkMigration()
            let stableId = try libraryIndexer.generateStableId(for: url)
            try await ExternalBookmarkStore.shared.store(bookmarkData, for: stableId)

            print("Stored bookmark for external file: \(url.lastPathComponent) with stableId: \(stableId)")
        } catch {
            print("Failed to store bookmark data: \(error)")
        }
    }

    private func isVisible(_ section: HomeSectionId) -> Bool {
        settings.homeSections.contains { $0.id == section && $0.isVisible }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.Spacing.l) {
                if libraryIndexer.isIndexing && !libraryIndexer.currentlyProcessing.isEmpty {
                    processingBanner
                        .pagePadding()
                }

                if tracks.isEmpty {
                    // Nothing to filter yet: no picker, and the welcome in the
                    // middle of the page as on Home, rather than floating
                    // under an empty picker near the top.
                    emptyLibrary
                        .containerRelativeFrame(.vertical, alignment: .center)
                } else {
                    filterPicker
                        .pagePadding()

                    collection
                        .pagePadding()
                }
            }
            .padding(.top, Design.Spacing.xs)
            .padding(.bottom, Design.Spacing.xl)
        }
        .debugScrollToBottom()
        .background(ScreenSpecificBackgroundView(screen: .library))
        .cosmosTabHeader(Localized.libraryTab)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                viewMenu

                if onManualSync != nil {
                    Button {
                        startManualSync()
                    } label: {
                        if isRefreshing {
                            ProgressView()
                        } else {
                            Label(Localized.syncLibrary, systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(isRefreshing)
                }

                Menu {
                    addMenuItems
                } label: {
                    Label(Localized.addMusic, systemImage: "plus")
                }

                Button {
                    showSettings = true
                } label: {
                    Label(Localized.settings, systemImage: "gearshape")
                }
            }
            .cosmosPlainBackground()
        }
        .refreshable {
            // Prevent multiple concurrent refreshes
            guard !isRefreshing else { return }

            // Provide haptic feedback for pull-to-refresh
            let impactFeedback = UIImpactFeedbackGenerator(style: .light)
            impactFeedback.impactOccurred()

            // Wait for any ongoing indexing to complete before starting sync
            while libraryIndexer.isIndexing {
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            }

            // For pull-to-refresh, use manual sync if available, otherwise just refresh
            let result = if let onManualSync = onManualSync {
                await onManualSync() // Full sync + refresh
            } else {
                await onRefresh()    // Just refresh
            }

            // Show feedback after sync/refresh is complete
            await MainActor.run {
                showSyncFeedback(trackCountBefore: result.before, trackCountAfter: result.after)
            }
        }
        .overlay(alignment: .bottom) {
            if showSyncToast {
                syncToast
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showSyncToast)
        .animation(.snappy(duration: 0.3), value: filter)
        .animation(.snappy(duration: 0.3), value: usesGrid)
        .sheet(isPresented: $showMusicPicker) {
            MusicFilePicker { urls in
                importMusicFiles(urls)
            }
        }
        .sheet(isPresented: $showFolderPicker) {
            MusicFolderPicker { url in
                linkFolder(url)
            }
        }
        .linkedFolderAlert($folderOutcome)
        .onChange(of: router.importRequest) { _, _ in
            showMusicPicker = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .cosmosSettingsDidChange)) { _ in
            settings = DeleteSettings.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LibraryNeedsRefresh"))) { _ in
            loadLibrary()
        }
        .task(id: TrackSearchIndex.identity(for: tracks)) {
            loadLibrary()
        }
        .onChange(of: sortRaw) { _, _ in
            loadLibrary()
        }
    }

    // MARK: Pieces

    private var processingBanner: some View {
        HStack(spacing: Design.Spacing.s) {
            ProgressView()
                .controlSize(.small)

            Text("\(Localized.processing): \(libraryIndexer.currentlyProcessing)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Design.Spacing.m)
        .padding(.vertical, Design.Spacing.s)
        .background(theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: Design.Radius.thumbnail, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// What the library shows, as the system's segmented control.
    private var filterPicker: some View {
        Picker(Localized.libraryTab, selection: $filter) {
            Text(Localized.all).tag(LibraryFilter.all)
            if isVisible(.playlists) {
                Text(Localized.playlists).tag(LibraryFilter.playlists)
            }
            if isVisible(.albums) {
                Text(Localized.albums).tag(LibraryFilter.albums)
            }
            if isVisible(.artists) {
                Text(Localized.artists).tag(LibraryFilter.artists)
            }
        }
        .pickerStyle(.segmented)
        // The page's full width on iPad too, lined up with the rows under
        // it: capped at 520 points it sat as a small box against the left
        // edge.
        .sensoryFeedback(.selection, trigger: filter)
    }

    /// Sort, layout and sync, in one toolbar menu.
    private var viewMenu: some View {
        Menu {
            Picker(selection: Binding(
                get: { offersReleaseSort || !sort.isByRelease ? sort : .recents },
                set: { sortRaw = $0.rawValue }
            )) {
                Label(Localized.recents, systemImage: "clock").tag(LibrarySort.recents)
                Label(Localized.sortNameAZ, systemImage: "textformat").tag(LibrarySort.nameAZ)
                if offersReleaseSort {
                    Label(Localized.sortReleaseOldest, systemImage: "calendar").tag(LibrarySort.releaseOldest)
                    Label(Localized.sortReleaseNewest, systemImage: "calendar").tag(LibrarySort.releaseNewest)
                }
            } label: {
                Text(Localized.sortBy)
            }
            .pickerStyle(.inline)

            Picker(selection: Binding(
                get: { usesGrid },
                set: { if isRegular { usesGridWide = $0 } else { usesGridOnPhone = $0 } }
            )) {
                Label(Localized.listView, systemImage: "list.bullet").tag(false)
                Label(Localized.gridView, systemImage: "square.grid.2x2").tag(true)
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
        } label: {
            Label(Localized.sortBy, systemImage: "arrow.up.arrow.down")
        }
    }

    /// Add songs, a folder or an M3U playlist: the toolbar's "+" and, on
    /// the phone, the "Add Music" row at the top of the list.
    @ViewBuilder
    private var addMenuItems: some View {
        Button {
            showMusicPicker = true
        } label: {
            Label(Localized.addSongsFiles, systemImage: "music.note")
        }
        Button {
            showFolderPicker = true
        } label: {
            Label(Localized.addFolder, systemImage: "folder.badge.plus")
        }
        PlaylistImportMenuButton()
    }

    // MARK: Collection

    private enum Entry: Identifiable {
        /// The phone's "Add Music" row. The toolbar's "+" sits among four
        /// small icons there, and people did not find M3U import or
        /// folder linking behind it.
        case add
        case songs
        case liked
        case folders
        case playlist(PlaylistEntry)
        case album(AlbumEntry)
        case artist(ArtistEntry)

        var id: String {
            switch self {
            case .add: return "add"
            case .songs: return "songs"
            case .liked: return "liked"
            case .folders: return "folders"
            case .playlist(let item): return "p\(item.id)"
            case .album(let item): return "a\(item.id)"
            case .artist(let item): return "r\(item.id)"
            }
        }
    }

    /// What the current filter shows: everything you collected - Liked Songs
    /// pinned first, then playlists and albums - or one kind on its own.
    private var entries: [Entry] {
        let playlists = playlistItems.map(Entry.playlist)
        let albums = albumItems.map(Entry.album)
        let artists = artistItems.map(Entry.artist)
        // On the phone, first in "All" and "Playlists" - where new music and
        // imported playlists land.
        let add: [Entry] = !isRegular && (filter == .all || filter == .playlists) ? [.add] : []
        return add + filteredEntries(playlists: playlists, albums: albums, artists: artists)
    }

    private func filteredEntries(playlists: [Entry], albums: [Entry], artists: [Entry]) -> [Entry] {
        switch filter {
        case .all:
            return (isVisible(.allSongs) ? [.songs] : []) + (isVisible(.likedSongs) ? [.liked] : []) + [.folders] + playlists + albums
        case .playlists:
            return (isVisible(.likedSongs) ? [.liked] : []) + playlists
        case .albums:
            return albums
        case .artists:
            return artists
        }
    }

    private var emptyLibrary: some View {
        CosmosEmptyState(
            systemImage: "square.stack",
            title: Localized.noSongsFound,
            message: Localized.welcomeMessage,
            actionTitle: Localized.addSongs
        ) {
            showMusicPicker = true
        }
    }

    @ViewBuilder
    private var collection: some View {
        if usesGrid {
            let isLarge = usesLargeGridTiles
            TileGrid(minimum: isLarge ? 180 : 100, maximum: isLarge ? 260 : 240, spacing: isLarge ? Design.Spacing.l : Design.Spacing.m, rowSpacing: isLarge ? Design.Spacing.xl : Design.Spacing.l) {
                ForEach(entries) { entry in
                    gridCell(entry)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
        } else {
            // One column where the list is chosen, as on the phone (two
            // columns side by side were tried on iPad and turned down).
            LazyVStack(spacing: Design.Spacing.xs) {
                ForEach(entries) { entry in
                    listRow(entry)
                }
            }
        }
    }

    private var isRegular: Bool { horizontalSizeClass == .regular }

    private var usesGrid: Bool { isRegular ? usesGridWide : usesGridOnPhone }

    /// iPad's bigger tiles, where three of them fit across. A "regular"
    /// page can be phone-narrow - iPhone Duo's page on one half of the
    /// fold, 340 points - and there the bigger minimum left one tile per
    /// row, each as wide as the screen half.
    private var usesLargeGridTiles: Bool {
        isRegular && gridWidth >= 180 * 3 + Design.Spacing.l * 2
    }

    @ViewBuilder
    private func gridCell(_ entry: Entry) -> some View {
        switch entry {
        case .add:
            Menu {
                addMenuItems
            } label: {
                VStack(alignment: .leading, spacing: Design.Spacing.xs + 2) {
                    AddMusicCover()
                    tileText(Localized.addMusic, subtitle: Localized.libraryAddRowSubtitle)
                }
            }
            .buttonStyle(PressableButtonStyle())
        case .songs:
            NavigationLink(value: LibraryRoute.allSongs) {
                VStack(alignment: .leading, spacing: Design.Spacing.xs + 2) {
                    SongsCover()
                    tileText(Localized.songs, subtitle: Localized.songsCountOnly(tracks.count), pinned: true)
                }
            }
            .buttonStyle(PressableButtonStyle())
        case .liked:
            NavigationLink(value: LibraryRoute.likedSongs) {
                VStack(alignment: .leading, spacing: Design.Spacing.xs + 2) {
                    LikedSongsCover()
                        .overlay(alignment: .bottomTrailing) {
                            if isRegular {
                                TilePlayButton { QuickPlay.liked(from: tracks) }
                                    .padding(Design.Spacing.xs)
                            }
                        }
                    tileText(Localized.likedSongs, subtitle: Localized.songsCountOnly(likedCount), pinned: true)
                }
            }
            .buttonStyle(PressableButtonStyle())
        case .folders:
            NavigationLink(value: LibraryRoute.folders) {
                VStack(alignment: .leading, spacing: Design.Spacing.xs + 2) {
                    FoldersCover()
                    tileText(Localized.folders, subtitle: foldersSubtitle, pinned: true)
                }
            }
            .buttonStyle(PressableButtonStyle())
        case .playlist(let item):
            NavigationLink(value: LibraryRoute.playlist(id: item.id)) {
                VStack(alignment: .leading, spacing: Design.Spacing.xs + 2) {
                    PlaylistTileCover(playlist: item.playlist, tracks: item.tracks)
                        .overlay(alignment: .bottomTrailing) {
                            if isRegular && !item.tracks.isEmpty {
                                TilePlayButton { QuickPlay.playlist(item.id) }
                                    .padding(Design.Spacing.xs)
                            }
                        }
                    tileText(item.playlist.title, subtitle: isRegular ? "\(Localized.playlist) · \(Localized.songsCountOnly(item.tracks.count))" : Localized.playlist)
                }
            }
            .buttonStyle(PressableButtonStyle())
        case .album(let item):
            NavigationLink(value: LibraryRoute.album(id: item.id)) {
                AlbumTileView(album: item.album, artworkTrack: item.artworkTrack, subtitle: item.artistName, onPlay: isRegular ? { QuickPlay.album(item.id) } : nil)
            }
            .buttonStyle(PressableButtonStyle())
        case .artist(let item):
            NavigationLink(value: LibraryRoute.artist(id: item.artist.id, name: item.artist.name)) {
                VStack(spacing: Design.Spacing.s) {
                    ArtistAvatar(name: item.artist.name, artworkTrack: item.artworkTrack)
                        .aspectRatio(1, contentMode: .fit)
                    Text(item.artist.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(Localized.songsCountOnly(item.songCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            .buttonStyle(PressableButtonStyle())
        }
    }

    @ViewBuilder
    private func listRow(_ entry: Entry) -> some View {
        switch entry {
        case .add:
            Menu {
                addMenuItems
            } label: {
                CollectionRow(title: Localized.addMusic, subtitle: Localized.libraryAddRowSubtitle) {
                    AddMusicCover(cornerRadius: 6)
                }
            }
            .buttonStyle(PressableButtonStyle())
        case .songs:
            NavigationLink(value: LibraryRoute.allSongs) {
                CollectionRow(title: Localized.songs, subtitle: Localized.songsCountOnly(tracks.count), pinned: true) {
                    SongsCover(cornerRadius: 6)
                }
            }
            .buttonStyle(PressableButtonStyle())
        case .liked:
            NavigationLink(value: LibraryRoute.likedSongs) {
                CollectionRow(title: Localized.likedSongs, subtitle: "\(Localized.playlist) · \(Localized.songsCountOnly(likedCount))", pinned: true) {
                    LikedSongsCover(cornerRadius: 6)
                }
            }
            .buttonStyle(PressableButtonStyle())
        case .folders:
            NavigationLink(value: LibraryRoute.folders) {
                CollectionRow(title: Localized.folders, subtitle: foldersSubtitle, pinned: true) {
                    FoldersCover(cornerRadius: 6)
                }
            }
            .buttonStyle(PressableButtonStyle())
        case .playlist(let item):
            NavigationLink(value: LibraryRoute.playlist(id: item.id)) {
                CollectionRow(title: item.playlist.title, subtitle: "\(Localized.playlist) · \(Localized.songsCountOnly(item.tracks.count))") {
                    PlaylistTileCover(playlist: item.playlist, tracks: item.tracks, cornerRadius: 6)
                }
            }
            .buttonStyle(PressableButtonStyle())
        case .album(let item):
            NavigationLink(value: LibraryRoute.album(id: item.id)) {
                CollectionRow(title: item.album.title, subtitle: [Localized.album, item.artistName].compactMap { $0 }.joined(separator: " · ")) {
                    AlbumThumb(track: item.artworkTrack)
                }
            }
            .buttonStyle(PressableButtonStyle())
        case .artist(let item):
            NavigationLink(value: LibraryRoute.artist(id: item.artist.id, name: item.artist.name)) {
                CollectionRow(title: item.artist.name, subtitle: "\(Localized.artist) · \(Localized.songsCountOnly(item.songCount))") {
                    ArtistAvatar(name: item.artist.name, artworkTrack: item.artworkTrack)
                }
            }
            .buttonStyle(PressableButtonStyle())
        }
    }

    /// Where the songs come from: this device, then each linked folder.
    private var foldersSubtitle: String {
        ([Localized.onThisDevice] + LinkedFolderStore.shared.folders.map(\.name)).joined(separator: " · ")
    }

    private func tileText(_ title: String, subtitle: String, pinned: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                if pinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(theme.accent)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private func startManualSync() {
        guard !isRefreshing, let onManualSync else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        isRefreshing = true
        Task {
            while libraryIndexer.isIndexing {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            let result = await onManualSync()
            isRefreshing = false
            showSyncFeedback(trackCountBefore: result.before, trackCountAfter: result.after)
        }
    }

    private var syncToast: some View {
        HStack(spacing: Design.Spacing.s) {
            Image(systemName: syncToastIcon)
                .foregroundStyle(syncToastColor)
                .font(.body.weight(.medium))
            Text(syncToastMessage)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, Design.Spacing.l)
        .padding(.vertical, Design.Spacing.m)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
        .padding(.bottom, Design.Spacing.xl)
        .accessibilityElement(children: .combine)
    }

    // MARK: Data

    private func loadLibrary() {
        let signpost = Perf.begin("Library load")
        defer { Perf.end("Library load", signpost) }
        let database = appCoordinator.databaseManager
        likedCount = (try? appCoordinator.getFavorites().count) ?? 0

        // Per album: the newest song (when it arrived), a song with a cover
        // and the earliest year among its songs.
        var newest: [Int64: Int64] = [:]
        var trackYears: [Int64: Int] = [:]
        var artwork: [Int64: Track] = [:]
        var artistArtwork: [Int64: Track] = [:]
        var artistCounts: [Int64: Int] = [:]
        for track in tracks {
            if let albumId = track.albumId {
                newest[albumId] = max(newest[albumId] ?? 0, track.id ?? 0)
                if let year = track.year {
                    trackYears[albumId] = min(trackYears[albumId] ?? year, year)
                }
                if artwork[albumId] == nil || (!(artwork[albumId]?.hasArtwork ?? false) && track.hasArtwork) {
                    artwork[albumId] = track
                }
            }
            if let artistId = track.artistId {
                artistCounts[artistId, default: 0] += 1
                if artistArtwork[artistId] == nil, track.hasArtwork {
                    artistArtwork[artistId] = track
                }
            }
        }

        let names = (try? database.getAllArtistNamesById()) ?? [:]

        var albums = ((try? appCoordinator.getAllAlbums()) ?? []).compactMap { album -> AlbumEntry? in
            guard let id = album.id else { return nil }
            return AlbumEntry(
                album: album,
                artworkTrack: artwork[id],
                artistName: album.albumArtist ?? album.artistId.flatMap { names[$0] },
                addedOrder: newest[id] ?? 0
            )
        }
        let allPlaylists = (try? database.getAllPlaylists()) ?? []
        // Every playlist's songs from one query, not two per playlist.
        let tracksByPlaylist = (try? database.getTracksForPlaylists(allPlaylists.compactMap(\.id))) ?? [:]
        var playlists = allPlaylists.compactMap { playlist -> PlaylistEntry? in
            guard let id = playlist.id else { return nil }
            return PlaylistEntry(playlist: playlist, tracks: tracksByPlaylist[id] ?? [])
        }
        var artists = ((try? database.getBrowsableArtists(mode: settings.artistListMode)) ?? []).compactMap { artist -> ArtistEntry? in
            guard let id = artist.id else { return nil }
            return ArtistEntry(artist: artist, artworkTrack: artistArtwork[id], songCount: artistCounts[id] ?? 0)
        }

        switch sort {
        case .nameAZ:
            albums.sort { $0.album.title.localizedCaseInsensitiveCompare($1.album.title) == .orderedAscending }
            playlists.sort { $0.playlist.title.localizedCaseInsensitiveCompare($1.playlist.title) == .orderedAscending }
            artists.sort { $0.artist.name.localizedCaseInsensitiveCompare($1.artist.name) == .orderedAscending }
        case .recents, .releaseOldest, .releaseNewest:
            // Playlists already come most recently played first.
            albums.sort { $0.addedOrder > $1.addedOrder }
            artists.sort { $0.songCount > $1.songCount }
        }
        if sort.isByRelease {
            // The album's own year tag, else its songs' earliest: many files
            // carry the year per song only. Albums with no year go last; the
            // same year keeps the recent order above (a stable sort).
            func year(_ entry: AlbumEntry) -> Int? {
                if let year = entry.album.year, (1000...9999).contains(year) { return year }
                return trackYears[entry.id]
            }
            let newestFirst = sort == .releaseNewest
            albums = albums.enumerated().sorted { a, b in
                switch (year(a.element), year(b.element)) {
                case let (x?, y?) where x != y: return newestFirst ? x > y : x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.offset < b.offset
                }
            }.map(\.element)
        }

        albumItems = albums
        playlistItems = playlists
        artistItems = artists
    }

}

/// A row of the Library list: 64pt artwork, title, kind and count.
struct CollectionRow<Artwork: View>: View {
    let title: String
    let subtitle: String
    var pinned = false
    @ViewBuilder let artwork: () -> Artwork
    @ObservedObject private var theme = ThemeStore.shared

    var body: some View {
        HStack(spacing: Design.Spacing.m) {
            artwork()
                .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(theme.accent)
                            .accessibilityHidden(true)
                    }
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Design.Spacing.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// An album's cover for a list row.
struct AlbumThumb: View {
    let track: Track?
    @State private var image: UIImage?

    var body: some View {
        ArtworkView(image: image, cornerRadius: 6, placeholderSymbol: "opticaldisc")
            .task(id: track?.stableId) {
                guard let track else { return }
                image = await ArtworkManager.shared.getThumbnail(for: track)
            }
    }
}

/// Liked Songs' cover: a heart on a warm gradient, the way music apps mark
/// the one collection the app makes for you.
struct LikedSongsCover: View {
    var cornerRadius: CGFloat = Design.Radius.artwork

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.93, green: 0.25, blue: 0.40), Color(red: 0.55, green: 0.20, blue: 0.75)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                GeometryReader { geometry in
                    Image(systemName: "heart.fill")
                        .font(.system(size: geometry.size.width * 0.32, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .accessibilityHidden(true)
    }
}

/// The cover of the phone's "Add Music" row: a plus on a quiet tile, so it
/// reads as an action rather than one more collection.
struct AddMusicCover: View {
    var cornerRadius: CGFloat = Design.Radius.artwork
    @ObservedObject private var theme = ThemeStore.shared

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(theme.accent.opacity(0.14))
            .overlay {
                GeometryReader { geometry in
                    Image(systemName: "plus")
                        .font(.system(size: geometry.size.width * 0.36, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .accessibilityHidden(true)
    }
}

/// The cover of the Songs entry: the accent colour with a note.
struct SongsCover: View {
    var cornerRadius: CGFloat = Design.Radius.artwork
    @ObservedObject private var theme = ThemeStore.shared

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(LinearGradient(colors: [theme.accent, theme.accent.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                GeometryReader { geometry in
                    Image(systemName: "music.note")
                        .font(.system(size: geometry.size.width * 0.32, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .accessibilityHidden(true)
    }
}

/// The cover of the Folders entry: a folder on the accent colour.
struct FoldersCover: View {
    var cornerRadius: CGFloat = Design.Radius.artwork
    @ObservedObject private var theme = ThemeStore.shared

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(LinearGradient(colors: [theme.accent.opacity(0.75), Color(red: 0.12, green: 0.55, blue: 0.70)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                GeometryReader { geometry in
                    Image(systemName: "folder.fill")
                        .font(.system(size: geometry.size.width * 0.32, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .accessibilityHidden(true)
    }
}

/// A playlist's cover for the Library grid, loading its own artwork.
struct PlaylistTileCover: View {
    let playlist: Playlist
    let tracks: [Track]
    var cornerRadius: CGFloat = Design.Radius.artwork
    @State private var artworks: [UIImage] = []
    @State private var customCover: UIImage?

    var body: some View {
        PlaylistCoverView(customCover: customCover, artworks: artworks, trackCount: tracks.count)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .task(id: tracks.first?.stableId) {
                if let path = playlist.customCoverImagePath, !path.isEmpty,
                   let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.dev.clq.Cosmos-Music-Player"),
                   let data = try? Data(contentsOf: container.appendingPathComponent(path)) {
                    customCover = UIImage(data: data)
                }
                var loaded: [UIImage] = []
                for track in tracks.prefix(4) {
                    if let image = await ArtworkManager.shared.getThumbnail(for: track, maxPixelSize: 256) {
                        loaded.append(image)
                    }
                }
                artworks = loaded
            }
    }
}

/// One row of the Library list: accent icon, name, count, chevron.
struct LibrarySectionRow: View {
    let title: String
    let systemImage: String
    let count: Int?
    let tint: Color

    var body: some View {
        HStack(spacing: Design.Spacing.l) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 32)
                .accessibilityHidden(true)

            Text(title)
                .font(.title3)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: Design.Spacing.s)

            if let count {
                Text("\(count)")
                    .font(.body)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Design.Spacing.l)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct AllSongsScreen: View {
    let tracks: [Track]

    var body: some View {
        // Shuffle lives in TrackListView so that it shuffles the songs on
        // screen - with a search active, shuffling the whole library instead
        // would ignore what the user just narrowed down to.
        TrackListView(tracks: tracks, listIdentifier: "all_songs", showsShuffleButton: true)
            .background(ScreenSpecificBackgroundView(screen: .allSongs))
            .navigationTitle(Localized.allSongs)
            .navigationBarTitleDisplayMode(.large)
            // Puts Songs on Home's Start Listening, like an album or playlist.
            .onAppear { ListeningHistory.shared.recordSource(.allSongs) }
    }
}

struct LikedSongsScreen: View {
    let allTracks: [Track]
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var likedTracks: [Track] = []

    var body: some View {
        TrackListView(
            tracks: likedTracks,
            listIdentifier: "liked_songs",
            isLikedSongsScreen: true,
            showsShuffleButton: true
        )
            .background(ScreenSpecificBackgroundView(screen: .likedSongs))
            .navigationTitle(Localized.likedSongs)
            .navigationBarTitleDisplayMode(.large)
            .onAppear {
                loadLikedTracks()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LibraryNeedsRefresh"))) { _ in
                loadLikedTracks()
            }
    }

    private func loadLikedTracks() {
        let signpost = Perf.begin("Liked songs load")
        defer { Perf.end("Liked songs load", signpost) }
        do {
            // A set: `contains` on the array compared every song with every
            // favourite - 60 million string comparisons for 20,000 songs and
            // 3,000 likes, on the main thread, each time Liked Songs opened.
            let favoriteIds = Set(try appCoordinator.getFavorites())
            likedTracks = allTracks.filter { favoriteIds.contains($0.stableId) }
        } catch {
            print("Failed to load liked tracks: \(error)")
        }
    }
}

/// The last sorted song list and what it was sorted from.
///
/// `TrackListView` re-runs its body for things that do not change the order
/// - selecting a song, bulk mode, the "acted on" flash - and each pass sorted
/// the whole list again: tens of milliseconds for 20,000 songs by date, far
/// more by name (a lowercased copy of both titles per comparison). Comparing
/// the input is cheap when nothing changed: an untouched array compares by
/// its storage before any element. A class, so remembering a result inside
/// `body` is not a state change.
final class TrackSortCache {
    private var input: [Track] = []
    private var option: TrackSortOption?
    private var output: [Track] = []

    func sorted(_ tracks: [Track], by option: TrackSortOption, using sort: ([Track]) -> [Track]) -> [Track] {
        if option == self.option, tracks == input { return output }
        input = tracks
        self.option = option
        output = sort(tracks)
        return output
    }

    func invalidate() {
        option = nil
        input = []
        output = []
    }
}

enum TrackSortOption: String, CaseIterable {
    case playlistOrder
    case dateNewest
    case dateOldest
    case nameAZ
    case nameZA
    case artistAZ
    case artistZA
    case sizeLargest
    case sizeSmallest

    var localizedString: String {
        switch self {
        case .playlistOrder: return Localized.sortManualOrder
        case .dateNewest: return Localized.sortDateNewest
        case .dateOldest: return Localized.sortDateOldest
        case .nameAZ: return Localized.sortNameAZ
        case .nameZA: return Localized.sortNameZA
        case .artistAZ: return Localized.sortArtistAZ
        case .artistZA: return Localized.sortArtistZA
        case .sizeLargest: return Localized.sortSizeLargest
        case .sizeSmallest: return Localized.sortSizeSmallest
        }
    }
}

struct TrackListView: View {

    let tracks: [Track]
    let playlist: Playlist?
    let isEditMode: Bool
    let listIdentifier: String?
    let isLikedSongsScreen: Bool
    let showsShuffleButton: Bool

    @EnvironmentObject private var appCoordinator: AppCoordinator

    // Local State
    @State private var sortOption: TrackSortOption = .dateNewest
    @State private var recentlyActedTracks: Set<String> = []

    // Bulk selection state
    @State private var isBulkMode = false
    @State private var selectedTracks: Set<String> = []
    @State private var showBulkPlaylistDialog = false
    @State private var showBulkDeleteConfirmation = false
    @State private var settings = DeleteSettings.load()
    @StateObject private var search = LibrarySearchState()
    @State private var searchIndex = TrackSearchIndex()
    @State private var sortCache = TrackSortCache()

    init(tracks: [Track], playlist: Playlist? = nil, isEditMode: Bool = false, listIdentifier: String? = nil, isLikedSongsScreen: Bool = false, showsShuffleButton: Bool = false) {
        self.tracks = tracks
        self.playlist = playlist
        self.isEditMode = isEditMode
        self.listIdentifier = listIdentifier
        self.isLikedSongsScreen = isLikedSongsScreen
        self.showsShuffleButton = showsShuffleButton
    }

    // Subscribed, not merely read: the list has to be rebuilt when the route
    // changes. Reading the singleton without subscribing meant connecting could
    // leave incompatible formats on screen and disconnecting left Opus/DSD
    // missing until some other refresh happened to fire.
    //
    // Deliberately CarPlayRouteState and not SFBAudioEngineManager: that class
    // also publishes `currentTime` from a 0.1s timer, so observing it rebuilt
    // this whole list ten times a second for the duration of every
    // Opus/Vorbis/DSD track.
    @ObservedObject private var carPlayState = CarPlayRouteState.shared

    // Sorting logic stays here
    private var playableTracks: [Track] {
        guard carPlayState.isConnected else { return tracks }
        return tracks.filter { track in
            let ext = URL(fileURLWithPath: track.path).pathExtension.lowercased()
            return !["ogg", "oga", "opus", "dsf", "dff"].contains(ext)
        }
    }

    private var sortedTracks: [Track] {
        // Narrow before sorting - the artist sorts below build a cache over
        // whatever survives this, and there is no point resolving names for
        // rows the search has already excluded.
        Perf.measure("Song list filter+sort") {
            let filtered = searchIndex.filter(playableTracks, query: search.text)
            return sortCache.sorted(filtered, by: sortOption) { sorted($0) }
        }
    }

    /// The same list in the same order, with the search not applied.
    ///
    /// Only ever evaluated inside a tap handler (see `queueSource`), never in
    /// `body`: sorting the unnarrowed library on every pass would undo exactly
    /// the work the line above exists to save.
    private var fullSortedTracks: [Track] {
        sorted(playableTracks)
    }

    private func sorted(_ filteredTracks: [Track]) -> [Track] {
        switch sortOption {
        case .playlistOrder: return filteredTracks
        case .dateNewest: return filteredTracks.sorted { ($0.id ?? 0) > ($1.id ?? 0) }
        case .dateOldest: return filteredTracks.sorted { ($0.id ?? 0) < ($1.id ?? 0) }
        case .nameAZ: return filteredTracks.sorted { $0.title.lowercased() < $1.title.lowercased() }
        case .nameZA: return filteredTracks.sorted { $0.title.lowercased() > $1.title.lowercased() }
        case .artistAZ:
            // Pre-fetch all artist names for performance
            let artistCache = buildArtistCache(for: filteredTracks)
            return filteredTracks.sorted { track1, track2 in
                let artist1 = artistCache[track1.artistId ?? -1] ?? ""
                let artist2 = artistCache[track2.artistId ?? -1] ?? ""
                return artist1.lowercased() < artist2.lowercased()
            }
        case .artistZA:
            // Pre-fetch all artist names for performance
            let artistCache = buildArtistCache(for: filteredTracks)
            return filteredTracks.sorted { track1, track2 in
                let artist1 = artistCache[track1.artistId ?? -1] ?? ""
                let artist2 = artistCache[track2.artistId ?? -1] ?? ""
                return artist1.lowercased() > artist2.lowercased()
            }
        case .sizeLargest: return filteredTracks.sorted { ($0.fileSize ?? 0) > ($1.fileSize ?? 0) }
        case .sizeSmallest: return filteredTracks.sorted { ($0.fileSize ?? 0) < ($1.fileSize ?? 0) }
        }
    }

    private func buildArtistCache(for tracks: [Track]) -> [Int64: String] {
        // Get unique artist IDs
        let artistIds = Set(tracks.compactMap { $0.artistId })

        // Fetch all artists in one query
        var cache: [Int64: String] = [:]
        do {
            try DatabaseManager.shared.read { db in
                let artists = try Artist.filter(artistIds.contains(Column("id"))).fetchAll(db)
                for artist in artists {
                    if let id = artist.id {
                        cache[id] = artist.name
                    }
                }
            }
        } catch {
            print("Failed to build artist cache: \(error)")
        }
        return cache
    }

    // Bulk Helpers
    private func enterBulkMode(initialSelection: String? = nil) {
        isBulkMode = true
        if let trackId = initialSelection { selectedTracks.insert(trackId) }
    }

    private func exitBulkMode() {
        isBulkMode = false
        selectedTracks.removeAll()
    }

    private func selectAll() {
        selectedTracks = Set(sortedTracks.map { $0.stableId })
    }

    // Selections survive a change of query, so these resolve ids against the
    // full list. Looking them up in the filtered list silently dropped every
    // song that the current query happens to hide.
    private func bulkAddToLikedSongs() {
        for trackId in selectedTracks {
            if let track = tracks.first(where: { $0.stableId == trackId }) {
                try? appCoordinator.toggleFavorite(trackStableId: track.stableId)
            }
        }
        exitBulkMode()
    }

    private func bulkDelete() {
        Task {
            let deleteSettings = DeleteSettings.load()
            for trackId in selectedTracks {
                if let track = tracks.first(where: { $0.stableId == trackId }) {
                    if deleteSettings.deleteFromLibraryOnly {
                        DeleteSettings.addExcludedTrack(track.stableId, path: track.path, modificationDate: track.modificationDate)
                    } else {
                        try? FileManager.default.removeItem(at: URL(fileURLWithPath: track.path))
                    }
                    try? await DatabaseManager.shared.deleteTrack(byStableId: track.stableId)
                }
            }
            NotificationCenter.default.post(name: NSNotification.Name("LibraryNeedsRefresh"), object: nil)
            exitBulkMode()
        }
    }

    private var shuffleButton: some View {
        Button {
            shuffleVisibleTracks()
        } label: {
            Label(Localized.shuffle, systemImage: "shuffle")
        }
        .disabled(sortedTracks.isEmpty)
    }

    private var sortMenu: some View {
        Menu {
            Picker(selection: Binding(
                get: { sortOption },
                set: { option in
                    sortOption = option
                    saveSortPreference()
                }
            )) {
                ForEach(TrackSortOption.allCases, id: \.self) { option in
                    Text(option.localizedString).tag(option)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
        } label: {
            Label(Localized.sortBy, systemImage: "arrow.up.arrow.down")
        }
    }

    private func shuffleVisibleTracks() {
        let shuffled = sortedTracks.shuffled()
        guard let first = shuffled.first else { return }
        ListeningLog.shared.tagQueue("shuffle", tracks: shuffled)
        Task {
            await appCoordinator.playTrack(first, queue: shuffled)
        }
    }

    // Persistence
    private func loadSortPreference() {
        guard let identifier = listIdentifier else { return }
        if let savedRawValue = UserDefaults.standard.string(forKey: "sortPreference_\(identifier)"),
           let saved = TrackSortOption(rawValue: savedRawValue) {
            sortOption = saved
        }
    }

    private func saveSortPreference() {
        guard let identifier = listIdentifier else { return }
        UserDefaults.standard.set(sortOption.rawValue, forKey: "sortPreference_\(identifier)")
    }

    var body: some View {
        // We pass the sorted tracks and state bindings to the Inner View.
        // The Inner View observes PlayerEngine, so IT updates, but THIS view (and the Toolbar) remains stable.
        TrackListContentView(
            tracks: sortedTracks,
            fullTracks: { fullSortedTracks },
            playlist: playlist,
            isEditMode: isEditMode,
            isSearching: search.isSearching,
            isBulkMode: $isBulkMode,
            selectedTracks: $selectedTracks,
            recentlyActedTracks: $recentlyActedTracks,
            onEnterBulkMode: { id in enterBulkMode(initialSelection: id) }
        )
        // MARK: - TOOLBAR
        // Since PlayerEngine is not observed in this view, this Toolbar will not rebuild on every frame.
        .toolbar {
            if isBulkMode {
                // Plain, as in TrackBulkActionsModifier.
                ToolbarItem(placement: .topBarLeading) {
                    Button(Localized.cancel) { exitBulkMode() }
                }
                .cosmosPlainBackground()

                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(action: { selectAll() }) {
                            Label(Localized.selectAll, systemImage: "checkmark.circle")
                        }
                        Divider()
                        Button(action: { bulkAddToLikedSongs() }) {
                            Label(isLikedSongsScreen ? Localized.removeFromLiked : Localized.addToLiked, systemImage: "heart.fill")
                        }
                        .disabled(selectedTracks.isEmpty)

                        Button(action: { showBulkPlaylistDialog = true }) {
                            Label(Localized.addToPlaylist, systemImage: "music.note.list")
                        }
                        .disabled(selectedTracks.isEmpty)
                        Divider()
                        Button(role: .destructive, action: { showBulkDeleteConfirmation = true }) {
                            Label(Localized.deleteFiles, systemImage: "trash")
                        }
                        .disabled(selectedTracks.isEmpty)
                    } label: {
                        Label(Localized.moreOptions, systemImage: "ellipsis.circle")
                    }
                }
                .cosmosPlainBackground()
            } else {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    LibrarySearchButton(state: search)
                    if showsShuffleButton { shuffleButton }
                    sortMenu
                    // Long-pressing a song selects too, but few found it.
                    if !tracks.isEmpty {
                        Button { enterBulkMode() } label: {
                            Label(Localized.select, systemImage: "checkmark.circle")
                        }
                    }
                }
                .cosmosPlainBackground()
            }
        }
        .sheet(isPresented: $showBulkPlaylistDialog) {
            BulkPlaylistSelectionView(trackIds: Array(selectedTracks), onComplete: { exitBulkMode() })
                .accentColor(settings.backgroundColorChoice.color)
        }
        .alert(Localized.deleteFilesConfirmation, isPresented: $showBulkDeleteConfirmation) {
            Button(Localized.delete, role: .destructive) { bulkDelete() }
            Button(Localized.cancel, role: .cancel) { }
        } message: {
            Text(Localized.deleteFilesConfirmationMessage(selectedTracks.count))
        }
        .librarySearchField(search, prompt: Localized.searchSongs)
        .onAppear {
            loadSortPreference()
        }
        #if DEBUG
        // -cosmosDebugSelect 1 opens the list already selecting, for
        // screenshots.
        .task(id: tracks.isEmpty) {
            guard UserDefaults.standard.string(forKey: "cosmosDebugSelect") != nil,
                  let first = tracks.first else { return }
            enterBulkMode(initialSelection: first.stableId)
        }
        #endif
        // .task rather than onAppear + onChange: the rebuild is asynchronous
        // now, and this both starts it on the first appearance and restarts it
        // whenever the row set changes, cancelling the previous one.
        .task(id: TrackSearchIndex.identity(for: tracks)) {
            let rebuilt = await TrackSearchIndex.rebuilt(from: searchIndex, for: tracks)
            // The detached build does not inherit this task's cancellation, so
            // a superseded run still finishes - and could land after the run
            // that replaced it. Drop it rather than store an index for a row
            // set that is no longer on screen.
            guard !Task.isCancelled else { return }
            searchIndex = rebuilt
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LibraryNeedsRefresh"))) { _ in
            // Artist names may have changed under the same songs.
            sortCache.invalidate()
            Task {
                searchIndex = await TrackSearchIndex.rebuilt(
                    from: searchIndex,
                    for: tracks,
                    force: true
                )
            }
        }
    }
}

struct TrackListContentView: View {
    let tracks: [Track]
    /// The list without the search applied, evaluated only when a tap actually
    /// needs it.
    let fullTracks: () -> [Track]
    let playlist: Playlist?
    let isEditMode: Bool
    /// Tells "this list is empty" apart from "your search matched nothing",
    /// which need different empty states.
    let isSearching: Bool

    // Bindings to parent state
    @Binding var isBulkMode: Bool
    @Binding var selectedTracks: Set<String>
    @Binding var recentlyActedTracks: Set<String>
    let onEnterBulkMode: (String?) -> Void

    // Only THIS view updates when the song progresses
    @StateObject private var playerEngine = PlayerEngine.shared
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var settings = DeleteSettings.load()
    @State private var displayLimit = 50
    @State private var artistNameCache: [Int64: String] = [:]
    @State private var artistDisplayNameCache: [String: String] = [:]
    private let pageSize = 50
    private let largeQueueCap = 5000

    private var displayedTracks: [Track] {
        Array(tracks.prefix(displayLimit))
    }

    private var trackDisplaySignature: String {
        "\(tracks.count)-\(tracks.first?.stableId ?? "")-\(tracks.last?.stableId ?? "")"
    }

    /// Identity for `TrackRowView`'s Equatable check - see its
    /// `contextIdentity`. Must fold in everything a row's closures read that
    /// is not already compared field-by-field: the visible track set (which is
    /// also the playback queue built by `queueForPlayback`), whether a search
    /// is narrowing it, and the two modes that change what a tap does.
    ///
    /// Deliberately O(1). This is recomputed on every body pass, and this view
    /// observes PlayerEngine, so hashing the whole array here would undo the
    /// optimisation `.equatable()` exists to provide. Count plus the first and
    /// last id is the same trade `TrackListIdentity` documents.
    private var rowContextIdentity: String {
        "\(trackDisplaySignature)|\(isSearching)|\(isBulkMode)|\(isEditMode)"
    }

    private func toggleSelection(for track: Track) {
        if selectedTracks.contains(track.stableId) {
            selectedTracks.remove(track.stableId)
        } else {
            selectedTracks.insert(track.stableId)
        }
    }

    private func markAsActed(_ trackId: String) {
        recentlyActedTracks.insert(trackId)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            recentlyActedTracks.remove(trackId)
        }
    }

    private func queueForPlayback(startingAt selectedTrack: Track) -> [Track] {
        let source = LibrarySearch.queueSource(
            filtered: tracks,
            full: fullTracks(),
            isSearching: isSearching
        )

        guard source.count > largeQueueCap,
              let selectedIndex = source.firstIndex(where: { $0.stableId == selectedTrack.stableId }) else {
            return source
        }

        let endIndex = min(selectedIndex + largeQueueCap, source.count)
        return Array(source[selectedIndex..<endIndex])
    }

    /// Artist names for the rows shown so far and the next page;
    /// `extendArtistNames` keeps a page ahead as the list grows, so a row
    /// never appears with only its first artist. Resolving the whole list -
    /// 20,000 lookups on the main thread - ran on every appearance and on
    /// every keystroke of a search, for rows nobody had scrolled to.
    private func loadArtistNameCache() {
        let signpost = Perf.begin("Song list artist names")
        defer { Perf.end("Song list artist names", signpost) }
        do {
            artistNameCache = try DatabaseManager.shared.getAllArtistNamesById()
            artistDisplayNameCache = try artistDisplayNames(for: Array(tracks.prefix(displayLimit + pageSize)))
        } catch {
            print("Failed to load artist name cache: \(error)")
        }
    }

    private func extendArtistNames() {
        let missing = tracks.prefix(displayLimit + pageSize).filter { artistDisplayNameCache[$0.stableId] == nil }
        guard !missing.isEmpty, let names = try? artistDisplayNames(for: missing) else { return }
        artistDisplayNameCache.merge(names) { current, _ in current }
    }

    private func artistDisplayNames(for rows: [Track]) throws -> [String: String] {
        let fallbackArtistIds = rows.reduce(into: [String: Int64]()) { result, track in
            if let artistId = track.artistId {
                result[track.stableId] = artistId
            }
        }
        return try DatabaseManager.shared.getArtistDisplayNames(
            forTrackStableIds: rows.map(\.stableId),
            fallbackArtistIdsByStableId: fallbackArtistIds
        )
    }

    private func updateArtworkWindow() {
        let visibleWindowIds = Array(displayedTracks.suffix(120)).map { $0.stableId }
        let prefetchIds = Array(tracks.dropFirst(displayLimit).prefix(20)).map { $0.stableId }
        ArtworkManager.shared.updateVisibleArtworkWindow(
            visibleTrackIds: visibleWindowIds,
            prefetchTrackIds: prefetchIds
        )
    }

    private func trackRow(_ track: Track, isTile: Bool = false) -> TrackRowView {
        TrackRowView(
            track: track,
            activeTrackId: playerEngine.currentTrack?.stableId,
            isAudioPlaying: playerEngine.isPlaying,
            artistName: artistDisplayNameCache[track.stableId] ?? track.artistId.flatMap { artistNameCache[$0] },
            isTile: isTile,
            onTap: {
                if isBulkMode {
                    toggleSelection(for: track)
                } else {
                    dismissSearchKeyboard()
                    Task {
                        if let playlist = playlist, let playlistId = playlist.id {
                            try? appCoordinator.updatePlaylistAccessed(playlistId: playlistId)
                            try? appCoordinator.updatePlaylistLastPlayed(playlistId: playlistId)
                        }
                        await appCoordinator.playTrack(track, queue: queueForPlayback(startingAt: track))
                    }
                }
            },
            playlist: playlist,
            showDirectDeleteButton: playlist != nil && isEditMode,
            onEnterBulkMode: { onEnterBulkMode(track.stableId) },
            contextIdentity: rowContextIdentity
        )
    }

    private func loadNextPageIfNeeded() {
        guard displayLimit < tracks.count else { return }

        // Scroll geometry only reaches this point when the user is actually
        // near the bottom. Unlike a List row's onAppear, it is not fired by
        // UICollectionView prefetching every newly appended page.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            displayLimit = min(displayLimit + pageSize, tracks.count)
        }
    }

    var body: some View {
        if tracks.isEmpty {
            if isSearching {
                ContentUnavailableView.search
            } else {
                CosmosEmptyState(
                    systemImage: "music.note",
                    title: Localized.noSongsFound,
                    message: Localized.yourMusicWillAppearHere.namingThisDevice
                )
            }
        } else if usesGrid {
            // iPad: songs as a grid of covers, like albums, rather than one
            // long column stretched across the screen. Selecting songs and
            // editing a playlist keep the list, where the row controls are.
            paged(
                ScrollView {
                    TileGrid(minimum: 160, maximum: 220, spacing: Design.Spacing.l, rowSpacing: Design.Spacing.xl) {
                        ForEach(displayedTracks, id: \.stableId) { track in
                            trackRow(track, isTile: true)
                                .equatable()
                        }
                    }
                    // The same side margin as Albums and Playlists.
                    .pagePadding()
                    .padding(.vertical, Design.Spacing.m)
                }
            )
        } else {
            paged(List {
                ForEach(displayedTracks, id: \.stableId) { track in
                    HStack(spacing: 0) {
                        if isBulkMode {
                            TrackSelectionIndicator(
                                isSelected: selectedTracks.contains(track.stableId),
                                accentColor: settings.backgroundColorChoice.color,
                                onTap: { toggleSelection(for: track) }
                            )
                            .padding(.leading, Design.Spacing.s)
                        }

                        trackRow(track)
                        .equatable() // Crucial for performance
                        .onLongPressGesture(minimumDuration: 0.5) {
                            if !isBulkMode { onEnterBulkMode(track.stableId) }
                        }
                    }
                    .songListRow(
                        track,
                        separatorLeading: (isBulkMode ? Design.Size.minTouch + Design.Spacing.s : 0)
                            + Design.Spacing.l + Design.Size.rowArtwork + Design.Spacing.m,
                        swipeActionsEnabled: !isBulkMode
                    )
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden))
        }
    }

    private var usesGrid: Bool {
        horizontalSizeClass == .regular && playlist == nil && !isBulkMode && !isEditMode
    }

    /// Loads more songs near the bottom and keeps the artwork window current,
    /// for the list and the grid alike.
    private func paged<Content: View>(_ content: Content) -> some View {
        content
            .debugScrollToBottom()
            .onScrollGeometryChange(for: Bool.self) { geometry in
                guard displayLimit < tracks.count,
                      geometry.containerSize.height > 0,
                      geometry.contentSize.height > geometry.containerSize.height else {
                    return false
                }

                let visibleBottom = max(0, geometry.contentOffset.y) + geometry.containerSize.height
                return visibleBottom >= geometry.contentSize.height - 500
            } action: { wasNearBottom, isNearBottom in
                guard isNearBottom, !wasNearBottom else { return }
                loadNextPageIfNeeded()
            }
            .onAppear {
                displayLimit = min(pageSize, tracks.count)
                if artistNameCache.isEmpty {
                    loadArtistNameCache()
                }
                updateArtworkWindow()
            }
            .onChange(of: trackDisplaySignature) { _, _ in
                displayLimit = min(pageSize, tracks.count)
                loadArtistNameCache()
                updateArtworkWindow()
            }
            .onChange(of: displayLimit) { _, _ in
                extendArtistNames()
                updateArtworkWindow()
            }
    }
}

// MARK: - Bulk Selection Components

struct BulkPlaylistSelectionView: View {
    let trackIds: [String]
    let onComplete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var playlists: [Playlist] = []
    @State private var showCreatePlaylist = false
    @State private var newPlaylistName = ""
    @State private var settings = DeleteSettings.load()

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Text(Localized.addToPlaylist)
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text(Localized.songsCountOnly(trackIds.count))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                if playlists.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)

                        Text(Localized.noPlaylistsYet)
                            .font(.headline)

                        Text(Localized.createFirstPlaylist)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(playlists, id: \.id) { playlist in
                            Button(action: {
                                addToPlaylist(playlist)
                            }) {
                                HStack {
                                    Image(systemName: "music.note.list")
                                        .foregroundColor(settings.backgroundColorChoice.color)

                                    Text(playlist.title)
                                        .foregroundColor(.primary)

                                    Spacer()

                                    Image(systemName: "plus.circle")
                                        .foregroundColor(settings.backgroundColorChoice.color)
                                }
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }

                Button(Localized.createNewPlaylist) {
                    showCreatePlaylist = true
                }
                .buttonStyle(.borderedProminent)
                .padding()
            }
            .padding()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(Localized.cancel) {
                        dismiss()
                    }
                }
            }
        }
        .alert(Localized.createPlaylist, isPresented: $showCreatePlaylist) {
            TextField(Localized.playlistNamePlaceholder, text: $newPlaylistName)
            Button(Localized.create) {
                createPlaylist()
            }
            .disabled(newPlaylistName.isEmpty)
            Button(Localized.cancel, role: .cancel) { }
        } message: {
            Text(Localized.enterPlaylistName)
        }
        .onAppear {
            loadPlaylists()
        }
    }

    private func loadPlaylists() {
        do {
            playlists = try DatabaseManager.shared.getAllPlaylists()
        } catch {
            print("Failed to load playlists: \(error)")
        }
    }

    private func createPlaylist() {
        let title = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }

        do {
            // Same name as an existing playlist (any case): add to that one
            // rather than making a second of the same name.
            let playlist: Playlist
            if let existing = try DatabaseManager.shared.playlist(matchingTitle: title) {
                playlist = existing
            } else {
                playlist = try appCoordinator.createPlaylist(title: title)
                playlists.append(playlist)
            }
            newPlaylistName = ""

            // Automatically add the tracks to the new playlist
            if let playlistId = playlist.id {
                for trackId in trackIds {
                    try? appCoordinator.addToPlaylist(playlistId: playlistId, trackStableId: trackId)
                }
            }

            onComplete()
            dismiss()
        } catch {
            print("Failed to create playlist: \(error)")
        }
    }

    private func addToPlaylist(_ playlist: Playlist) {
        do {
            guard let playlistId = playlist.id else {
                print("Error: Playlist has no ID")
                return
            }

            for trackId in trackIds {
                try? appCoordinator.addToPlaylist(playlistId: playlistId, trackStableId: trackId)
            }

            onComplete()
            dismiss()
        } catch {
            print("Failed to add to playlist: \(error)")
        }
    }
}

// MARK: - Search View

/// The Search tab. Uses the system search field and scope bar, so it reads,
/// scales and speaks like search everywhere else in iOS, and opens results in
/// its own tab - it used to be a sheet that had to dismiss itself and then
/// push the result onto the Library screen behind it.
struct SearchView: View {
    let allTracks: [Track]
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var selectedCategory = SearchCategory.all
    @State private var debounceTask: Task<Void, Never>?
    @State private var searchTask: Task<Void, Never>?
    @State private var searchResults = SearchResults()
    @State private var isSearching = false
    @State private var artistNameCache: [Int64: String] = [:]
    @State private var artistDisplayNameCache: [String: String] = [:]
    /// A song with a cover per artist, for their circle - as the Artists
    /// screen does. Without it every artist result showed only an initial.
    @State private var artworkTrackByArtist: [Int64: Track] = [:]

    /// How many results of each kind the "All" scope shows before "See All".
    private let previewCount = 5

    enum SearchCategory: String, CaseIterable, Hashable {
        case all = "All"
        case songs = "Songs"
        case artists = "Artists"
        case albums = "Albums"
        case playlists = "Playlists"

        var localizedString: String {
            switch self {
            case .all: return Localized.all
            case .songs: return Localized.songs
            case .artists: return Localized.artists
            case .albums: return Localized.albums
            case .playlists: return Localized.playlists
            }
        }
    }

    struct SearchResults {
        let songs: [Track]
        let artists: [Artist]
        let albums: [Album]
        let playlists: [Playlist]

        init(songs: [Track] = [], artists: [Artist] = [], albums: [Album] = [], playlists: [Playlist] = []) {
            self.songs = songs
            self.artists = artists
            self.albums = albums
            self.playlists = playlists
        }

        var isEmpty: Bool {
            songs.isEmpty && artists.isEmpty && albums.isEmpty && playlists.isEmpty
        }
    }

    private func performSearch(query: String) {
        // Cancel any existing search task
        searchTask?.cancel()

        guard !query.isEmpty else {
            searchResults = SearchResults()
            isSearching = false
            return
        }

        isSearching = true

        searchTask = Task {
            // Normalize query for better matching
            let normalizedQuery = query
                .lowercased()
                .folding(options: .diacriticInsensitive, locale: .current)

            // Run database queries on background thread
            let results = await Task.detached(priority: .userInitiated) {
                let signpost = Perf.begin("Search query")
                defer { Perf.end("Search query", signpost) }
                var songs: [Track] = []
                var artists: [Artist] = []
                var albums: [Album] = []
                var playlists: [Playlist] = []

                do {
                    // Use optimized database-level search
                    songs = try DatabaseManager.shared.searchTracks(query: normalizedQuery, limit: 50)
                    artists = try DatabaseManager.shared.searchArtists(query: normalizedQuery, limit: 20)
                    albums = try DatabaseManager.shared.searchAlbums(query: normalizedQuery, limit: 30)
                    playlists = try DatabaseManager.shared.searchPlaylists(query: normalizedQuery, limit: 15)

                    // Also include songs and albums from matched artists
                    let matchedArtistIds = artists.compactMap { $0.id }
                    if !matchedArtistIds.isEmpty {
                        var existingSongIds = Set(songs.map { $0.stableId })
                        var existingAlbumIds = Set(albums.compactMap { $0.id })

                        for artistId in matchedArtistIds {
                            let artistTracks = try DatabaseManager.shared.getTracksByArtistId(artistId)
                            for track in artistTracks where !existingSongIds.contains(track.stableId) {
                                songs.append(track)
                                existingSongIds.insert(track.stableId)
                            }

                            let artistAlbums = try DatabaseManager.shared.getAlbumsByArtistId(artistId)
                            for album in artistAlbums {
                                guard let albumId = album.id, !existingAlbumIds.contains(albumId) else { continue }
                                albums.append(album)
                                existingAlbumIds.insert(albumId)
                            }
                        }
                    }
                } catch {
                    print("Search error: \(error)")
                }

                return SearchResults(
                    songs: songs,
                    artists: artists,
                    albums: albums,
                    playlists: playlists
                )
            }.value

            // Check if task was cancelled
            guard !Task.isCancelled else { return }

            // Update UI on main thread
            await MainActor.run {
                self.searchResults = results
                self.isSearching = false
                loadArtistCache(for: results.songs)
                let visibleIds = Array(results.songs.prefix(20)).map { $0.stableId }
                ArtworkManager.shared.updateVisibleArtworkWindow(visibleTrackIds: visibleIds)
            }
        }
    }

    @FocusState private var isFieldFocused: Bool
    @ObservedObject private var theme = ThemeStore.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// The last searches, newest first, newline-separated.
    @AppStorage("cosmos.recentSearches") private var recentSearchesStorage = ""
    @State private var browseArtwork: [BrowseCategory: Track] = [:]
    @State private var browseWidth: CGFloat = 0

    private var recentSearches: [String] {
        recentSearchesStorage.split(separator: "\n").map(String.init)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.Spacing.l) {
                searchField
                    .pagePadding()

                if debouncedSearchText.isEmpty {
                    if !recentSearches.isEmpty {
                        recentSearchesSection
                    }
                    browseSection
                } else {
                    scopeChips
                    results
                }
            }
            .frame(maxWidth: horizontalSizeClass == .regular ? 1100 : .infinity, alignment: .leading)
            .padding(.bottom, Design.Spacing.xl)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(ScreenSpecificBackgroundView(screen: .allSongs))
        .cosmosTabHeader(Localized.search)
        .onChange(of: searchText) { _, newValue in
            // Cancel any existing debounce task
            debounceTask?.cancel()

            // Create new debounce task
            debounceTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
                if !Task.isCancelled {
                    debouncedSearchText = newValue
                    performSearch(query: newValue)
                }
            }
        }
        // Search is a tab now and stays alive, so results have to follow the
        // library: a song deleted from a result row, or removed by a rescan,
        // must not stay playable here.
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LibraryNeedsRefresh"))) { _ in
            guard !debouncedSearchText.isEmpty else { return }
            performSearch(query: debouncedSearchText)
        }
        .task(id: allTracks.count) {
            loadBrowseArtwork()
            #if DEBUG
            // -cosmosDebugSearch <query> searches at launch, for screenshots.
            if let query = UserDefaults.standard.string(forKey: "cosmosDebugSearch"), !allTracks.isEmpty {
                searchText = query
            }
            #endif
        }
        .task(id: TrackSearchIndex.identity(for: allTracks)) {
            var index: [Int64: Track] = [:]
            for track in allTracks where track.hasArtwork {
                if let artistId = track.artistId, index[artistId] == nil {
                    index[artistId] = track
                }
            }
            artworkTrackByArtist = index
        }
    }

    // MARK: Field

    /// A large search field in the page itself - on iPad the system one sat
    /// as a small box in the corner of the toolbar.
    private var searchField: some View {
        HStack(spacing: Design.Spacing.s) {
            Image(systemName: "magnifyingglass")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(Localized.searchYourMusicLibrary, text: $searchText)
                .font(.body)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .focused($isFieldFocused)
                .onSubmit { remember(searchText) }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    debouncedSearchText = ""
                    searchResults = SearchResults()
                    // Clearing ends the search: the keyboard goes too,
                    // showing the browse page underneath in full.
                    isFieldFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: Design.Size.minTouch, height: Design.Size.minTouch)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Localized.clear)
            }
        }
        .padding(.leading, Design.Spacing.m)
        .frame(minHeight: 50)
        .background(SurfaceColor.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isFieldFocused ? theme.accent.opacity(0.7) : Color(.separator).opacity(0.5), lineWidth: isFieldFocused ? 1.5 : 0.5)
        )
        .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
        .animation(.easeOut(duration: 0.2), value: isFieldFocused)
        .contentShape(Rectangle())
        .onTapGesture { isFieldFocused = true }
    }

    private var scopeChips: some View {
        ShelfScrollView {
            HStack(spacing: Design.Spacing.s) {
                ForEach(SearchCategory.allCases, id: \.self) { category in
                    let isSelected = selectedCategory == category
                    Button {
                        withAnimation(.snappy(duration: 0.25)) { selectedCategory = category }
                    } label: {
                        Text(category.localizedString)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .padding(.horizontal, Design.Spacing.l)
                            .frame(minHeight: 36)
                            // Filled like the Play and Shuffle buttons: white
                            // chips vanished into the page in light mode.
                            .background(isSelected ? theme.accent : SurfaceColor.control, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color(.separator).opacity(isSelected ? 0 : 0.5), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                }
            }
            .pagePadding()
        }
        .clipsShelfSides()
    }

    // MARK: Before typing

    private var recentSearchesSection: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.s) {
            SectionTitle(title: Localized.recentSearches) {
                Button(Localized.clear) {
                    withAnimation { recentSearchesStorage = "" }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.accent)
            }
            .pagePadding()

            ShelfScrollView {
                HStack(spacing: Design.Spacing.s) {
                    ForEach(recentSearches, id: \.self) { query in
                        Button {
                            searchText = query
                        } label: {
                            Label(query, systemImage: "clock.arrow.circlepath")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, Design.Spacing.m)
                                .frame(minHeight: 36)
                                .background(SurfaceColor.control, in: Capsule())
                                .overlay(Capsule().strokeBorder(Color(.separator).opacity(0.5), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .pagePadding()
            }
            .clipsShelfSides()
        }
    }

    enum BrowseCategory: CaseIterable, Hashable {
        case songs, liked, albums, artists, playlists, recentlyAdded

        var title: String {
            switch self {
            case .songs: return Localized.allSongs
            case .liked: return Localized.likedSongs
            case .albums: return Localized.albums
            case .artists: return Localized.artists
            case .playlists: return Localized.playlists
            case .recentlyAdded: return Localized.recentlyAdded
            }
        }

        var color: Color {
            switch self {
            case .songs: return Color(red: 0.20, green: 0.42, blue: 0.85)
            case .liked: return Color(red: 0.86, green: 0.22, blue: 0.36)
            case .albums: return Color(red: 0.90, green: 0.50, blue: 0.12)
            case .artists: return Color(red: 0.52, green: 0.30, blue: 0.82)
            case .playlists: return Color(red: 0.12, green: 0.62, blue: 0.42)
            case .recentlyAdded: return Color(red: 0.14, green: 0.55, blue: 0.70)
            }
        }

        var route: LibraryRoute {
            switch self {
            case .songs, .recentlyAdded: return .allSongs
            case .liked: return .likedSongs
            case .albums: return .albums
            case .artists: return .artists
            case .playlists: return .playlists
            }
        }
    }

    private var isRegularWidth: Bool { horizontalSizeClass == .regular }

    /// iPad's bigger tiles, where two of them still fit side by side. A
    /// "regular" column can be phone-narrow - iPhone Duo's page on one half
    /// of the fold - and there the big tiles stacked one per row, three of
    /// them filling the screen.
    private var usesLargeBrowseTiles: Bool {
        isRegularWidth && browseWidth >= 240 * 2 + Design.Spacing.l * 3
    }

    /// Colourful tiles into the library, each with a tilted cover from it.
    private var browseSection: some View {
        let isLarge = usesLargeBrowseTiles
        return VStack(alignment: .leading, spacing: Design.Spacing.m) {
            SectionTitle(Localized.browse)
                .pagePadding()

            TileGrid(minimum: isLarge ? 240 : 160, spacing: isLarge ? Design.Spacing.l : Design.Spacing.m, rowSpacing: isLarge ? Design.Spacing.l : Design.Spacing.m) {
                ForEach(BrowseCategory.allCases, id: \.self) { category in
                    NavigationLink(value: category.route) {
                        BrowseTile(title: category.title, color: category.color, track: browseArtwork[category], isLarge: isLarge)
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }
            .pagePadding()
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { browseWidth = $0 }
    }

    private func loadBrowseArtwork() {
        let withArt = allTracks.filter(\.hasArtwork)
        guard !withArt.isEmpty else { return }
        let favorites = Set((try? appCoordinator.getFavorites()) ?? [])
        let newest = withArt.max { ($0.id ?? 0) < ($1.id ?? 0) }
        var picks: [BrowseCategory: Track] = [:]
        picks[.songs] = withArt.first
        picks[.liked] = withArt.first { favorites.contains($0.stableId) } ?? withArt.dropFirst().first
        picks[.albums] = withArt.dropFirst(2).first
        picks[.artists] = withArt.dropFirst(3).first
        picks[.playlists] = withArt.dropFirst(4).first
        picks[.recentlyAdded] = newest
        browseArtwork = picks
    }

    private func remember(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = recentSearches.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        list.insert(trimmed, at: 0)
        recentSearchesStorage = list.prefix(8).joined(separator: "\n")
    }

    // MARK: Results

    @ViewBuilder
    private var results: some View {
        if isSearching && searchResults.isEmpty {
            ProgressView(Localized.searching)
                .frame(maxWidth: .infinity)
                .padding(.top, Design.Spacing.xxl)
        } else if searchResults.isEmpty || !hasResults(in: selectedCategory) {
            ContentUnavailableView.search(text: debouncedSearchText)
                .padding(.top, Design.Spacing.xl)
        } else {
            resultsList
        }
    }

    private func hasResults(in category: SearchCategory) -> Bool {
        switch category {
        case .all: return !searchResults.isEmpty
        case .songs: return !searchResults.songs.isEmpty
        case .artists: return !searchResults.artists.isEmpty
        case .albums: return !searchResults.albums.isEmpty
        case .playlists: return !searchResults.playlists.isEmpty
        }
    }

    private func limited<T>(_ items: [T], for category: SearchCategory) -> [T] {
        selectedCategory == .all ? Array(items.prefix(previewCount)) : items
    }

    private func shows(_ category: SearchCategory) -> Bool {
        selectedCategory == .all || selectedCategory == category
    }

    private var resultsIdentity: String {
        "\(debouncedSearchText)|\(searchResults.songs.count)"
    }

    private var resultsList: some View {
        LazyVStack(alignment: .leading, spacing: Design.Spacing.xl) {
            if shows(.songs), !searchResults.songs.isEmpty {
                resultsGroup(Localized.songs, category: .songs, count: searchResults.songs.count) {
                    ForEach(limited(searchResults.songs, for: .songs), id: \.stableId) { track in
                        LiveTrackRow(
                            track: track,
                            artistName: artistDisplayNameCache[track.stableId] ?? track.artistId.flatMap { artistNameCache[$0] },
                            contextIdentity: resultsIdentity
                        ) {
                            remember(debouncedSearchText)
                            dismissSearchKeyboard()
                            Task {
                                // Only queue the selected song from search
                                await appCoordinator.playTrack(track, queue: [track])
                            }
                        }
                    }
                }
            }

            if shows(.artists), !searchResults.artists.isEmpty {
                resultsGroup(Localized.artists, category: .artists, count: searchResults.artists.count) {
                    ForEach(limited(searchResults.artists, for: .artists), id: \.id) { artist in
                        NavigationLink(value: LibraryRoute.artist(id: artist.id, name: artist.name)) {
                            ArtistRowView(name: artist.name, artworkTrack: artist.id.flatMap { artworkTrackByArtist[$0] }, photoLookupArtistId: artist.id)
                                .pagePadding()
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture().onEnded { remember(debouncedSearchText) })
                    }
                }
            }

            if shows(.albums), !searchResults.albums.isEmpty {
                resultsGroup(Localized.albums, category: .albums, count: searchResults.albums.count) {
                    ForEach(limited(searchResults.albums, for: .albums), id: \.id) { album in
                        if let albumId = album.id {
                            NavigationLink(value: LibraryRoute.album(id: albumId)) {
                                AlbumRowView(
                                    album: album,
                                    artistName: album.albumArtist ?? album.artistId.flatMap { artistNameCache[$0] }
                                )
                                .pagePadding()
                            }
                            .buttonStyle(.plain)
                            .simultaneousGesture(TapGesture().onEnded { remember(debouncedSearchText) })
                        }
                    }
                }
            }

            if shows(.playlists), !searchResults.playlists.isEmpty {
                resultsGroup(Localized.playlists, category: .playlists, count: searchResults.playlists.count) {
                    ForEach(limited(searchResults.playlists, for: .playlists), id: \.id) { playlist in
                        if let playlistId = playlist.id {
                            NavigationLink(value: LibraryRoute.playlist(id: playlistId)) {
                                PlaylistRowView(playlist: playlist)
                                    .pagePadding()
                            }
                            .buttonStyle(.plain)
                            .simultaneousGesture(TapGesture().onEnded { remember(debouncedSearchText) })
                        }
                    }
                }
            }
        }
    }

    private func resultsGroup<Content: View>(_ title: String, category: SearchCategory, count: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Design.Spacing.xs) {
            resultsHeader(title, category: category, count: count)
                .pagePadding()
            content()
        }
    }

    private func resultsHeader(_ title: String, category: SearchCategory, count: Int) -> some View {
        SectionTitle(title: title) {
            if selectedCategory == .all && count > previewCount {
                Button(Localized.seeAll) {
                    selectedCategory = category
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.top, Design.Spacing.s)
    }

    private func loadArtistCache(for songs: [Track]) {
        do {
            if artistNameCache.isEmpty {
                artistNameCache = try DatabaseManager.shared.getAllArtistNamesById()
            }
            let fallbackArtistIds = songs.reduce(into: [String: Int64]()) { result, track in
                if let artistId = track.artistId {
                    result[track.stableId] = artistId
                }
            }
            artistDisplayNameCache = try DatabaseManager.shared.getArtistDisplayNames(
                forTrackStableIds: songs.map(\.stableId),
                fallbackArtistIdsByStableId: fallbackArtistIds
            )
        } catch {
            print("Failed to load search artist cache: \(error)")
        }
    }
}

/// A Browse tile on the Search tab: a block of colour, its title, and one of
/// the library's covers tilted into the corner.
struct BrowseTile: View {
    let title: String
    let color: Color
    let track: Track?
    /// iPad: a taller tile with a bigger cover and title.
    var isLarge = false
    @State private var image: UIImage?

    private var coverSide: CGFloat { isLarge ? 112 : 72 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [color, color.opacity(0.78)], startPoint: .topLeading, endPoint: .bottomTrailing)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: coverSide, height: coverSide)
                    .clipShape(RoundedRectangle(cornerRadius: isLarge ? 8 : 6, style: .continuous))
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                    .rotationEffect(.degrees(22))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .offset(x: coverSide * 0.2, y: coverSide * 0.17)
                    .accessibilityHidden(true)
            }

            Text(title)
                .font((isLarge ? Font.title3 : Font.headline).weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                // The tile is a fixed height: large text shrinks a little
                // rather than cutting "Ajoutés récemment" to "récem…".
                .minimumScaleFactor(0.7)
                .padding(isLarge ? Design.Spacing.l : Design.Spacing.m)
                .padding(.trailing, coverSide * 0.66)
        }
        .frame(height: isLarge ? 150 : 104)
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius.artwork, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Design.Radius.artwork, style: .continuous))
        .accessibilityElement(children: .combine)
        .task(id: track?.stableId) {
            guard let track else { return }
            image = await ArtworkManager.shared.getThumbnail(for: track, maxPixelSize: 360)
        }
    }
}

// MARK: - Library item rows

/// A row for something that opens a page - an artist, album or playlist - in
/// a list. Same height and text styles as a song row.
struct LibraryItemRow<Artwork: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let artwork: () -> Artwork

    var body: some View {
        HStack(spacing: Design.Spacing.m) {
            artwork()
                .frame(width: Design.Size.rowArtwork, height: Design.Size.rowArtwork)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(minHeight: 72)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// An artist in a list. Local files carry no artist photo, so the avatar is
/// the artist's initial on the accent colour.
struct ArtistRowView: View {
    let name: String
    var subtitle: String? = nil
    var artworkTrack: Track? = nil
    /// Set to look the artist's photo up online when none is saved yet.
    var photoLookupArtistId: Int64? = nil

    var body: some View {
        LibraryItemRow(title: name, subtitle: subtitle) {
            ArtistAvatar(name: name, artworkTrack: artworkTrack, photoLookupArtistId: photoLookupArtistId)
        }
    }
}

/// An artist's circle: their photo once one is saved (from their page, or
/// looked up when `fetchesPhoto`), else the artwork of one of their songs,
/// else - while it loads, or when there is none - their initial.
struct ArtistAvatar: View {
    let name: String
    var artworkTrack: Track? = nil
    /// Set to look the artist's photo up online when none is saved yet.
    var photoLookupArtistId: Int64? = nil
    @ObservedObject private var theme = ThemeStore.shared
    @State private var artwork: UIImage?

    private var initial: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }

    var body: some View {
        Circle()
            .fill(theme.accent.opacity(0.18))
            .overlay {
                if let artwork {
                    Image(uiImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .transition(.opacity)
                } else {
                    // Scales with the circle, from a row to a grid portrait.
                    GeometryReader { geometry in
                        Text(initial)
                            .font(.system(size: max(14, geometry.size.width * 0.38), weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.accent)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .accessibilityHidden(true)
            .task(id: "\(name)|\(artworkTrack?.stableId ?? "")") {
                if let photo = await ArtistPhotoStore.shared.cachedPhoto(for: name) {
                    withAnimation(.easeOut(duration: 0.25)) { artwork = photo }
                    return
                }
                if let artworkTrack {
                    let image = await ArtworkManager.shared.getThumbnail(for: artworkTrack, maxPixelSize: 400)
                    withAnimation(.easeOut(duration: 0.25)) { artwork = image }
                }
                guard let artistId = photoLookupArtistId, !Task.isCancelled,
                      let photo = await ArtistPhotoStore.shared.photo(for: name, artistId: artistId) else { return }
                withAnimation(.easeOut(duration: 0.25)) { artwork = photo }
            }
    }
}

struct AlbumRowView: View {
    let album: Album
    let artistName: String?
    @State private var artworkImage: UIImage?
    @State private var trackCount: Int?

    var body: some View {
        LibraryItemRow(title: album.title, subtitle: subtitle) {
            ArtworkView(image: artworkImage, cornerRadius: Design.Radius.thumbnail, placeholderSymbol: "opticaldisc")
        }
        .task(id: album.id) {
            guard let albumId = album.id else { return }
            let tracks = (try? DatabaseManager.shared.getTracksByAlbumId(albumId)) ?? []
            trackCount = tracks.count
            if let first = tracks.first {
                artworkImage = await ArtworkManager.shared.getThumbnail(for: first)
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let artistName, !artistName.isEmpty { parts.append(artistName) }
        if let year = album.year, year > 0 { parts.append(String(year)) }
        if parts.isEmpty, let trackCount { parts.append(Localized.songsCountOnly(trackCount)) }
        return parts.joined(separator: " · ")
    }
}

struct PlaylistRowView: View {
    let playlist: Playlist
    @ObservedObject private var theme = ThemeStore.shared

    var body: some View {
        LibraryItemRow(title: playlist.title, subtitle: Localized.playlist) {
            RoundedRectangle(cornerRadius: Design.Radius.thumbnail, style: .continuous)
                .fill(theme.accent.opacity(0.16))
                .overlay {
                    Image(systemName: "music.note.list")
                        .font(.title2)
                        .foregroundStyle(theme.accent)
                }
                .accessibilityHidden(true)
        }
    }
}

struct MusicFilePicker: UIViewControllerRepresentable {
    let onFilesPicked: ([URL]) -> Void

    /// iOS declares no system UTI for Opus, OGG or DSD, so those files carry a
    /// dynamic type conforming to `public.data` and the picker greys them out
    /// under `UTType.audio` alone. The app's Info.plist now imports them
    /// (`UTImportedTypeDeclarations`) as conforming to `public.audio`; naming
    /// them here too keeps the picker working even where a provider hands back
    /// the dynamic type anyway.
    private static let audioContentTypes: [UTType] = {
        var types: [UTType] = [.audio, .mp3, .wav, .mpeg4Audio, .aiff]
        for identifier in [
            "org.xiph.flac", "org.xiph.opus", "org.xiph.ogg",
            "com.sony.dsf", "com.sony.dsdiff"
        ] {
            if let type = UTType(identifier) {
                types.append(type)
            }
        }
        return types
    }()

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: Self.audioContentTypes
        )

        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = true
        picker.modalPresentationStyle = .formSheet

        // Store reference to prevent premature deallocation
        context.coordinator.picker = picker

        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: UIDocumentPickerViewController, coordinator: Coordinator) {
        // Clean up to prevent DocumentManager crash
        uiViewController.delegate = nil
        coordinator.picker = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onFilesPicked: onFilesPicked)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFilesPicked: ([URL]) -> Void
        weak var picker: UIDocumentPickerViewController?

        init(onFilesPicked: @escaping ([URL]) -> Void) {
            self.onFilesPicked = onFilesPicked
            super.init()
        }

        deinit {
            // Ensure delegate is cleared on deallocation
            picker?.delegate = nil
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onFilesPicked(urls)
            // Clean up delegate to prevent DocumentManager issues
            controller.delegate = nil
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            // User cancelled, clean up delegate
            controller.delegate = nil
        }
    }
}
