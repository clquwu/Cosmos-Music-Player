import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Features

/// What the app can tell about how a song sounds without listening to it:
/// its genre, year and tempo tags, its loudness from ReplayGain - and, for
/// artists whose files carry no tags, the on-device model's description of
/// the artist (`ArtistProfile`).
enum MusicFeatures {
    /// "Rock; Indie", "rock/pop" and " ROCK " all become "rock": the first
    /// genre, lower-cased, so tags written differently still match.
    static func normalizedGenre(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let first = raw.split(whereSeparator: { ";/,|\\".contains($0) }).first.map(String.init) ?? raw
        let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, trimmed != "unknown", trimmed != "other", trimmed != "genre" else { return nil }
        return trimmed
    }

    /// For showing a genre in a subtitle: "hip-hop" becomes "Hip-Hop".
    static func displayGenre(_ genre: String) -> String {
        genre.capitalized(with: Locale.current)
    }

    static func year(of track: Track, albumYear: Int?) -> Int? {
        let year = track.year ?? albumYear
        guard let year, (1900...2100).contains(year) else { return nil }
        return year
    }

    /// 0 calm ... 1 intense, from tempo and loudness. ReplayGain is the gain
    /// that brings a song to a reference level, so a loud master has a large
    /// negative gain. Tags first; where a tag is missing, what the on-device
    /// analysis heard in the file (`AudioAnalyzer`) - its loudness is mapped
    /// onto the same scale. Nil when neither is known either way.
    static func energy(of track: Track) -> Double? {
        let tempo = (track.bpm.map(Double.init) ?? track.analyzedTempo).map { min(max(($0 - 60) / 120, 0), 1) }
        let loudness = track.replaygainTrackGain.map { min(max(-$0 / 12, 0), 1) } ?? track.analyzedEnergy
        switch (tempo, loudness) {
        case let (tempo?, loudness?): return tempo * 0.6 + loudness * 0.4
        case let (tempo?, nil): return tempo
        case let (nil, loudness?): return loudness
        case (nil, nil): return nil
        }
    }

    /// 0 squashed ... 1 wide dynamics, from the peak-to-loudness ratio:
    /// how far the loudest instant stands above the average level. A
    /// brick-walled modern master sits around 6 dB, a classical recording
    /// at 18 dB or more. Tempo and loudness alone call a quiet string
    /// quartet and a soft-mastered rock song the same; this tells them
    /// apart. ReplayGain's reference is -18 LUFS, so the song's loudness is
    /// -18 - gain. Nil without both tags.
    static func dynamics(of track: Track) -> Double? {
        guard let peak = track.replaygainTrackPeak, peak > 0, let gain = track.replaygainTrackGain else { return nil }
        let loudness = -18 - gain
        let ratio = 20 * log10(peak) - loudness
        return min(max((ratio - 6) / 14, 0), 1)
    }

    /// 0 dark ... 1 bright, from the on-device analysis only - no tag says
    /// it. A third sound axis beside energy and dynamics: a mellow piano
    /// record and a mellow synth-pop one share the first two, not this.
    static func brightness(of track: Track) -> Double? {
        track.analyzedBrightness
    }
}

// MARK: - On-device model budget

/// Keeps the app's own background use of the on-device model small: a few
/// requests a day, none in Low Power Mode or when the device is hot. What the
/// listener asks for directly (Siri, "make me a mix") does not count here.
@MainActor
enum LocalModelBudget {
    private static let dailyLimit = 8
    private static let storageKey = "cosmos.localModelBudget"

    private static var today: String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }

    private static var used: Int {
        let stored = UserDefaults.standard.dictionary(forKey: storageKey)
        return stored?["day"] as? String == today ? (stored?["count"] as? Int ?? 0) : 0
    }

    /// Whether background work may run now at all.
    static var allowsBackgroundWork: Bool {
        !ProcessInfo.processInfo.isLowPowerModeEnabled
            && ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue
            && used < dailyLimit
    }

    /// Takes one request from today's allowance; false when none is left.
    static func spend() -> Bool {
        guard allowsBackgroundWork else { return false }
        UserDefaults.standard.set(["day": today, "count": used + 1], forKey: storageKey)
        return true
    }
}

// MARK: - Artist profiles

/// A broad description of an artist from the on-device model, used only
/// where the files have no genre or year tags. Real tags always win.
struct ArtistProfile: Codable, Equatable {
    /// Broad styles, lower-case, e.g. ["jazz", "soul"]. Empty when unknown.
    var styles: [String]
    /// 1 calm ... 5 intense; 0 when unknown.
    var energy: Int
    /// e.g. 1990; 0 when unknown.
    var decade: Int
}

/// Profiles of the artists in the library, kept on the device.
@MainActor
final class ArtistProfileStore {
    static let shared = ArtistProfileStore()

    private(set) var profiles: [String: ArtistProfile] = [:]
    private var isProfiling = false
    /// Bumped by `clear()`: profiling or a save started before it must not
    /// bring the forgotten profiles back.
    private var generation = 0

    /// Artists the model was asked about and could not place, so they are
    /// not asked about on every launch.
    private var attempted: Set<String> = []

    private static let batchSize = 20
    /// Per run: the model runs on the device, so the library is profiled a
    /// little at a time rather than all at once - each batch also spends one
    /// request of `LocalModelBudget`.
    private static let perLaunchLimit = 40

    private struct Stored: Codable {
        var profiles: [String: ArtistProfile]
        var attempted: [String]
    }

    nonisolated private static var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("artist-profiles.json")
    }

    private init() {
        if let url = Self.fileURL,
           let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            profiles = stored.profiles
            attempted = Set(stored.attempted)
        }
    }

    /// Spellings of one artist share a profile.
    nonisolated static func key(for name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func profile(for name: String) -> ArtistProfile? {
        profiles[Self.key(for: name)]
    }

    /// Asks the model about artists that have no genre tags and no profile
    /// yet, most-played first. Returns true when anything new was learned.
    /// `hints` maps an artist's name to one of their album titles, which
    /// tells the model which artist of that name is meant.
    func profileMissing(_ artists: [String], hints: [String: String]) async -> Bool {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *), !isProfiling else { return false }
        guard case .available = SystemLanguageModel.default.availability else { return false }
        let pending = artists
            .filter { profiles[Self.key(for: $0)] == nil && !attempted.contains(Self.key(for: $0)) }
            .prefix(Self.perLaunchLimit)
        guard !pending.isEmpty else { return false }

        isProfiling = true
        defer { isProfiling = false }
        let startedIn = generation
        var learned = false
        for batch in stride(from: 0, to: pending.count, by: Self.batchSize).map({ Array(pending.dropFirst($0).prefix(Self.batchSize)) }) {
            guard !Task.isCancelled, generation == startedIn, LocalModelBudget.spend() else { break }
            let results = await FoundationArtistProfiler.profile(batch, hints: hints)
            // History cleared while the model answered: drop what it said.
            guard generation == startedIn else { return false }
            for name in batch {
                let key = Self.key(for: name)
                attempted.insert(key)
                if let profile = results[key], !profile.styles.isEmpty || profile.decade > 0 || profile.energy > 0 {
                    profiles[key] = profile
                    learned = true
                }
            }
            save()
        }
        return learned
        #else
        return false
        #endif
    }

    func clear() {
        generation += 1
        profiles = [:]
        attempted = []
        if let url = Self.fileURL { try? FileManager.default.removeItem(at: url) }
    }

    private func save() {
        let stored = Stored(profiles: profiles, attempted: Array(attempted))
        let savedIn = generation
        Task.detached(priority: .utility) {
            guard let url = ArtistProfileStore.fileURL, let data = try? JSONEncoder().encode(stored),
                  await ArtistProfileStore.shared.generation == savedIn else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}

#if canImport(FoundationModels)
/// Broad styles, few enough that two artists described separately still
/// land on the same words.
@available(iOS 26.0, *)
@Generable
enum MusicStyle: CaseIterable {
    case rock, pop, indie, metal, punk, hiphop, rnb, soul, funk, jazz, blues, classical, soundtrack,
         electronic, dance, ambient, folk, country, latin, reggae, world, jpop, kpop, anime, gospel, unknown

    var name: String? {
        switch self {
        case .hiphop: return "hip-hop"
        case .rnb: return "r&b"
        case .jpop: return "j-pop"
        case .kpop: return "k-pop"
        case .unknown: return nil
        default: return String(describing: self)
        }
    }
}

@available(iOS 26.0, *)
@Generable
struct ArtistProfileGuess {
    @Guide(description: "The artist's name, exactly as given")
    var name: String
    @Guide(description: "One to three broad styles of this artist's music. Use unknown when you do not know this artist.", .maximumCount(3))
    var styles: [MusicStyle]
    @Guide(description: "Typical energy of their music from 1 (calm) to 5 (intense), or 0 if unknown", .range(0...5))
    var energy: Int
    @Guide(description: "The decade most of their music comes from, such as 1970 or 2010, or 0 if unknown", .range(0...2030))
    var decade: Int
}

@available(iOS 26.0, *)
@Generable
struct ArtistProfileBatch {
    @Guide(description: "One entry per artist in the list")
    var artists: [ArtistProfileGuess]
}

@available(iOS 26.0, *)
enum FoundationArtistProfiler {
    static func profile(_ artists: [String], hints: [String: String]) async -> [String: ArtistProfile] {
        let session = LanguageModelSession(instructions: """
        You describe music artists for a personal music library. For each artist give \
        broad styles, a typical energy and the decade most of their music is from. \
        If you are not sure who an artist is, answer unknown and 0 rather than guessing.
        """)
        let list = artists.map { name in
            hints[name].map { "\(name) (album: \($0))" } ?? name
        }.joined(separator: "\n")
        guard let response = try? await session.respond(to: "Artists:\n\(list)", generating: ArtistProfileBatch.self) else {
            return [:]
        }
        var result: [String: ArtistProfile] = [:]
        for guess in response.content.artists {
            let decade = guess.decade >= 1900 ? guess.decade / 10 * 10 : 0
            result[ArtistProfileStore.key(for: guess.name)] = ArtistProfile(
                styles: guess.styles.compactMap(\.name),
                energy: guess.energy,
                decade: decade
            )
        }
        return result
    }
}
#endif
