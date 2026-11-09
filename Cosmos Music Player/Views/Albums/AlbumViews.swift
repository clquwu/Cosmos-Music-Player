import SwiftUI
import GRDB

/// How the Albums screen orders its grid; remembered between launches.
enum AlbumSortOption: String, CaseIterable {
    case title
    case artist
    case releaseOldest
    case releaseNewest

    var localizedString: String {
        switch self {
        case .title: return Localized.sortNameAZ
        case .artist: return Localized.sortArtistAZ
        case .releaseOldest: return Localized.sortReleaseOldest
        case .releaseNewest: return Localized.sortReleaseNewest
        }
    }
}

struct AlbumsScreen: View {
    let allTracks: [Track]
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var albums: [Album] = []
    @StateObject private var search = LibrarySearchState()
    @State private var artistNamesById: [Int64: String] = [:]
    /// The track each album's artwork is read from, built once per library
    /// change. Each tile used to filter the whole library for its own tracks.
    @State private var artworkTrackByAlbum: [Int64: Track] = [:]
    /// Each album's release year: its own tag, else the earliest year among
    /// its songs - many files carry the year per track only.
    @State private var yearByAlbum: [Int64: Int] = [:]
    @AppStorage("cosmos.albumSort") private var sortOption: AlbumSortOption = .title

    private var sortedAlbums: [Album] {
        switch sortOption {
        case .title:
            return albums
        case .artist:
            return albums.sorted { a, b in
                let order = (artistName(for: a) ?? "").localizedStandardCompare(artistName(for: b) ?? "")
                if order != .orderedSame { return order == .orderedAscending }
                return releaseOrder(a, b, newestFirst: false)
            }
        case .releaseOldest:
            return albums.sorted { releaseOrder($0, $1, newestFirst: false) }
        case .releaseNewest:
            return albums.sorted { releaseOrder($0, $1, newestFirst: true) }
        }
    }

    /// By year, albums without one last; same year by artist, then title.
    private func releaseOrder(_ a: Album, _ b: Album, newestFirst: Bool) -> Bool {
        let yearA = a.id.flatMap { yearByAlbum[$0] }
        let yearB = b.id.flatMap { yearByAlbum[$0] }
        switch (yearA, yearB) {
        case let (x?, y?) where x != y: return newestFirst ? x > y : x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: break
        }
        let order = (artistName(for: a) ?? "").localizedStandardCompare(artistName(for: b) ?? "")
        if order != .orderedSame { return order == .orderedAscending }
        return a.title.localizedStandardCompare(b.title) == .orderedAscending
    }

    private var visibleAlbums: [Album] {
        let terms = LibrarySearch.terms(in: search.text)
        guard !terms.isEmpty else { return sortedAlbums }
        return sortedAlbums.filter { album in
            // Match the artist too, so "daft punk" finds their albums without
            // the user having to remember an album title.
            LibrarySearch.matches(terms: terms, in: album.title, artistName(for: album))
        }
    }

    private func artistName(for album: Album) -> String? {
        album.albumArtist ?? album.artistId.flatMap { artistNamesById[$0] }
    }

    var body: some View {
        // Once per pass: it sorts (by artist or year) and filters every album,
        // and was evaluated twice - for the empty check and for the grid.
        let visibleAlbums = self.visibleAlbums
        Group {
            if visibleAlbums.isEmpty {
                if albums.isEmpty {
                    CosmosEmptyState(
                        systemImage: "square.stack",
                        title: Localized.noAlbumsFound,
                        message: Localized.albumsWillAppear
                    )
                } else {
                    ContentUnavailableView.search(text: search.text)
                }
            } else {
                ScrollView {
                    TileGrid(minimum: Design.Size.gridTileMinWidth, maximum: 260, spacing: Design.Spacing.l, rowSpacing: Design.Spacing.xl) {
                        ForEach(visibleAlbums, id: \.id) { album in
                            if let albumId = album.id {
                                NavigationLink(value: LibraryRoute.album(id: albumId)) {
                                    AlbumTileView(
                                        album: album,
                                        artworkTrack: artworkTrackByAlbum[albumId],
                                        subtitle: artistName(for: album)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.vertical, Design.Spacing.l)
                    .pagePadding()
                }
            }
        }
        .background(ScreenSpecificBackgroundView(screen: .albums))
        .navigationTitle(Localized.albums)
        .navigationBarTitleDisplayMode(.large)
        .librarySearchField(search, prompt: Localized.searchAlbums)
        .toolbar {
            // Search first, then sort, in the order Songs, Artists and
            // Playlists show them.
            ToolbarItem(placement: .topBarTrailing) {
                LibrarySearchButton(state: search)
            }
            .cosmosPlainBackground()
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker(selection: $sortOption) {
                        ForEach(AlbumSortOption.allCases, id: \.self) { option in
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
            .cosmosPlainBackground()
        }
        .onAppear(perform: loadAlbums)
        .task(id: TrackSearchIndex.identity(for: allTracks)) {
            indexArtworkTracks()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("LibraryNeedsRefresh"))) { _ in
            loadAlbums()
        }
    }

    private func indexArtworkTracks() {
        var index: [Int64: Track] = [:]
        var trackYears: [Int64: Int] = [:]
        for track in allTracks {
            guard let albumId = track.albumId else { continue }
            if let year = track.year {
                trackYears[albumId] = min(trackYears[albumId] ?? year, year)
            }
            // Prefer the first song of the first disc, which is usually the
            // one that carries the cover.
            if let existing = index[albumId] {
                let existingKey = ((existing.discNo ?? 1), (existing.trackNo ?? Int.max))
                let candidateKey = ((track.discNo ?? 1), (track.trackNo ?? Int.max))
                if candidateKey < existingKey { index[albumId] = track }
            } else {
                index[albumId] = track
            }
        }
        artworkTrackByAlbum = index
        yearByAlbum = trackYears
        for album in albums {
            if let id = album.id, let year = album.year, (1000...9999).contains(year) {
                yearByAlbum[id] = year
            }
        }
    }

    private func loadAlbums() {
        let signpost = Perf.begin("Albums load")
        defer { Perf.end("Albums load", signpost) }
        do {
            albums = try appCoordinator.getAllAlbums()
            artistNamesById = try DatabaseManager.shared.getAllArtistNamesById()
            indexArtworkTracks()
        } catch {
            print("Failed to load albums: \(error)")
        }
    }
}

/// An album in a grid or on a shelf: cover, title, artist.
struct AlbumTileView: View {
    let album: Album
    let artworkTrack: Track?
    var subtitle: String? = nil
    /// Shows a play button on the cover that plays the whole album.
    var onPlay: (() -> Void)? = nil
    @State private var artworkImage: UIImage?

    private var resolvedSubtitle: String? {
        if let subtitle, !subtitle.isEmpty { return subtitle }
        return album.albumArtist
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.xs + 2) {
            ArtworkView(image: artworkImage, cornerRadius: Design.Radius.artwork, placeholderSymbol: "opticaldisc")
                .overlay(alignment: .bottomTrailing) {
                    if let onPlay {
                        TilePlayButton(action: onPlay)
                            .padding(Design.Spacing.xs)
                    }
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(album.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let resolvedSubtitle {
                    Text(resolvedSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: onPlay == nil ? .combine : .contain)
        .task(id: artworkTrack?.stableId) {
            loadAlbumArtwork()
        }
        .reloadsArtwork(for: artworkTrack?.stableId) { loadAlbumArtwork() }
    }

    private func loadAlbumArtwork() {
        guard let artworkTrack else { return }
        Task {
            artworkImage = await ArtworkManager.shared.getThumbnail(for: artworkTrack, maxPixelSize: 512)
        }
    }
}

struct AlbumDetailScreen: View {

    let album: Album
    let allTracks: [Track]
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var artworkImage: UIImage?
    @State private var settings = DeleteSettings.load()
    @State private var albumTracks: [Track] = []
    @State private var artistNameCache: [Int64: String] = [:]
    @State private var trackArtistNames: [String: String] = [:]
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

    private var hasKnownArtist: Bool {
        album.artistId != nil || !(album.albumArtist ?? "").isEmpty
    }

    /// "2019 · 12 songs · 48 min"
    private var detailLine: String {
        var parts: [String] = []
        if let year = album.year, year > 0 { parts.append(String(year)) }
        parts.append(Localized.songsCountOnly(filteredAlbumTracks.count))
        if let length = DurationFormatter.totalLength(of: filteredAlbumTracks) { parts.append(length) }
        return parts.joined(separator: " · ")
    }

    /// Identity for the rows' Equatable check - see
    /// `TrackRowView.contextIdentity`. The tap handler captures the album's
    /// track list and the selection mode.
    private var rowContextIdentity: String {
        "\(filteredAlbumTracks.count)-\(filteredAlbumTracks.first?.stableId ?? "")|\(isBulkMode)"
    }

    var body: some View {
        DetailPage {
            DetailHeader(
                title: album.title,
                subtitle: albumArtist,
                // "Unknown Artist" is a placeholder, not a page.
                onSubtitleTap: hasKnownArtist ? {
                    AppRouter.shared.openArtist(id: album.artistId, name: albumArtist)
                } : nil,
                detail: detailLine,
                isPlayDisabled: filteredAlbumTracks.isEmpty,
                onPlay: {
                    if let first = filteredAlbumTracks.first {
                        Task {
                            await playerEngine.playTrack(first, queue: filteredAlbumTracks)
                        }
                    }
                },
                onShuffle: {
                    guard !filteredAlbumTracks.isEmpty else { return }
                    let shuffled = filteredAlbumTracks.shuffled()
                    Task {
                        await playerEngine.playTrack(shuffled[0], queue: shuffled)
                    }
                }
            ) {
                ArtworkView(image: artworkImage, cornerRadius: Design.Radius.artwork, placeholderSymbol: "opticaldisc")
            }
        } rows: {
            ForEach(groupedByDisc, id: \.discNumber) { disc in
                Section {
                    ForEach(Array(disc.tracks.enumerated()), id: \.element.stableId) { index, track in
                        let trackArtist = trackArtistNames[track.stableId]
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
                                // Only name the artist where it differs from the
                                // album's - a guest, or a compilation.
                                artistName: trackArtist,
                                leading: .number(track.trackNo ?? (index + 1)),
                                showsDuration: true,
                                showsAlbumLink: false,
                                showsArtist: trackArtist != nil && trackArtist != albumArtist,
                                onEnterBulkMode: { beginSelection(with: track) },
                                contextIdentity: rowContextIdentity
                            ) {
                                // While selecting, a tap toggles instead of playing.
                                if isBulkMode {
                                    toggleSelection(track)
                                } else {
                                    Task {
                                        await playerEngine.playTrack(track, queue: filteredAlbumTracks)
                                    }
                                }
                            }
                            .onLongPressGesture(minimumDuration: 0.5) {
                                beginSelection(with: track)
                            }
                        }
                        .songListRow(
                            track,
                            separatorLeading: (isBulkMode ? Design.Size.minTouch + Design.Spacing.s : 0)
                                + Design.Spacing.l + 28 + Design.Spacing.m,
                            swipeActionsEnabled: !isBulkMode
                        )
                    }
                } header: {
                    if hasMultipleDiscs {
                        Text(Localized.discNumber(disc.discNumber))
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                    }
                }
            }
        }
        .background(ArtworkBackground(image: artworkImage, line: HaloLine(for: .albumDetail)))
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTitleDisplayMode(.inline)
        .trackBulkActions(
            tracks: filteredAlbumTracks,
            isBulkMode: $isBulkMode,
            selectedTracks: $selectedTracks
        )
        .onAppear {
            loadArtistNameCache()
            loadAlbumTracks()
        }
        // albumTracks is @State loaded once, so without this a bulk delete left
        // the removed tracks on screen until the view was revisited.
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LibraryNeedsRefresh"))) { _ in
            loadAlbumTracks()
        }
        .task(id: albumTracks.first?.stableId) {
            loadAlbumArtwork()
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
        let signpost = Perf.begin("Album page load")
        defer { Perf.end("Album page load", signpost) }
        do {
            albumTracks = try appCoordinator.databaseManager.getTracksByAlbumId(albumId)
            let fallbackArtistIds = albumTracks.reduce(into: [String: Int64]()) { result, track in
                if let artistId = track.artistId {
                    result[track.stableId] = artistId
                }
            }
            trackArtistNames = (try? DatabaseManager.shared.getArtistDisplayNames(
                forTrackStableIds: albumTracks.map(\.stableId),
                fallbackArtistIdsByStableId: fallbackArtistIds
            )) ?? [:]
        } catch {
            print("Failed to load album tracks: \(error)")
        }
    }

    private func loadAlbumArtwork() {
        guard let first = filteredAlbumTracks.first else { return }
        Task {
            let image = await ArtworkManager.shared.getArtwork(for: first)
            await MainActor.run {
                artworkImage = image
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

struct ArtistDetailScreenWrapper: View {
    let artistName: String
    let allTracks: [Track]
    @State private var artist: Artist?

    var body: some View {
        Group {
            if let artist {
                ArtistDetailScreen(artist: artist, allTracks: allTracks)
            } else {
                ProgressView(Localized.loadingArtist)
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
