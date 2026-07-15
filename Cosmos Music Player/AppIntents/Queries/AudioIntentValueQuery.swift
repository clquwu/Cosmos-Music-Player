//
//  AudioIntentValueQuery.swift
//  Cosmos Music Player
//
//  Resolves open-ended Siri requests ("play something", "play some calm
//  jazz") into audio entities. For search queries it returns a broad,
//  token-ranked candidate set across the whole library and lets Apple
//  Intelligence pick; for unspecified requests it returns favorites first.
//

#if canImport(MediaIntents)
import AppIntents
import Foundation
import MediaIntents

@available(iOS 27.0, *)
extension AudioEntity {
    struct AudioIntentValueQuery {

        @Dependency var store: IntentEntityStore

        /// Favorites-first candidates for a bare "play something" request,
        /// so the ranking picks from music the person already endorsed.
        @MainActor
        private func unspecifiedResults() throws -> [AudioEntity] {
            try store.suggestedSongEntities(limit: 50).map(AudioEntity.song)
        }

        /// Tokenized search across songs, albums, artists and playlists.
        /// Songs are ranked by token-hit count with title tie-breaks; the
        /// other kinds are appended unranked as alternative interpretations.
        @MainActor
        private func searchResults(for query: String) throws -> [AudioEntity] {
            let tokens = tokenize(query)
            guard !tokens.isEmpty else { return [] }

            var songsById: [String: SongEntity] = [:]
            var songMatchCounts: [String: Int] = [:]
            var albumsById: [String: AlbumEntity] = [:]
            var artistsById: [String: ArtistEntity] = [:]
            var playlistsById: [String: PlaylistEntity] = [:]

            for token in tokens {
                for entity in try store.songEntities(matching: token) {
                    songsById[entity.id] = entity
                    songMatchCounts[entity.id, default: 0] += 1
                }
                for entity in try store.albumEntities(matching: token) {
                    albumsById[entity.id] = entity
                }
                for entity in try store.artistEntities(matching: token) {
                    artistsById[entity.id] = entity
                }
                for entity in try store.playlistEntities(matching: token) {
                    playlistsById[entity.id] = entity
                }
            }

            let rankedSongs = songsById.values.sorted { lhs, rhs in
                let leftCount = songMatchCounts[lhs.id, default: 0]
                let rightCount = songMatchCounts[rhs.id, default: 0]
                if leftCount != rightCount { return leftCount > rightCount }
                return lhs.title < rhs.title
            }

            return rankedSongs.map(AudioEntity.song)
                + albumsById.values.map(AudioEntity.album)
                + artistsById.values.map(AudioEntity.artist)
                + playlistsById.values.map(AudioEntity.playlist)
        }

        private func tokenize(_ query: String) -> [String] {
            query
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: " ")
                .map(String.init)
                .filter { !$0.isEmpty }
        }
    }
}

@available(iOS 27.0, *)
extension AudioEntity.AudioIntentValueQuery: IntentValueQuery {
    @MainActor
    func values(for input: AudioSearch) async throws -> [AudioEntity] {
        SiriDiag.log("APP AudioIntentValueQuery criteria=\(input.criteria)")
        switch input.criteria {
        case .searchQuery(let query):
            return try searchResults(for: query)
        case .unspecified:
            return try unspecifiedResults()
        case .url:
            return []
        default:
            return []
        }
    }
}

#endif // canImport(MediaIntents)
