//
//  MixGenerator.swift
//  Cosmos Music Player
//
//  On-device Foundation Models mix generation, in two steps. The model first
//  reads the request into a structured query - artists, styles, decades,
//  energy - and the whole library is ranked against it using genre, year and
//  tempo tags and the artist profiles, so a request reaches every song rather
//  than a fixed handful. The model then picks from the best-ranked songs, by
//  number, so it can only ever choose real tracks. Falls back to the ranking
//  alone when the model is unavailable or returns nothing usable.
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
@Generable
struct MixRequestQuery {
    @Guide(description: "Artist names the request mentions, exactly as written. Empty if none.")
    var artists: [String]
    @Guide(description: "Broad styles the request asks for. Empty if it names none.", .maximumCount(3))
    var styles: [MusicStyle]
    @Guide(description: "First year of the era asked for, such as 1980 for 'the 80s', or 0 if none", .range(0...2030))
    var fromYear: Int
    @Guide(description: "Last year of the era asked for, such as 1989 for 'the 80s', or 0 if none", .range(0...2030))
    var toYear: Int
    @Guide(description: "Energy asked for from 1 (calm, sleep, focus) to 5 (party, workout), or 0 if the request does not say", .range(0...5))
    var energy: Int
    @Guide(description: "Other important words from the request, such as a mood, an album or a song name. Lower case.", .maximumCount(5))
    var keywords: [String]
}

@available(iOS 26.0, *)
@MainActor
final class MixGenerator {

    struct Mix {
        let title: String
        let tracks: [Track]
    }

    private var database: DatabaseManager { DatabaseManager.shared }

    private static let fallbackMixSize = 20

    /// How long the on-device model may take. The in-app sheet can wait;
    /// Siri cannot - a perform() that outlives its response window is
    /// reported as the generic "Something went wrong", even though a mix
    /// from the plain ranking would have been fine.
    struct Budget {
        /// Seconds for both model steps together; nil means no limit.
        let total: Double?
        /// Cap for the request-reading step, which is optional.
        let queryStep: Double?
        /// Songs shown to the selection step; fewer means a faster prompt.
        let candidateLimit: Int
        /// The selection step is skipped when less than this is left.
        let minimumSelectionTime: Double

        static let unlimited = Budget(total: nil, queryStep: nil, candidateLimit: 120, minimumSelectionTime: 0)
        static let siri = Budget(total: 6, queryStep: 2, candidateLimit: 60, minimumSelectionTime: 2)
    }

    func generate(matching request: String, budget: Budget = .unlimited) async throws -> Mix {
        let started = Date()
        func remaining() -> Double? {
            budget.total.map { $0 - Date().timeIntervalSince(started) }
        }

        let artistNames = try database.getAllArtistNamesById()
        let albumTitles = try albumTitlesById()

        let query: MixRequestQuery?
        if let cap = budget.queryStep {
            query = await IntentRuntime.withDeadline(min(cap, remaining() ?? cap)) { [self] in
                await self.readQuery(from: request)
            } ?? nil
            if query == nil { SiriDiag.log("APP MixGenerator query step skipped or timed out") }
        } else {
            query = await readQuery(from: request)
        }

        let candidates = try candidateTracks(
            matching: request,
            query: query,
            artistNames: artistNames,
            albumTitles: albumTitles,
            limit: budget.candidateLimit
        )
        guard !candidates.isEmpty else {
            throw MixGenerationError.emptyLibrary
        }

        if case .available = SystemLanguageModel.default.availability {
            let select: @MainActor () async -> Mix? = { [self] in
                try? await self.generateWithModel(
                    request: request,
                    candidates: candidates,
                    artistNames: artistNames,
                    albumTitles: albumTitles
                )
            }
            let mix: Mix?
            if let left = remaining() {
                mix = left >= budget.minimumSelectionTime
                    ? (await IntentRuntime.withDeadline(left, select) ?? nil)
                    : nil
                if mix == nil { SiriDiag.log("APP MixGenerator selection step skipped or timed out (left=\(left))") }
            } else {
                mix = await select()
            }
            if let mix {
                return mix
            }
        }

        return fallbackMix(matching: request, candidates: candidates)
    }

    // MARK: - Foundation Models path

    /// The request as artists, styles, era and energy, or nil when the model
    /// is unavailable.
    private func readQuery(from request: String) async -> MixRequestQuery? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let session = LanguageModelSession(instructions: """
        You read a request for a music mix and describe what it asks for: artists it names, \
        broad styles, an era and an energy level. Leave out anything the request does not say.
        """)
        return try? await session.respond(to: "Request: \(request)", generating: MixRequestQuery.self).content
    }

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
        var generator = SeededGenerator(seed: UInt64.random(in: 0...UInt64.max))
        return Mix(title: title.isEmpty ? defaultTitle(for: request) : title, tracks: MixEngine.flowOrder(tracks, generator: &generator))
    }

    // MARK: - Fallback path

    /// Without the model the ranking alone decides: candidates are already
    /// ordered by how well they match the request, then favourites and habits.
    private func fallbackMix(matching request: String, candidates: [Track]) -> Mix {
        var generator = SeededGenerator(seed: UInt64.random(in: 0...UInt64.max))
        return Mix(
            title: defaultTitle(for: request),
            tracks: MixEngine.flowOrder(Array(candidates.prefix(Self.fallbackMixSize)), generator: &generator)
        )
    }

    // MARK: - Helpers

    /// The whole library ranked against the request - a named artist or
    /// album, the styles, era and energy the model read from it, the
    /// listener's favourites and habits - capped so the prompt stays inside
    /// the on-device context window.
    private func candidateTracks(
        matching request: String,
        query: MixRequestQuery?,
        artistNames: [Int64: String],
        albumTitles: [Int64: String],
        limit: Int
    ) throws -> [Track] {
        let all = try database.getAllTracks()
        let favorites = Set(try database.getFavorites())
        let albumYears = Dictionary(
            try database.getAllAlbums().compactMap { album in album.id.flatMap { id in album.year.map { (id, $0) } } },
            uniquingKeysWith: { first, _ in first }
        )
        var plays: [String: Double] = [:]
        for event in ListeningLog.shared.events { plays[event.id, default: 0] += event.weight }

        func folded(_ text: String) -> String {
            ArtistProfileStore.key(for: text).filter { $0.isLetter || $0.isNumber }
        }
        var tokens = Set(request.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 2 })
        tokens.formUnion(query?.keywords.map { $0.lowercased() } ?? [])
        let wantedArtists = (query?.artists ?? []).map(folded).filter { !$0.isEmpty }
        let wantedStyles = Set((query?.styles ?? []).compactMap(\.name).map(folded))
        let years = query.flatMap { query -> ClosedRange<Int>? in
            guard query.fromYear >= 1900 else { return nil }
            return query.fromYear...max(query.fromYear, query.toYear >= 1900 ? query.toYear : query.fromYear + 9)
        }
        let energy = query.flatMap { $0.energy > 0 ? Double($0.energy - 1) / 4 : nil }

        let profiles = ArtistProfileStore.shared
        let scored: [(Track, Double)] = all.map { track in
            var score = 0.0
            let artist = track.artistId.flatMap { artistNames[$0] } ?? ""
            let foldedArtist = folded(artist)
            if !foldedArtist.isEmpty, wantedArtists.contains(where: { foldedArtist.contains($0) || $0.contains(foldedArtist) }) {
                score += 6
            }
            let haystack = describe(track, artistNames: artistNames, albumTitles: albumTitles).lowercased()
            score += Double(tokens.filter { haystack.contains($0) }.count)

            if !wantedStyles.isEmpty {
                var styles = Set<String>()
                if let genre = MusicFeatures.normalizedGenre(track.genre) { styles.insert(folded(genre)) }
                if styles.isEmpty, let profile = profiles.profile(for: artist) { styles.formUnion(profile.styles.map(folded)) }
                if styles.contains(where: { style in wantedStyles.contains { style.contains($0) || $0.contains(style) } }) {
                    score += 3
                }
            }
            if let years, let year = MusicFeatures.year(of: track, albumYear: track.albumId.flatMap { albumYears[$0] })
                ?? profiles.profile(for: artist).flatMap({ $0.decade > 0 ? $0.decade + 5 : nil }) {
                score += years.contains(year) ? 2 : 0
            }
            if let energy, let trackEnergy = MusicFeatures.energy(of: track)
                ?? profiles.profile(for: artist).flatMap({ $0.energy > 0 ? Double($0.energy - 1) / 4 : nil }) {
                score += (1 - abs(trackEnergy - energy)) * 1.5
            }
            if favorites.contains(track.stableId) { score += 0.6 }
            score += min(max(plays[track.stableId] ?? 0, -1), 3) * 0.2
            // A little randomness so the same request does not give the same mix.
            score += Double.random(in: 0..<0.4)
            return (track, score)
        }
        return Array(scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0))
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
        if let genre = track.genre, !genre.isEmpty {
            parts.append(genre)
        }
        if let year = track.year {
            parts.append(String(year))
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
