//
//  MusicBrainzAPI.swift
//  Cosmos Music Player
//
//  MusicBrainz lookups for artist pages: who an artist is (id, aliases,
//  disambiguation, country, active years, genres) and where to read more
//  (Wikidata / Wikipedia / Discogs links). Free and keyless, unlike Spotify,
//  which now refuses apps whose owner has no Premium subscription.
//

import Foundation

// MARK: - Models

/// One artist from a MusicBrainz search, reduced to what choosing between
/// namesakes needs.
struct MusicBrainzArtistCandidate: Codable, Sendable, Equatable {
    let id: String
    let name: String
    let sortName: String
    let score: Int
    let disambiguation: String?
    let country: String?
    let type: String?
    let aliases: [String]
    let tags: [String]
    let beginYear: String?
    let endYear: String?

    /// "1987–1994", "1967–" or nil.
    var activeYears: String? {
        guard let beginYear else { return nil }
        return "\(beginYear)–\(endYear ?? "")"
    }
}

/// A looked-up artist with the links the rest of the chain follows.
struct MusicBrainzArtistDetails: Sendable {
    let candidate: MusicBrainzArtistCandidate
    let genres: [String]
    let wikidataID: String?
    let wikipediaURL: String?
    let discogsID: Int?
    /// A Wikimedia Commons file page, when MusicBrainz links one directly.
    let commonsImagePage: String?
}

/// What resolving a library artist's name produced.
struct MusicBrainzResolution: Sendable {
    let chosen: MusicBrainzArtistDetails
    /// Other artists that carry the same name, best first. Kept so the AI
    /// agent and "Wrong artist?" can offer the next one.
    let alternatives: [MusicBrainzArtistCandidate]
    /// Several namesakes and nothing in the library said which one is meant.
    let isAmbiguous: Bool
}

// MARK: - Wire format

private struct MBSearchResponse: Decodable {
    let artists: [MBArtist]?
}

private struct MBArtist: Decodable {
    struct LifeSpan: Decodable { let begin: String?; let end: String? }
    struct Named: Decodable { let name: String }
    struct Relation: Decodable {
        struct Link: Decodable { let resource: String }
        let type: String
        let url: Link?
    }

    let id: String
    let name: String
    let sortName: String?
    let score: Int?
    let disambiguation: String?
    let country: String?
    let type: String?
    let lifeSpan: LifeSpan?
    let aliases: [Named]?
    let tags: [Named]?
    let genres: [Named]?
    let relations: [Relation]?

    enum CodingKeys: String, CodingKey {
        case id, name, score, disambiguation, country, type, aliases, tags, genres, relations
        case sortName = "sort-name"
        case lifeSpan = "life-span"
    }

    var candidate: MusicBrainzArtistCandidate {
        MusicBrainzArtistCandidate(
            id: id,
            name: name,
            sortName: sortName ?? name,
            score: score ?? 100,
            disambiguation: disambiguation?.isEmpty == false ? disambiguation : nil,
            country: country,
            type: type,
            aliases: (aliases ?? []).map(\.name),
            tags: (tags ?? []).map(\.name),
            beginYear: lifeSpan?.begin.map { String($0.prefix(4)) },
            endYear: lifeSpan?.end.map { String($0.prefix(4)) }
        )
    }
}

private struct MBReleaseGroupResponse: Decodable {
    struct ReleaseGroup: Decodable {
        struct Credit: Decodable {
            struct CreditedArtist: Decodable { let id: String }
            let artist: CreditedArtist
        }
        let score: Int?
        let title: String
        let artistCredit: [Credit]?

        enum CodingKeys: String, CodingKey {
            case score, title
            case artistCredit = "artist-credit"
        }
    }
    let releaseGroups: [ReleaseGroup]?

    enum CodingKeys: String, CodingKey {
        case releaseGroups = "release-groups"
    }
}

// MARK: - Service

/// An actor so every request goes through one queue: MusicBrainz allows one
/// request per second per client and answers 503 to anything faster.
actor MusicBrainzAPIService {
    static let shared = MusicBrainzAPIService()

    private let baseURL = "https://musicbrainz.org/ws/2"
    /// MusicBrainz blocks anonymous clients; it asks for an application
    /// name, version and contact URL.
    nonisolated static let userAgent: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "CosmosMusicPlayer/\(version) ( https://github.com/clquwu/Cosmos-Music-Player )"
    }()

    /// The earliest moment the next request may leave. Each caller reserves
    /// its slot before sleeping, so concurrent callers queue up a second
    /// apart even though the actor is re-entered while they wait.
    private var nextSlot = Date.distantPast
    private let spacing: TimeInterval = 1.1

    // MARK: Public API

    func searchArtists(name: String, limit: Int = 8) async throws -> [MusicBrainzArtistCandidate] {
        let response: MBSearchResponse = try await get("artist/", query: [
            "query": Self.escapeLucene(name),
            "limit": String(limit)
        ])
        return (response.artists ?? []).map(\.candidate)
    }

    func artist(id: String) async throws -> MusicBrainzArtistDetails {
        let artist: MBArtist = try await get("artist/\(id)", query: ["inc": "url-rels+genres+tags+aliases"])
        let relations = artist.relations ?? []
        func link(_ type: String) -> String? {
            relations.first(where: { $0.type == type })?.url?.resource
        }
        let discogsID = link("discogs")
            .flatMap { $0.split(separator: "/").last }
            .flatMap { Int($0) }
        let commons = link("image").flatMap { $0.contains("commons.wikimedia.org") ? $0 : nil }
        return MusicBrainzArtistDetails(
            candidate: artist.candidate,
            genres: (artist.genres ?? []).map(\.name),
            wikidataID: link("wikidata").flatMap { $0.split(separator: "/").last.map(String.init) },
            wikipediaURL: link("wikipedia"),
            discogsID: discogsID,
            commonsImagePage: commons
        )
    }

    /// Artist ids credited on release groups whose title matches one of the
    /// library's album titles - the strongest hint for telling namesakes
    /// apart ("Nevermind" picks the grunge band, "Local Anaesthetic" the
    /// 60s British one). One request covers every hint.
    func artistIDs(creditedOn albumTitles: [String], artistName: String) async throws -> [String: Int] {
        let titles = albumTitles.prefix(4).map { "releasegroup:\"\(Self.escapeQuoted($0))\"" }
        guard !titles.isEmpty else { return [:] }
        let query = "(\(titles.joined(separator: " OR "))) AND artist:\"\(Self.escapeQuoted(artistName))\""
        let response: MBReleaseGroupResponse = try await get("release-group/", query: ["query": query, "limit": "15"])

        let wanted = Set(albumTitles.map(Self.fold))
        var votes: [String: Int] = [:]
        for group in response.releaseGroups ?? [] where (group.score ?? 0) >= 85 {
            // Lucene also returns "Nevermind Sessions" for "Nevermind"; only
            // a title that matches outright counts as evidence.
            guard wanted.contains(Self.fold(group.title)) else { continue }
            for credit in group.artistCredit ?? [] {
                votes[credit.artist.id, default: 0] += 1
            }
        }
        return votes
    }

    /// Searches and picks the artist the library means. Nil when nobody on
    /// MusicBrainz plausibly carries this name.
    func resolve(name: String, albumHints: [String], excluding excludedIDs: Set<String> = []) async throws -> MusicBrainzResolution? {
        let candidates = try await searchArtists(name: name)
            .filter { !excludedIDs.contains($0.id) }
        let plausible = Self.plausibleMatches(for: name, in: candidates)
        guard let best = plausible.first else { return nil }

        var chosen = best
        var isAmbiguous = plausible.count > 1
        if plausible.count > 1, !albumHints.isEmpty,
           let votes = try? await artistIDs(creditedOn: albumHints, artistName: name),
           let winner = plausible.max(by: { votes[$0.id, default: 0] < votes[$1.id, default: 0] }),
           votes[winner.id, default: 0] > 0 {
            chosen = winner
            isAmbiguous = false
        }

        let details = try await artist(id: chosen.id)
        return MusicBrainzResolution(
            chosen: details,
            alternatives: plausible.filter { $0.id != chosen.id },
            isAmbiguous: isAmbiguous
        )
    }

    // MARK: Matching

    /// Candidates whose name, sort name or an alias is the library's name,
    /// best score first. Japanese artists are often filed under their
    /// native-script name with the romanisation as an alias ("鷺巣詩郎" /
    /// "Shirō Sagisu"), so aliases matter as much as the name. When nothing
    /// matches outright, a single very confident hit is still accepted.
    nonisolated static func plausibleMatches(for name: String, in candidates: [MusicBrainzArtistCandidate]) -> [MusicBrainzArtistCandidate] {
        let target = fold(name)
        let exact = candidates.filter { candidate in
            ([candidate.name, candidate.sortName, swapSortName(candidate.sortName)] + candidate.aliases)
                .contains { fold($0) == target }
        }
        if !exact.isEmpty {
            // Namesakes far below the best score are usually obscure
            // projects that would only add noise to the ambiguity check.
            let top = exact.map(\.score).max() ?? 100
            return exact.filter { $0.score >= top - 40 }.sorted { $0.score > $1.score }
        }
        return candidates.filter { $0.score >= 95 }.prefix(1).map { $0 }
    }

    /// Case, accents, width and punctuation do not tell artists apart:
    /// "Shirō Sagisu", "SHIRO SAGISU" and "Shiro Sagisu" are one name.
    nonisolated static func fold(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let kept = folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        // A name made only of punctuation ("!!!") would fold to nothing and
        // match every other such name, so it is compared as written.
        return kept.isEmpty ? folded : String(String.UnicodeScalarView(kept))
    }

    /// "Sagisu, Shiro" -> "Shiro Sagisu".
    private nonisolated static func swapSortName(_ sortName: String) -> String {
        let parts = sortName.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.count == 2 ? "\(parts[1]) \(parts[0])" : sortName
    }

    // MARK: Requests

    private nonisolated static func escapeLucene(_ text: String) -> String {
        let special = Set("+-&|!(){}[]^\"~*?:\\/")
        return String(text.flatMap { special.contains($0) ? ["\\", $0] : [$0] })
    }

    private nonisolated static func escapeQuoted(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func waitForSlot() async throws {
        let now = Date()
        let slot = max(now, nextSlot)
        nextSlot = slot.addingTimeInterval(spacing)
        let delay = slot.timeIntervalSince(now)
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
    }

    private func get<T: Decodable>(_ path: String, query: [String: String]) async throws -> T {
        guard var components = URLComponents(string: "\(baseURL)/\(path)") else { throw MusicBrainzAPIError.invalidURL }
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } + [URLQueryItem(name: "fmt", value: "json")]
        guard let url = components.url else { throw MusicBrainzAPIError.invalidURL }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // One retry on 503: the limit is shared by everything behind the
        // same address, so even a well-behaved client is sometimes told to
        // slow down.
        for attempt in 0..<2 {
            try await waitForSlot()
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            if status == 503, attempt == 0 {
                nextSlot = max(nextSlot, Date().addingTimeInterval(2))
                continue
            }
            guard status == 200 else { throw MusicBrainzAPIError.httpError(status) }
            return try JSONDecoder().decode(T.self, from: data)
        }
        throw MusicBrainzAPIError.httpError(503)
    }
}

enum MusicBrainzAPIError: Error, LocalizedError {
    case invalidURL
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .httpError(let code): return "HTTP Error: \(code)"
        }
    }
}
