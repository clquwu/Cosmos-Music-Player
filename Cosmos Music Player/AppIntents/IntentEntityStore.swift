//
//  IntentEntityStore.swift
//  Cosmos Music Player
//
//  Builds App Entities from the GRDB models for entity queries and the
//  Spotlight index. Read-only; all data comes from DatabaseManager.
//

#if canImport(MediaIntents)
import Foundation

@available(iOS 27.0, *)
@MainActor
final class IntentEntityStore {

    private var database: DatabaseManager { DatabaseManager.shared }

    private var unknownArtistName: String {
        NSLocalizedString("unknown_artist", value: "Unknown Artist", comment: "")
    }

    // MARK: - Songs

    func songEntities(for identifiers: [String]) throws -> [SongEntity] {
        let tracks = try database.getTracksByStableIdsPreservingOrder(identifiers)
        return try songEntities(from: tracks)
    }

    func allSongEntities() throws -> [SongEntity] {
        try songEntities(from: database.getAllTracks())
    }

    /// Favorites first — shown as suggestions in Shortcuts parameter pickers.
    func suggestedSongEntities(limit: Int = 50) throws -> [SongEntity] {
        let favorites = try database.getTracksByStableIds(database.getFavorites())
        var tracks = favorites
        if tracks.count < limit {
            let favoriteIds = Set(favorites.map(\.stableId))
            let fill = try database.getAllTracks().filter { !favoriteIds.contains($0.stableId) }
            tracks.append(contentsOf: fill.prefix(limit - tracks.count))
        }
        return try songEntities(from: Array(tracks.prefix(limit)))
    }

    func songEntities(matching string: String) throws -> [SongEntity] {
        try songEntities(from: database.searchTracks(query: string))
    }

    func songEntities(from tracks: [Track]) throws -> [SongEntity] {
        guard !tracks.isEmpty else { return [] }
        let artistNames = try database.getAllArtistNamesById()
        let albumsById = try albumLookup()

        return tracks.map { track in
            let artistName = track.artistId.flatMap { artistNames[$0] } ?? unknownArtistName
            let albumEntity = track.albumId.flatMap { albumsById[$0] }.map { album in
                AlbumEntity(album: album, artistName: albumArtistName(for: album, artistNames: artistNames))
            }
            return SongEntity(track: track, artistName: artistName, album: albumEntity)
        }
    }

    // MARK: - Albums

    func albumEntities(for identifiers: [String]) throws -> [AlbumEntity] {
        let wanted = Set(identifiers.compactMap(Int64.init))
        let albums = try database.getAllAlbums().filter { album in
            guard let id = album.id else { return false }
            return wanted.contains(id)
        }
        return try albumEntities(from: albums, loadSongs: true)
    }

    func allAlbumEntities(limit: Int? = nil) throws -> [AlbumEntity] {
        var albums = try database.getAllAlbums()
        if let limit { albums = Array(albums.prefix(limit)) }
        return try albumEntities(from: albums, loadSongs: false)
    }

    func albumEntities(matching string: String) throws -> [AlbumEntity] {
        try albumEntities(from: database.searchAlbums(query: string), loadSongs: false)
    }

    private func albumEntities(from albums: [Album], loadSongs: Bool) throws -> [AlbumEntity] {
        guard !albums.isEmpty else { return [] }
        let artistNames = try database.getAllArtistNamesById()

        return try albums.compactMap { album in
            guard let albumId = album.id else { return nil }
            let artistName = albumArtistName(for: album, artistNames: artistNames)
            var songs: [SongEntity] = []
            if loadSongs {
                songs = try database.getTracksByAlbumId(albumId).map { track in
                    let trackArtist = track.artistId.flatMap { artistNames[$0] } ?? artistName
                    return SongEntity(track: track, artistName: trackArtist, album: nil)
                }
            }
            return AlbumEntity(album: album, artistName: artistName, songs: songs)
        }
    }

    private func albumLookup() throws -> [Int64: Album] {
        let albums = try database.getAllAlbums()
        return Dictionary(
            albums.compactMap { album in album.id.map { ($0, album) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func albumArtistName(for album: Album, artistNames: [Int64: String]) -> String {
        if let albumArtist = album.albumArtist, !albumArtist.isEmpty {
            return albumArtist
        }
        return album.artistId.flatMap { artistNames[$0] } ?? unknownArtistName
    }

    // MARK: - Artists

    func artistEntities(for identifiers: [String]) throws -> [ArtistEntity] {
        let wanted = Set(identifiers)
        let artists = try database.getAllArtists().filter { wanted.contains($0.name) }
        return try artistEntities(from: artists)
    }

    func allArtistEntities(limit: Int? = nil) throws -> [ArtistEntity] {
        var artists = try database.getAllArtists()
        if let limit { artists = Array(artists.prefix(limit)) }
        return try artistEntities(from: artists)
    }

    func artistEntities(matching string: String) throws -> [ArtistEntity] {
        try artistEntities(from: database.searchArtists(query: string))
    }

    private func artistEntities(from artists: [Artist]) throws -> [ArtistEntity] {
        try artists.map { artist in
            var albums: [AlbumEntity] = []
            if let artistId = artist.id {
                albums = try database.getAlbumsByArtistId(artistId).map {
                    AlbumEntity(album: $0, artistName: artist.name)
                }
            }
            return ArtistEntity(name: artist.name, albums: albums)
        }
    }

    // MARK: - Playlists

    func playlistEntities(for identifiers: [String]) throws -> [PlaylistEntity] {
        let wanted = Set(identifiers.compactMap(Int64.init))
        let playlists = try database.getAllPlaylists().filter { playlist in
            guard let id = playlist.id else { return false }
            return wanted.contains(id)
        }
        return try playlistEntities(from: playlists)
    }

    func allPlaylistEntities() throws -> [PlaylistEntity] {
        try playlistEntities(from: database.getAllPlaylists())
    }

    func playlistEntities(matching string: String) throws -> [PlaylistEntity] {
        try playlistEntities(from: database.searchPlaylists(query: string))
    }

    private func playlistEntities(from playlists: [Playlist]) throws -> [PlaylistEntity] {
        try playlists.compactMap { playlist in
            guard let playlistId = playlist.id else { return nil }
            let items = try database.getPlaylistItems(playlistId: playlistId)
            let tracks = try database.getTracksByStableIds(items.map(\.trackStableId))
            let totalDuration = TimeInterval(tracks.reduce(0) { $0 + ($1.durationMs ?? 0) }) / 1000.0
            return PlaylistEntity(playlist: playlist, trackCount: items.count, totalDuration: totalDuration)
        }
    }
}

#endif // canImport(MediaIntents)
