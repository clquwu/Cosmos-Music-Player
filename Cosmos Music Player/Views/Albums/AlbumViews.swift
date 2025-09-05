import SwiftUI
import GRDB

struct AlbumsScreen: View {
    let allTracks: [Track]
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var albums: [Album] = []
    @State private var settings = DeleteSettings.load()
    
    var body: some View {
        ZStack {
            ScreenSpecificBackgroundView(screen: .albums)
            
            VStack {
                if albums.isEmpty {
                    EmptyAlbumsView()
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: 20),
                                GridItem(.flexible())
                            ],
                            spacing: 16
                        ) {
                            ForEach(albums, id: \.id) { album in
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
        .onAppear(perform: loadAlbums)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("LibraryNeedsRefresh"))) { _ in
            loadAlbums()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            settings = DeleteSettings.load()
        }
    }
    
    private func getAlbumTracks(_ album: Album) -> [Track] {
        allTracks.filter { $0.albumId == album.id }
    }
    
    private func loadAlbums() {
        do {
            albums = try appCoordinator.getAllAlbums()
        } catch {
            print("Failed to load albums: \(error)")
        }
    }
}

private struct EmptyAlbumsView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "opticaldisc")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text(Localized.noAlbumsFound).font(.headline)
            Text(Localized.albumsWillAppear)
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
    }
    
    private func loadAlbumArtwork() {
        // Use the first track in the album to get artwork
        guard let firstTrack = tracks.first else { return }
        Task {
            artworkImage = await ArtworkManager.shared.getArtwork(for: firstTrack)
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
    
    private var playerEngine: PlayerEngine {
        appCoordinator.playerEngine
    }
    
    private var albumTracks: [Track] {
        allTracks
            .filter { $0.albumId == album.id }
            .sorted {
                ($0.trackNo ?? 0) < ($1.trackNo ?? 0)
            }
    }
    
    private var albumArtist: String {
        if let artistId = album.artistId,
           let artist = try? DatabaseManager.shared.read({ db in
               try Artist.fetchOne(db, key: artistId)
           }) {
            return artist.name
        }
        return "Unknown Artist"
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
                        
                        HStack(spacing: 20) {
                            Button {
                                if let first = albumTracks.first {
                                    Task {
                                        await playerEngine.playTrack(first, queue: albumTracks)
                                    }
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "play.fill")
                                    Text(Localized.play)
                                }
                                .font(.title3.weight(.semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity) .frame(height: 50)
                                .background(settings.backgroundColorChoice.color)
                                .cornerRadius(25)
                            }
                            
                            Button {
                                guard !albumTracks.isEmpty else { return }
                                let shuffled = albumTracks.shuffled()
                                Task {
                                    await playerEngine.playTrack(shuffled[0], queue: shuffled)
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "shuffle")
                                    Text(Localized.shuffle)
                                }
                                .font(.title3.weight(.semibold))
                                .foregroundColor(settings.backgroundColorChoice.color)
                                .frame(maxWidth: .infinity) .frame(height: 50)
                                .background(settings.backgroundColorChoice.color.opacity(0.1))
                                .cornerRadius(25)
                            }
                        }
                        .padding(.horizontal)
                    }
                    .padding(.horizontal)
                    
                    // Track list
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(Localized.songs)
                                .font(.title3.weight(.bold))
                            Spacer()
                            Text(Localized.songsCount(albumTracks.count))
                                .font(.body)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 12)
                        
                        LazyVStack(spacing: 0) {
                            ForEach(Array(albumTracks.enumerated()), id: \.offset) { index, track in
                                AlbumTrackRowView(
                                    track: track,
                                    trackNumber: track.trackNo ?? (index + 1),
                                    onTap: {
                                        Task {
                                            await playerEngine.playTrack(track, queue: albumTracks)
                                        }
                                    }
                                )
                                
                                if index < albumTracks.count - 1 {
                                    Divider().padding(.leading, 60)
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 100) // Add padding for mini player
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadAlbumArtwork)
        .task {
            // Ensure artwork loads even if onAppear doesn't trigger
            if artworkImage == nil {
                loadAlbumArtwork()
            }
        }
    }
    
    private func loadAlbumArtwork() {
        guard let first = albumTracks.first else { return }
        Task {
            do {
                let image = await ArtworkManager.shared.getArtwork(for: first)
                await MainActor.run {
                    artworkImage = image
                }
            }
        }
    }
}

struct AlbumTrackRowView: View {
    let track: Track
    let trackNumber: Int
    let onTap: () -> Void
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var isFavorite = false
    @State private var showPlaylistDialog = false
    @State private var showDeleteConfirmation = false
    @State private var deleteSettings = DeleteSettings.load()
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                // Track number - moved more to the left
                Text("\(trackNumber)")
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                    .frame(width: 20, alignment: .leading)
                
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
                        if let artistId = track.artistId,
                           let artist = try? DatabaseManager.shared.read({ db in
                               try Artist.fetchOne(db, key: artistId)
                           }) {
                            Text(artist.name)
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
                       let allArtistTracks = try? DatabaseManager.shared.read({ db in
                           try Track.filter(Column("artist_id") == artistId).fetchAll(db)
                       }) {
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
            Button("Delete", role: .destructive) {
                deleteFile()
            }
            Button("Cancel", role: .cancel) { }
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
                let url = URL(fileURLWithPath: track.path)
                let artistId = track.artistId
                let albumId = track.albumId
                
                // Delete file from storage
                try FileManager.default.removeItem(at: url)
                print("🗑️ Deleted file from storage: \(track.title)")
                
                // Delete from database with cleanup of orphaned relations
                try DatabaseManager.shared.write { db in
                    print("🔍 Starting database deletion for track: \(track.title) with stableId: \(track.stableId)")
                    
                    // Remove from favorites if it exists
                    let favoritesDeleted = try Favorite.filter(Column("track_stable_id") == track.stableId).deleteAll(db)
                    print("🗑️ Removed \(favoritesDeleted) favorite entries for: \(track.title)")
                    
                    // Remove from playlists
                    let playlistItemsDeleted = try PlaylistItem.filter(Column("track_stable_id") == track.stableId).deleteAll(db)
                    print("🗑️ Removed \(playlistItemsDeleted) playlist entries for: \(track.title)")
                    
                    // Delete the track using stableId (primary key)
                    let tracksDeleted = try Track.filter(Column("stable_id") == track.stableId).deleteAll(db)
                    print("🗑️ Deleted \(tracksDeleted) tracks from database: \(track.title)")
                    
                    if tracksDeleted == 0 {
                        print("❌ WARNING: No tracks were deleted from database!")
                        return
                    }
                    
                    // Clean up orphaned album
                    if let albumId = albumId {
                        let remainingTracksInAlbum = try Track.filter(Column("album_id") == albumId).fetchCount(db)
                        print("🔍 Remaining tracks in album \(albumId): \(remainingTracksInAlbum)")
                        if remainingTracksInAlbum == 0 {
                            let albumsDeleted = try Album.deleteOne(db, key: albumId)
                            print("🗑️ Deleted orphaned album: \(albumId) (success: \(albumsDeleted))")
                        }
                    }
                    
                    // Clean up orphaned artist
                    if let artistId = artistId {
                        let remainingTracksForArtist = try Track.filter(Column("artist_id") == artistId).fetchCount(db)
                        let remainingAlbumsForArtist = try Album.filter(Column("artist_id") == artistId).fetchCount(db)
                        print("🔍 Remaining tracks for artist \(artistId): \(remainingTracksForArtist)")
                        print("🔍 Remaining albums for artist \(artistId): \(remainingAlbumsForArtist)")
                        if remainingTracksForArtist == 0 && remainingAlbumsForArtist == 0 {
                            let artistsDeleted = try Artist.deleteOne(db, key: artistId)
                            print("🗑️ Deleted orphaned artist: \(artistId) (success: \(artistsDeleted))")
                        }
                    }
                }
                print("✅ Database transaction completed successfully")
                
                // Notify UI to refresh
                NotificationCenter.default.post(name: NSNotification.Name("LibraryNeedsRefresh"), object: nil)
                
            } catch {
                print("❌ Failed to delete file: \(error)")
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
