//
//  MixGenerator.swift
//  Cosmos Music Player
//
//  On-device Foundation Models mix generation: the model picks songs from a
//  numbered candidate list built out of the library (favorites first), so it
//  can only ever choose real tracks. Falls back to token matching when the
//  model is unavailable or returns nothing usable.
//

#if canImport(FoundationModels)
import Foundation
import FoundationModels

@available(iOS 26.0, *)
@Generable
struct GeneratedMixSelection {
    @Guide(description: "Indices of the chosen songs from the numbered candidate list. Choose 10 to 25 songs, best matches first. Only use numbers that appear in the list.")
    var songIndices: [Int]

    @Guide(description: "A short, catchy title for the mix in the same language as the request, e.g. 'Chill Evening' or 'Soirée Détente'. No quotes.")
    var title: String
}

@available(iOS 26.0, *)
@MainActor
final class MixGenerator {

    struct Mix {
        let title: String
        let tracks: [Track]
    }

    private var database: DatabaseManager { DatabaseManager.shared }

    private static let candidateLimit = 120
    private static let fallbackMixSize = 20

    func generate(matching request: String) async throws -> Mix {
        let artistNames = try database.getAllArtistNamesById()
        let albumTitles = try albumTitlesById()
        let candidates = try candidateTracks(
            matching: request,
            artistNames: artistNames,
            albumTitles: albumTitles
        )
        guard !candidates.isEmpty else {
            throw MixGenerationError.emptyLibrary
        }

        if case .available = SystemLanguageModel.default.availability {
            if let mix = try? await generateWithModel(
                request: request,
                candidates: candidates,
                artistNames: artistNames,
                albumTitles: albumTitles
            ) {
                return mix
            }
        }

        return fallbackMix(matching: request, candidates: candidates, artistNames: artistNames, albumTitles: albumTitles)
    }

    // MARK: - Foundation Models path

    private func generateWithModel(
        request: String,
        candidates: [Track],
        artistNames: [Int64: String],
        albumTitles: [Int64: String]
    ) async throws -> Mix? {
        let catalog = candidates.enumerated().map { index, track in
            "\(index). \(describe(track, artistNames: artistNames, albumTitles: albumTitles))"
        }.joined(separator: "\n")

        let instructions = """
        You are a music curator building a mix from someone's personal library. \
        You receive a numbered song list and a request describing the desired \
        mood, genre, activity or artist. Pick the songs that fit the request \
        best, using the titles, artists and album names as your only signals. \
        When the request names a specific artist or album, pick ONLY songs by \
        that artist or from that album as long as at least 8 such songs exist \
        in the list; add other songs only to fill up to 10 when there are \
        fewer matches. Only pick numbers that exist in the list, never invent \
        songs, and don't pick the same number twice.
        """

        let prompt = """
        Request: \(request)

        Song list:
        \(catalog)
        """

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt, generating: GeneratedMixSelection.self)
        let selection = response.content

        var seen = Set<Int>()
        let tracks = selection.songIndices
            .filter { candidates.indices.contains($0) && seen.insert($0).inserted }
            .map { candidates[$0] }

        // Too few picks means the model didn't really engage with the list —
        // let the caller fall back to token matching instead.
        guard tracks.count >= 3 else { return nil }

        let title = selection.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return Mix(title: title.isEmpty ? defaultTitle(for: request) : title, tracks: tracks)
    }

    // MARK: - Fallback path

    private func fallbackMix(
        matching request: String,
        candidates: [Track],
        artistNames: [Int64: String],
        albumTitles: [Int64: String]
    ) -> Mix {
        let tokens = request
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)

        var matched: [Track] = []
        if !tokens.isEmpty {
            let scored: [(track: Track, hits: Int)] = candidates.compactMap { track in
                let haystack = describe(track, artistNames: artistNames, albumTitles: albumTitles).lowercased()
                let hits = tokens.filter { haystack.contains($0) }.count
                return hits > 0 ? (track, hits) : nil
            }
            matched = scored.sorted { $0.hits > $1.hits }.map(\.track)
        }

        // No text matches — candidates are already favorites-first, so a
        // shuffled slice of them is still a personal selection.
        let picked = matched.isEmpty ? candidates.shuffled() : matched
        return Mix(
            title: defaultTitle(for: request),
            tracks: Array(picked.prefix(Self.fallbackMixSize))
        )
    }

    // MARK: - Helpers

    /// Tracks matching the request first (so a named artist/album is fully
    /// represented in the catalog), then favorites, then the rest of the
    /// library, capped so the prompt stays inside the on-device context
    /// window.
    private func candidateTracks(
        matching request: String,
        artistNames: [Int64: String],
        albumTitles: [Int64: String]
    ) throws -> [Track] {
        let all = try database.getAllTracks()
        let tokens = request
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)

        var matched: [Track] = []
        if !tokens.isEmpty {
            let scored: [(track: Track, hits: Int)] = all.compactMap { track in
                let haystack = describe(track, artistNames: artistNames, albumTitles: albumTitles).lowercased()
                let hits = tokens.filter { haystack.contains($0) }.count
                return hits > 0 ? (track, hits) : nil
            }
            matched = scored.sorted { $0.hits > $1.hits }.map(\.track)
        }

        var seen = Set(matched.map(\.stableId))
        var tracks = matched
        if tracks.count < Self.candidateLimit {
            let favorites = try database.getTracksByStableIds(database.getFavorites())
                .filter { seen.insert($0.stableId).inserted }
            tracks.append(contentsOf: favorites.prefix(Self.candidateLimit - tracks.count))
        }
        if tracks.count < Self.candidateLimit {
            let fill = all.filter { seen.insert($0.stableId).inserted }
            tracks.append(contentsOf: fill.prefix(Self.candidateLimit - tracks.count))
        }
        return Array(tracks.prefix(Self.candidateLimit))
    }

    private func albumTitlesById() throws -> [Int64: String] {
        Dictionary(
            try database.getAllAlbums().compactMap { album in album.id.map { ($0, album.title) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func describe(_ track: Track, artistNames: [Int64: String], albumTitles: [Int64: String]) -> String {
        var parts = [track.title]
        if let artistId = track.artistId, let artist = artistNames[artistId] {
            parts.append(artist)
        }
        if let albumId = track.albumId, let album = albumTitles[albumId] {
            parts.append(album)
        }
        return parts.joined(separator: " — ")
    }

    private func defaultTitle(for request: String) -> String {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Cosmos Mix" : trimmed.capitalized
    }
}

@available(iOS 26.0, *)
enum MixGenerationError: Error {
    case emptyLibrary
    case mixUnavailable
}

@available(iOS 26.0, *)
extension MixGenerationError: CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .emptyLibrary:
            LocalizedStringResource(
                "Your library is empty, so there's nothing to build a mix from.",
                comment: "Spoken when a mix is requested but the library has no tracks."
            )
        case .mixUnavailable:
            LocalizedStringResource(
                "That mix isn't available anymore. Ask for a new one.",
                comment: "Spoken when the mix snippet refers to a mix that is no longer pending."
            )
        }
    }
}

#endif // canImport(FoundationModels)
