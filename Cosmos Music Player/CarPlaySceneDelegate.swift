import CarPlay
import UIKit

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    var interfaceController: CPInterfaceController?
    var allTracks: [Track] = []
    var lastSelectedTabIndex: Int = 0

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                 didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController

        // Fetch all tracks and filter incompatible formats for CarPlay
        let allFetchedTracks = (try? AppCoordinator.shared.getAllTracks()) ?? []
        self.allTracks = allFetchedTracks.filter { track in
            let ext = URL(fileURLWithPath: track.path).pathExtension.lowercased()
            let incompatibleFormats = ["ogg", "opus", "dsf", "dff"]
            return !incompatibleFormats.contains(ext)
        }

        // Update SFBAudioEngine CarPlay status
        SFBAudioEngineManager.shared.updateCarPlayStatus()

        // Create tab bar template with top tabs
        let allSongsTemplate = createAllSongsTab(tracks: allTracks)
        let favoritesTemplate = createFavoritesTab(tracks: allTracks)
        let playlistsTemplate = createPlaylistsTab()
        let searchTemplate = createSearchTab(tracks: allTracks)

        let tabBarTemplate = CPTabBarTemplate(templates: [allSongsTemplate, favoritesTemplate, playlistsTemplate, searchTemplate])

        interfaceController.setRootTemplate(tabBarTemplate, animated: true, completion: nil)

        // Observe player state changes for Now Playing updates
        setupPlayerStateObserver()
    }

    private func setupPlayerStateObserver() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("PlayerStateChanged"),
            object: nil,
            queue: .main
        ) { _ in
            // CarPlay will automatically update based on MPNowPlayingInfoCenter playbackState
            print("🎛️ Player state changed - CarPlay will sync automatically")
        }
    }

    // MARK: - Tab Creation

    private func createAllSongsTab(tracks: [Track]) -> CPListTemplate {
        let songItems: [CPListItem] = tracks.map { track in
            let artistName = getArtistName(for: track)
            let item = CPListItem(text: track.title, detailText: artistName)

            // Image loading disabled - causes crashes on real CarPlay hardware
            // when images haven't been preprocessed

            item.handler = { _, completion in
                Task {
                    await AppCoordinator.shared.playTrack(track, queue: tracks)
                }
                completion()
            }
            return item
        }

        let section = CPListSection(items: songItems)
        let template = CPListTemplate(title: Localized.allSongs, sections: [section])
        template.tabImage = UIImage(systemName: "music.note")

        // Add Now Playing button to trailing bar
        if let nowPlayingImage = UIImage(systemName: "play.circle.fill") {
            let nowPlayingButton = CPBarButton(image: nowPlayingImage) { [weak self] _ in
                self?.showNowPlaying()
            }
            template.trailingNavigationBarButtons = [nowPlayingButton]
        }

        return template
    }

    private func createFavoritesTab(tracks: [Track]) -> CPListTemplate {
        let favoriteIds = (try? AppCoordinator.shared.getFavorites()) ?? []
        let likedTracks = tracks.filter { favoriteIds.contains($0.stableId) }

        let songItems: [CPListItem] = likedTracks.map { track in
            let artistName = getArtistName(for: track)
            let item = CPListItem(text: track.title, detailText: artistName)

            // Image loading disabled - causes crashes on real CarPlay hardware
            // when images haven't been preprocessed

            item.handler = { _, completion in
                Task {
                    await AppCoordinator.shared.playTrack(track, queue: likedTracks)
                }
                completion()
            }
            return item
        }

        let section = CPListSection(items: songItems)
        let template = CPListTemplate(title: Localized.likedSongs, sections: [section])
        template.tabImage = UIImage(systemName: "heart.fill")

        // Add Now Playing button
        if let nowPlayingImage = UIImage(systemName: "play.circle.fill") {
            let nowPlayingButton = CPBarButton(image: nowPlayingImage) { [weak self] _ in
                self?.showNowPlaying()
            }
            template.trailingNavigationBarButtons = [nowPlayingButton]
        }

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

        let section = CPListSection(items: playlistItems)
        let template = CPListTemplate(title: Localized.playlists, sections: [section])
        template.tabImage = UIImage(systemName: "music.note.list")

        // Add Now Playing button
        if let nowPlayingImage = UIImage(systemName: "play.circle.fill") {
            let nowPlayingButton = CPBarButton(image: nowPlayingImage) { [weak self] _ in
                self?.showNowPlaying()
            }
            template.trailingNavigationBarButtons = [nowPlayingButton]
        }

        return template
    }

    private func createSearchTab(tracks: [Track]) -> CPListTemplate {
        // Show browse categories
        let artistsItem = CPListItem(text: Localized.artists, detailText: Localized.browseByArtist)
        artistsItem.handler = { [weak self] _, completion in
            self?.showArtists(tracks: tracks)
            completion()
        }

        let albumsItem = CPListItem(text: Localized.albums, detailText: Localized.browseByAlbum)
        albumsItem.handler = { [weak self] _, completion in
            self?.showAlbums(tracks: tracks)
            completion()
        }

        let section = CPListSection(items: [artistsItem, albumsItem])
        let template = CPListTemplate(title: Localized.browse, sections: [section])
        template.tabImage = UIImage(systemName: "magnifyingglass")

        // Add Now Playing button
        if let nowPlayingImage = UIImage(systemName: "play.circle.fill") {
            let nowPlayingButton = CPBarButton(image: nowPlayingImage) { [weak self] _ in
                self?.showNowPlaying()
            }
            template.trailingNavigationBarButtons = [nowPlayingButton]
        }

        return template
    }

    // MARK: - Now Playing

    private func showNowPlaying() {
        let nowPlayingTemplate = CPNowPlayingTemplate.shared
        interfaceController?.pushTemplate(nowPlayingTemplate, animated: true, completion: nil)
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                 didDisconnect interfaceController: CPInterfaceController) {
        self.interfaceController = nil

        // Update SFBAudioEngineManager's CarPlay status
        print("🚗 CarPlay disconnected")
        Task { @MainActor in
            SFBAudioEngineManager.shared.updateCarPlayStatus()
        }
    }

    // MARK: - Navigation Methods

    private func showAllSongs(tracks: [Track]) {
        let songItems: [CPListItem] = tracks.map { track in
            let artistName = getArtistName(for: track)
            let item = CPListItem(text: track.title, detailText: artistName)

            // Add artwork asynchronously
            Task { @MainActor in
                if let artwork = await ArtworkManager.shared.getArtwork(for: track) {
                    let resizedImage = resizeImageForCarPlay(artwork, rounded: true)
                    item.setImage(resizedImage)
                } else {
                    // Set placeholder image
                    let placeholder = createPlaceholderImage()
                    item.setImage(placeholder)
                }
            }

            item.handler = { _, completion in
                Task {
                    await AppCoordinator.shared.playTrack(track, queue: tracks)
                }
                completion()
            }
            return item
        }

        let section = CPListSection(items: songItems)
        let listTemplate = CPListTemplate(title: Localized.allSongs, sections: [section])
        interfaceController?.pushTemplate(listTemplate, animated: true, completion: nil)
    }

    private func showLikedSongs(tracks: [Track]) {
        let favoriteIds = (try? AppCoordinator.shared.getFavorites()) ?? []
        let likedTracks = tracks.filter { favoriteIds.contains($0.stableId) }

        let songItems: [CPListItem] = likedTracks.map { track in
            let artistName = getArtistName(for: track)
            let item = CPListItem(text: track.title, detailText: artistName)
            item.handler = { _, completion in
                Task {
                    await AppCoordinator.shared.playTrack(track, queue: likedTracks)
                }
                completion()
            }
            return item
        }

        let section = CPListSection(items: songItems)
        let listTemplate = CPListTemplate(title: Localized.likedSongs, sections: [section])
        interfaceController?.pushTemplate(listTemplate, animated: true, completion: nil)
    }

    private func showPlaylists() {
        let playlists = (try? AppCoordinator.shared.databaseManager.getAllPlaylists()) ?? []

        let playlistItems: [CPListItem] = playlists.map { playlist in
            let item = CPListItem(text: playlist.title, detailText: nil)
            item.handler = { [weak self] _, completion in
                self?.showPlaylistDetail(playlist: playlist)
                completion()
            }
            return item
        }

        let section = CPListSection(items: playlistItems)
        let listTemplate = CPListTemplate(title: Localized.playlists, sections: [section])
        interfaceController?.pushTemplate(listTemplate, animated: true, completion: nil)
    }

    private func showPlaylistDetail(playlist: Playlist) {
        guard let playlistId = playlist.id else { return }

        // Get playlist tracks using the same logic as PlaylistDetailScreen
        let playlistItems = (try? AppCoordinator.shared.databaseManager.getPlaylistItems(playlistId: playlistId)) ?? []
        let allTracks = (try? AppCoordinator.shared.getAllTracks()) ?? []
        let allPlaylistTracks = playlistItems.compactMap { item in
            allTracks.first { $0.stableId == item.trackStableId }
        }

        // Filter out incompatible formats for CarPlay
        let tracks = allPlaylistTracks.filter { track in
            let ext = URL(fileURLWithPath: track.path).pathExtension.lowercased()
            let incompatibleFormats = ["ogg", "opus", "dsf", "dff"]
            return !incompatibleFormats.contains(ext)
        }

        let songItems: [CPListItem] = tracks.map { track in
            let artistName = getArtistName(for: track)
            let item = CPListItem(text: track.title, detailText: artistName)

            // Image loading disabled - causes crashes on real CarPlay hardware
            // when images haven't been preprocessed

            item.handler = { _, completion in
                Task {
                    await AppCoordinator.shared.playTrack(track, queue: tracks)
                }
                completion()
            }
            return item
        }

        let section = CPListSection(items: songItems)
        let listTemplate = CPListTemplate(title: playlist.title, sections: [section])
        interfaceController?.pushTemplate(listTemplate, animated: true, completion: nil)
    }

    private func showArtists(tracks: [Track]) {
        let artists = (try? AppCoordinator.shared.databaseManager.getAllArtists()) ?? []

        let artistItems: [CPListItem] = artists.map { artist in
            let artistTracks = tracks.filter { $0.artistId == artist.id }
            let item = CPListItem(text: artist.name, detailText: "\(artistTracks.count) songs")
            item.handler = { [weak self] _, completion in
                self?.showArtistDetail(artist: artist, tracks: artistTracks)
                completion()
            }
            return item
        }

        let section = CPListSection(items: artistItems)
        let listTemplate = CPListTemplate(title: Localized.artists, sections: [section])
        interfaceController?.pushTemplate(listTemplate, animated: true, completion: nil)
    }

    private func showArtistDetail(artist: Artist, tracks: [Track]) {
        // Filter out incompatible formats for CarPlay
        let filteredTracks = tracks.filter { track in
            let ext = URL(fileURLWithPath: track.path).pathExtension.lowercased()
            let incompatibleFormats = ["ogg", "opus", "dsf", "dff"]
            return !incompatibleFormats.contains(ext)
        }

        let songItems: [CPListItem] = filteredTracks.map { track in
            let artistName = getArtistName(for: track)
            let item = CPListItem(text: track.title, detailText: artistName)

            // Image loading disabled - causes crashes on real CarPlay hardware
            // when images haven't been preprocessed

            item.handler = { _, completion in
                Task {
                    await AppCoordinator.shared.playTrack(track, queue: filteredTracks)
                }
                completion()
            }
            return item
        }

        let section = CPListSection(items: songItems)
        let listTemplate = CPListTemplate(title: artist.name, sections: [section])
        interfaceController?.pushTemplate(listTemplate, animated: true, completion: nil)
    }

    private func showAlbums(tracks: [Track]) {
        let albums = (try? AppCoordinator.shared.getAllAlbums()) ?? []

        let albumItems: [CPListItem] = albums.map { album in
            let albumTracks = tracks.filter { $0.albumId == album.id }
            let artistName = getArtistNameForAlbum(album)
            let item = CPListItem(text: album.title, detailText: artistName)
            item.handler = { [weak self] _, completion in
                self?.showAlbumDetail(album: album, tracks: albumTracks)
                completion()
            }
            return item
        }

        let section = CPListSection(items: albumItems)
        let listTemplate = CPListTemplate(title: Localized.albums, sections: [section])
        interfaceController?.pushTemplate(listTemplate, animated: true, completion: nil)
    }

    private func showAlbumDetail(album: Album, tracks: [Track]) {
        // Filter out incompatible formats for CarPlay
        let filteredTracks = tracks.filter { track in
            let ext = URL(fileURLWithPath: track.path).pathExtension.lowercased()
            let incompatibleFormats = ["ogg", "opus", "dsf", "dff"]
            return !incompatibleFormats.contains(ext)
        }

        let songItems: [CPListItem] = filteredTracks.map { track in
            let artistName = getArtistName(for: track)
            let item = CPListItem(text: track.title, detailText: artistName)

            // Image loading disabled - causes crashes on real CarPlay hardware
            // when images haven't been preprocessed

            item.handler = { _, completion in
                Task {
                    await AppCoordinator.shared.playTrack(track, queue: filteredTracks)
                }
                completion()
            }
            return item
        }

        let section = CPListSection(items: songItems)
        let listTemplate = CPListTemplate(title: album.title, sections: [section])
        interfaceController?.pushTemplate(listTemplate, animated: true, completion: nil)
    }

    // MARK: - Helper Methods

    private func getArtistName(for track: Track) -> String {
        guard let artistId = track.artistId else { return "" }
        do {
            if let artist = try DatabaseManager.shared.read({ db in
                try Artist.fetchOne(db, key: artistId)
            }) {
                return artist.name
            }
        } catch {
            print("Failed to fetch artist: \(error)")
        }
        return ""
    }

    private func getArtistNameForAlbum(_ album: Album) -> String {
        guard let artistId = album.artistId else { return "" }
        do {
            if let artist = try DatabaseManager.shared.read({ db in
                try Artist.fetchOne(db, key: artistId)
            }) {
                return artist.name
            }
        } catch {
            print("Failed to fetch artist for album: \(error)")
        }
        return ""
    }
}


// MARK: - CPSearchTemplateDelegate

extension CarPlaySceneDelegate: CPSearchTemplateDelegate {
    func searchTemplate(_ searchTemplate: CPSearchTemplate, updatedSearchText searchText: String, completionHandler: @escaping ([CPListItem]) -> Void) {
        guard !searchText.isEmpty else {
            completionHandler([])
            return
        }

        let lowercasedQuery = searchText.lowercased()
        var items: [CPListItem] = []

        // Search songs (by title, artist, album)
        let matchingSongs = allTracks.filter { track in
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

        // Add song results
        for track in matchingSongs {
            let artistName = getArtistName(for: track)
            let item = CPListItem(text: track.title, detailText: artistName)

            // Add artwork
            Task { @MainActor in
                if let artwork = await ArtworkManager.shared.getArtwork(for: track) {
                    let resizedImage = resizeImageForCarPlay(artwork, rounded: true)
                    item.setImage(resizedImage)
                } else {
                    let placeholder = createPlaceholderImage()
                    item.setImage(placeholder)
                }
            }

            item.handler = { _, completion in
                Task {
                    await AppCoordinator.shared.playTrack(track, queue: matchingSongs)
                }
                completion()
            }
            items.append(item)
        }

        // Search artists
        if let allArtists = try? AppCoordinator.shared.databaseManager.getAllArtists() {
            let matchingArtists = allArtists.filter { $0.name.lowercased().contains(lowercasedQuery) }

            for artist in matchingArtists {
                let artistTracks = allTracks.filter { $0.artistId == artist.id }
                let item = CPListItem(text: "🎤 \(artist.name)", detailText: Localized.songsCount(artistTracks.count))
                item.handler = { [weak self] _, completion in
                    self?.showArtistDetail(artist: artist, tracks: artistTracks)
                    completion()
                }
                items.append(item)
            }
        }

        // Search albums
        if let allAlbums = try? AppCoordinator.shared.getAllAlbums() {
            let matchingAlbums = allAlbums.filter { album in
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

            for album in matchingAlbums {
                let albumTracks = allTracks.filter { $0.albumId == album.id }
                let artistName = getArtistNameForAlbum(album)
                let item = CPListItem(text: "💿 \(album.title)", detailText: artistName)
                item.handler = { [weak self] _, completion in
                    self?.showAlbumDetail(album: album, tracks: albumTracks)
                    completion()
                }
                items.append(item)
            }
        }

        // Search playlists
        if let allPlaylists = try? AppCoordinator.shared.databaseManager.getAllPlaylists() {
            let matchingPlaylists = allPlaylists.filter { $0.title.lowercased().contains(lowercasedQuery) }

            for playlist in matchingPlaylists {
                let item = CPListItem(text: "📝 \(playlist.title)", detailText: Localized.playlist)
                item.handler = { [weak self] _, completion in
                    self?.showPlaylistDetail(playlist: playlist)
                    completion()
                }
                items.append(item)
            }
        }

        completionHandler(items)
    }

    func searchTemplate(_ searchTemplate: CPSearchTemplate, selectedResult item: CPListItem, completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

// Helper function to create colored SF Symbol icons
private func createColoredIcon(systemName: String, color: UIColor, size: CGFloat = 480) -> UIImage {
    let config = UIImage.SymbolConfiguration(pointSize: size, weight: .medium)
    let image = UIImage(systemName: systemName, withConfiguration: config)!

    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 640))
    return renderer.image { context in
        // Draw background with color opacity
        let rect = CGRect(x: 20, y: 20, width: 600, height: 600)
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 80)
        color.withAlphaComponent(0.2).setFill()
        path.fill()

        // Draw colored icon centered
        color.setFill()
        image.draw(in: CGRect(x: 100, y: 100, width: 440, height: 440))
    }
}

// Helper function to resize images for CarPlay with aspect-fill cropping
@MainActor
private func resizeImageForCarPlay(_ image: UIImage, rounded: Bool = false) -> UIImage {
    let maxSize = CPListItem.maximumImageSize

    // Use square size for list items
    let squareSize = min(maxSize.width, maxSize.height)
    let targetSize = CGSize(width: squareSize, height: squareSize)

    let renderer = UIGraphicsImageRenderer(size: targetSize)
    return renderer.image { context in
        if rounded {
            // Create rounded square path
            let path = UIBezierPath(roundedRect: CGRect(origin: .zero, size: targetSize), cornerRadius: 8)
            path.addClip()
        }

        // Calculate aspect-fill rect (crop to fill square without distortion)
        let imageSize = image.size
        let scale = max(targetSize.width / imageSize.width, targetSize.height / imageSize.height)
        let scaledWidth = imageSize.width * scale
        let scaledHeight = imageSize.height * scale
        let x = (targetSize.width - scaledWidth) / 2
        let y = (targetSize.height - scaledHeight) / 2

        image.draw(in: CGRect(x: x, y: y, width: scaledWidth, height: scaledHeight))
    }
}

// Helper function to create placeholder image for songs without artwork
@MainActor
private func createPlaceholderImage() -> UIImage {
    let size = CPListItem.maximumImageSize
    let renderer = UIGraphicsImageRenderer(size: size)

    return renderer.image { context in
        // Draw rounded square background
        let path = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8)
        UIColor.systemGray5.setFill()
        path.fill()

        // Draw music note icon
        let iconSize: CGFloat = size.width * 0.5
        let iconRect = CGRect(x: (size.width - iconSize) / 2,
                             y: (size.height - iconSize) / 2,
                             width: iconSize,
                             height: iconSize)

        if let musicIcon = UIImage(systemName: "music.note")?.withConfiguration(
            UIImage.SymbolConfiguration(pointSize: iconSize * 0.6, weight: .medium)
        ) {
            UIColor.systemGray3.setFill()
            musicIcon.draw(in: iconRect, blendMode: .normal, alpha: 1.0)
        }
    }
}
