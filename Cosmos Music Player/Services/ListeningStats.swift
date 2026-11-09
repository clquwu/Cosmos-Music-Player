import Foundation
import GRDB

// MARK: - Listening stats

/// Listening totals kept for good, month by month and day by day - what
/// yearly and monthly stats will be built from.
///
/// `ListeningLog` keeps only the last 5,000 listens with their dates; older
/// ones roll into per-song lifetime totals that have none, so "what did I
/// play in March" is gone after a few months. This keeps, per calendar month
/// and per song, the plays (listens that were not skips), the skips and the
/// seconds actually heard; per day, the seconds and plays; and each song's
/// title, artist and album as they were when it played, so a song deleted
/// later still counts towards its artist and album.
///
/// Fed by `ListeningLog` whenever it settles how a listen went (the song
/// changed, or the app went to the background). A listen settled twice -
/// a song resumed within half an hour, or written on the way to the
/// background and finished later - has its play/skip outcome replaced, not
/// added again; the seconds are always only the ones heard since the last
/// time. Small by construction - a month holds one entry per song played in
/// it - and never pruned. Stored as JSON in Application Support, read and
/// written off the main thread, a couple of seconds after the last change.
/// "Clear Listening History" clears it with the log.
@MainActor
final class ListeningStats {
    static let shared = ListeningStats()

    struct SongCount: Codable, Equatable {
        var plays = 0
        var skips = 0
        /// Time the song was actually playing - seeks skipped over do not
        /// count - in seconds.
        var seconds = 0.0
    }

    struct Month: Codable, Equatable {
        /// By stable id.
        var songs: [String: SongCount] = [:]
    }

    struct Day: Codable, Equatable {
        var seconds = 0.0
        var plays = 0
    }

    /// A song as it was tagged when last counted.
    struct SongInfo: Codable, Equatable {
        var title: String
        var artist: String?
        var album: String?
        var albumArtist: String?
        var genre: String?
        var year: Int?
        var durationMs: Int?
    }

    enum Outcome: String, Codable {
        case play, skip
    }

    /// The listen counted last, and where its outcome went.
    struct Credit: Codable, Equatable {
        var id: String
        var startedAt: Date
        var month: String
        var day: String
        var outcome: Outcome
    }

    struct Store: Codable {
        var version = 1
        /// When the first listen was counted.
        var since: Date?
        /// "2026-11" -> that month's counts, in the listener's time zone.
        var months: [String: Month] = [:]
        /// "2026-11-08" -> that day's totals.
        var days: [String: Day] = [:]
        /// Stable id -> title, artist, album.
        var songs: [String: SongInfo] = [:]
        var lastCredit: Credit?
    }

    /// One settled listen, kept until the stored totals have been read.
    private struct Listen {
        let id: String
        let startedAt: Date
        let skipped: Bool
        let seconds: Double
        let info: SongInfo?
    }

    /// Nil until the file has been read; listens settled before that wait
    /// in `queued`, so reading it never holds up the main thread at launch.
    private var store: Store?
    private var queued: [Listen] = []
    private var loadTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    /// Bumped by `clear()`; a load or save started before it must not land.
    private var generation = 0

    nonisolated static var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("listening-stats.json")
    }

    private init() {}

    /// Starts reading the stored totals. Called once at launch; `record`
    /// also starts it if needed.
    func load() {
        guard store == nil, loadTask == nil else { return }
        let generation = self.generation
        loadTask = Task.detached(priority: .utility) {
            var loaded = Store()
            if let url = ListeningStats.fileURL, let data = try? Data(contentsOf: url) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let decoded = try? decoder.decode(Store.self, from: data) {
                    loaded = decoded
                }
            }
            await ListeningStats.shared.finishLoading(loaded, generation: generation)
        }
    }

    private func finishLoading(_ loaded: Store, generation: Int) {
        loadTask = nil
        guard generation == self.generation else { return }
        store = loaded
        guard !queued.isEmpty else { return }
        let waiting = queued
        queued = []
        for listen in waiting { apply(listen) }
        scheduleSave()
    }

    /// Counts a listen whose outcome `ListeningLog` has just settled.
    ///
    /// - Parameters:
    ///   - startedAt: when the listen began; with `id`, what identifies it,
    ///     and what decides its month and day.
    ///   - seconds: heard since the last time this listen was counted.
    ///   - track: the song, for its title, artist and album.
    func record(id: String, startedAt: Date, skipped: Bool, seconds: Double, track: Track?) {
        let listen = Listen(
            id: id,
            startedAt: startedAt,
            skipped: skipped,
            seconds: max(0, seconds),
            info: track.map(Self.info(for:))
        )
        guard store != nil else {
            queued.append(listen)
            load()
            return
        }
        apply(listen)
        scheduleSave()
    }

    /// The totals as they stand, once read. For a future stats screen.
    var current: Store? { store }

    /// Forgets every count. Part of "Clear Listening History".
    func clear() {
        generation += 1
        saveTask?.cancel()
        loadTask?.cancel()
        loadTask = nil
        queued = []
        store = Store()
        if let url = Self.fileURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func apply(_ listen: Listen) {
        guard var store else { return }
        let month = Self.monthKey(listen.startedAt)
        let day = Self.dayKey(listen.startedAt)
        let outcome: Outcome = listen.skipped ? .skip : .play

        if store.since == nil { store.since = listen.startedAt }

        // The same listen settled again: move its outcome rather than count
        // it twice.
        var countsOutcome = true
        // Within a second: the file keeps whole seconds (ISO 8601).
        if let last = store.lastCredit, last.id == listen.id,
           abs(last.startedAt.timeIntervalSince(listen.startedAt)) < 1 {
            if last.outcome == outcome {
                countsOutcome = false
            } else {
                store.months[last.month, default: Month()].songs[listen.id, default: SongCount()].remove(last.outcome)
                if last.outcome == .play {
                    store.days[last.day, default: Day()].plays = max(0, store.days[last.day, default: Day()].plays - 1)
                }
            }
        }
        if countsOutcome {
            store.months[month, default: Month()].songs[listen.id, default: SongCount()].add(outcome)
            if outcome == .play { store.days[day, default: Day()].plays += 1 }
        }

        if listen.seconds > 0 {
            store.months[month, default: Month()].songs[listen.id, default: SongCount()].seconds += listen.seconds
            store.days[day, default: Day()].seconds += listen.seconds
        }
        if let info = listen.info { store.songs[listen.id] = info }
        store.lastCredit = Credit(id: listen.id, startedAt: listen.startedAt, month: month, day: day, outcome: outcome)
        self.store = store
    }

    private func scheduleSave() {
        guard let snapshot = store else { return }
        saveTask?.cancel()
        let generation = self.generation
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let url = ListeningStats.fileURL else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(snapshot),
                  await ListeningStats.shared.generation == generation else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: Keys and song details

    /// "2026-11", in the listener's calendar and time zone.
    static func monthKey(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    /// "2026-11-08".
    static func dayKey(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Two indexed reads, once per song change: the artist names as shown
    /// (all credited artists) and the album's title and album artist.
    private static func info(for track: Track) -> SongInfo {
        let database = DatabaseManager.shared
        let artist = try? database.getArtistDisplayName(forTrackStableId: track.stableId, fallbackArtistId: track.artistId)
        let album = track.albumId.flatMap { albumId in
            try? database.read { db in try Album.fetchOne(db, key: albumId) }
        }
        return SongInfo(
            title: track.title,
            artist: artist,
            album: album?.title,
            albumArtist: album?.albumArtist,
            genre: track.genre,
            year: track.year,
            durationMs: track.durationMs
        )
    }
}

private extension ListeningStats.SongCount {
    mutating func add(_ outcome: ListeningStats.Outcome) {
        switch outcome {
        case .play: plays += 1
        case .skip: skips += 1
        }
    }

    mutating func remove(_ outcome: ListeningStats.Outcome) {
        switch outcome {
        case .play: plays = max(0, plays - 1)
        case .skip: skips = max(0, skips - 1)
        }
    }
}
