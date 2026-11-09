//
//  CosmosSiriActions.swift
//  Cosmos Music Player
//
//  Voice actions shared by the App Intents and the legacy SiriKit hand-off
//  (SiriPlayRouter), so "play my liked songs", "play Made for You" or
//  "a mix like this song" behave the same whichever Siri path heard them.
//
//  Everything here is deterministic and works without Apple Intelligence.
//  Heavy library reads run off the main thread; playback is started with the
//  background audio session prepared first, because Siri usually reaches
//  Cosmos while it is in the background.
//

import Foundation

@MainActor
enum CosmosSiriActions {

    // MARK: - Database

    /// Keeps GRDB awake while a Siri request runs in the background (the
    /// suspension coordinator otherwise aborts every statement), then hands
    /// control back to the coordinator.
    static func withDatabaseAwake<T>(_ body: () async throws -> T) async rethrows -> T {
        DatabaseSuspensionCoordinator.shared.beginHold()
        defer { DatabaseSuspensionCoordinator.shared.endHold() }
        return try await body()
    }

    /// Runs a database read on a background thread.
    nonisolated static func read<T: Sendable>(_ work: @escaping @Sendable (DatabaseManager) throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            try work(DatabaseManager.shared)
        }.value
    }

    // MARK: - Playback

    /// Starts `tracks`, preparing the background audio session first.
    @discardableResult
    static func play(_ tracks: [Track], shuffled: Bool = false, source: String? = nil) async -> Bool {
        let queue = shuffled ? tracks.shuffled() : tracks
        guard let first = queue.first else { return false }
        // Preparing the session suspends; a song chosen meanwhile wins.
        let baseline = MixStore.PlaybackBaseline.now()
        await AppCoordinator.shared.prepareSiriAudioSession()
        guard !baseline.listenerMovedOn else { return false }
        if let source { ListeningLog.shared.tagQueue(source, tracks: queue) }
        await AppCoordinator.shared.playTrack(first, queue: queue)
        // playTrack awaits the load; a hard failure leaves the message set.
        return PlayerEngine.shared.playbackErrorMessage == nil
    }

    /// Polls until `condition` holds or `timeout` passes.
    static func waitUntil(timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    /// The song playing now, restoring the saved session (bounded) when
    /// Siri cold-launched the app, so "this song" is the one last heard.
    static func currentTrackRestoringSession(timeout: Double = 2) async -> Track? {
        if let track = PlayerEngine.shared.currentTrack { return track }
        let restore = Task { @MainActor in await PlayerEngine.shared.ensureSavedStateRestored() }
        _ = await waitUntil(timeout: timeout) { PlayerEngine.shared.currentTrack != nil }
        if PlayerEngine.shared.currentTrack == nil { restore.cancel() }
        return PlayerEngine.shared.currentTrack
    }

    // MARK: - Liked songs

    static func likedTracks() async throws -> [Track] {
        try await read { database in
            try database.getTracksByStableIdsPreservingOrder(database.getFavorites())
        }
    }

    // MARK: - Mixes (Made for You / Rediscover)

    enum MixShelf: String, Sendable {
        case madeForYou
        case rediscover
    }

    /// Makes sure MixStore has its mixes. A cold Siri launch never shows
    /// Home, which is what normally loads them; a saved set loads at once,
    /// a stale one is rebuilt off the main thread (bounded wait).
    @discardableResult
    static func ensureMixesLoaded(timeout: Double = 4.5) async -> Bool {
        let store = MixStore.shared
        if !store.madeForYou.isEmpty || !store.moments.isEmpty { return true }
        let tracks = (try? await read { try $0.getAllTracks() }) ?? []
        guard !tracks.isEmpty else { return false }
        store.rebuild(tracks: tracks)
        return await waitUntil(timeout: timeout) { !store.madeForYou.isEmpty || !store.moments.isEmpty }
    }

    static func allMixes() -> [(mix: Mix, shelf: MixShelf)] {
        MixStore.shared.madeForYou.map { ($0, .madeForYou) } + MixStore.shared.moments.map { ($0, .rediscover) }
    }

    /// The mix whose title best matches a spoken name (accent-insensitive,
    /// tolerant to small mishearings), or nil.
    static func mix(named spoken: String) -> Mix? {
        let query = ArtistMatcher.normalized(spoken)
        guard !query.isEmpty else { return nil }
        let scored = allMixes().map { entry -> (Mix, Double) in
            let title = ArtistMatcher.normalized(entry.mix.title)
            if title == query { return (entry.mix, 1) }
            if title.contains(query) || query.contains(title) { return (entry.mix, 0.9) }
            return (entry.mix, ArtistMatcher.similarity(query, title))
        }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= 0.75 else { return nil }
        return best.0
    }

    static func firstMix(on shelf: MixShelf) -> Mix? {
        switch shelf {
        case .madeForYou: MixStore.shared.madeForYou.first
        case .rediscover: MixStore.shared.moments.first
        }
    }

    /// Plays a mix and waits (bounded) until its first song is loaded, so
    /// Siri doesn't report success before anything happened.
    @discardableResult
    static func play(mix: Mix, shuffled: Bool = false) async -> Bool {
        let ids = Set(mix.trackIds)
        guard !ids.isEmpty else { return false }
        let baseline = MixStore.PlaybackBaseline.now()
        await AppCoordinator.shared.prepareSiriAudioSession()
        guard !baseline.listenerMovedOn else { return false }
        let before = PlayerEngine.shared.currentTrack?.stableId
        // MixStore.play only spawns the play: until it runs, the old song's
        // state (playing, or a stale error) is still what the engine shows.
        // Its playTrack bumps the choice counter in the same main-actor turn
        // that selects the song and clears the error.
        let choice = PlayerEngine.shared.listenerChoiceGeneration
        MixStore.shared.play(mix, shuffled: shuffled)
        // playTrack selects the song before loading it, so a new current
        // song alone says nothing: wait for it to play or to fail.
        let settled = await waitUntil(timeout: 4) {
            let player = PlayerEngine.shared
            guard player.listenerChoiceGeneration != choice,
                  let current = player.currentTrack?.stableId, ids.contains(current) else { return false }
            return player.isPlaying || player.playbackErrorMessage != nil
        }
        let player = PlayerEngine.shared
        guard player.listenerChoiceGeneration != choice,
              let current = player.currentTrack?.stableId, ids.contains(current),
              player.playbackErrorMessage == nil else { return false }
        // Not playing yet but no error either: still downloading from iCloud,
        // or held by an interruption - it starts on its own.
        return settled || current != before
    }

    // MARK: - Something for now ("play something for tonight")

    enum Moment: String, Sendable {
        case now
        case tonight

        /// The part of the day asked for: nil for now, the evening for
        /// tonight - or the night, once it is already late.
        var dayPart: Int? {
            guard self == .tonight else { return nil }
            return MixEngine.dayPart(of: Date(), calendar: .current) == 3 ? 3 : 2
        }
    }

    /// Plays the mix for the listening mode that fits the moment - its time,
    /// the day and the output playing now (`MixStore.mixForMoment`) - and
    /// returns it, or nil when there was nothing to play.
    static func playSomething(for moment: Moment) async -> Mix? {
        // Building the mix can take a moment; a song or album chosen
        // meanwhile wins over it rather than being replaced. Taken before
        // loading the mixes, which can itself take seconds on a cold launch.
        let baseline = MixStore.PlaybackBaseline.now()
        await ensureMixesLoaded()
        guard let mix = await MixStore.shared.mixForMoment(dayPart: moment.dayPart),
              !Task.isCancelled, !baseline.listenerMovedOn else { return nil }
        return await play(mix: mix) ? mix : nil
    }

    // MARK: - Song radio ("a mix like this song")

    /// A mix grown from `seed`, as "Song Mix" in a song's menu makes it.
    /// `requiresCompanions`: report failure, playing nothing, when the
    /// engine finds no song to add to the seed (the caller has a fallback).
    @discardableResult
    static func playSongRadio(seed: Track, requiresCompanions: Bool = false) async -> Bool {
        // Still downloading from iCloud counts: it plays once its bytes land,
        // so reporting failure would have Siri say nothing started.
        switch await songRadio(seed: seed, requiresCompanions: requiresCompanions) {
        case .playing, .loading: return true
        case .noCompanions, .notStarted, .failed: return false
        }
    }

    private enum SongRadioResult {
        case playing
        /// Started and not failed, but not playing yet: still downloading from
        /// iCloud, held by an interruption, or paused by the listener.
        case loading
        case noCompanions
        /// Started, but its first song failed to load: it stays current yet
        /// will never play.
        case failed
        /// Superseded by the listener or a newer mix: nothing to replace.
        case notStarted
    }

    private static func songRadio(seed: Track, requiresCompanions: Bool) async -> SongRadioResult {
        await AppCoordinator.shared.prepareSiriAudioSession()
        // Awaited rather than inferred from the queue: a one-song mix, or
        // one rebuilding the queue already there, did start.
        let current: String
        switch await MixStore.shared.playSongMix(from: seed, requiresCompanions: requiresCompanions) {
        case .started(let playing): current = playing
        case .noCompanions: return .noCompanions
        case .superseded: return .notStarted
        }
        // Its first song can still be materialising from iCloud.
        let playing = await waitUntil(timeout: 5) {
            let player = PlayerEngine.shared
            return player.currentTrack?.stableId == current && player.isPlaying
        }
        if playing { return .playing }
        let player = PlayerEngine.shared
        guard player.currentTrack?.stableId == current else { return .notStarted }
        // A hard load failure leaves the song current but stopped, and always
        // sets the error message. Without one it is still downloading, held
        // by an interruption, or the listener paused it - none is a failure,
        // and the artist fallback must not replace it.
        return player.playbackErrorMessage == nil ? .loading : .failed
    }

    /// A mix grown from one of the artist's songs; the artist's songs
    /// shuffled when the mix engine has nothing to add or the seed failed to
    /// load. Only then: a mix superseded by the listener's own choice, or
    /// still loading its first song, must not be replaced by the fallback.
    @discardableResult
    static func playArtistRadio(spoken: String) async throws -> Bool {
        let tracks = try await read { try $0.tracksForSpokenArtist(spoken) }
        guard let seed = tracks.randomElement() else { return false }
        switch await songRadio(seed: seed, requiresCompanions: true) {
        case .playing, .loading: return true
        case .notStarted: return false
        // A seed that failed to load: the shuffle draws on the artist's other
        // songs too, rather than leaving silence reported as success.
        case .noCompanions, .failed: return await play(tracks, shuffled: true, source: "artist")
        }
    }

    // MARK: - Library search (Shortcuts "Play" by name)

    enum SearchHit {
        case tracks([Track], source: String)
        case mix(Mix)
    }

    /// Cascade used by the by-name App Intent: liked phrase → mix → playlist
    /// → artist → album → song. Fuzzy where the tags rarely match speech.
    static func search(_ spoken: String) async throws -> SearchHit? {
        let query = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        if let mix = mix(named: query) { return .mix(mix) }

        return try await read { database -> SearchHit? in
            let normalized = ArtistMatcher.normalized(query)
            let playlists = try database.getAllPlaylists()
            let exactPlaylist = playlists.first { ArtistMatcher.normalized($0.title) == normalized }
            let playlistHit = try exactPlaylist ?? database.searchPlaylists(query: query).first
            if let playlist = playlistHit, let id = playlist.id {
                let ids = try database.getPlaylistItems(playlistId: id).map(\.trackStableId)
                let tracks = try database.getTracksByStableIdsPreservingOrder(ids)
                if !tracks.isEmpty { return .tracks(tracks, source: "playlist") }
            }
            let songs = try database.searchTracks(query: query)
            let exactSong = songs.contains { ArtistMatcher.normalized($0.title) == normalized }
            if !exactSong {
                let artistTracks = try database.tracksForSpokenArtist(query)
                if !artistTracks.isEmpty { return .tracks(artistTracks, source: "artist") }
                if let album = try database.searchAlbums(query: query).first, let id = album.id {
                    let tracks = try database.getTracksByAlbumId(id)
                    if !tracks.isEmpty { return .tracks(tracks, source: "album") }
                }
            }
            if let song = songs.first {
                let all = try database.getAllTracks()
                let start = all.firstIndex { $0.stableId == song.stableId } ?? 0
                return .tracks(Array(all[start...]) + Array(all[..<start]), source: "search")
            }
            return nil
        }
    }

    /// Best single track for a spoken song name.
    static func track(named spoken: String) async throws -> Track? {
        try await read { try $0.searchTracks(query: spoken).first }
    }
}
