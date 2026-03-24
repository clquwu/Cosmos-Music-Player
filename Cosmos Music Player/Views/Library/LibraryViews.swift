import SwiftUI
import GRDB
import UniformTypeIdentifiers
import Combine

// MARK: - Responsive Font Helper
extension View {
    func responsiveLibraryTitleFont() -> some View {
        self.font(.largeTitle)
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

struct LibraryView: View {
    let tracks: [Track]
    @Binding var showTutorial: Bool
    @Binding var showPlaylistManagement: Bool
    @Binding var showSettings: Bool
    let onRefresh: () async -> (before: Int, after: Int)
    let onManualSync: (() async -> (before: Int, after: Int))?
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @StateObject private var libraryIndexer = LibraryIndexer.shared
    @State private var artistToNavigate: Artist?
    @State private var artistAllTracks: [Track] = []
    @State private var albumToNavigate: Album?
    @State private var albumAllTracks: [Track] = []
    @State private var searchArtistToNavigate: Artist?
    @State private var searchArtistTracks: [Track] = []
    @State private var searchAlbumToNavigate: Album?
    @State private var searchAlbumTracks: [Track] = []
    @State private var searchPlaylistToNavigate: Playlist?
    @State private var playlistToNavigate: Playlist?
    @State private var showSearch = false
    @State private var settings = DeleteSettings.load()
    @State private var isRefreshing = false
    @State private var showSyncToast = false
    @State private var syncToastMessage = ""
    @State private var syncToastIcon = "checkmark.circle.fill"
    @State private var syncToastColor = Color.green
    @State private var newTracksFoundCount = 0
    @State private var syncCompleted = false
    @State private var showMusicPicker = false
    
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
        
        withAnimation(.easeInOut(duration: 0.2)) {
            showSyncToast = true
        }
        
        // Auto-hide toast after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation(.easeInOut(duration: 0.3)) {
                showSyncToast = false
            }
        }
        
        // Reset tracking variables
        newTracksFoundCount = 0
        syncCompleted = false
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
                        if addedCount == 1 {
                            syncToastMessage = "1 song imported"
                        } else {
                            syncToastMessage = "\(addedCount) songs imported"
                        }
                    } else if addedCount == 0 {
                        syncToastIcon = "info.circle.fill"
                        syncToastColor = .blue
                        syncToastMessage = "\(skippedCount) already in library"
                    } else {
                        syncToastMessage = "\(addedCount) imported, \(skippedCount) skipped"
                    }
                    
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showSyncToast = true
                    }
                    
                    // Auto-hide toast after 3 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            showSyncToast = false
                        }
                    }
                }
            }
            
            // Trigger library refresh to update UI
            if addedCount > 0, let onManualSync = onManualSync {
                _ = await onManualSync()
            }
        }
    }
    
    private func storeBookmarkData(_ bookmarkData: Data, for url: URL) async {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let bookmarksURL = documentsURL.appendingPathComponent("ExternalFileBookmarks.plist")
        
        do {
            // Load existing bookmarks or create new dictionary
            var bookmarks: [String: Data] = [:]
            if FileManager.default.fileExists(atPath: bookmarksURL.path) {
                if let data = try? Data(contentsOf: bookmarksURL),
                   let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Data] {
                    bookmarks = plist
                }
            }
            
            // Generate stableId for this file
            let stableId = try libraryIndexer.generateStableId(for: url)
            
            // Store bookmark using stableId as key (survives file moves)
            bookmarks[stableId] = bookmarkData
            
            // Save updated bookmarks
            let plistData = try PropertyListSerialization.data(fromPropertyList: bookmarks, format: .xml, options: 0)
            try plistData.write(to: bookmarksURL)
            
            print("Stored bookmark for external file: \(url.lastPathComponent) with stableId: \(stableId)")
        } catch {
            print("Failed to store bookmark data: \(error)")
        }
    }

    @ViewBuilder
    private func homeSectionView(for sectionId: HomeSectionId) -> some View {
        switch sectionId {
        case .allSongs:
            NavigationLink {
                AllSongsScreen(tracks: tracks)
            } label: {
                LibrarySectionRowView(
                    title: Localized.allSongs,
                    subtitle: Localized.songsCountOnly(tracks.count),
                    icon: "music.note",
                    color: settings.backgroundColorChoice.color
                )
            }
            .buttonStyle(PlainButtonStyle())

        case .likedSongs:
            NavigationLink {
                LikedSongsScreen(allTracks: tracks)
            } label: {
                LibrarySectionRowView(
                    title: Localized.likedSongs,
                    subtitle: Localized.yourFavorites,
                    icon: "heart.fill",
                    color: .red
                )
            }
            .buttonStyle(PlainButtonStyle())

        case .playlists:
            NavigationLink {
                PlaylistsScreen()
            } label: {
                LibrarySectionRowView(
                    title: Localized.playlists,
                    subtitle: Localized.yourPlaylists,
                    icon: "music.note.list",
                    color: .green
                )
            }
            .buttonStyle(PlainButtonStyle())

        case .artists:
            NavigationLink {
                ArtistsScreen(allTracks: tracks)
            } label: {
                LibrarySectionRowView(
                    title: Localized.artists,
                    subtitle: Localized.browseByArtist,
                    icon: "person.2.fill",
                    color: .purple
                )
            }
            .buttonStyle(PlainButtonStyle())

        case .albums:
            NavigationLink {
                AlbumsScreen(allTracks: tracks)
            } label: {
                LibrarySectionRowView(
                    title: Localized.albums,
                    subtitle: Localized.browseByAlbum,
                    icon: "opticaldisc.fill",
                    color: .orange
                )
            }
            .buttonStyle(PlainButtonStyle())

        case .addSongs:
            Button(action: {
                showMusicPicker = true
            }) {
                LibrarySectionRowView(
                    title: Localized.addSongs,
                    subtitle: Localized.importMusicFiles,
                    icon: "plus.circle.fill",
                    color: .blue
                )
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ScreenSpecificBackgroundView(screen: .library)
                
                VStack(spacing: 0) {
                    
                    // Compact processing status at the top of library
                    if libraryIndexer.isIndexing && !libraryIndexer.currentlyProcessing.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 12, height: 12)
                            
                            Text("\(Localized.processing): \(libraryIndexer.currentlyProcessing)")
                                .font(.caption2)
                                .foregroundColor(settings.backgroundColorChoice.color)
                                .lineLimit(1)
                            
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(settings.backgroundColorChoice.color.opacity(0.05))
                    }
                    
                    // Large section rows
                    ScrollView {
                        VStack(spacing: 16) {
                            // Library title with icons that scrolls with content
                            HStack(alignment: .center) {
                                Text(Localized.library)
                                    .responsiveLibraryTitleFont()
                                    .foregroundColor(.primary)
                                
                                Spacer()
                                
                                HStack(spacing: 20) {
                                    // Sync button (if available)
                                    if let onManualSync = onManualSync {
                                        Button(action: {
                                            guard !isRefreshing else { return }
                                            
                                            // Provide immediate haptic feedback
                                            let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
                                            impactFeedback.impactOccurred()
                                            
                                            withAnimation(.easeInOut(duration: 0.1)) {
                                                isRefreshing = true
                                            }
                                            
                                            Task {
                                                // Wait for any ongoing indexing to complete first
                                                while libraryIndexer.isIndexing {
                                                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                                                }
                                                
                                                let result = await onManualSync()
                                                
                                                await MainActor.run {
                                                    isRefreshing = false
                                                    showSyncFeedback(trackCountBefore: result.before, trackCountAfter: result.after)
                                                }
                                            }
                                        }) {
                                            ZStack {
                                                if isRefreshing {
                                                    ProgressView()
                                                        .scaleEffect(0.8)
                                                        .progressViewStyle(CircularProgressViewStyle(tint: settings.backgroundColorChoice.color))
                                                } else {
                                                    Image(systemName: "arrow.clockwise")
                                                        .font(.system(size: 26, weight: .medium))
                                                        .foregroundColor(settings.backgroundColorChoice.color)
                                                }
                                            }
                                            .padding(.bottom, 4)
                                            .scaleEffect(isRefreshing ? 0.9 : 1.0)
                                            .animation(.easeInOut(duration: 0.2), value: isRefreshing)
                                        }
                                        .disabled(isRefreshing)
                                    }
                                    
                                    // Search button (center)
                                    Button(action: {
                                        showSearch = true
                                    }) {
                                        Image(systemName: "magnifyingglass")
                                            .font(.system(size: 26, weight: .medium))
                                            .foregroundColor(settings.backgroundColorChoice.color)
                                    }
                                    
                                    // Settings button
                                    Button(action: {
                                        showSettings = true
                                    }) {
                                        Image(systemName: "gearshape")
                                            .font(.system(size: 26, weight: .medium))
                                            .foregroundColor(settings.backgroundColorChoice.color)
                                    }
                                }
                            }
                            .padding(.leading, 4)
                            .padding(.trailing, 4)
                            ForEach(settings.homeSections.filter(\.isVisible)) { section in
                                homeSectionView(for: section.id)
                            }
                        }
                        .padding(16)
                        .padding(.bottom, 100) // Add padding for mini player
                    }
                }
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.large)
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
                
                // Hidden NavigationLink for programmatic navigation from player
                NavigationLink(
                    destination: artistToNavigate.map { artist in
                        ArtistDetailScreenWrapper(artistName: artist.name, allTracks: artistAllTracks)
                    },
                    isActive: Binding(
                        get: { artistToNavigate != nil },
                        set: { if !$0 { artistToNavigate = nil } }
                    )
                ) {
                    EmptyView()
                }
                .hidden()
                
                // Hidden NavigationLink for album navigation from player
                NavigationLink(
                    destination: albumToNavigate.map { album in
                        AlbumDetailScreen(album: album, allTracks: albumAllTracks)
                    },
                    isActive: Binding(
                        get: { albumToNavigate != nil },
                        set: { if !$0 { albumToNavigate = nil } }
                    )
                ) {
                    EmptyView()
                }
                .hidden()
                
            }
            .navigationDestination(isPresented: Binding(
                get: { searchArtistToNavigate != nil },
                set: { if !$0 { searchArtistToNavigate = nil } }
            )) {
                if let artist = searchArtistToNavigate {
                    
                    ArtistDetailScreen(artist: artist, allTracks: searchArtistTracks)
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { searchAlbumToNavigate != nil },
                set: { if !$0 { searchAlbumToNavigate = nil } }
            )) {
                if let album = searchAlbumToNavigate {
                    AlbumDetailScreen(album: album, allTracks: searchAlbumTracks)
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { searchPlaylistToNavigate != nil },
                set: { if !$0 { searchPlaylistToNavigate = nil } }
            )) {
                if let playlist = searchPlaylistToNavigate {
                    PlaylistDetailScreen(playlist: playlist)
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { playlistToNavigate != nil },
                set: { if !$0 { playlistToNavigate = nil } }
            )) {
                if let playlist = playlistToNavigate {
                    PlaylistDetailScreen(playlist: playlist)
                }
            }
        }
        .background(.clear)
        .toolbarBackground(.clear, for: .navigationBar)
        .toolbarBackground(.clear, for: .automatic)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            settings = DeleteSettings.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NavigateToArtistFromPlayer"))) { notification in
            if let userInfo = notification.userInfo,
               let artist = userInfo["artist"] as? Artist,
               let allTracks = userInfo["allTracks"] as? [Track] {
                artistToNavigate = artist
                artistAllTracks = allTracks
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NavigateToAlbumFromPlayer"))) { notification in
            if let userInfo = notification.userInfo,
               let album = userInfo["album"] as? Album,
               let allTracks = userInfo["allTracks"] as? [Track] {
                albumToNavigate = album
                albumAllTracks = allTracks
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NavigateToPlaylist"))) { notification in
            if let userInfo = notification.userInfo,
               let playlistId = userInfo["playlistId"] as? Int64 {
                do {
                    let playlists = try appCoordinator.databaseManager.getAllPlaylists()
                    if let playlist = playlists.first(where: { $0.id == playlistId }) {
                        playlistToNavigate = playlist
                        print("✅ LibraryView: Navigating to playlist \(playlist.title)")
                    }
                } catch {
                    print("❌ LibraryView: Failed to find playlist: \(error)")
                }
            }
        }
        .overlay(
            // Sync result toast notification
            Group {
                if showSyncToast {
                    VStack {
                        Spacer()
                        HStack {
                            Image(systemName: syncToastIcon)
                                .foregroundColor(syncToastColor)
                                .font(.system(size: 16, weight: .medium))
                            Text(syncToastMessage)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.primary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(.regularMaterial)
                                .shadow(color: .black.opacity(0.2), radius: 12, x: 0, y: 6)
                        )
                        .padding(.horizontal, 20)
                        .padding(.bottom, 120) // Space above mini player
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
                .animation(.easeInOut(duration: 0.3), value: showSyncToast)
        )
        .sheet(isPresented: $showSearch) {
            SearchView(
                allTracks: tracks,
                onNavigateToArtist: { artist, tracks in
                    searchArtistToNavigate = artist
                    searchArtistTracks = tracks
                },
                onNavigateToAlbum: { album, tracks in
                    searchAlbumToNavigate = album
                    searchAlbumTracks = tracks
                },
                onNavigateToPlaylist: { playlist in
                    searchPlaylistToNavigate = playlist
                }
            )
            .accentColor(settings.backgroundColorChoice.color)
        }
        .sheet(isPresented: $showMusicPicker) {
            MusicFilePicker { urls in
                importMusicFiles(urls)
            }
        }
    }
}

struct LibrarySectionRowView: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    @State private var settings = DeleteSettings.load()
    
    var body: some View {
        HStack(spacing: 16) {
            // Icon
            if settings.minimalistIcons {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(.primary)
                    .frame(width: 60, height: 60)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(color.opacity(0.2))
                        .frame(width: 60, height: 60)
                    
                    Image(systemName: icon)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(color)
                }
            }
            
            // Text content
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .responsiveSectionTitleFont()
                    .foregroundColor(.primary)
                
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Chevron
            Image(systemName: "chevron.right")
                .font(.body)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(
            // Glassy background that reflects gradient
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .opacity(0.8)
        )
        .cornerRadius(12)
        .shadow(color: settings.backgroundColorChoice.color.opacity(0.15), radius: 4, x: 0, y: 2)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            settings = DeleteSettings.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("BackgroundColorChanged"))) { _ in
            settings = DeleteSettings.load()
        }
    }
}

struct AllSongsScreen: View {
    let tracks: [Track]
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var settings = DeleteSettings.load()
    
    var body: some View {
        TrackListView(tracks: tracks, listIdentifier: "all_songs")
            .background(ScreenSpecificBackgroundView(screen: .allSongs))
            .navigationTitle(Localized.allSongs)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        shuffleAllSongs()
                    } label: {
                        Image(systemName: "shuffle")
                            .foregroundColor(settings.backgroundColorChoice.color)
                    }
                    .disabled(tracks.isEmpty)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                settings = DeleteSettings.load()
            }
    }
    
    private func shuffleAllSongs() {
        guard !tracks.isEmpty else { return }
        let shuffled = tracks.shuffled()
        Task {
            await appCoordinator.playTrack(shuffled[0], queue: shuffled)
        }
    }
}

struct LikedSongsScreen: View {
    let allTracks: [Track]
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var likedTracks: [Track] = []
    @State private var settings = DeleteSettings.load()
    
    var body: some View {
        TrackListView(tracks: likedTracks, listIdentifier: "liked_songs", isLikedSongsScreen: true)
            .background(ScreenSpecificBackgroundView(screen: .likedSongs))
            .navigationTitle(Localized.likedSongs)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        shuffleLikedSongs()
                    } label: {
                        Image(systemName: "shuffle")
                            .foregroundColor(settings.backgroundColorChoice.color)
                    }
                    .disabled(likedTracks.isEmpty)
                }
            }
            .onAppear {
                loadLikedTracks()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LibraryNeedsRefresh"))) { _ in
                loadLikedTracks()
            }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                settings = DeleteSettings.load()
            }
    }
    
    private func shuffleLikedSongs() {
        guard !likedTracks.isEmpty else { return }
        let shuffled = likedTracks.shuffled()
        Task {
            await appCoordinator.playTrack(shuffled[0], queue: shuffled)
        }
    }
    
    private func loadLikedTracks() {
        do {
            let favoriteIds = try appCoordinator.getFavorites()
            likedTracks = allTracks.filter { favoriteIds.contains($0.stableId) }
        } catch {
            print("Failed to load liked tracks: \(error)")
        }
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
        case .playlistOrder: return "Manual Order"
        case .dateNewest: return Localized.sortDateNewest
        case .dateOldest: return Localized.sortDateOldest
        case .nameAZ: return Localized.sortNameAZ
        case .nameZA: return Localized.sortNameZA
        case .artistAZ: return "Artist A-Z"
        case .artistZA: return "Artist Z-A"
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
    
    init(tracks: [Track], playlist: Playlist? = nil, isEditMode: Bool = false, listIdentifier: String? = nil, isLikedSongsScreen: Bool = false) {
        self.tracks = tracks
        self.playlist = playlist
        self.isEditMode = isEditMode
        self.listIdentifier = listIdentifier
        self.isLikedSongsScreen = isLikedSongsScreen
    }
    
    // Sorting logic stays here
    private var sortedTracks: [Track] {
        let filteredTracks: [Track]
        if SFBAudioEngineManager.shared.isCarPlayEnvironment {
            filteredTracks = tracks.filter { track in
                let ext = URL(fileURLWithPath: track.path).pathExtension.lowercased()
                return !["ogg", "opus", "dsf", "dff"].contains(ext)
            }
        } else {
            filteredTracks = tracks
        }
        
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
    
    private func bulkAddToLikedSongs() {
        for trackId in selectedTracks {
            if let track = sortedTracks.first(where: { $0.stableId == trackId }) {
                try? appCoordinator.toggleFavorite(trackStableId: track.stableId)
            }
        }
        exitBulkMode()
    }
    
    private func bulkDelete() {
        Task {
            let deleteSettings = DeleteSettings.load()
            for trackId in selectedTracks {
                if let track = sortedTracks.first(where: { $0.stableId == trackId }) {
                    if deleteSettings.deleteFromLibraryOnly {
                        DeleteSettings.addExcludedTrack(track.stableId)
                    } else {
                        try? FileManager.default.removeItem(at: URL(fileURLWithPath: track.path))
                    }
                    try? DatabaseManager.shared.deleteTrack(byStableId: track.stableId)
                }
            }
            NotificationCenter.default.post(name: NSNotification.Name("LibraryNeedsRefresh"), object: nil)
            exitBulkMode()
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
            playlist: playlist,
            isEditMode: isEditMode,
            isBulkMode: $isBulkMode,
            selectedTracks: $selectedTracks,
            recentlyActedTracks: $recentlyActedTracks,
            onEnterBulkMode: { id in enterBulkMode(initialSelection: id) }
        )
        // MARK: - TOOLBAR
        // Since PlayerEngine is not observed in this view, this Toolbar will not rebuild on every frame.
        .toolbar {
            if isBulkMode {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(Localized.cancel) { exitBulkMode() }
                        .foregroundColor(settings.backgroundColorChoice.color)
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
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
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                            .foregroundColor(settings.backgroundColorChoice.color)
                        // Increase hit area
                            .padding(4)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                }
            } else {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        ForEach(TrackSortOption.allCases, id: \.self) { option in
                            Button(action: {
                                sortOption = option
                                saveSortPreference()
                            }) {
                                HStack {
                                    Text(option.localizedString)
                                    if sortOption == option { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down.circle")
                            .font(.title3)
                            .foregroundColor(settings.backgroundColorChoice.color)
                            .padding(4)
                            .contentShape(Rectangle())
                    }
                }
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
        .onAppear { loadSortPreference() }
    }
}

struct TrackListContentView: View {
    let tracks: [Track]
    let playlist: Playlist?
    let isEditMode: Bool
    
    // Bindings to parent state
    @Binding var isBulkMode: Bool
    @Binding var selectedTracks: Set<String>
    @Binding var recentlyActedTracks: Set<String>
    let onEnterBulkMode: (String?) -> Void
    
    // Only THIS view updates when the song progresses
    @StateObject private var playerEngine = PlayerEngine.shared
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var settings = DeleteSettings.load()
    @State private var displayLimit = 50
    @State private var artistNameCache: [Int64: String] = [:]
    private let pageSize = 50
    private let largeQueueCap = 5000

    private var displayedTracks: [Track] {
        Array(tracks.prefix(displayLimit))
    }

    private var trackDisplaySignature: String {
        "\(tracks.count)-\(tracks.first?.stableId ?? "")-\(tracks.last?.stableId ?? "")"
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
        guard tracks.count > largeQueueCap,
              let selectedIndex = tracks.firstIndex(where: { $0.stableId == selectedTrack.stableId }) else {
            return tracks
        }

        let endIndex = min(selectedIndex + largeQueueCap, tracks.count)
        return Array(tracks[selectedIndex..<endIndex])
    }

    private func loadArtistNameCache() {
        do {
            artistNameCache = try DatabaseManager.shared.getAllArtistNamesById()
        } catch {
            print("Failed to load artist name cache: \(error)")
        }
    }

    private func updateArtworkWindow() {
        let visibleWindowIds = Array(displayedTracks.suffix(120)).map { $0.stableId }
        let prefetchIds = Array(tracks.dropFirst(displayLimit).prefix(20)).map { $0.stableId }
        ArtworkManager.shared.updateVisibleArtworkWindow(
            visibleTrackIds: visibleWindowIds,
            prefetchTrackIds: prefetchIds
        )
    }
    
    var body: some View {
        if tracks.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "music.note").font(.system(size: 40)).foregroundColor(.secondary)
                Text(Localized.noSongsFound).font(.headline)
                Text(Localized.yourMusicWillAppearHere).font(.subheadline).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(displayedTracks, id: \.stableId) { track in
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        if isBulkMode {
                            Image(systemName: selectedTracks.contains(track.stableId) ? "checkmark.circle.fill" : "circle")
                                .font(.title2)
                                .foregroundColor(selectedTracks.contains(track.stableId) ? settings.backgroundColorChoice.color : .secondary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                                .onTapGesture { toggleSelection(for: track) }
                        }
                        
                        TrackRowView(
                            track: track,
                            activeTrackId: playerEngine.currentTrack?.stableId,
                            isAudioPlaying: playerEngine.isPlaying,
                            artistName: track.artistId.flatMap { artistNameCache[$0] },
                            onTap: {
                                if isBulkMode {
                                    toggleSelection(for: track)
                                } else {
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
                            onEnterBulkMode: { onEnterBulkMode(track.stableId) }
                        )
                        .equatable() // Crucial for performance
                        .onLongPressGesture(minimumDuration: 0.5) {
                            if !isBulkMode { onEnterBulkMode(track.stableId) }
                        }
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if !isBulkMode && !recentlyActedTracks.contains(track.stableId) {
                        Button {
                            playerEngine.insertNext(track)
                            markAsActed(track.stableId)
                        } label: { Label(Localized.playNext, systemImage: "text.line.first.and.arrowtriangle.forward") }
                            .tint(settings.backgroundColorChoice.color)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    if !isBulkMode && !recentlyActedTracks.contains(track.stableId) {
                        Button {
                            playerEngine.addToQueue(track)
                            markAsActed(track.stableId)
                        } label: { Label(Localized.addToQueue, systemImage: "text.append") }
                            .tint(.blue)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial).opacity(0.7))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .listRowSeparator(.hidden).listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
                if displayLimit < tracks.count {
                    Color.clear
                        .frame(height: 1)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .onAppear {
                            displayLimit = min(displayLimit + pageSize, tracks.count)
                        }
                }
            }
            .listStyle(PlainListStyle())
            .scrollContentBackground(.hidden)
            .contentMargins(.bottom, 100, for: .scrollContent)
            .onAppear {
                displayLimit = min(pageSize, tracks.count)
                if artistNameCache.isEmpty {
                    loadArtistNameCache()
                }
                updateArtworkWindow()
            }
            .onChange(of: trackDisplaySignature) { _, _ in
                displayLimit = min(pageSize, tracks.count)
                updateArtworkWindow()
            }
            .onChange(of: displayLimit) { _, _ in
                updateArtworkWindow()
            }
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
        NavigationView {
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
                ToolbarItem(placement: .navigationBarTrailing) {
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
        guard !newPlaylistName.isEmpty else { return }
        
        do {
            let playlist = try appCoordinator.createPlaylist(title: newPlaylistName)
            playlists.append(playlist)
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

struct SearchView: View {
    let allTracks: [Track]
    let onNavigateToArtist: (Artist, [Track]) -> Void
    let onNavigateToAlbum: (Album, [Track]) -> Void
    let onNavigateToPlaylist: (Playlist) -> Void
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var selectedCategory = SearchCategory.all
    @State private var settings = DeleteSettings.load()
    @FocusState private var isSearchFocused: Bool
    @State private var debounceTask: Task<Void, Never>?
    @State private var searchTask: Task<Void, Never>?
    @State private var searchResults = SearchResults()
    @State private var isSearching = false

    enum SearchCategory: String, CaseIterable {
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
                        let existingSongIds = Set(songs.map { $0.stableId })
                        let existingAlbumIds = Set(albums.compactMap { $0.id })

                        for artistId in matchedArtistIds {
                            let artistTracks = try DatabaseManager.shared.getTracksByArtistId(artistId)
                            for track in artistTracks where !existingSongIds.contains(track.stableId) {
                                songs.append(track)
                            }

                            let allAlbums = try DatabaseManager.shared.getAllAlbums()
                            for album in allAlbums where album.artistId == artistId && !existingAlbumIds.contains(album.id!) {
                                albums.append(album)
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
            }
        }
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                ScreenSpecificBackgroundView(screen: .library)
                
                VStack(spacing: 0) {
                    // Search bar
                    HStack {
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.secondary)
                            
                            TextField("Search your library", text: $searchText)
                                .textFieldStyle(PlainTextFieldStyle())
                                .autocorrectionDisabled()
                                .focused($isSearchFocused)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(.systemGray6))
                        .cornerRadius(10)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    
                    // Category filters
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(SearchCategory.allCases, id: \.self) { category in
                                Button(action: {
                                    selectedCategory = category
                                }) {
                                    Text(category.localizedString)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 8)
                                        .background(
                                            selectedCategory == category ?
                                            settings.backgroundColorChoice.color :
                                                Color(.systemGray6)
                                        )
                                        .foregroundColor(
                                            selectedCategory == category ?
                                                .white :
                                                    .primary
                                        )
                                        .cornerRadius(20)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.top, 12)
                    
                    // Results
                    if debouncedSearchText.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary)

                            Text(Localized.searchYourMusicLibrary)
                                .font(.headline)

                            Text(Localized.findSongsArtistsAlbumsPlaylists)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if isSearching {
                        VStack(spacing: 16) {
                            ProgressView()
                                .scaleEffect(1.2)
                                .progressViewStyle(CircularProgressViewStyle(tint: settings.backgroundColorChoice.color))

                            Text("Searching...")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        SearchResultsView(
                            results: searchResults,
                            selectedCategory: selectedCategory,
                            allTracks: allTracks,
                            onDismiss: { dismiss() },
                            onNavigateToArtist: onNavigateToArtist,
                            onNavigateToAlbum: onNavigateToAlbum,
                            onNavigateToPlaylist: onNavigateToPlaylist
                        )
                    }
                }
                .navigationTitle(Localized.search)
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarBackButtonHidden()
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(Localized.done) {
                            dismiss()
                        }
                        .foregroundColor(settings.backgroundColorChoice.color)
                    }
                }
            }
            .onChange(of: searchText) { newValue in
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
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                settings = DeleteSettings.load()
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isSearchFocused = true
                }
            }
            .onDisappear {
                debounceTask?.cancel()
                searchTask?.cancel()
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
    
    
    struct SearchResultsView: View {
        let results: SearchResults
        let selectedCategory: SearchView.SearchCategory
        let allTracks: [Track]
        let onDismiss: () -> Void
        let onNavigateToArtist: (Artist, [Track]) -> Void
        let onNavigateToAlbum: (Album, [Track]) -> Void
        let onNavigateToPlaylist: (Playlist) -> Void
        @State private var settings = DeleteSettings.load()
        @State private var artistNameCache: [Int64: String] = [:]

        private func loadArtistCache() {
            do {
                artistNameCache = try DatabaseManager.shared.getAllArtistNamesById()
            } catch {
                print("Failed to load search artist cache: \(error)")
            }
        }
        
        var body: some View {
            if results.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "magnifyingglass.circle")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    
                    Text(Localized.noResultsFound)
                        .font(.headline)
                    
                    Text(Localized.tryDifferentKeywords)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        // Songs
                        if selectedCategory == .all || selectedCategory == .songs, !results.songs.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(Localized.songs)
                                    .font(.title3)
                                    .fontWeight(.bold)
                                    .padding(.horizontal, 16)

                                ForEach(results.songs, id: \.stableId) { track in
                                    SearchSongRowView(
                                        track: track,
                                        allTracks: allTracks,
                                        artistName: track.artistId.flatMap { artistNameCache[$0] },
                                        onDismiss: onDismiss
                                    )
                                    .shadow(color: settings.backgroundColorChoice.color.opacity(0.15), radius: 4, x: 0, y: 2)
                                    .padding(.horizontal, 16)
                                }
                            }
                        }

                        // Albums (also shown when Artists category is selected, grouped by artist)
                        if selectedCategory == .all || selectedCategory == .albums, !results.albums.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(Localized.albums)
                                    .font(.title3)
                                    .fontWeight(.bold)
                                    .padding(.horizontal, 16)

                                ForEach(results.albums, id: \.id) { album in
                                    SearchAlbumRowView(
                                        album: album,
                                        albumArtistName: album.artistId.flatMap { artistNameCache[$0] },
                                        onDismiss: onDismiss,
                                        onNavigate: onNavigateToAlbum
                                    )
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(.ultraThinMaterial)
                                            .opacity(0.7)
                                    )
                                    .shadow(color: settings.backgroundColorChoice.color.opacity(0.15), radius: 4, x: 0, y: 2)
                                    .padding(.horizontal, 16)
                                }
                            }
                        }

                        // Artists - show artist row + their albums underneath
                        if selectedCategory == .all || selectedCategory == .artists, !results.artists.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(Localized.artists)
                                    .font(.title3)
                                    .fontWeight(.bold)
                                    .padding(.horizontal, 16)

                                ForEach(results.artists, id: \.id) { artist in
                                    VStack(alignment: .leading, spacing: 0) {
                                        SearchArtistRowView(
                                            artist: artist,
                                            onDismiss: onDismiss,
                                            onNavigate: onNavigateToArtist
                                        )
                                        .background(
                                            RoundedRectangle(cornerRadius: 12)
                                                .fill(.ultraThinMaterial)
                                                .opacity(0.7)
                                        )
                                        .shadow(color: settings.backgroundColorChoice.color.opacity(0.15), radius: 4, x: 0, y: 2)
                                        .padding(.horizontal, 16)

                                        // Show this artist's albums below
                                        SearchArtistAlbumsRow(
                                            artist: artist,
                                            onDismiss: onDismiss,
                                            onNavigateToAlbum: onNavigateToAlbum
                                        )
                                    }
                                    .padding(.bottom, 4)
                                }
                            }
                        }

                        // Playlists
                        if selectedCategory == .all || selectedCategory == .playlists, !results.playlists.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(Localized.playlists)
                                    .font(.title3)
                                    .fontWeight(.bold)
                                    .padding(.horizontal, 16)

                                ForEach(results.playlists, id: \.id) { playlist in
                                    SearchPlaylistRowView(
                                        playlist: playlist,
                                        onDismiss: onDismiss,
                                        onNavigate: onNavigateToPlaylist
                                    )
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(.ultraThinMaterial)
                                            .opacity(0.7)
                                    )
                                    .shadow(color: settings.backgroundColorChoice.color.opacity(0.15), radius: 4, x: 0, y: 2)
                                    .padding(.horizontal, 16)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 16)
                }
                .safeAreaInset(edge: .bottom) {
                    Color.clear.frame(height: 100) // Space for mini player
                }
                .onAppear {
                    if artistNameCache.isEmpty {
                        loadArtistCache()
                    }
                    let visibleIds = Array(results.songs.prefix(20)).map { $0.stableId }
                    ArtworkManager.shared.updateVisibleArtworkWindow(visibleTrackIds: visibleIds)
                }
            }
        }
    }
    
    struct SearchSongRowView: View {
        let track: Track
        let allTracks: [Track]
        let artistName: String?
        let onDismiss: () -> Void
        @EnvironmentObject private var appCoordinator: AppCoordinator
        @StateObject private var playerEngine = PlayerEngine.shared
        @State private var settings = DeleteSettings.load()
        @State private var artworkImage: UIImage?
        @State private var swipeOffset: CGFloat = 0
        @State private var swipeAction: SwipeAction = .none
        @State private var isFavorite = false
        @State private var showPlaylistDialog = false
        @State private var showDeleteConfirmation = false
        private let swipeThreshold: CGFloat = 80

        private enum SwipeAction {
            case none, playNext, addToQueue
        }

        private var isCurrentlyPlaying: Bool {
            playerEngine.currentTrack?.stableId == track.stableId
        }

        var body: some View {
            ZStack {
                // Swipe bubble icons
                HStack {
                    // Left side - Play Next bubble (appears on right swipe)
                    if swipeOffset > 0 {
                        Image(systemName: "text.line.first.and.arrowtriangle.forward")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(settings.backgroundColorChoice.color)
                            .clipShape(Circle())
                            .opacity(min(Double(swipeOffset) / swipeThreshold, 1.0))
                            .scaleEffect(min(Double(swipeOffset) / swipeThreshold, 1.0))
                            .padding(.leading, 8)
                    }

                    Spacer()

                    // Right side - Add to Queue bubble (appears on left swipe)
                    if swipeOffset < 0 {
                        Image(systemName: "text.append")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(.blue)
                            .clipShape(Circle())
                            .opacity(min(Double(-swipeOffset) / swipeThreshold, 1.0))
                            .scaleEffect(min(Double(-swipeOffset) / swipeThreshold, 1.0))
                            .padding(.trailing, 8)
                    }
                }

                // Main content
                HStack(spacing: 12) {
                    // Album artwork
                    ZStack {
                        Group {
                            if let artworkImage = artworkImage {
                                Image(uiImage: artworkImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } else {
                                Image(systemName: "music.note")
                                    .font(.system(size: 16))
                                    .foregroundColor(settings.backgroundColorChoice.color)
                            }
                        }
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .background(Color(.systemGray5))

                        if isCurrentlyPlaying {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(settings.backgroundColorChoice.color, lineWidth: 1.5)
                                .frame(width: 40, height: 40)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title)
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundColor(isCurrentlyPlaying ? settings.backgroundColorChoice.color : .primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .multilineTextAlignment(.leading)

                        if let artistName, !artistName.isEmpty {
                            Text(artistName)
                                .font(.caption)
                                .foregroundColor(isCurrentlyPlaying ? settings.backgroundColorChoice.color.opacity(0.8) : .secondary)
                        }
                    }

                    Spacer()

                    // Currently playing indicator
                    if isCurrentlyPlaying {
                        let eqKey = "\(playerEngine.isPlaying && isCurrentlyPlaying)-\(playerEngine.currentTrack?.stableId ?? "")"

                        EqualizerBarsExact(
                            color: settings.backgroundColorChoice.color,
                            isActive: playerEngine.isPlaying && isCurrentlyPlaying,
                            isLarge: false,
                            trackId: playerEngine.currentTrack?.stableId
                        )
                        .id(eqKey)
                    }

                    if let duration = track.durationMs {
                        Text(formatDuration(duration))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.ultraThinMaterial)
                        .opacity(0.7)
                )
                .offset(x: swipeOffset)
                .gesture(
                    DragGesture(minimumDistance: 20)
                        .onChanged { value in
                            swipeOffset = value.translation.width
                            if swipeOffset > swipeThreshold {
                                swipeAction = .playNext
                            } else if swipeOffset < -swipeThreshold {
                                swipeAction = .addToQueue
                            } else {
                                swipeAction = .none
                            }
                        }
                        .onEnded { _ in
                            withAnimation(.spring(response: 0.3)) {
                                switch swipeAction {
                                case .playNext:
                                    playerEngine.insertNext(track)
                                case .addToQueue:
                                    playerEngine.addToQueue(track)
                                case .none:
                                    break
                                }
                                swipeOffset = 0
                                swipeAction = .none
                            }
                        }
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    onDismiss()
                    Task {
                        // Only queue the selected song from search
                        await appCoordinator.playTrack(track, queue: [track])
                    }
                }
                .contextMenu {
                    Button(action: {
                        do {
                            try appCoordinator.toggleFavorite(trackStableId: track.stableId)
                            isFavorite.toggle()
                        } catch {
                            print("Failed to toggle favorite: \(error)")
                        }
                    }) {
                        Label(
                            isFavorite ? Localized.removeFromLikedSongs : Localized.addToLikedSongs,
                            systemImage: isFavorite ? "heart.slash" : "heart"
                        )
                    }

                    Button(action: {
                        playerEngine.insertNext(track)
                    }) {
                        Label(Localized.playNext, systemImage: "text.line.first.and.arrowtriangle.forward")
                    }

                    Button(action: {
                        playerEngine.addToQueue(track)
                    }) {
                        Label(Localized.addToQueue, systemImage: "text.append")
                    }

                    Button(action: {
                        showPlaylistDialog = true
                    }) {
                        Label(Localized.addToPlaylistEllipsis, systemImage: "rectangle.stack.badge.plus")
                    }

                    if let artistId = track.artistId,
                       let artist = try? DatabaseManager.shared.read({ db in
                           try Artist.fetchOne(db, key: artistId)
                       }),
                       let allArtistTracks = try? DatabaseManager.shared.read({ db in
                           try Track.filter(Column("artist_id") == artistId).fetchAll(db)
                       }) {
                        NavigationLink(destination: ArtistDetailScreen(artist: artist, allTracks: allArtistTracks)) {
                            Label(Localized.showArtistPage, systemImage: "person.circle")
                        }
                    }

                    Button(role: .destructive, action: {
                        showDeleteConfirmation = true
                    }) {
                        Label(Localized.deleteFile, systemImage: "trash")
                    }
                }
            }
            .onAppear {
                loadArtwork()
                checkFavoriteStatus()
            }
            .sheet(isPresented: $showPlaylistDialog) {
                PlaylistSelectionView(track: track)
                    .accentColor(settings.backgroundColorChoice.color)
            }
            .alert(Localized.deleteFile, isPresented: $showDeleteConfirmation) {
                Button(Localized.delete, role: .destructive) {
                    deleteFile()
                }
                Button(Localized.cancel, role: .cancel) { }
            } message: {
                Text(Localized.deleteFileConfirmation(track.title))
            }
        }

        private func checkFavoriteStatus() {
            do {
                isFavorite = try DatabaseManager.shared.isFavorite(trackStableId: track.stableId)
            } catch {
                print("Failed to check favorite status: \(error)")
            }
        }

        private func loadArtwork() {
            Task {
                artworkImage = await ArtworkManager.shared.getArtwork(for: track)
            }
        }

        private func deleteFile() {
            Task {
                do {
                    let settings = DeleteSettings.load()
                    if settings.deleteFromLibraryOnly {
                        DeleteSettings.addExcludedTrack(track.stableId)
                    } else {
                        do {
                            try FileManager.default.removeItem(at: URL(fileURLWithPath: track.path))
                        } catch {
                            print("⚠️ Could not remove file from disk: \(error.localizedDescription)")
                        }
                    }

                    try DatabaseManager.shared.deleteTrack(byStableId: track.stableId)
                    NotificationCenter.default.post(name: NSNotification.Name("LibraryNeedsRefresh"), object: nil)
                } catch {
                    print("❌ Failed to delete track: \(error)")
                }
            }
        }

        private func formatDuration(_ milliseconds: Int) -> String {
            let seconds = milliseconds / 1000
            let minutes = seconds / 60
            let remainingSeconds = seconds % 60
            return String(format: "%d:%02d", minutes, remainingSeconds)
        }

    }
    
    struct SearchArtistRowView: View {
        let artist: Artist
        let onDismiss: () -> Void
        let onNavigate: (Artist, [Track]) -> Void
        
        var body: some View {
            Button(action: {
                let artistTracks: [Track]
                if let artistId = artist.id {
                    artistTracks = (try? DatabaseManager.shared.getTracksByArtistId(artistId)) ?? []
                } else {
                    artistTracks = []
                }
                onDismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    onNavigate(artist, artistTracks)
                }
            }) {
                HStack(spacing: 12) {
                    Image(systemName: "person.circle.fill")
                        .font(.title2)
                        .foregroundColor(.purple)
                        .frame(width: 24, height: 24)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(artist.name)
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        
                        Text(Localized.artist)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
    
    struct SearchArtistAlbumsRow: View {
        let artist: Artist
        let onDismiss: () -> Void
        let onNavigateToAlbum: (Album, [Track]) -> Void
        @State private var artistAlbums: [Album] = []
        @State private var artistTracks: [Track] = []

        var body: some View {
            Group {
                if !artistAlbums.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(artistAlbums, id: \.id) { album in
                                let albumTracks = artistTracks.filter { $0.albumId == album.id }
                                Button {
                                    onDismiss()
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                        onNavigateToAlbum(album, albumTracks)
                                    }
                                } label: {
                                    SearchArtistAlbumCard(album: album, tracks: artistTracks)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                    }
                }
            }
            .onAppear { loadArtistData() }
        }

        private func loadArtistData() {
            guard let artistId = artist.id else { return }
            Task {
                let tracks = (try? DatabaseManager.shared.getTracksByArtistId(artistId)) ?? []
                let allAlbums = (try? DatabaseManager.shared.getAllAlbums()) ?? []
                let albums = allAlbums.filter { $0.artistId == artistId }
                await MainActor.run {
                    artistTracks = tracks
                    artistAlbums = albums
                }
            }
        }

        struct SearchArtistAlbumCard: View {
            let album: Album
            let tracks: [Track]
            @State private var artworkImage: UIImage?

            var body: some View {
                VStack(spacing: 4) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(.systemGray5))
                            .frame(width: 80, height: 80)

                        if let image = artworkImage {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 80, height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        } else {
                            Image(systemName: "opticaldisc.fill")
                                .font(.title3)
                                .foregroundColor(.secondary)
                        }
                    }

                    Text(album.title)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(width: 80)
                        .foregroundColor(.primary)
                }
                .onAppear { loadArtwork() }
            }

            private func loadArtwork() {
                let albumTracks = tracks.filter { $0.albumId == album.id }
                guard let firstTrack = albumTracks.first else { return }
                Task {
                    let image = await ArtworkManager.shared.getArtwork(for: firstTrack)
                    await MainActor.run { artworkImage = image }
                }
            }
        }

    }

    struct SearchAlbumRowView: View {
        let album: Album
        let albumArtistName: String?
        let onDismiss: () -> Void
        let onNavigate: (Album, [Track]) -> Void
        @State private var settings = DeleteSettings.load()
        @State private var artworkImage: UIImage?
        @State private var albumTracks: [Track] = []
        
        var body: some View {
            Button(action: {
                onDismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    onNavigate(album, albumTracks)
                }
            }) {
                HStack(spacing: 12) {
                    // Album artwork
                    Group {
                        if let artworkImage = artworkImage {
                            Image(uiImage: artworkImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: "opticaldisc.fill")
                                .font(.system(size: 20))
                                .foregroundColor(.orange)
                        }
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .background(Color(.systemGray5))
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(album.title)
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        
                        HStack(spacing: 4) {
                            if let albumArtistName, !albumArtistName.isEmpty {
                                Text(albumArtistName)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Text("• \(Localized.album)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Spacer()
                    
                    Text(Localized.songsCountOnly(albumTracks.count))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .onAppear {
                loadAlbumData()
            }
        }
        
        private func loadAlbumData() {
            guard let albumId = album.id else { return }

            Task {
                let tracks = (try? DatabaseManager.shared.getTracksByAlbumId(albumId)) ?? []
                await MainActor.run {
                    albumTracks = tracks
                }

                guard let firstTrack = tracks.first else { return }
                let artwork = await ArtworkManager.shared.getArtwork(for: firstTrack)
                await MainActor.run {
                    artworkImage = artwork
                }
            }
        }
    }
    
    struct SearchPlaylistRowView: View {
        let playlist: Playlist
        let onDismiss: () -> Void
        let onNavigate: (Playlist) -> Void
        @State private var settings = DeleteSettings.load()
        
        var body: some View {
            Button(action: {
                onDismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    onNavigate(playlist)
                }
            }) {
                HStack(spacing: 12) {
                    Image(systemName: "music.note.list")
                        .font(.title2)
                        .foregroundColor(.green)
                        .frame(width: 24, height: 24)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(playlist.title)
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        
                        Text(Localized.playlist)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
}

struct MusicFilePicker: UIViewControllerRepresentable {
    let onFilesPicked: ([URL]) -> Void
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [
            UTType.audio,
            UTType("public.mp3")!,
            UTType("org.xiph.flac")!
        ])
        
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
