//
//  IntentPlaybackService.swift
//  Cosmos Music Player
//
//  Single playback/library surface for App Intents. Wraps PlayerEngine,
//  AppCoordinator and DatabaseManager so intents never touch them directly.
//

import Foundation

@MainActor
final class IntentPlaybackService {

    private var playerEngine: PlayerEngine { PlayerEngine.shared }
    private var coordinator: AppCoordinator { AppCoordinator.shared }
    private var database: DatabaseManager { DatabaseManager.shared }

    // MARK: - Playback

    var currentTrack: Track? { playerEngine.currentTrack }
    var isPlaying: Bool { playerEngine.isPlaying }

    func resume() {
        playerEngine.play()
    }

    func pause() {
        playerEngine.pause()
    }

    /// Starts playback of a queue, setting up the background audio session
    /// first — required when Siri launches the app in the background.
    func play(tracks: [Track], startingAt index: Int = 0) async {
        guard !tracks.isEmpty else { return }
        let startIndex = min(max(index, 0), tracks.count - 1)
        await coordinator.prepareSiriAudioSession()
        await coordinator.playTrack(tracks[startIndex], queue: tracks)
    }

    func insertNext(_ track: Track) {
        playerEngine.insertNext(track)
    }

    func addToQueue(_ track: Track) {
        playerEngine.addToQueue(track)
    }

    /// Queues multiple tracks right after the current one, preserving order.
    /// Falls back to starting playback when nothing is queued.
    func insertNext(_ tracks: [Track]) async {
        guard playerEngine.currentTrack != nil else {
            await play(tracks: tracks)
            return
        }
        for track in tracks.reversed() {
            playerEngine.insertNext(track)
        }
    }

    /// Appends multiple tracks to the end of the queue.
    /// Falls back to starting playback when nothing is queued.
    func addToQueue(_ tracks: [Track]) async {
        guard playerEngine.currentTrack != nil else {
            await play(tracks: tracks)
            return
        }
        for track in tracks {
            playerEngine.addToQueue(track)
        }
    }

    func toggleShuffle() {
        playerEngine.toggleShuffle()
    }

    var isShuffled: Bool { playerEngine.isShuffled }

    func setShuffle(_ enabled: Bool) {
        if playerEngine.isShuffled != enabled {
            playerEngine.toggleShuffle()
        }
    }

    func setQueueRepeat(_ enabled: Bool) {
        playerEngine.isRepeating = enabled
        if enabled {
            playerEngine.isLoopingSong = false
        }
    }

    // MARK: - Library fetch

    func allTracks() throws -> [Track] {
        try database.getAllTracks()
    }

    func favoriteTracks() throws -> [Track] {
        let favoriteIds = try database.getFavorites()
        return try database.getTracksByStableIds(favoriteIds)
    }

    func tracks(inPlaylist playlistId: Int64) throws -> [Track] {
        let items = try database.getPlaylistItems(playlistId: playlistId)
        return try database.getTracksByStableIdsPreservingOrder(items.map(\.trackStableId))
    }

    func searchTracks(query: String) throws -> [Track] {
        try database.searchTracks(query: query)
    }

    func tracks(forStableIds ids: [String]) throws -> [Track] {
        try database.getTracksByStableIdsPreservingOrder(ids)
    }

    func tracks(forAlbumId albumId: Int64) throws -> [Track] {
        try database.getTracksByAlbumId(albumId)
    }

    func tracks(forArtistName name: String) throws -> [Track] {
        guard let artist = try database.getAllArtists().first(where: { $0.name == name }),
              let artistId = artist.id else {
            return []
        }
        return try database.getTracksByArtistId(artistId)
    }

    func searchPlaylists(query: String) throws -> [Playlist] {
        try database.searchPlaylists(query: query)
    }

    func allPlaylists() throws -> [Playlist] {
        try database.getAllPlaylists()
    }

    // MARK: - Library mutation

    func toggleFavorite(trackStableId: String) throws {
        try coordinator.toggleFavorite(trackStableId: trackStableId)
    }

    func isFavorite(trackStableId: String) throws -> Bool {
        try coordinator.isFavorite(trackStableId: trackStableId)
    }

    /// Idempotent like/unlike — only toggles when the state actually changes.
    func setFavorite(trackStableId: String, isFavorite wanted: Bool) throws {
        if try coordinator.isFavorite(trackStableId: trackStableId) != wanted {
            try coordinator.toggleFavorite(trackStableId: trackStableId)
        }
    }

    /// Returns false when the track was already in the playlist.
    func addToPlaylist(playlistId: Int64, trackStableId: String) throws -> Bool {
        let existing = try database.getPlaylistItems(playlistId: playlistId)
        guard !existing.contains(where: { $0.trackStableId == trackStableId }) else {
            return false
        }
        try coordinator.addToPlaylist(playlistId: playlistId, trackStableId: trackStableId)
        return true
    }

    // MARK: - Generated mix

    struct PendingMix {
        let title: String
        let tracks: [Track]
        var savedPlaylistId: Int64?
    }

    /// The most recently generated mix, kept so the result snippet can offer
    /// saving it as a playlist after playback has started.
    private(set) var pendingMix: PendingMix?

    func setPendingMix(title: String, tracks: [Track]) {
        pendingMix = PendingMix(title: title, tracks: tracks, savedPlaylistId: nil)
    }

    /// Saves the pending mix as a playlist. Idempotent: saving twice returns
    /// the already-saved state instead of creating a duplicate playlist.
    func savePendingMix() throws -> (title: String, alreadySaved: Bool)? {
        guard var mix = pendingMix else { return nil }
        if mix.savedPlaylistId != nil {
            return (mix.title, true)
        }
        let playlist = try coordinator.createPlaylist(title: mix.title)
        guard let playlistId = playlist.id else { return nil }
        for track in mix.tracks {
            try coordinator.addToPlaylist(playlistId: playlistId, trackStableId: track.stableId)
        }
        mix.savedPlaylistId = playlistId
        pendingMix = mix
        return (mix.title, false)
    }
}
