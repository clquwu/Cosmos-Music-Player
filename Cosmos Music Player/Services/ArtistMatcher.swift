import Foundation
import GRDB

/// Finds the artist Siri meant. Speech recognition rarely spells a name the
/// way the tags do - "Shiva Sagisu" for Shiro Sagisu, "Sagisu" alone - and
/// a library often holds one artist under several spellings ("Shirō Sagisu",
/// "Shiro SAGISU, 鷺巣詩郎"). A plain substring search found none of these.
enum ArtistMatcher {
    /// The library's artists that best match a spoken name: the closest one
    /// and every other spelling of it, or none when nothing is close enough.
    static func artists(matching spoken: String, in artists: [Artist], threshold: Double = 0.7) -> [Artist] {
        let query = normalized(spoken)
        guard !query.isEmpty else { return [] }
        let scored = artists.map { ($0, similarity(query, normalized($0.name))) }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= threshold else { return [] }
        // Other spellings of the same artist score about as well, or carry
        // the same name with more around it ("Shiro SAGISU, 鷺巣詩郎").
        // Containing the name only counts as whole words: "Shiro SAGISU,
        // 鷺巣詩郎" carries "shiro sagisu", but "Asia" does not carry "Sia".
        let bestWords = normalized(best.0.name).split(separator: " ")
        return scored.filter { candidate in
            if candidate.1 >= best.1 - 0.05 { return true }
            let words = normalized(candidate.0.name).split(separator: " ")
            guard words.count > bestWords.count else { return false }
            return (0...(words.count - bestWords.count)).contains { Array(words[$0..<($0 + bestWords.count)]) == bestWords }
        }.map(\.0)
    }

    /// 0...1: the better of whole-name closeness and word-by-word closeness,
    /// so both a misheard name and a surname alone find the artist.
    static func similarity(_ query: String, _ candidate: String) -> Double {
        guard !candidate.isEmpty else { return 0 }
        if query == candidate { return 1 }
        let whole = ratio(query, candidate)
        let candidateWords = candidate.split(separator: " ").map(String.init)
        let queryWords = query.split(separator: " ").map(String.init)
        guard !queryWords.isEmpty, !candidateWords.isEmpty else { return whole }
        let perWord = queryWords.map { word in candidateWords.map { ratio(word, $0) }.max() ?? 0 }
        let words = perWord.reduce(0, +) / Double(perWord.count) * 0.95
        return max(whole, words)
    }

    /// Lower-case, accents folded, punctuation dropped: "Shirō SAGISU," and
    /// "shiro sagisu" compare equal.
    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let cleaned = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }

    /// 1 minus the edit distance over the longer length.
    static func ratio(_ a: String, _ b: String) -> Double {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty || !b.isEmpty else { return 1 }
        var previous = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(b.count, 1) where !b.isEmpty {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return 1 - Double(previous[b.count]) / Double(max(a.count, b.count))
    }
}

extension DatabaseManager {
    /// How many songs each artist has, and the library's size, counted by
    /// the database rather than by loading every song.
    func artistSongCounts() throws -> (byArtist: [Int64: Int], total: Int) {
        try read { db in
            var counts: [Int64: Int] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT artist_id, COUNT(*) AS n FROM track WHERE artist_id IS NOT NULL GROUP BY artist_id") {
                counts[row["artist_id"]] = row["n"]
            }
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track") ?? 0
            return (counts, total)
        }
    }

    /// Every song by the artist a spoken name best matches, all spellings
    /// together, album by album.
    func tracksForSpokenArtist(_ spoken: String) throws -> [Track] {
        let matches = ArtistMatcher.artists(matching: spoken, in: try getAllArtists())
        var tracks: [Track] = []
        var seen = Set<String>()
        for artist in matches {
            guard let id = artist.id else { continue }
            // A song credited to two of the matched spellings plays once.
            tracks += try getTracksByArtistId(id).filter { seen.insert($0.stableId).inserted }
        }
        return tracks
    }
}
