import SwiftUI
import GRDB

struct ArtistsScreen: View {
    let allTracks: [Track]
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var artists: [Artist] = []
    @State private var settings = DeleteSettings.load()
    
    var body: some View {
        ZStack {
            ScreenSpecificBackgroundView(screen: .artists)
            
            VStack {
                if artists.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "person.2")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        
                        Text("No artists found")
                            .font(.headline)
                        
                        Text("Artists will appear here once you add music to your library")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(artists, id: \.id) { artist in
                        ZStack {
                            NavigationLink(destination: ArtistDetailScreen(artist: artist, allTracks: allTracks)) {
                                EmptyView()
                            }
                            .opacity(0.0)
                            
                            HStack {
                                Image(systemName: "person")
                                    .foregroundColor(.purple)
                                    .frame(width: 24, height: 24)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(artist.name)
                                        .font(.headline)
                                    
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
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(.ultraThinMaterial)
                                    .opacity(0.7)
                            )
                        }
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                    }
                    .listStyle(PlainListStyle())
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8)
                    .safeAreaInset(edge: .bottom) {
                        Color.clear.frame(height: 100) // Space for mini player
                    }
                }
            }
            .navigationTitle(Localized.artists)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                loadArtists()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LibraryNeedsRefresh"))) { _ in
                loadArtists()
            }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                settings = DeleteSettings.load()
            }
        }
    } // end body
    
    private func loadArtists() {
        do {
            artists = try appCoordinator.databaseManager.getAllArtists()
        } catch {
            print("Failed to load artists: \(error)")
        }
    }
}

struct ArtistListView: View {
    let artists: [Artist]
    let onArtistTap: (Artist) -> Void
    
    var body: some View {
        if artists.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "person.2")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary)
                
                Text("No artists found")
                    .font(.headline)
                
                Text("Artists will appear here once you add music to your library")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(artists, id: \.id) { artist in
                HStack {
                    Image(systemName: "person")
                        .foregroundColor(.purple)
                        .frame(width: 24, height: 24)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(artist.name)
                            .font(.headline)
                        
                        Text("Artist")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(height: 66)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
                .onTapGesture {
                    onArtistTap(artist)
                }
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
            }
            .listStyle(PlainListStyle())
        }
    }
}

struct ArtistDetailScreen: View {
    let artist: Artist
    let allTracks: [Track]
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @StateObject private var hybridAPI = HybridMusicAPIService.shared
    @State private var unifiedArtist: UnifiedArtist?
    @State private var isLoading = false
    @State private var artistImage: UIImage?
    @State private var showFullProfile = false
    @State private var hasTriedAlternatives = false
    @State private var hasShownWrongArtistButton = false
    @State private var settings = DeleteSettings.load()
    
    private var playerEngine: PlayerEngine {
        appCoordinator.playerEngine
    }
    
    private var artistTracks: [Track] {
        allTracks.filter { $0.artistId == artist.id }
    }
    
    private var artistAlbums: [Album] {
        do {
            let albums = try appCoordinator.getAllAlbums()
            return albums.filter { $0.artistId == artist.id }
        } catch {
            return []
        }
    }
    
    private var hasShownWrongArtistButtonBefore: Bool {
        let key = "hasShownWrongArtistButton_\(artist.id?.description ?? artist.name)"
        return UserDefaults.standard.bool(forKey: key)
    }
    
    private func markWrongArtistButtonAsShown() {
        let key = "hasShownWrongArtistButton_\(artist.id?.description ?? artist.name)"
        UserDefaults.standard.set(true, forKey: key)
    }
    
    var body: some View {
        ZStack {
            ScreenSpecificBackgroundView(screen: .artistDetail)
            
            Group {
                if let unifiedArtist = unifiedArtist, !isLoading {
                    richArtistView(unifiedArtist)
                } else {
                    simpleView
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadArtistData() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            settings = DeleteSettings.load()
        }
    }
    
    @ViewBuilder
    private func richArtistView(_ unifiedArtist: UnifiedArtist) -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    headerSection(geometry: geometry)
                    VStack(spacing: 20) {
                        if !artistTracks.isEmpty { songsSection }
                        if !artistAlbums.isEmpty { albumsSection }
                    }
                    .padding(.top, 20)
                    .padding(.bottom, 100) // Add padding for mini player
                }
            }
        }
        .ignoresSafeArea(.all, edges: .top)
    }
    
    @ViewBuilder
    private var simpleView: some View {
        ScrollView {
            VStack(spacing: 20) {
                simpleHeader
                if !artistTracks.isEmpty { songsSection }
                if !artistAlbums.isEmpty { albumsSection }
            }
            .padding(.bottom, 100) // Add padding for mini player
        }
    }
    
    // MARK: - Subsections
    
    @ViewBuilder
    private func headerSection(geometry: GeometryProxy) -> some View {
        let safeAreaTop = geometry.safeAreaInsets.top
        let imageHeight: CGFloat = 300 + safeAreaTop
        
        VStack(spacing: 16) {
            ZStack {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: geometry.size.width, height: imageHeight)
                    .clipped()
                    .overlay {
                        if let image = artistImage {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: geometry.size.width, height: imageHeight)
                                .clipped()
                        } else {
                            Image(systemName: "person.circle")
                                .font(.system(size: 60))
                                .foregroundColor(.secondary)
                        }
                    }
                    .overlay(
                        LinearGradient(
                            colors: [
                                Color.clear,
                                Color.clear,
                                Color.black.opacity(0.3),
                                Color.black.opacity(0.6)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                VStack {
                    HStack {
                        Spacer()
                        if let unifiedArtist = unifiedArtist, unifiedArtist.source == .spotify {
                            Image("SpotifyWhite")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 21, height: 21)
                                .padding(.top, 16)
                                .padding(.trailing, 20)
                        }
                    }
                    Spacer()
                    HStack {
                        Text(artist.name)
                            .font(.title)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 1)
                            .padding(.leading, 20)
                            .padding(.bottom, 20)
                        Spacer()
                    }
                }
            }
            .overlay(
                VStack {
                    Spacer()
                    LinearGradient(
                        colors: [
                            Color.clear,
                            Color(UIColor.systemBackground).opacity(0.3),
                            Color(UIColor.systemBackground).opacity(0.7),
                            Color(UIColor.systemBackground)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 20)
                }
            )
            .frame(maxWidth: .infinity)
            
            VStack(spacing: 16) {
                if let unifiedArtist = unifiedArtist, !unifiedArtist.profile.isEmpty {
                    profileSection(unifiedArtist)
                }
                
                // Wrong artist button - only show first time visiting this artist
                if unifiedArtist != nil && !hasShownWrongArtistButtonBefore {
                    HStack {
                        Button(action: {
                            Task {
                                await searchAlternativeArtistAutomatically()
                            }
                            markWrongArtistButtonAsShown()
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "questionmark.circle")
                                Text(Localized.wrongArtist)
                            }
                            .font(.caption)
                            .foregroundColor(.orange)
                        }
                        Spacer()
                    }
                }
                
                playButtons
            }
            .padding(.horizontal)
        }
    }
    
    @ViewBuilder
    private var simpleHeader: some View {
        VStack(spacing: 16) {
            Text(artist.name)
                .font(.largeTitle)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            if isLoading {
                ProgressView("Fetching artist info...")
            }
            playButtons
        }
        .padding(.horizontal)
    }
    
    @ViewBuilder
    private func profileSection(_ unifiedArtist: UnifiedArtist) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if unifiedArtist.source == .spotify {
                // Spotify content with attribution
                Text(unifiedArtist.profile)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .lineLimit(showFullProfile ? nil : 3)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.3)) { showFullProfile.toggle() }
                    }
                
                if showFullProfile {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 4) {
                            Text(Localized.dataProvidedBy("Spotify"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            if let spotifyArtist = unifiedArtist.spotifyArtist,
                               let spotifyURL = spotifyArtist.externalUrls.spotify {
                                Button(Localized.openSpotify) {
                                    if let url = URL(string: spotifyURL) {
#if os(macOS)
                                        NSWorkspace.shared.open(url)
#else
                                        UIApplication.shared.open(url)
#endif
                                    }
                                }
                                .font(.caption)
                                .foregroundColor(settings.backgroundColorChoice.color)
                            }
                        }
                        
                        // Show "Wrong artist?" button in expanded profile
                        Button(action: {
                            Task {
                                await searchAlternativeArtistAutomatically()
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "questionmark.circle")
                                Text(Localized.wrongArtist)
                            }
                            .font(.caption)
                            .foregroundColor(.orange)
                        }
                    }
                    .padding(.top, 4)
                }
            } else {
                // Discogs or other source content
                Text(unifiedArtist.profile)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .lineLimit(showFullProfile ? nil : 3)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.3)) { showFullProfile.toggle() }
                    }
                
                if showFullProfile {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Localized.dataProvidedBy(unifiedArtist.source.rawValue.capitalized))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        // Show "Wrong artist?" button in expanded profile
                        Button(action: {
                            Task {
                                await searchAlternativeArtistAutomatically()
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "questionmark.circle")
                                Text(Localized.wrongArtist)
                            }
                            .font(.caption)
                            .foregroundColor(.orange)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }
    
    private var playButtons: some View {
        HStack(spacing: 20) {
            Button {
                guard let first = artistTracks.first else { return }
                Task { await playerEngine.playTrack(first, queue: artistTracks) }
            } label: {
                HStack { Image(systemName: "play.fill"); Text(Localized.play) }
                    .font(.title3).fontWeight(.semibold)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(settings.backgroundColorChoice.color)
                    .cornerRadius(25)
            }
            Button {
                let shuffled = artistTracks.shuffled()
                guard let first = shuffled.first else { return }
                Task { await playerEngine.playTrack(first, queue: shuffled) }
            } label: {
                HStack { Image(systemName: "shuffle"); Text(Localized.shuffle) }
                    .font(.title3).fontWeight(.semibold)
                    .foregroundColor(settings.backgroundColorChoice.color)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(settings.backgroundColorChoice.color.opacity(0.1))
                    .cornerRadius(25)
            }
        }
    }
    
    private var songsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(Localized.songs).font(.title3).fontWeight(.bold)
                Spacer()
                Text("\(artistTracks.count) song\(artistTracks.count == 1 ? "" : "s")")
                    .font(.body).foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
            LazyVStack(spacing: 0) {
                ForEach(artistTracks.indices, id: \.self) { index in
                    let track = artistTracks[index]
                    ArtistTrackRowView(track: track) {
                        Task { await playerEngine.playTrack(track, queue: artistTracks) }
                    }
                    if index < artistTracks.count - 1 {
                        Divider().padding(.leading, 20)
                    }
                }
            }
        }
    }
    
    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(Localized.albums).font(.title3).fontWeight(.bold)
                Spacer()
                Text("\(artistAlbums.count) album\(artistAlbums.count == 1 ? "" : "s")")
                    .font(.body).foregroundColor(.secondary)
            }
            .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(artistAlbums, id: \.id) { album in
                        NavigationLink {
                            AlbumDetailScreen(album: album, allTracks: allTracks)
                        } label: {
                            ArtistAlbumCardView(album: album, tracks: allTracks)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.horizontal)
            }
        }
    }
    
    // MARK: - Data Loading
    private func loadArtistData() {
        guard unifiedArtist == nil && !isLoading else { return }
        isLoading = true
        Task { @MainActor in
            do {
                let fetchedArtist = try await HybridMusicAPIService.shared.searchArtist(name: artist.name)
                self.unifiedArtist = fetchedArtist
                self.isLoading = false
                if let fetchedArtist = fetchedArtist { await loadArtistImage(from: fetchedArtist.images) }
            } catch {
                self.isLoading = false
                print("❌ Failed to load artist data: \(error)")
            }
        }
    }
    
    private func searchAlternativeArtist() async {
        isLoading = true
        
        Task { @MainActor in
            do {
                let currentSource = unifiedArtist?.source
                let fetchedArtist = try await HybridMusicAPIService.shared.searchAlternativeArtist(name: artist.name, currentSource: currentSource)
                
                if let fetchedArtist = fetchedArtist {
                    self.unifiedArtist = fetchedArtist
                    self.artistImage = nil // Clear old image
                    await loadArtistImage(from: fetchedArtist.images)
                    print("✅ Found alternative artist: \(fetchedArtist.name) from \(fetchedArtist.source.rawValue)")
                } else {
                    print("❌ No alternative artist found")
                }
                
                self.isLoading = false
            } catch {
                self.isLoading = false
                print("❌ Failed to find alternative artist: \(error)")
            }
        }
    }
    
    private func searchSimilarArtist() async {
        isLoading = true
        hasTriedAlternatives = true
        
        Task { @MainActor in
            do {
                let currentSource = unifiedArtist?.source
                let fetchedArtist = try await HybridMusicAPIService.shared.searchSimilarArtist(originalName: artist.name, currentSource: currentSource)
                
                if let fetchedArtist = fetchedArtist {
                    self.unifiedArtist = fetchedArtist
                    self.artistImage = nil // Clear old image
                    await loadArtistImage(from: fetchedArtist.images)
                    print("✅ Found similar artist: \(fetchedArtist.name) from \(fetchedArtist.source.rawValue)")
                } else {
                    print("❌ No similar artist found")
                }
                
                self.isLoading = false
            } catch {
                self.isLoading = false
                print("❌ Failed to find similar artist: \(error)")
            }
        }
    }
    
    private func searchAlternativeArtistAutomatically() async {
        isLoading = true
        
        Task { @MainActor in
            do {
                let currentSource = unifiedArtist?.source
                
                // First try different source with same name
                print("🔄 Trying different source for: \(artist.name)")
                var fetchedArtist = try await HybridMusicAPIService.shared.searchAlternativeArtist(name: artist.name, currentSource: currentSource)
                
                // If that fails, try similar names with different sources
                if fetchedArtist == nil {
                    print("🔄 Trying similar names for: \(artist.name)")
                    fetchedArtist = try await HybridMusicAPIService.shared.searchSimilarArtist(originalName: artist.name, currentSource: currentSource)
                }
                
                if let fetchedArtist = fetchedArtist {
                    self.unifiedArtist = fetchedArtist
                    self.artistImage = nil // Clear old image
                    await loadArtistImage(from: fetchedArtist.images)
                    print("✅ Found alternative artist: \(fetchedArtist.name) from \(fetchedArtist.source.rawValue)")
                } else {
                    print("❌ No alternative artist found with different source or similar names")
                }
                
                self.isLoading = false
            } catch {
                self.isLoading = false
                print("❌ Failed to find alternative artist: \(error)")
            }
        }
    }
    
    private func loadArtistImage(from images: [UnifiedImage]) async {
        let sortedImages = images.sorted { a, b in
            let aSize = (a.width ?? 0) * (a.height ?? 0)
            let bSize = (b.width ?? 0) * (b.height ?? 0)
            return aSize > bSize
        }
        guard let best = sortedImages.first, let url = URL(string: best.url) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let img = UIImage(data: data) {
                await MainActor.run { self.artistImage = img }
            }
        } catch {
            print("❌ Failed to load artist image: \(error)")
        }
    }
}

struct ArtistTrackRowView: View {
    let track: Track
    let onTap: () -> Void
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var isFavorite = false
    @State private var showPlaylistDialog = false
    @State private var showDeleteConfirmation = false
    @State private var deleteSettings = DeleteSettings.load()
    @State private var artworkImage: UIImage?
    @State private var isPressed = false
    @State private var isMenuInteracting = false
    
    var body: some View {
        HStack {
            // Album artwork thumbnail
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 60, height: 60)
                
                if let image = artworkImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: "music.note")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.title3)
                    .fontWeight(.medium)
                    .lineLimit(1)
                
                if let duration = track.durationMs {
                    Text(formatDuration(duration))
                        .font(.body)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
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
                        NavigationLink(destination: ArtistDetailScreen(artist: artist, allTracks: allArtistTracks)) {
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
                    .frame(width: 30, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        isMenuInteracting = true
                    }
                    .onEnded { _ in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            isMenuInteracting = false
                        }
                    }
            )
        }
        .frame(height: 80)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            if !isMenuInteracting {
                withAnimation(.easeOut(duration: 0.1)) {
                    isPressed = true
                }
                onTap()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                    withAnimation(.easeOut(duration: 0.08)) {
                        isPressed = false
                    }
                }
            }
        }
        .onAppear {
            checkFavoriteStatus()
            loadArtwork()
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

struct ArtistAlbumCardView: View {
    let album: Album
    let tracks: [Track]
    @State private var artworkImage: UIImage?
    
    private var albumTracks: [Track] {
        tracks.filter { $0.albumId == album.id }
    }
    
    var body: some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.2))
                .frame(width: 120, height: 120)
                .overlay {
                    if let image = artworkImage {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 120, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Image(systemName: "music.note")
                            .font(.title2)
                            .foregroundColor(.secondary)
                    }
                }
            
            Text(album.title)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 120)
                .frame(minHeight: 32) // Min height for 2 lines alignment
                .foregroundColor(.primary)
        }
        .onAppear {
            loadAlbumArtwork()
        }
    }
    
    private func loadAlbumArtwork() {
        guard let firstTrack = albumTracks.first else { return }
        
        Task {
            let image = await ArtworkManager.shared.getArtwork(for: firstTrack)
            await MainActor.run {
                self.artworkImage = image
            }
        }
    }
}
