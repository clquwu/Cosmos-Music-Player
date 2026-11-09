import SwiftUI
import GRDB

// MARK: - Routes

/// Everything the app can push onto a tab's navigation stack.
///
/// Records are referred to by id rather than carried whole: GRDB records are
/// not Hashable, and a route that is resolved when it is shown always shows
/// the current row rather than a copy taken when the link was made.
enum LibraryRoute: Hashable {
    case allSongs
    case likedSongs
    case albums
    case artists
    case playlists
    case album(id: Int64)
    case artist(id: Int64?, name: String)
    case playlist(id: Int64)
    case mix(id: String)
    /// The library as folders on disk, and one folder in it.
    case folders
    case folder(path: String)
}

/// The app's tabs. Each has one job, so nothing appears twice:
/// - Home: what you have been listening to.
/// - Library: songs, liked songs, folders, playlists, albums and artists,
///   with its own All / Playlists / Albums / Artists switch.
/// - Search.
/// The same three on every device: iPad and an unfolded foldable used to
/// list the library's sections as sidebar tabs of their own, and the user
/// wanted their Library to work like the phone's instead.
enum AppTab: Hashable {
    case home
    case library
    // Not tabs any more: selecting one opens its page in the Library tab
    // (see `AppRouter.selectedTab`). Kept so callers can still name them.
    case songs
    case likedSongs
    case playlists
    case artists
    case albums
    case folders
    case search

    /// The Library tab's page for one of the library's sections.
    var libraryRoute: LibraryRoute? {
        switch self {
        case .songs: return .allSongs
        case .likedSongs: return .likedSongs
        case .playlists: return .playlists
        case .artists: return .artists
        case .albums: return .albums
        case .folders: return .folders
        case .home, .library, .search: return nil
        }
    }
}

// MARK: - Router

/// Owns the selected tab, each tab's navigation path and whether the
/// full-screen player is up.
///
/// Replaces the hidden `NavigationLink(isActive:)`s that the old single-stack
/// layout drove from NotificationCenter. Anything - a song's menu, the player,
/// a Siri hand-off - can now open a page with `AppRouter.shared.open(_:)`, and
/// it lands on whichever tab the user is looking at.
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    @Published var selectedTab: AppTab = .home {
        didSet {
            // A library section is a page of the Library tab, not a tab:
            // anything still asking for one as a tab opens it there.
            guard let route = selectedTab.libraryRoute else { return }
            var path = NavigationPath()
            path.append(route)
            paths[.library] = path
            selectedTab = .library
        }
    }
    @Published var paths: [AppTab: NavigationPath] = [:]
    @Published var isPlayerPresented = false
    /// Bumped to ask the Library tab to open the file importer, e.g. from
    /// Home's welcome screen on an empty library.
    @Published private(set) var importRequest = 0

    func requestImport() {
        selectedTab = .library
        importRequest += 1
    }

    private init() {}

    func path(for tab: AppTab) -> Binding<NavigationPath> {
        Binding(
            get: { self.paths[tab] ?? NavigationPath() },
            set: { self.paths[tab] = $0 }
        )
    }

    /// Pushes `route` onto the visible tab, closing the player first if it is
    /// open so the page is actually seen.
    /// - Parameter replacingStack: show `route` as the only page above the
    ///   tab's root. For hand-offs from outside the app (a widget), where
    ///   opening the same playlist twice should not stack two copies.
    func open(_ route: LibraryRoute, in tab: AppTab? = nil, replacingStack: Bool = false) {
        if isPlayerPresented {
            isPlayerPresented = false
        }
        let target = tab ?? selectedTab
        if target != selectedTab {
            selectedTab = target
        }
        var path = replacingStack ? NavigationPath() : (paths[target] ?? NavigationPath())
        path.append(route)
        paths[target] = path
    }

    func openArtist(id: Int64?, name: String) {
        open(.artist(id: id, name: name))
    }

    /// Opens the artist credited on `track`, if it has one.
    func openArtist(of track: Track) {
        guard let artistId = track.artistId,
              let artist = try? DatabaseManager.shared.getArtist(byId: artistId) else { return }
        openArtist(id: artist.id, name: artist.name)
    }

    func openAlbum(of track: Track) {
        guard let albumId = track.albumId else { return }
        open(.album(id: albumId))
    }
}

// MARK: - Library tracks in the environment

private struct LibraryTracksKey: EnvironmentKey {
    static let defaultValue: [Track] = []
}

extension EnvironmentValues {
    /// The whole library, provided once at the root. Several detail pages
    /// still take it (album cards look their artwork up in it).
    var libraryTracks: [Track] {
        get { self[LibraryTracksKey.self] }
        set { self[LibraryTracksKey.self] = newValue }
    }
}

// MARK: - Destinations

extension View {
    /// Registers the destinations for `LibraryRoute`. Applied to the root view
    /// of every tab's stack.
    func libraryDestinations() -> some View {
        navigationDestination(for: LibraryRoute.self) { route in
            LibraryRouteView(route: route)
        }
    }
}

private struct LibraryRouteView: View {
    let route: LibraryRoute
    @Environment(\.libraryTracks) private var tracks

    var body: some View {
        destination
            .hidesSystemTabBar()
            .onAppear {
                // Opening an album, playlist, artist or mix puts it on Home's
                // Start Listening, to come back to.
                ListeningHistory.shared.recordSource(route)
            }
    }

    @ViewBuilder
    private var destination: some View {
        switch route {
        case .allSongs:
            AllSongsScreen(tracks: tracks)
        case .likedSongs:
            LikedSongsScreen(allTracks: tracks)
        case .albums:
            AlbumsScreen(allTracks: tracks)
        case .artists:
            ArtistsScreen(allTracks: tracks)
        case .playlists:
            PlaylistsScreen()
        case .album(let id):
            AlbumRouteView(albumId: id, allTracks: tracks)
        case .artist(let id, let name):
            ArtistRouteView(artistId: id, name: name, allTracks: tracks)
        case .playlist(let id):
            PlaylistRouteView(playlistId: id)
        case .mix(let id):
            MixDetailView(mixId: id)
        case .folders:
            FoldersScreen(tracks: tracks)
        case .folder(let path):
            FolderDetailScreen(path: path, allTracks: tracks)
        }
    }
}

private struct AlbumRouteView: View {
    let albumId: Int64
    let allTracks: [Track]
    @State private var album: Album?
    @State private var didLoad = false

    var body: some View {
        Group {
            if let album {
                AlbumDetailScreen(album: album, allTracks: allTracks)
            } else if didLoad {
                CosmosEmptyState(systemImage: "opticaldisc", title: Localized.noAlbumsFound)
            } else {
                ProgressView()
            }
        }
        .task {
            album = try? DatabaseManager.shared.read { db in
                try Album.fetchOne(db, key: albumId)
            }
            didLoad = true
        }
    }
}

private struct ArtistRouteView: View {
    let artistId: Int64?
    let name: String
    let allTracks: [Track]

    var body: some View {
        if let artistId {
            ArtistDetailScreen(artist: Artist(id: artistId, name: name), allTracks: allTracks)
        } else {
            ArtistDetailScreenWrapper(artistName: name, allTracks: allTracks)
        }
    }
}

private struct PlaylistRouteView: View {
    let playlistId: Int64
    @State private var playlist: Playlist?
    @State private var didLoad = false

    var body: some View {
        Group {
            if let playlist {
                PlaylistDetailScreen(playlist: playlist)
            } else if didLoad {
                CosmosEmptyState(systemImage: "music.note.list", title: Localized.noPlaylistsYet)
            } else {
                ProgressView()
            }
        }
        .task {
            playlist = try? DatabaseManager.shared.getAllPlaylists().first { $0.id == playlistId }
            didLoad = true
        }
    }
}

// MARK: - Now-playing presence

/// Whether anything is loaded in the player, published only when that answer
/// changes. The root view needs to know this to show the mini player, and
/// observing PlayerEngine itself would rebuild the whole tab hierarchy on
/// every play, pause and track change.
@MainActor
final class NowPlayingPresence: ObservableObject {
    static let shared = NowPlayingPresence()

    @Published private(set) var hasTrack = false

    private var task: Task<Void, Never>?

    private init() {
        hasTrack = PlayerEngine.shared.currentTrack != nil
        // Listens are logged when playback starts, not when a track is
        // merely loaded (restoring last session's song is not a listen).
        ListeningLog.shared.start()
        task = Task { @MainActor [weak self] in
            for await track in PlayerEngine.shared.$currentTrack.values {
                guard let self else { return }
                let present = track != nil
                if present != self.hasTrack {
                    self.hasTrack = present
                }
            }
        }
    }
}

// MARK: - Root

/// The app's top level: a tab bar on iPhone that becomes a sidebar on iPad
/// and on an unfolded foldable, with the mini player attached to it and the
/// full-screen player above everything.
///
/// The Library tab is the old home screen - same rows, same order setting -
/// so nothing anyone relied on has moved; the tabs are shortcuts to pages
/// that used to be one tap further in.
struct RootTabView: View {
    let tracks: [Track]
    @Binding var showSettings: Bool
    let onRefresh: () async -> (before: Int, after: Int)
    let onManualSync: (() async -> (before: Int, after: Int))?

    @ObservedObject private var router = AppRouter.shared
    @ObservedObject private var presence = NowPlayingPresence.shared
    @ObservedObject private var theme = ThemeStore.shared
    @Namespace private var playerTransition
    // v4: the Library tab was hidden from the sidebar in earlier layouts, and
    // a saved customization would keep it hidden now that it is the way in.
    @AppStorage("cosmos.tabViewCustomization.v4") private var tabCustomization = TabViewCustomization()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var chromeHeight: CGFloat = 0
    @State private var wideMiniPlayerHeight: CGFloat = 0

    /// A phone, or a narrow iPad window: Cosmos draws its own solid tab bar
    /// and mini player. Wider than that, the system sidebar takes over.
    private var isCompact: Bool { horizontalSizeClass == .compact }

    /// Room below each tab's scrolling content for what floats over it: the
    /// phone's mini player and tab bar, or the wide layouts' mini player. Its
    /// safe-area inset does not reach past the navigation stack either - on
    /// iPhone Duo's inner screen the last rows stayed under it.
    private var bottomScrollRoom: CGFloat {
        if isCompact { return chromeHeight + Design.Spacing.m }
        return presence.hasTrack ? wideMiniPlayerHeight : 0
    }

    var body: some View {
        tabs
            .tabViewStyle(.sidebarAdaptable)
            // Where there is room for it the sidebar starts open, so the
            // library's sections are visible rather than behind a button.
            .modifier(DefaultSidebarPlacement())
            // The phone's mini player and tab bar float over the content;
            // each tab's content is given exactly their height of extra
            // scroll room below (see `stack`), so the last rows can always be
            // scrolled clear of them.
            .overlay(alignment: .bottom) {
                if isCompact {
                    compactBottomChrome
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { chromeHeight = $0 }
                }
            }
            .tabViewSidebarHeader {
                SidebarHeader()
            }
            .animation(.smooth(duration: 0.35), value: presence.hasTrack)
            .environment(\.libraryTracks, tracks)
            .detectsFoldableDisplay()
            .readsPageMargin()
            .tint(theme.accent)
            .fullScreenCover(isPresented: $router.isPlayerPresented) {
                PlayerView()
                    .environmentObject(AppCoordinator.shared)
                    .tint(theme.accent)
                    .accentColor(theme.accent)
                    .navigationTransition(.zoom(sourceID: MiniPlayerView.transitionID, in: playerTransition))
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NavigateToArtistFromPlayer"))) { notification in
                guard let artist = notification.userInfo?["artist"] as? Artist else { return }
                router.openArtist(id: artist.id, name: artist.name)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NavigateToAlbumFromPlayer"))) { notification in
                guard let album = notification.userInfo?["album"] as? Album, let id = album.id else { return }
                router.open(.album(id: id))
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NavigateToPlaylist"))) { notification in
                guard let playlistId = notification.userInfo?["playlistId"] as? Int64 else { return }
                // Home is a tab on every device; the Playlists tab is
                // sidebar-only and hidden on a phone.
                router.open(.playlist(id: playlistId), in: .home, replacingStack: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("MinimizePlayer"))) { _ in
                router.isPlayerPresented = false
            }
            // The halo holds still after a while untouched; every window
            // reports its touches from here on.
            .onAppear { HaloActivity.shared.watchTouches() }
            #if DEBUG
            .task(id: tracks.count) {
                await DebugLaunchRoute.scanIfRequested()
                await DebugLaunchRoute.apply(tracks: tracks)
                // -cosmosDebugSettings 1 opens Settings, for screenshots.
                if UserDefaults.standard.bool(forKey: "cosmosDebugSettings"), !tracks.isEmpty {
                    try? await Task.sleep(for: .milliseconds(Int.random(in: 0...1500)))
                    showSettings = true
                }
            }
            // -cosmosDebugWidth <points>: lays the app out in a narrower
            // column, standing in for a resized iPad window - the simulator
            // cannot be resized or rotated from the command line.
            .modifier(DebugWindowWidth())
            #endif
    }

    /// The phone's bottom chrome: the mini player card sitting on a solid
    /// tab bar. Both opaque - no glass - so nothing shows through them.
    private var compactBottomChrome: some View {
        VStack(spacing: 0) {
            if presence.hasTrack {
                MiniPlayerView(transitionNamespace: playerTransition)
                    .padding(.bottom, Design.Spacing.s)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            CosmosTabBar(selection: $router.selectedTab)
        }
    }

    private var tabs: some View {
        TabView(selection: $router.selectedTab) {
            Tab(Localized.home, systemImage: "house", value: AppTab.home) {
                stack(for: .home) {
                    HomeView(tracks: tracks, showSettings: $showSettings, onManualSync: onManualSync)
                }
            }
            .customizationID("cosmos.tab.home")

            // Songs, liked songs, folders, playlists, albums and artists, on
            // every device - in the sidebar too, as on the phone.
            Tab(Localized.libraryTab, systemImage: "square.stack.fill", value: AppTab.library) {
                stack(for: .library) {
                    LibraryView(
                        tracks: tracks,
                        showSettings: $showSettings,
                        onRefresh: onRefresh,
                        onManualSync: onManualSync
                    )
                }
            }
            .customizationID("cosmos.tab.library")

            Tab(value: AppTab.search, role: .search) {
                stack(for: .search) {
                    SearchView(allTracks: tracks)
                }
            }
            .customizationID("cosmos.tab.search")
        }
        .tabViewCustomization($tabCustomization)
    }

    private func stack<Content: View>(for tab: AppTab, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack(path: router.path(for: tab)) {
            content()
                .hidesSystemTabBar()
                .libraryDestinations()
        }
        // Scroll room under the floating mini player and tab bar. Content
        // margins reach every scroll view inside the stack (safe-area padding
        // did not get past the navigation stack, so the last rows stayed
        // stuck behind the bars). Horizontal shelves opt out - see
        // ShelfScrollView.
        .contentMargins(.bottom, bottomScrollRoom, for: .scrollContent)
        // iPhone Duo's cover screen: the camera and status items stack down
        // the right edge; keep the content and its top bar clear of them.
        .modifier(TrailingOcclusionPadding())
        // Wide layouts: the mini player sits at the bottom of the content
        // column, beside the sidebar. Only the visible tab's copy is the
        // zoom's source - two sources with one id would be ambiguous.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !isCompact && presence.hasTrack {
                MiniPlayerView(transitionNamespace: router.selectedTab == tab ? playerTransition : nil)
                    .frame(maxWidth: 640)
                    .padding(.bottom, Design.Spacing.m)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { wideMiniPlayerHeight = $0 }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}

// MARK: - Tab bar

extension View {
    /// Hides the system tab bar on a phone, where Cosmos draws its own.
    func hidesSystemTabBar() -> some View {
        modifier(HidesSystemTabBar())
    }
}

private struct HidesSystemTabBar: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        content.toolbar(horizontalSizeClass == .compact ? .hidden : .automatic, for: .tabBar)
    }
}

/// The phone's tab bar: solid, three destinations, the selected one in the
/// accent colour. Tapping the current tab again returns it to its root.
struct CosmosTabBar: View {
    @Binding var selection: AppTab
    @ObservedObject private var theme = ThemeStore.shared
    @Namespace private var selectionPill

    private struct Item {
        let tab: AppTab
        let title: String
        let symbol: String
        let selectedSymbol: String
    }

    private let items = [
        Item(tab: .home, title: Localized.home, symbol: "house", selectedSymbol: "house.fill"),
        Item(tab: .library, title: Localized.libraryTab, symbol: "square.stack", selectedSymbol: "square.stack.fill"),
        Item(tab: .search, title: Localized.search, symbol: "magnifyingglass", selectedSymbol: "magnifyingglass")
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.title) { item in
                let isSelected = selection == item.tab
                Button {
                    if isSelected {
                        AppRouter.shared.paths[item.tab] = NavigationPath()
                    } else {
                        selection = item.tab
                    }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: isSelected ? item.selectedSymbol : item.symbol)
                            .font(.system(size: 20, weight: isSelected ? .semibold : .regular))
                            .symbolEffect(.bounce, value: isSelected)
                            .frame(height: 24)
                        Text(item.title)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(isSelected ? theme.accent : Color.secondary)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background {
                        // The selected tab sits in a soft pill that slides
                        // between tabs.
                        if isSelected {
                            Capsule()
                                .fill(theme.accent.opacity(0.14))
                                .matchedGeometryEffect(id: "selection", in: selectionPill)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                // As the system tab bar does: the labels stop growing at the
                // largest standard size - at the accessibility sizes they
                // were cut to "Biblioth..." and "Recherc..." - and a long
                // press shows the tab enlarged instead.
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .accessibilityShowsLargeContentViewer()
            }
        }
        .padding(6)
        // A floating bubble of half glass: a blur with the background colour
        // laid over it at part strength, so the halo and covers glow through
        // softly while the labels stay readable.
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().fill(Color(.systemBackground).opacity(0.55)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        }
        // Inset like the mini player above it, so the two line up; sitting
        // a little into the home-indicator area, as the system bar does,
        // rather than floating high above it.
        .padding(.horizontal, Design.Spacing.l)
        .padding(.bottom, -Design.Spacing.s)
        .animation(.snappy(duration: 0.3), value: selection)
    }
}

/// Reads the camera inset set at the root (inside the tab view, so the
/// value is there) and keeps the tab's content and top bar clear of it.
private struct TrailingOcclusionPadding: ViewModifier {
    @Environment(\.trailingOcclusion) private var inset

    func body(content: Content) -> some View {
        content.safeAreaPadding(.trailing, inset)
    }
}

/// iOS 27 replaced `defaultAdaptableTabBarPlacement` with
/// `defaultTabBarPlacement`; on 27 only the new one is honoured, which is why
/// iPad landscape opened with the tab bar instead of the sidebar.
///
/// Only a window wide enough to keep the sidebar beside the page starts with
/// it. Narrower - an iPad in portrait, a smaller window - the sidebar can only
/// slide over the page, and opening it there greyed the screen at every launch
/// until it was dismissed; those start with the tab bar, the sidebar a tap
/// away on its button.
private struct DefaultSidebarPlacement: ViewModifier {
    #if DEBUG
    /// -cosmosDebugSidebar 1 opens the sidebar at any width, for screenshots.
    private static let debugForcesSidebar = UserDefaults.standard.bool(forKey: "cosmosDebugSidebar")
    #else
    private static let debugForcesSidebar = false
    #endif

    func body(content: Content) -> some View {
        // Read before the tab view is first built, so the first frame
        // already has the right bar. Every iPad is wider than 1100 points in
        // landscape and narrower in portrait (the 13-inch is 1032).
        GeometryReader { geometry in
            let placement: AdaptableTabBarPlacement = Self.opensSidebar(in: geometry) ? .sidebar : .tabBar
            if #available(iOS 27.0, *) {
                content
                    .defaultAdaptableTabBarPlacement(placement)
                    .defaultTabBarPlacement(placement)
            } else {
                content.defaultAdaptableTabBarPlacement(placement)
            }
        }
    }

    nonisolated static func opensSidebar(in geometry: GeometryProxy) -> Bool {
        geometry.size.width >= 1100 || isFoldableHeldOpenLikeABook(geometry) || debugForcesSidebar
    }

    /// iPhone Duo's inner screen held sideways, the fold running down the
    /// middle: only about 950 points wide, but the system keeps the sidebar
    /// beside the page there rather than over it. Below 1100 points it fell
    /// back to the tab bar, which on a phone lists every tab - the library's
    /// sections too - and pushed Search into a More tab.
    nonisolated private static func isFoldableHeldOpenLikeABook(_ geometry: GeometryProxy) -> Bool {
        guard #available(iOS 27.1, *), geometry.size.width > geometry.size.height else { return false }
        return !geometry.reservedRegions(kind: .division, options: .includeInactive).isEmpty
    }
}

#if DEBUG
private struct DebugWindowWidth: ViewModifier {
    private let width = UserDefaults.standard.double(forKey: "cosmosDebugWidth")

    func body(content: Content) -> some View {
        if width > 0 {
            content
                .frame(width: width)
                .frame(maxWidth: .infinity)
                .background(Color.black.ignoresSafeArea())
        } else {
            content
        }
    }
}

/// Opens a given screen at launch, for checking the design screen by screen
/// on a simulator without tapping through by hand. Debug builds only.
///
///     simctl launch <device> dev.clq.Cosmos-Music-Player \
///         -cosmosDebugTab library -cosmosDebugRoute album -cosmosDebugPlay 1
@MainActor
enum DebugLaunchRoute {
    private static var applied = false
    private static var scanned = false

    /// `-cosmosDebugScan 1`: run the manual sync once, ignoring the
    /// once-a-day automatic scan limit.
    static func scanIfRequested() async {
        // `-cosmosDebugLinkFolder <path>`: link a folder as if picked in Files.
        if !scanned, let path = UserDefaults.standard.string(forKey: "cosmosDebugLinkFolder") {
            let outcome = await LinkedFolderImporter.link(URL(fileURLWithPath: path, isDirectory: true))
            print("🧪 Link folder \(path): \(outcome)")
        }
        guard !scanned, UserDefaults.standard.bool(forKey: "cosmosDebugScan") else { return }
        scanned = true
        await AppCoordinator.shared.manualSync()
    }

    static func apply(tracks: [Track]) async {
        let defaults = UserDefaults.standard
        let tab = defaults.string(forKey: "cosmosDebugTab")
        let route = defaults.string(forKey: "cosmosDebugRoute")
        let play = defaults.bool(forKey: "cosmosDebugPlay")
        let panel = defaults.string(forKey: "cosmosDebugPanel")
        let openPlayer = defaults.bool(forKey: "cosmosDebugOpenPlayer")
        let router = AppRouter.shared
        let tabs: [String: AppTab] = [
            "home": .home, "library": .library, "search": .search, "songs": .songs,
            "liked": .likedSongs, "playlists": .playlists, "artists": .artists, "albums": .albums,
            "folders": .folders
        ]
        // An empty library still opens the tab, to check its empty state.
        if tracks.isEmpty, let tab, let target = tabs[tab] {
            router.selectedTab = target
        }
        guard !applied, tab != nil || route != nil || play || openPlayer, !tracks.isEmpty else { return }
        applied = true

        if let tab, let target = tabs[tab] {
            router.selectedTab = target
        }

        try? await Task.sleep(for: .milliseconds(400))

        switch route {
        case "album":
            if let albumId = tracks.first(where: { $0.albumId != nil })?.albumId {
                router.open(.album(id: albumId))
            }
        case "artist":
            if let track = tracks.first(where: { $0.artistId != nil }) {
                router.openArtist(of: track)
            }
        case "playlist":
            if let playlist = try? DatabaseManager.shared.getAllPlaylists().first, let id = playlist.id {
                router.open(.playlist(id: id))
            }
        case "mix":
            try? await Task.sleep(for: .seconds(1))
            if let mix = MixStore.shared.madeForYou.first {
                router.open(.mix(id: mix.id))
            }
        case "songs": router.open(.allSongs)
        case "liked": router.open(.likedSongs)
        case "albums": router.open(.albums)
        case "artists": router.open(.artists)
        case "playlists": router.open(.playlists)
        case "folders": router.open(.folders)
        case "folder":
            if let path = defaults.string(forKey: "cosmosDebugFolderPath") {
                router.open(.folder(path: path))
            }
        default: break
        }

        if play, let first = tracks.first(where: { $0.albumId != nil }) ?? tracks.first {
            let queue = tracks.filter { $0.albumId == first.albumId }
            await AppCoordinator.shared.playTrack(first, queue: queue.isEmpty ? [first] : queue)
            try? await Task.sleep(for: .milliseconds(800))
        }

        // `-cosmosDebugSkipStress N` (with -cosmosDebugPlay 1): N rounds of quick
        // song changes issued the way the UI does (fire-and-forget row taps and
        // Next/Previous, plus Pause/Play unless -cosmosDebugStressNoPause 1),
        // then Play, logging whether playback actually runs afterwards.
        let rounds = defaults.integer(forKey: "cosmosDebugSkipStress")
        if rounds > 0 {
            let engine = PlayerEngine.shared
            let actions = defaults.bool(forKey: "cosmosDebugStressNoPause") ? 2 : 5
            for round in 1...rounds {
                for _ in 0..<Int.random(in: 2...4) {
                    switch Int.random(in: 0..<actions) {
                    case 0:
                        let track = tracks.randomElement()!
                        Task { await AppCoordinator.shared.playTrack(track, queue: tracks) }
                    case 1: Task { await engine.nextTrack() }
                    case 2: engine.pause()
                    case 3: engine.play()
                    default: Task { await engine.previousTrack() }
                    }
                    try? await Task.sleep(for: .milliseconds(Int.random(in: 50...400)))
                }
                try? await Task.sleep(for: .milliseconds(Int.random(in: 0...1500)))
                print("🧪 stress \(round) settled: \(engine.currentTrack?.title ?? "-") state=\(engine.playbackState) playing=\(engine.isPlaying)")
                if !engine.isPlaying { engine.play() }
                try? await Task.sleep(for: .milliseconds(2500))
                let ok = engine.isPlaying && engine.playbackTime > 0.5
                print("🧪 stress \(round) after Play: \(ok ? "OK" : "STUCK") state=\(engine.playbackState) t=\(engine.playbackTime)")
            }
        }

        // Opens on whatever is loaded - the restored session when not playing.
        if openPlayer, PlayerEngine.shared.currentTrack != nil {
            router.isPlayerPresented = true
            if let panel {
                try? await Task.sleep(for: .milliseconds(700))
                NotificationCenter.default.post(name: Notification.Name("CosmosDebugPlayerPanel"), object: panel)
            }
        }
    }
}
#endif

/// The top of the iPad sidebar: the Cosmos icon and name, so the sidebar
/// reads as the app's own rather than a stock list.
private struct SidebarHeader: View {
    var body: some View {
        HStack(spacing: Design.Spacing.m) {
            CosmosLogo(size: 34)
            Text("Cosmos")
                .font(.title2.weight(.bold))
            Spacer(minLength: 0)
        }
        .padding(.vertical, Design.Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
