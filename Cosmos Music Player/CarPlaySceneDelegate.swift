import CarPlay
import UIKit

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    private var interfaceController: CPInterfaceController?
    private var allSongsTemplate: CPListTemplate?
    private var favoritesTemplate: CPListTemplate?
    private var playlistsTemplate: CPListTemplate?
    private var allSongsTracks: [Track] = []
    private var artistNameCache: [Int64: String] = [:]
    /// Display names for the tracks currently on screen, resolved in one
    /// batched query per fetch. `getArtistName(for:)` used to run
    /// `getArtistDisplayName` per row, so a single All Songs page cost 200
    /// database round trips - and the whole list is rebuilt on every refresh.
    private var trackArtistNames: [String: String] = [:]
    /// What the root lists were last built from. A refresh that would produce
    /// the same rows is skipped rather than rebuilt: during an import the
    /// favourite and playlist notifications fire constantly without those
    /// lists actually changing.
    private var lastRootDataSignature: Int?
    private var likedTracksCache: [Track] = []
    private var playlistRowsCache: [CarPlayRootData.PlaylistRow] = []

    private let incompatibleFormats = ["ogg", "oga", "opus", "dsf", "dff"]
    private let maxArtworkItems = 50
    private let carPlayPageSize = 200
    private let maxQueueItems = 5000

    private var allSongsOffset = 0
    private var allSongsTotal = 0

    /// Held so they can be removed on disconnect. Block-based observers are
    /// not released by deinit, and this delegate used to register one on every
    /// connect and never remove it, so they accumulated across reconnects.
    private var observerTokens: [NSObjectProtocol] = []
    private var pendingLibraryRefresh: DispatchWorkItem?
    private var refreshRequestedAt: Date?
    private var rootRefreshGeneration: UInt64 = 0

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                 didConnect interfaceController: CPInterfaceController) {
        rootRefreshGeneration &+= 1
        self.interfaceController = interfaceController

        loadInitialCarPlayData()

        // Route CarPlay state through PlayerEngine so an active SFB track and
        // its Now Playing state are repaired regardless of whether the scene or
        // AVAudioSession route callback arrives first.
        Task { @MainActor in
            PlayerEngine.shared.handleCarPlayStatusChange()
        }

        let allSongsTemplate = createAllSongsTab()
        self.allSongsTemplate = allSongsTemplate

        let favoritesTemplate = createFavoritesTab()
        self.favoritesTemplate = favoritesTemplate

        let playlistsTemplate = createPlaylistsTab()
        self.playlistsTemplate = playlistsTemplate

        let browseTemplate = createBrowseTab()

        let tabBarTemplate = CPTabBarTemplate(templates: [allSongsTemplate, favoritesTemplate, playlistsTemplate, browseTemplate])
        interfaceController.setRootTemplate(tabBarTemplate, animated: true, completion: nil)

        setupPlayerStateObserver()
        setupLibraryObservers()
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                 didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        self.interfaceController = nil
        allSongsTemplate = nil
        favoritesTemplate = nil
        playlistsTemplate = nil

        pendingLibraryRefresh?.cancel()
        pendingLibraryRefresh = nil
        refreshRequestedAt = nil
        // A detached database fetch from this connection may still complete
        // after a later reconnect. It must not overwrite the new templates.
        rootRefreshGeneration &+= 1
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
        observerTokens.removeAll()

        print("🚗 CarPlay disconnected")
        // Force the flag off rather than re-detecting through
        // handleCarPlayStatusChange(): this scene is normally still present in
        // connectedScenes while its own disconnect callback runs, so
        // detectCarPlay() answers true and the flag latches on.
        Task { @MainActor in
            SFBAudioEngineManager.shared.handleCarPlayDisconnected()
        }
    }

    /// Everything the three data-driven root lists are built from, fetched in
    /// one go so the queries can run off the main thread.
    private struct CarPlayRootData: Sendable {
        var artistNamesById: [Int64: String] = [:]
        var trackArtistNames: [String: String] = [:]
        var allSongsTotal = 0
        var allSongsPage: [Track] = []
        var likedTracks: [Track] = []
        var playlists: [PlaylistRow] = []

        struct PlaylistRow: Sendable {
            let playlist: Playlist
            let tracks: [Track]
        }

        /// Covers everything rendered in the three root lists. Stable IDs
        /// alone miss retagged titles/artists, while playlist counts miss
        /// equal-sized replacements, reorders and custom-cover changes.
        var signature: Int {
            var hasher = Hasher()

            func combineTrack(_ track: Track, includeDisplayArtist: Bool) {
                hasher.combine(track.stableId)
                hasher.combine(track.title)
                hasher.combine(track.artistId)
                hasher.combine(track.albumId)
                hasher.combine(track.modificationDate)
                hasher.combine(track.fileSize)
                hasher.combine(track.hasEmbeddedArt)
                if includeDisplayArtist {
                    hasher.combine(trackArtistNames[track.stableId])
                }
            }

            hasher.combine(allSongsTotal)
            hasher.combine(allSongsPage.count)
            for track in allSongsPage {
                combineTrack(track, includeDisplayArtist: true)
            }

            hasher.combine(likedTracks.count)
            for track in likedTracks {
                combineTrack(track, includeDisplayArtist: true)
            }

            hasher.combine(playlists.count)
            for row in playlists {
                hasher.combine(row.playlist.id)
                hasher.combine(row.playlist.title)
                hasher.combine(row.playlist.customCoverImagePath)
                hasher.combine(row.tracks.count)
                for track in row.tracks {
                    combineTrack(track, includeDisplayArtist: false)
                }
            }

            return hasher.finalize()
        }
    }

    /// Runs every root-list query. `nonisolated static` so it can be called
    /// from a background task: `DatabaseManager` reads are synchronous, and
    /// doing them inline on the main queue stalled the car's UI every time a
    /// refresh landed.
    private nonisolated static func fetchRootData(
        pageSize: Int,
        incompatibleFormats: [String]
    ) -> CarPlayRootData {
        func isCompatible(_ track: Track) -> Bool {
            !incompatibleFormats.contains(URL(fileURLWithPath: track.path).pathExtension.lowercased())
        }

        let database = DatabaseManager.shared
        var data = CarPlayRootData()

        data.artistNamesById = (try? database.getAllArtistNamesById()) ?? [:]
        data.allSongsTotal = (try? database.getTrackCount(excludingFormats: incompatibleFormats)) ?? 0
        data.allSongsPage = (try? database.getTracksPaginated(
            limit: pageSize,
            offset: 0,
            excludingFormats: incompatibleFormats
        )) ?? []
        data.likedTracks = (try? database.getFavoriteTracks(excludingFormats: incompatibleFormats)) ?? []

        let playlists = (try? database.getAllPlaylists()) ?? []
        data.playlists = playlists.map { playlist in
            guard let playlistId = playlist.id else {
                return CarPlayRootData.PlaylistRow(playlist: playlist, tracks: [])
            }
            let items = (try? database.getPlaylistItems(playlistId: playlistId)) ?? []
            let tracks = (try? database.getTracksByStableIdsPreservingOrder(items.map(\.trackStableId))) ?? []
            return CarPlayRootData.PlaylistRow(
                playlist: playlist,
                tracks: tracks.filter(isCompatible)
            )
        }

        // One batched lookup for every row that will be displayed, instead of
        // one query per row inside the section builders.
        let displayed = data.allSongsPage + data.likedTracks
        if !displayed.isEmpty {
            var fallbacks: [String: Int64] = [:]
            for track in displayed where track.artistId != nil {
                fallbacks[track.stableId] = track.artistId
            }
            data.trackArtistNames = (try? database.getArtistDisplayNames(
                forTrackStableIds: displayed.map(\.stableId),
                fallbackArtistIdsByStableId: fallbacks
            )) ?? [:]
        }

        return data
    }

    private func apply(_ data: CarPlayRootData) {
        artistNameCache = data.artistNamesById
        trackArtistNames = data.trackArtistNames
        allSongsTotal = data.allSongsTotal
        allSongsTracks = data.allSongsPage
        allSongsOffset = data.allSongsPage.count
        likedTracksCache = data.likedTracks
        playlistRowsCache = data.playlists
    }

    private func loadInitialCarPlayData() {
        // Only the first build, before any template exists, is synchronous -
        // didConnect has nothing to show until it completes. Every later
        // refresh goes through refreshRootTemplates(), which fetches off-main.
        let data = Self.fetchRootData(
            pageSize: carPlayPageSize,
            incompatibleFormats: incompatibleFormats
        )
        apply(data)
        lastRootDataSignature = data.signature
    }

    private func setupPlayerStateObserver() {
        let token = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("PlayerStateChanged"),
            object: nil,
            queue: .main
        ) { _ in
            print("🎛️ Player state changed - CarPlay will sync automatically")
        }
        observerTokens.append(token)
    }

    /// Keeps the three data-driven root lists in step with the library.
    ///
    /// They used to be built once in didConnect and never touched again, so
    /// plugging the phone in at the start of a drive - which cold-launches the
    /// app and starts a library scan - left All Songs showing whatever had
    /// been indexed at that instant for the whole journey. Favouriting a song
    /// or editing a playlist on the phone was equally invisible until the
    /// cable was pulled. The Browse tab is static and its drill-down screens
    /// query when opened, so neither needs this.
    private func setupLibraryObservers() {
        let names = [
            NSNotification.Name("LibraryNeedsRefresh"),
            NSNotification.Name("TrackFound"),
            NSNotification.Name("FavoritesChanged"),
            NSNotification.Name("PlaylistsChanged")
        ]

        for name in names {
            let token = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // The observer is registered on .main, so this already runs on
                // the main thread - but the closure is nonisolated, and the
                // delegate's methods are main-actor isolated through
                // CPTemplateApplicationSceneDelegate.
                MainActor.assumeIsolated {
                    self?.scheduleLibraryRefresh()
                }
            }
            observerTokens.append(token)
        }
    }

    /// A scan posts TrackFound once per file, so rebuilding on each one would
    /// requery the database thousands of times during an import. Coalesce.
    private func scheduleLibraryRefresh() {
        let now = Date()
        let firstRequest = refreshRequestedAt ?? now
        refreshRequestedAt = firstRequest

        pendingLibraryRefresh?.cancel()

        // Debounce the burst, but never starve. A purely trailing debounce
        // pushes its deadline back on every notification, so a long import -
        // which posts TrackFound continuously for minutes - would refresh only
        // once the scan finally stopped, which is precisely the case this
        // exists to fix. Cap the wait so the list fills in as the scan runs -
        // but not too eagerly: a rebuild discards and re-requests the artwork
        // of every row, so during a long import the cap is what sets the cost.
        let delay = max(0, min(1.0, 15.0 - now.timeIntervalSince(firstRequest)))

        let work = DispatchWorkItem { [weak self] in
            self?.pendingLibraryRefresh = nil
            self?.refreshRequestedAt = nil
            self?.refreshRootTemplates()
        }
        pendingLibraryRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func refreshRootTemplates() {
        guard interfaceController != nil else { return }

        let pageSize = carPlayPageSize
        let formats = incompatibleFormats
        rootRefreshGeneration &+= 1
        let refreshGeneration = rootRefreshGeneration

        Task { @MainActor [weak self] in
            // Every root-list query, off the main thread. Run inline these
            // stalled the car's UI: an artist map, a count, a 200-row page, the
            // favourites, and per-playlist item + track queries, repeated for
            // the whole duration of an import.
            let data = await Task.detached(priority: .userInitiated) {
                CarPlaySceneDelegate.fetchRootData(
                    pageSize: pageSize,
                    incompatibleFormats: formats
                )
            }.value

            guard let self,
                  self.interfaceController != nil,
                  self.rootRefreshGeneration == refreshGeneration else {
                return
            }

            // Nothing user-visible changed, so rebuilding would only throw away
            // the artwork already loaded for these rows and re-request it.
            let signature = data.signature
            guard signature != self.lastRootDataSignature else {
                print("🚗 CarPlay root lists already current - skipping rebuild")
                return
            }
            self.lastRootDataSignature = signature

            // Rebuild the first page from scratch. Anything the user had paged
            // in with "Load More" is dropped deliberately: the offsets it was
            // fetched at no longer describe the same rows once the table has
            // changed.
            self.apply(data)

            self.allSongsTemplate?.updateSections([self.buildAllSongsSection()])
            self.favoritesTemplate?.updateSections([self.buildFavoritesSection()])
            self.playlistsTemplate?.updateSections([self.buildPlaylistsSection()])

            print("🚗 Refreshed CarPlay root lists (\(self.allSongsTotal) playable tracks)")
        }
    }

    // MARK: - Tab Creation

    private func createAllSongsTab() -> CPListTemplate {
        let template = CPListTemplate(title: Localized.allSongs, sections: [buildAllSongsSection()])
        template.tabImage = UIImage(systemName: "music.note")
        addNowPlayingButton(to: template)
        return template
    }

    private func buildAllSongsSection() -> CPListSection {
        let visibleIds = Array(allSongsTracks.prefix(maxArtworkItems)).map { $0.stableId }
        let prefetchIds = Array(allSongsTracks.dropFirst(maxArtworkItems).prefix(20)).map { $0.stableId }
        ArtworkManager.shared.updateVisibleArtworkWindow(visibleTrackIds: visibleIds, prefetchTrackIds: prefetchIds)

        var items: [CPListItem] = allSongsTracks.enumerated().map { index, track in
            let item = CPListItem(text: track.title, detailText: getArtistName(for: track))
            configureArtwork(for: item, track: track, index: index)

            item.handler = { [weak self] _, completion in
                guard let self else {
                    completion()
                    return
                }

                Task {
                    let queue = self.queueForAllSongs(startingAt: index)
                    await AppCoordinator.shared.playTrack(track, queue: queue)
                }
                completion()
            }

            return item
        }

        if allSongsOffset < allSongsTotal {
            let remaining = allSongsTotal - allSongsOffset
            let loadMoreItem = CPListItem(text: "Load More", detailText: "\(remaining) remaining")
            loadMoreItem.handler = { [weak self] _, completion in
                self?.loadMoreAllSongs()
                completion()
            }
            items.append(loadMoreItem)
        }

        return CPListSection(items: items)
    }

    private func loadMoreAllSongs() {
        guard allSongsOffset < allSongsTotal else { return }

        let nextTracks = (try? DatabaseManager.shared.getTracksPaginated(
            limit: carPlayPageSize,
            offset: allSongsOffset,
            excludingFormats: incompatibleFormats
        )) ?? []

        guard !nextTracks.isEmpty else { return }

        allSongsTracks.append(contentsOf: nextTracks)
        allSongsOffset += nextTracks.count
        allSongsTemplate?.updateSections([buildAllSongsSection()])
    }

    private func createFavoritesTab() -> CPListTemplate {
        let template = CPListTemplate(title: Localized.likedSongs, sections: [buildFavoritesSection()])
        template.tabImage = UIImage(systemName: "heart.fill")
        addNowPlayingButton(to: template)
        return template
    }

    private func buildFavoritesSection() -> CPListSection {
        // From the batched fetch - this used to query on every rebuild.
        let likedTracks = likedTracksCache

        let items: [CPListItem] = likedTracks.enumerated().map { index, track in
            let item = CPListItem(text: track.title, detailText: getArtistName(for: track))
            configureArtwork(for: item, track: track, index: index)

            item.handler = { _, completion in
                Task {
                    let queue = self.forwardQueue(from: likedTracks, startingAt: index)
                    await AppCoordinator.shared.playTrack(track, queue: queue)
                }
                completion()
            }

            return item
        }

        return CPListSection(items: items)
    }

    private func createPlaylistsTab() -> CPListTemplate {
        let template = CPListTemplate(title: Localized.playlists, sections: [buildPlaylistsSection()])
        template.tabImage = UIImage(systemName: "music.note.list")
        addNowPlayingButton(to: template)
        return template
    }

    private func buildPlaylistsSection() -> CPListSection {
        // Rows come from the batched fetch. Querying the items and then the
        // tracks of every playlist inside this builder put two database round
        // trips per playlist on the main queue, on every refresh.
        let playlistItems: [CPListItem] = playlistRowsCache.map { row in
            let playlist = row.playlist
            let tracks = row.tracks
            let item = CPListItem(text: playlist.title, detailText: Localized.songsCountOnly(tracks.count))
            configurePlaylistArtwork(for: item, playlist: playlist, tracks: tracks)
            item.handler = { [weak self] _, completion in
                self?.showPlaylistDetail(playlist: playlist)
                completion()
            }
            return item
        }

        return CPListSection(items: playlistItems)
    }

    private func createBrowseTab() -> CPListTemplate {
        let artistsItem = CPListItem(text: Localized.artists, detailText: Localized.browseByArtist)
        artistsItem.handler = { [weak self] _, completion in
            self?.showArtists()
            completion()
        }

        let albumsItem = CPListItem(text: Localized.albums, detailText: Localized.browseByAlbum)
        albumsItem.handler = { [weak self] _, completion in
            self?.showAlbums()
            completion()
        }

        let template = CPListTemplate(title: Localized.browse, sections: [CPListSection(items: [artistsItem, albumsItem])])
        template.tabImage = UIImage(systemName: "magnifyingglass")
        addNowPlayingButton(to: template)
        return template
    }

    // MARK: - Navigation Methods

    private func showPlaylistDetail(playlist: Playlist) {
        let tracks = getCompatibleTracks(for: playlist)

        let songItems: [CPListItem] = tracks.enumerated().map { index, track in
            let item = CPListItem(text: track.title, detailText: getArtistName(for: track))
            configureArtwork(for: item, track: track, index: index)
            item.handler = { _, completion in
                Task {
                    let queue = self.forwardQueue(from: tracks, startingAt: index)
                    await AppCoordinator.shared.playTrack(track, queue: queue)
                }
                completion()
            }
            return item
        }

        interfaceController?.pushTemplate(
            CPListTemplate(title: playlist.title, sections: [CPListSection(items: songItems)]),
            animated: true,
            completion: nil
        )
    }

    private func showArtists() {
        // Honour the same album-artist preference as the phone. CarPlay caps
        // how many rows it will show and is the worst place to scroll past a
        // hundred single-track featured guests.
        let mode = DeleteSettings.load().artistListMode
        let artists = (try? AppCoordinator.shared.databaseManager.getBrowsableArtists(mode: mode)) ?? []

        let artistItems: [CPListItem] = artists.map { artist in
            let item = CPListItem(text: artist.name, detailText: Localized.artist)
            item.handler = { [weak self] _, completion in
                self?.showArtistDetail(artist: artist)
                completion()
            }
            return item
        }

        interfaceController?.pushTemplate(
            CPListTemplate(title: Localized.artists, sections: [CPListSection(items: artistItems)]),
            animated: true,
            completion: nil
        )
    }

    private func showArtistDetail(artist: Artist) {
        guard let artistId = artist.id else { return }

        let tracks = ((try? AppCoordinator.shared.databaseManager.getTracksByArtistId(artistId)) ?? [])
            .filter(isCompatible)

        let songItems: [CPListItem] = tracks.enumerated().map { index, track in
            let item = CPListItem(text: track.title, detailText: getArtistName(for: track))
            configureArtwork(for: item, track: track, index: index)
            item.handler = { _, completion in
                Task {
                    let queue = self.forwardQueue(from: tracks, startingAt: index)
                    await AppCoordinator.shared.playTrack(track, queue: queue)
                }
                completion()
            }
            return item
        }

        interfaceController?.pushTemplate(
            CPListTemplate(title: artist.name, sections: [CPListSection(items: songItems)]),
            animated: true,
            completion: nil
        )
    }

    private func showAlbums() {
        let albums = (try? AppCoordinator.shared.getAllAlbums()) ?? []

        let albumItems: [CPListItem] = albums.map { album in
            let item = CPListItem(text: album.title, detailText: getArtistNameForAlbum(album))
            configureAlbumArtwork(for: item, album: album)
            item.handler = { [weak self] _, completion in
                self?.showAlbumDetail(album: album)
                completion()
            }
            return item
        }

        interfaceController?.pushTemplate(
            CPListTemplate(title: Localized.albums, sections: [CPListSection(items: albumItems)]),
            animated: true,
            completion: nil
        )
    }

    private func showAlbumDetail(album: Album) {
        guard let albumId = album.id else { return }

        let tracks = ((try? AppCoordinator.shared.databaseManager.getTracksByAlbumId(albumId)) ?? [])
            .filter(isCompatible)
            .sorted {
                let disc0 = $0.discNo ?? 1
                let disc1 = $1.discNo ?? 1
                if disc0 != disc1 { return disc0 < disc1 }
                return ($0.trackNo ?? 0) < ($1.trackNo ?? 0)
            }

        let songItems: [CPListItem] = tracks.enumerated().map { index, track in
            let item = CPListItem(text: track.title, detailText: getArtistName(for: track))
            configureArtwork(for: item, track: track, index: index)
            item.handler = { _, completion in
                Task {
                    let queue = self.forwardQueue(from: tracks, startingAt: index)
                    await AppCoordinator.shared.playTrack(track, queue: queue)
                }
                completion()
            }
            return item
        }

        interfaceController?.pushTemplate(
            CPListTemplate(title: album.title, sections: [CPListSection(items: songItems)]),
            animated: true,
            completion: nil
        )
    }

    // MARK: - Helpers

    private func addNowPlayingButton(to template: CPListTemplate) {
        guard let nowPlayingImage = UIImage(systemName: "play.circle.fill") else { return }

        let nowPlayingButton = CPBarButton(image: nowPlayingImage) { [weak self] _ in
            self?.showNowPlaying()
        }
        template.trailingNavigationBarButtons = [nowPlayingButton]
    }

    private func showNowPlaying() {
        let nowPlayingTemplate = CPNowPlayingTemplate.shared
        interfaceController?.pushTemplate(nowPlayingTemplate, animated: true, completion: nil)
    }

    private func queueForAllSongs(startingAt index: Int) -> [Track] {
        if let paginatedQueue = try? DatabaseManager.shared.getTracksPaginated(
            limit: maxQueueItems,
            offset: index,
            excludingFormats: incompatibleFormats
        ), !paginatedQueue.isEmpty {
            return paginatedQueue
        }

        return forwardQueue(from: allSongsTracks, startingAt: index)
    }

    private func forwardQueue(from tracks: [Track], startingAt index: Int) -> [Track] {
        guard !tracks.isEmpty else { return [] }
        let safeIndex = max(0, min(index, tracks.count - 1))
        let endIndex = min(safeIndex + maxQueueItems, tracks.count)
        return Array(tracks[safeIndex..<endIndex])
    }

    private func isCompatible(track: Track) -> Bool {
        let ext = URL(fileURLWithPath: track.path).pathExtension.lowercased()
        return !incompatibleFormats.contains(ext)
    }

    private func getCompatibleTracks(for playlist: Playlist) -> [Track] {
        guard let playlistId = playlist.id else { return [] }

        let playlistItems = (try? AppCoordinator.shared.databaseManager.getPlaylistItems(playlistId: playlistId)) ?? []
        let trackIds = playlistItems.map { $0.trackStableId }
        let allPlaylistTracks = (try? AppCoordinator.shared.databaseManager.getTracksByStableIdsPreservingOrder(trackIds)) ?? []
        return allPlaylistTracks.filter(isCompatible)
    }

    private func configureArtwork(for item: CPListItem, track: Track, index _: Int) {
        item.setImage(createPlaceholderImage())
        Task { @MainActor in
            if let artwork = await ArtworkManager.shared.getArtwork(for: track) {
                item.setImage(resizeImageForCarPlay(artwork, rounded: true))
            }
        }
    }

    private func configureAlbumArtwork(for item: CPListItem, album: Album) {
        item.setImage(createPlaceholderImage(systemName: "opticaldisc.fill"))
        Task { @MainActor in
            guard let albumId = album.id,
                  let firstTrack = ((try? DatabaseManager.shared.getTracksByAlbumId(albumId)) ?? []).first(where: isCompatible),
                  let artwork = await ArtworkManager.shared.getArtwork(for: firstTrack) else {
                return
            }

            item.setImage(resizeImageForCarPlay(artwork, rounded: true))
        }
    }

    private func configurePlaylistArtwork(for item: CPListItem, playlist: Playlist, tracks: [Track]) {
        item.setImage(createPlaceholderImage(systemName: "music.note.list"))

        Task { @MainActor in
            if let customCover = loadCustomPlaylistCover(for: playlist) {
                item.setImage(resizeImageForCarPlay(customCover, rounded: true))
                return
            }

            var artworks: [UIImage] = []
            var seenStableIds = Set<String>()

            for track in tracks where artworks.count < 4 {
                guard !seenStableIds.contains(track.stableId) else { continue }
                seenStableIds.insert(track.stableId)

                if let artwork = await ArtworkManager.shared.getArtwork(for: track) {
                    artworks.append(artwork)
                }
            }

            if let collage = createPlaylistCollageImage(from: artworks) {
                item.setImage(collage)
            }
        }
    }

    private func getArtistName(for track: Track) -> String {
        // Resolved in one batched query during the fetch. The per-track lookup
        // below is only a fallback for rows the batch did not cover - a
        // drill-down screen, or a "Load More" page.
        if let cached = trackArtistNames[track.stableId] {
            return cached
        }

        if let displayName = try? DatabaseManager.shared.getArtistDisplayName(
            forTrackStableId: track.stableId,
            fallbackArtistId: track.artistId
        ) {
            return displayName
        }

        guard let artistId = track.artistId else { return "" }
        return artistNameCache[artistId] ?? ""
    }

    private func getArtistNameForAlbum(_ album: Album) -> String {
        if let albumArtist = album.albumArtist, !albumArtist.isEmpty {
            return albumArtist
        }

        guard let artistId = album.artistId else { return "" }
        return artistNameCache[artistId] ?? ""
    }
}

// Helper function to resize images for CarPlay with aspect-fill cropping
@MainActor
private func resizeImageForCarPlay(_ image: UIImage, rounded: Bool = false) -> UIImage {
    let maxSize = CPListItem.maximumImageSize

    let squareSize = min(maxSize.width, maxSize.height)
    let targetSize = CGSize(width: squareSize, height: squareSize)

    let renderer = UIGraphicsImageRenderer(size: targetSize)
    return renderer.image { _ in
        if rounded {
            let path = UIBezierPath(roundedRect: CGRect(origin: .zero, size: targetSize), cornerRadius: 8)
            path.addClip()
        }

        drawAspectFill(image, in: CGRect(origin: .zero, size: targetSize))
    }
}

@MainActor
private func drawAspectFill(_ image: UIImage, in rect: CGRect) {
    let imageSize = image.size
    let scale = max(rect.width / imageSize.width, rect.height / imageSize.height)
    let scaledWidth = imageSize.width * scale
    let scaledHeight = imageSize.height * scale
    let x = rect.midX - scaledWidth / 2
    let y = rect.midY - scaledHeight / 2

    image.draw(in: CGRect(x: x, y: y, width: scaledWidth, height: scaledHeight))
}

@MainActor
private func loadCustomPlaylistCover(for playlist: Playlist) -> UIImage? {
    guard let customPath = playlist.customCoverImagePath, !customPath.isEmpty else {
        return nil
    }

    guard let containerURL = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: "group.dev.clq.Cosmos-Music-Player"
    ) else {
        return nil
    }

    let fileURL = containerURL.appendingPathComponent(customPath)
    guard let data = try? Data(contentsOf: fileURL) else {
        return nil
    }

    return UIImage(data: data)
}

@MainActor
private func createPlaylistCollageImage(from artworks: [UIImage]) -> UIImage? {
    guard !artworks.isEmpty else { return nil }

    let maxSize = CPListItem.maximumImageSize
    let squareSize = min(maxSize.width, maxSize.height)
    let targetSize = CGSize(width: squareSize, height: squareSize)
    let tileSize = squareSize / 2

    let renderer = UIGraphicsImageRenderer(size: targetSize)
    return renderer.image { _ in
        let path = UIBezierPath(roundedRect: CGRect(origin: .zero, size: targetSize), cornerRadius: 8)
        path.addClip()

        UIColor.systemGray5.setFill()
        UIRectFill(CGRect(origin: .zero, size: targetSize))

        for index in 0..<4 {
            let image = artworks[index % artworks.count]
            let origin = CGPoint(
                x: index.isMultiple(of: 2) ? 0 : tileSize,
                y: index < 2 ? 0 : tileSize
            )
            drawAspectFill(image, in: CGRect(origin: origin, size: CGSize(width: tileSize, height: tileSize)))
        }
    }
}

@MainActor
private func createPlaceholderImage(systemName: String = "music.note") -> UIImage {
    let size = CPListItem.maximumImageSize
    let renderer = UIGraphicsImageRenderer(size: size)

    return renderer.image { _ in
        let path = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8)
        UIColor.systemGray5.setFill()
        path.fill()

        let iconSize: CGFloat = size.width * 0.5
        let iconRect = CGRect(
            x: (size.width - iconSize) / 2,
            y: (size.height - iconSize) / 2,
            width: iconSize,
            height: iconSize
        )

        if let musicIcon = UIImage(systemName: systemName)?.withConfiguration(
            UIImage.SymbolConfiguration(pointSize: iconSize * 0.6, weight: .medium)
        ) {
            UIColor.systemGray3.setFill()
            musicIcon.draw(in: iconRect, blendMode: .normal, alpha: 1.0)
        }
    }
}
