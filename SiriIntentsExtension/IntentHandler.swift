//
//  IntentHandler.swift
//  SiriIntentsExtension
//
//  Created by CLQ on 15/09/2025.
//

import Intents
import Foundation
import GRDB

// String similarity extension for fuzzy matching
extension String {
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
        let distance = self.levenshteinDistance(to: other)
        let maxLength = Swift.max(self.count, other.count)
        return maxLength == 0 ? 1.0 : 1.0 - (Double(distance) / Double(maxLength))
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

    func searchTracks(query: String) -> [SimpleTrack] {
        guard let dbQueue = dbQueue else { return [] }

        do {
            return try dbQueue.read { db in
                // Try multiple search strategies
                var results: [SimpleTrack] = []

                // 1. Exact match first
                let exactSql = "SELECT stable_id, title FROM track WHERE title = ? COLLATE NOCASE ORDER BY title"
                results = try SimpleTrack.fetchAll(db, sql: exactSql, arguments: [query])

                if results.isEmpty {
                    // 2. Contains match
                    let searchPattern = "%\(query)%"
                    let likeSql = "SELECT stable_id, title FROM track WHERE title LIKE ? COLLATE NOCASE ORDER BY title"
                    results = try SimpleTrack.fetchAll(db, sql: likeSql, arguments: [searchPattern])
                }

                if results.isEmpty {
                    // 3. Word-based search (split query and search for individual words)
                    let words = query.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                    if words.count > 1 {
                        let wordPatterns = words.map { "%\($0)%" }.joined(separator: "' AND title LIKE '")
                        let wordSql = "SELECT stable_id, title FROM track WHERE title LIKE '%\(wordPatterns)%' COLLATE NOCASE ORDER BY title"
                        results = try SimpleTrack.fetchAll(db, sql: wordSql)
                    }
                }

                if results.isEmpty {
                    // 4. Fuzzy matching for tracks (limit to first 100 for performance)
                    let allSql = "SELECT stable_id, title FROM track ORDER BY title LIMIT 100"
                    let allTracks = try SimpleTrack.fetchAll(db, sql: allSql)

                    let fuzzyResults = allTracks.compactMap { track -> (SimpleTrack, Double)? in
                        let similarity = query.similarityScore(to: track.title)
                        return similarity >= 0.7 ? (track, similarity) : nil
                    }

                    results = fuzzyResults
                        .sorted { $0.1 > $1.1 }
                        .prefix(5)
                        .map { $0.0 }

                    if !results.isEmpty {
                        print("🎵 Fuzzy track search '\(query)': found \(results.count) matches")
                        for result in results {
                            let score = query.similarityScore(to: result.title)
                            print("  - '\(result.title)' (similarity: \(String(format: "%.2f", score)))")
                        }
                    }
                }

                print("🎵 Track search '\(query)': \(results.count) results")
                return results
            }
        } catch {
            print("❌ Error searching tracks: \(error)")
            return []
        }
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
struct SimpleTrack: Codable, FetchableRecord {
    var stableId: String
    var title: String

    static let databaseTableName = "track"

    enum CodingKeys: String, CodingKey {
        case title
        case stableId = "stable_id"
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

class IntentHandler: INExtension, INPlayMediaIntentHandling {

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
        guard let mediaSearch = intent.mediaSearch else {
            print("❌ No media search in intent")
            completion([INPlayMediaMediaItemResolutionResult.unsupported()])
            return
        }

        print("🎤 resolveMediaItems called with search: type=\(mediaSearch.mediaType), name='\(mediaSearch.mediaName ?? "nil")'")

        let mediaItems = resolveActualMediaItems(from: mediaSearch)
        print("🎤 resolveActualMediaItems returned \(mediaItems.count) items")

        if mediaItems.isEmpty {
            print("❌ No media items resolved - returning unsupported")
            completion([INPlayMediaMediaItemResolutionResult.unsupported()])
        } else {
            print("✅ Returning \(mediaItems.count) media items as successes")
            for item in mediaItems {
                print("  - \(item.title ?? "unknown") (\(item.identifier ?? "no-id"))")
            }
            completion(INPlayMediaMediaItemResolutionResult.successes(with: mediaItems))
        }
    }

    func handle(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        // Return handleInApp to launch the main app and handle playback there
        completion(INPlayMediaIntentResponse(code: .handleInApp, userActivity: createUserActivity(from: intent)))
    }

    // MARK: - Private Methods

    private func resolveActualMediaItems(from mediaSearch: INMediaSearch) -> [INMediaItem] {
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
                // Regular song search (favorites are handled above)
                let tracks = database.searchTracks(query: songName)
                print("🎵 Found \(tracks.count) tracks for '\(songName)'")
                if !tracks.isEmpty {
                    return tracks.map { track in
                        INMediaItem(
                            identifier: track.stableId,
                            title: track.title,
                            type: .song,
                            artwork: nil,
                            artist: nil
                        )
                    }
                }

                // If no exact matches, try returning a generic item that will be handled by the main app
                return [INMediaItem(
                    identifier: "search_song_\(songName)",
                    title: songName,
                    type: .song,
                    artwork: nil,
                    artist: nil
                )]
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
            // Albums are no longer supported - return generic item to avoid Siri failures
            return [INMediaItem(
                identifier: "music_all",
                title: "My Music",
                type: .music,
                artwork: nil
            )]

        case .artist:
            // Artists are no longer supported - return generic item to avoid Siri failures
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
            print("❌ Unsupported media type: \(mediaSearch.mediaType)")
            // Return a generic item instead of empty array
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
