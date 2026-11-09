import SwiftUI
import GRDB

// MARK: - Listening history

/// The songs played most recently, newest first, kept in UserDefaults.
///
/// The database records when a *playlist* was last played but not songs, and
/// a Recently Played shelf needs songs. A capped list of ids is all it takes,
/// and keeping it out of the database means no migration.
@MainActor
final class ListeningHistory: ObservableObject {
    static let shared = ListeningHistory()

    @Published private(set) var recentTrackIds: [String]
    /// Albums, playlists, artists and mixes recently opened or played from,
    /// newest first - Home's way back into them.
    @Published private(set) var recentSources: [LibraryRoute]

    private static let storageKey = "cosmos.recentlyPlayedTrackIds"
    private static let sourcesKey = "cosmos.recentSources"
    private static let capacity = 60
    private static let sourceCapacity = 12

    private init() {
        recentTrackIds = UserDefaults.standard.stringArray(forKey: Self.storageKey) ?? []
        recentSources = (UserDefaults.standard.stringArray(forKey: Self.sourcesKey) ?? []).compactMap(Self.decode)
    }

    func clear() {
        recentTrackIds = []
        recentSources = []
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
        UserDefaults.standard.removeObject(forKey: Self.sourcesKey)
    }

    func recordSource(_ route: LibraryRoute) {
        guard Self.encode(route) != nil, recentSources.first != route else { return }
        var sources = recentSources
        sources.removeAll { $0 == route }
        sources.insert(route, at: 0)
        if sources.count > Self.sourceCapacity {
            sources.removeLast(sources.count - Self.sourceCapacity)
        }
        recentSources = sources
        UserDefaults.standard.set(sources.compactMap(Self.encode), forKey: Self.sourcesKey)
    }

    private static func encode(_ route: LibraryRoute) -> String? {
        switch route {
        case .album(let id): return "album:\(id)"
        case .playlist(let id): return "playlist:\(id)"
        case .artist(let id?, let name): return "artist:\(id):\(name)"
        case .mix(let id): return "mix:\(id)"
        case .allSongs: return "songs:"
        case .likedSongs: return "liked:"
        default: return nil
        }
    }

    private static func decode(_ string: String) -> LibraryRoute? {
        // Empty parts kept: "songs:" has nothing after its colon, and
        // dropping it lost Songs from Start Listening on every relaunch.
        let parts = string.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }
        switch parts[0] {
        case "album": return Int64(parts[1]).map { .album(id: $0) }
        case "playlist": return Int64(parts[1]).map { .playlist(id: $0) }
        case "artist": return parts.count == 3 ? Int64(parts[1]).map { .artist(id: $0, name: parts[2]) } : nil
        case "mix": return .mix(id: parts.dropFirst().joined(separator: ":"))
        case "songs": return .allSongs
        case "liked": return .likedSongs
        default: return nil
        }
    }

    func record(_ track: Track) {
        guard recentTrackIds.first != track.stableId else { return }
        var ids = recentTrackIds
        ids.removeAll { $0 == track.stableId }
        ids.insert(track.stableId, at: 0)
        if ids.count > Self.capacity {
            ids.removeLast(ids.count - Self.capacity)
        }
        recentTrackIds = ids
        UserDefaults.standard.set(ids, forKey: Self.storageKey)
    }
}

// MARK: - Quick play

/// One-tap playback of a whole collection, shared by the play buttons on
/// Home, Library and Search tiles.
@MainActor
enum QuickPlay {
    static func album(_ albumId: Int64) {
        ListeningHistory.shared.recordSource(.album(id: albumId))
        let tracks = (try? DatabaseManager.shared.getTracksByAlbumId(albumId)) ?? []
        start(tracks, source: "album")
    }

    static func playlist(_ playlistId: Int64) {
        ListeningHistory.shared.recordSource(.playlist(id: playlistId))
        let ids = ((try? DatabaseManager.shared.getPlaylistItems(playlistId: playlistId)) ?? []).map(\.trackStableId)
        let tracks = (try? DatabaseManager.shared.getTracksByStableIdsPreservingOrder(ids)) ?? []
        try? AppCoordinator.shared.updatePlaylistLastPlayed(playlistId: playlistId)
        start(tracks, source: "playlist")
    }

    /// An artist's songs, shuffled.
    static func artistMix(_ artistId: Int64) {
        let tracks = (try? DatabaseManager.shared.getTracksByArtistId(artistId)) ?? []
        start(tracks.shuffled(), source: "artist")
    }

    static func liked(from library: [Track]) {
        let favorites = Set((try? AppCoordinator.shared.getFavorites()) ?? [])
        start(library.filter { favorites.contains($0.stableId) }, source: "liked")
    }

    static func start(_ tracks: [Track], source: String? = nil) {
        guard let first = tracks.first else { return }
        if let source { ListeningLog.shared.tagQueue(source, tracks: tracks) }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task { await AppCoordinator.shared.playTrack(first, queue: tracks) }
    }
}

/// The play button on artwork tiles: a small dark disc with a white glyph,
/// as Music draws it - it sits on any cover without fighting it.
struct TilePlayButton: View {
    var size: CGFloat = 32
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "play.fill")
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(.white)
                .offset(x: size * 0.03)
                .frame(width: size, height: size)
                .background(Color.black.opacity(0.55), in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                .frame(width: max(size, Design.Size.minTouch), height: max(size, Design.Size.minTouch))
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(Localized.play)
    }
}

// MARK: - Home

/// The Home tab. Built like the big music apps' home screens, from what is
/// in the library and what has been played:
/// a quick-access grid, songs to start from, then artwork shelves - each
/// with a play button so a whole album, playlist or mix starts in one tap.
/// The mini player already shows what is playing, so Home does not repeat it.
struct HomeView: View {
    let tracks: [Track]
    @Binding var showSettings: Bool
    let onManualSync: (() async -> (before: Int, after: Int))?

    @EnvironmentObject private var appCoordinator: AppCoordinator
    @ObservedObject private var history = ListeningHistory.shared
    @ObservedObject private var theme = ThemeStore.shared
    @ObservedObject private var mixes = MixStore.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.pageMargin) private var pageMargin

    @State private var startTracks: [Track] = []
    @State private var isSyncing = false
    @State private var startSources: [StartSource] = []
    @State private var recentlyPlayed: [ShelfAlbum] = []
    @State private var recentlyAdded: [ShelfAlbum] = []
    @State private var rediscover: [ShelfAlbum] = []
    @State private var playlists: [ShelfPlaylist] = []
    @State private var topArtists: [ShelfArtist] = []
    @State private var artistNames: [String: String] = [:]
    /// Home is on screen. A song change while it is not only marks the
    /// recent shelves stale; they refresh when Home shows again.
    @State private var isVisible = false
    @State private var recentIsStale = false
    @State private var recentRefresh: Task<Void, Never>?

    /// An album on a shelf, with the track its artwork is read from.
    struct ShelfAlbum: Identifiable {
        let album: Album
        let artworkTrack: Track?
        var id: Int64 { album.id ?? -1 }
    }

    struct ShelfPlaylist: Identifiable {
        let playlist: Playlist
        let tracks: [Track]
        var id: Int64 { playlist.id ?? -1 }
    }

    /// A way back into something: Liked Songs, or an album, playlist,
    /// artist or mix recently opened or played from.
    struct StartSource: Identifiable {
        enum Kind {
            case songs(count: Int)
            case liked(count: Int)
            case playlist(ShelfPlaylist)
            case album(ShelfAlbum)
            case artist(ShelfArtist)
            case mix(Mix)
        }
        let route: LibraryRoute
        let kind: Kind
        var id: LibraryRoute { route }
    }

    /// One cell of Start Listening: a place, then songs.
    enum StartItem: Identifiable {
        case source(StartSource)
        case song(Track)

        var id: String {
            switch self {
            case .source(let source): return "source-\(source.route)"
            case .song(let track): return "song-\(track.stableId)"
            }
        }
    }

    /// Three pages of a 3 x 3 grid: 27 tiles, places first, then songs.
    static let startPageSize = 9
    static let startPageCount = 3

    /// Full pages only: three 3 x 3 pages (27), or two 4 x 3 pages (24)
    /// where the shelf is as wide as an iPad's.
    ///
    /// Read from the shelf's width, not the size class: iPhone Duo's inner
    /// screen is "regular" yet, with the sidebar open or the page on one half
    /// of the fold, only 360 to 640 points wide, and four columns made a
    /// third smaller left tiles 60 to 100 points across with their titles
    /// cut to a syllable.
    private var startColumns: Int { startShelfWidth >= 700 ? 4 : 3 }
    private var startPages: Int { startColumns == 4 ? 2 : Self.startPageCount }
    private var startShelfWidth: CGFloat { shelfWidth - pageMargin * 2 }

    private var startItems: [StartItem] {
        let capacity = startColumns * 3 * startPages
        var items = startSources.map(StartItem.source) + startTracks.map(StartItem.song)
        // A small library has fewer songs than tiles: albums and artists
        // fill the rest, so every page is a full grid.
        if items.count < capacity {
            var routes = Set(startSources.map(\.route))
            let fillers = recentlyAdded.map { StartSource(route: .album(id: $0.id), kind: .album($0)) }
                + recentlyPlayed.map { StartSource(route: .album(id: $0.id), kind: .album($0)) }
                + topArtists.map { StartSource(route: .artist(id: $0.id, name: $0.artist.name), kind: .artist($0)) }
            for filler in fillers where items.count < capacity && routes.insert(filler.route).inserted {
                items.append(.source(filler))
            }
        }
        // Whole columns only: a part-filled last column is dropped.
        let whole = items.count >= capacity ? capacity : items.count - items.count % 3
        return Array(items.prefix(max(whole, min(items.count, 3))))
    }

    struct ShelfArtist: Identifiable {
        let artist: Artist
        let artworkTrack: Track?
        var id: Int64 { artist.id ?? -1 }
    }

    private var isRegular: Bool { horizontalSizeClass == .regular }
    private var tileWidth: CGFloat { fitted(minimum: isRegular ? 160 : 140) ?? (isRegular ? 200 : 148) }
    private var artistTileWidth: CGFloat { fitted(minimum: isRegular ? 120 : 96) ?? (isRegular ? 124 : 104) }

    /// The width the shelves have for their items, measured from the page.
    @State private var shelfWidth: CGFloat = 0

    /// The item width that fits a whole number of items at least `minimum`
    /// wide across the shelf, so none is cut at the edge - and a page swipe
    /// moves by whole items, leaving no gap at the end.
    /// Start Listening's tiles: whole tiles across the shelf, three on a
    /// phone, more on a wide screen.
    /// A phone's page fills the shelf's width; on a wider shelf the tiles are
    /// a third smaller - full width they were too big - and the next page
    /// shows beside it.
    private var startTileSide: CGFloat {
        let available = startShelfWidth
        guard available > 0 else { return 110 }
        let full = min(available / CGFloat(startColumns), 260)
        return available >= 500 ? full * 0.67 : full
    }

    private func fitted(minimum: CGFloat, spacing: CGFloat = Design.Spacing.l) -> CGFloat? {
        // The shelf's side margins, whatever the gap between items.
        let available = shelfWidth - pageMargin * 2
        guard available > minimum else { return nil }
        let count = max(1, Int((available + spacing) / (minimum + spacing)))
        return (available - spacing * CGFloat(count - 1)) / CGFloat(count)
    }

    var body: some View {
        ScrollView {
            if tracks.isEmpty {
                welcome
                    .containerRelativeFrame(.vertical, alignment: .center)
            } else {
                LazyVStack(alignment: .leading, spacing: Design.Spacing.xxl) {
                    if !startItems.isEmpty {
                        startListening
                    }

                    if !recentlyPlayed.isEmpty {
                        shelf(Localized.recentlyPlayed, seeAll: nil) {
                            ForEach(recentlyPlayed) { albumTile($0) }
                        }
                    }

                    if !mixes.madeForYou.isEmpty {
                        shelf(Localized.madeForYou, seeAll: nil) {
                            ForEach(mixes.madeForYou) { mix in
                                MixTile(mix: mix, width: tileWidth)
                            }
                        }
                    }

                    if !recentlyAdded.isEmpty {
                        shelf(Localized.recentlyAdded, seeAll: .albums) {
                            ForEach(recentlyAdded) { albumTile($0) }
                        }
                    }

                    // Moments in time when there are some; until the listening
                    // log and the library have history, albums not played lately.
                    if !mixes.moments.isEmpty {
                        shelf(Localized.rediscover, seeAll: nil) {
                            ForEach(mixes.moments) { mix in
                                MixTile(mix: mix, width: tileWidth)
                            }
                        }
                    } else if !rediscover.isEmpty {
                        shelf(Localized.rediscover, seeAll: nil) {
                            ForEach(rediscover) { albumTile($0) }
                        }
                    }

                    if !playlists.isEmpty {
                        shelf(Localized.playlists, seeAll: .playlists) {
                            ForEach(playlists) { playlistTile($0) }
                        }
                    }

                    if !topArtists.isEmpty {
                        shelf(Localized.yourArtists, seeAll: .artists) {
                            ForEach(topArtists) { artistTile($0) }
                        }
                    }
                }
                .padding(.top, Design.Spacing.s)
                .padding(.bottom, Design.Spacing.xl)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { shelfWidth = $0 }
            }
        }
        .debugScrollToBottom()
        .background(ScreenSpecificBackgroundView(screen: .library))
        .cosmosTabHeader(Localized.home)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                // Refresh, add, settings: the three things done from the top
                // of the app, within a thumb's reach of each other.
                if let onManualSync {
                    Button {
                        guard !isSyncing else { return }
                        isSyncing = true
                        Task {
                            _ = await onManualSync()
                            isSyncing = false
                        }
                    } label: {
                        if isSyncing {
                            ProgressView()
                        } else {
                            Label(Localized.syncLibrary, systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(isSyncing)
                }

                Button {
                    AppRouter.shared.requestImport()
                } label: {
                    Label(Localized.addSongs, systemImage: "plus")
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
            if let onManualSync {
                _ = await onManualSync()
            }
        }
        .task(id: TrackSearchIndex.identity(for: tracks)) {
            reload()
            #if DEBUG
            // -cosmosDebugSongMix 1 starts a song mix from the first Start
            // Listening song once the library is in, to time building one.
            if UserDefaults.standard.bool(forKey: "cosmosDebugSongMix"), let seed = startTracks.first {
                try? await Task.sleep(for: .seconds(2))
                _ = await mixes.playSongMix(from: seed)
            }
            #endif
        }
        .onChange(of: history.recentTrackIds) { _, _ in
            // Every song change lands here. Only what depends on it is
            // refreshed - the whole Home used to be rebuilt (the library,
            // every playlist's songs, top artists) on each track, even with
            // Home hidden behind another tab - and only once skipping
            // through songs settles.
            recentRefresh?.cancel()
            guard isVisible else { recentIsStale = true; return }
            recentRefresh = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                reloadRecent()
            }
        }
        .onAppear {
            isVisible = true
            if recentIsStale { reloadRecent() }
        }
        .onDisappear {
            isVisible = false
        }
        .onChange(of: history.recentSources) { _, _ in
            loadStartSources()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LibraryNeedsRefresh"))) { _ in
            reload()
        }
    }


    // MARK: Sections

    private var welcome: some View {
        CosmosEmptyState(
            systemImage: "music.note.house",
            title: Localized.welcomeTitle,
            message: Localized.welcomeMessage,
            actionTitle: Localized.addSongs
        ) {
            AppRouter.shared.requestImport()
        }
    }

    /// Songs to start from, in swipeable columns of four - the way Music
    /// shows top songs - so a phone shows a full card of them and an iPad
    /// shows two or three columns side by side.
    private var startListening: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.m) {
            SectionTitle(Localized.startListening)
                .pagePadding()

            // Pages of three rows of square tiles, titles on the cover as on
            // the mixes. The tiles in a page meet edge to edge, each keeping
            // its rounded corners; a swipe turns a whole page.
            let side = startTileSide
            let columns = startColumns
            let rows = 3
            let pages = stride(from: 0, to: startItems.count, by: columns * rows).map {
                Array(startItems[$0..<min($0 + columns * rows, startItems.count)])
            }
            ShelfScrollView {
                LazyHStack(alignment: .top, spacing: Design.Spacing.l) {
                    ForEach(pages.indices, id: \.self) { index in
                        LazyHGrid(rows: Array(repeating: GridItem(.fixed(side), spacing: 0), count: rows), spacing: 0) {
                            ForEach(pages[index]) { item in
                                startTile(item)
                                    .frame(width: side, height: side)
                            }
                        }
                        .frame(width: side * CGFloat(columns), alignment: .leading)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .shelfEdges()
        }
    }

    @ViewBuilder
    private func startTile(_ item: StartItem) -> some View {
        switch item {
        case .source(let source):
            StartSourceCell(source: source, showsTrailingIcon: isRegular, onPlay: { play(source) })
        case .song(let track):
            // A song on its own starts a mix grown from it, rather than its
            // album from the top.
            StartSongCell(track: track, artistName: artistNames[track.stableId], showsTrailingIcon: isRegular) {
                Task { await mixes.playSongMix(from: track) }
            }
        }
    }

    private func shelf<Content: View>(_ title: String, seeAll: LibraryRoute?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Design.Spacing.m) {
            SectionTitle(title: title) {
                if let seeAll {
                    NavigationLink(value: seeAll) {
                        // Plain text and a chevron in a soft primary: the
                        // accent was hard to see on the halo, a pill too heavy.
                        // Color.primary, not .primary: inside a link the
                        // hierarchical style resolves to the tint.
                        HStack(spacing: 3) {
                            Text(Localized.seeAll)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary.opacity(0.7))
                        .frame(minHeight: Design.Size.minTouch)
                        .contentShape(Rectangle())
                    }
                }
            }
            .pagePadding()

            ShelfScrollView {
                LazyHStack(alignment: .top, spacing: Design.Spacing.l) {
                    content()
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .shelfEdges()
        }
    }

    private func albumTile(_ item: ShelfAlbum) -> some View {
        NavigationLink(value: LibraryRoute.album(id: item.id)) {
            AlbumTileView(album: item.album, artworkTrack: item.artworkTrack, onPlay: { QuickPlay.album(item.id) })
                .frame(width: tileWidth)
        }
        .buttonStyle(PressableButtonStyle())
    }

    private func playlistTile(_ item: ShelfPlaylist) -> some View {
        NavigationLink(value: LibraryRoute.playlist(id: item.id)) {
            VStack(alignment: .leading, spacing: Design.Spacing.xs + 2) {
                PlaylistTileCover(playlist: item.playlist, tracks: item.tracks)
                    .overlay(alignment: .bottomTrailing) {
                        if !item.tracks.isEmpty {
                            TilePlayButton { QuickPlay.playlist(item.id) }
                                .padding(Design.Spacing.xs)
                        }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.playlist.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(Localized.songsCountOnly(item.tracks.count))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: tileWidth)
            .accessibilityElement(children: .contain)
        }
        .buttonStyle(PressableButtonStyle())
    }

    private func artistTile(_ item: ShelfArtist) -> some View {
        NavigationLink(value: LibraryRoute.artist(id: item.artist.id, name: item.artist.name)) {
            VStack(spacing: Design.Spacing.s) {
                ArtistAvatar(name: item.artist.name, artworkTrack: item.artworkTrack)
                    .frame(width: artistTileWidth, height: artistTileWidth)
                Text(item.artist.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(width: artistTileWidth)
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(PressableButtonStyle())
    }

    private func play(_ source: StartSource) {
        switch source.kind {
        case .songs: QuickPlay.start(tracks.shuffled(), source: "shuffle")
        case .liked: QuickPlay.liked(from: tracks)
        case .playlist(let item): QuickPlay.playlist(item.id)
        case .album(let item): QuickPlay.album(item.id)
        case .artist(let item): QuickPlay.artistMix(item.id)
        case .mix(let mix): mixes.play(mix)
        }
    }

    // MARK: Data

    /// Liked Songs first, then the three places most recently opened or
    /// played from - with the latest albums and playlists filling in for a
    /// new listener - so the first column of Start Listening is the way back
    /// into them.
    private func loadStartSources() {
        var sources: [StartSource] = []
        let likedCount = (try? appCoordinator.getFavorites().count) ?? 0
        if likedCount > 0 {
            sources.append(StartSource(route: .likedSongs, kind: .liked(count: likedCount)))
        }

        let database = DatabaseManager.shared
        let allPlaylists = (try? database.getAllPlaylists()) ?? []
        // Playlist songs already loaded for the Playlists shelf are reused:
        // each place used to read its playlist's songs again.
        let shelfTracks = Dictionary(playlists.map { ($0.id, $0.tracks) }, uniquingKeysWith: { first, _ in first })
        func resolve(_ route: LibraryRoute) -> StartSource? {
            switch route {
            case .album(let id):
                guard let album = try? database.read({ db in try Album.fetchOne(db, key: id) }) else { return nil }
                let artwork = tracks.first { $0.albumId == id && $0.hasArtwork } ?? tracks.first { $0.albumId == id }
                return StartSource(route: route, kind: .album(ShelfAlbum(album: album, artworkTrack: artwork)))
            case .playlist(let id):
                guard let playlist = allPlaylists.first(where: { $0.id == id }) else { return nil }
                let items = shelfTracks[id] ?? ((try? database.getTracksForPlaylists([id]))?[id] ?? [])
                return StartSource(route: route, kind: .playlist(ShelfPlaylist(playlist: playlist, tracks: items)))
            case .artist(let id?, let name):
                guard tracks.contains(where: { $0.artistId == id }) else { return nil }
                let artwork = tracks.first { $0.artistId == id && $0.hasArtwork }
                return StartSource(route: route, kind: .artist(ShelfArtist(artist: Artist(id: id, name: name), artworkTrack: artwork)))
            case .mix(let id):
                return mixes.mix(id: id).map { StartSource(route: route, kind: .mix($0)) }
            case .allSongs:
                return StartSource(route: route, kind: .songs(count: tracks.count))
            default:
                return nil
            }
        }

        var routes = history.recentSources
        routes += recentlyPlayed.map { LibraryRoute.album(id: $0.id) }
        routes += playlists.map { LibraryRoute.playlist(id: $0.id) }
        // Liked Songs is already pinned first.
        var seen: Set<LibraryRoute> = [.likedSongs]
        for route in routes where sources.count < 4 && seen.insert(route).inserted {
            if let source = resolve(route) { sources.append(source) }
        }
        startSources = sources
    }

    /// Refreshes only what a song change affects: Recently Played and Start
    /// Listening (with its places).
    private func reloadRecent() {
        let signpost = Perf.begin("Home reloadRecent")
        defer { Perf.end("Home reloadRecent", signpost) }
        recentIsStale = false
        let byId = Dictionary(tracks.map { ($0.stableId, $0) }, uniquingKeysWith: { first, _ in first })
        let recentTracks = history.recentTrackIds.compactMap { byId[$0] }
        var playedOrder: [Int64] = []
        var artworkTrack: [Int64: Track] = [:]
        for track in recentTracks {
            guard let albumId = track.albumId, !playedOrder.contains(albumId) else { continue }
            artworkTrack[albumId] = track
            playedOrder.append(albumId)
        }
        let shown = Array(playedOrder.prefix(12))
        let fetched = (try? DatabaseManager.shared.read { db in try Album.fetchAll(db, keys: shown) }) ?? []
        let albumsById = Dictionary(fetched.compactMap { album in album.id.map { ($0, album) } }, uniquingKeysWith: { first, _ in first })
        recentlyPlayed = shown.compactMap { id in albumsById[id].map { ShelfAlbum(album: $0, artworkTrack: artworkTrack[id]) } }
        loadStartTracks(recentTracks: recentTracks)
    }

    private func reload() {
        recentIsStale = false
        let signpost = Perf.begin("Home reload")
        defer {
            Perf.end("Home reload", signpost)
            if !tracks.isEmpty { Perf.endLaunchIfNeeded() }
        }
        Perf.measure("Mix rebuild (Home)") {
            mixes.rebuild(tracks: tracks)
        }
        let newestFirst = self.newestFirst
        let byId = Dictionary(tracks.map { ($0.stableId, $0) }, uniquingKeysWith: { first, _ in first })
        let recentTracks = history.recentTrackIds.compactMap { byId[$0] }

        // Recently played albums, newest first.
        var playedOrder: [Int64] = []
        var artworkTrack: [Int64: Track] = [:]
        for track in recentTracks {
            guard let albumId = track.albumId, !playedOrder.contains(albumId) else { continue }
            artworkTrack[albumId] = track
            playedOrder.append(albumId)
        }

        // Recently added albums: track ids grow with every insert.
        var addedOrder: [Int64] = []
        var albumFirstTrack: [Int64: Track] = [:]
        for track in newestFirst {
            guard let albumId = track.albumId else { continue }
            if albumFirstTrack[albumId] == nil {
                albumFirstTrack[albumId] = track
                addedOrder.append(albumId)
            }
        }

        let allAlbumIds = Array(Set(playedOrder + addedOrder))
        let albumsById: [Int64: Album] = {
            let fetched = (try? DatabaseManager.shared.read { db in try Album.fetchAll(db, keys: allAlbumIds) }) ?? []
            return Dictionary(fetched.compactMap { album in album.id.map { ($0, album) } }, uniquingKeysWith: { first, _ in first })
        }()
        func shelfAlbums(_ ids: [Int64]) -> [ShelfAlbum] {
            ids.compactMap { id in
                albumsById[id].map { ShelfAlbum(album: $0, artworkTrack: artworkTrack[id] ?? albumFirstTrack[id]) }
            }
        }

        recentlyPlayed = shelfAlbums(Array(playedOrder.prefix(12)))
        recentlyAdded = shelfAlbums(Array(addedOrder.prefix(12)))

        // Rediscover: albums not played lately, a different handful each day.
        let played = Set(playedOrder)
        var generator = SeededGenerator(seed: UInt64(Date().timeIntervalSince1970 / 86_400))
        rediscover = shelfAlbums(Array(addedOrder.filter { !played.contains($0) }.shuffled(using: &generator).prefix(12)))

        // Playlists, most recently played first.
        let recentPlaylists = Array(((try? appCoordinator.databaseManager.getAllPlaylists()) ?? []).prefix(12))
        // Every song, not just the four the cover needs: the card also
        // shows the playlist's song count. One query for all twelve rather
        // than two per playlist.
        let tracksByPlaylist = (try? appCoordinator.databaseManager.getTracksForPlaylists(recentPlaylists.compactMap(\.id))) ?? [:]
        playlists = recentPlaylists.compactMap { playlist in
            guard let playlistId = playlist.id, let tracks = tracksByPlaylist[playlistId] else { return nil }
            // Empty playlists have nothing to offer on Home; Library still
            // lists them.
            return tracks.isEmpty ? nil : ShelfPlaylist(playlist: playlist, tracks: tracks)
        }

        // Top artists by number of songs.
        var counts: [Int64: Int] = [:]
        var artistArtwork: [Int64: Track] = [:]
        for track in tracks {
            guard let artistId = track.artistId else { continue }
            counts[artistId, default: 0] += 1
            if artistArtwork[artistId] == nil, track.hasArtwork {
                artistArtwork[artistId] = track
            }
        }
        let names = (try? DatabaseManager.shared.getAllArtistNamesById()) ?? [:]
        topArtists = counts.sorted { $0.value > $1.value }.prefix(12).compactMap { entry in
            names[entry.key].map { ShelfArtist(artist: Artist(id: entry.key, name: $0), artworkTrack: artistArtwork[entry.key]) }
        }

        loadStartTracks(recentTracks: recentTracks, newestFirst: newestFirst)
    }

    /// The library newest first (track ids grow with every insert).
    ///
    /// The list arrives from the database in that order already, so this is
    /// usually one pass to confirm it rather than a sort: sorting 20,000
    /// songs - twice per reload - was most of Home's main-thread time on a
    /// big library. The sort is stable, so an already-ordered list is
    /// exactly what it would return.
    private var newestFirst: [Track] {
        let ordered = zip(tracks, tracks.dropFirst()).allSatisfy { ($0.id ?? 0) >= ($1.id ?? 0) }
        return ordered ? tracks : tracks.sorted { ($0.id ?? 0) > ($1.id ?? 0) }
    }

    private func loadStartTracks(recentTracks: [Track], newestFirst: [Track]? = nil) {
        // Start Listening: the last songs played, else the newest additions.
        // Up to twelve: what was played last, topped up with new additions.
        // Enough for three full pages of nine, with the places in front.
        let wanted = Self.startPageSize * Self.startPageCount
        var start = Array(recentTracks.prefix(wanted))
        if start.count < wanted {
            // Stops at the first songs it needs instead of filtering the
            // whole library.
            var seen = Set(start.map(\.stableId))
            for track in newestFirst ?? self.newestFirst where start.count < wanted {
                if seen.insert(track.stableId).inserted { start.append(track) }
            }
        }
        startTracks = start
        artistNames = (try? DatabaseManager.shared.getArtistDisplayNames(
            forTrackStableIds: start.map(\.stableId),
            fallbackArtistIdsByStableId: start.reduce(into: [:]) { result, track in
                if let artistId = track.artistId { result[track.stableId] = artistId }
            }
        )) ?? [:]
        loadStartSources()
    }
}

/// A place in Start Listening - Liked Songs, a playlist, album, artist or
/// mix. Tapping opens it; holding it offers Play.
private struct StartSourceCell: View {
    let source: HomeView.StartSource
    /// The chevron on the right; left out in a phone's narrow columns, where
    /// the words need the room.
    var showsTrailingIcon = true
    let onPlay: () -> Void

    @State private var image: UIImage?
    @State private var tint: Color?

    private var title: String {
        switch source.kind {
        case .songs: return Localized.songs
        case .liked: return Localized.likedSongs
        case .playlist(let item): return item.playlist.title
        case .album(let item): return item.album.title
        case .artist(let item): return item.artist.name
        case .mix(let mix): return mix.title
        }
    }

    private var subtitle: String {
        switch source.kind {
        case .songs(let count): return Localized.songsCountOnly(count)
        case .liked(let count): return "\(Localized.playlist) · \(Localized.songsCountOnly(count))"
        case .playlist(let item): return "\(Localized.playlist) · \(Localized.songsCountOnly(item.tracks.count))"
        case .album(let item): return [Localized.album, item.album.albumArtist].compactMap { $0 }.joined(separator: " · ")
        case .artist: return Localized.artist
        case .mix: return Localized.madeForYou
        }
    }

    var body: some View {
        // Songs beside it play when tapped; a place opens - the chevron says
        // so - and holding it offers Play.
        NavigationLink(value: source.route) {
            StartTile(title: title, subtitle: subtitle, tint: tint) {
                artwork
            }
        }
        .buttonStyle(PressableButtonStyle())
        .contextMenu {
            Button(action: onPlay) {
                Label(Localized.play, systemImage: "play.fill")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Localized.play, onPlay)
        // Keyed on the artwork's song too: the place can appear before its
        // songs are resolved, and a task keyed on the route alone never
        // loaded the cover once they were.
        .task(id: "\(source.route)|\(artworkTrackId ?? "")") {
            switch source.kind {
            case .album(let item):
                if let track = item.artworkTrack { image = await ArtworkManager.shared.getThumbnail(for: track) }
            case .artist(let item):
                if let track = item.artworkTrack { image = await ArtworkManager.shared.getThumbnail(for: track) }
            case .liked:
                tint = Color(red: 0.62, green: 0.16, blue: 0.36)
                return
            case .mix(let mix):
                // The mix's own colour, as on its cover.
                tint = Color(hue: mix.hue, saturation: 0.65, brightness: 0.55)
                return
            case .playlist(let item):
                // The playlist's cover is drawn by its own view; its first
                // song's artwork gives the colour.
                if let track = item.tracks.first(where: \.hasArtwork) {
                    tint = await StartTileTint.color(for: await ArtworkManager.shared.getThumbnail(for: track))
                }
                return
            default:
                return
            }
            tint = await StartTileTint.color(for: image)
        }
    }

    private var artworkTrackId: String? {
        switch source.kind {
        case .album(let item): return item.artworkTrack?.stableId
        case .artist(let item): return item.artworkTrack?.stableId
        default: return nil
        }
    }

    @ViewBuilder
    private var artwork: some View {
        switch source.kind {
        case .songs:
            SongsCover(cornerRadius: Design.Radius.thumbnail)
        case .liked:
            LikedSongsCover(cornerRadius: Design.Radius.thumbnail)
        case .playlist(let item):
            PlaylistTileCover(playlist: item.playlist, tracks: item.tracks, cornerRadius: Design.Radius.thumbnail)
        case .album:
            ArtworkView(image: image, cornerRadius: Design.Radius.thumbnail)
        case .artist:
            // Square like the other tiles: a round portrait left empty
            // corners in the tile.
            ArtworkView(image: image, cornerRadius: 0, placeholderSymbol: "music.microphone")
        case .mix(let mix):
            MixCover(mix: mix, showsTitle: false)
                .clipShape(RoundedRectangle(cornerRadius: Design.Radius.thumbnail, style: .continuous))
        }
    }
}

/// The colour behind a Start Listening tile's words: the cover's top colour,
/// dimmed to sit under white text - the same tuning the player uses.
enum StartTileTint {
    static func color(for image: UIImage?) async -> Color? {
        guard let image else { return nil }
        return await PlayerPalette.make(from: image, fallback: .gray).top
    }
}

/// A Start Listening tile, laid out like a mix cover: the artwork fills the
/// square and the title and subtitle sit on it, over a dark fade at the
/// bottom, so the words get the whole width. The song playing is ringed in
/// the theme colour.
private struct StartTile<Artwork: View>: View {
    let title: String
    let subtitle: String?
    /// The colour behind the words: the cover's own, as a mix shows its
    /// colour; the theme colour until the cover's is known.
    var tint: Color? = nil
    @ViewBuilder let artwork: () -> Artwork
    @ObservedObject private var theme = ThemeStore.shared

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            artwork()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            // As on a mix: the colour rises behind the words and leaves the
            // artwork above clear.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.35),
                    .init(color: (tint ?? theme.accent).opacity(0.75), location: 0.72),
                    .init(color: (tint ?? theme.accent).opacity(0.95), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .animation(.easeInOut(duration: 0.4), value: tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .opacity(0.8)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            // The words sit on a tile that does not grow: at accessibility
            // sizes they broke mid-word ("Cas-cade"). VoiceOver still reads
            // them in full.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .padding(Design.Spacing.s)
        }
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius.artwork, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Design.Radius.artwork, style: .continuous))
    }
}

/// One song in Start Listening: artwork, title, artist; the playing song in
/// the accent colour with live bars.
private struct StartSongCell: View {
    let track: Track
    let artistName: String?
    /// The playing bars on the right; left out in a phone's narrow columns,
    /// where the title in the theme colour already marks the song playing.
    var showsTrailingIcon = true
    let onTap: () -> Void

    @ObservedObject private var playerEngine = PlayerEngine.shared
    @ObservedObject private var theme = ThemeStore.shared
    @State private var image: UIImage?
    @State private var tint: Color?

    private var isCurrent: Bool { playerEngine.currentTrack?.stableId == track.stableId }

    var body: some View {
        Button(action: onTap) {
            StartTile(title: track.title, subtitle: artistName, tint: tint) {
                ArtworkView(image: image, cornerRadius: 0)
            }
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel([track.title, artistName].compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(isCurrent ? Localized.nowPlaying : "")
        .task(id: track.stableId) {
            image = await ArtworkManager.shared.getThumbnail(for: track)
            tint = await StartTileTint.color(for: image)
        }
    }
}
