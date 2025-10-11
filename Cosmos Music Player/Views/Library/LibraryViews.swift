import SwiftUI
import GRDB
import UniformTypeIdentifiers

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
    @State private var searchArtistToNavigate: Artist?
    @State private var searchArtistTracks: [Track] = []
    @State private var searchAlbumToNavigate: Album?
    @State private var searchAlbumTracks: [Track] = []
    @State private var searchPlaylistToNavigate: Playlist?
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
            var processedCount = 0

            for url in urls {
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
                    await libraryIndexer.processExternalFile(url)
                    processedCount += 1
                    print("Processed and bookmarked file from original location: \(url.lastPathComponent)")

                } catch {
                    print("Failed to create bookmark for \(url.lastPathComponent): \(error)")

                    // Still try to process the file even if bookmark creation fails
                    await libraryIndexer.processExternalFile(url)
                    processedCount += 1
                    print("Processed file from original location (no bookmark): \(url.lastPathComponent)")
                }
            }

            // Show feedback
            await MainActor.run {
                if processedCount > 0 {
                    syncToastIcon = "plus.circle.fill"
                    syncToastColor = .green
                    if processedCount == 1 {
                        syncToastMessage = "1 song processed"
                    } else {
                        syncToastMessage = "\(processedCount) songs processed"
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
            if processedCount > 0, let onManualSync = onManualSync {
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

    var body: some View {
        TrackListView(tracks: tracks)
            .background(ScreenSpecificBackgroundView(screen: .allSongs))
            .navigationTitle(Localized.allSongs)
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct LikedSongsScreen: View {
    let allTracks: [Track]
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var likedTracks: [Track] = []

    var body: some View {
        TrackListView(tracks: likedTracks)
            .background(ScreenSpecificBackgroundView(screen: .likedSongs))
            .navigationTitle(Localized.likedSongs)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                loadLikedTracks()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LibraryNeedsRefresh"))) { _ in
            loadLikedTracks()
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
    case dateNewest
    case dateOldest
    case nameAZ
    case nameZA
    case sizeLargest
    case sizeSmallest

    var localizedString: String {
        switch self {
        case .dateNewest: return Localized.sortDateNewest
        case .dateOldest: return Localized.sortDateOldest
        case .nameAZ: return Localized.sortNameAZ
        case .nameZA: return Localized.sortNameZA
        case .sizeLargest: return Localized.sortSizeLargest
        case .sizeSmallest: return Localized.sortSizeSmallest
        }
    }
}

struct TrackListView: View {
    let tracks: [Track]
    let playlist: Playlist?
    let isEditMode: Bool
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var sortOption: TrackSortOption = .dateNewest
    @State private var showSortMenu = false

    init(tracks: [Track], playlist: Playlist? = nil, isEditMode: Bool = false) {
        self.tracks = tracks
        self.playlist = playlist
        self.isEditMode = isEditMode
    }

    private var sortedTracks: [Track] {
        // Filter out incompatible formats when connected to CarPlay
        let filteredTracks: [Track]
        if SFBAudioEngineManager.shared.isCarPlayEnvironment {
            filteredTracks = tracks.filter { track in
                let ext = URL(fileURLWithPath: track.path).pathExtension.lowercased()
                let incompatibleFormats = ["ogg", "opus", "dsf", "dff"]
                return !incompatibleFormats.contains(ext)
            }
        } else {
            filteredTracks = tracks
        }

        switch sortOption {
        case .dateNewest:
            return filteredTracks.sorted { ($0.id ?? 0) > ($1.id ?? 0) }
        case .dateOldest:
            return filteredTracks.sorted { ($0.id ?? 0) < ($1.id ?? 0) }
        case .nameAZ:
            return filteredTracks.sorted { $0.title.lowercased() < $1.title.lowercased() }
        case .nameZA:
            return filteredTracks.sorted { $0.title.lowercased() > $1.title.lowercased() }
        case .sizeLargest:
            return filteredTracks.sorted { ($0.fileSize ?? 0) > ($1.fileSize ?? 0) }
        case .sizeSmallest:
            return filteredTracks.sorted { ($0.fileSize ?? 0) < ($1.fileSize ?? 0) }
        }
    }

    var body: some View {
        if tracks.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "music.note")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary)

                Text(Localized.noSongsFound)
                    .font(.headline)

                Text(Localized.yourMusicWillAppearHere)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(sortedTracks, id: \.stableId) { track in
                TrackRowView(
                    track: track,
                    onTap: {
                        Task {
                            // Update playlist access time if track is played from a playlist
                            if let playlist = playlist, let playlistId = playlist.id {
                                try? appCoordinator.updatePlaylistAccessed(playlistId: playlistId)
                                try? appCoordinator.updatePlaylistLastPlayed(playlistId: playlistId)
                            }
                            await appCoordinator.playTrack(track, queue: sortedTracks)
                        }
                    },
                    playlist: playlist,
                    showDirectDeleteButton: playlist != nil && isEditMode
                )
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.ultraThinMaterial)
                        .opacity(0.7)
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            .listStyle(PlainListStyle())
            .scrollContentBackground(.hidden)
            .contentMargins(.bottom, 100, for: .scrollContent)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        ForEach(TrackSortOption.allCases, id: \.self) { option in
                            Button(action: { sortOption = option }) {
                                HStack {
                                    Text(option.localizedString)
                                    if sortOption == option {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                }
            }
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
    @State private var selectedCategory = SearchCategory.all
    @State private var settings = DeleteSettings.load()
    @FocusState private var isSearchFocused: Bool
    
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
    
    private var searchResults: SearchResults {
        if searchText.isEmpty {
            return SearchResults()
        }
        
        let lowercasedQuery = searchText.lowercased()
        
        // Search songs
        let songs = allTracks.filter { track in
            // Search by title
            if track.title.lowercased().contains(lowercasedQuery) {
                return true
            }
            
            // Search by artist name
            if let artistId = track.artistId,
               let artist = try? DatabaseManager.shared.read({ db in
                   try Artist.fetchOne(db, key: artistId)
               }),
               artist.name.lowercased().contains(lowercasedQuery) {
                return true
            }
            
            // Search by album name
            if let albumId = track.albumId,
               let album = try? DatabaseManager.shared.read({ db in
                   try Album.fetchOne(db, key: albumId)
               }),
               album.title.lowercased().contains(lowercasedQuery) {
                return true
            }
            
            return false
        }
        
        // Search artists
        let artists: [Artist] = {
            do {
                let allArtists = try appCoordinator.databaseManager.getAllArtists()
                return allArtists.filter { $0.name.lowercased().contains(lowercasedQuery) }
            } catch {
                return []
            }
        }()
        
        // Search albums
        let albums: [Album] = {
            do {
                let allAlbums = try appCoordinator.getAllAlbums()
                return allAlbums.filter { album in
                    // Search by album title
                    if album.title.lowercased().contains(lowercasedQuery) {
                        return true
                    }
                    
                    // Search by artist name
                    if let artistId = album.artistId,
                       let artist = try? DatabaseManager.shared.read({ db in
                           try Artist.fetchOne(db, key: artistId)
                       }),
                       artist.name.lowercased().contains(lowercasedQuery) {
                        return true
                    }
                    
                    return false
                }
            } catch {
                return []
            }
        }()
        
        // Search playlists
        let playlists: [Playlist] = {
            do {
                let allPlaylists = try appCoordinator.databaseManager.getAllPlaylists()
                return allPlaylists.filter { $0.title.lowercased().contains(lowercasedQuery) }
            } catch {
                return []
            }
        }()
        
        return SearchResults(songs: songs, artists: artists, albums: albums, playlists: playlists)
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
                    if searchText.isEmpty {
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
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                settings = DeleteSettings.load()
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isSearchFocused = true
                }
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
        @EnvironmentObject private var appCoordinator: AppCoordinator
        @State private var settings = DeleteSettings.load()
        
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
                        if selectedCategory == .all || selectedCategory == .songs, !results.songs.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(Localized.songs)
                                    .font(.title3)
                                    .fontWeight(.bold)
                                    .padding(.horizontal, 16)
                                
                                ForEach(results.songs, id: \.stableId) { track in
                                    SearchSongRowView(track: track, allTracks: allTracks, onDismiss: onDismiss)
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
                        
                        if selectedCategory == .all || selectedCategory == .artists, !results.artists.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(Localized.artists)
                                    .font(.title3)
                                    .fontWeight(.bold)
                                    .padding(.horizontal, 16)
                                
                                ForEach(results.artists, id: \.id) { artist in
                                    SearchArtistRowView(
                                        artist: artist, 
                                        allTracks: allTracks, 
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
                                }
                            }
                        }
                        
                        if selectedCategory == .all || selectedCategory == .albums, !results.albums.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(Localized.albums)
                                    .font(.title3)
                                    .fontWeight(.bold)
                                    .padding(.horizontal, 16)
                                
                                ForEach(results.albums, id: \.id) { album in
                                    SearchAlbumRowView(
                                        album: album, 
                                        allTracks: allTracks, 
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
            }
        }
    }
    
    struct SearchSongRowView: View {
        let track: Track
        let allTracks: [Track]
        let onDismiss: () -> Void
        @EnvironmentObject private var appCoordinator: AppCoordinator
        @StateObject private var playerEngine = PlayerEngine.shared
        @State private var settings = DeleteSettings.load()
        @State private var artworkImage: UIImage?
        
        private var isCurrentlyPlaying: Bool {
            playerEngine.currentTrack?.stableId == track.stableId
        }
        
        var body: some View {
            Button(action: {
                onDismiss()
                Task {
                    await appCoordinator.playTrack(track, queue: allTracks)
                }
            }) {
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
                        
                        HStack(spacing: 4) {
                            if let artistId = track.artistId,
                               let artist = try? DatabaseManager.shared.read({ db in
                                   try Artist.fetchOne(db, key: artistId)
                               }) {
                                Text(artist.name)
                                    .font(.caption)
                                    .foregroundColor(isCurrentlyPlaying ? settings.backgroundColorChoice.color.opacity(0.8) : .secondary)
                            }
                        }
                    }
                    
                    Spacer()
                    
                    // Currently playing indicator (Deezer-style equalizer)
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
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .onAppear {
                loadArtwork()
            }
        }
        
        private func loadArtwork() {
            Task {
                artworkImage = await ArtworkManager.shared.getArtwork(for: track)
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
        let allTracks: [Track]
        let onDismiss: () -> Void
        let onNavigate: (Artist, [Track]) -> Void
        @State private var settings = DeleteSettings.load()
        
        private var artistTracks: [Track] {
            allTracks.filter { $0.artistId == artist.id }
        }
        
        var body: some View {
            Button(action: {
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
    
    struct SearchAlbumRowView: View {
        let album: Album
        let allTracks: [Track]
        let onDismiss: () -> Void
        let onNavigate: (Album, [Track]) -> Void
        @State private var settings = DeleteSettings.load()
        @State private var artworkImage: UIImage?
        
        private var albumTracks: [Track] {
            allTracks.filter { $0.albumId == album.id }
        }
        
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
                            if let artistId = album.artistId,
                               let artist = try? DatabaseManager.shared.read({ db in
                                   try Artist.fetchOne(db, key: artistId)
                               }) {
                                Text(artist.name)
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
                loadAlbumArtwork()
            }
        }
        
        private func loadAlbumArtwork() {
            guard let firstTrack = albumTracks.first else { return }
            Task {
                artworkImage = await ArtworkManager.shared.getArtwork(for: firstTrack)
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

