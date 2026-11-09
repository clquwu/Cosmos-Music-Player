//
//  IntentHandler.swift
//  SiriIntentsExtension
//
//  Created by CLQ on 15/09/2025.
//
//  Resolves SiriKit media requests ("Joue … dans Cosmos") into identifiers
//  the app plays (see SiriPlayRouter / AppCoordinator.handleSiriPlaybackIntent).
//
//  Speed: everything runs off the main thread against a cached, pre-folded
//  library snapshot (SiriLibrarySnapshot.swift). Deterministic ranking
//  answers almost every request in well under a second; the on-device model
//  is only consulted when the ranking is genuinely ambiguous, and it is
//  raced against a hard deadline so a request never waits more than
//  `modelDeadline` for it. Every path works without Apple Intelligence.
//
//  Identifier contract with the app:
//    <stableId>                 a song
//    playlist_<id>              a playlist
//    album_<id>                 an album
//    search_artist_<name>       an artist (fuzzy-matched again in the app)
//    liked_songs                Liked Songs
//    mix_<id>                   a Made for You / Rediscover mix
//    mixkind_madeForYou|mixkind_rediscover   the first mix of that shelf
//    radio_current              a song mix from the playing song
//    radio_song_<stableId>      a song mix from a named song
//    radio_artist_<name>        a mix grown from an artist
//    artist_current             the playing song's artist
//    generate_<text>            a mood/genre mix ("play something calm")
//    music_all                  the whole library, shuffled
//    mode_now|mode_tonight      the listening mode that fits the moment
//                               ("something for now / tonight")
//    cosmos_not_found           nothing matched (Siri says so)
//

import Intents
import Foundation
import GRDB
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Legacy string helpers (kept for source compatibility)

extension String {
    var siriSearchNormalized: String { SiriText.normalize(self) }

    func similarityScore(to other: String) -> Double {
        SiriText.ratio(Array(siriSearchNormalized), Array(other.siriSearchNormalized))
    }

    func siriSearchScore(against candidate: String) -> Double {
        SiriKey(self).score(against: SiriKey(candidate))
    }
}

struct RankedSimpleTrack: Sendable {
    let track: SimpleTrack
    let score: Double
}

// Temporary Siri-routing diagnostics: append to a log in the app group
// container so it can be pulled off-device with devicectl.
enum SiriDiag {
    private static let queue = DispatchQueue(label: "cosmos.siri.diag")

    static func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        queue.async {
            guard let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: SiriLibraryCache.groupId
            ) else { return }
            let dir = container.appendingPathComponent("Library", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("siri-diagnostics.log")
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
}

// MARK: - Database access (INAddMedia + legacy callers)

final class ExtensionDatabaseAccess: @unchecked Sendable {
    static let shared = ExtensionDatabaseAccess()
    private init() {}

    func rankedTrackCandidates(
        query: String,
        artistName: String? = nil,
        albumName: String? = nil,
        limit: Int = 25
    ) -> [RankedSimpleTrack] {
        SiriRanker(snapshot: SiriLibraryCache.shared.snapshot())
            .rankTracks(query: SiriKey(query), artist: artistName.map(SiriKey.init), album: albumName.map(SiriKey.init), limit: limit)
    }

    func searchTracks(query: String, artistName: String? = nil, albumName: String? = nil) -> [SimpleTrack] {
        let ranked = rankedTrackCandidates(query: query, artistName: artistName, albumName: albumName)
        guard let best = ranked.first, best.score >= SiriRanker.songThreshold else { return [] }
        let cutoff = max(SiriRanker.songThreshold, best.score - 0.10)
        return ranked.prefix(5).filter { $0.score >= cutoff }.map(\.track)
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

// MARK: - Deterministic ranking

struct SiriRanker {
    let snapshot: SiriLibrarySnapshot

    static let songThreshold = 0.58
    /// A song match this good, clearly ahead of the next title, needs no model.
    static let confidentScore = 0.88

    func rankTracks(query: SiriKey, artist: SiriKey?, album: SiriKey?, limit: Int = 25) -> [RankedSimpleTrack] {
        guard !query.isEmpty else { return [] }
        var ranked: [RankedSimpleTrack] = []
        ranked.reserveCapacity(snapshot.tracks.count)
        for row in snapshot.tracks {
            var score = query.score(against: row.title)
            // Metadata only helps when the title alone isn't already close.
            if score < 0.9 {
                score = max(score, query.score(against: row.metadata) * 0.94)
            }
            if let artist, !artist.isEmpty {
                score += artist.artistSimilarity(to: row.artist) * 0.10
            }
            if let album, !album.isEmpty {
                score += album.score(against: row.album) * 0.08
            }
            ranked.append(RankedSimpleTrack(track: row.track, score: min(score, 1)))
        }
        ranked.sort {
            if abs($0.score - $1.score) > 0.0001 { return $0.score > $1.score }
            return $0.track.title.localizedCaseInsensitiveCompare($1.track.title) == .orderedAscending
        }
        return Array(ranked.prefix(limit))
    }

    /// Best artist for a spoken name and its score (ArtistMatcher semantics).
    func bestArtist(_ query: SiriKey) -> (name: String, score: Double)? {
        var best: (String, Double)?
        for artist in snapshot.artists {
            let score = query.artistSimilarity(to: artist.key)
            if score > (best?.1 ?? 0) { best = (artist.name, score) }
        }
        return best.map { (name: $0.0, score: $0.1) }
    }

    func bestNamed(_ query: SiriKey, in rows: [SiriNamedRow]) -> (row: SiriNamedRow, score: Double)? {
        var best: (SiriNamedRow, Double)?
        for row in rows {
            let score = query.score(against: row.key)
            if score > (best?.1 ?? 0) { best = (row, score) }
        }
        return best.map { (row: $0.0, score: $0.1) }
    }

    func bestMix(_ query: SiriKey) -> (record: SiriMixRecord, score: Double)? {
        var best: (SiriMixRecord, Double)?
        for mix in snapshot.mixes {
            let score = query.score(against: mix.key)
            if score > (best?.1 ?? 0) { best = (mix.record, score) }
        }
        return best.map { (record: $0.0, score: $0.1) }
    }
}

// MARK: - Spoken phrase classification

enum SiriPhrase {
    private static func words(_ name: String) -> [String] {
        SiriText.normalize(name).split(separator: " ").map(String.init)
    }

    private static let possessives: Set<String> = [
        "my", "mes", "ma", "mon", "the", "les", "la", "le", "all", "of", "toutes", "tous", "toute", "tout",
        "songs", "song", "tracks", "track", "titres", "titre", "chansons", "chanson", "morceaux", "morceau",
        "music", "musique", "de", "du", "des", "d", "playlist", "liste", "lecture", "in", "dans", "cosmos",
        "play", "joue", "mets", "lance", "some", "me", "moi", "a", "un", "une", "mix", "list"
    ]

    private static let likedWords: Set<String> = [
        "liked", "like", "likes", "likees", "likee", "love", "loved", "favorite", "favorites", "favourite",
        "favourites", "favori", "favoris", "favorite", "prefere", "preferes", "preferee", "preferees",
        "aime", "aimes", "aimee", "aimees", "coup", "coups", "coeur", "coeurs", "cœur", "cœurs", "j", "heart", "hearted",
        "избранное", "любимые", "любимое"
    ]

    /// "mes titres likés", "my liked songs", "mes coups de cœur", "favoris"…
    /// Only when *every* meaningful word is a liked-word, so a song called
    /// "Love Story" is not mistaken for Liked Songs.
    static func isLikedSongs(_ name: String) -> Bool {
        let meaningful = words(name).filter { !possessives.contains($0) }
        guard !meaningful.isEmpty else { return false }
        return meaningful.allSatisfy { likedWords.contains($0) }
    }

    static func isAllMusic(_ name: String) -> Bool {
        let all = words(name)
        guard !all.isEmpty else { return false }
        let library: Set<String> = ["bibliotheque", "collection", "library", "everything", "tout", "all"]
        let meaningful = all.filter { !possessives.contains($0) || $0 == "all" || $0 == "tout" }
        if meaningful.isEmpty {
            // "my music", "ma musique", "mes chansons", "toute ma musique"
            return all.contains { ["music", "musique", "songs", "chansons", "titres", "morceaux"].contains($0) }
        }
        return meaningful.allSatisfy { library.contains($0) }
    }

    enum MixShelf { case madeForYou, rediscover }

    /// "Made for You", "mes mix pour moi", "Redécouvrir"…
    static func mixShelf(_ name: String) -> MixShelf? {
        let all = Set(words(name))
        if !all.isDisjoint(with: ["rediscover", "redecouvrir", "redecouverte", "redecouvre", "redecouvertes"]) {
            return .rediscover
        }
        let madeWords: Set<String> = ["made", "for", "you", "pour", "vous", "toi", "moi", "me", "fait", "faits",
                                      "concu", "concus", "daily", "jour", "quotidien", "personnalise", "personnalises"]
        let meaningful = all.subtracting(possessives).subtracting(["mix", "mixes", "mixs"])
        let mentionsMix = !all.isDisjoint(with: ["mix", "mixes", "mixs"])
        if meaningful.isEmpty { return mentionsMix ? .madeForYou : nil }
        if meaningful.isSubset(of: madeWords), all.contains("made") || all.contains("pour") || all.contains("for") || mentionsMix {
            return .madeForYou
        }
        return nil
    }

    enum Moment { case now, tonight }

    /// "something for now", "quelque chose pour ce soir", "de la musique
    /// pour maintenant", "music for tonight": a request for whatever fits
    /// the moment, which the app answers with the listening mode of that
    /// time (identifiers mode_now / mode_tonight). Every word must be one
    /// of these, with a time word and a "for"/"something" word among them,
    /// so a song called "Tonight" or "Now" is still that song.
    static func moment(_ name: String) -> Moment? {
        let all = words(name)
        guard !all.isEmpty else { return nil }
        let nowWords: Set<String> = ["now", "maintenant", "moment", "today", "aujourd", "hui", "aujourdhui", "сеичас", "сейчас"]
        let tonightWords: Set<String> = ["tonight", "evening", "night", "soir", "soiree", "nuit", "вечер", "вечером"]
        let asking: Set<String> = ["for", "pour", "something", "quelque", "chose", "truc", "music", "musique",
                                   "что", "нибудь", "на", "для", "музыку", "музыка"]
        let glue: Set<String> = ["a", "de", "la", "du", "des", "some", "play", "joue", "mets", "lance", "ce", "cette", "this",
                                 "the", "right", "me", "moi", "un", "une", "peu", "songs", "titres", "chansons", "morceaux",
                                 "in", "dans", "cosmos", "qui", "va", "bien", "fits", "goes", "with", "avec", "le", "en",
                                 "ecouter", "listen", "to", "сегодня", "включи", "поставь", "-"]
        guard all.allSatisfy({ nowWords.contains($0) || tonightWords.contains($0) || asking.contains($0) || glue.contains($0) }),
              all.contains(where: asking.contains) else { return nil }
        if all.contains(where: tonightWords.contains) { return .tonight }
        return all.contains(where: nowWords.contains) ? .now : nil
    }

    /// "this song", "ce morceau", "celui-ci", "ça" — a reference to now playing.
    static func isCurrentReference(_ subject: String) -> Bool {
        let meaningful = words(subject).filter {
            !["this", "that", "the", "current", "song", "track", "one", "playing", "now", "ce", "cette", "cet", "ca",
              "celui", "ci", "celle", "la", "le", "morceau", "titre", "chanson", "en", "cours", "actuel", "actuelle",
              "qui", "joue", "it", "music", "musique", "what", "s", "i", "m", "listening", "to", "j", "ecoute"].contains($0)
        }
        return meaningful.isEmpty
    }

    /// Splits "radio Shiro Sagisu", "a mix like Cruel Angel's Thesis",
    /// "des titres comme ce morceau" into the radio subject, or nil when the
    /// request isn't a radio/similar request.
    static func radioSubject(_ name: String) -> String? {
        let normalized = " " + SiriText.normalize(name) + " "
        let markers = [
            " radio ", " station ", " similar to ", " similar ", " more like ", " like ", " based on ",
            " inspired by ", " in the style of ", " sounds like ", " mix of ", " mix like ", " mix from ",
            " comme ", " similaire a ", " similaires a ", " similaire ", " similaires ", " dans le style de ",
            " dans le genre de ", " base sur ", " basee sur ", " inspire de ", " inspiree de ", " a partir de ",
            " qui ressemble a ", " qui ressemblent a ", " du meme genre que ", " proche de ", " mix de ", " mix a partir de ",
            " похожее на ", " похожие на ", " радио "
        ]
        guard let marker = markers.first(where: { normalized.contains($0) }) else { return nil }
        var subject = normalized.replacingOccurrences(of: marker, with: " ")
        for other in markers { subject = subject.replacingOccurrences(of: other, with: " ") }
        let filler: Set<String> = ["play", "a", "an", "some", "me", "start", "songs", "music", "tracks", "mix", "the",
                                   "joue", "mets", "lance", "moi", "un", "une", "des", "de", "du", "titres", "morceaux",
                                   "chansons", "musique", "mix", "la", "le", "les", "plus", "more", "in", "on", "dans",
                                   "sur", "cosmos", "similar"]
        // Trim filler only at the edges: "Fly Me to the Moon" keeps its words.
        var words = subject.split(separator: " ").map(String.init)
        while let first = words.first, filler.contains(first) { words.removeFirst() }
        while let last = words.last, filler.contains(last) { words.removeLast() }
        return words.joined(separator: " ")
    }

    static var prefersFrench: Bool {
        (Locale.preferredLanguages.first ?? "en").hasPrefix("fr")
    }
}

// MARK: - On-device model tie-breaker (last resort, hard deadline)

#if canImport(FoundationModels)
@available(iOS 26.0, *)
private enum SiriLanguageModelSongMatcher {
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static func bestMatch(
        query: String,
        artistName: String?,
        candidates: [RankedSimpleTrack]
    ) async -> SimpleTrack? {
        guard isAvailable, !candidates.isEmpty else { return nil }
        let shortlist = Array(candidates.prefix(8))
        let catalog = shortlist.enumerated().map { index, candidate in
            "\(index): \(candidate.track.title) — \(candidate.track.artistName ?? "?")"
        }.joined(separator: "\n")

        let prompt = """
        Spoken request (may be misheard): \(query)\(artistName.map { " by \($0)" } ?? "")
        Which numbered song is meant? Answer only the number, or NONE.
        \(catalog)
        """
        let session = LanguageModelSession()
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 4)
        guard let response = try? await session.respond(to: prompt, options: options) else { return nil }
        let answer = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if answer.uppercased().contains("NONE") { return nil }
        guard let index = answer.split(whereSeparator: { !$0.isNumber }).compactMap({ Int($0) }).first,
              shortlist.indices.contains(index) else { return nil }
        SiriDiag.log("EXT LLM matched query=\(query) index=\(index) title=\(shortlist[index].track.title)")
        return shortlist[index].track
    }
}
#endif

/// Resolves a continuation exactly once — whichever of work/deadline wins.
private final class OnceBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }
    func resume(_ value: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

/// Returns `operation`'s value, or nil once `seconds` have passed. The
/// operation is cancelled but not awaited, so a slow model can't hold Siri.
private func withHardDeadline<T: Sendable>(
    _ seconds: Double,
    _ operation: @escaping @Sendable () async -> T?
) async -> T? {
    guard seconds > 0.05 else { return nil }
    return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let box = OnceBox(continuation)
        let work = Task.detached(priority: .userInitiated) {
            box.resume(await operation())
        }
        Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            box.resume(nil)
            work.cancel()
        }
    }
}

// MARK: - Intent handler

class IntentHandler: INExtension, INPlayMediaIntentHandling, INAddMediaIntentHandling {

    /// Total wall-clock budget for one resolve, model included.
    static let resolveBudget: Double = 2.5

    override func handler(for intent: INIntent) -> Any {
        // Start loading the library snapshot while Siri is still setting up
        // the request; resolve waits on the same lock instead of starting
        // from scratch. A no-op when the cached snapshot is current.
        DispatchQueue.global(qos: .userInitiated).async {
            _ = SiriLibraryCache.shared.snapshot()
        }
        return self
    }

    // MARK: INPlayMediaIntentHandling

    func resolveMediaItems(for intent: INPlayMediaIntent, with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void) {
        // NOTE: Siri still routes by-name media requests here even when the
        // assistant-schema App Intents are registered (verified on iOS 27.0)
        // and does NOT fall back to the schema path on .unsupported.
        guard let mediaSearch = intent.mediaSearch else {
            // "Play" with nothing else: keep listening / the whole library.
            completion([.success(with: Self.item("music_all", Self.text("My Music", "Ma musique"), .music))])
            return
        }
        let started = Date()
        SiriDiag.log("EXT resolveMediaItems type=\(mediaSearch.mediaType.rawValue) name=\(mediaSearch.mediaName ?? "nil") artist=\(mediaSearch.artistName ?? "nil") album=\(mediaSearch.albumName ?? "nil") reference=\(mediaSearch.reference.rawValue) genres=\(mediaSearch.genreNames ?? []) moods=\(mediaSearch.moodNames ?? []) shuffled=\(intent.playShuffled.map { "\($0)" } ?? "nil") queue=\(intent.playbackQueueLocation.rawValue)")

        let request = SiriRequest(search: mediaSearch, started: started)
        Task.detached(priority: .userInitiated) {
            let items = await request.resolve()
            SiriDiag.log("EXT resolved \(items.count) items in \(String(format: "%.2f", Date().timeIntervalSince(started)))s: \(items.prefix(5).map { $0.identifier ?? "nil" }.joined(separator: ","))")
            if items.isEmpty {
                // A successful sentinel lets handling return a normal Siri
                // failure. Returning .unsupported makes Siri offer to
                // "continue in Cosmos", which can't fix a missing item.
                completion([.success(with: Self.item(
                    "cosmos_not_found",
                    Self.text("I couldn't find that in Cosmos", "Je n'ai pas trouvé ça dans Cosmos"),
                    .song
                ))])
            } else {
                completion(INPlayMediaMediaItemResolutionResult.successes(with: items))
            }
        }
    }

    func handle(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        SiriDiag.log("EXT handle -> handleInApp items=\(intent.mediaItems?.prefix(5).compactMap { $0.identifier }.joined(separator: ",") ?? "none")")
        if intent.mediaItems?.contains(where: { $0.identifier == "cosmos_not_found" }) == true {
            completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
            return
        }
        completion(INPlayMediaIntentResponse(code: .handleInApp, userActivity: createUserActivity(from: intent)))
    }

    // MARK: INAddMediaIntentHandling ("add this song to favorites / to <playlist>")

    func resolveMediaItems(for intent: INAddMediaIntent, with completion: @escaping ([INAddMediaMediaItemResolutionResult]) -> Void) {
        let mediaSearch = intent.mediaSearch
        SiriDiag.log("EXT AddMedia resolve name=\(mediaSearch?.mediaName ?? "nil") reference=\(mediaSearch?.reference.rawValue ?? -1)")
        let name = mediaSearch?.mediaName
        let isCurrent = mediaSearch?.reference == .currentlyPlaying || name.map(SiriPhrase.isCurrentReference) ?? true
        Task.detached(priority: .userInitiated) {
            if let name, !isCurrent,
               let track = ExtensionDatabaseAccess.shared.searchTracks(query: name, artistName: mediaSearch?.artistName).first {
                completion([.success(with: INMediaItem(identifier: track.stableId, title: track.title, type: .song, artwork: nil, artist: track.artistName))])
                return
            }
            // Default: the currently playing song (the app resolves it).
            completion([.success(with: INMediaItem(identifier: "current_track", title: Self.text("Current Song", "Morceau en cours"), type: .song, artwork: nil, artist: nil))])
        }
    }

    func handle(intent: INAddMediaIntent, completion: @escaping (INAddMediaIntentResponse) -> Void) {
        SiriDiag.log("EXT AddMedia handle -> handleInApp")
        completion(INAddMediaIntentResponse(code: .handleInApp, userActivity: nil))
    }

    // MARK: Helpers

    static func text(_ english: String, _ french: String) -> String {
        SiriPhrase.prefersFrench ? french : english
    }

    static func item(_ identifier: String, _ title: String, _ type: INMediaItemType, artist: String? = nil) -> INMediaItem {
        INMediaItem(identifier: identifier, title: title, type: type, artwork: nil, artist: artist)
    }

    private func createUserActivity(from intent: INPlayMediaIntent) -> NSUserActivity {
        let activity = NSUserActivity(activityType: "com.cosmos.music.play")
        if let mediaSearch = intent.mediaSearch {
            var userInfo: [String: Any] = [:]
            userInfo["mediaType"] = mediaSearch.mediaType.rawValue
            if let mediaName = mediaSearch.mediaName { userInfo["mediaName"] = mediaName }
            if let artistName = mediaSearch.artistName { userInfo["artistName"] = artistName }
            if let albumName = mediaSearch.albumName { userInfo["albumName"] = albumName }
            userInfo["reference"] = mediaSearch.reference.rawValue
            if let mediaItems = intent.mediaItems {
                userInfo["mediaIdentifiers"] = mediaItems.compactMap { $0.identifier }
            }
            activity.userInfo = userInfo
        }
        return activity
    }
}

// MARK: - One request's resolution

private struct SiriRequest: @unchecked Sendable {
    let search: INMediaSearch
    let started: Date

    private typealias Handler = IntentHandler

    private func remaining() -> Double {
        Handler.resolveBudget - Date().timeIntervalSince(started)
    }

    /// Strips "… on Cosmos" / "… dans Cosmos" that Siri sometimes leaves in.
    private static func cleaned(_ raw: String?) -> String? {
        guard var name = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        for suffix in [" on cosmos", " in cosmos", " dans cosmos", " sur cosmos", " avec cosmos", " from cosmos", " de cosmos", " cosmos"] {
            if name.lowercased().hasSuffix(suffix) { name = String(name.dropLast(suffix.count)) }
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    func resolve() async -> [INMediaItem] {
        let name = Self.cleaned(search.mediaName)
        let artistHint = Self.cleaned(search.artistName)
        let type = search.mediaType

        // 1. "Play more like this" / "play this artist".
        if search.reference == .currentlyPlaying {
            if type == .artist {
                return [Handler.item("artist_current", Handler.text("This artist", "Cet artiste"), .artist)]
            }
            return [Handler.item("radio_current", Handler.text("Songs like this one", "Titres similaires"), .station)]
        }

        // 2. No name at all.
        guard let name else {
            if let artistHint {
                return resolveArtist(artistHint, fallbackToName: true)
            }
            let moods = (search.moodNames ?? []) + (search.genreNames ?? [])
            if !moods.isEmpty {
                let text = moods.joined(separator: " ")
                return [Handler.item("generate_\(text)", text, .music)]
            }
            if type == .playlist {
                // "Play my playlist" → the most recently played one.
                let snapshot = SiriLibraryCache.shared.snapshot()
                if let playlist = snapshot.playlists.first {
                    return [Handler.item("playlist_\(playlist.id)", playlist.name, .playlist)]
                }
            }
            return [Handler.item("music_all", Handler.text("My Music", "Ma musique"), .music)]
        }

        let snapshot = SiriLibraryCache.shared.snapshot()
        let ranker = SiriRanker(snapshot: snapshot)
        let key = SiriKey(name)

        // 3. Exact names win over keyword guesses ("Love", "Radio Gaga").
        if let mix = ranker.bestMix(key), mix.score >= 0.97 {
            return [Handler.item("mix_\(mix.record.id)", mix.record.title, .playlist)]
        }
        if let playlist = ranker.bestNamed(key, in: snapshot.playlists), playlist.score >= 0.97 {
            return [Handler.item("playlist_\(playlist.row.id)", playlist.row.name, .playlist)]
        }
        let exactTrack = snapshot.tracks.first { $0.title.text == key.text }

        // 4. Keyword requests.
        if exactTrack == nil {
            switch SiriPhrase.moment(name) {
            case .now?:
                return [Handler.item("mode_now", Handler.text("Something for now", "Quelque chose pour maintenant"), .music)]
            case .tonight?:
                return [Handler.item("mode_tonight", Handler.text("Something for tonight", "Quelque chose pour ce soir"), .music)]
            case nil:
                break
            }
            if SiriPhrase.isLikedSongs(name) {
                return [Handler.item("liked_songs", Handler.text("Liked Songs", "Titres likés"), .playlist)]
            }
            if SiriPhrase.isAllMusic(name) {
                return [Handler.item("music_all", Handler.text("My Music", "Ma musique"), .music)]
            }
            if let shelf = SiriPhrase.mixShelf(name) {
                if let mix = ranker.bestMix(key), mix.score >= 0.85 {
                    return [Handler.item("mix_\(mix.record.id)", mix.record.title, .playlist)]
                }
                switch shelf {
                case .madeForYou:
                    return [Handler.item("mixkind_madeForYou", Handler.text("Made for You", "Pour vous"), .playlist)]
                case .rediscover:
                    return [Handler.item("mixkind_rediscover", Handler.text("Rediscover", "Redécouvrir"), .playlist)]
                }
            }
            let isStation = [.musicStation, .radioStation, .station, .algorithmicRadioStation].contains(type)
            if let subject = SiriPhrase.radioSubject(name) ?? (isStation ? name : nil) {
                if let radio = await resolveRadio(subject: subject, artistHint: artistHint, ranker: ranker) {
                    return radio
                }
            }
        }

        // 5. Typed requests.
        switch type {
        case .song:
            let songs = await songMatches(name, artistHint: artistHint, ranker: ranker)
            if !songs.isEmpty { return songs }
            return await resolveUntyped(name, artistHint: artistHint, ranker: ranker, snapshot: snapshot)

        case .album:
            if let album = ranker.bestNamed(key, in: snapshot.albums), album.score >= 0.75 {
                return [Handler.item("album_\(album.row.id)", album.row.name, .album)]
            }
            return await resolveUntyped(name, artistHint: artistHint, ranker: ranker, snapshot: snapshot)

        case .artist:
            let artists = resolveArtist(name, fallbackToName: false)
            if !artists.isEmpty { return artists }
            return await resolveUntyped(name, artistHint: artistHint, ranker: ranker, snapshot: snapshot)

        case .playlist:
            if let mix = ranker.bestMix(key), mix.score >= 0.85 {
                return [Handler.item("mix_\(mix.record.id)", mix.record.title, .playlist)]
            }
            if let playlist = ranker.bestNamed(key, in: snapshot.playlists), playlist.score >= 0.7 {
                return [Handler.item("playlist_\(playlist.row.id)", playlist.row.name, .playlist)]
            }
            let generic = ["ma playlist", "ma liste de lecture", "mes playlists", "liste de lecture", "my playlist", "playlist"]
            if generic.contains(key.text), let playlist = snapshot.playlists.first {
                return [Handler.item("playlist_\(playlist.id)", playlist.name, .playlist)]
            }
            return await resolveUntyped(name, artistHint: artistHint, ranker: ranker, snapshot: snapshot)

        case .music:
            // "Play some <name> music": a library match, else a mood mix.
            let found = await resolveUntyped(name, artistHint: artistHint, ranker: ranker, snapshot: snapshot)
            return found.isEmpty ? [Handler.item("generate_\(name)", name, .music)] : found

        case .genre:
            return [Handler.item("generate_\(name)", name, .music)]

        default:
            return await resolveUntyped(name, artistHint: artistHint, ranker: ranker, snapshot: snapshot)
        }
    }

    private func resolveArtist(_ spoken: String, fallbackToName: Bool) -> [INMediaItem] {
        let ranker = SiriRanker(snapshot: SiriLibraryCache.shared.snapshot())
        if let best = ranker.bestArtist(SiriKey(spoken)), best.score >= 0.7 {
            // The app re-matches the spoken name fuzzily, all spellings together.
            return [Handler.item("search_artist_\(spoken)", best.name, .artist)]
        }
        return fallbackToName ? [Handler.item("search_artist_\(spoken)", spoken, .artist)] : []
    }

    private func resolveRadio(subject: String, artistHint: String?, ranker: SiriRanker) async -> [INMediaItem]? {
        if SiriPhrase.isCurrentReference(subject) {
            return [Handler.item("radio_current", Handler.text("Songs like this one", "Titres similaires"), .station)]
        }
        let key = SiriKey(subject)
        let artist = ranker.bestArtist(key)
        let songs = ranker.rankTracks(query: key, artist: artistHint.map(SiriKey.init), album: nil, limit: 3)
        let songScore = songs.first?.score ?? 0
        if let artist, artist.score >= 0.8, artist.score >= songScore - 0.02 {
            return [Handler.item("radio_artist_\(subject)", artist.name, .station)]
        }
        if let song = songs.first, songScore >= SiriRanker.songThreshold {
            return [Handler.item("radio_song_\(song.track.stableId)", song.track.title, .station, artist: song.track.artistName)]
        }
        if let artist, artist.score >= 0.7 {
            return [Handler.item("radio_artist_\(subject)", artist.name, .station)]
        }
        return nil
    }

    /// Untyped requests (iOS 27 Siri sends most by-name requests as
    /// mediaType .unknown): pick the kind whose best match is strongest.
    private func resolveUntyped(_ name: String, artistHint: String?, ranker: SiriRanker, snapshot: SiriLibrarySnapshot) async -> [INMediaItem] {
        let key = SiriKey(name)
        let ranked = ranker.rankTracks(query: key, artist: artistHint.map(SiriKey.init), album: nil)
        let songScore = ranked.first?.score ?? 0
        let artist = ranker.bestArtist(key)
        let artistScore = artist?.score ?? 0
        let album = ranker.bestNamed(key, in: snapshot.albums)
        let playlist = ranker.bestNamed(key, in: snapshot.playlists)
        let mix = ranker.bestMix(key)
        SiriDiag.log("EXT untyped '\(name)' song=\(String(format: "%.2f", songScore)) artist=\(String(format: "%.2f", artistScore)) album=\(String(format: "%.2f", album?.score ?? 0)) playlist=\(String(format: "%.2f", playlist?.score ?? 0)) mix=\(String(format: "%.2f", mix?.score ?? 0))")

        // An exact playlist/mix/album name is what was asked for.
        if let playlist, playlist.score >= 0.97 {
            return [Handler.item("playlist_\(playlist.row.id)", playlist.row.name, .playlist)]
        }
        if let mix, mix.score >= 0.97 {
            return [Handler.item("mix_\(mix.record.id)", mix.record.title, .playlist)]
        }
        // An artist's name, even misheard ("Shiva Sagisu"), is an artist
        // request unless a song title matches clearly better.
        if let artist, artistScore >= 0.8, artistScore >= songScore - 0.02 {
            return [Handler.item("search_artist_\(name)", artist.name, .artist)]
        }
        if let album, album.score >= 0.97, album.score >= songScore {
            return [Handler.item("album_\(album.row.id)", album.row.name, .album)]
        }
        let songs = await songMatches(name, artistHint: artistHint, ranker: ranker, preRanked: ranked)
        if !songs.isEmpty { return songs }
        if let playlist, playlist.score >= 0.75 {
            return [Handler.item("playlist_\(playlist.row.id)", playlist.row.name, .playlist)]
        }
        if let mix, mix.score >= 0.8 {
            return [Handler.item("mix_\(mix.record.id)", mix.record.title, .playlist)]
        }
        if let album, album.score >= 0.75 {
            return [Handler.item("album_\(album.row.id)", album.row.name, .album)]
        }
        if let artist, artistScore >= 0.7 {
            return [Handler.item("search_artist_\(name)", artist.name, .artist)]
        }
        // Nothing in the library carries this name: treat the words as a
        // description ("something calm", "du piano") and build a mix from
        // them, rather than answering that nothing was found.
        if SiriKey(name).text.count >= 3 {
            SiriDiag.log("EXT untyped '\(name)' matched nothing; building a mix from the words")
            return [Handler.item("generate_\(name)", name, .music)]
        }
        return []
    }

    /// Deterministic song ranking; the on-device model only breaks a real
    /// tie, within what's left of the request's budget.
    private func songMatches(
        _ query: String,
        artistHint: String?,
        ranker: SiriRanker,
        preRanked: [RankedSimpleTrack]? = nil
    ) async -> [INMediaItem] {
        let ranked = preRanked ?? ranker.rankTracks(query: SiriKey(query), artist: artistHint.map(SiriKey.init), album: nil)
        let best = ranked.first?.score ?? 0
        let cutoff = max(SiriRanker.songThreshold, best - 0.10)
        var deterministic = ranked.prefix(5).filter { $0.score >= cutoff }.map(\.track)

        let second = ranked.dropFirst().first { $0.track.title != ranked.first?.track.title }?.score ?? 0
        let confident = best >= SiriRanker.confidentScore && best - second >= 0.05
        let plausible = ranked.filter { $0.score >= 0.5 }

        if !confident, plausible.count > 1 {
#if canImport(FoundationModels)
            if #available(iOS 26.0, *), SiriLanguageModelSongMatcher.isAvailable {
                let budget = min(remaining(), 2.0)
                let shortlist = Array(plausible.prefix(8))
                let modelStart = Date()
                let pick = await withHardDeadline(budget) {
                    await SiriLanguageModelSongMatcher.bestMatch(query: query, artistName: artistHint, candidates: shortlist)
                }
                SiriDiag.log("EXT model step \(pick == nil ? "no answer" : "answered") in \(String(format: "%.2f", Date().timeIntervalSince(modelStart)))s (budget \(String(format: "%.2f", budget))s)")
                if let pick {
                    deterministic.removeAll { $0.stableId == pick.stableId }
                    deterministic.insert(pick, at: 0)
                }
            }
#endif
        }

        return deterministic.map { track in
            Handler.item(track.stableId, track.title, .song, artist: track.artistName)
        }
    }
}
