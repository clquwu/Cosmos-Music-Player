import SwiftUI
import GRDB
import AVFoundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Listening log

/// Every listen, with when it happened and how much of the song was heard,
/// kept on the device.
///
/// One event is written when playback actually starts on a song - restoring
/// last session's track at launch is not a listen - and repeats of the same
/// song within half an hour count once. How much was heard is filled in when
/// the song changes or the app goes to the background, so a song skipped
/// after a few seconds counts against it rather than as a play.
@MainActor
final class ListeningLog: ObservableObject {
    static let shared = ListeningLog()

    struct Event: Codable, Equatable {
        let id: String
        let at: Date
        /// Fraction of the song heard, 0...1. Nil for listens logged before
        /// this was recorded, which count as full plays.
        var heard: Double? = nil
        /// Left within the first 30 seconds and before a third of the song.
        var skipped: Bool? = nil
        /// Where the play came from: "mix:<id>", "radio:<song>", "album",
        /// "playlist", "artist", "liked", "shuffle"; nil when the listener
        /// picked the song themselves. Lets each mix be judged by how its
        /// songs are received, and keeps the app's own mixes from teaching
        /// it the links they were built from.
        var source: String? = nil
        /// Where the sound went: "car", "bluetooth", "headphones",
        /// "speaker" or "airplay". Only the kind of output - never a device
        /// name or a place - so a context mix can tell the car from home.
        var route: String? = nil

        /// How much this listen says the listener likes the song.
        var weight: Double {
            guard let heard else { return 1 }
            if skipped == true { return -0.6 }
            if heard >= 0.8 { return 1 }
            if heard >= 0.3 { return 0.5 }
            return 0.2
        }

        var isSkip: Bool { skipped == true }
    }

    /// What one song's listens add up to over the whole time the app has
    /// known it, once they have rolled off the log. The log keeps 5 000
    /// listens - about three months for someone who listens all day - and
    /// without this, a favourite from last year would look never played.
    struct Lifetime: Codable, Equatable {
        /// Listens that were not skips.
        var plays = 0
        /// Heard at least 80 %.
        var completions = 0
        var skips = 0
        var firstPlayed: Date
        /// The last listen that was not a skip.
        var lastPlayed: Date?
        /// How much the listener likes it in the long run: listens weighted
        /// like `Event.weight`, fading with a half-life of about six months.
        /// Stored as it stood at `scoredAt`; `score(at:)` fades it to now.
        var score = 0.0
        var scoredAt: Date

        static let halfLifeDays = 180.0

        init(firstPlayed: Date) {
            self.firstPlayed = firstPlayed
            self.scoredAt = firstPlayed
        }

        mutating func add(_ event: Event) {
            if event.isSkip {
                skips += 1
            } else {
                plays += 1
                if (event.heard ?? 1) >= 0.8 { completions += 1 }
                lastPlayed = max(lastPlayed ?? .distantPast, event.at)
            }
            firstPlayed = min(firstPlayed, event.at)
            // Events arrive oldest first, so this is usually the first branch.
            if event.at >= scoredAt {
                score = score * Self.fade(event.at.timeIntervalSince(scoredAt)) + event.weight
                scoredAt = event.at
            } else {
                score += event.weight * Self.fade(scoredAt.timeIntervalSince(event.at))
            }
        }

        func score(at date: Date) -> Double {
            score * Self.fade(max(0, date.timeIntervalSince(scoredAt)))
        }

        static func fade(_ interval: TimeInterval) -> Double {
            pow(0.5, interval / 86_400 / halfLifeDays)
        }
    }

    @Published private(set) var events: [Event] = []
    /// Per song, the listens that have rolled off the log. Folded in as they
    /// leave rather than as they arrive: how much of a song was heard is only
    /// known after it was added, and a listen counts here exactly once.
    private(set) var lifetime: [String: Lifetime] = [:]
    /// How many listens have rolled off, so "a lot of new listening" can
    /// still be noticed once the log is full.
    private(set) var rolledOff = 0
    private var lifetimeChanged = false
    /// Bumped whenever more listens roll off, so a save that wrote an older
    /// lifetime does not mark a newer roll-off as written.
    private var lifetimeRevision = 0

    /// Every listen ever logged, including those that rolled off.
    var totalListens: Int { events.count + rolledOff }

    private struct StoredLifetime: Codable {
        var tracks: [String: Lifetime]
        var rolledOff: Int
    }

    private static let capacity = 5000
    private var observation: Task<Void, Never>?
    private var trackObservation: Task<Void, Never>?
    private var progressObservation: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    /// Bumped by Clear History; a save started before it must not write.
    private var saveGeneration = 0

    /// The source the current queue was started from, and its songs.
    private var queueSource: String?
    private var queueSongs: Set<String> = []

    /// Marks what is about to play as coming from `source`. Songs played
    /// from anywhere else afterwards are untagged again.
    func tagQueue(_ source: String, tracks: [Track]) {
        queueSource = source
        queueSongs = Set(tracks.map(\.stableId))
        // Something other than a song mix now plays: the skips counted in
        // the last one must not carry over and refill a later one early.
        if !source.hasPrefix("radio:") { MixStore.shared.resetRadioFeedback() }
    }

    /// Whether the song playing now still comes from the queue tagged
    /// `source` - false once the listener started something else (an
    /// album, a playlist), which a song mix must then leave alone.
    func isPlaying(from source: String) -> Bool {
        guard queueSource == source, let current = PlayerEngine.shared.currentTrack else { return false }
        return queueSongs.contains(current.stableId)
    }

    /// The event of the song playing now, and the furthest point heard in it.
    private var openEvent: (index: Int, id: String, duration: TimeInterval)?
    private var furthestHeard: TimeInterval = 0
    private var backgroundObserver: NSObjectProtocol?
    /// For `ListeningStats`: the song of the open event, and the seconds of
    /// it actually played since its listen was last counted - small forward
    /// steps of the playback clock only, so a seek is not time heard (unlike
    /// `furthestHeard`, which is about how far into the song it got).
    private var openTrack: Track?
    private var heardSeconds: TimeInterval = 0
    private var lastPlaybackTime: TimeInterval?

    nonisolated private static var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("listening-log.json")
    }

    nonisolated private static var lifetimeURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("listening-lifetime.json")
    }

    private init() {
        let signpost = Perf.begin("ListeningLog load")
        defer { Perf.end("ListeningLog load", signpost) }
        if let url = Self.fileURL,
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([Event].self, from: data) {
            events = decoded
        }
        if let url = Self.lifetimeURL,
           let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode(StoredLifetime.self, from: data) {
            lifetime = stored.tracks
            rolledOff = stored.rolledOff
        }
    }

    /// Starts listening to the player. Called once at launch.
    func start() {
        guard observation == nil else { return }
        // Read off the main thread now, so it is ready when a listen closes.
        ListeningStats.shared.load()
        let engine = PlayerEngine.shared
        observation = Task { @MainActor [weak self] in
            for await isPlaying in engine.$isPlaying.values {
                guard let self, isPlaying, let track = engine.currentTrack else { continue }
                self.record(track, duration: engine.duration)
            }
        }
        trackObservation = Task { @MainActor [weak self] in
            for await track in engine.$currentTrack.values {
                guard let self else { return }
                if track?.stableId != self.openEvent?.id {
                    self.closeOpenEvent()
                }
            }
        }
        progressObservation = Task { @MainActor [weak self] in
            for await time in engine.progress.$playbackTime.values {
                guard let self, self.openEvent != nil else { continue }
                // The furthest point, not the last: seeking back to replay a
                // passage still means the song was heard that far.
                self.furthestHeard = max(self.furthestHeard, time)
                if let last = self.lastPlaybackTime, time > last, time - last <= 3 {
                    self.heardSeconds += time - last
                }
                self.lastPlaybackTime = time
            }
        }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { _ in
            // Keep the fraction so far; a song can still finish later.
            Task { @MainActor in ListeningLog.shared.writeOpenEvent() }
        }
    }

    /// Forgets everything played: the log, recents and the mixes built from them.
    func clear() {
        saveTask?.cancel()
        // A save already past its cancellation check would write the old
        // log back after the files are removed; each write checks this first.
        saveGeneration += 1
        events = []
        lifetime = [:]
        rolledOff = 0
        lifetimeChanged = false
        openEvent = nil
        heardSeconds = 0
        ListeningStats.shared.clear()
        ListeningHistory.shared.clear()
        ArtistProfileStore.shared.clear()
        MixStore.shared.invalidate()
        UserDefaults.standard.removeObject(forKey: RediscoverCooldown.storageKey)
        UserDefaults.standard.removeObject(forKey: MixLessons.storageKey)
        UserDefaults.standard.removeObject(forKey: "cosmos.tasteCuration")
        for url in [Self.fileURL, Self.lifetimeURL].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func record(_ track: Track, duration: TimeInterval) {
        let now = Date()
        let length = duration > 0 ? duration : TimeInterval(track.durationMs ?? 0) / 1000
        if let last = events.last, last.id == track.stableId, now.timeIntervalSince(last.at) < 30 * 60 {
            // Resuming the same song: keep filling in the same listen.
            if openEvent == nil {
                openEvent = (events.count - 1, track.stableId, length)
                furthestHeard = (last.heard ?? 0) * length
                openTrack = track
                heardSeconds = 0
                lastPlaybackTime = PlayerEngine.shared.progress.playbackTime
            }
            return
        }
        closeOpenEvent()
        let source = queueSongs.contains(track.stableId) ? queueSource : nil
        if source == nil { queueSource = nil; queueSongs = [] }
        events.append(Event(id: track.stableId, at: now, source: source, route: Self.currentRoute()))
        if events.count > Self.capacity {
            let overflow = events.count - Self.capacity
            for event in events.prefix(overflow) {
                lifetime[event.id, default: Lifetime(firstPlayed: event.at)].add(event)
            }
            rolledOff += overflow
            lifetimeChanged = true
            lifetimeRevision += 1
            events.removeFirst(overflow)
        }
        openEvent = (events.count - 1, track.stableId, length)
        furthestHeard = PlayerEngine.shared.progress.playbackTime
        openTrack = track
        heardSeconds = 0
        lastPlaybackTime = PlayerEngine.shared.progress.playbackTime
        ListeningHistory.shared.record(track)
        scheduleSave()
    }

    /// The kind of output playing now. Bluetooth covers both earbuds and
    /// speakers - the port type cannot tell them apart.
    static func currentRoute() -> String? {
        guard let port = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType else { return nil }
        switch port {
        case .carAudio: return "car"
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: return "bluetooth"
        case .headphones, .usbAudio: return "headphones"
        case .builtInSpeaker, .builtInReceiver: return "speaker"
        case .airPlay: return "airplay"
        default: return nil
        }
    }

    /// Writes how much of the current song was heard, and stops following it.
    private func closeOpenEvent() {
        writeOpenEvent()
        if let open = openEvent, events.indices.contains(open.index), events[open.index].id == open.id,
           events[open.index].source?.hasPrefix("radio:") == true {
            MixStore.shared.radioListened(events[open.index])
        }
        openEvent = nil
        furthestHeard = 0
        openTrack = nil
        lastPlaybackTime = nil
    }

    private func writeOpenEvent() {
        guard let open = openEvent, events.indices.contains(open.index), events[open.index].id == open.id,
              open.duration > 0 else { return }
        let fraction = min(furthestHeard / open.duration, 1)
        events[open.index].heard = max(events[open.index].heard ?? 0, fraction)
        events[open.index].skipped = furthestHeard < 30 && fraction < 0.3
        // The long-term month-by-month totals. Counted here, where the
        // listen's outcome is settled; a listen settled again (resumed, or
        // first written on the way to the background) replaces its outcome
        // there, and only adds the seconds heard since.
        ListeningStats.shared.record(
            id: open.id,
            startedAt: events[open.index].at,
            skipped: events[open.index].skipped == true,
            seconds: heardSeconds,
            track: openTrack?.stableId == open.id ? openTrack : nil
        )
        heardSeconds = 0
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = events
        // The lifetime file is written only when a listen rolled off into it.
        let lifetimeSnapshot = lifetimeChanged ? StoredLifetime(tracks: lifetime, rolledOff: rolledOff) : nil
        let generation = saveGeneration
        let revision = lifetimeRevision
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let url = ListeningLog.fileURL,
                  let data = try? JSONEncoder().encode(snapshot) else { return }
            guard await ListeningLog.shared.saveGeneration == generation else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
            if let lifetimeSnapshot, let lifetimeURL = ListeningLog.lifetimeURL,
               let lifetimeData = try? JSONEncoder().encode(lifetimeSnapshot),
               await ListeningLog.shared.saveGeneration == generation {
                try? lifetimeData.write(to: lifetimeURL, options: .atomic)
                await MainActor.run {
                    let log = ListeningLog.shared
                    if log.saveGeneration == generation, log.lifetimeRevision == revision { log.lifetimeChanged = false }
                }
            }
        }
    }
}

// MARK: - Mixes

/// A playlist the app makes for the listener.
struct Mix: Identifiable, Hashable, Codable {
    let id: String
    var title: String
    var subtitle: String
    let trackIds: [String]
    /// Songs with covers, for the mix's collage.
    let coverTrackIds: [String]
    /// The hue of the mix's cover, so each one is recognisable.
    let hue: Double
    /// What the on-device model is told to name the mix from.
    var naming: MixNamingContext? = nil
    /// Where the mix comes from, in the listener's own numbers ("What you
    /// play on weekend mornings · mostly piano · 62 listens"). Made for You
    /// only; shown on the mix's page, and as its subtitle until the model
    /// gives it one.
    var why: String? = nil
}

/// What a habit mix is made of, for the on-device model to name it.
struct MixNamingContext: Hashable, Codable {
    /// Cache key for the name: the artist the mix grew from, not its songs,
    /// so the name stays put while the songs rotate daily.
    let key: String
    let artists: [String]
    let songs: [String]
    let albums: [String]
    let styles: [String]
    let decade: Int?
    /// "calm", "mellow", "upbeat" or "intense", when known.
    let energy: String?
}

/// Builds the mixes from the listener's own habits.
///
/// Nothing here is a fixed theme. Made for You comes from:
/// - **Personal score** of each song: every listen weighted by how recent it
///   is (half-life of about three weeks) and by how much of the song was
///   heard - a skip counts against it - plus a boost for liked songs. Songs
///   skipped early three times with no full listen in between are left out
///   for 60 days.
/// - **Affinity** of each artist: the sum of their songs' scores, plus likes,
///   plus a little weight for how much of them is in the library, so a new
///   listener with no history still gets mixes grown from their collection.
/// - **Togetherness** of artists: played in the same listening session
///   (sessions split at 30 quiet minutes), kept in the same playlist, on the
///   same album, or filed in the same folder - normalised, so the artists
///   played most do not end up beside everyone.
/// - **Likeness** of artists: shared genres, decade and energy, from tags or,
///   where there are none, the on-device model's profile of the artist.
///
/// Mixes are grown from the strongest artists outwards, then filled with the
/// listener's favourite songs by those artists and a share of ones they have
/// not played yet, and ordered to flow - building up and winding down -
/// rather than shuffled. The day seeds every choice, so a mix is stable for a
/// day and moves on the next.
struct MixEngine {
    let tracks: [Track]
    let favorites: Set<String>
    let events: [ListeningLog.Event]
    /// Each playlist's songs, as stable ids.
    let playlists: [[String]]
    let artistNames: [Int64: String]
    var albumYears: [Int64: Int] = [:]
    var albumTitles: [Int64: String] = [:]
    /// The on-device model's profiles, keyed by `ArtistProfileStore.key(for:)`.
    var profiles: [String: ArtistProfile] = [:]
    /// The app's short play history, for listeners whose log is still new.
    var recentTrackIds: [String] = []
    /// Songs Rediscover showed for several days running, resting for now.
    var rediscoverCooldown: Set<String> = []
    /// Listens that rolled off the log, per song (`ListeningLog.lifetime`).
    var lifetime: [String: ListeningLog.Lifetime] = [:]
    /// Artists learned to be skipped inside a habit mix, by mix id - kept
    /// from earlier builds (`MixLessons`), so the lesson outlives the log.
    var mixLessons: [String: Set<Int64>] = [:]
    /// The listening modes found at the last build, for song and playlist
    /// mixes made in between (`TasteModes`).
    var modes: [ListeningMode] = []
    /// How readily the listener takes to new songs, from the last build
    /// (`TasteProfile.noveltySeeking`).
    var noveltySeeking: Double? = nil
    /// The kind of output playing now ("car", "headphones"...).
    var currentRoute: String? = nil
    let now: Date

    static let minimumSize = 8
    static let mixSize = 40
    static let halfLifeDays = 21.0
    static let sessionGap: TimeInterval = 30 * 60
    static let linkShrinkage = 1.5

    static func sourceWeight(_ source: String?) -> Double {
        guard let source else { return 1 }
        if source == "shuffle" { return 0.2 }
        if source.hasPrefix("mix:") || source.hasPrefix("radio:") { return 0.5 }
        return 1
    }

    var calendar: Calendar { Calendar.current }

    /// The songs worth putting in a mix: no intros, interludes, skits or
    /// outros - under a minute or named so - and one copy of each recording,
    /// so the same song from an album and a best-of does not play twice.
    /// The copy kept is the one listened to most.
    var mixable: [Track] {
        var plays: [String: Int] = [:]
        for event in events where !event.isSkip { plays[event.id, default: 0] += 1 }
        var kept: [String: Track] = [:]
        for track in tracks {
            if let duration = track.durationMs, duration > 0, duration < 60_000 { continue }
            if Self.isFiller(track.title) { continue }
            let key = "\(track.artistId ?? -1)|\(Self.recordingKey(track.title))"
            if let existing = kept[key] {
                let better = (plays[track.stableId] ?? 0, favorites.contains(track.stableId) ? 1 : 0)
                    > (plays[existing.stableId] ?? 0, favorites.contains(existing.stableId) ? 1 : 0)
                if better { kept[key] = track }
            } else {
                kept[key] = track
            }
        }
        let keptIds = Set(kept.values.map(\.stableId))
        return tracks.filter { keptIds.contains($0.stableId) }
    }

    private static let fillerWords: Set<String> = ["intro", "interlude", "skit", "outro"]

    static func isFiller(_ title: String) -> Bool {
        let words = title.lowercased().split(whereSeparator: { !$0.isLetter })
        return words.contains { fillerWords.contains(String($0)) }
    }

    /// The title without what tells versions of one recording apart on
    /// different releases: "(Remastered 2011)", " - 2009 Remaster", "[Bonus]".
    ///
    /// Runs on every song of the library for each build, so it walks the
    /// title once instead of searching it again for each bracket.
    static func recordingKey(_ title: String) -> String {
        var text = ""
        var note = ""
        var depth = 0
        for character in title.lowercased() {
            if character == "(" || character == "[" {
                depth += 1
                if depth == 1 { note = ""; continue }
            } else if character == ")" || character == "]", depth > 0 {
                depth -= 1
                if depth == 0 {
                    // Keep "(Live)", "(Acoustic)", "(Remix)": those are other recordings.
                    if !note.contains("remaster"),
                       ["live", "acoustic", "remix", "mix", "version", "demo", "instrumental", "edit"].contains(where: note.contains) {
                        text += " " + note + " "
                    }
                    continue
                }
            }
            if depth > 0 { note.append(character) } else { text.append(character) }
        }
        if let dash = text.range(of: " - "), text[dash.upperBound...].contains("remaster") {
            text = String(text[..<dash.lowerBound])
        }
        return normalized(text)
    }

    /// `ArtistMatcher.normalized` - folded, letters and digits only, single
    /// spaces - with a fast path for plain-ASCII titles, most of a library,
    /// which skips Foundation's folding and character sets.
    static func normalized(_ text: String) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count)
        var pendingSpace = false
        for byte in text.utf8 {
            guard byte < 0x80 else { return ArtistMatcher.normalized(text) }
            let lower = (65...90).contains(byte) ? byte + 32 : byte
            if (97...122).contains(lower) || (48...57).contains(lower) {
                if pendingSpace, !bytes.isEmpty { bytes.append(32) }
                pendingSpace = false
                bytes.append(lower)
            } else {
                pendingSpace = true
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Kinds of version a title can name, from the words in its brackets
    /// or after a dash: "Song (Live at Wembley)", "Song - Acoustic".
    struct Versions: OptionSet {
        let rawValue: Int
        static let live = Versions(rawValue: 1)
        static let acoustic = Versions(rawValue: 2)
        static let remix = Versions(rawValue: 4)
        static let demo = Versions(rawValue: 8)
        static let instrumental = Versions(rawValue: 16)
    }

    /// The versions a title names, and the recording it is a version of:
    /// the title with every bracket and version note taken off, so "Song",
    /// "Song (Live)" and "Song - 2011 Remaster" all give "song".
    static func versionInfo(_ title: String) -> (recording: String, versions: Versions) {
        let lower = title.lowercased()
        var base = ""
        var notes: [String] = []
        var depth = 0
        var note = ""
        for character in lower {
            if character == "(" || character == "[" {
                depth += 1
                if depth == 1 { note = ""; continue }
            } else if character == ")" || character == "]", depth > 0 {
                depth -= 1
                if depth == 0 { notes.append(note); continue }
            }
            if depth > 0 { note.append(character) } else { base.append(character) }
        }
        var versions: Versions = []
        func flag(_ text: String) -> Bool {
            let words = Set(text.split(whereSeparator: { !$0.isLetter }).map(String.init))
            var found: Versions = []
            if words.contains("live") { found.insert(.live) }
            if words.contains("acoustic") || words.contains("unplugged") { found.insert(.acoustic) }
            // "Original Mix" is the original; "Radio Edit" is only shorter.
            if words.contains("remix") || words.contains("rmx") || words.contains("rework")
                || (words.contains("mix") && !words.contains("original")) { found.insert(.remix) }
            if words.contains("demo") { found.insert(.demo) }
            if words.contains("instrumental") || words.contains("karaoke") { found.insert(.instrumental) }
            versions.formUnion(found)
            return !found.isEmpty || words.contains("remaster") || words.contains("remastered")
        }
        notes.forEach { _ = flag($0) }
        // A dash note is cut only when it names a version: "Part 1 - The
        // Beginning" stays a different song from "Part 1 - The End".
        if let dash = base.range(of: " - "), flag(String(base[dash.upperBound...])) {
            base = String(base[..<dash.lowerBound])
        }
        let recording = normalized(base)
        return (recording.isEmpty ? recordingKey(title) : recording, versions)
    }

    /// Keeps a mix from repeating itself: never two versions of one
    /// recording, and at most one live song and one remix - a live album's
    /// worth of crowd noise in a mix sounds like a mistake.
    struct VersionGuard {
        private var recordings = Set<String>()
        private var hasLive = false
        private var hasRemix = false

        /// Whether `track` may join, and if so, notes it as in.
        mutating func admit(_ track: Track) -> Bool {
            let info = MixEngine.versionInfo(track.title)
            let key = "\(track.artistId ?? -1)|\(info.recording)"
            if recordings.contains(key) { return false }
            if info.versions.contains(.live), hasLive { return false }
            if info.versions.contains(.remix), hasRemix { return false }
            recordings.insert(key)
            if info.versions.contains(.live) { hasLive = true }
            if info.versions.contains(.remix) { hasRemix = true }
            return true
        }
    }

    /// The first `limit` songs of `tracks` that pass a `VersionGuard`.
    static func varied(_ tracks: [Track], limit: Int) -> [Track] {
        var guardian = VersionGuard()
        var result: [Track] = []
        for track in tracks where result.count < limit {
            if guardian.admit(track) { result.append(track) }
        }
        return result
    }

    var byId: [String: Track] {
        Dictionary(tracks.map { ($0.stableId, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func recencyWeight(_ date: Date) -> Double {
        let days = max(0, now.timeIntervalSince(date) / 86_400)
        return pow(0.5, days / Self.halfLifeDays)
    }

    // MARK: Listening signals

    struct Signals {
        /// 0.6 x the last few weeks (21-day half-life) + 0.4 x the long run
        /// (180-day half-life, including listens rolled off the log), so a
        /// song loved last year still counts and this week still leads.
        /// Negative for songs mostly skipped.
        var trackScore: [String: Double] = [:]
        /// Listens that were not skips, over the song's whole lifetime.
        var plays: [String: Int] = [:]
        var lastPlayed: [String: Date] = [:]
        var firstPlayed: [String: Date] = [:]
        /// The first listen the app knows of.
        var earliest: Date?
        /// Skipped early three times running - no full listen between - in
        /// the last 60 days.
        var rejected: Set<String> = []
        /// Per mix id, songs heard there for the first time: (finished at
        /// least half, skipped).
        var newSongOutcomes: [String: (finished: Int, skipped: Int)] = [:]

        /// How much of a mix should be songs not played yet, learned from
        /// how that mix's new songs were received: the mean of a Beta(2, 3)
        /// prior updated with them, so with nothing to go on it is 0.3, and
        /// it moves with each new song finished or skipped in that mix.
        func discoveryShare(for mixId: String) -> Double {
            let outcome = newSongOutcomes[mixId] ?? (0, 0)
            let estimate = 0.1 + 0.5 * Double(outcome.finished + 2) / Double(outcome.finished + outcome.skipped + 5)
            return min(estimate, 0.5)
        }
    }

    func signals() -> Signals {
        var signals = Signals()
        // Early skips since the song was last heard to the end. Skips are a
        // noisy signal - studies of skipping find most are about the moment
        // (wrong mood, already heard it today, a car arriving) rather than
        // the song - so one or two say little; three in a row with no full
        // listen between is a pattern. Older than 60 days, they expire:
        // tastes come back round.
        var skipStreak: [String: Int] = [:]
        let skipWindow = now.addingTimeInterval(-60 * 86_400)
        var short: [String: Double] = [:]
        var long: [String: Double] = [:]
        for (id, past) in lifetime {
            long[id] = past.score(at: now)
            signals.plays[id] = past.plays
            if let last = past.lastPlayed { signals.lastPlayed[id] = last }
            signals.firstPlayed[id] = past.firstPlayed
            signals.earliest = min(signals.earliest ?? past.firstPlayed, past.firstPlayed)
        }
        var seenSongs = Set<String>()
        for event in events {
            short[event.id, default: 0] += recencyWeight(event.at) * event.weight
            long[event.id, default: 0] += ListeningLog.Lifetime.fade(max(0, now.timeIntervalSince(event.at))) * event.weight
            if event.isSkip {
                if event.at >= skipWindow { skipStreak[event.id, default: 0] += 1 }
            } else {
                if (event.heard ?? 1) >= 0.8 { skipStreak[event.id] = nil }
                signals.plays[event.id, default: 0] += 1
                signals.lastPlayed[event.id] = max(signals.lastPlayed[event.id] ?? .distantPast, event.at)
            }
            if signals.firstPlayed[event.id] == nil { signals.firstPlayed[event.id] = event.at }
            signals.earliest = min(signals.earliest ?? event.at, event.at)
            // A first listen ever, inside a mix: how that mix's new songs land.
            if seenSongs.insert(event.id).inserted, lifetime[event.id] == nil,
               let source = event.source, source.hasPrefix("mix:"), let heard = event.heard {
                let mixId = String(source.dropFirst("mix:".count))
                var outcome = signals.newSongOutcomes[mixId] ?? (0, 0)
                if event.isSkip { outcome.skipped += 1 } else if heard >= 0.5 { outcome.finished += 1 }
                signals.newSongOutcomes[mixId] = outcome
            }
        }
        for (id, longScore) in long {
            signals.trackScore[id] = 0.6 * (short[id] ?? 0) + 0.4 * longScore
        }
        signals.rejected = Set(skipStreak.filter { $0.value >= 3 }.map(\.key))
        return signals
    }

    /// Artists the listener skipped early at least half the time over four
    /// or more plays inside one habit mix, by mix id. Evidence against the
    /// artist in that company, not against the artist: they stay welcome
    /// in other mixes.
    func learnedMixLessons() -> [String: Set<Int64>] {
        learnedMixLessons(byId: byId)
    }

    private func learnedMixLessons(byId: [String: Track]) -> [String: Set<Int64>] {
        var tally: [String: [Int64: (plays: Int, skips: Int)]] = [:]
        for event in events {
            guard let source = event.source, source.hasPrefix("mix:habit-") || source.hasPrefix("mix:mode-"),
                  let artistId = byId[event.id]?.artistId else { continue }
            let mixId = String(source.dropFirst("mix:".count))
            var count = tally[mixId]?[artistId] ?? (0, 0)
            count.plays += 1
            if event.isSkip { count.skips += 1 }
            tally[mixId, default: [:]][artistId] = count
        }
        var lessons: [String: Set<Int64>] = [:]
        for (mixId, artists) in tally {
            for (artistId, count) in artists where count.plays >= 4 && count.skips * 2 >= count.plays {
                lessons[mixId, default: []].insert(artistId)
            }
        }
        return lessons
    }

    // MARK: Artist traits

    /// How an artist sounds: genres (as shares summing to 1), decade,
    /// energy, dynamics (`MusicFeatures.dynamics`) and brightness
    /// (`MusicFeatures.brightness`).
    struct Traits {
        var genres: [String: Double] = [:]
        var decade: Int?
        var energy: Double?
        var dynamics: Double?
        var brightness: Double?

        /// `rarity` weighs each genre by how few artists share it, so two
        /// shoegaze artists are likelier kin than two "rock" ones.
        func likeness(to other: Traits, rarity: [String: Double]) -> Double {
            var score = 0.0
            for (genre, share) in genres {
                score += min(share, other.genres[genre] ?? 0) * 0.6 * (rarity[genre] ?? 1)
            }
            if let decade, let otherDecade = other.decade {
                score += decade == otherDecade ? 0.25 : abs(decade - otherDecade) == 10 ? 0.1 : 0
            }
            if let energy, let otherEnergy = other.energy {
                score += (1 - abs(energy - otherEnergy)) * 0.15
            }
            // A second sound axis: as fast and loud on average, a quiet
            // classical label and a brick-walled one are still not kin.
            if let dynamics, let otherDynamics = other.dynamics {
                score += (1 - abs(dynamics - otherDynamics)) * 0.1
            }
            // A third, from the audio analysis: the same energy and decade
            // with a dark, warm mix and a bright, airy one are cousins at best.
            if let brightness, let otherBrightness = other.brightness {
                score += (1 - abs(brightness - otherBrightness)) * 0.08
            }
            return score
        }
    }

    /// How much a shared genre says, by how many artists have it (inverse
    /// document frequency): about 1 for a genre a tenth of the artists
    /// share, 0.4 at least for one most share, at most 1.5 for a rare one.
    /// Small libraries keep every genre at 1 - with a dozen artists, how
    /// common a genre is says little.
    static func genreRarity(_ traits: [Int64: Traits]) -> [String: Double] {
        var artistsWith: [String: Int] = [:]
        var tagged = 0
        for traits in traits.values where !traits.genres.isEmpty {
            tagged += 1
            for genre in traits.genres.keys { artistsWith[genre, default: 0] += 1 }
        }
        guard tagged >= 20 else { return [:] }
        return artistsWith.mapValues { count in
            min(max(log(1 + Double(tagged) / Double(count)) / log(11), 0.4), 1.5)
        }
    }

    /// `MusicFeatures.normalizedGenre`, worked out once per distinct tag:
    /// a library of 50 000 songs has a few hundred genre tags at most.
    static func genre(_ raw: String?, cache: inout [String: String?]) -> String? {
        guard let raw else { return nil }
        if let known = cache[raw] { return known }
        let genre = MusicFeatures.normalizedGenre(raw)
        cache[raw] = genre
        return genre
    }

    func traits(for tracksByArtist: [Int64: [Track]]) -> [Int64: Traits] {
        var result: [Int64: Traits] = [:]
        var genreCache: [String: String?] = [:]
        for (artistId, list) in tracksByArtist {
            var traits = Traits()
            var genreCounts: [String: Double] = [:]
            var years: [Int] = []
            var energies: [Double] = []
            var dynamics: [Double] = []
            var brightness: [Double] = []
            for track in list {
                if let genre = Self.genre(track.genre, cache: &genreCache) { genreCounts[genre, default: 0] += 1 }
                if let year = MusicFeatures.year(of: track, albumYear: track.albumId.flatMap { albumYears[$0] }) { years.append(year) }
                if let energy = MusicFeatures.energy(of: track) { energies.append(energy) }
                if let value = MusicFeatures.dynamics(of: track) { dynamics.append(value) }
                if let value = MusicFeatures.brightness(of: track) { brightness.append(value) }
            }
            // Tags first; the model's profile only fills what they leave out.
            let profile = artistNames[artistId].flatMap { profiles[ArtistProfileStore.key(for: $0)] }
            if genreCounts.isEmpty, let styles = profile?.styles, !styles.isEmpty {
                for style in styles { genreCounts[style] = 1 }
            }
            let total = genreCounts.values.reduce(0, +)
            if total > 0 { traits.genres = genreCounts.mapValues { $0 / total } }
            if !years.isEmpty {
                traits.decade = years.sorted()[years.count / 2] / 10 * 10
            } else if let decade = profile?.decade, decade > 0 {
                traits.decade = decade
            }
            if !energies.isEmpty {
                traits.energy = energies.reduce(0, +) / Double(energies.count)
            } else if let energy = profile?.energy, energy > 0 {
                traits.energy = Double(energy - 1) / 4
            }
            if !dynamics.isEmpty { traits.dynamics = dynamics.reduce(0, +) / Double(dynamics.count) }
            if !brightness.isEmpty { traits.brightness = brightness.reduce(0, +) / Double(brightness.count) }
            result[artistId] = traits
        }
        return result
    }

    /// How strongly artists belong together: played in the same listening
    /// session (sessions split at 30 quiet minutes), kept in the same
    /// playlist, on the same album, or filed in the same folder.
    func artistLinks(byId: [String: Track]) -> [Int64: [Int64: Double]] {
        var together: [Int64: [Int64: Double]] = [:]
        /// Links every pair in a group. The weight is shared out among the
        /// group, so a 30-artist shuffle session does not count for more than
        /// an evening with three artists - it says less about any one pair.
        func link(_ artists: Set<Int64>, weight: Double) {
            // Sorted, so which 30 are kept does not change from run to run.
            let list = Array(artists.sorted().prefix(30))
            guard list.count > 1 else { return }
            let share = weight / Double(list.count - 1)
            for i in list.indices {
                for j in list.indices where j != i {
                    together[list[i], default: [:]][list[j], default: 0] += share
                }
            }
        }
        var sessionArtists = Set<Int64>()
        var sessionWeight = 0.0
        var lastEvent: Date?
        for event in events.sorted(by: { $0.at < $1.at }) where !event.isSkip {
            if let lastEvent, event.at.timeIntervalSince(lastEvent) > Self.sessionGap {
                link(sessionArtists, weight: sessionWeight)
                sessionArtists = []
            }
            if let artistId = byId[event.id]?.artistId {
                sessionArtists.insert(artistId)
            }
            // What the listener chose says more than what the app or a
            // shuffle put on: the app's own mixes would otherwise teach it
            // the very links they were built from.
            sessionWeight = recencyWeight(event.at) * Self.sourceWeight(event.source)
            lastEvent = event.at
        }
        link(sessionArtists, weight: sessionWeight)
        for playlist in playlists {
            link(Set(playlist.compactMap { byId[$0]?.artistId }), weight: 0.4)
        }
        // The library's own shape: artists on one album (soundtracks,
        // compilations), and artists the listener filed in one folder.
        var albumArtists: [Int64: Set<Int64>] = [:]
        var folderArtists: [String: Set<Int64>] = [:]
        for track in tracks {
            guard let artistId = track.artistId else { continue }
            if let albumId = track.albumId { albumArtists[albumId, default: []].insert(artistId) }
            // The folder above the album's: string work, four times faster
            // than building a URL for each of 50 000 songs.
            let path = track.path
            if let file = path.lastIndex(of: "/"), let album = path[..<file].lastIndex(of: "/") {
                folderArtists[String(path[..<album]), default: []].insert(artistId)
            }
        }
        for artists in albumArtists.values where artists.count > 1 {
            link(artists, weight: 0.3)
        }
        // A folder holding everything says nothing about taste.
        for artists in folderArtists.values where artists.count > 1 && artists.count <= 25 {
            link(artists, weight: 0.15)
        }
        return together
    }

    // MARK: Made for You

    func madeForYou() -> [Mix] {
        madeForYou(taste: tasteContext()).mixes
    }

    /// Made for You: first a mix for each listening mode that fits today
    /// (`TasteModes`) - when the log shows modes - then the time-of-day and
    /// context mixes they do not already cover, then mixes grown from
    /// artist clusters, eight at most. With little history there are no
    /// modes, and the artist clusters make the whole shelf.
    func madeForYou(taste: TasteContext?) -> MadeForYouResult {
        let byId = self.byId
        // Every pick below draws from the songs worth mixing.
        let tracks = mixable
        let signals = self.signals()
        let trackScore = signals.trackScore

        var tracksByArtist: [Int64: [Track]] = [:]
        for track in tracks where !signals.rejected.contains(track.stableId) {
            guard let artistId = track.artistId else { continue }
            tracksByArtist[artistId, default: []].append(track)
        }
        let traits = self.traits(for: tracksByArtist)
        let rarity = Self.genreRarity(traits)

        var affinity: [Int64: Double] = [:]
        for (artistId, list) in tracksByArtist {
            var score = 0.02 * Double(list.count)
            for track in list {
                score += trackScore[track.stableId] ?? 0
                if favorites.contains(track.stableId) { score += 1.5 }
            }
            affinity[artistId] = score
        }

        let together = artistLinks(byId: byId)
        // Normalised by each artist's total, so an artist linked to
        // everything (the one played most) is not everyone's neighbour.
        let linkTotals = together.mapValues { $0.values.reduce(0, +) }
        func closeness(_ a: Int64, _ b: Int64) -> Double {
            let shared = together[a]?[b] ?? 0
            // The 1.5 damps links seen once or twice between artists with
            // little else: one shared session should not make them twins.
            let normalised = shared > 0 ? shared / (sqrt(max(linkTotals[a] ?? 1, 0.001) * max(linkTotals[b] ?? 1, 0.001)) + Self.linkShrinkage) : 0
            let alike = traits[a].flatMap { first in traits[b].map { first.likeness(to: $0, rarity: rarity) } } ?? 0
            return normalised + alike * 0.5
        }
        // What each habit mix has taught: artists skipped inside it sit
        // further from the artist it grows from (x0.3), so at the next
        // build they usually find another mix. Keyed by the seed artist.
        var lessons: [Int64: Set<Int64>] = [:]
        var allLessons = mixLessons
        for (mixId, artists) in learnedMixLessons(byId: byId) { allLessons[mixId, default: []].formUnion(artists) }
        for (mixId, artists) in allLessons {
            if let seed = Int64(mixId.dropFirst("habit-".count)), mixId.hasPrefix("habit-") { lessons[seed] = artists }
        }
        func fit(_ a: Int64, _ b: Int64, seed: Int64) -> Double {
            let value = closeness(a, b)
            guard let skipped = lessons[seed] else { return value }
            if (a == seed && skipped.contains(b)) || (b == seed && skipped.contains(a)) { return value * 0.3 }
            return value
        }

        var mixes: [Mix] = []
        // A song goes in one mix only: six mixes sharing the same favourites
        // would feel like one mix six times.
        var used = Set<String>()
        let mixableById = Dictionary(tracks.map { ($0.stableId, $0) }, uniquingKeysWith: { first, _ in first })
        var shortlists: [String: [String]] = [:]
        // Artists leading a mode mix do not also seed an artist mix: the
        // shelf would say the same thing twice.
        var modeArtists = Set<Int64>()
        // Times and contexts a mode mix already stands for.
        var coveredParts = Set<Int>()
        var coveredContexts = Set<String>()
        if let taste, !taste.modes.isEmpty {
            var byGenre: [String: [Track]] = [:]
            for track in tracks where !signals.rejected.contains(track.stableId) {
                if let genre = taste.features[track.stableId]?.genre { byGenre[genre, default: []].append(track) }
            }
            let pool = ModePool(byId: mixableById, byArtist: tracksByArtist, byGenre: byGenre)
            let today = modesForToday(taste.modes)
            let titles = modeTitles(today)
            for mode in today where mixes.count < 4 {
                guard let built = modeMix(mode, title: titles[mode.id] ?? Localized.madeForYou, taste: taste, signals: signals,
                                          pool: pool, excluding: used, lessons: allLessons[mode.id] ?? []) else { continue }
                mixes.append(built.mix)
                used.formUnion(built.mix.trackIds)
                shortlists[mode.id] = built.shortlist
                modeArtists.formUnion(mode.topArtists.prefix(3))
                if let part = mode.dayPart {
                    if mode.weekend == true { coveredContexts.insert("weekend-\(part)") } else { coveredParts.insert(part) }
                }
                if let route = mode.route { coveredContexts.insert("route-\(route)") }
            }
        }
        if !coveredParts.contains(Self.dayPart(of: now, calendar: calendar)),
           let timeMix = timeOfDayMix(byId: mixableById, signals: signals) {
            mixes.append(timeMix)
            used.formUnion(timeMix.trackIds)
        }
        if let contextMix = contextMix(byId: mixableById, signals: signals, excluding: used, skipping: coveredContexts) {
            mixes.append(contextMix)
            used.formUnion(contextMix.trackIds)
        }
        // Songs never played that sound like the listener now. After the
        // mode and context mixes, so it takes none of their songs; before
        // the artist mixes, which then leave its songs to it.
        if let fresh = freshFindsMix(taste: taste, signals: signals,
                                     tracks: tracks.filter { !signals.rejected.contains($0.stableId) },
                                     traits: traits, excluding: used) {
            mixes.append(fresh)
            used.formUnion(fresh.trackIds)
        }
        let familiarSet = Set(trackScore.filter { $0.value > 0 }.keys).union(favorites)
        let twoDays = now.addingTimeInterval(-2 * 86_400)
        // How much each album is liked, to choose which unplayed songs to offer.
        var albumScore: [Int64: Double] = [:]
        for track in tracks {
            guard let albumId = track.albumId else { continue }
            albumScore[albumId, default: 0] += max(trackScore[track.stableId] ?? 0, 0) + (favorites.contains(track.stableId) ? 1 : 0)
        }

        // Small libraries make mixes from fewer songs.
        let minimumCandidates = tracks.count < 150 ? 8 : 12
        // Each artist's listens in the log, for the line saying why.
        var artistListens: [Int64: Int] = [:]
        for event in events where !event.isSkip {
            if let artistId = byId[event.id]?.artistId { artistListens[artistId, default: 0] += 1 }
        }

        /// A mix from a group of artists: each artist's share follows how
        /// much they are played, favourites first, about a third unplayed.
        func build(members: [Int64], seed: Int64) -> Mix? {
            let seedHash = UInt64(truncatingIfNeeded: members.sorted().reduce(0, { $0 &* 31 &+ $1 }))
            var generator = SeededGenerator(seed: Self.daySeed(now) ^ seedHash)
            let totalAffinity = members.reduce(0.0) { $0 + max(affinity[$1] ?? 0, 0.01) }

            var chosen: [Track] = []
            var perAlbum: [Int64: Int] = [:]
            var versions = VersionGuard()
            // Learned from this mix's own new songs, not from the listener
            // overall: someone may love surprises in one mix and not another.
            let discoveryShare = signals.discoveryShare(for: "habit-\(seed)")
            /// No more than three songs from one album, so a mix is not an
            /// album played out of order; one version of each recording.
            func take(_ list: [Track], upTo limit: Int) {
                var taken = 0
                for track in list where taken < limit {
                    if let albumId = track.albumId, perAlbum[albumId, default: 0] >= 3 { continue }
                    guard versions.admit(track) else { continue }
                    if let albumId = track.albumId { perAlbum[albumId, default: 0] += 1 }
                    chosen.append(track)
                    taken += 1
                }
            }
            for member in members {
                let pool = (tracksByArtist[member] ?? []).filter { !used.contains($0.stableId) }
                let share = max(4, Int(Double(Self.mixSize) * max(affinity[member] ?? 0, 0.01) / totalAffinity))
                // Favourites first - played and liked - with a little daily
                // jitter so the same handful does not lead every day, and
                // songs heard in the last two days held back a little.
                let familiar = pool.filter { familiarSet.contains($0.stableId) }.map { track -> (Track, Double) in
                    var score = trackScore[track.stableId] ?? 0
                    if favorites.contains(track.stableId) { score += 0.8 }
                    if (signals.lastPlayed[track.stableId] ?? .distantPast) > twoDays { score *= 0.3 }
                    score += Double.random(in: 0..<0.3, using: &generator)
                    return (track, score)
                }.sorted { $0.1 > $1.1 }.map(\.0)
                // New songs from the albums already loved come first.
                let fresh = pool.filter { trackScore[$0.stableId] == nil && !favorites.contains($0.stableId) }.map { track -> (Track, Double) in
                    let albumLove = track.albumId.flatMap { albumScore[$0] } ?? 0
                    return (track, min(albumLove, 5) * 0.2 + Double.random(in: 0..<0.6, using: &generator))
                }.sorted { $0.1 > $1.1 }.map(\.0)
                let discoveryCount = familiar.isEmpty ? share : max(1, Int((Double(share) * discoveryShare).rounded()))
                take(familiar, upTo: share - min(discoveryCount, fresh.count))
                take(fresh, upTo: discoveryCount)
            }
            guard chosen.count >= minimumCandidates else { return nil }

            let ordered = Self.flowOrder(Array(chosen.shuffled(using: &generator).prefix(Self.mixSize)), familiar: familiarSet, generator: &generator)
            // Spellings of one artist ("Shirō Sagisu", "Shiro Sagisu") are
            // separate artists in the library but one name to a reader.
            var seenNames = Set<String>()
            let names = members.compactMap { artistNames[$0] }.filter {
                seenNames.insert(ArtistProfileStore.key(for: $0)).inserted
            }
            let fallback: String
            if names.count >= 2 {
                fallback = String(format: Localized.mixPairFormat, names[0], names[1])
            } else {
                fallback = names.first.map { String(format: Localized.mixFormat, $0) } ?? Localized.madeForYou
            }

            // What the mix sounds like, for its subtitle and its name.
            var genreWeights: [String: Double] = [:]
            var decades: [Int: Int] = [:]
            var energies: [Double] = []
            for member in members {
                guard let memberTraits = traits[member] else { continue }
                let weight = Double(tracksByArtist[member]?.count ?? 1)
                for (genre, share) in memberTraits.genres { genreWeights[genre, default: 0] += share * weight }
                if let decade = memberTraits.decade { decades[decade, default: 0] += 1 }
                if let energy = memberTraits.energy { energies.append(energy) }
            }
            let styles = genreWeights.sorted { $0.value > $1.value }.prefix(2).map(\.key)
            let decade = decades.max { $0.value < $1.value }?.key
            let energy = energies.isEmpty ? nil : energies.reduce(0, +) / Double(energies.count)
            let why = TasteWords.artistsWhy(
                names,
                listens: members.reduce(0) { $0 + (artistListens[$1] ?? 0) },
                songs: members.reduce(0) { $0 + (tracksByArtist[$1]?.count ?? 0) }
            )

            var mix = Self.mix(
                id: "habit-\(seed)",
                title: fallback,
                subtitle: why,
                tracks: ordered,
                hue: Double(seed % 360) / 360
            )
            mix.why = why
            var albums: [String] = []
            for track in ordered {
                guard albums.count < 3, let title = track.albumId.flatMap({ albumTitles[$0] }), !albums.contains(title) else { continue }
                albums.append(title)
            }
            // Named after the artist it grew from, so the name survives the
            // neighbours changing as listening habits do.
            mix.naming = MixNamingContext(
                key: String(seed),
                artists: Array(names.prefix(4)),
                songs: ordered.prefix(8).map(\.title),
                albums: albums,
                styles: styles,
                decade: decade,
                energy: energy.map { $0 < 0.25 ? "calm" : $0 < 0.5 ? "mellow" : $0 < 0.75 ? "upbeat" : "intense" }
            )
            return mix
        }

        let ranked = affinity.sorted { $0.value > $1.value }.map(\.key)
        let habitLimit = min(8, mixes.count + 6)

        // Where a seed looks for company: artists it is linked to, and the
        // best-loved artists sharing its main genre or decade. Scoring every
        // artist against every seed is fine for 50 and far too slow for
        // 5 000; an artist with no link and neither genre nor decade in
        // common could not pass the closeness bar anyway.
        var byMainGenre: [String: [Int64]] = [:]
        var byMainDecade: [Int: [Int64]] = [:]
        for artist in ranked {
            if let genre = traits[artist]?.genres.max(by: { $0.value < $1.value })?.key, byMainGenre[genre, default: []].count < 150 {
                byMainGenre[genre, default: []].append(artist)
            }
            if let decade = traits[artist]?.decade, byMainDecade[decade, default: []].count < 100 {
                byMainDecade[decade, default: []].append(artist)
            }
        }
        func neighbourhood(of seed: Int64) -> Set<Int64> {
            var result = Set<Int64>(together[seed].map { Array($0.keys) } ?? [])
            for (genre, _) in traits[seed]?.genres ?? [:] { result.formUnion(byMainGenre[genre] ?? []) }
            if let decade = traits[seed]?.decade { result.formUnion(byMainDecade[decade] ?? []) }
            result.remove(seed)
            return result
        }

        // Grow clusters from the strongest artists - the first hundred: a
        // seed further down has too little history to lead a mix, and the
        // fallbacks below gather those artists anyway.
        var assigned = modeArtists
        for seed in ranked.prefix(100) {
            guard mixes.count < habitLimit else { break }
            guard !assigned.contains(seed) else { continue }
            // Grow the group one artist at a time, each time taking the
            // candidate that fits the whole group best - its average
            // closeness to every member, not just to the first. Growing from
            // the seed alone made star-shaped groups whose members had only
            // the seed in common.
            var members = [seed]
            var candidateCount = tracksByArtist[seed]?.count ?? 0
            var pool = neighbourhood(of: seed)
                .filter { !assigned.contains($0) && tracksByArtist[$0] != nil }
                .map { ($0, fit(seed, $0, seed: seed)) }
                .filter { $0.1 > 0.08 }
                .sorted { $0.1 > $1.1 }
                .prefix(200)
                .map(\.0)
            while members.count < 5, candidateCount < 30, !pool.isEmpty {
                let fits = pool.map { candidate in
                    (candidate, members.reduce(0.0) { $0 + fit($1, candidate, seed: seed) } / Double(members.count))
                }
                guard let best = fits.max(by: { $0.1 < $1.1 }), best.1 > 0.06 else { break }
                members.append(best.0)
                candidateCount += tracksByArtist[best.0]?.count ?? 0
                pool.removeAll { $0 == best.0 }
            }
            // Too few songs: leave these artists free to join another mix.
            guard candidateCount >= minimumCandidates, let mix = build(members: members, seed: seed) else { continue }
            assigned.formUnion(members)
            used.formUnion(mix.trackIds)
            mixes.append(mix)
        }

        // Many small artists with little history link few of them. Group the
        // rest by genre, then decade, then by how much they are played, so
        // there are still a few mixes - and ones that hang together.
        let fallbackLimit = min(habitLimit, mixes.count + 4)
        func groups(by key: (Int64) -> String?) -> [[Int64]] {
            var buckets: [String: [Int64]] = [:]
            for artist in ranked where !assigned.contains(artist) {
                if let key = key(artist) { buckets[key, default: []].append(artist) }
            }
            return buckets.values
                .filter { $0.reduce(0) { $0 + (tracksByArtist[$1]?.count ?? 0) } >= minimumCandidates }
                .sorted { ($0.first.flatMap { affinity[$0] } ?? 0) > ($1.first.flatMap { affinity[$0] } ?? 0) }
        }
        let byGenre = groups { traits[$0]?.genres.max { $0.value < $1.value }?.key }
        let byDecade = groups { traits[$0]?.decade.map { "d\($0)" } }
        for group in byGenre + byDecade {
            guard mixes.count < fallbackLimit else { break }
            let members = Array(group.filter { !assigned.contains($0) }.prefix(8))
            guard members.reduce(0, { $0 + (tracksByArtist[$1]?.count ?? 0) }) >= minimumCandidates,
                  let mix = build(members: members, seed: members[0]) else { continue }
            assigned.formUnion(members)
            used.formUnion(mix.trackIds)
            mixes.append(mix)
        }
        var group: [Int64] = []
        var groupCount = 0
        for artist in ranked where !assigned.contains(artist) {
            guard mixes.count < min(fallbackLimit, 4) else { break }
            group.append(artist)
            groupCount += tracksByArtist[artist]?.count ?? 0
            guard groupCount >= 20 || (group.count >= 6 && groupCount >= minimumCandidates) else { continue }
            if let mix = build(members: group, seed: group[0]) {
                assigned.formUnion(group)
                used.formUnion(mix.trackIds)
                mixes.append(mix)
            }
            group = []
            groupCount = 0
        }

        return MadeForYouResult(mixes: mixes, shortlists: shortlists)
    }

    // MARK: Song mix

    /// A mix grown from one song, like a radio station: the song first, then
    /// songs the listener plays in the same sittings as it, and songs that
    /// sound and belong like it - the same artist in moderation, the artists
    /// closest to them, the same genre, era and energy - leaning on what the
    /// listener likes, and ordered to flow.
    ///
    /// Two stages, the way recommenders keep both quality and speed: a cheap
    /// gathering of about 200 plausible songs from a few pools, then a
    /// careful scoring of only those, and a pick that weighs each song's fit
    /// against how much it repeats what is already in (`pickVaried`).
    ///
    /// Mode-aware once modes are known: the seed's listening mode - the one
    /// it is heard in most - pulls toward songs that sound like that mode
    /// and were heard in it, a little more when now is that mode's usual
    /// time or output; and the share of songs never played follows this
    /// listener's appetite for them.
    func songMix(seed: Track, size: Int = 30) -> [Track] {
        songMixWithSpares(seed: seed, size: size).queue
    }

    /// `songMix`, with the next 15 songs it would have picked, for the
    /// on-device model to choose among (`TasteCurator.rerank`).
    func songMixWithSpares(seed: Track, size: Int = 30) -> (queue: [Track], spares: [Track]) {
        let byId = self.byId
        // Every pick below draws from the songs worth mixing.
        let tracks = mixable
        let signals = self.signals()
        var tracksByArtist: [Int64: [Track]] = [:]
        for track in tracks {
            if let artistId = track.artistId { tracksByArtist[artistId, default: []].append(track) }
        }
        let traits = self.traits(for: tracksByArtist)
        let rarity = Self.genreRarity(traits)
        // Once per artist, not once per song.
        let mainGenre = traits.compactMapValues { $0.genres.max { $0.value < $1.value }?.key }
        let together = artistLinks(byId: byId)
        let totals = together.mapValues { $0.values.reduce(0, +) }
        let seedArtist = seed.artistId
        func artistCloseness(_ other: Int64?) -> Double {
            guard let seedArtist, let other else { return 0 }
            if other == seedArtist { return 1 }
            let shared = together[seedArtist]?[other] ?? 0
            let linked = shared > 0 ? shared / (sqrt(max(totals[seedArtist] ?? 1, 0.001) * max(totals[other] ?? 1, 0.001)) + Self.linkShrinkage) : 0
            let alike = traits[seedArtist].flatMap { first in traits[other].map { first.likeness(to: $0, rarity: rarity) } } ?? 0
            return min(linked + alike * 0.5, 1)
        }
        var genreCache: [String: String?] = [:]
        func genre(of track: Track) -> String? {
            Self.genre(track.genre, cache: &genreCache) ?? track.artistId.flatMap { mainGenre[$0] }
        }
        func year(of track: Track) -> Int? {
            MusicFeatures.year(of: track, albumYear: track.albumId.flatMap { albumYears[$0] })
        }
        func energy(of track: Track) -> Double? {
            MusicFeatures.energy(of: track) ?? track.artistId.flatMap { traits[$0]?.energy }
        }
        let seedGenre = genre(of: seed)
        let seedDynamics = MusicFeatures.dynamics(of: seed) ?? seedArtist.flatMap { traits[$0]?.dynamics }
        let seedYear = year(of: seed)
        let seedEnergy = energy(of: seed)
        func brightness(of track: Track) -> Double? {
            MusicFeatures.brightness(of: track) ?? track.artistId.flatMap { traits[$0]?.brightness }
        }
        let seedBrightness = brightness(of: seed)
        let seedMode = mode(for: seed, features: SongFeatures(artist: seedArtist, genre: seedGenre, year: seedYear, energy: seedEnergy,
                                                              dynamics: seedDynamics, brightness: seedBrightness))
        // The mode's songs count for more when now is when or where it is played.
        let modeContext = seedMode.map { mode in
            mode.dayPart == Self.dayPart(of: now, calendar: calendar) || (mode.route != nil && mode.route == currentRoute) ? 1.6 : 1
        } ?? 1
        let modeTop = seedMode?.songs.values.max() ?? 1

        let seedHash = seed.stableId.utf8.reduce(UInt64(0)) { $0 &* 31 &+ UInt64($1) }
        var generator = SeededGenerator(seed: Self.daySeed(now) ^ seedHash)
        // What the listener plays straight after the seed, and before it:
        // the strongest radio signal there is, and it costs nothing - it is
        // already in the log.
        var after: [String: Double] = [:]
        var before: [String: Double] = [:]
        let ordered = events.sorted { $0.at < $1.at }
        for (previous, next) in zip(ordered, ordered.dropFirst())
        where !previous.isSkip && !next.isSkip && next.at.timeIntervalSince(previous.at) < 20 * 60 {
            if previous.id == seed.stableId { after[next.id, default: 0] += recencyWeight(next.at) }
            if next.id == seed.stableId { before[previous.id, default: 0] += recencyWeight(previous.at) }
        }
        let neighbours = sessionNeighbours(of: seed.stableId, chronological: ordered)

        // Stage 1: gather. Each pool is cheap and capped; together they hold
        // what could belong on this station, without scoring the library.
        let pickable = Dictionary(tracks.map { ($0.stableId, $0) }, uniquingKeysWith: { first, _ in first })
        var candidates: [Track] = []
        var gathered: Set<String> = [seed.stableId]
        func gather(_ list: [Track], upTo limit: Int) {
            var taken = 0
            for track in list where taken < limit {
                guard !signals.rejected.contains(track.stableId), gathered.insert(track.stableId).inserted else { continue }
                candidates.append(track)
                taken += 1
            }
        }
        /// Best liked first, with the day's jitter, so a capped pool does not
        /// always offer the same handful.
        func liked(_ list: [Track]) -> [Track] {
            list.map { ($0, (signals.trackScore[$0.stableId] ?? 0) + (favorites.contains($0.stableId) ? 1 : 0)
                            + Double.random(in: 0..<0.5, using: &generator)) }
                .sorted { $0.1 > $1.1 }.map(\.0)
        }
        // Played in the same sittings as the seed, and right before or after it.
        gather(neighbours.sorted { $0.value > $1.value }.compactMap { pickable[$0.key] }, upTo: 80)
        let transitions = after.merging(before, uniquingKeysWith: +)
        gather(transitions.sorted { ($0.value, $0.key) > ($1.value, $1.key) }.compactMap { pickable[$0.key] }, upTo: 20)
        // The seed's artist, and the artists closest to them.
        if let seedArtist {
            gather(liked(tracksByArtist[seedArtist] ?? []), upTo: 30)
            let closest = tracksByArtist.keys
                .filter { $0 != seedArtist }
                .map { ($0, artistCloseness($0)) }
                .filter { $0.1 > 0.1 }
                .sorted { ($0.1, $0.0) > ($1.1, $1.0) }
                .prefix(10)
            for (artistId, _) in closest { gather(liked(tracksByArtist[artistId] ?? []), upTo: 6) }
        }
        // What the listener plays in the seed's mode.
        if let seedMode {
            gather(seedMode.songs.sorted { ($0.value, $0.key) > ($1.value, $1.key) }.prefix(80).compactMap { pickable[$0.key] }, upTo: 40)
        }
        // The seed's genre and era, for libraries with little history.
        if seedGenre != nil || seedYear != nil {
            let alike = tracks.filter { track in
                if let seedGenre, genre(of: track) == seedGenre { return true }
                if let seedYear, let year = year(of: track), abs(year - seedYear) <= 5 { return true }
                return false
            }
            gather(liked(alike), upTo: 60)
        }

        // Stage 2: score the gathered songs on everything known about them.
        let scored: [Candidate] = candidates.compactMap { track in
            var score = 0.0
            // How often the two share a sitting, against how often each is
            // played at all: the main signal, as in session-based
            // recommenders, where it beats far heavier models.
            score += min(neighbours[track.stableId] ?? 0, 1) * 3
            if let artistId = track.artistId { score += artistCloseness(artistId) * 2 }
            let genre = genre(of: track)
            if let seedGenre, genre == seedGenre { score += 0.8 * min(rarity[seedGenre] ?? 1, 1.2) }
            let year = year(of: track)
            if let seedYear, let year {
                let gap = abs(year - seedYear)
                score += gap <= 3 ? 0.4 : gap <= 10 ? 0.2 : 0
            }
            let energy = energy(of: track)
            if let seedEnergy, let energy { score += (1 - abs(energy - seedEnergy)) * 0.5 }
            if let seedDynamics, let dynamics = MusicFeatures.dynamics(of: track) ?? track.artistId.flatMap({ traits[$0]?.dynamics }) {
                score += (1 - abs(dynamics - seedDynamics)) * 0.3
            }
            let brightness = brightness(of: track)
            if let seedBrightness, let brightness { score += (1 - abs(brightness - seedBrightness)) * 0.25 }
            score += min(after[track.stableId] ?? 0, 2) * 0.8 + min(before[track.stableId] ?? 0, 2) * 0.4
            // Something to go on first: unrelated songs stay out.
            guard score > 0.5 else { return nil }
            if let seedMode {
                let dynamics = MusicFeatures.dynamics(of: track) ?? track.artistId.flatMap { traits[$0]?.dynamics }
                score += 0.8 * seedMode.closeness(genre: genre, year: year, energy: energy, dynamics: dynamics, brightness: brightness)
                score += 0.6 * modeContext * min((seedMode.songs[track.stableId] ?? 0) / max(modeTop, 0.001) * 3, 1)
                score -= 0.3 * Double(min(seedMode.skips[track.stableId] ?? 0, 3))
            }
            score += min(max(signals.trackScore[track.stableId] ?? 0, -1), 3) * 0.15
            if favorites.contains(track.stableId) { score += 0.3 }
            score += Double.random(in: 0..<0.35, using: &generator)
            return Candidate(track: track, relevance: score, genre: genre, year: year, energy: energy)
        }

        let start = Candidate(track: seed, relevance: 0, genre: seedGenre, year: seedYear, energy: seedEnergy)
        // Songs never played, as many as this listener tends to welcome.
        let fresh = Set(scored.map(\.track.stableId).filter { signals.plays[$0] == nil && !favorites.contains($0) })
        let share = Self.noveltyShare(noveltySeeking ?? 0.4)
        let chosen = Self.pickVaried(scored, after: start, count: size - 1 + 15,
                                     fresh: fresh, freshLimit: Int((Double(size + 15) * share).rounded()), mixLength: size - 1)
        let familiar = Set(signals.trackScore.filter { $0.value > 0 }.keys).union(favorites)
        return ([seed] + Self.flowOrder(Array(chosen.prefix(size - 1)), familiar: familiar, generator: &generator),
                Array(chosen.dropFirst(size - 1)))
    }

    /// A song up for a song mix, with what `pickVaried` compares.
    struct Candidate {
        let track: Track
        let relevance: Double
        let genre: String?
        let year: Int?
        let energy: Double?

        /// How much two songs repeat each other, 0...1: one artist or one
        /// album is a full repeat; a shared genre, era or energy a little.
        func overlap(with other: Candidate) -> Double {
            if let artist = track.artistId, artist == other.track.artistId { return 1 }
            if let album = track.albumId, album == other.track.albumId { return 1 }
            var value = 0.0
            if let genre, genre == other.genre { value += 0.3 }
            if let year, let otherYear = other.year, abs(year - otherYear) <= 3 { value += 0.1 }
            if let energy, let otherEnergy = other.energy { value += (1 - abs(energy - otherEnergy)) * 0.1 }
            return min(value, 1)
        }
    }

    /// Maximal marginal relevance (Carbonell & Goldstein): each next song is
    /// the one with the best 0.7 x fit - 0.3 x its overlap with the closest
    /// song already in. Fixed caps per artist let a strong artist fill its
    /// whole allowance with near-identical songs and kept a fifth great song
    /// by a neighbour out; this lets a song in when it is good enough to
    /// outweigh repeating something, and asks more of each repeat.
    ///
    /// Hard limits stay where repetition is never wanted: three songs from
    /// an album, one version of a recording (`VersionGuard`), and at most
    /// half the mix from the seed's artist.
    static func pickVaried(_ candidates: [Candidate], after seed: Candidate, count: Int,
                           fresh: Set<String> = [], freshLimit: Int = .max, mixLength: Int? = nil) -> [Track] {
        let lambda = 0.7
        let top = max(candidates.map(\.relevance).max() ?? 1, 0.001)
        // Overlap with the closest song in so far, the seed included.
        var overlap = candidates.map { $0.overlap(with: seed) }
        var open = Array(candidates.indices)
        var chosen: [Track] = []
        var perAlbum: [Int64: Int] = [:]
        if let album = seed.track.albumId { perAlbum[album] = 1 }
        var fromSeedArtist = 1
        // Half of the mix itself, not of the spares picked past its end.
        let seedArtistLimit = max(3, ((mixLength ?? count) + 1) / 2)
        // Not the seed again from another release or as a live take.
        var versions = VersionGuard()
        _ = versions.admit(seed.track)
        var freshCount = 0
        while chosen.count < count, !open.isEmpty {
            var bestSlot = 0
            var bestValue = -Double.infinity
            for (slot, index) in open.enumerated() {
                let value = lambda * candidates[index].relevance / top - (1 - lambda) * overlap[index]
                if value > bestValue {
                    bestValue = value
                    bestSlot = slot
                }
            }
            let picked = candidates[open.remove(at: bestSlot)]
            let track = picked.track
            let isSeedArtist = track.artistId != nil && track.artistId == seed.track.artistId
            if isSeedArtist, fromSeedArtist >= seedArtistLimit { continue }
            let isFresh = fresh.contains(track.stableId)
            if isFresh, freshCount >= freshLimit { continue }
            if let albumId = track.albumId, perAlbum[albumId, default: 0] >= 3 { continue }
            guard versions.admit(track) else { continue }
            if let albumId = track.albumId { perAlbum[albumId, default: 0] += 1 }
            if isSeedArtist { fromSeedArtist += 1 }
            if isFresh { freshCount += 1 }
            chosen.append(track)
            for index in open { overlap[index] = max(overlap[index], candidates[index].overlap(with: picked)) }
        }
        return chosen
    }

    /// How alike the seed is to each song by when they are played: session
    /// k-nearest-neighbours, which Ludewig & Jannach found matches or beats
    /// neural session recommenders. A session is a run of listens with no
    /// 30-minute pause, skips left out; a song scores by the sessions it
    /// shares with the seed, against how many sessions each is in - cosine
    /// similarity - so a song played everywhere does not top every station.
    ///
    /// Sessions count by recency (three-week half-life) and by who chose the
    /// songs: the app's own mixes and radio would otherwise teach it the
    /// very picks it made. A long session pairs everything with everything
    /// and counts for less, and a link seen in one session is halved - one
    /// evening should not make two songs twins.
    func sessionNeighbours(of seedId: String, chronological ordered: [ListeningLog.Event]) -> [String: Double] {
        var sessions: [(songs: Set<String>, weight: Double)] = []
        var sessionsOf: [String: [Int]] = [:]
        var songs = Set<String>()
        var sourceTotal = 0.0
        var listens = 0
        var last: Date?
        func close() {
            if songs.count > 1, let last, listens > 0 {
                let weight = recencyWeight(last) * (sourceTotal / Double(listens)) / max(1, (Double(songs.count) / 20).squareRoot())
                for id in songs { sessionsOf[id, default: []].append(sessions.count) }
                sessions.append((songs, weight))
            }
            songs = []
            sourceTotal = 0
            listens = 0
        }
        for event in ordered where !event.isSkip {
            if let last, event.at.timeIntervalSince(last) > Self.sessionGap { close() }
            songs.insert(event.id)
            sourceTotal += Self.sourceWeight(event.source)
            listens += 1
            last = event.at
        }
        close()

        guard let seedSessions = sessionsOf[seedId] else { return [:] }
        var seedTotal = 0.0
        var shared: [String: (weight: Double, sessions: Int)] = [:]
        for index in seedSessions {
            let session = sessions[index]
            seedTotal += session.weight
            for id in session.songs where id != seedId {
                shared[id, default: (0, 0)].weight += session.weight
                shared[id, default: (0, 0)].sessions += 1
            }
        }
        var result: [String: Double] = [:]
        for (id, together) in shared {
            let total = (sessionsOf[id] ?? []).reduce(0.0) { $0 + sessions[$1].weight }
            guard seedTotal > 0, total > 0 else { continue }
            let cosine = together.weight / (seedTotal * total).squareRoot()
            let evidence = Double(together.sessions) / Double(together.sessions + 1)
            result[id] = cosine * evidence
        }
        return result
    }

    /// What the listener plays at this time of day, once there is enough
    /// history to say.
    private func timeOfDayMix(byId: [String: Track], signals: Signals, part requested: Int? = nil) -> Mix? {
        guard events.count >= 30 else { return nil }
        let part = requested ?? Self.dayPart(of: now, calendar: calendar)
        var counts: [String: Double] = [:]
        for event in events where !event.isSkip && Self.dayPart(of: event.at, calendar: calendar) == part {
            counts[event.id, default: 0] += (0.5 + recencyWeight(event.at)) * event.weight
        }
        let ranked = counts.filter { $0.value > 0 && !signals.rejected.contains($0.key) }
            .sorted { $0.value > $1.value }.compactMap { byId[$0.key] }
        guard ranked.count >= 12 else { return nil }
        var generator = SeededGenerator(seed: Self.daySeed(now) ^ UInt64(part))
        let ordered = Self.flowOrder(Self.varied(ranked, limit: Self.mixSize).shuffled(using: &generator), generator: &generator)
        let title = [Localized.yourMornings, Localized.yourAfternoons, Localized.yourEvenings, Localized.yourNights][part]
        let listens = events.filter { !$0.isSkip && Self.dayPart(of: $0.at, calendar: calendar) == part }.count
        let why = [String(format: Localized.whyPlayFormat, TasteWords.partPhrase(part)), TasteWords.listens(listens)].joined(separator: " · ")
        var mix = Self.mix(id: "daypart-\(part)", title: title, subtitle: why,
                           tracks: ordered, hue: [0.12, 0.08, 0.72, 0.62][part])
        mix.why = why
        return mix
    }

    /// The time-of-day mix for `part` (0 morning ... 3 night), on its own -
    /// for "play something for tonight" when the shelf has none for it.
    func timeOfDayMix(part: Int) -> Mix? {
        let tracks = mixable
        return timeOfDayMix(byId: Dictionary(tracks.map { ($0.stableId, $0) }, uniquingKeysWith: { first, _ in first }),
                            signals: signals(), part: part)
    }

    /// One mix from where or when the listener plays: in the car, on
    /// headphones, weekend mornings. Only from the kind of audio output and
    /// the clock - never location - and only when at least 40 listens were
    /// made in that context, so it appears when the habit is real. A context
    /// holding most of all listening (someone always on headphones) is just
    /// their listening, not a context, and is passed over.
    ///
    /// Songs rank by how often they play there times how much more they
    /// play there than elsewhere, so the mix is what belongs to the car,
    /// not the overall favourites again.
    private func contextMix(byId: [String: Track], signals: Signals, excluding used: Set<String>, skipping covered: Set<String> = []) -> Mix? {
        var listens: [String: Int] = [:]
        var weight: [String: [String: Double]] = [:]
        var contextTotal: [String: Double] = [:]
        var overall: [String: Double] = [:]
        var overallTotal = 0.0
        var plays = 0
        for event in events where !event.isSkip {
            let value = (0.5 + recencyWeight(event.at)) * event.weight
            overall[event.id, default: 0] += value
            overallTotal += value
            plays += 1
            var contexts: [String] = []
            if let route = event.route { contexts.append("route-\(route)") }
            if calendar.isDateInWeekend(event.at) { contexts.append("weekend-\(Self.dayPart(of: event.at, calendar: calendar))") }
            for context in contexts {
                listens[context, default: 0] += 1
                weight[context, default: [:]][event.id, default: 0] += value
                contextTotal[context, default: 0] += value
            }
        }
        let eligible = listens.filter { $0.value >= 40 && Double($0.value) <= Double(plays) * 0.7 && !covered.contains($0.key) }.keys.sorted()
        guard !eligible.isEmpty, overallTotal > 0 else { return nil }
        // One a day, taking turns when several contexts qualify.
        let start = Int(Self.daySeed(now) % UInt64(eligible.count))
        for offset in eligible.indices {
            let context = eligible[(start + offset) % eligible.count]
            guard let title = Self.contextTitle(context), let songs = weight[context],
                  let total = contextTotal[context], total > 0 else { continue }
            let ranked = songs.compactMap { id, value -> (Track, Double)? in
                guard !used.contains(id), !signals.rejected.contains(id), let track = byId[id] else { return nil }
                let lift = (value / total) / max((overall[id] ?? value) / overallTotal, 0.000_001)
                return (track, value * min(lift, 4))
            }.sorted { $0.1 > $1.1 }.map(\.0)
            guard ranked.count >= 12 else { continue }
            let hash = context.utf8.reduce(UInt64(0)) { $0 &* 31 &+ UInt64($1) }
            var generator = SeededGenerator(seed: Self.daySeed(now) ^ hash)
            let ordered = Self.flowOrder(Self.varied(ranked, limit: Self.mixSize).shuffled(using: &generator),
                                         familiar: Set(ranked.map(\.stableId)), generator: &generator)
            // "What you play in the car · 140 listens", from the context's own parts.
            let route = context.hasPrefix("route-") ? String(context.dropFirst("route-".count)) : nil
            let part = context.hasPrefix("weekend-") ? Int(context.dropFirst("weekend-".count)) : nil
            let phrase = TasteWords.contextPhrase(dayPart: part, weekend: part == nil ? nil : true, route: route)
            let why = [phrase.map { String(format: Localized.whyPlayFormat, $0) }, TasteWords.listens(listens[context] ?? 0)]
                .compactMap { $0 }.joined(separator: " · ")
            var mix = Self.mix(id: "context-\(context)", title: title, subtitle: why,
                               tracks: ordered, hue: Double(hash % 360) / 360)
            mix.why = why
            return mix
        }
        return nil
    }

    static func contextTitle(_ context: String) -> String? {
        switch context {
        case "route-car": return Localized.inTheCar
        case "route-headphones": return Localized.onHeadphones
        case "route-bluetooth": return Localized.bluetoothSessions
        case "route-speaker": return Localized.outLoud
        case "route-airplay": return Localized.onAirPlay
        case "weekend-0": return Localized.weekendMornings
        case "weekend-1": return Localized.weekendAfternoons
        case "weekend-2": return Localized.weekendEvenings
        case "weekend-3": return Localized.weekendNights
        default: return nil
        }
    }

    static func dayPart(of date: Date, calendar: Calendar) -> Int {
        switch calendar.component(.hour, from: date) {
        case 5..<12: return 0
        case 12..<18: return 1
        case 18..<23: return 2
        default: return 3
        }
    }

    // MARK: Rediscover

    /// Rediscover: what you played lately, then a daily handful from a pool
    /// of ways back into the library - favourites you drifted from, artists
    /// you have not heard in a while, albums you started, unplayed songs by
    /// artists you love, the first songs you played here, past years and
    /// decades. Songs shown several days running rest for two weeks, and
    /// songs played this week are left out: rediscovering means not lately.
    ///
    /// With a taste profile, the pool also holds a listening mode set aside
    /// for weeks, songs that fell out of a mode still played, and artists
    /// played on repeat and then dropped (`tasteRediscoveries`).
    func rediscover(excluding madeForYou: Set<String> = [], taste: TasteContext? = nil) -> [Mix] {
        let byId = self.byId
        // Every pick below draws from the songs worth mixing.
        let tracks = mixable
        let signals = self.signals()
        var generator = SeededGenerator(seed: Self.daySeed(now) &+ 7)
        let week = now.addingTimeInterval(-7 * 86_400)
        let drift = now.addingTimeInterval(-45 * 86_400)
        let available = tracks.filter {
            !signals.rejected.contains($0.stableId)
                && !madeForYou.contains($0.stableId)
                && !rediscoverCooldown.contains($0.stableId)
                && (signals.lastPlayed[$0.stableId] ?? .distantPast) < week
        }
        // Looked up per song below; an array search there was quadratic.
        let availableIds = Set(available.map(\.stableId))

        var lately: Mix?
        var pool: [Mix] = []

        // Lately: the last two weeks, newest first.
        let twoWeeks = now.addingTimeInterval(-14 * 86_400)
        var recent: [Track] = []
        var seen = Set<String>()
        for event in events.reversed() where event.at >= twoWeeks && !event.isSkip {
            if let track = byId[event.id], seen.insert(track.stableId).inserted { recent.append(track) }
        }
        if recent.count < Self.minimumSize {
            for id in recentTrackIds {
                if let track = byId[id], seen.insert(track.stableId).inserted { recent.append(track) }
            }
        }
        if recent.count >= Self.minimumSize {
            lately = Self.mix(id: "recent", title: Localized.youRecentlyPlayed, subtitle: Localized.mixHabitDescription,
                              tracks: Array(recent.prefix(Self.mixSize)), hue: 0.55)
        }

        func add(_ id: String, _ title: String, _ subtitle: String, _ list: [Track], hue: Double, minimum: Int = 10, keepOrder: Bool = false) {
            guard list.count >= minimum else { return }
            let picked = Self.varied(keepOrder ? list : list.shuffled(using: &generator), limit: Self.mixSize)
            pool.append(Self.mix(id: id, title: title, subtitle: subtitle, tracks: Self.flowOrder(picked, generator: &generator), hue: hue))
        }

        let memory = self.memory()

        // Forgotten Favorites: songs once strong in memory and faded since -
        // ranked by how much they faded (`Memory`) - and liked songs not
        // played in a while.
        let forgotten = available.compactMap { track -> (Track, Double)? in
            let plays = signals.plays[track.stableId] ?? 0
            let last = signals.lastPlayed[track.stableId]
            let faded = memory[track.stableId]?.faded ?? 0
            if plays >= 3, let last, last < drift {
                return (track, faded + (favorites.contains(track.stableId) ? 1 : 0))
            }
            if favorites.contains(track.stableId), (last ?? .distantPast) < drift {
                return (track, faded + 1)
            }
            return nil
        }.sorted { $0.1 > $1.1 }.map(\.0)
        add("forgotten", Localized.forgottenFavorites, Localized.forgottenFavoritesDescription, Array(forgotten.prefix(80)), hue: 0.95, minimum: Self.minimumSize)

        // Long Time No Hear: artists you played a lot, none of them for 90
        // days, the most faded first. An artist's memory is the sum of its
        // songs': each song's peak came at its own time, so the sum
        // overstates the artist's true peak, but it ranks the same way -
        // most played, and most densely.
        var artistPlays: [Int64: Int] = [:]
        var artistLast: [Int64: Date] = [:]
        var artistFaded: [Int64: Double] = [:]
        for (id, count) in signals.plays {
            guard let artistId = byId[id]?.artistId else { continue }
            artistPlays[artistId, default: 0] += count
            artistLast[artistId] = max(artistLast[artistId] ?? .distantPast, signals.lastPlayed[id] ?? .distantPast)
            artistFaded[artistId, default: 0] += memory[id]?.faded ?? 0
        }
        let quarter = now.addingTimeInterval(-90 * 86_400)
        let quietArtists = artistPlays.filter { $0.value >= 5 && (artistLast[$0.key] ?? .distantPast) < quarter }
            .keys.sorted { (artistFaded[$0] ?? 0, $0) > (artistFaded[$1] ?? 0, $1) }
        var quietSongs: [Int64: [Track]] = [:]
        let quietSet = Set(quietArtists)
        for track in available { if let artistId = track.artistId, quietSet.contains(artistId) { quietSongs[artistId, default: []].append(track) } }
        // A few songs from each, most faded artists first: the strongest
        // memories lead, and one big artist does not fill the mix.
        var longTime: [Track] = []
        for artistId in quietArtists where longTime.count < 80 {
            let songs = (quietSongs[artistId] ?? []).map { track in
                (track, (memory[track.stableId]?.faded ?? 0) + Double.random(in: 0..<0.3, using: &generator))
            }.sorted { $0.1 > $1.1 }.map(\.0)
            longTime += songs.prefix(5)
        }
        add("long-time", Localized.longTimeNoHear, Localized.longTimeNoHearDescription, longTime, hue: 0.42)

        // Unfinished Albums: albums of eight or more songs where you have
        // played only a few - the rest of them.
        var albumSongs: [Int64: [Track]] = [:]
        for track in tracks { if let albumId = track.albumId { albumSongs[albumId, default: []].append(track) } }
        var unfinished: [Track] = []
        for (_, songs) in albumSongs where songs.count >= 8 {
            let played = songs.filter { (signals.plays[$0.stableId] ?? 0) > 0 }.count
            guard (1...3).contains(played) else { continue }
            unfinished += songs.filter { (signals.plays[$0.stableId] ?? 0) == 0 && availableIds.contains($0.stableId) }
        }
        add("unfinished", Localized.unfinishedAlbums, Localized.unfinishedAlbumsDescription, unfinished, hue: 0.33)

        // Deep Cuts: never played, by your ten most-played artists.
        let topArtists = Set(artistPlays.sorted { $0.value > $1.value }.prefix(10).map(\.key))
        add("deep-cuts", Localized.deepCuts, Localized.deepCutsDescription,
            available.filter { signals.plays[$0.stableId] == nil && ($0.artistId.map(topArtists.contains) ?? false) }, hue: 0.78)

        // First Loves: the first songs you played here, once the app has
        // known you half a year - from the lifetime record, so they are
        // still known after their listens rolled off the log.
        if let first = signals.earliest, now.timeIntervalSince(first) > 180 * 86_400 {
            let earliest = signals.firstPlayed.sorted { $0.value < $1.value }.prefix(60).compactMap { byId[$0.key] }
            add("first-loves", Localized.firstLoves, Localized.firstLovesDescription,
                earliest.filter { availableIds.contains($0.stableId) }, hue: 0.02, keepOrder: false)
        }

        // A past year: what you played then - from the log - and what arrived
        // then, unless that year is a bulk copy of the library (file dates
        // reset when files are copied, so one year holding a third of the
        // library says nothing). One year a week, in turn.
        let thisYear = calendar.component(.year, from: now)
        var byYear: [Int: Set<String>] = [:]
        for (id, date) in signals.lastPlayed {
            let year = calendar.component(.year, from: date)
            if year < thisYear { byYear[year, default: []].insert(id) }
        }
        var arrivals: [Int: [String]] = [:]
        for track in tracks {
            guard let date = Self.arrival(of: track) else { continue }
            arrivals[calendar.component(.year, from: date), default: []].append(track.stableId)
        }
        for (year, ids) in arrivals where year < thisYear && Double(ids.count) <= Double(tracks.count) * 0.35 {
            byYear[year, default: []].formUnion(ids)
        }
        let years = byYear.filter { $0.value.count >= 10 }.keys.sorted()
        if !years.isEmpty {
            let year = years[Int(Self.daySeed(now) / 7) % years.count]
            add("year-\(year)", String(format: Localized.rediscoverYearFormat, String(year)), Localized.mixHabitDescription,
                available.filter { byYear[year]?.contains($0.stableId) ?? false }, hue: Double(year % 12) / 12)
        }

        // A decade of the library, from year tags, one a week in turn.
        var byDecade: [Int: [Track]] = [:]
        for track in available {
            if let year = MusicFeatures.year(of: track, albumYear: track.albumId.flatMap { albumYears[$0] }) {
                byDecade[year / 10 * 10, default: []].append(track)
            }
        }
        let decades = byDecade.filter { $0.value.count >= 15 }.keys.sorted()
        if decades.count >= 2 {
            let decade = decades[Int(Self.daySeed(now) / 7 + 3) % decades.count]
            add("decade-\(decade)", String(format: Localized.decadeMixFormat, Self.decadeLabel(decade)), Localized.decadeMixDescription,
                byDecade[decade] ?? [], hue: Double(decade % 100) / 100)
        }

        // Old Gems: the oldest quarter of the library - only when arrival
        // dates mean something.
        let dated = tracks.compactMap { track in Self.arrival(of: track).map { (track, $0) } }
        let largestYear = arrivals.values.map(\.count).max() ?? 0
        if dated.count > tracks.count / 2, Double(largestYear) <= Double(tracks.count) * 0.35 {
            let oldest = Set(dated.sorted { $0.1 < $1.1 }.prefix(max(Self.minimumSize, dated.count / 4)).map(\.0.stableId))
            add("old-gems", Localized.oldGems, Localized.oldGemsDescription, available.filter { oldest.contains($0.stableId) }, hue: 0.1)
        }

        if let taste {
            for entry in tasteRediscoveries(taste: taste, available: available, memory: memory, signals: signals, byId: byId) {
                add(entry.id, entry.title, entry.subtitle, entry.tracks, hue: entry.hue)
            }
        }

        // The strongest four of the pool today: fuller mixes rank higher, and
        // mixes of songs that faded most from memory (ACT-R), with the day's
        // jitter so the pool takes turns.
        func faded(_ mix: Mix) -> Double {
            guard !mix.trackIds.isEmpty else { return 0 }
            let average = mix.trackIds.reduce(0.0) { $0 + (memory[$1]?.faded ?? 0) } / Double(mix.trackIds.count)
            return 0.5 * average / (average + 1)
        }
        let today = pool.map { mix -> (Mix, Double) in
            (mix, Double(min(mix.trackIds.count, Self.mixSize)) / Double(Self.mixSize) + faded(mix)
                + Double.random(in: 0..<0.6, using: &generator))
        }.sorted { $0.1 > $1.1 }.prefix(4).map(\.0)
        return (lately.map { [$0] } ?? []) + today
    }

    /// How strongly each played song sits in the listener's memory, after
    /// the ACT-R model of memory that Reiter-Haas et al. (2021) found
    /// predicts which songs people go back to: every listen adds to a
    /// song's activation and fades as a power of the time since,
    /// ln(sum of t^-0.5) - the more listens, and the more recent, the
    /// stronger. Times are in days plus one, so a listen this hour is not
    /// infinitely strong.
    struct Memory {
        /// The highest the song stood, just after one of its listens.
        var peak = 0.0
        /// Where it stands today.
        var current = 0.0

        /// How much has faded, in strength (e^activation) rather than
        /// activation: in log units, ten plays and one play forgotten for
        /// the same time would tie, since the counts cancel out.
        var faded: Double { max(peak - current, 0) }
    }

    private static let memoryDecay = 0.5

    /// `Memory` for every song played, from its listens in the log and,
    /// for listens that rolled off, its lifetime record - spread evenly
    /// between its first and last play, which is all that is kept of them.
    func memory() -> [String: Memory] {
        var listens: [String: [(at: Date, count: Double)]] = [:]
        for (id, past) in lifetime where past.plays > 0 {
            let last = past.lastPlayed ?? past.firstPlayed
            let samples = min(past.plays, 20)
            let span = last.timeIntervalSince(past.firstPlayed)
            for sample in 0..<samples {
                let offset = samples > 1 ? span * Double(sample) / Double(samples - 1) : 0
                listens[id, default: []].append((past.firstPlayed.addingTimeInterval(offset), Double(past.plays) / Double(samples)))
            }
        }
        for event in events where !event.isSkip { listens[event.id, default: []].append((event.at, 1)) }

        func strength(of list: ArraySlice<(at: Date, count: Double)>, at date: Date) -> Double {
            list.reduce(0.0) { total, listen in
                total + listen.count * pow(max(date.timeIntervalSince(listen.at), 0) / 86_400 + 1, -Self.memoryDecay)
            }
        }
        var result: [String: Memory] = [:]
        for (id, unsorted) in listens {
            let list = unsorted.sorted { $0.at < $1.at }
            var memory = Memory()
            memory.current = strength(of: list[...], at: now)
            // The peak comes just after a listen; checking at most 40 of them,
            // spread out, keeps a song played 500 times cheap.
            let step = max(1, list.count / 40)
            for index in stride(from: list.count - 1, through: 0, by: -step) {
                memory.peak = max(memory.peak, strength(of: list[...index], at: list[index].at))
            }
            result[id] = memory
        }
        return result
    }

    // MARK: Building

    /// "1990s", or the localised form of it.
    static func decadeLabel(_ decade: Int) -> String {
        String(format: Localized.decadeLabelFormat, String(decade))
    }

    private static func arrival(of track: Track) -> Date? {
        guard let micros = track.modificationDate, micros > 946_684_800_000_000 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(micros) / 1_000_000)
    }

    static func mix(id: String, title: String, subtitle: String, tracks: [Track], hue: Double) -> Mix {
        var coverIds: [String] = []
        var coverAlbums = Set<Int64>()
        for track in tracks where track.hasArtwork && coverIds.count < 4 {
            // Four different albums make a better collage than one album four times.
            if let albumId = track.albumId, !coverAlbums.insert(albumId).inserted { continue }
            coverIds.append(track.stableId)
        }
        return Mix(
            id: id,
            title: title,
            subtitle: subtitle,
            trackIds: tracks.map(\.stableId),
            coverTrackIds: coverIds.isEmpty ? Array(tracks.prefix(4).map(\.stableId)) : coverIds,
            hue: hue
        )
    }

    /// Orders a mix to flow: it opens moderately, builds to a peak about
    /// two-thirds in and winds down, each song chosen to sit close to the
    /// last in energy and dynamics, and the same artist kept three songs
    /// apart. Where too few songs have tempo or loudness to go on, the
    /// shuffle is kept and only the artists are spread.
    ///
    /// Built in two passes: a greedy one that picks, song by song, the best
    /// next song - quick, but it paints itself into a corner near the end,
    /// where only the leftovers remain - then a short local search
    /// (`improveFlow`) that reverses stretches of the order wherever that
    /// lowers the cost of the whole mix.
    static func flowOrder(_ tracks: [Track], familiar: Set<String> = [], generator: inout SeededGenerator) -> [Track] {
        let energies = tracks.map(MusicFeatures.energy)
        // Without tempo or loudness for most songs there is no arc to draw;
        // the familiar/new pattern and the artist spacing still apply.
        let hasEnergy = energies.compactMap({ $0 }).count * 2 >= tracks.count
        let dynamics = tracks.map(MusicFeatures.dynamics)
        let hasDynamics = dynamics.contains { $0 != nil }
        let brightness = tracks.map(MusicFeatures.brightness)
        let hasBrightness = brightness.contains { $0 != nil }
        guard tracks.count > 3, hasEnergy || hasDynamics || hasBrightness || !familiar.isEmpty else {
            return spreadArtists(tracks, generator: &generator)
        }
        let known = energies.compactMap { $0 }
        let average = hasEnergy ? known.reduce(0, +) / Double(known.count) : 0.5
        let features = FlowFeatures(
            energy: energies.map { hasEnergy ? ($0 ?? average) : 0.5 },
            dynamics: dynamics,
            brightness: brightness,
            artist: tracks.map(\.artistId),
            isNew: familiar.isEmpty ? nil : tracks.map { !familiar.contains($0.stableId) },
            followsArc: hasEnergy
        )
        let count = tracks.count
        var remaining = Array(tracks.indices)
        var order: [Int] = []
        order.reserveCapacity(count)
        while !remaining.isEmpty {
            let target = features.target(at: order.count, of: count)
            var bestIndex = 0
            var bestCost = Double.infinity
            for (index, candidate) in remaining.enumerated() {
                let cost = features.step(candidate, at: order.count, after: order, target: target)
                    + Double.random(in: 0..<0.08, using: &generator)
                if cost < bestCost {
                    bestCost = cost
                    bestIndex = index
                }
            }
            order.append(remaining.remove(at: bestIndex))
        }
        improveFlow(&order, features: features)
        return order.map { tracks[$0] }
    }

    /// What `flowOrder` judges an order by, one entry per song.
    struct FlowFeatures {
        let energy: [Double]
        let dynamics: [Double?]
        let brightness: [Double?]
        let artist: [Int64?]
        /// Per song, whether the listener has not played it yet; nil when
        /// that is not known, and the familiar/new pattern does not apply.
        let isNew: [Bool]?
        let followsArc: Bool

        /// A gentle arc: 0.35 at the start, 0.8 at two-thirds, 0.45 at the end.
        func target(at position: Int, of count: Int) -> Double {
            guard followsArc else { return 0.5 }
            let x = Double(position) / Double(max(count - 1, 1))
            return x < 0.66 ? 0.35 + 0.45 * (x / 0.66) : 0.8 - 0.35 * ((x - 0.66) / 0.34)
        }

        /// The cost of playing song `song` at `position`, after `order[..<position]`.
        func step(_ song: Int, at position: Int, after order: [Int], target: Double) -> Double {
            var cost = abs(energy[song] - target)
            if position > 0 {
                let previous = order[position - 1]
                cost += abs(energy[song] - energy[previous]) * 0.5
                // From a quiet, wide-open recording straight into a
                // brick-walled one is a jolt even at the same tempo.
                if let last = dynamics[previous], let next = dynamics[song] { cost += abs(next - last) * 0.4 }
                // So is a dark, warm mix straight into a bright, thin one.
                if let last = brightness[previous], let next = brightness[song] { cost += abs(next - last) * 0.3 }
            }
            // Open on a song the listener knows, and set new songs between
            // familiar ones rather than in a run.
            if let isNew, isNew[song] {
                cost += position == 0 ? 1 : isNew[order[position - 1]] ? 0.4 : 0
            }
            if let id = artist[song] {
                for back in 1...3 where position - back >= 0 && artist[order[position - back]] == id {
                    cost += 1
                    break
                }
            }
            return cost
        }

        /// The whole order's cost: the sum of its steps.
        func cost(_ order: [Int]) -> Double {
            var total = 0.0
            for position in order.indices {
                total += step(order[position], at: position, after: order, target: target(at: position, of: order.count))
            }
            return total
        }
    }

    /// 2-opt local search: reverse a stretch of the order whenever that makes
    /// the whole mix cost less, until no reversal helps. Reversing keeps the
    /// songs inside the stretch next to the same neighbours, so it repairs
    /// the greedy pass's bad joins without breaking its good ones. The first
    /// song stays first - it was chosen to open the mix, and a song mix's
    /// seed is placed before it. Each try re-costs the whole order, so the
    /// tries are capped by the work they take: about 3 000 for 40 songs, a
    /// few milliseconds; a long list gets proportionally fewer.
    static func improveFlow(_ order: inout [Int], features: FlowFeatures) {
        let count = order.count
        guard count > 3 else { return }
        var budget = 120_000 / count
        var best = features.cost(order)
        var improved = true
        search: while improved {
            improved = false
            for start in 1..<(count - 1) {
                for end in (start + 1)..<count {
                    guard budget > 0 else { break search }
                    budget -= 1
                    order[start...end].reverse()
                    let cost = features.cost(order)
                    if cost < best - 1e-9 {
                        best = cost
                        improved = true
                    } else {
                        order[start...end].reverse()
                    }
                }
            }
        }
    }

    /// Reorders so the same artist does not play twice in a row whenever
    /// that can be avoided, keeping each artist's songs in the order given.
    static func spreadArtists(_ tracks: [Track]) -> [Track] {
        // Seeded from the songs, so the same list spreads the same way.
        let seed = tracks.reduce(UInt64(tracks.count)) { hash, track in
            track.stableId.utf8.reduce(hash) { $0 &* 31 &+ UInt64($1) }
        }
        var generator = SeededGenerator(seed: seed)
        return mergeShuffle(tracks.map(\.artistId), generator: &generator, shuffleWithin: false).map { tracks[$0] }
    }

    /// `spreadArtists`, with each artist's songs shuffled too: a shuffle
    /// that never plays one artist twice in a row when it can be avoided.
    static func spreadArtists(_ tracks: [Track], generator: inout SeededGenerator) -> [Track] {
        mergeShuffle(tracks.map(\.artistId), generator: &generator, shuffleWithin: true).map { tracks[$0] }
    }

    /// Ruud van Asseldonk's merge-shuffle ("An algorithm for shuffling
    /// playlists", 2023), as indices into `artists`. Taking whichever next
    /// song has another artist - the obvious greedy way - leaves the biggest
    /// artist's songs bunched at the end; this places one artist apart from
    /// the next only where it is impossible not to, and spreads each
    /// artist's songs evenly across the list.
    ///
    /// Each artist's songs form a group (a song with no artist is a group of
    /// its own). The groups are merged into the result one at a time,
    /// smallest first, so the largest goes in last, when there is the most
    /// to space it with. A group at least as long as the result so far is
    /// cut into one more part than the result has songs, and the result's
    /// songs go between the parts; a shorter group's songs go between runs
    /// of the result - first at every place where one artist plays twice,
    /// then at random places until each of its songs has one.
    static func mergeShuffle(_ artists: [Int64?], generator: inout SeededGenerator, shuffleWithin: Bool = true) -> [Int] {
        var byArtist: [Int64: [Int]] = [:]
        var groups: [[Int]] = []
        for (index, artist) in artists.enumerated() {
            if let artist { byArtist[artist, default: []].append(index) } else { groups.append([index]) }
        }
        // Sorted, so the same input always merges in the same order.
        groups += byArtist.keys.sorted().map { byArtist[$0]! }
        if shuffleWithin {
            groups = groups.map { $0.shuffled(using: &generator) }
        }
        // Smallest first; ties broken at random.
        groups = groups.map { ($0, UInt64.random(in: 0...UInt64.max, using: &generator)) }
            .sorted { ($0.0.count, $0.1) < ($1.0.count, $1.1) }
            .map(\.0)

        var result: [Int] = []
        for group in groups {
            if group.count >= result.count {
                result = interleave(group, between: result, generator: &generator)
            } else {
                result = intersperse(group, into: result, artists: artists, generator: &generator)
            }
        }
        return result
    }

    /// `longer` cut into `shorter.count + 1` near-equal parts - the parts
    /// one song longer chosen at random - with `shorter`'s songs between
    /// them. Of equal length, the two simply alternate, a coin deciding
    /// which goes first.
    private static func interleave(_ longer: [Int], between shorter: [Int], generator: inout SeededGenerator) -> [Int] {
        if longer.count == shorter.count {
            let (first, second) = Bool.random(using: &generator) ? (longer, shorter) : (shorter, longer)
            return zip(first, second).flatMap { [$0, $1] }
        }
        let parts = shorter.count + 1
        var sizes = Array(repeating: longer.count / parts, count: parts)
        for part in Array(0..<parts).shuffled(using: &generator).prefix(longer.count % parts) { sizes[part] += 1 }
        var result: [Int] = []
        result.reserveCapacity(longer.count + shorter.count)
        var next = 0
        for (part, size) in sizes.enumerated() {
            result += longer[next..<(next + size)]
            next += size
            if part < shorter.count { result.append(shorter[part]) }
        }
        return result
    }

    /// `group`'s songs set between runs of `result`: cut first where one
    /// artist plays twice in a row, then at random until there is a gap for
    /// each song. `group` is one artist that is not in `result` yet, so
    /// every cut it fills is a repeat mended or two other artists parted.
    private static func intersperse(_ group: [Int], into result: [Int], artists: [Int64?], generator: inout SeededGenerator) -> [Int] {
        // A cut before position i splits result[i - 1] from result[i].
        var cuts = Set<Int>()
        for i in 1..<result.count where artists[result[i]] != nil && artists[result[i]] == artists[result[i - 1]] {
            cuts.insert(i)
        }
        let free = Array((1..<result.count).filter { !cuts.contains($0) }).shuffled(using: &generator)
        for i in free where cuts.count < group.count { cuts.insert(i) }
        // The proof says there are never more repeats than songs to mend them
        // with; should one remain, it stays rather than a song being lost.
        let chosen = cuts.sorted().prefix(group.count)
        var merged: [Int] = []
        merged.reserveCapacity(result.count + group.count)
        var start = 0
        // `group.count + 1` runs need `group.count` cuts, one song in each;
        // `result` is longer than `group`, so there is always room for them.
        var songs = group[...]
        for cut in chosen {
            merged += result[start..<cut]
            merged.append(songs.removeFirst())
            start = cut
        }
        merged += result[start...]
        merged += songs
        return merged
    }

    static func daySeed(_ date: Date) -> UInt64 {
        UInt64(max(0, date.timeIntervalSince1970) / 86_400)
    }
}

/// Songs Rediscover has shown three days running rest for two weeks, so it
/// does not offer the same handful every morning.
@MainActor
enum RediscoverCooldown {
    static let storageKey = "cosmos.rediscoverShown"
    private static let streakDays = 3
    private static let restDays = 14

    /// [stable id: [first day of the current run, last day shown]]
    private static var shown: [String: [Int]] {
        get { (UserDefaults.standard.dictionary(forKey: storageKey) as? [String: [Int]]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: storageKey) }
    }

    private static var today: Int { Int(MixEngine.daySeed(Date())) }

    static func resting() -> Set<String> {
        let today = self.today
        return Set(shown.compactMap { id, run in
            guard run.count == 2 else { return nil }
            let length = run[1] - run[0] + 1
            return length >= streakDays && today <= run[1] + restDays && today > run[1] ? id : nil
        })
    }

    static func record(_ mixes: [Mix]) {
        let today = self.today
        var shown = self.shown
        for id in Set(mixes.filter { $0.id != "recent" }.flatMap(\.trackIds)) {
            if let run = shown[id], run.count == 2, today - run[1] <= 1 {
                shown[id] = [run[0], today]
            } else {
                shown[id] = [today, today]
            }
        }
        // Forget runs long over.
        shown = shown.filter { today - ($0.value.last ?? today) <= restDays + 1 }
        self.shown = shown
    }
}

/// What each habit mix has learned about artists skipped inside it, kept
/// past the listens that taught it: a lesson lasts 90 days from the last
/// time the log confirmed it, then the artist gets another chance. Cleared
/// with the listening log.
@MainActor
enum MixLessons {
    static let storageKey = "cosmos.mixLessons"
    private static let keepDays = 90

    /// [mix id: [artist id: day last confirmed]]
    private static var stored: [String: [String: Int]] {
        get { (UserDefaults.standard.dictionary(forKey: storageKey) as? [String: [String: Int]]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: storageKey) }
    }

    private static var today: Int { Int(MixEngine.daySeed(Date())) }

    static func current() -> [String: Set<Int64>] {
        let today = self.today
        return stored.compactMapValues { artists in
            let kept = Set(artists.filter { today - $0.value <= keepDays }.keys.compactMap { Int64($0) })
            return kept.isEmpty ? nil : kept
        }
    }

    static func remember(_ learned: [String: Set<Int64>]) {
        let today = self.today
        var stored = self.stored
        for (mixId, artists) in learned {
            for artist in artists { stored[mixId, default: [:]][String(artist)] = today }
        }
        stored = stored.compactMapValues { artists in
            let kept = artists.filter { today - $0.value <= keepDays }
            return kept.isEmpty ? nil : kept
        }
        self.stored = stored
    }
}

/// Names habit mixes with the on-device model, once per seed artist.
@MainActor
enum MixNamer {
    private static let cacheKey = "cosmos.mixNames.v3"
    /// Title and subtitle share one cache entry.
    private static let separator = "\u{1F}"

    static func cached(for key: String) -> (title: String, subtitle: String?)? {
        guard let entry = (UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String])?[languageScoped(key)] else {
            return nil
        }
        let parts = entry.components(separatedBy: separator)
        return (capitalized(parts[0]), parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil)
    }

    /// The model sometimes answers all in lower case; a title should not be.
    /// English gets title case, other languages a capital first letter.
    static func capitalized(_ name: String) -> String {
        guard name == name.lowercased() else { return name }
        if Locale.current.language.languageCode?.identifier == "en" {
            return name.capitalized(with: Locale.current)
        }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    static func store(title: String, subtitle: String?, for key: String) {
        var cache = (UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String]) ?? [:]
        cache[languageScoped(key)] = title + separator + (subtitle ?? "")
        UserDefaults.standard.set(cache, forKey: cacheKey)
    }

    private static func languageScoped(_ key: String) -> String {
        "\(Locale.current.language.languageCode?.identifier ?? "en")|\(key)"
    }

    /// A name and a one-line description for each mix from Apple
    /// Intelligence, in one request - or nils where it is not available, and
    /// the mixes keep their names made from their artists.
    static func generate(for contexts: [MixNamingContext]) async -> [(title: String, subtitle: String?)?] {
        guard !contexts.isEmpty else { return [] }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), LocalModelBudget.spend() {
            return await FoundationMixNamer.names(contexts)
        }
        #endif
        return contexts.map { _ in nil }
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct GeneratedMixName {
    @Guide(description: "A short, evocative name for a personal music mix, two to four words, capturing its mood or style. No quotes, no emoji, and not just the word Mix.")
    var title: String
    @Guide(description: "One short line, at most eight words, describing how the mix feels. No quotes, no artist names.")
    var subtitle: String
}

@available(iOS 26.0, *)
@Generable
struct GeneratedMixNames {
    @Guide(description: "One entry per mix, in the same order as the numbered list")
    var mixes: [GeneratedMixName]
}

@available(iOS 26.0, *)
enum FoundationMixNamer {
    static func names(_ contexts: [MixNamingContext]) async -> [(title: String, subtitle: String?)?] {
        let empty = contexts.map { _ -> (title: String, subtitle: String?)? in nil }
        guard case .available = SystemLanguageModel.default.availability else { return empty }
        let language = Locale.current.localizedString(forLanguageCode: Locale.current.language.languageCode?.identifier ?? "en") ?? "English"
        let session = LanguageModelSession(instructions: """
        You name personal music mixes made from someone's own library. For each numbered mix, \
        from its artists, albums, songs and style, give a short evocative name that captures its \
        mood and a one-line description, both in \(language). Every name must be different. \
        Avoid generic names, avoid repeating the artists' names, never use quotes.
        """)
        let list = contexts.enumerated().map { index, context in
            var lines = ["\(index + 1). Artists: \(context.artists.joined(separator: ", "))"]
            if !context.albums.isEmpty { lines.append("   Albums: \(context.albums.joined(separator: "; "))") }
            lines.append("   Songs: \(context.songs.prefix(5).joined(separator: "; "))")
            if !context.styles.isEmpty { lines.append("   Styles: \(context.styles.joined(separator: ", "))") }
            if let decade = context.decade { lines.append("   Mostly from the \(decade)s") }
            if let energy = context.energy { lines.append("   Energy: \(energy)") }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
        guard let response = try? await session.respond(to: "Mixes:\n\(list)", generating: GeneratedMixNames.self) else {
            return empty
        }
        let trim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”«»"))
        var seen = Set<String>()
        return contexts.indices.map { index -> (title: String, subtitle: String?)? in
            guard response.content.mixes.indices.contains(index) else { return nil }
            let named = response.content.mixes[index]
            let title = named.title.trimmingCharacters(in: trim)
            let subtitle = named.subtitle.trimmingCharacters(in: trim)
            // A repeat or an overlong name is dropped; that mix keeps its
            // artist-based name and is named again with the next batch.
            guard !title.isEmpty, title.count <= 40, seen.insert(title.lowercased()).inserted else { return nil }
            return (title, subtitle.isEmpty || subtitle.count > 70 ? nil : subtitle)
        }
    }
}
#endif

/// A stable shuffle, so a mix keeps its order for the whole day.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Holds the current mixes so a mix's page can find it by id.
@MainActor
final class MixStore: ObservableObject {
    static let shared = MixStore()

    @Published private(set) var madeForYou: [Mix] = []
    @Published private(set) var moments: [Mix] = []
    /// The listening modes found at the last build, active and faded.
    @Published private(set) var modes: [ListeningMode] = []
    /// The listener at a glance, from the last build.
    private(set) var taste: TasteSummary?

    private var namingTask: Task<Void, Never>?
    private var curationTask: Task<Void, Never>?
    private var refineTask: Task<Void, Never>?
    private var profilingTask: Task<Void, Never>?
    private var buildTask: Task<Void, Never>?
    /// The newest library a rebuild was asked for while one was running.
    /// Looked at again once that one lands, instead of being dropped.
    private var pendingRebuild: [Track]?
    /// The mix being built to play (song, playlist mix). One at a time: a
    /// second tap supersedes the first, which must not land afterwards.
    private var mixPlayTask: Task<MixPlayOutcome, Never>?

    private init() {}

    func mix(id: String) -> Mix? {
        madeForYou.first { $0.id == id } ?? moments.first { $0.id == id }
    }

    /// What a set of mixes was built from, saved with them, so they are only
    /// rebuilt when something meaningful changed.
    private struct Snapshot: Codable {
        var builtAt: Date
        var libraryCount: Int
        var eventCount: Int
        /// The artists played most in the 30 days before the build.
        var topArtists: [Int64]
        var madeForYou: [Mix]
        var moments: [Mix]
        var modes: [ListeningMode]? = nil
        var taste: TasteSummary? = nil
        /// Per mode mix, the longer list it was cut from.
        var shortlists: [String: [String]]? = nil
    }

    /// The day the model last curated the mode mixes, and the order it
    /// chose - reapplied when the mixes are rebuilt later that day, so a
    /// rebuild neither loses it nor asks again.
    private static let curationKey = "cosmos.tasteCuration"
    private var curation: (day: Int, order: [String])? {
        get {
            guard let stored = UserDefaults.standard.dictionary(forKey: Self.curationKey),
                  let day = stored["day"] as? Int, let order = stored["order"] as? [String] else { return nil }
            return (day, order)
        }
        set {
            guard let newValue else { UserDefaults.standard.removeObject(forKey: Self.curationKey); return }
            UserDefaults.standard.set(["day": newValue.day, "order": newValue.order], forKey: Self.curationKey)
        }
    }

    /// Today's curated order, when there is one.
    private func curatedOrder(_ mixes: [Mix]) -> [Mix] {
        guard let curation, curation.day == Int(MixEngine.daySeed(Date())) else { return mixes }
        return Self.reordered(mixes, featuring: curation.order)
    }

    nonisolated private static var snapshotURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("mixes.json")
    }

    private var snapshot: Snapshot?
    private var lastProfilingDay: String? {
        get { UserDefaults.standard.string(forKey: "cosmos.lastArtistProfiling") }
        set { UserDefaults.standard.set(newValue, forKey: "cosmos.lastArtistProfiling") }
    }

    /// Forgets the saved mixes, so the next visit to Home builds new ones.
    func invalidate() {
        snapshot = nil
        if let url = Self.snapshotURL { try? FileManager.default.removeItem(at: url) }
    }

    /// Brings the mixes up to date - which usually means keeping them.
    ///
    /// A mix is a promise: once made, it stays as it is, so playing one does
    /// not make it change or disappear. New mixes are made at most once a
    /// day, or sooner only when something real changed: songs added to or
    /// removed from the library, a good deal of new listening, or a shift in
    /// the artists played most this month.
    func rebuild(tracks: [Track]) {
        // An empty list here is the library not loaded yet - Home's first
        // pass at launch runs before it is read - far more often than an
        // emptied library, and Home shows no mixes without songs anyway.
        // Building from it saved mixes "for 0 songs", so the real library a
        // moment later always rebuilt them (a second of work on every
        // launch), and when it arrived while that empty build still ran it
        // was dropped, leaving Made for You empty.
        guard !tracks.isEmpty else { return }
        if snapshot == nil, let url = Self.snapshotURL, let data = try? Data(contentsOf: url) {
            snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        }
        let events = ListeningLog.shared.events
        let topArtists = Self.topArtists(tracks: tracks, events: events)
        // Every listen ever, not the log's length: the log stops growing at
        // 5 000, and "a lot of new listening" must still be noticed then.
        let listenCount = ListeningLog.shared.totalListens

        if let snapshot, !Self.needsRebuild(snapshot, libraryCount: tracks.count, eventCount: listenCount, topArtists: topArtists) {
            if madeForYou.isEmpty && moments.isEmpty {
                // Songs deleted since stay out; a mix left too short goes.
                let existing = Set(tracks.map(\.stableId))
                func trimmed(_ mixes: [Mix]) -> [Mix] {
                    mixes.compactMap { mix in
                        let ids = mix.trackIds.filter(existing.contains)
                        guard ids.count >= 5 else { return nil }
                        return Mix(id: mix.id, title: mix.title, subtitle: mix.subtitle, trackIds: ids,
                                   coverTrackIds: mix.coverTrackIds.filter(existing.contains), hue: mix.hue, naming: mix.naming, why: mix.why)
                    }
                }
                madeForYou = applyingCachedNames(curatedOrder(trimmed(snapshot.madeForYou)))
                moments = trimmed(snapshot.moments)
                modes = snapshot.modes ?? []
                taste = snapshot.taste
                nameUnnamedMixes()
                curateModes()
            }
            return
        }
        guard buildTask == nil else {
            // Not dropped: the running build may be for an older library.
            // Checked again against its result once it lands.
            pendingRebuild = tracks
            return
        }

        // The work runs off the main thread - the database reads too.
        buildTask = Task { [weak self] in
            let buildSignpost = Perf.begin("Mix build")
            defer { Perf.end("Mix build", buildSignpost) }
            let library = await Task.detached(priority: .utility) { MixStore.readLibrary(tracks: tracks) }.value
            guard let made = self?.makeEngine(library: library, events: events) else { return }
            let (engine, artistNames, albumTitles) = made
            let result = await Task.detached(priority: .utility) { () -> (MadeForYouResult, [Mix], [String: Set<Int64>], [ListeningMode], TasteSummary) in
                #if DEBUG
                let clock = ContinuousClock()
                let start = clock.now
                #endif
                let taste = engine.tasteContext()
                #if DEBUG
                let tasteDone = clock.now
                #endif
                let made = engine.madeForYou(taste: taste)
                #if DEBUG
                let madeDone = clock.now
                #endif
                let moments = engine.rediscover(excluding: Set(made.mixes.flatMap(\.trackIds)), taste: taste)
                #if DEBUG
                let summary = taste.summary
                print("[Mixes] built for \(engine.tracks.count) songs, \(engine.events.count) listens: taste profile \(tasteDone - start) (\(summary.sessions) sessions, k \(summary.clusters), silhouette \(String(format: "%.2f", summary.silhouette)), \(taste.modes.count) modes, \(taste.modes.filter(\.isActive).count) active), made for you \(madeDone - tasteDone), rediscover \(clock.now - madeDone)")
                #endif
                return (made, moments, engine.learnedMixLessons(), taste.modes, taste.summary)
            }.value
            guard let self else { return }
            self.buildTask = nil
            MixLessons.remember(result.2)
            self.madeForYou = self.applyingCachedNames(self.curatedOrder(result.0.mixes))
            self.moments = result.1
            self.modes = result.3
            self.taste = result.4
            self.snapshot = Snapshot(
                builtAt: Date(),
                libraryCount: tracks.count,
                eventCount: listenCount,
                topArtists: topArtists,
                madeForYou: result.0.mixes,
                moments: result.1,
                modes: result.3,
                taste: result.4,
                shortlists: result.0.shortlists
            )
            self.saveSnapshot()
            RediscoverCooldown.record(result.1)
            self.nameUnnamedMixes()
            self.curateModes()
            self.profileUntaggedArtists(tracks: tracks, artistNames: artistNames, albumTitles: albumTitles)
            // A newer library asked for meanwhile: compared with the mixes
            // just made, which usually keeps them.
            if let pending = self.pendingRebuild {
                self.pendingRebuild = nil
                self.rebuild(tracks: pending)
            }
        }
    }

    /// An engine over the library as it is now - or, for the replay test, as
    /// it was at `now`.
    private func makeEngine(tracks: [Track], events: [ListeningLog.Event], now: Date = Date()) -> (MixEngine, [Int64: String], [Int64: String]) {
        makeEngine(library: Self.readLibrary(tracks: tracks), events: events, now: now)
    }

    /// What a mix engine reads from the database. Read off the main thread:
    /// the whole library, every playlist's songs and every album can take a
    /// noticeable moment on a large library, right when a tap wants a mix.
    struct LibraryInputs: Sendable {
        var tracks: [Track]
        var favorites: Set<String>
        var playlists: [[String]]
        var albumYears: [Int64: Int]
        var albumTitles: [Int64: String]
        var artistNames: [Int64: String]
    }

    /// The database reads behind an engine; `tracks` when already loaded.
    /// GRDB reads are thread-safe, so this runs on any thread.
    nonisolated static func readLibrary(tracks: [Track]? = nil) -> LibraryInputs {
        let database = DatabaseManager.shared
        let tracks = tracks ?? ((try? database.getAllTracks()) ?? [])
        let favorites = Set((try? database.getFavorites()) ?? [])
        let playlists = ((try? database.getAllPlaylists()) ?? []).compactMap { playlist -> [String]? in
            guard let id = playlist.id else { return nil }
            return ((try? database.getPlaylistItems(playlistId: id)) ?? []).map(\.trackStableId)
        }
        let albums = (try? database.getAllAlbums()) ?? []
        var albumYears: [Int64: Int] = [:]
        var albumTitles: [Int64: String] = [:]
        for album in albums {
            guard let id = album.id else { continue }
            albumTitles[id] = album.title
            if let year = album.year, year > 0 { albumYears[id] = year }
        }
        let artistNames = (try? database.getAllArtistNamesById()) ?? [:]
        return LibraryInputs(tracks: tracks, favorites: favorites, playlists: playlists,
                             albumYears: albumYears, albumTitles: albumTitles, artistNames: artistNames)
    }

    /// An engine over the library as it is now, its database reads done
    /// off the main thread; the listening state is read here, on main.
    private func makeEngineOffMain() async -> MixEngine {
        let library = await Task.detached(priority: .userInitiated) { Self.readLibrary() }.value
        return makeEngine(library: library, events: ListeningLog.shared.events).0
    }

    private func makeEngine(library: LibraryInputs, events: [ListeningLog.Event], now: Date = Date()) -> (MixEngine, [Int64: String], [Int64: String]) {
        let artistNames = library.artistNames
        let albumTitles = library.albumTitles
        let engine = MixEngine(
            tracks: library.tracks,
            favorites: library.favorites,
            events: events,
            playlists: library.playlists,
            artistNames: artistNames,
            albumYears: library.albumYears,
            albumTitles: albumTitles,
            profiles: ArtistProfileStore.shared.profiles,
            recentTrackIds: ListeningHistory.shared.recentTrackIds,
            rediscoverCooldown: RediscoverCooldown.resting(),
            lifetime: ListeningLog.shared.lifetime,
            mixLessons: MixLessons.current(),
            modes: modes,
            noveltySeeking: taste?.noveltySeeking,
            currentRoute: ListeningLog.currentRoute(),
            now: now
        )
        return (engine, artistNames, albumTitles)
    }

    /// The mix for a moment - now, or the `dayPart` asked for ("something
    /// for tonight"): the listening mode that fits its time, days and the
    /// output playing now, its mix from the shelf or built on the spot;
    /// without modes, the time-of-day mix; else the first Made for You mix.
    /// Deterministic, no Apple Intelligence involved.
    func mixForMoment(dayPart requested: Int?) async -> Mix? {
        let now = Date()
        let calendar = Calendar.current
        let part = requested ?? MixEngine.dayPart(of: now, calendar: calendar)
        let fitting = MixEngine.modesFitting(modes, dayPart: part, weekend: calendar.isDateInWeekend(now), route: ListeningLog.currentRoute())
        var engine: MixEngine?
        func makeEngineOnce() async -> MixEngine {
            if let engine { return engine }
            let made = await makeEngineOffMain()
            engine = made
            return made
        }
        if let mode = fitting.first {
            if let onShelf = madeForYou.first(where: { $0.id == mode.id }) { return onShelf }
            let built = await makeEngineOnce()
            if let mix = await Task.detached(priority: .userInitiated, operation: { built.modeMix(for: mode) }).value {
                return applyingCachedNames([mix]).first
            }
        }
        if let timeMix = madeForYou.first(where: { $0.id == "daypart-\(part)" }) { return timeMix }
        // Not on the shelf - a mode mix stood for that time, or the time
        // asked for is not now's: built on the spot.
        let built = await makeEngineOnce()
        if let mix = await Task.detached(priority: .userInitiated, operation: { built.timeOfDayMix(part: part) }).value {
            return mix
        }
        return madeForYou.first
    }

    /// The listener's last choice when a mix starts being built. Building
    /// takes a moment (library read, engine), and the listener may meanwhile
    /// tap an album or ask Siri for something else: the mix must then not
    /// replace their choice. Counted by PlayerEngine rather than read off
    /// the queue, which also changes with nobody choosing: the saved session
    /// restored on a cold launch, a previous mix reshaping what is left,
    /// bookmark identities migrating, repeat wrapping round or an unplayable
    /// song skipped. A mix's own plays do not count either.
    struct PlaybackBaseline {
        let choice: UInt64

        @MainActor static func now() -> PlaybackBaseline {
            PlaybackBaseline(choice: PlayerEngine.shared.listenerChoiceGeneration)
        }

        /// Whether something else was chosen since.
        @MainActor var listenerMovedOn: Bool {
            PlayerEngine.shared.listenerChoiceGeneration != choice
        }
    }

    /// How a mix play ended. Siri's artist radio falls back to the artist's
    /// songs shuffled only on `noCompanions`: when superseded, the listener
    /// (or a newer mix) chose something else, and replacing it would
    /// override them.
    enum MixPlayOutcome {
        /// The mix is in the queue; `current` is the song it plays now - the
        /// seed, or the song the seed ran on into while the mix was built.
        case started(current: String)
        /// The engine found nothing to add to the seed; nothing was played.
        case noCompanions
        /// A newer mix was asked for or the listener moved on; nothing was
        /// played, or what played was replaced since.
        case superseded
    }

    /// Runs `build` as the one mix play under way, cancelling the previous.
    /// `stillWanted` turns false once a newer mix was asked for or the
    /// listener moved on; `build` checks it after every wait, before playing.
    private func startMixPlay(_ build: @escaping @MainActor (_ stillWanted: @escaping @MainActor () -> Bool) async -> MixPlayOutcome) -> Task<MixPlayOutcome, Never> {
        let previous = mixPlayTask
        previous?.cancel()
        // The last mix's skip streak, refill and Apple Intelligence
        // refinement belong to it: left running, they reshape the queue
        // while this one is built and then under it.
        resetRadioFeedback()
        refineTask?.cancel()
        // Taken now, not after the previous mix settles: a song tapped while
        // it finishes is the listener's choice and must win. The previous
        // mix, cancelled, checks that right before playing - and its plays,
        // like this one's, are not counted as the listener's.
        let baseline = PlaybackBaseline.now()
        let task = Task { @MainActor () -> MixPlayOutcome in
            if let previous { _ = await previous.value }
            // On a cold launch (Siri's song radio) the saved session can still
            // be loading; let it land first so the seed check below sees it and
            // it cannot overwrite the mix. Bounded: its retries take seconds.
            // Raced by polling rather than in a task group - a group waits for
            // every child, and cancelling it never reaches PlayerEngine's own
            // unstructured restore task, so the cap did not hold. Left running
            // past the deadline, the restore yields to the mix's playTrack.
            let restore = RestoreFlag()
            Task { @MainActor in
                await PlayerEngine.shared.ensureSavedStateRestored()
                restore.finished = true
            }
            let deadline = Date().addingTimeInterval(3)
            while !restore.finished, !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            return await build { !Task.isCancelled && !baseline.listenerMovedOn }
        }
        mixPlayTask = task
        return task
    }

    @MainActor private final class RestoreFlag {
        var finished = false
    }

    /// Plays a mix grown from one song - from a tap on a song in Start
    /// Listening, "Song Mix" in any song's menu, or Siri. Superseded when a
    /// newer mix was asked for or the listener moved on meanwhile;
    /// `noCompanions` - only with `requiresCompanions` - when the engine found
    /// nothing to add to the seed.
    @discardableResult
    func playSongMix(from seed: Track, requiresCompanions: Bool = false) async -> MixPlayOutcome {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        // Taken now, before the build: "the seed just ended" only means
        // something if it was playing when the mix was asked for. A queue row
        // already played, or a Start Listening song that merely sits before
        // the current one, must still be played rather than skipped.
        let seedWasCurrent = PlayerEngine.shared.currentTrack?.stableId == seed.stableId
        let task = startMixPlay { stillWanted in
            let songMixSignpost = Perf.begin("Song mix build")
            let engine = await self.makeEngineOffMain()
            guard stillWanted() else { Perf.end("Song mix build", songMixSignpost); return .superseded }
            let (queue, spares) = await Task.detached(priority: .userInitiated) { engine.songMixWithSpares(seed: seed) }.value
            Perf.end("Song mix build", songMixSignpost)
            guard stillWanted() else { return .superseded }
            if requiresCompanions, queue.count < 2 { return .noCompanions }
            let source = "radio:\(seed.stableId)"
            ListeningLog.shared.tagQueue(source, tracks: queue + spares)
            // A new mix: the last one's skip streak and any refill of it
            // still under way must not reshape this one.
            self.resetRadioFeedback()
            let player = PlayerEngine.shared
            let current = player.currentTrack
            // The seed ended on its own while the mix was built and the queue
            // ran on into the next song: restarting the seed from 0 would replay
            // what was just heard. The mix follows the song playing now instead.
            // Repeat All wraps a seed that was the last song back to index 0,
            // so its predecessor is then the queue's last entry.
            let queueNow = player.playbackQueue
            let previousIndex = player.currentIndex == 0 && player.isRepeating
                ? queueNow.count - 1 : player.currentIndex - 1
            let seedJustEnded = seedWasCurrent
                && current?.stableId != seed.stableId
                && previousIndex != player.currentIndex
                && queueNow.indices.contains(previousIndex)
                && queueNow[previousIndex].stableId == seed.stableId
            // No suspension from the last stillWanted() check to the plays below,
            // so Shuffle and Repeat One are only turned off for a mix that does
            // play. replaceQueueAfterCurrent turns both off itself.
            if let current, current.stableId == seed.stableId || seedJustEnded, !queue.isEmpty {
                // The seed is already loaded (started from the player, or the
                // session Siri restored): it carries on, and the mix follows it.
                // Paused, it starts - asking for a mix means wanting to hear it,
                // and Siri's "more like this" otherwise left silence.
                player.replaceQueueAfterCurrent(with: queue.filter { $0.stableId != seed.stableId })
                if !player.isPlaying { player.play() }
            } else {
                // Repeat One would keep replaying the seed; shuffle left on
                // would reshuffle the mix in playTrack and make every later
                // reshape of what is left a no-op.
                player.isLoopingSong = false
                player.isShuffled = false
                await player.playTrack(seed, queue: queue.isEmpty ? [seed] : queue, countsAsListenerChoice: false)
            }
            let expected = seedJustEnded ? current?.stableId : seed.stableId
            guard !Task.isCancelled, let expected, player.currentTrack?.stableId == expected else { return .superseded }
            self.refineUpcoming(source: source, description: String(format: Localized.songMix + ": %@", seed.title), queue: queue, spares: spares)
            return .started(current: expected)
        }
        return await task.value
    }

    /// Plays a mix grown from a whole playlist (`MixEngine.playlistMix`).
    func playPlaylistMix(playlistId: Int64) {
        let ids = ((try? DatabaseManager.shared.getPlaylistItems(playlistId: playlistId)) ?? []).map(\.trackStableId)
        let seeds = (try? DatabaseManager.shared.getTracksByStableIdsPreservingOrder(ids)) ?? []
        guard !seeds.isEmpty else { return }
        let title = ((try? DatabaseManager.shared.getAllPlaylists()) ?? []).first { $0.id == playlistId }?.title
        playMix(seeds: seeds, source: "radio:playlist:\(playlistId)", description: title.map { Localized.playlistMix + ": " + $0 })
    }

    /// Plays a mix grown from several songs at once, tagged with `source`
    /// so its skips steer it like a song mix's and its listens are counted.
    /// Superseded like a song mix (see `startMixPlay`).
    func playMix(seeds: [Track], source: String, description: String? = nil) {
        guard !seeds.isEmpty else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        _ = startMixPlay { stillWanted in
            let engine = await self.makeEngineOffMain()
            guard stillWanted() else { return .superseded }
            let (queue, spares) = await Task.detached(priority: .userInitiated) { engine.playlistMix(seeds: seeds) }.value
            guard stillWanted(), let first = queue.first else { return .superseded }
            ListeningLog.shared.tagQueue(source, tracks: queue + spares)
            self.resetRadioFeedback()
            // Turned off only here, with no suspension since the last
            // stillWanted() check: Repeat One would keep replaying the first
            // song, and shuffle left on would reshuffle the mix in playTrack
            // and make every later reshape of what is left a no-op.
            PlayerEngine.shared.isLoopingSong = false
            PlayerEngine.shared.isShuffled = false
            await PlayerEngine.shared.playTrack(first, queue: queue, countsAsListenerChoice: false)
            guard !Task.isCancelled else { return .superseded }
            self.refineUpcoming(source: source, description: description ?? Localized.playlistMix, queue: queue, spares: spares)
            return .started(current: first.stableId)
        }
    }

    /// With Apple Intelligence, lets the model choose, among the songs still
    /// to come and the spares, the ones that belong together best - after
    /// playback has started, so nobody waits for it. Asked by the listener,
    /// so outside the background budget, but never in Low Power Mode or
    /// when hot, and dropped after two seconds; the songs already queued,
    /// and the one up next, stay as they are.
    private func refineUpcoming(source: String, description: String, queue: [Track], spares: [Track]) {
        refineTask?.cancel()
        guard !spares.isEmpty, queue.count > 4, TasteCurator.deviceAllows, TasteCurator.isAvailable else { return }
        let pool = Array(queue.dropFirst(2)) + spares
        let keep = queue.count - 2
        let names = (try? DatabaseManager.shared.getArtistDisplayNames(
            forTrackStableIds: pool.map(\.stableId),
            fallbackArtistIdsByStableId: pool.reduce(into: [:]) { result, track in
                if let artistId = track.artistId { result[track.stableId] = artistId }
            }
        )) ?? [:]
        let lines = pool.map { track in
            [track.title, names[track.stableId], track.genre, track.year.map(String.init)].compactMap { $0 }.joined(separator: " - ")
        }
        refineTask = Task { @MainActor in
            guard let picked = await TasteCurator.rerank(description: description, songs: lines, keep: keep, timeout: 2),
                  !Task.isCancelled else { return }
            let player = PlayerEngine.shared
            // Only while the listener is still in this mix, its queue untouched.
            let queued = Set(queue.map(\.stableId))
            guard let current = player.currentTrack, queued.contains(current.stableId),
                  player.playbackQueue.dropFirst(player.currentIndex + 1).allSatisfy({ queued.contains($0.stableId) }) else { return }
            var generator = SeededGenerator(seed: UInt64.random(in: 0...UInt64.max))
            let chosen = MixEngine.flowOrder(picked.map { pool[$0] }, generator: &generator)
            let played = Set(player.playbackQueue.prefix(player.currentIndex + 2).map(\.stableId))
            let upcoming = chosen.filter { !played.contains($0.stableId) }
            guard !upcoming.isEmpty else { return }
            ListeningLog.shared.tagQueue(source, tracks: queue + spares)
            player.reshapeUpcoming { _ in upcoming }
        }
    }

    private static func needsRebuild(_ snapshot: Snapshot, libraryCount: Int, eventCount: Int, topArtists: [Int64]) -> Bool {
        // A day old: new day, new mixes.
        if Date().timeIntervalSince(snapshot.builtAt) >= 24 * 3600 { return true }
        // Songs added or removed - ten, or a twentieth of the library.
        let libraryChange = abs(libraryCount - snapshot.libraryCount)
        if libraryChange >= max(10, snapshot.libraryCount / 20) { return true }
        // A lot of new listening - roughly an afternoon's worth.
        if eventCount - snapshot.eventCount >= 60 || eventCount < snapshot.eventCount { return true }
        // The artists played most this month are mostly different ones.
        if !snapshot.topArtists.isEmpty, !topArtists.isEmpty {
            let shared = Set(snapshot.topArtists).intersection(topArtists).count
            if Double(shared) / Double(min(snapshot.topArtists.count, topArtists.count)) < 0.5 { return true }
        }
        return false
    }

    /// The eight artists played most in the last 30 days.
    private static func topArtists(tracks: [Track], events: [ListeningLog.Event]) -> [Int64] {
        let month = Date().addingTimeInterval(-30 * 86_400)
        let artistOf = Dictionary(tracks.map { ($0.stableId, $0.artistId) }, uniquingKeysWith: { first, _ in first })
        var plays: [Int64: Int] = [:]
        for event in events where event.at >= month && !event.isSkip {
            if let artistId = artistOf[event.id] ?? nil { plays[artistId, default: 0] += 1 }
        }
        return plays.sorted { $0.value > $1.value }.prefix(8).map(\.key)
    }

    private func applyingCachedNames(_ mixes: [Mix]) -> [Mix] {
        mixes.map { mix in
            var mix = mix
            if let key = mix.naming?.key, let cached = MixNamer.cached(for: key) {
                mix.title = cached.title
                if let subtitle = cached.subtitle { mix.subtitle = subtitle }
            }
            return mix
        }
    }

    private func saveSnapshot() {
        guard let snapshot else { return }
        Task.detached(priority: .utility) {
            guard let url = MixStore.snapshotURL, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Asks the on-device model to name the mixes that have no name yet.
    private func nameUnnamedMixes() {
        namingTask?.cancel()
        // Mode mixes are named with today's curation (`curateModes`).
        let pending = madeForYou.filter { mix in
            !mix.id.hasPrefix("mode-") && (mix.naming.map { MixNamer.cached(for: $0.key) == nil } ?? false)
        }
        guard !pending.isEmpty else { return }
        namingTask = Task { @MainActor [weak self] in
            // All of them in one request: one spend of the daily budget, and
            // the model sees every mix at once so no two get the same name.
            let contexts = pending.compactMap(\.naming)
            let names = await MixNamer.generate(for: contexts)
            guard !Task.isCancelled else { return }
            for (mix, named) in zip(pending, names) {
                guard let named, let context = mix.naming else { continue }
                MixNamer.store(title: named.title, subtitle: named.subtitle, for: context.key)
                guard let self, let index = self.madeForYou.firstIndex(where: { $0.id == mix.id }) else { continue }
                // The name only arrives once, so the mix keeps it from here on.
                self.madeForYou[index].title = MixNamer.capitalized(named.title)
                if let subtitle = named.subtitle { self.madeForYou[index].subtitle = subtitle }
            }
        }
    }

    /// Once a day, with Apple Intelligence: one request that chooses which
    /// mode mixes to feature today and in what order, names the new ones
    /// and gives each a line saying why - from a summary of the profile and
    /// the modes' own numbers, no song lists. Then, if the budget allows,
    /// one more that lets the model choose the top mode mix's songs from
    /// its shortlist. Background work: within `LocalModelBudget`, never in
    /// Low Power Mode or hot, after launch has settled. Without it, the
    /// mixes keep the app's own order, names and lines.
    private func curateModes() {
        let today = Int(MixEngine.daySeed(Date()))
        let modeMixes = madeForYou.filter { $0.id.hasPrefix("mode-") }
        guard curationTask == nil, curation?.day != today, !modeMixes.isEmpty,
              LocalModelBudget.allowsBackgroundWork, TasteCurator.isAvailable else { return }
        let modesById = Dictionary(modes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let briefs = modeMixes.compactMap { mix in modesById[mix.id].map { (mix, $0) } }
        guard !briefs.isEmpty else { return }
        let names = (try? DatabaseManager.shared.getAllArtistNamesById()) ?? [:]
        let profile = Self.profileBrief(taste)
        let lines = briefs.map { Self.modeBrief($0.1, title: $0.0.title, artistNames: names) }
        let now = Date()
        let todayText = now.formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "en_US")))
            + ", " + ["morning", "afternoon", "evening", "night"][TasteModes.dayPart(ofHour: Calendar.current.component(.hour, from: now))]

        curationTask = Task { @MainActor [weak self] in
            defer { self?.curationTask = nil }
            // Let launch finish first: this is background work.
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, LocalModelBudget.spend() else { return }
            let picks = await TasteCurator.curate(profile: profile, modes: lines, today: todayText)
            guard let self, !Task.isCancelled else { return }
            // Asked today, whatever came back: the budget is not spent twice.
            self.curation = (today, picks.map { $0.map { briefs[$0.index].0.id } } ?? [])
            if let picks {
                var order: [String] = []
                for pick in picks {
                    let (mix, mode) = briefs[pick.index]
                    order.append(mix.id)
                    // A name once given stays with the mode; the line is today's.
                    let title = MixNamer.cached(for: mode.id)?.title ?? pick.title
                    if let title { MixNamer.store(title: title, subtitle: pick.why, for: mode.id) }
                }
                self.madeForYou = self.applyingCachedNames(Self.reordered(self.madeForYou, featuring: order))
            }
            await self.rerankTopMode()
        }
    }

    /// The mode mixes in `order` first, then the other mode mixes, each
    /// keeping its place among the rest of the shelf's slots.
    private static func reordered(_ mixes: [Mix], featuring order: [String]) -> [Mix] {
        let slots = mixes.indices.filter { mixes[$0].id.hasPrefix("mode-") }
        let modeMixes = slots.map { mixes[$0] }
        let ranked = order.compactMap { id in modeMixes.first { $0.id == id } }
            + modeMixes.filter { !order.contains($0.id) }
        var result = mixes
        for (slot, mix) in zip(slots, ranked) { result[slot] = mix }
        return result
    }

    /// The first mode mix's songs, chosen by the model from its shortlist
    /// of 60 - indices only, checked - and ordered to flow again.
    private func rerankTopMode() async {
        guard let mix = madeForYou.first(where: { $0.id.hasPrefix("mode-") }),
              let shortlist = snapshot?.shortlists?[mix.id], shortlist.count > mix.trackIds.count,
              LocalModelBudget.spend() else { return }
        let database = DatabaseManager.shared
        let tracks = (try? database.getTracksByStableIdsPreservingOrder(shortlist)) ?? []
        guard tracks.count > mix.trackIds.count else { return }
        let names = (try? database.getArtistDisplayNames(
            forTrackStableIds: tracks.map(\.stableId),
            fallbackArtistIdsByStableId: tracks.reduce(into: [:]) { result, track in
                if let artistId = track.artistId { result[track.stableId] = artistId }
            }
        )) ?? [:]
        let lines = tracks.map { track in
            [track.title, names[track.stableId], track.genre, track.year.map(String.init)].compactMap { $0 }.joined(separator: " - ")
        }
        let description = [mix.title, mix.why].compactMap { $0 }.joined(separator: " - ")
        guard let picked = await TasteCurator.rerank(description: description, songs: lines, keep: mix.trackIds.count, timeout: 30),
              picked.count >= 15 else { return }
        let favorites = Set((try? AppCoordinator.shared.getFavorites()) ?? [])
        let chosen = picked.map { tracks[$0] }
        let ordered = await Task.detached(priority: .utility) { () -> [Track] in
            var generator = SeededGenerator(seed: MixEngine.daySeed(Date()))
            return MixEngine.flowOrder(chosen, familiar: favorites, generator: &generator)
        }.value
        func replacing(_ mixes: [Mix]) -> [Mix] {
            mixes.map { old in
                guard old.id == mix.id else { return old }
                var coverIds: [String] = []
                var coverAlbums = Set<Int64>()
                for track in ordered where track.hasArtwork && coverIds.count < 4 {
                    if let albumId = track.albumId, !coverAlbums.insert(albumId).inserted { continue }
                    coverIds.append(track.stableId)
                }
                return Mix(id: old.id, title: old.title, subtitle: old.subtitle, trackIds: ordered.map(\.stableId),
                           coverTrackIds: coverIds.isEmpty ? old.coverTrackIds : coverIds, hue: old.hue, naming: old.naming, why: old.why)
            }
        }
        madeForYou = replacing(madeForYou)
        if let stored = snapshot?.madeForYou { snapshot?.madeForYou = replacing(stored) }
        saveSnapshot()
    }

    /// The listener, in a few compact lines for the model: no song lists.
    private static func profileBrief(_ taste: TasteSummary?) -> String {
        guard let taste else { return "{}" }
        var fields: [String] = []
        if !taste.topArtists.isEmpty { fields.append("top artists: \(taste.topArtists.joined(separator: ", "))") }
        if !taste.risingArtists.isEmpty { fields.append("rising: \(taste.risingArtists.joined(separator: ", "))") }
        if !taste.fadingArtists.isEmpty { fields.append("fading: \(taste.fadingArtists.joined(separator: ", "))") }
        if !taste.topGenres.isEmpty { fields.append("top genres: \(taste.topGenres.joined(separator: ", "))") }
        fields.append(String(format: "finishes %.0f%% of songs new to them", taste.noveltySeeking * 100))
        fields.append(String(format: "replays %.0f%% of listens within a week", taste.repeatTendency * 100))
        fields.append("about \(taste.typicalSessionLength) songs per sitting")
        return "{" + fields.joined(separator: "; ") + "}"
    }

    /// One mode, as facts the model may use: its sound, when and where it
    /// is played, its artists, how much and how lately.
    private static func modeBrief(_ mode: ListeningMode, title: String, artistNames: [Int64: String]) -> String {
        var fields = ["current name: \(title)"]
        let genres = mode.genres.sorted { ($0.value, $0.key) > ($1.value, $1.key) }.prefix(3)
            .map { "\($0.key) \(Int(($0.value * 100).rounded()))%" }
        if !genres.isEmpty { fields.append("genres: \(genres.joined(separator: ", "))") }
        if let year = mode.year, (mode.yearSpread ?? 99) <= 12 { fields.append("era: \(Int(year) / 10 * 10)s") }
        if let energy = mode.energyLabel { fields.append("energy: \(energy)") }
        if let part = mode.dayPart { fields.append("time: \(["morning", "afternoon", "evening", "night"][part])") }
        if let weekend = mode.weekend { fields.append(weekend ? "days: weekends" : "days: weekdays") }
        if let route = mode.route { fields.append("output: \(route)") }
        let artists = mode.topArtists.prefix(4).compactMap { artistNames[$0] }
        if !artists.isEmpty { fields.append("artists: \(artists.joined(separator: ", "))") }
        let days = max(0, Int(Date().timeIntervalSince(mode.lastPlayed) / 86_400))
        fields.append("\(mode.sessions) sittings, \(mode.listens) listens, \(mode.recentSessions) in the last 4 weeks, last \(days) days ago")
        fields.append(String(format: "%.0f%% of their listening", mode.share * 100))
        return "{" + fields.joined(separator: "; ") + "}"
    }

    /// Artists whose files carry no genre or year tags get a profile from the
    /// on-device model, most-played first, a few batches per launch; the
    /// mixes are rebuilt once when that taught the app something.
    private func profileUntaggedArtists(tracks: [Track], artistNames: [Int64: String], albumTitles: [Int64: String]) {
        let today = String(MixEngine.daySeed(Date()))
        guard profilingTask == nil, lastProfilingDay != today, LocalModelBudget.allowsBackgroundWork else { return }
        var tagged = Set<Int64>()
        var songCount: [Int64: Int] = [:]
        var hint: [Int64: String] = [:]
        for track in tracks {
            guard let artistId = track.artistId else { continue }
            songCount[artistId, default: 0] += 1
            if track.genre != nil || track.year != nil { tagged.insert(artistId) }
            if hint[artistId] == nil, let albumId = track.albumId { hint[artistId] = albumTitles[albumId] }
        }
        var playCount: [Int64: Int] = [:]
        let byId = Dictionary(tracks.map { ($0.stableId, $0.artistId) }, uniquingKeysWith: { first, _ in first })
        for event in ListeningLog.shared.events {
            if let artistId = byId[event.id] ?? nil { playCount[artistId, default: 0] += 1 }
        }
        let untagged = songCount.keys
            .filter { !tagged.contains($0) }
            .sorted { (playCount[$0] ?? 0, songCount[$0] ?? 0) > (playCount[$1] ?? 0, songCount[$1] ?? 0) }
            .compactMap { artistNames[$0] }
        guard !untagged.isEmpty else { return }
        var hints: [String: String] = [:]
        for (artistId, album) in hint { if let name = artistNames[artistId] { hints[name] = album } }

        profilingTask = Task { @MainActor [weak self] in
            // Let launch finish first; this is background work. What it
            // learns shapes the next day's mixes - today's stay as they are.
            try? await Task.sleep(for: .seconds(8))
            _ = await ArtistProfileStore.shared.profileMissing(untagged, hints: hints)
            self?.lastProfilingDay = today
        }
    }

    // MARK: Song mix feedback

    /// Early skips in a row in the song mix playing now.
    private var radioSkipsInRow = 0
    private var radioRefillTask: Task<Void, Never>?

    /// Forgets the song mix's skip streak and any refill under way - the
    /// listener moved on to a queue of their own.
    func resetRadioFeedback() {
        radioSkipsInRow = 0
        radioRefillTask?.cancel()
        radioRefillTask = nil
    }

    /// Reacts to a song of a song mix ending, the way a radio station takes
    /// a thumbs-down: a quick skip sends that artist to the back of what is
    /// left and drops the rest of that album; two in a row rebuild the rest
    /// of the mix from its seed, minus what has played. A song heard to the
    /// end brings one more by that artist a little closer.
    func radioListened(_ event: ListeningLog.Event) {
        guard let source = event.source, source.hasPrefix("radio:") else { return }
        // The song ends because the listener left the mix (tapped an album
        // within 30 s): that is not a thumbs-down, and the queue now playing
        // is theirs, not the mix's - never reshape or refill it.
        guard ListeningLog.shared.isPlaying(from: source) else {
            resetRadioFeedback()
            return
        }
        guard let track = try? DatabaseManager.shared.getTrack(byStableId: event.id) else { return }
        let engine = PlayerEngine.shared
        if event.isSkip {
            radioSkipsInRow += 1
            engine.reshapeUpcoming { upcoming in
                let sameAlbum = { (other: Track) in track.albumId != nil && other.albumId == track.albumId }
                let sameArtist = { (other: Track) in track.artistId != nil && other.artistId == track.artistId }
                let kept = upcoming.filter { !sameAlbum($0) }
                return kept.filter { !sameArtist($0) } + kept.filter(sameArtist)
            }
            if radioSkipsInRow >= 2 { refillRadio(seedId: String(source.dropFirst("radio:".count))) }
        } else if (event.heard ?? 0) >= 0.8 {
            radioSkipsInRow = 0
            engine.reshapeUpcoming { upcoming in
                guard let index = upcoming.indices.dropFirst(2).first(where: { upcoming[$0].artistId == track.artistId && track.artistId != nil }) else {
                    return upcoming
                }
                var reordered = upcoming
                let moved = reordered.remove(at: index)
                reordered.insert(moved, at: min(1, reordered.count))
                return reordered
            }
        }
    }

    /// Rebuilds what is left of a song mix from its seed, leaving out every
    /// song already played or queued before the current point.
    private func refillRadio(seedId: String) {
        radioSkipsInRow = 0
        radioRefillTask?.cancel()
        refineTask?.cancel()
        let source = "radio:\(seedId)"
        radioRefillTask = Task {
            // A playlist mix grows again from its playlist; a song mix from
            // its song. Read off the main thread, like the library itself.
            let seeds = await Task.detached(priority: .userInitiated) { () -> (tracks: [Track], fromPlaylist: Bool) in
                let database = DatabaseManager.shared
                if seedId.hasPrefix("playlist:"), let playlistId = Int64(seedId.dropFirst("playlist:".count)) {
                    let ids = ((try? database.getPlaylistItems(playlistId: playlistId)) ?? []).map(\.trackStableId)
                    return ((try? database.getTracksByStableIdsPreservingOrder(ids)) ?? [], true)
                }
                return ((try? database.getTrack(byStableId: seedId)).map { [$0] } ?? [], false)
            }.value
            guard let seed = seeds.tracks.first, !Task.isCancelled else { return }
            let engine = await self.makeEngineOffMain()
            let seedList = seeds.tracks
            let fromPlaylist = seeds.fromPlaylist
            let fresh = await Task.detached(priority: .userInitiated) {
                fromPlaylist ? engine.playlistMix(seeds: seedList, size: 40).queue : engine.songMix(seed: seed, size: 40)
            }.value
            // The build takes a moment: the listener may have left the mix
            // meanwhile, and their new queue is not this mix's to replace.
            guard !Task.isCancelled, ListeningLog.shared.isPlaying(from: source) else { return }
            let player = PlayerEngine.shared
            let played = Set(player.playbackQueue.prefix(player.currentIndex + 2).map(\.stableId))
            let refill = fresh.filter { !played.contains($0.stableId) }
            ListeningLog.shared.tagQueue(source, tracks: player.playbackQueue + refill)
            player.reshapeUpcoming { _ in refill }
        }
    }

    // MARK: Quality

    /// When the mixes on screen were made.
    var builtAt: Date? { snapshot?.builtAt }

    /// How a mix's songs were received, from the listens it started.
    struct Stats {
        var plays = 0
        var earlySkips = 0
        var completions = 0
        var earlySkipRate: Double { plays == 0 ? 0 : Double(earlySkips) / Double(plays) }
        var completionRate: Double { plays == 0 ? 0 : Double(completions) / Double(plays) }
    }

    /// Listens whose source starts with `prefix` ("mix:habit-12", "radio:").
    func stats(forSource prefix: String) -> Stats {
        var stats = Stats()
        for event in ListeningLog.shared.events where event.source?.hasPrefix(prefix) == true {
            stats.plays += 1
            if event.isSkip { stats.earlySkips += 1 }
            if (event.heard ?? 0) >= 0.8 { stats.completions += 1 }
        }
        return stats
    }

    /// Replays the engine against the listening log: mixes made as of a past
    /// day are compared with what was really played, not skipped, in the
    /// seven days after - beside a baseline of random songs by the same
    /// artists. Lets the weights be tuned on real habits instead of guessed.
    func replayEvaluation() async -> String {
        let events = ListeningLog.shared.events
        guard let first = events.first?.at, let last = events.last?.at,
              last.timeIntervalSince(first) > 4 * 86_400 else {
            return "Not enough history yet: the log needs at least four days."
        }
        let window: TimeInterval = min(7 * 86_400, last.timeIntervalSince(first) / 2)
        let cutoff = last.addingTimeInterval(-window)
        let past = events.filter { $0.at < cutoff }
        let future = Set(events.filter { $0.at >= cutoff && !$0.isSkip }.map(\.id))
        let tracks = (try? DatabaseManager.shared.getAllTracks()) ?? []
        let (engine, _, _) = makeEngine(tracks: tracks, events: past, now: cutoff)
        let mixes = await Task.detached(priority: .userInitiated) { engine.madeForYou() }.value
        let byArtist = Dictionary(grouping: tracks, by: \.artistId)
        let artistOf = Dictionary(tracks.map { ($0.stableId, $0.artistId) }, uniquingKeysWith: { first, _ in first })

        var lines = ["Cutoff \(cutoff.formatted(date: .abbreviated, time: .omitted)), \(past.count) listens before, \(future.count) songs played after."]
        var totalHits = 0, totalSongs = 0, totalBaseline = 0
        for mix in mixes {
            let hits = mix.trackIds.filter(future.contains).count
            // Baseline: as many random songs by the same artists.
            let artists = Set(mix.trackIds.compactMap { artistOf[$0] ?? nil })
            let pool = artists.flatMap { byArtist[$0] ?? [] }.map(\.stableId).shuffled().prefix(mix.trackIds.count)
            let baseline = pool.filter(future.contains).count
            totalHits += hits; totalSongs += mix.trackIds.count; totalBaseline += baseline
            lines.append("\(mix.title): \(hits)/\(mix.trackIds.count) played (baseline \(baseline))")
        }
        let rate = totalSongs == 0 ? 0 : Double(totalHits) / Double(totalSongs)
        let baseRate = totalSongs == 0 ? 0 : Double(totalBaseline) / Double(totalSongs)
        let recall = future.isEmpty ? 0 : Double(Set(mixes.flatMap(\.trackIds)).intersection(future).count) / Double(future.count)
        lines.insert(String(format: "Hit rate %.0f%% vs baseline %.0f%% · recall %.0f%%", rate * 100, baseRate * 100, recall * 100), at: 1)
        return lines.joined(separator: "\n")
    }

    func play(_ mix: Mix, shuffled: Bool = false) {
        ListeningHistory.shared.recordSource(.mix(id: mix.id))
        let tracks = (try? DatabaseManager.shared.getTracksByStableIdsPreservingOrder(mix.trackIds)) ?? []
        // Shuffled, but never one artist twice in a row when it can be avoided.
        var generator = SeededGenerator(seed: UInt64.random(in: 0...UInt64.max))
        QuickPlay.start(shuffled ? MixEngine.spreadArtists(tracks, generator: &generator) : tracks, source: "mix:\(mix.id)")
    }
}

// MARK: - Mix views

/// A mix's cover: a 2x2 collage of its songs' artwork under a wash of the
/// mix's own colour, with its title set large across the bottom.
struct MixCover: View {
    let mix: Mix
    var showsTitle = true
    @State private var images: [UIImage] = []

    private var tint: Color { Color(hue: mix.hue, saturation: 0.65, brightness: 0.55) }

    var body: some View {
        GeometryReader { geometry in
            let side = geometry.size.width
            ZStack(alignment: .bottomLeading) {
                collage(side: side)

                if showsTitle {
                    // The mix's colour rises from the bottom behind its title
                    // and leaves the artwork above clear.
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.35),
                            .init(color: tint.opacity(0.75), location: 0.72),
                            .init(color: tint.opacity(0.95), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    Text(mix.title)
                        .font(.system(size: max(15, side * 0.11), weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .padding(side * 0.07)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius.artwork, style: .continuous))
        .accessibilityHidden(true)
        .task(id: mix.id) {
            let tracks = (try? DatabaseManager.shared.getTracksByStableIdsPreservingOrder(mix.coverTrackIds)) ?? []
            var loaded: [UIImage] = []
            for track in tracks {
                if let image = await ArtworkManager.shared.getThumbnail(for: track, maxPixelSize: 256) {
                    loaded.append(image)
                }
            }
            images = loaded
        }
    }

    @ViewBuilder
    private func collage(side: CGFloat) -> some View {
        if images.count >= 4 {
            let half = side / 2
            VStack(spacing: 0) {
                HStack(spacing: 0) { tile(images[0], half); tile(images[1], half) }
                HStack(spacing: 0) { tile(images[2], half); tile(images[3], half) }
            }
        } else if let first = images.first {
            tile(first, side)
        } else {
            tint
        }
    }

    private func tile(_ image: UIImage, _ side: CGFloat) -> some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: side, height: side)
            .clipped()
    }
}

/// A mix on a shelf: its cover, a play button, and what it is.
struct MixTile: View {
    let mix: Mix
    var width: CGFloat = 160

    var body: some View {
        NavigationLink(value: LibraryRoute.mix(id: mix.id)) {
            VStack(alignment: .leading, spacing: Design.Spacing.xs + 2) {
                MixCover(mix: mix)
                    // Top corner: at the bottom it sat on the mix's title.
                    .overlay(alignment: .topTrailing) {
                        TilePlayButton { MixStore.shared.play(mix) }
                            .padding(Design.Spacing.xs)
                    }
                Text(mix.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(height: 40, alignment: .topLeading)
            }
            .frame(width: width)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(mix.title)
        }
        .buttonStyle(PressableButtonStyle())
    }
}

/// A mix's own page: cover, Play / Shuffle, and its songs in order.
struct MixDetailView: View {
    let mixId: String
    @ObservedObject private var store = MixStore.shared
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var tracks: [Track] = []
    @State private var artistNames: [String: String] = [:]

    private var mix: Mix? { store.mix(id: mixId) }

    var body: some View {
        Group {
            if let mix {
                DetailPage {
                    VStack(spacing: Design.Spacing.s) {
                        DetailHeader(
                            title: mix.title,
                            subtitle: nil,
                            // The why line below already says what the subtitle would.
                            detail: [mix.subtitle == mix.why ? nil : mix.subtitle, Localized.songsCountOnly(tracks.count), DurationFormatter.totalLength(of: tracks)]
                                .compactMap { $0 }.joined(separator: " · "),
                            isPlayDisabled: tracks.isEmpty,
                            onPlay: { QuickPlay.start(tracks, source: "mix:\(mixId)") },
                            onShuffle: { QuickPlay.start(tracks.shuffled(), source: "mix:\(mixId)") }
                        ) {
                            MixCover(mix: mix, showsTitle: false)
                        }
                        // Why this mix: where it comes from, in the listener's own numbers.
                        if let why = mix.why, !why.isEmpty {
                            Text(why)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, Design.Spacing.l)
                                .padding(.bottom, Design.Spacing.s)
                        }
                    }
                } rows: {
                    Section {
                        ForEach(Array(tracks.enumerated()), id: \.element.stableId) { index, track in
                            LiveTrackRow(
                                track: track,
                                artistName: artistNames[track.stableId],
                                contextIdentity: "mix-\(mixId)-\(tracks.count)"
                            ) {
                                ListeningLog.shared.tagQueue("mix:\(mixId)", tracks: tracks)
                                Task { await appCoordinator.playerEngine.playTrack(at: index, in: tracks) }
                            }
                            .songListRow(track)
                        }
                    }
                }
            } else {
                CosmosEmptyState(systemImage: "sparkles", title: Localized.madeForYou)
            }
        }
        .background(ScreenSpecificBackgroundView(screen: .playlistDetail))
        .navigationTitle(mix?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: mixId) {
            guard let mix else { return }
            tracks = (try? DatabaseManager.shared.getTracksByStableIdsPreservingOrder(mix.trackIds)) ?? []
            artistNames = (try? DatabaseManager.shared.getArtistDisplayNames(
                forTrackStableIds: tracks.map(\.stableId),
                fallbackArtistIdsByStableId: tracks.reduce(into: [:]) { result, track in
                    if let artistId = track.artistId { result[track.stableId] = artistId }
                }
            )) ?? [:]
        }
    }
}
