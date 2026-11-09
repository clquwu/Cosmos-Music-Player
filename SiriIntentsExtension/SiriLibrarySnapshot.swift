//
//  SiriLibrarySnapshot.swift
//  SiriIntentsExtension
//
//  A pre-normalized, cached copy of the library the extension ranks Siri
//  requests against. Built off the main thread on first use and reused for
//  every later request until the database file changes, so a request costs
//  one in-memory ranking pass instead of a full SQL read + string folding.
//

import Foundation
import GRDB

/// Text folded the same way for the query and the candidates: lower-case,
/// accents and width folded, punctuation turned into single spaces.
enum SiriText {
    static func normalize(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: nil
        )
        var out = ""
        out.reserveCapacity(folded.count)
        var lastWasSpace = true
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        if out.hasSuffix(" ") { out.removeLast() }
        return out
    }

    /// 1 minus the edit distance over the longer length (two-row Levenshtein).
    static func ratio(_ lhs: [Character], _ rhs: [Character]) -> Double {
        if lhs.isEmpty && rhs.isEmpty { return 1 }
        if lhs.isEmpty || rhs.isEmpty { return 0 }
        if lhs == rhs { return 1 }
        var previous = Array(0...rhs.count)
        var current = Array(repeating: 0, count: rhs.count + 1)
        for i in 1...lhs.count {
            current[0] = i
            let l = lhs[i - 1]
            for j in 1...rhs.count {
                let cost = l == rhs[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return 1 - Double(previous[rhs.count]) / Double(max(lhs.count, rhs.count))
    }

    static let fillerWords: Set<String> = [
        "a", "an", "the", "song", "songs", "music", "track", "tracks", "play", "please", "by", "from",
        "in", "on", "cosmos", "my", "some",
        "le", "la", "les", "l", "un", "une", "chanson", "chansons", "musique", "titre", "titres",
        "morceau", "morceaux", "joue", "jouer", "mets", "mettre", "lance", "de", "du", "des", "d",
        "dans", "sur", "mon", "ma", "mes", "avec"
    ]
}

/// A normalized string plus its characters and word list, computed once.
struct SiriKey: Sendable {
    let text: String
    let chars: [Character]
    let words: [[Character]]

    init(_ raw: String) {
        text = SiriText.normalize(raw)
        chars = Array(text)
        words = text.split(separator: " ").map { Array($0) }
    }

    var isEmpty: Bool { text.isEmpty }

    /// Same scale as the previous `siriSearchScore`: 1 for equal, ~0.9 for
    /// containment, otherwise the better of whole-string and per-word
    /// closeness (filler words such as "the" / "la" ignored on the query).
    func score(against value: SiriKey) -> Double {
        guard !text.isEmpty, !value.text.isEmpty else { return 0 }
        if text == value.text { return 1 }
        if value.text.contains(text) {
            return min(0.98, 0.88 + 0.10 * Double(chars.count) / Double(value.chars.count))
        }
        if text.contains(value.text) {
            return min(0.94, 0.82 + 0.10 * Double(value.chars.count) / Double(chars.count))
        }
        let queryWords = words.filter { !SiriText.fillerWords.contains(String($0)) }
        var coverage = 0.0
        if !queryWords.isEmpty, !value.words.isEmpty {
            var total = 0.0
            for word in queryWords {
                var best = 0.0
                for candidate in value.words {
                    // Cheap length bound: a ratio can't beat this, skip it.
                    let bound = 1 - Double(abs(word.count - candidate.count)) / Double(max(word.count, candidate.count))
                    if bound <= best { continue }
                    best = max(best, SiriText.ratio(word, candidate))
                    if best == 1 { break }
                }
                total += best
            }
            coverage = total / Double(queryWords.count)
        }
        // Whole-string edit distance only matters for similar lengths.
        let lengthBound = 1 - Double(abs(chars.count - value.chars.count)) / Double(max(chars.count, value.chars.count))
        let whole = lengthBound > coverage * 0.90 ? SiriText.ratio(chars, value.chars) : 0
        return max(whole, coverage * 0.90)
    }

    /// ArtistMatcher's measure (app side): whole-name or word-by-word
    /// closeness, so both a misheard name and a surname alone match.
    func artistSimilarity(to candidate: SiriKey) -> Double {
        guard !candidate.isEmpty, !isEmpty else { return 0 }
        if text == candidate.text { return 1 }
        let whole = SiriText.ratio(chars, candidate.chars)
        guard !words.isEmpty, !candidate.words.isEmpty else { return whole }
        let perWord = words.map { word in candidate.words.map { SiriText.ratio(word, $0) }.max() ?? 0 }
        return max(whole, perWord.reduce(0, +) / Double(perWord.count) * 0.95)
    }
}

struct SiriTrackRow: Sendable {
    let track: SimpleTrack
    let title: SiriKey
    let metadata: SiriKey
    let artist: SiriKey
    let album: SiriKey
}

struct SiriNamedRow: Sendable {
    let id: String
    let name: String
    let key: SiriKey
}

/// Mix list the app writes to the app group (see SiriMixIndex in the app).
struct SiriMixRecord: Codable, Sendable {
    let id: String
    let title: String
    /// "madeForYou" or "rediscover".
    let kind: String
}

struct SiriLibrarySnapshot: Sendable {
    let tracks: [SiriTrackRow]
    let artists: [SiriNamedRow]
    let albums: [SiriNamedRow]
    let playlists: [SiriNamedRow]
    let mixes: [(record: SiriMixRecord, key: SiriKey)]
    let favoriteIds: [String]
}

/// Loads and caches the snapshot. Thread-safe; never touches the main thread.
final class SiriLibraryCache: @unchecked Sendable {
    static let shared = SiriLibraryCache()

    static let groupId = "group.dev.clq.Cosmos-Music-Player"

    private let lock = NSLock()
    private var cached: SiriLibrarySnapshot?
    private var cachedStamp: String?
    private var dbQueue: DatabaseQueue?

    private init() {}

    private var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.groupId)
    }

    /// Database + WAL + mix index modification dates: any change rebuilds.
    private func currentStamp() -> String {
        guard let container = containerURL else { return "none" }
        let paths = [
            container.appendingPathComponent("cosmos_music.db").path,
            container.appendingPathComponent("cosmos_music.db-wal").path,
            container.appendingPathComponent("Library/siri-mixes.json").path
        ]
        return paths.map { path -> String in
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let date = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            return "\(date)-\(size)"
        }.joined(separator: "|")
    }

    private func queue() -> DatabaseQueue? {
        if let dbQueue { return dbQueue }
        guard let container = containerURL else { return nil }
        let url = container.appendingPathComponent("cosmos_music.db")
        dbQueue = try? DatabaseQueue(path: url.path)
        return dbQueue
    }

    func database() -> DatabaseQueue? {
        lock.lock(); defer { lock.unlock() }
        return queue()
    }

    func snapshot() -> SiriLibrarySnapshot {
        lock.lock(); defer { lock.unlock() }
        let stamp = currentStamp()
        if let cached, cachedStamp == stamp { return cached }
        let started = Date()
        let built = build()
        cached = built
        cachedStamp = stamp
        SiriDiag.log("EXT snapshot built tracks=\(built.tracks.count) artists=\(built.artists.count) mixes=\(built.mixes.count) in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
        return built
    }

    private func build() -> SiriLibrarySnapshot {
        var tracks: [SiriTrackRow] = []
        var artists: [SiriNamedRow] = []
        var albums: [SiriNamedRow] = []
        var playlists: [SiriNamedRow] = []
        var favorites: [String] = []

        if let dbQueue = queue() {
            do {
                try dbQueue.read { db in
                    let rows = try SimpleTrack.fetchAll(db, sql: """
                        SELECT track.stable_id,
                               track.title,
                               artist.name AS artist_name,
                               album.title AS album_title
                        FROM track
                        LEFT JOIN artist ON artist.id = track.artist_id
                        LEFT JOIN album ON album.id = track.album_id
                        """)
                    tracks = rows.map { track in
                        SiriTrackRow(
                            track: track,
                            title: SiriKey(track.title),
                            metadata: SiriKey([track.title, track.artistName, track.albumTitle].compactMap { $0 }.joined(separator: " ")),
                            artist: SiriKey(track.artistName ?? ""),
                            album: SiriKey(track.albumTitle ?? "")
                        )
                    }
                    for row in try Row.fetchAll(db, sql: "SELECT id, name FROM artist") {
                        let id: Int64 = row["id"]
                        let name: String = row["name"]
                        artists.append(SiriNamedRow(id: String(id), name: name, key: SiriKey(name)))
                    }
                    for row in try Row.fetchAll(db, sql: "SELECT id, title FROM album") {
                        let id: Int64 = row["id"]
                        let title: String = row["title"]
                        albums.append(SiriNamedRow(id: String(id), name: title, key: SiriKey(title)))
                    }
                    for row in try Row.fetchAll(db, sql: "SELECT id, title FROM playlist ORDER BY last_played_at DESC, title") {
                        let id: Int64 = row["id"]
                        let title: String = row["title"]
                        playlists.append(SiriNamedRow(id: String(id), name: title, key: SiriKey(title)))
                    }
                    favorites = try String.fetchAll(db, sql: "SELECT track_stable_id FROM favorite")
                }
            } catch {
                SiriDiag.log("EXT snapshot read failed: \(error)")
            }
        }

        var mixes: [(record: SiriMixRecord, key: SiriKey)] = []
        if let url = containerURL?.appendingPathComponent("Library/siri-mixes.json"),
           let data = try? Data(contentsOf: url),
           let records = try? JSONDecoder().decode([SiriMixRecord].self, from: data) {
            mixes = records.map { ($0, SiriKey($0.title)) }
        }

        return SiriLibrarySnapshot(
            tracks: tracks,
            artists: artists,
            albums: albums,
            playlists: playlists,
            mixes: mixes,
            favoriteIds: favorites
        )
    }
}
