import SwiftUI
import GRDB

struct ArtistsScreen: View {
    let allTracks: [Track]
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var artists: [Artist] = []
    @State private var settings = DeleteSettings.load()
    @StateObject private var search = LibrarySearchState()
    /// One song per artist to take a picture from, built once per library.
    @State private var artworkTrackByArtist: [Int64: Track] = [:]
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isRegular: Bool { horizontalSizeClass == .regular }

    private var visibleArtists: [Artist] {
        let terms = LibrarySearch.terms(in: search.text)
        guard !terms.isEmpty else { return artists }
        return artists.filter { LibrarySearch.matches(terms: terms, in: $0.name) }
    }

    var body: some View {
        Group {
            if visibleArtists.isEmpty {
                if artists.isEmpty {
                    CosmosEmptyState(
                        systemImage: "music.microphone",
                        title: Localized.noArtistsFound,
                        message: Localized.artistsWillAppear
                    )
                } else {
                    ContentUnavailableView.search(text: search.text)
                }
            } else {
                // Portraits in a grid, as Music and Spotify show artists:
                // a face is quicker to find than a name in a long list.
                ScrollView {
                    TileGrid(minimum: isRegular ? 150 : 100, maximum: 200, spacing: isRegular ? Design.Spacing.xl : Design.Spacing.l, rowSpacing: isRegular ? Design.Spacing.xl : Design.Spacing.l) {
                        ForEach(visibleArtists, id: \.id) { artist in
                            NavigationLink(value: LibraryRoute.artist(id: artist.id, name: artist.name)) {
                                VStack(spacing: Design.Spacing.s) {
                                    ArtistAvatar(name: artist.name, artworkTrack: artist.id.flatMap { artworkTrackByArtist[$0] })
                                        .aspectRatio(1, contentMode: .fit)
                                        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                                    Text(artist.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .multilineTextAlignment(.center)
                                        .lineLimit(2)
                                }
                                .accessibilityElement(children: .combine)
                            }
                            .buttonStyle(PressableButtonStyle())
                        }
                    }
                    // The same side margin as Albums and Playlists.
                    .pagePadding()
                    .padding(.vertical, Design.Spacing.m)
                }
                .debugScrollToBottom()
            }
        }
        .background(ScreenSpecificBackgroundView(screen: .artists))
        .navigationTitle(settings.artistListMode.displayName)
        .navigationBarTitleDisplayMode(.large)
        .librarySearchField(search, prompt: Localized.searchArtists)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                LibrarySearchButton(state: search)
                artistModeMenu
            }
            .cosmosPlainBackground()
        }
        .onAppear {
            loadArtists()
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
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LibraryNeedsRefresh"))) { _ in
            loadArtists()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cosmosSettingsDidChange)) { _ in
            let previousMode = settings.artistListMode
            settings = DeleteSettings.load()
            if settings.artistListMode != previousMode { loadArtists() }
        }
    } // end body

    /// Switches between listing album artists and every credited artist.
    /// It lives in the toolbar rather than in Settings because the difference
    /// is only meaningful while looking at this list.
    private var artistModeMenu: some View {
        Menu {
            Picker(selection: Binding(
                get: { settings.artistListMode },
                set: { mode in
                    settings.artistListMode = mode
                    settings.save()
                    loadArtists()
                }
            )) {
                ForEach(ArtistListMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
        } label: {
            Label(settings.artistListMode.displayName, systemImage: "line.3.horizontal.decrease")
        }
    }

    private func loadArtists() {
        let signpost = Perf.begin("Artists load")
        defer { Perf.end("Artists load", signpost) }
        do {
            artists = try appCoordinator.databaseManager.getBrowsableArtists(mode: settings.artistListMode)
        } catch {
            print("Failed to load artists: \(error)")
        }
    }
}

struct ArtistDetailScreen: View {

    let artist: Artist
    let allTracks: [Track]
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @StateObject private var hybridAPI = HybridMusicAPIService.shared
    @ObservedObject private var theme = ThemeStore.shared
    @State private var unifiedArtist: UnifiedArtist?
    @State private var isLoading = false
    @State private var artistImage: UIImage?
    @State private var showFullProfile = false
    @State private var settings = DeleteSettings.load()
    @State private var isBulkMode = false
    @State private var selectedTracks: Set<String> = []
    /// Loaded once per appearance and library change. This was a computed
    /// property that queried the database every time it was read - several
    /// times per render.
    @State private var loadedTracks: [Track] = []
    @State private var artistAlbums: [Album] = []
    @State private var artworkTrackByAlbum: [Int64: Track] = [:]
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isRegular: Bool { horizontalSizeClass == .regular }

    private var playerEngine: PlayerEngine {
        appCoordinator.playerEngine
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

    private var artistTracks: [Track] {
        // Filter out incompatible formats when connected to CarPlay
        guard carPlayState.isConnected else { return loadedTracks }
        return loadedTracks.filter { track in
            let ext = URL(fileURLWithPath: track.path).pathExtension.lowercased()
            let incompatibleFormats = ["ogg", "oga", "opus", "dsf", "dff"]
            return !incompatibleFormats.contains(ext)
        }
    }

    private var hasRichHeader: Bool {
        unifiedArtist != nil && !isLoading
    }

    private var rowContextIdentity: String {
        "\(artistTracks.count)-\(artistTracks.first?.stableId ?? "")|\(isBulkMode)"
    }

    var body: some View {
        let tracks = artistTracks

        List {
            Section {
                Group {
                    if let unifiedArtist, !isLoading {
                        richHeader(unifiedArtist)
                    } else {
                        simpleHeader
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if !artistAlbums.isEmpty {
                Section {
                    albumsShelf
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } header: {
                    // On the shelf's and the Songs title's margin; the
                    // header's own sat a few points further in on iPad.
                    SectionTitle(Localized.albums)
                        .pageRowInsets(top: Design.Spacing.s, bottom: Design.Spacing.s, isActive: isRegular)
                }
                .headerProminence(.increased)
            }

            if !tracks.isEmpty {
                Section {
                    // A row, not the pinned section header: see PlaylistDetailView.
                    SectionTitle(title: Localized.songs) {
                        Text(Localized.songsCount(tracks.count))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .songsTitleRow()
                    ForEach(tracks, id: \.stableId) { track in
                        HStack(spacing: 0) {
                            if isBulkMode {
                                TrackSelectionIndicator(
                                    isSelected: selectedTracks.contains(track.stableId),
                                    accentColor: settings.backgroundColorChoice.color,
                                    onTap: { toggleSelection(track) }
                                )
                                .padding(.leading, Design.Spacing.s)
                            }

                            LiveTrackRow(
                                track: track,
                                artistName: nil,
                                showsDuration: true,
                                showsArtistLink: false,
                                showsArtist: false,
                                onEnterBulkMode: { beginSelection(with: track) },
                                contextIdentity: rowContextIdentity
                            ) {
                                // While selecting, a tap toggles instead of playing.
                                if isBulkMode {
                                    toggleSelection(track)
                                } else {
                                    Task { await playerEngine.playTrack(track, queue: tracks) }
                                }
                            }
                            .onLongPressGesture(minimumDuration: 0.5) {
                                beginSelection(with: track)
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
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(ScreenSpecificBackgroundView(screen: .artistDetail))
        // The photo runs up under the navigation bar, as it always has - on
        // a phone. iPad's bar is two rows (tab bar, then title) and hid the
        // top third of the photo, the face with it, under a white fade.
        .ignoresSafeArea(.container, edges: hasRichHeader && !isRegular ? .top : [])
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTitleDisplayMode(.inline)
        .trackBulkActions(
            tracks: artistTracks,
            isBulkMode: $isBulkMode,
            selectedTracks: $selectedTracks
        )
        .onAppear {
            loadLocalData()
            loadArtistData()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LibraryNeedsRefresh"))) { _ in
            loadLocalData()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cosmosSettingsDidChange)) { _ in
            settings = DeleteSettings.load()
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

    // MARK: - Headers

    private func richHeader(_ unifiedArtist: UnifiedArtist) -> some View {
        VStack(spacing: Design.Spacing.l) {
            // iPad: taller, and cropped from the top. A screen-wide band
            // 340 high showed a portrait photo's chest, the face cut off.
            Color.clear
                .frame(height: isRegular ? 420 : 340)
                .overlay {
                    if let artistImage {
                        Image(uiImage: artistImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isRegular ? .top : .center)
                    } else {
                        ZStack {
                            theme.accent.opacity(0.18)
                            Image(systemName: "music.microphone")
                                .font(.system(size: 60))
                                .foregroundStyle(theme.accent.opacity(0.6))
                        }
                    }
                }
                .clipped()
                .overlay(
                    LinearGradient(
                        colors: [.clear, .clear, .black.opacity(0.35), .black.opacity(0.7)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(alignment: .bottomLeading) {
                    Text(artist.name)
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                        .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                        .padding(.horizontal, Design.Spacing.l + 4)
                        .padding(.bottom, Design.Spacing.l)
                        .accessibilityAddTraits(.isHeader)
                }
                .overlay(alignment: .topTrailing) {
                    if unifiedArtist.source == .spotify {
                        Image("SpotifyWhite")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 21, height: 21)
                            // Clear of the bar the photo runs under on a phone.
                            .padding(.top, isRegular ? Design.Spacing.l : 60)
                            .padding(.trailing, 20)
                            .accessibilityLabel(Localized.dataProvidedBy("Spotify"))
                    }
                }

            VStack(alignment: .leading, spacing: Design.Spacing.l) {
                // A photo credit alone still needs somewhere to be shown.
                if !unifiedArtist.profile.isEmpty || unifiedArtist.imagePageURL != nil {
                    profileSection(unifiedArtist)
                }

                // The width they have on an album page; screen-wide on
                // iPad they were two long bars.
                PlayShuffleButtons(isDisabled: artistTracks.isEmpty, onPlay: playAll, onShuffle: shuffleAll)
                    .frame(maxWidth: isRegular ? 380 : .infinity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .pagePadding()
            .padding(.bottom, Design.Spacing.s)
        }
    }

    private var simpleHeader: some View {
        VStack(spacing: Design.Spacing.l) {
            ArtistAvatar(name: artist.name, artworkTrack: loadedTracks.first)
                .frame(width: 160, height: 160)
                .shadow(color: .black.opacity(0.2), radius: 14, y: 8)
                .overlay {
                    if isLoading {
                        ProgressView()
                            .offset(y: 90)
                    }
                }

            Text(artist.name)
                .font(.title.weight(.bold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            PlayShuffleButtons(isDisabled: artistTracks.isEmpty, onPlay: playAll, onShuffle: shuffleAll)
                .frame(maxWidth: isRegular ? 380 : .infinity)
        }
        .frame(maxWidth: .infinity)
        .pagePadding()
        .padding(.vertical, Design.Spacing.l)
    }

    private func profileSection(_ unifiedArtist: UnifiedArtist) -> some View {
        VStack(alignment: .leading, spacing: Design.Spacing.s) {
            if !unifiedArtist.profile.isEmpty {
                // Expanded, an on-device summary gives way to the full text
                // it was made from.
                Text(showFullProfile ? (unifiedArtist.fullBio ?? unifiedArtist.profile) : unifiedArtist.profile)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(showFullProfile ? nil : 3)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.3)) { showFullProfile.toggle() }
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(showFullProfile ? "" : Localized.seeAll)

                // Wikipedia's licence asks for its text to be credited with a
                // link, so the credit stays visible while the bio is collapsed.
                bioCredit(unifiedArtist)
            }

            if showFullProfile || unifiedArtist.profile.isEmpty {
                VStack(alignment: .leading, spacing: Design.Spacing.s) {
                    if let photoCredit = photoCredit(unifiedArtist) {
                        photoCredit
                    }

                    if unifiedArtist.source == .spotify {
                        HStack(spacing: Design.Spacing.xs) {
                            Text(Localized.dataProvidedBy("Spotify"))
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if let spotifyURL = unifiedArtist.spotifyURL ?? unifiedArtist.spotifyArtist?.externalUrls.spotify,
                               let url = URL(string: spotifyURL) {
                                Link(Localized.openSpotify, destination: url)
                                    .font(.caption)
                                    .foregroundStyle(theme.accent)
                            }
                        }
                    }

                    // Show "Wrong artist?" button in expanded profile
                    Button {
                        Task {
                            await searchAlternativeArtistAutomatically()
                        }
                    } label: {
                        Label(Localized.wrongArtist, systemImage: "questionmark.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, Design.Spacing.xs)
            }
        }
    }

    @ViewBuilder
    private func bioCredit(_ unifiedArtist: UnifiedArtist) -> some View {
        // Spotify's sentence is credited with its logo and "Data provided by".
        if let source = unifiedArtist.bioSource, source != .spotify {
            HStack(spacing: Design.Spacing.xs) {
                let label = String(format: Localized.artistInfoSource, source.displayName)
                if let page = unifiedArtist.bioURL, let url = URL(string: page) {
                    Link(label, destination: url)
                        .font(.caption)
                        .foregroundStyle(theme.accent)
                } else {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if unifiedArtist.bioIsSummarized {
                    Text("· \(Localized.artistBioSummarized)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Commons photos are CC BY-SA too; the credit links the file page,
    /// which names the photographer and licence.
    private func photoCredit(_ unifiedArtist: UnifiedArtist) -> AnyView? {
        guard let source = unifiedArtist.imageSource, source != .spotify,
              let page = unifiedArtist.imagePageURL, let url = URL(string: page) else { return nil }
        let name = source == .wikipedia ? "Wikimedia Commons" : source.displayName
        return AnyView(
            Link(String(format: Localized.artistPhotoSource, name), destination: url)
                .font(.caption)
                .foregroundStyle(theme.accent)
        )
    }

    private var albumsShelf: some View {
        ShelfScrollView {
            LazyHStack(alignment: .top, spacing: Design.Spacing.l) {
                ForEach(artistAlbums, id: \.id) { album in
                    if let albumId = album.id {
                        NavigationLink(value: LibraryRoute.album(id: albumId)) {
                            AlbumTileView(
                                album: album,
                                artworkTrack: artworkTrackByAlbum[albumId],
                                subtitle: album.year.flatMap { $0 > 0 ? String($0) : nil }
                            )
                            // Home's shelf size on iPad.
                            .frame(width: isRegular ? 180 : 140)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .pagePadding()
            .padding(.vertical, Design.Spacing.xs)
        }
        .clipsShelfSides()
    }

    // MARK: - Actions

    private func playAll() {
        let queue = artistTracks
        guard let first = queue.first else { return }
        Task { await playerEngine.playTrack(first, queue: queue) }
    }

    private func shuffleAll() {
        let shuffled = artistTracks.shuffled()
        guard let first = shuffled.first else { return }
        Task { await playerEngine.playTrack(first, queue: shuffled) }
    }

    // MARK: - Data Loading

    private func loadLocalData() {
        let signpost = Perf.begin("Artist page load")
        defer { Perf.end("Artist page load", signpost) }
        if let artistId = artist.id,
           let databaseTracks = try? appCoordinator.databaseManager.getTracksByArtistId(artistId) {
            loadedTracks = databaseTracks
        } else {
            loadedTracks = allTracks.filter { $0.artistId == artist.id }
        }

        guard let artistId = artist.id else {
            artistAlbums = []
            return
        }
        artistAlbums = (try? appCoordinator.databaseManager.getAlbumsByArtistId(artistId)) ?? []

        // Album covers come from the album's own songs, which on a
        // compilation need not be by this artist.
        var index: [Int64: Track] = [:]
        for album in artistAlbums {
            guard let albumId = album.id else { continue }
            if let track = loadedTracks.first(where: { $0.albumId == albumId })
                ?? (try? appCoordinator.databaseManager.getTracksByAlbumId(albumId))?.first {
                index[albumId] = track
            }
        }
        artworkTrackByAlbum = index
    }

    private func loadArtistData() {
        guard unifiedArtist == nil && !isLoading else { return }
        isLoading = true
        Task { @MainActor in
            do {
                // The library's album titles tell namesakes apart.
                let albumHints = artistAlbums.map(\.title)
                let fetchedArtist = try await HybridMusicAPIService.shared.searchArtist(name: artist.name, albumHints: albumHints)
                self.unifiedArtist = fetchedArtist
                self.isLoading = false
                if let fetchedArtist = fetchedArtist {
                    await loadArtistImage(from: fetchedArtist.images)
                    await refineArtistData(fetchedArtist, albumHints: albumHints)
                }
            } catch {
                self.isLoading = false
                print("❌ Failed to load artist data: \(error)")
            }
        }
    }

    /// With Apple Intelligence, a second look that may settle namesakes or
    /// shorten the bio. The page already shows the result above, so this
    /// only ever replaces it in place, and does nothing without the model.
    private func refineArtistData(_ current: UnifiedArtist, albumHints: [String]) async {
        guard let refined = await HybridMusicAPIService.shared.refineWithOnDeviceModel(
            name: artist.name, artist: current, albumHints: albumHints, userInitiated: true
        ) else { return }
        // "Wrong artist?" may have replaced the artist in the meantime.
        guard unifiedArtist?.id == current.id, unifiedArtist?.musicBrainzID == current.musicBrainzID else { return }
        let photoChanged = refined.images.first?.url != current.images.first?.url
        withAnimation(.easeInOut(duration: 0.3)) { unifiedArtist = refined }
        if photoChanged {
            artistImage = nil
            await loadArtistImage(from: refined.images)
        }
    }

    private func searchAlternativeArtistAutomatically() async {
        isLoading = true

        Task { @MainActor in
            do {
                let current = unifiedArtist
                let albumHints = artistAlbums.map(\.title)

                // First try different source with same name
                print("🔄 Trying different source for: \(artist.name)")
                var fetchedArtist = try await HybridMusicAPIService.shared.searchAlternativeArtist(name: artist.name, current: current, albumHints: albumHints)

                // If that fails, try similar names with different sources
                if fetchedArtist == nil {
                    print("🔄 Trying similar names for: \(artist.name)")
                    fetchedArtist = try await HybridMusicAPIService.shared.searchSimilarArtist(originalName: artist.name, current: current)
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
                // So Search and the lists show the same photo.
                await ArtistPhotoStore.shared.store(data, for: artist.name)
            }
        } catch {
            print("❌ Failed to load artist image: \(error)")
        }
    }
}
