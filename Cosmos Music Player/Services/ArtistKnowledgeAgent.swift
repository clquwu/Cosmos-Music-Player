//
//  ArtistKnowledgeAgent.swift
//  Cosmos Music Player
//
//  On devices with Apple Intelligence, a short tool-calling loop with the
//  on-device model that settles which of several namesakes the library
//  means and writes a 2-3 sentence bio in the device language. The model
//  knows little about niche artists and would happily invent, so it only
//  gets to read what the tools fetch, and its answer is checked against
//  what they returned. Everything it does is optional: the artist page
//  already shows the deterministic result, and any failure keeps it.
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// What the agent concluded, in plain types so callers need no
/// FoundationModels import.
struct ArtistKnowledgeOutcome: Sendable {
    enum Confidence: String, Sendable { case high, medium, low }

    struct GroundedSource: Sendable {
        let source: ArtistInfoSource
        let url: String?
        /// The artist the text was about, when known.
        let musicBrainzID: String?
    }

    /// Only ids the tools returned; nil when the model gave none or made
    /// one up.
    let musicBrainzID: String?
    /// Nil when no text was fetched or the model wrote none.
    let bio: String?
    let confidence: Confidence
    /// The texts the bio may be based on.
    let groundedSources: [GroundedSource]
}

#if canImport(FoundationModels)

/// What the tools fetched during one run, so the answer can be checked
/// against it. Tools run concurrently with the session, hence the lock.
final class ArtistAgentLog: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<String> = []
    private var texts: [ArtistKnowledgeOutcome.GroundedSource] = []

    func saw(ids newIDs: [String]) {
        lock.lock(); defer { lock.unlock() }
        ids.formUnion(newIDs)
    }

    func read(_ source: ArtistKnowledgeOutcome.GroundedSource) {
        lock.lock(); defer { lock.unlock() }
        texts.append(source)
    }

    var seenIDs: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return ids
    }

    var sources: [ArtistKnowledgeOutcome.GroundedSource] {
        lock.lock(); defer { lock.unlock() }
        return texts
    }
}

// MARK: - Tools

@available(iOS 26.0, *)
struct SearchMusicBrainzTool: Tool {
    let name = "searchMusicBrainz"
    let description = "Searches MusicBrainz for artists with a name. Lists each candidate's id, description, country and years, and whether they released the given album."

    let log: ArtistAgentLog

    @Generable
    struct Arguments {
        @Guide(description: "The artist name to search for")
        var name: String
        @Guide(description: "One album title by this artist from the listener's library, or an empty string")
        var albumHint: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        let service = MusicBrainzAPIService.shared
        let candidates = try await service.searchArtists(name: arguments.name, limit: 6)
        let plausible = MusicBrainzAPIService.plausibleMatches(for: arguments.name, in: candidates)
        let shown = Array((plausible.isEmpty ? candidates : plausible).prefix(5))
        guard !shown.isEmpty else { return "No artist named \(arguments.name) on MusicBrainz." }
        log.saw(ids: shown.map(\.id))

        let hint = arguments.albumHint.trimmingCharacters(in: .whitespacesAndNewlines)
        var votes: [String: Int] = [:]
        if !hint.isEmpty {
            votes = (try? await service.artistIDs(creditedOn: [hint], artistName: arguments.name)) ?? [:]
        }

        return shown.map { candidate in
            var parts = ["id: \(candidate.id)", "name: \(candidate.name)"]
            if let disambiguation = candidate.disambiguation { parts.append("about: \(disambiguation)") }
            if let country = candidate.country { parts.append("country: \(country)") }
            if let years = candidate.activeYears { parts.append("years: \(years)") }
            if !hint.isEmpty {
                parts.append("released \"\(hint)\": \(votes[candidate.id, default: 0] > 0 ? "yes" : "no")")
            }
            return parts.joined(separator: "; ")
        }.joined(separator: "\n")
    }
}

@available(iOS 26.0, *)
struct WikipediaSummaryTool: Tool {
    let name = "wikipediaSummary"
    let description = "Returns the opening of an artist's Wikipedia article. Pass an article title, or a MusicBrainz id to get that artist's article."

    let log: ArtistAgentLog

    @Generable
    struct Arguments {
        @Guide(description: "A Wikipedia article title, or a MusicBrainz artist id")
        var title: String
        @Guide(description: "A Wikipedia language code such as en, fr or ja")
        var language: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        let title = arguments.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = arguments.language.isEmpty ? "en" : arguments.language.lowercased()
        var summary: WikipediaSummary?
        var artistID: String?

        if UUID(uuidString: title) != nil {
            // A MusicBrainz id: follow its own Wikidata link, so the article
            // is that artist's and not a namesake's.
            let details = try await MusicBrainzAPIService.shared.artist(id: title)
            artistID = details.candidate.id
            if let wikidataID = details.wikidataID {
                let titles = try await WikipediaAPI.articleTitles(wikidataID: wikidataID, languages: [language, "en"])
                for edition in [language, "en"] {
                    guard let article = titles[edition] else { continue }
                    if let found = try await WikipediaAPI.summary(title: article, language: edition) { summary = found; break }
                }
            } else if let articleURL = details.wikipediaURL {
                summary = try await WikipediaAPI.summary(articleURL: articleURL)
            }
        } else {
            summary = try await WikipediaAPI.summary(title: title, language: language)
        }

        guard let summary else { return "No Wikipedia article found." }
        log.read(.init(source: .wikipedia, url: summary.pageURL, musicBrainzID: artistID))
        return "Article \"\(summary.title)\" (\(summary.language)):\n\(ArtistKnowledgeAgent.clip(summary.extract, to: 1200))"
    }
}

@available(iOS 26.0, *)
struct DiscogsSearchTool: Tool {
    let name = "discogsSearch"
    let description = "Returns an artist's profile text from Discogs, for artists without a Wikipedia article."

    let log: ArtistAgentLog
    let discogs: DiscogsAPIService

    @Generable
    struct Arguments {
        @Guide(description: "The artist name to look up")
        var name: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        guard let artist = try await discogs.searchArtist(name: arguments.name) else {
            return "No artist named \(arguments.name) on Discogs."
        }
        let profile = DiscogsAPIService.cleanProfile(artist.profile)
        guard !profile.isEmpty else { return "Discogs has \(artist.name) but no profile text." }
        // A name search may land on a namesake, so this text is not tied to
        // any MusicBrainz id.
        log.read(.init(source: .discogs, url: artist.uri, musicBrainzID: nil))
        return "Discogs profile of \(artist.name):\n\(ArtistKnowledgeAgent.clip(profile, to: 900))"
    }
}

// MARK: - Answer

@available(iOS 26.0, *)
@Generable
enum ArtistKnowledgeConfidence {
    case high, medium, low
}

@available(iOS 26.0, *)
@Generable
struct ArtistKnowledgeAnswer {
    @Guide(description: "The MusicBrainz id of the artist the listener means, copied exactly from the tool results or the current match. Empty if unsure.")
    var musicBrainzID: String
    @Guide(description: "Two or three sentences about that artist using only facts from fetched text. Empty if no text was fetched.")
    var bio: String
    @Guide(description: "high only when the albums or the fetched text clearly identify the artist; low when unsure or nothing was fetched")
    var confidence: ArtistKnowledgeConfidence
}

// MARK: - Agent

@available(iOS 26.0, *)
enum ArtistKnowledgeAgent {
    /// Long enough for two or three tool calls and an answer; past it the
    /// listener is better served by what the page already shows.
    /// Long enough for the model to load on a cold start and make a few
    /// tool calls - each MusicBrainz call waits about a second for its rate
    /// limit. Eight seconds ran out on every run on an iPhone 16e. The page
    /// shows the plain result meanwhile, so the wait costs nothing visible.
    static let timeLimit: TimeInterval = 30

    /// Why the model is or is not available, for the logs.
    static var availabilityDescription: String {
        switch SystemLanguageModel.default.availability {
        case .available: return "available"
        case .unavailable(let reason): return "unavailable (\(reason))"
        @unknown default: return "unknown"
        }
    }

    static func isAvailable(language: String) -> Bool {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { return false }
        return model.supportsLocale(Locale(identifier: language))
    }

    static func clip(_ text: String, to length: Int) -> String {
        text.count > length ? String(text.prefix(length)) + "…" : text
    }

    /// Nil on any failure or after `timeLimit`.
    /// `rejected`: the listener said the current match is the wrong artist
    /// and there is no other same-name artist to fall back on - the model
    /// searches for the right one and must not answer the rejected id.
    static func run(name: String, albumHints: [String], current: UnifiedArtist, language: String, discogs: DiscogsAPIService, rejected: Bool = false) async -> ArtistKnowledgeOutcome? {
        let log = ArtistAgentLog()
        // What the deterministic lookup already found counts as fetched:
        // the model may summarise it without calling a tool again.
        if let id = current.musicBrainzID { log.saw(ids: [id] + current.alternativeMusicBrainzIDs) }
        if let source = current.bioSource, source == .wikipedia || source == .discogs, !current.profile.isEmpty {
            log.read(.init(source: source, url: current.bioURL, musicBrainzID: source == .wikipedia ? current.musicBrainzID : nil))
        }

        let languageName = Locale(identifier: "en").localizedString(forLanguageCode: language) ?? "English"
        let prompt = makePrompt(name: name, albumHints: albumHints, current: current, rejected: rejected)

        let started = Date()
        let answer: ArtistKnowledgeAnswer? = await withTimeLimit(timeLimit) {
            let session = LanguageModelSession(
                tools: [
                    SearchMusicBrainzTool(log: log),
                    WikipediaSummaryTool(log: log),
                    DiscogsSearchTool(log: log, discogs: discogs)
                ],
                instructions: """
                You identify a music artist from a listener's library and describe them briefly. \
                Use only facts from the text in this conversation and from tool results; never add \
                anything you remember yourself. If several artists share the name, call \
                searchMusicBrainz with one of the listener's album titles to see which one released it. \
                If you need text about the artist, call wikipediaSummary with their MusicBrainz id, or \
                discogsSearch. Write the bio in \(languageName). If you cannot tell which artist it is, \
                or have no text about them, answer with low confidence.
                """
            )
            do {
                return try await session.respond(to: prompt, generating: ArtistKnowledgeAnswer.self).content
            } catch {
                print("⚠️ ArtistAgent: \(error.localizedDescription)")
                return nil
            }
        }
        guard let answer else {
            print("⚠️ ArtistAgent: no answer for \(name) within \(Int(timeLimit)) s")
            return nil
        }
        print("🧠 ArtistAgent: \(name) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s → id \(answer.musicBrainzID), confidence \(answer.confidence), \(log.sources.count) text(s) fetched, bio \(answer.bio.count) chars")

        let confidence: ArtistKnowledgeOutcome.Confidence
        switch answer.confidence {
        case .high: confidence = .high
        case .medium: confidence = .medium
        case .low: confidence = .low
        }

        // An id is only taken when a tool or the lookup produced it. The model
        // has been seen copying one with a character dropped; such a near
        // miss is mapped back to the id the tools actually returned.
        let answered = answer.musicBrainzID.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = Self.returnedID(matching: answered, among: log.seenIDs) ?? answered
        // A rejected match can never come back as the answer.
        let musicBrainzID = log.seenIDs.contains(id) && !(rejected && id == current.musicBrainzID) ? id : nil

        let sources = log.sources
        let bio = answer.bio.trimmingCharacters(in: .whitespacesAndNewlines)
        // A bio with nothing fetched behind it can only be from memory.
        let groundedBio = !sources.isEmpty && bio.count >= 40 && bio.count <= 900 ? bio : nil

        return ArtistKnowledgeOutcome(
            musicBrainzID: musicBrainzID,
            bio: groundedBio,
            confidence: musicBrainzID == nil && groundedBio == nil ? .low : confidence,
            groundedSources: sources
        )
    }

    /// The returned id `answer` is a copy of: itself, or the single one within
    /// two edits of it (length within one). MusicBrainz ids are UUIDs, so two
    /// real ids are never that close; anything less certain is no match.
    private static func returnedID(matching answer: String, among seen: Set<String>) -> String? {
        guard !answer.isEmpty else { return nil }
        if seen.contains(answer) { return answer }
        let target = Array(answer.lowercased())
        let near = seen.filter { candidate in
            abs(candidate.count - target.count) <= 1
                && editDistance(Array(candidate.lowercased()), target, limit: 2) <= 2
        }
        return near.count == 1 ? near.first : nil
    }

    /// Levenshtein distance, giving up (returning `limit + 1`) once it is
    /// certainly above `limit`.
    private static func editDistance(_ a: [Character], _ b: [Character], limit: Int) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                )
            }
            if current.min() ?? 0 > limit { return limit + 1 }
            previous = current
        }
        return previous[b.count]
    }

    private static func makePrompt(name: String, albumHints: [String], current: UnifiedArtist, rejected: Bool) -> String {
        var lines = ["Artist in the library: \(name)"]
        if !albumHints.isEmpty {
            lines.append("Their albums in the library: \(albumHints.prefix(5).joined(separator: "; "))")
        }
        if let id = current.musicBrainzID {
            var match = "Current match: MusicBrainz id \(id)"
            if let disambiguation = current.disambiguation { match += " (\(disambiguation))" }
            lines.append(match)
        }
        if rejected, current.musicBrainzID == nil, !current.profile.isEmpty {
            // A match from Discogs or Spotify has no MusicBrainz id: describe
            // it, so the model can tell the wrong artist apart.
            lines.append("The wrong match (from \(current.source.rawValue)) was described as: \(clip(current.profile, to: 300))")
        }
        if rejected {
            lines.append("""
            The listener says this current match is the WRONG artist. Find the artist who actually \
            made their albums: call searchMusicBrainz with the name and an album title, and try other \
            spellings or the artist's name in its original script if nothing fits. Never answer the \
            current id. If no other artist clearly released these albums, answer with low confidence.
            """)
        } else if current.isAmbiguous && !current.alternativeMusicBrainzIDs.isEmpty {
            lines.append("Other artists with this name exist; check which one released the listener's albums.")
        }
        if !rejected, !current.profile.isEmpty, current.bioSource == .wikipedia || current.bioSource == .discogs {
            lines.append("Fetched text about the current match (\(current.bioSource?.displayName ?? "")):")
            lines.append(clip(current.profile, to: 1200))
        }
        return lines.joined(separator: "\n")
    }

    /// Runs `operation`, giving up with nil after `seconds`. The model and
    /// the tools' requests are cancelled when the time is up.
    private static func withTimeLimit<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

#endif
