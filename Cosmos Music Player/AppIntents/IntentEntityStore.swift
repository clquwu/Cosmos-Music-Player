//
//  IntentEntityStore.swift
//  Cosmos Music Player
//
//  Builds App Entities from the GRDB models for entity queries and the
//  Spotlight index. Read-only; all data comes from DatabaseManager.
//

#if canImport(MediaIntents)
import Foundation

// Not main-actor bound: it holds no state, and every method is database
// reads (GRDB's pool is thread-safe) plus value building. On the main actor,
// the Spotlight reindex and Shortcuts' suggestion queries built an entity
// for every song, album, artist and playlist on the main thread - hundreds
// of milliseconds of frozen UI a few seconds after each launch and scan on
// a large library.
@available(iOS 27.0, *)
final class IntentEntityStore: Sendable {

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
        let favorites = try database.getTracksByStableIdsPreservingOrder(database.getFavorites())
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
        let literal = try database.searchArtists(query: string)
        if !literal.isEmpty { return try artistEntities(from: literal) }
        // Speech rarely spells a name the way the tags do ("Shiva Sagisu"
        // for Shiro Sagisu): fall back to the fuzzy matcher.
        return try artistEntities(from: ArtistMatcher.artists(matching: string, in: database.getAllArtists()))
    }

    /// The artists with the most songs: the values Siri pre-registers for
    /// App Shortcut phrases such as "Mélange <artiste> dans Cosmos".
    func topArtistEntities(limit: Int) throws -> [ArtistEntity] {
        // Counted by SQL: this runs on the main actor at launch, after every
        // scan and on each trip to the background, and loading every track
        // just to count them stalled the UI on large libraries.
        let songCount = try database.artistSongCounts().byArtist
        let artists = try database.getAllArtists()
            .filter { $0.id != nil }
            .sorted { songCount[$0.id!, default: 0] > songCount[$1.id!, default: 0] }
        return try artistEntities(from: Array(artists.prefix(limit)))
    }

    private func artistEntities(from artists: [Artist]) throws -> [ArtistEntity] {
        // Every artist's albums from one query: the Spotlight index builds
        // an entity for every artist in the library, and a query per artist
        // was the bulk of a main-thread stall after each launch and scan.
        // A handful of artists (a Siri lookup) keeps the per-artist query.
        let albumsByArtist = artists.count > 8 ? try database.getAlbumsByArtist() : nil
        return try artists.map { artist in
            var albums: [AlbumEntity] = []
            if let artistId = artist.id {
                let artistAlbums = try albumsByArtist.map { $0[artistId] ?? [] }
                    ?? database.getAlbumsByArtistId(artistId)
                albums = artistAlbums.map {
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
        // Counts and lengths summed by SQL for all playlists at once. Every
        // playlist's songs used to be loaded in full just to add up their
        // durations - on each Shortcuts suggestion and Spotlight reindex.
        let stats = try database.getPlaylistItemStats()
        return playlists.compactMap { playlist in
            guard let playlistId = playlist.id else { return nil }
            let stat = stats[playlistId] ?? (itemCount: 0, durationMs: 0)
            let totalDuration = TimeInterval(stat.durationMs) / 1000.0
            return PlaylistEntity(playlist: playlist, trackCount: stat.itemCount, totalDuration: totalDuration)
        }
    }
}

#endif // canImport(MediaIntents)
