import SwiftUI
import GRDB

struct AlbumsScreen: View {
    let allTracks: [Track]
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var albums: [Album] = []
    @State private var settings = DeleteSettings.load()
    @StateObject private var search = LibrarySearchState()
    @State private var artistNamesById: [Int64: String] = [:]

    private var visibleAlbums: [Album] {
        let terms = LibrarySearch.terms(in: search.text)
        guard !terms.isEmpty else { return albums }
        return albums.filter { album in
            // Match the artist too, so "daft punk" finds their albums without
            // the user having to remember an album title.
            let artist = album.albumArtist ?? album.artistId.flatMap { artistNamesById[$0] }
            return LibrarySearch.matches(terms: terms, in: album.title, artist)
        }
    }

    var body: some View {
        ZStack {
            ScreenSpecificBackgroundView(screen: .albums)
            
            VStack {
                if visibleAlbums.isEmpty {
                    EmptyAlbumsView(isSearching: !albums.isEmpty)
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: 20),
                                GridItem(.flexible())
                            ],
                            spacing: 16
                        ) {
                            ForEach(visibleAlbums, id: \.id) { album in
                                NavigationLink {
                                    AlbumDetailScreen(album: album, allTracks: allTracks)
                                } label: {
                                    AlbumCardView(album: album,
                                                  tracks: getAlbumTracks(album))
                                        .frame(maxWidth: .infinity, alignment: .topLeading)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(16)
                        .padding(.bottom, 100) // Add padding for mini player
                    }
                }
            }
        }
        .navigationTitle(Localized.albums)
        .navigationBarTitleDisplayMode(.inline)
        .librarySearchField(search, prompt: Localized.searchAlbums)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                LibrarySearchButton(state: search)
            }
        }
        .onAppear(perform: loadAlbums)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("LibraryNeedsRefresh"))) { _ in
            loadAlbums()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cosmosSettingsDidChange)) { _ in
            settings = DeleteSettings.load()
        }
    }
    
    private func getAlbumTracks(_ album: Album) -> [Track] {
        allTracks.filter { $0.albumId == album.id }
    }
    
    private func loadAlbums() {
        do {
            albums = try appCoordinator.getAllAlbums()
            artistNamesById = try DatabaseManager.shared.getAllArtistNamesById()
        } catch {
            print("Failed to load albums: \(error)")
        }
    }
}

private struct EmptyAlbumsView: View {
    /// The library has albums, they just don't match the current query.
    var isSearching = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: isSearching ? "magnifyingglass" : "opticaldisc")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text(isSearching ? Localized.noResultsFound : Localized.noAlbumsFound).font(.headline)
            Text(isSearching ? Localized.tryDifferentKeywords : Localized.albumsWillAppear)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// Album card with artwork loading
private struct AlbumCardView: View {
    let album: Album
    let tracks: [Track]
    @State private var artworkImage: UIImage?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Album artwork area with fixed aspect ratio
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.15))
                    .overlay {
                        if let image = artworkImage {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: geometry.size.width, height: geometry.size.width)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        } else {
                            Image(systemName: "music.note")
                                .font(.system(size: 36))
                                .foregroundColor(.secondary)
                        }
                    }
            }
            .aspectRatio(1, contentMode: .fit)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(album.title)
                    .font(.headline)
                    .lineLimit(2)
                
                Text(Localized.songsCount(tracks.count))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(minHeight: 60, alignment: .topLeading)
        }
        .task {
            loadAlbumArtwork()
        }
        .reloadsArtwork(for: tracks.first?.stableId) { loadAlbumArtwork() }
    }
    
    private func loadAlbumArtwork() {
        // Use the first track in the album to get artwork
        guard let firstTrack = tracks.first else { return }
        Task {
            artworkImage = await ArtworkManager.shared.getThumbnail(for: firstTrack, maxPixelSize: 512)
        }
    }
}

// Album detail view reconstructed
struct AlbumDetailScreen: View {

    let album: Album
    let allTracks: [Track]
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var artworkImage: UIImage?
    @State private var settings = DeleteSettings.load()
    @State private var albumTracks: [Track] = []
    @State private var artistNameCache: [Int64: String] = [:]
    @State private var isBulkMode = false
    @State private var selectedTracks: Set<String> = []

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

    private var playerEngine: PlayerEngine {
        appCoordinator.playerEngine
    }

    private var filteredAlbumTracks: [Track] {
        // Filter out incompatible formats when connected to CarPlay
        if carPlayState.isConnected {
            return albumTracks.filter { track in
                let ext = URL(fileURLWithPath: track.path).pathExtension.lowercased()
                let incompatibleFormats = ["ogg", "oga", "opus", "dsf", "dff"]
                return !incompatibleFormats.contains(ext)
            }
        } else {
            return albumTracks
        }
    }

    private var groupedByDisc: [(discNumber: Int, tracks: [Track])] {
        let grouped = Dictionary(grouping: filteredAlbumTracks) { track in
            track.discNo ?? 1
        }
        return grouped.sorted(by: { $0.key < $1.key }).map { (discNumber: $0.key, tracks: $0.value) }
    }

    private var hasMultipleDiscs: Bool {
        return groupedByDisc.count > 1
    }
    
    private var albumArtist: String {
        if let albumArtist = album.albumArtist, !albumArtist.isEmpty {
            return albumArtist
        }
        if let artistId = album.artistId,
           let artistName = artistNameCache[artistId] {
            return artistName
        }
        return Localized.unknownArtist
    }
    
    var body: some View {
        ZStack {
            ScreenSpecificBackgroundView(screen: .albumDetail)
            
            ScrollView {
                VStack(spacing: 24) {
                    // Artwork + info
                    VStack(spacing: 16) {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.gray.opacity(0.2))
                            .frame(width: 250, height: 250)
                            .overlay {
                                if let image = artworkImage {
                                    Image(uiImage: image)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 250, height: 250)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                } else {
                                    Image(systemName: "music.note")
                                        .font(.system(size: 50))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
                        
                        VStack(spacing: 8) {
                            Text(album.title)
                                .font(.title2)
                                .fontWeight(.bold)
                                .multilineTextAlignment(.center)
                            
                            NavigationLink {
                                ArtistDetailScreenWrapper(artistName: albumArtist, allTracks: allTracks)
                            } label: {
                                Text(albumArtist)
                                    .font(.title3)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .buttonStyle(.plain)
                        }
                        
                        HStack(spacing: 12) {
                            Button {
                                if let first = filteredAlbumTracks.first {
                                    Task {
                                        await playerEngine.playTrack(first, queue: filteredAlbumTracks)
                                    }
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "play.fill")
                                    Text(Localized.play)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.6)
                                }
                                .font(.title3.weight(.semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .frame(maxWidth: .infinity)
                                .frame(height: 56)
                                .background(settings.backgroundColorChoice.color)
                                .cornerRadius(28)
                            }

                            Button {
                                guard !filteredAlbumTracks.isEmpty else { return }
                                let shuffled = filteredAlbumTracks.shuffled()
                                Task {
                                    await playerEngine.playTrack(shuffled[0], queue: shuffled)
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "shuffle")
                                    Text(Localized.shuffle)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.6)
                                }
                                .font(.title3.weight(.semibold))
                                .foregroundColor(settings.backgroundColorChoice.color)
                                .padding(.horizontal, 8)
                                .frame(maxWidth: .infinity)
                                .frame(height: 56)
                                .background(settings.backgroundColorChoice.color.opacity(0.1))
                                .cornerRadius(28)
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                    .padding(.horizontal)
                    
                    // Track list
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(Localized.songs)
                                .font(.title3.weight(.bold))
                            Spacer()
                            Text(Localized.songsCount(filteredAlbumTracks.count))
                                .font(.body)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 12)

                        LazyVStack(spacing: 0) {
                            ForEach(groupedByDisc, id: \.discNumber) { disc in
                                // Disc header (only show if multiple discs)
                                if hasMultipleDiscs {
                                    HStack {
                                        Text(Localized.discNumber(disc.discNumber))
                                            .font(.headline)
                                            .foregroundColor(.secondary)
                                        Spacer()
                                    }
                                    .padding(.horizontal)
                                    .padding(.top, disc.discNumber > 1 ? 16 : 0)
                                    .padding(.bottom, 8)
                                }

                                // Tracks for this disc
                                ForEach(Array(disc.tracks.enumerated()), id: \.element.stableId) { index, track in
                                    HStack(spacing: 12) {
                                        if isBulkMode {
                                            TrackSelectionIndicator(
                                                isSelected: selectedTracks.contains(track.stableId),
                                                accentColor: settings.backgroundColorChoice.color,
                                                onTap: { toggleSelection(track) }
                                            )
                                            .padding(.leading)
                                        }

                                        AlbumTrackRowView(
                                            track: track,
                                            trackNumber: track.trackNo ?? (index + 1),
                                            artistName: (try? DatabaseManager.shared.getArtistDisplayName(forTrackStableId: track.stableId, fallbackArtistId: track.artistId)) ?? track.artistId.flatMap { artistNameCache[$0] },
                                            onTap: {
                                                // While selecting, a tap toggles instead of playing.
                                                if isBulkMode {
                                                    toggleSelection(track)
                                                } else {
                                                    Task {
                                                        await playerEngine.playTrack(track, queue: filteredAlbumTracks)
                                                    }
                                                }
                                            },
                                            onEnterBulkMode: { beginSelection(with: track) }
                                        )
                                    }
                                    .contentShape(Rectangle())
                                    // simultaneousGesture rather than
                                    // onLongPressGesture: this row's root is a
                                    // Button, whose own press recogniser wins an
                                    // ordinary long press, so selection could
                                    // never be entered by holding a track.
                                    .simultaneousGesture(
                                        LongPressGesture(minimumDuration: 0.5)
                                            .onEnded { _ in beginSelection(with: track) }
                                    )

                                    // Add divider between tracks (not after last track of last disc)
                                    let isLastTrackOfDisc = index == disc.tracks.count - 1
                                    let isLastDisc = disc.discNumber == groupedByDisc.last?.discNumber
                                    if !isLastTrackOfDisc || !isLastDisc {
                                        Divider().padding(.leading, 60)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 100) // Add padding for mini player
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .trackBulkActions(
            tracks: filteredAlbumTracks,
            isBulkMode: $isBulkMode,
            selectedTracks: $selectedTracks
        )
        .onAppear {
            loadArtistNameCache()
            loadAlbumTracks()
            loadAlbumArtwork()
        }
        // albumTracks is @State loaded once, so without this a bulk delete left
        // the removed tracks on screen until the view was revisited.
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LibraryNeedsRefresh"))) { _ in
            loadAlbumTracks()
        }
        .task {
            // Ensure data loads even if onAppear doesn't trigger
            if albumTracks.isEmpty {
                loadAlbumTracks()
            }
            if artworkImage == nil {
                loadAlbumArtwork()
            }
        }
    }

    private func toggleSelection(_ track: Track) {
        if selectedTracks.contains(track.stableId) {
            selectedTracks.remove(track.stableId)
        } else {
            selectedTracks.insert(track.stableId)
        }
    }

    private func beginSelection(with track: Track) {
        guard !isBulkMode else { return }
        isBulkMode = true
        selectedTracks.insert(track.stableId)
    }

    private func loadAlbumTracks() {
        guard let albumId = album.id else { return }
        do {
            albumTracks = try appCoordinator.databaseManager.getTracksByAlbumId(albumId)
        } catch {
            print("Failed to load album tracks: \(error)")
        }
    }

    private func loadAlbumArtwork() {
        guard let first = filteredAlbumTracks.first else { return }
        Task {
            do {
                let image = await ArtworkManager.shared.getArtwork(for: first)
                await MainActor.run {
                    artworkImage = image
                }
            }
        }
    }

    private func loadArtistNameCache() {
        do {
            artistNameCache = try DatabaseManager.shared.getAllArtistNamesById()
        } catch {
            print("Failed to load album artist cache: \(error)")
        }
    }
}

struct AlbumTrackRowView: View {
    let track: Track
    let trackNumber: Int
    let artistName: String?
    let onTap: () -> Void
    /// Menu entry point into multi-select. The long press is unreliable over
    /// this row's Button root, so the menu is the dependable route.
    var onEnterBulkMode: (() -> Void)? = nil
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var isFavorite = false
    @State private var showPlaylistDialog = false
    @State private var showDeleteConfirmation = false
    @State private var deleteSettings = DeleteSettings.load()
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                // Track number
                Text("\(trackNumber)")
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                    .frame(width: 22, alignment: .leading)
                
                // Track info
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)
                    
                    // Artist name and duration with dot separator
                    HStack(spacing: 0) {
                        if let artistName, !artistName.isEmpty {
                            Text(artistName)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            if track.durationMs != nil {
                                Text(" • ")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        if let duration = track.durationMs {
                            Text(formatDuration(duration))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Spacer()
                
                // Menu button - reduced spacing
                Menu {
                    if let onEnterBulkMode {
                        Button(action: { onEnterBulkMode() }) {
                            Label(Localized.select, systemImage: "checkmark.circle")
                        }
                        Divider()
                    }

                    Button(action: {
                        do {
                            try appCoordinator.toggleFavorite(trackStableId: track.stableId)
                            isFavorite.toggle()
                        } catch {
                            print("Failed to toggle favorite: \(error)")
                        }
                    }) {
                        HStack {
                            Image(systemName: isFavorite ? "heart.slash" : "heart")
                                .foregroundColor(isFavorite ? .red : .primary)
                            Text(isFavorite ? Localized.removeFromLikedSongs : Localized.addToLikedSongs)
                                .foregroundColor(.primary)
                        }
                    }
                    
                    if let artistId = track.artistId,
                       let artist = try? DatabaseManager.shared.read({ db in
                           try Artist.fetchOne(db, key: artistId)
                       }),
                       let allArtistTracks = try? DatabaseManager.shared.getTracksByArtistId(artistId) {
                        NavigationLink(destination: ArtistDetailScreenWrapper(artistName: artist.name, allTracks: allArtistTracks)) {
                            Label(Localized.showArtistPage, systemImage: "person.circle")
                        }
                    }
                    
                    Button(action: {
                        showPlaylistDialog = true
                    }) {
                        Label(Localized.addToPlaylistEllipsis, systemImage: "rectangle.stack.badge.plus")
                    }
                    
                    Button(action: {
                        showDeleteConfirmation = true
                    }) {
                        Label(Localized.deleteFile, systemImage: "trash")
                    }
                    .foregroundColor(.red)
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 30)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .onAppear {
            checkFavoriteStatus()
        }
        .sheet(isPresented: $showPlaylistDialog) {
            PlaylistSelectionView(track: track)
                .accentColor(deleteSettings.backgroundColorChoice.color)
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
    
    private func formatDuration(_ milliseconds: Int) -> String {
        let seconds = milliseconds / 1000
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
    
    private func deleteFile() {
        Task {
            do {
                let settings = DeleteSettings.load()
                if settings.deleteFromLibraryOnly {
                    DeleteSettings.addExcludedTrack(track.stableId, path: track.path, modificationDate: track.modificationDate)
                } else {
                    do {
                        try FileManager.default.removeItem(at: URL(fileURLWithPath: track.path))
                    } catch {
                        print("⚠️ Could not remove file from disk: \(error.localizedDescription)")
                    }
                }

                try await DatabaseManager.shared.deleteTrack(byStableId: track.stableId)
                NotificationCenter.default.post(name: NSNotification.Name("LibraryNeedsRefresh"), object: nil)
            } catch {
                print("❌ Failed to delete track: \(error)")
            }
        }
    }
}

struct ArtistDetailScreenWrapper: View {
    let artistName: String
    let allTracks: [Track]
    @State private var artist: Artist?
    
    var body: some View {
        Group {
            if let artist {
                ArtistDetailScreen(artist: artist, allTracks: allTracks)
            } else {
                VStack(spacing: 16) {
                    ProgressView()
                    Text(Localized.loadingArtist)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear(perform: loadArtist)
    }
    
    private func loadArtist() {
        do {
            artist = try DatabaseManager.shared.read { db in
                try Artist.filter(Column("name") == artistName).fetchOne(db)
            } ?? Artist(id: nil, name: artistName)
        } catch {
            print("Failed to load artist: \(error)")
            artist = Artist(id: nil, name: artistName)
        }
    }
}
