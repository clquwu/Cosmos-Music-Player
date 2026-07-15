//
//  IntentHandler.swift
//  SiriIntentsExtension
//
//  Created by CLQ on 15/09/2025.
//

import Intents
import Foundation
import GRDB
#if canImport(FoundationModels)
import FoundationModels
#endif

// String similarity extension for fuzzy matching
extension String {
    var siriSearchNormalized: String {
        let folded = folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        let searchable = folded.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }
            .joined()
        return searchable
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .joined(separator: " ")
    }

    func levenshteinDistance(to other: String) -> Int {
        let selfArray = Array(self.lowercased())
        let otherArray = Array(other.lowercased())

        let selfCount = selfArray.count
        let otherCount = otherArray.count

        if selfCount == 0 { return otherCount }
        if otherCount == 0 { return selfCount }

        var matrix = Array(repeating: Array(repeating: 0, count: otherCount + 1), count: selfCount + 1)

        for i in 0...selfCount {
            matrix[i][0] = i
        }

        for j in 0...otherCount {
            matrix[0][j] = j
        }

        for i in 1...selfCount {
            for j in 1...otherCount {
                if selfArray[i-1] == otherArray[j-1] {
                    matrix[i][j] = matrix[i-1][j-1]
                } else {
                    matrix[i][j] = Swift.min(
                        matrix[i-1][j] + 1,    // deletion
                        matrix[i][j-1] + 1,    // insertion
                        matrix[i-1][j-1] + 1   // substitution
                    )
                }
            }
        }

        return matrix[selfCount][otherCount]
    }

    func similarityScore(to other: String) -> Double {
        let left = siriSearchNormalized
        let right = other.siriSearchNormalized
        let distance = left.levenshteinDistance(to: right)
        let maxLength = Swift.max(left.count, right.count)
        return maxLength == 0 ? 1.0 : 1.0 - (Double(distance) / Double(maxLength))
    }

    func siriSearchScore(against candidate: String) -> Double {
        let query = siriSearchNormalized
        let value = candidate.siriSearchNormalized
        guard !query.isEmpty, !value.isEmpty else { return 0 }
        if query == value { return 1 }
        if value.contains(query) {
            return min(0.98, 0.88 + 0.10 * Double(query.count) / Double(value.count))
        }
        if query.contains(value) {
            return min(0.94, 0.82 + 0.10 * Double(value.count) / Double(query.count))
        }

        let ignoredWords: Set<String> = [
            "a", "an", "the", "song", "music", "track", "play", "please", "by", "from", "in", "on", "cosmos",
            "le", "la", "les", "un", "une", "chanson", "musique", "titre", "joue", "de", "du", "des", "dans", "sur"
        ]
        let queryTokens = query.split(separator: " ").map(String.init).filter { !ignoredWords.contains($0) }
        let valueTokens = value.split(separator: " ").map(String.init)
        let tokenCoverage: Double
        if queryTokens.isEmpty || valueTokens.isEmpty {
            tokenCoverage = 0
        } else {
            let total = queryTokens.reduce(0.0) { partial, token in
                partial + (valueTokens.map { token.similarityScore(to: $0) }.max() ?? 0)
            }
            tokenCoverage = total / Double(queryTokens.count)
        }

        return max(similarityScore(to: value), tokenCoverage * 0.90)
    }
}

struct RankedSimpleTrack: Sendable {
    let track: SimpleTrack
    let score: Double
}

// Temporary Siri-routing diagnostics: append to a log in the app group
// container so it can be pulled off-device with devicectl.
enum SiriDiag {
    static func log(_ message: String) {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.dev.clq.Cosmos-Music-Player"
        ) else { return }
        let dir = container.appendingPathComponent("Library", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("siri-diagnostics.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(message)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}

// Simple shared database access for extension
class ExtensionDatabaseAccess {
    static let shared = ExtensionDatabaseAccess()

    private var dbQueue: DatabaseQueue?

    private init() {
        setupDatabase()
    }

    private func setupDatabase() {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.dev.clq.Cosmos-Music-Player") else {
            print("❌ Unable to get app group container")
            return
        }

        let databaseURL = containerURL.appendingPathComponent("cosmos_music.db")

        do {
            dbQueue = try DatabaseQueue(path: databaseURL.path)
            print("✅ Extension database connected at: \(databaseURL.path)")
        } catch {
            print("❌ Failed to connect to extension database: \(error)")
        }
    }

    func rankedTrackCandidates(
        query: String,
        artistName: String? = nil,
        albumName: String? = nil,
        limit: Int = 25
    ) -> [RankedSimpleTrack] {
        guard let dbQueue = dbQueue else { return [] }

        do {
            return try dbQueue.read { db in
                // Rank the complete library. Siri transcription errors may not
                // share a literal SQL substring, and the previous LIMIT 100
                // meant most libraries were never considered at all.
                let tracks = try SimpleTrack.fetchAll(db, sql: """
                    SELECT track.stable_id,
                           track.title,
                           artist.name AS artist_name,
                           album.title AS album_title
                    FROM track
                    LEFT JOIN artist ON artist.id = track.artist_id
                    LEFT JOIN album ON album.id = track.album_id
                    ORDER BY track.title
                    """)

                return tracks.map { track in
                    let metadata = [track.title, track.artistName, track.albumTitle]
                        .compactMap { $0 }
                        .joined(separator: " ")
                    var score = max(
                        query.siriSearchScore(against: track.title),
                        query.siriSearchScore(against: metadata) * 0.94
                    )
                    if let artistName, !artistName.siriSearchNormalized.isEmpty {
                        score += artistName.siriSearchScore(against: track.artistName ?? "") * 0.10
                    }
                    if let albumName, !albumName.siriSearchNormalized.isEmpty {
                        score += albumName.siriSearchScore(against: track.albumTitle ?? "") * 0.08
                    }
                    return RankedSimpleTrack(track: track, score: min(score, 1))
                }
                .sorted {
                    if abs($0.score - $1.score) > 0.0001 { return $0.score > $1.score }
                    return $0.track.title.localizedCaseInsensitiveCompare($1.track.title) == .orderedAscending
                }
                .prefix(limit)
                .map { $0 }
            }
        } catch {
            print("❌ Error ranking tracks: \(error)")
            return []
        }
    }

    func searchTracks(query: String, artistName: String? = nil, albumName: String? = nil) -> [SimpleTrack] {
        let ranked = rankedTrackCandidates(query: query, artistName: artistName, albumName: albumName)
        guard let best = ranked.first, best.score >= 0.58 else {
            print("🎵 Track search '\(query)': no confident match")
            return []
        }
        let cutoff = max(0.58, best.score - 0.10)
        let results = ranked.prefix(5).filter { $0.score >= cutoff }.map(\.track)
        print("🎵 Smart track search '\(query)': \(results.count) matches, best=\(String(format: "%.2f", best.score))")
        return results
    }

    func searchPlaylists(query: String) -> [SimplePlaylist] {
        guard let dbQueue = dbQueue else { return [] }

        do {
            return try dbQueue.read { db in
                if query.isEmpty {
                    let sql = "SELECT id, title FROM playlist ORDER BY last_played_at DESC, title"
                    return try SimplePlaylist.fetchAll(db, sql: sql)
                } else {
                    var results: [SimplePlaylist] = []

                    // 1. Exact match first
                    let exactSql = "SELECT id, title FROM playlist WHERE title = ? COLLATE NOCASE ORDER BY title"
                    results = try SimplePlaylist.fetchAll(db, sql: exactSql, arguments: [query])

                    if results.isEmpty {
                        // 2. Contains match
                        let searchPattern = "%\(query)%"
                        let likeSql = "SELECT id, title FROM playlist WHERE title LIKE ? COLLATE NOCASE ORDER BY title"
                        results = try SimplePlaylist.fetchAll(db, sql: likeSql, arguments: [searchPattern])
                    }

                    if results.isEmpty {
                        // 3. Fuzzy matching - get all playlists and find similar ones
                        let allSql = "SELECT id, title FROM playlist ORDER BY title"
                        let allPlaylists = try SimplePlaylist.fetchAll(db, sql: allSql)

                        let fuzzyResults = allPlaylists.compactMap { playlist -> (SimplePlaylist, Double)? in
                            let similarity = query.similarityScore(to: playlist.title)
                            // Use a threshold of 0.6 for fuzzy matching (60% similarity)
                            return similarity >= 0.6 ? (playlist, similarity) : nil
                        }

                        // Sort by similarity score descending
                        results = fuzzyResults
                            .sorted { $0.1 > $1.1 }
                            .map { $0.0 }

                        print("📋 Fuzzy playlist search '\(query)': found \(results.count) matches with similarity >= 0.6")
                        for result in results.prefix(3) {
                            let score = query.similarityScore(to: result.title)
                            print("  - '\(result.title)' (similarity: \(String(format: "%.2f", score)))")
                        }
                    }

                    print("📋 Playlist search '\(query)': \(results.count) results")
                    return results
                }
            }
        } catch {
            print("❌ Error searching playlists: \(error)")
            return []
        }
    }

    func getAllTracks() -> [SimpleTrack] {
        guard let dbQueue = dbQueue else { return [] }

        do {
            return try dbQueue.read { db in
                let sql = "SELECT stable_id, title FROM track ORDER BY id DESC"
                return try SimpleTrack.fetchAll(db, sql: sql)
            }
        } catch {
            print("❌ Error getting all tracks: \(error)")
            return []
        }
    }

    func getFavorites() -> [String] {
        guard let dbQueue = dbQueue else { return [] }

        do {
            return try dbQueue.read { db in
                let sql = "SELECT track_stable_id FROM favorite"
                return try String.fetchAll(db, sql: sql)
            }
        } catch {
            print("❌ Error getting favorites: \(error)")
            return []
        }
    }

    func getTracksByStableIds(_ stableIds: [String]) -> [SimpleTrack] {
        guard let dbQueue = dbQueue else { return [] }
        guard !stableIds.isEmpty else { return [] }

        do {
            return try dbQueue.read { db in
                let placeholders = Array(repeating: "?", count: stableIds.count).joined(separator: ", ")
                let sql = "SELECT stable_id, title FROM track WHERE stable_id IN (\(placeholders)) ORDER BY id DESC"
                return try SimpleTrack.fetchAll(db, sql: sql, arguments: StatementArguments(stableIds))
            }
        } catch {
            print("❌ Error getting tracks by stable IDs: \(error)")
            return []
        }
    }
}

// Simple data structures for extension
struct SimpleTrack: Codable, FetchableRecord, Sendable {
    var stableId: String
    var title: String
    var artistName: String?
    var albumTitle: String?

    static let databaseTableName = "track"

    enum CodingKeys: String, CodingKey {
        case title
        case stableId = "stable_id"
        case artistName = "artist_name"
        case albumTitle = "album_title"
    }
}


struct SimplePlaylist: Codable, FetchableRecord {
    var id: Int64?
    var title: String

    static let databaseTableName = "playlist"
}

struct SimpleFavorite: Codable, FetchableRecord {
    var trackStableId: String

    static let databaseTableName = "favorite"

    enum CodingKeys: String, CodingKey {
        case trackStableId = "track_stable_id"
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@MainActor
private enum SiriLanguageModelSongMatcher {
    static func bestMatch(
        query: String,
        artistName: String?,
        albumName: String?,
        candidates: [RankedSimpleTrack]
    ) async -> SimpleTrack? {
        guard case .available = SystemLanguageModel.default.availability,
              !candidates.isEmpty else { return nil }

        let shortlist = Array(candidates.prefix(20))
        let catalog = shortlist.enumerated().map { index, candidate in
            let track = candidate.track
            return "\(index): title=\(track.title) | artist=\(track.artistName ?? "unknown") | album=\(track.albumTitle ?? "unknown")"
        }.joined(separator: "\n")

        let prompt = """
        A person asked Siri to play a song from their private Cosmos library.
        Spoken words can be misspelled or transcribed phonetically. Select the
        one catalog entry that most likely means the requested song. Consider
        title, artist, album, soundtrack/franchise names, abbreviations and
        transcription mistakes. Never invent a song. If no entry is a
        plausible match, answer NONE. Otherwise answer only its numeric index.

        Requested title: \(query)
        Artist hint: \(artistName ?? "none")
        Album hint: \(albumName ?? "none")

        Catalog:
        \(catalog)
        """

        let session = LanguageModelSession()
        guard let response = try? await session.respond(to: prompt) else { return nil }
        let answer = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if answer.uppercased().contains("NONE") { return nil }
        let index = answer
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
            .first
        guard let index, shortlist.indices.contains(index) else { return nil }
        SiriDiag.log("EXT LLM matched query=\(query) index=\(index) title=\(shortlist[index].track.title)")
        return shortlist[index].track
    }
}
#endif

class IntentHandler: INExtension, INPlayMediaIntentHandling, INAddMediaIntentHandling {

    private let database = ExtensionDatabaseAccess.shared

    override func handler(for intent: INIntent) -> Any {
        switch intent {
        case is INPlayMediaIntent:
            return self
        default:
            return self
        }
    }

    // MARK: - INPlayMediaIntentHandling

    func resolveMediaItems(for intent: INPlayMediaIntent, with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void) {
        // NOTE: Siri still routes by-name media requests here even when the
        // assistant-schema App Intents are registered (verified on iOS 27.0
        // beta, 2026-07-15) and does NOT fall back to the schema path if we
        // return .unsupported — so this extension keeps serving all OS
        // versions. Schema intents handle context-based and open-ended
        // requests in parallel.
        guard let mediaSearch = intent.mediaSearch else {
            print("❌ No media search in intent")
            completion([INPlayMediaMediaItemResolutionResult.unsupported()])
            return
        }

        print("🎤 resolveMediaItems called with search: type=\(mediaSearch.mediaType), name='\(mediaSearch.mediaName ?? "nil")'")
        SiriDiag.log("EXT resolveMediaItems type=\(mediaSearch.mediaType.rawValue) name=\(mediaSearch.mediaName ?? "nil") artist=\(mediaSearch.artistName ?? "nil") album=\(mediaSearch.albumName ?? "nil") reference=\(mediaSearch.reference.rawValue)")

        Task { @MainActor in
            let mediaItems = await resolveActualMediaItems(from: mediaSearch)
            print("🎤 resolveActualMediaItems returned \(mediaItems.count) items")

            SiriDiag.log("EXT resolved \(mediaItems.count) items: \(mediaItems.map { $0.identifier ?? "nil" }.joined(separator: ","))")
            if mediaItems.isEmpty {
                // A successful sentinel lets handling return a normal Siri
                // failure response. Returning .unsupported makes Siri offer
                // to "continue in Cosmos", even though opening the app cannot
                // repair a genuinely missing library item.
                let missing = INMediaItem(
                    identifier: "cosmos_not_found",
                    title: "I couldn't find that song in Cosmos",
                    type: .song,
                    artwork: nil,
                    artist: nil
                )
                completion([INPlayMediaMediaItemResolutionResult.success(with: missing)])
                return
            }
            print("✅ Returning \(mediaItems.count) media items as successes")
            completion(INPlayMediaMediaItemResolutionResult.successes(with: mediaItems))
        }
    }

    // MARK: - INAddMediaIntentHandling ("add this song to favorites / to <playlist>")

    func resolveMediaItems(for intent: INAddMediaIntent, with completion: @escaping ([INAddMediaMediaItemResolutionResult]) -> Void) {
        let mediaSearch = intent.mediaSearch
        SiriDiag.log("EXT AddMedia resolve name=\(mediaSearch?.mediaName ?? "nil") reference=\(mediaSearch?.reference.rawValue ?? -1)")

        // A named song: match it in the library.
        if let name = mediaSearch?.mediaName, mediaSearch?.reference != .currentlyPlaying {
            let tracks = database.searchTracks(query: name)
            if let track = tracks.first {
                completion([INAddMediaMediaItemResolutionResult.success(with: INMediaItem(
                    identifier: track.stableId,
                    title: track.title,
                    type: .song,
                    artwork: nil,
                    artist: nil
                ))])
                return
            }
        }

        // Default: the currently playing song (the app resolves it).
        completion([INAddMediaMediaItemResolutionResult.success(with: INMediaItem(
            identifier: "current_track",
            title: "Current Song",
            type: .song,
            artwork: nil,
            artist: nil
        ))])
    }

    func handle(intent: INAddMediaIntent, completion: @escaping (INAddMediaIntentResponse) -> Void) {
        SiriDiag.log("EXT AddMedia handle -> handleInApp")
        completion(INAddMediaIntentResponse(code: .handleInApp, userActivity: nil))
    }

    func handle(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        SiriDiag.log("EXT handle -> handleInApp items=\(intent.mediaItems?.compactMap { $0.identifier }.joined(separator: ",") ?? "none")")
        if intent.mediaItems?.contains(where: { $0.identifier == "cosmos_not_found" }) == true {
            completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
            return
        }
        // Return handleInApp to launch the main app and handle playback there
        completion(INPlayMediaIntentResponse(code: .handleInApp, userActivity: createUserActivity(from: intent)))
    }

    // MARK: - Private Methods

    @MainActor
    private func smartSongMatches(from mediaSearch: INMediaSearch, query: String) async -> [SimpleTrack] {
        let ranked = database.rankedTrackCandidates(
            query: query,
            artistName: mediaSearch.artistName,
            albumName: mediaSearch.albumName
        )
        let bestScore = ranked.first?.score ?? 0
        let cutoff = max(0.58, bestScore - 0.10)
        let deterministic = ranked.prefix(5).filter { $0.score >= cutoff }.map(\.track)

        // Exact or near-exact unique matches do not need model latency.
        if bestScore >= 0.94, deterministic.count == 1 {
            return deterministic
        }

#if canImport(FoundationModels)
        if #available(iOS 26.0, *),
           let modelMatch = await SiriLanguageModelSongMatcher.bestMatch(
               query: query,
               artistName: mediaSearch.artistName,
               albumName: mediaSearch.albumName,
               candidates: ranked
           ) {
            return [modelMatch]
        }
#endif

        return deterministic
    }

    @MainActor
    private func resolveActualMediaItems(from mediaSearch: INMediaSearch) async -> [INMediaItem] {
        print("🎤 Resolving media for type: \(mediaSearch.mediaType), name: '\(mediaSearch.mediaName ?? "nil")', reference: \(mediaSearch.reference)")

        // Log all search parameters for debugging
        if let artistName = mediaSearch.artistName {
            print("🎤 Artist name: '\(artistName)'")
        }
        if let albumName = mediaSearch.albumName {
            print("🎤 Album name: '\(albumName)'")
        }

        // Enhanced debugging for playlists
        if mediaSearch.mediaType == .playlist {
            print("🎤 PLAYLIST DEBUG - mediaName: '\(mediaSearch.mediaName ?? "nil")', reference: \(mediaSearch.reference)")
            if let mediaName = mediaSearch.mediaName {
                print("🎤 PLAYLIST DEBUG - mediaName lowercased: '\(mediaName.lowercased())'")
            }
        }

        // Check if this is a favorites request regardless of media type
        if let mediaName = mediaSearch.mediaName {
            let lowercased = mediaName.lowercased()
            print("🔍 Checking if '\(mediaName)' is a favorites request...")

            let englishFavoriteKeywords = [
                "favorite", "favourite", "liked", "love", "loved",
                "liked songs", "favorite songs", "favourite songs",
                "my liked songs", "my favorite songs", "my favourite songs",
                "my loved songs", "loved songs"
            ]
            // French keywords
            let frenchFavoriteKeywords = [
                "préféré", "prefere", "favori", "favoris", "aimé", "aime", "coup de coeur",
                "chansons préférées", "mes chansons préférées", "chansons aimées",
                "mes chansons aimées", "musique préférée", "ma musique préférée"
            ]

            let isFavorites = englishFavoriteKeywords.contains { lowercased.contains($0) } ||
                             frenchFavoriteKeywords.contains { lowercased.contains($0) }

            if isFavorites {
                print("🎵 FAVORITES DETECTED: '\(mediaName)'")
                let favoriteIds = database.getFavorites()
                print("🎵 Found \(favoriteIds.count) favorite track IDs: \(favoriteIds)")

                if !favoriteIds.isEmpty {
                    let tracks = database.getTracksByStableIds(favoriteIds)
                    print("🎵 Retrieved \(tracks.count) favorite tracks from database")
                    return tracks.map { track in
                        INMediaItem(
                            identifier: track.stableId,
                            title: track.title,
                            type: .song,
                            artwork: nil,
                            artist: nil
                        )
                    }
                } else {
                    print("🎵 No favorites in database - returning empty to avoid playing all music")
                    return [INMediaItem(
                        identifier: "no_favorites",
                        title: "No Favorites",
                        type: .song,
                        artwork: nil,
                        artist: nil
                    )]
                }
            }

            // For "my songs" or "my music", return special identifier to play all music
            // English variations
            let englishMusicKeywords = ["my songs", "my music", "all my songs", "all my music"]
            // French variations
            let frenchMusicKeywords = ["ma musique", "mes chansons", "toute ma musique", "toutes mes chansons", "ma bibliothèque", "ma collection"]

            let isAllMusic = englishMusicKeywords.contains(lowercased) || frenchMusicKeywords.contains(lowercased)

            if isAllMusic {
                print("🎵 MY SONGS/MUSIC DETECTED: '\(mediaName)' - will play all music")
                return [INMediaItem(
                    identifier: "music_all",
                    title: "My Music",
                    type: .music,
                    artwork: nil
                )]
            }
        }

        // Also check for .my reference without media name - should play all music, not favorites
        if mediaSearch.reference == .my && mediaSearch.mediaName == nil {
            print("🎵 MY REFERENCE DETECTED without media name - will play all music")
            return [INMediaItem(
                identifier: "music_all",
                title: "My Music",
                type: .music,
                artwork: nil
            )]
        }

        switch mediaSearch.mediaType {
        case .song:
            if let songName = mediaSearch.mediaName {
                let tracks = await smartSongMatches(from: mediaSearch, query: songName)
                print("🎵 Found \(tracks.count) tracks for '\(songName)'")
                return tracks.map { track in
                    INMediaItem(
                        identifier: track.stableId,
                        title: track.title,
                        type: .song,
                        artwork: nil,
                        artist: track.artistName
                    )
                }
            } else if mediaSearch.reference == .my {
                // "Play my songs" - should play all music
                print("🎵 Playing my songs - will play all music")
                return [INMediaItem(
                    identifier: "music_all",
                    title: "My Music",
                    type: .music,
                    artwork: nil
                )]
            } else {
                return []
            }

        case .album:
            if let albumName = mediaSearch.mediaName {
                // The app database knows albums; resolve there.
                return [INMediaItem(
                    identifier: "search_album_\(albumName)",
                    title: albumName,
                    type: .album,
                    artwork: nil
                )]
            }
            return [INMediaItem(
                identifier: "music_all",
                title: "My Music",
                type: .music,
                artwork: nil
            )]

        case .artist:
            if let artistName = mediaSearch.mediaName ?? mediaSearch.artistName {
                // The app database knows artists; resolve there.
                return [INMediaItem(
                    identifier: "search_artist_\(artistName)",
                    title: artistName,
                    type: .artist,
                    artwork: nil
                )]
            }
            return [INMediaItem(
                identifier: "music_all",
                title: "My Music",
                type: .music,
                artwork: nil
            )]

        case .playlist:
            if let playlistName = mediaSearch.mediaName {
                // Handle French playlist keywords that might be passed as playlist names
                let lowercased = playlistName.lowercased()
                let frenchPlaylistKeywords = ["ma playlist", "ma liste de lecture", "mes playlists", "liste de lecture"]

                // Check if this is a generic French playlist request
                if frenchPlaylistKeywords.contains(lowercased) {
                    print("📋 French 'my playlist' detected: '\(playlistName)'")
                    let playlists = database.searchPlaylists(query: "")
                    print("📋 Found \(playlists.count) playlists for French 'my playlist'")
                    if !playlists.isEmpty {
                        return [INMediaItem(
                            identifier: "playlist_\(playlists[0].id ?? 0)",
                            title: playlists[0].title,
                            type: .playlist,
                            artwork: nil
                        )]
                    }
                    // Return generic "my playlist" item
                    return [INMediaItem(
                        identifier: "my_playlist",
                        title: "Ma Playlist",
                        type: .playlist,
                        artwork: nil
                    )]
                } else {
                    // Regular playlist name search
                    let playlists = database.searchPlaylists(query: playlistName)
                    print("📋 Found \(playlists.count) playlists for '\(playlistName)'")
                    if !playlists.isEmpty {
                        return playlists.map { playlist in
                            INMediaItem(
                                identifier: "playlist_\(playlist.id ?? 0)",
                                title: playlist.title,
                                type: .playlist,
                                artwork: nil
                            )
                        }
                    }

                    // If no exact matches, return a search item
                    return [INMediaItem(
                        identifier: "search_playlist_\(playlistName)",
                        title: playlistName,
                        type: .playlist,
                        artwork: nil
                    )]
                }
            } else if mediaSearch.reference == .my {
                let playlists = database.searchPlaylists(query: "")
                print("📋 Found \(playlists.count) playlists for 'my playlist'")
                if !playlists.isEmpty {
                    return [INMediaItem(
                        identifier: "playlist_\(playlists[0].id ?? 0)",
                        title: playlists[0].title,
                        type: .playlist,
                        artwork: nil
                    )]
                }

                // Return generic "my playlist" item
                return [INMediaItem(
                    identifier: "my_playlist",
                    title: "My Playlist",
                    type: .playlist,
                    artwork: nil
                )]
            }
            // Fallback for playlists - never return empty
            return [INMediaItem(
                identifier: "search_playlist_unknown",
                title: "Playlist",
                type: .playlist,
                artwork: nil
            )]

        case .music:
            print("🎵 Resolving 'play my music'")
            return [INMediaItem(
                identifier: "music_all",
                title: "My Music",
                type: .music,
                artwork: nil
            )]

        default:
            // iOS 27 Siri routinely sends mediaType == .unknown with only a
            // spoken name — resolve by name across every kind instead of
            // falling back to the whole library.
            if let name = mediaSearch.mediaName ?? mediaSearch.artistName {
                SiriDiag.log("EXT unknown-type name search: \(name)")
                let tracks = await smartSongMatches(from: mediaSearch, query: name)
                if !tracks.isEmpty {
                    print("🎵 Unknown-type: matched \(tracks.count) tracks for '\(name)'")
                    return tracks.map { track in
                        INMediaItem(
                            identifier: track.stableId,
                            title: track.title,
                            type: .song,
                            artwork: nil,
                            artist: track.artistName
                        )
                    }
                }
                let playlists = database.searchPlaylists(query: name)
                if let playlist = playlists.first {
                    print("📋 Unknown-type: matched playlist '\(playlist.title)' for '\(name)'")
                    return [INMediaItem(
                        identifier: "playlist_\(playlist.id ?? 0)",
                        title: playlist.title,
                        type: .playlist,
                        artwork: nil
                    )]
                }
                // Do not manufacture a successful item for a failed lookup.
                // That forces Siri to launch the app and say "continue in
                // Cosmos" even though there is no matching library content.
                return []
            }
            print("❌ Unsupported media type with no name: \(mediaSearch.mediaType)")
            return [INMediaItem(
                identifier: "music_all",
                title: "Music",
                type: .music,
                artwork: nil
            )]
        }
    }

    private func createUserActivity(from intent: INPlayMediaIntent) -> NSUserActivity {
        let activity = NSUserActivity(activityType: "com.cosmos.music.play")

        if let mediaSearch = intent.mediaSearch {
            var userInfo: [String: Any] = [:]

            userInfo["mediaType"] = mediaSearch.mediaType.rawValue

            if let mediaName = mediaSearch.mediaName {
                userInfo["mediaName"] = mediaName
            }

            if let artistName = mediaSearch.artistName {
                userInfo["artistName"] = artistName
            }

            if let albumName = mediaSearch.albumName {
                userInfo["albumName"] = albumName
            }

            userInfo["reference"] = mediaSearch.reference.rawValue

            if let mediaItems = intent.mediaItems {
                let identifiers = mediaItems.compactMap { $0.identifier }
                userInfo["mediaIdentifiers"] = identifiers
            }

            activity.userInfo = userInfo
        }

        return activity
    }
}
