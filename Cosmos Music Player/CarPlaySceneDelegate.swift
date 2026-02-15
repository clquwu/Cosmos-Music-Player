import CarPlay
import UIKit

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    private var interfaceController: CPInterfaceController?
    private var allSongsTemplate: CPListTemplate?
    private var allSongsTracks: [Track] = []
    private var artistNameCache: [Int64: String] = [:]

    private let incompatibleFormats = ["ogg", "opus", "dsf", "dff"]
    private let maxArtworkItems = 50
    private let carPlayPageSize = 200
    private let maxQueueItems = 5000

    private var allSongsOffset = 0
    private var allSongsTotal = 0

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                 didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController

        loadInitialCarPlayData()

        // Update SFBAudioEngine CarPlay status
        SFBAudioEngineManager.shared.updateCarPlayStatus()

        let allSongsTemplate = createAllSongsTab()
        self.allSongsTemplate = allSongsTemplate

        let favoritesTemplate = createFavoritesTab()
        let playlistsTemplate = createPlaylistsTab()
        let browseTemplate = createBrowseTab()

        let tabBarTemplate = CPTabBarTemplate(templates: [allSongsTemplate, favoritesTemplate, playlistsTemplate, browseTemplate])
        interfaceController.setRootTemplate(tabBarTemplate, animated: true, completion: nil)

        setupPlayerStateObserver()
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                 didDisconnect interfaceController: CPInterfaceController) {
        self.interfaceController = nil

        print("🚗 CarPlay disconnected")
        Task { @MainActor in
            SFBAudioEngineManager.shared.updateCarPlayStatus()
        }
    }

    private func loadInitialCarPlayData() {
        artistNameCache = (try? DatabaseManager.shared.getAllArtistNamesById()) ?? [:]
        allSongsTotal = (try? DatabaseManager.shared.getTrackCount(excludingFormats: incompatibleFormats)) ?? 0
        allSongsTracks = (try? DatabaseManager.shared.getTracksPaginated(
            limit: carPlayPageSize,
            offset: 0,
            excludingFormats: incompatibleFormats
        )) ?? []
        allSongsOffset = allSongsTracks.count
    }

    private func setupPlayerStateObserver() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("PlayerStateChanged"),
            object: nil,
            queue: .main
        ) { _ in
            print("🎛️ Player state changed - CarPlay will sync automatically")
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
        let likedTracks = (try? DatabaseManager.shared.getFavoriteTracks(excludingFormats: incompatibleFormats)) ?? []

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

        let template = CPListTemplate(title: Localized.likedSongs, sections: [CPListSection(items: items)])
        template.tabImage = UIImage(systemName: "heart.fill")
        addNowPlayingButton(to: template)
        return template
    }

    private func createPlaylistsTab() -> CPListTemplate {
        let playlists = (try? AppCoordinator.shared.databaseManager.getAllPlaylists()) ?? []

        let playlistItems: [CPListItem] = playlists.map { playlist in
            let item = CPListItem(text: playlist.title, detailText: nil)
            item.handler = { [weak self] _, completion in
                self?.showPlaylistDetail(playlist: playlist)
                completion()
            }
            return item
        }

        let template = CPListTemplate(title: Localized.playlists, sections: [CPListSection(items: playlistItems)])
        template.tabImage = UIImage(systemName: "music.note.list")
        addNowPlayingButton(to: template)
        return template
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
        guard let playlistId = playlist.id else { return }

        let playlistItems = (try? AppCoordinator.shared.databaseManager.getPlaylistItems(playlistId: playlistId)) ?? []
        let trackIds = playlistItems.map { $0.trackStableId }
        let allPlaylistTracks = (try? AppCoordinator.shared.databaseManager.getTracksByStableIdsPreservingOrder(trackIds)) ?? []
        let tracks = allPlaylistTracks.filter(isCompatible)

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
        let artists = (try? AppCoordinator.shared.databaseManager.getAllArtists()) ?? []

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

    private func configureArtwork(for item: CPListItem, track: Track, index _: Int) {
        item.setImage(createPlaceholderImage())
        Task { @MainActor in
            if let artwork = await ArtworkManager.shared.getArtwork(for: track) {
                item.setImage(resizeImageForCarPlay(artwork, rounded: true))
            }
        }
    }

    private func getArtistName(for track: Track) -> String {
        guard let artistId = track.artistId else { return "" }
        return artistNameCache[artistId] ?? ""
    }

    private func getArtistNameForAlbum(_ album: Album) -> String {
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

        let imageSize = image.size
        let scale = max(targetSize.width / imageSize.width, targetSize.height / imageSize.height)
        let scaledWidth = imageSize.width * scale
        let scaledHeight = imageSize.height * scale
        let x = (targetSize.width - scaledWidth) / 2
        let y = (targetSize.height - scaledHeight) / 2

        image.draw(in: CGRect(x: x, y: y, width: scaledWidth, height: scaledHeight))
    }
}

@MainActor
private func createPlaceholderImage() -> UIImage {
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

        if let musicIcon = UIImage(systemName: "music.note")?.withConfiguration(
            UIImage.SymbolConfiguration(pointSize: iconSize * 0.6, weight: .medium)
        ) {
            UIColor.systemGray3.setFill()
            musicIcon.draw(in: iconRect, blendMode: .normal, alpha: 1.0)
        }
    }
}
