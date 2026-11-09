import Foundation

// MARK: - Taste profile

/// How one song sounds, as far as the app can tell: its own tags first, and
/// its artist's (tags, or the on-device model's profile) where it has none.
/// Worked out once per build for the whole library.
struct SongFeatures {
    var artist: Int64?
    var genre: String?
    var year: Int?
    var energy: Double?
    var dynamics: Double?
    /// From the on-device analysis (`MusicFeatures.brightness`), else the artist's.
    var brightness: Double? = nil
}

/// One listen, as the taste profile reads it: plain values only, so the
/// profile can be built away from the app's types (and tested on its own).
struct TasteListen {
    let id: String
    let at: Date
    /// How much the listen says the listener likes the song (`Event.weight`).
    let weight: Double
    /// Fraction heard, nil for listens logged before that was recorded.
    let heard: Double?
    let skipped: Bool
    let source: String?
    let route: String?
}

/// What the listening log says about the listener: every session described
/// by what it sounded like and when and where it happened, and listener-wide
/// habits - who and what is played most, rising and fading, how keen they
/// are on songs they have never heard, how much they repeat.
///
/// Nothing here is a fixed category. Sessions are described by numbers
/// (genre shares, era, energy, dynamics, hour on a circle, weekend, output),
/// and `TasteModes` finds whatever groups those numbers fall into.
struct TasteProfile {
    /// A run of listens with no 30-minute pause.
    struct Session {
        var start: Date
        var end: Date
        /// Songs heard, not skipped, with how much they count: completion
        /// (`TasteListen.weight`, at least 0.2) added up over the session.
        var songs: [String: Double] = [:]
        /// Songs skipped early in this session, with how often.
        var skips: [String: Int] = [:]
        /// Listens that were not skips.
        var listens = 0
        /// Genre shares, summing to 1 over the songs whose genre is known.
        var genres: [String: Double] = [:]
        var year: Double?
        var energy: Double?
        var dynamics: Double?
        var brightness: Double?
        /// The mean of the listens' hours on a 24-hour circle, as sine and
        /// cosine - 23:00 and 01:00 are two hours apart, not twenty-two.
        /// Shorter than 1 when the session spans many hours.
        var hourSin = 0.0
        var hourCos = 0.0
        var weekend = false
        /// Output shares ("car", "headphones"...), summing to 1 when known.
        var routes: [String: Double] = [:]
        /// How much the session counts: recent sessions more, and sessions
        /// the listener chose more than the app's own mixes or a shuffle.
        var weight = 1.0
        /// The session as a point for clustering (`TasteProfile.vector`).
        var vector: [Double] = []
    }

    var sessions: [Session] = []
    /// Per song, the sessions it was heard in, by index into `sessions`.
    var sessionsOf: [String: [Int]] = [:]

    /// How readily the listener takes to songs they have never heard: the
    /// share of first listens heard at least halfway, 0...1, as the mean of
    /// a Beta(2, 3) prior updated with them - 0.4 with nothing to go on.
    var noveltySeeking = 0.4
    var firstListens = 0
    /// Share of listens that replay a song heard in the week before.
    var repeatTendency = 0.0
    /// Listens in a typical session (the median).
    var typicalSessionLength = 0
    /// Share of listens at each hour, 0...23.
    var hourShare = [Double](repeating: 0, count: 24)
    var weekendShare = 0.0
    var routeShare: [String: Double] = [:]
    /// Share of listening per genre and artist, recent (three-week
    /// half-life) and long-run (six-month half-life plus the lifetime record).
    var recentGenres: [String: Double] = [:]
    var longGenres: [String: Double] = [:]
    var recentArtists: [Int64: Double] = [:]
    var longArtists: [Int64: Double] = [:]
    /// Means over every listen, used where a session or song is untagged.
    var meanYear: Double?
    var meanEnergy: Double?
    var meanDynamics: Double?
    var meanBrightness: Double?
    /// The genres the session vectors spell out; the rest fold into "other".
    var vocabulary: [String] = []

    static let sessionGap: TimeInterval = 30 * 60
    static let routes = ["car", "headphones", "bluetooth", "speaker", "airplay"]

    // MARK: Building

    /// - Parameters:
    ///   - listens: oldest first.
    ///   - features: every song of the library.
    ///   - lifetime: per song, its long-run score from listens that rolled
    ///     off the log (`ListeningLog.Lifetime.score(at:)`).
    static func build(
        listens: [TasteListen],
        features: [String: SongFeatures],
        lifetime: [String: Double],
        now: Date,
        calendar: Calendar
    ) -> TasteProfile {
        var profile = TasteProfile()
        guard !listens.isEmpty else { return profile }

        func recency(_ date: Date, halfLife: Double) -> Double {
            pow(0.5, max(0, now.timeIntervalSince(date)) / 86_400 / halfLife)
        }
        func sourceWeight(_ source: String?) -> Double {
            guard let source else { return 1 }
            if source == "shuffle" { return 0.2 }
            if source.hasPrefix("mix:") || source.hasPrefix("radio:") { return 0.5 }
            return 1
        }

        // Listener-wide tallies, in one pass.
        var seen = Set(lifetime.keys)
        var firstFinished = 0
        var lastHeard: [String: Date] = [:]
        var repeats = 0
        var played = 0
        var weekendListens = 0
        var routeCounts: [String: Double] = [:]
        var routed = 0.0
        var yearSum = 0.0, yearCount = 0.0
        var energySum = 0.0, energyCount = 0.0
        var dynamicsSum = 0.0, dynamicsCount = 0.0
        var brightnessSum = 0.0, brightnessCount = 0.0
        for (id, score) in lifetime where score > 0 {
            guard let song = features[id] else { continue }
            if let genre = song.genre { profile.longGenres[genre, default: 0] += score }
            if let artist = song.artist { profile.longArtists[artist, default: 0] += score }
        }

        for listen in listens {
            let song = features[listen.id]
            if seen.insert(listen.id).inserted, let heard = listen.heard {
                profile.firstListens += 1
                if !listen.skipped && heard >= 0.5 { firstFinished += 1 }
            }
            guard !listen.skipped else { continue }
            played += 1
            if let last = lastHeard[listen.id], listen.at.timeIntervalSince(last) < 7 * 86_400 { repeats += 1 }
            lastHeard[listen.id] = listen.at
            profile.hourShare[calendar.component(.hour, from: listen.at)] += 1
            if calendar.isDateInWeekend(listen.at) { weekendListens += 1 }
            if let route = listen.route { routeCounts[route, default: 0] += 1; routed += 1 }
            let recent = recency(listen.at, halfLife: 21) * max(listen.weight, 0)
            let long = recency(listen.at, halfLife: 180) * max(listen.weight, 0)
            if let genre = song?.genre {
                profile.recentGenres[genre, default: 0] += recent
                profile.longGenres[genre, default: 0] += long
            }
            if let artist = song?.artist {
                profile.recentArtists[artist, default: 0] += recent
                profile.longArtists[artist, default: 0] += long
            }
            if let year = song?.year { yearSum += Double(year); yearCount += 1 }
            if let energy = song?.energy { energySum += energy; energyCount += 1 }
            if let dynamics = song?.dynamics { dynamicsSum += dynamics; dynamicsCount += 1 }
            if let brightness = song?.brightness { brightnessSum += brightness; brightnessCount += 1 }
        }
        profile.noveltySeeking = Double(firstFinished + 2) / Double(profile.firstListens + 5)
        profile.repeatTendency = played > 0 ? Double(repeats) / Double(played) : 0
        if played > 0 {
            profile.hourShare = profile.hourShare.map { $0 / Double(played) }
            profile.weekendShare = Double(weekendListens) / Double(played)
        }
        if routed > 0 { profile.routeShare = routeCounts.mapValues { $0 / routed } }
        profile.recentGenres = normalized(profile.recentGenres)
        profile.longGenres = normalized(profile.longGenres)
        profile.recentArtists = normalized(profile.recentArtists)
        profile.longArtists = normalized(profile.longArtists)
        profile.meanYear = yearCount > 0 ? yearSum / yearCount : nil
        profile.meanEnergy = energyCount > 0 ? energySum / energyCount : nil
        profile.meanDynamics = dynamicsCount > 0 ? dynamicsSum / dynamicsCount : nil
        profile.meanBrightness = brightnessCount > 0 ? brightnessSum / brightnessCount : nil

        // Sessions: split at 30 quiet minutes. Skips belong to the session
        // they happened in - they say what did not fit there.
        var current: Session?
        var tally = SessionTally()
        func close() {
            guard var session = current else { return }
            tally.finish(into: &session)
            if session.listens > 0 {
                let index = profile.sessions.count
                for id in session.songs.keys { profile.sessionsOf[id, default: []].append(index) }
                session.weight = (0.25 + recency(session.end, halfLife: 60)) * tally.sourceAverage
                profile.sessions.append(session)
            }
            current = nil
            tally = SessionTally()
        }
        for listen in listens {
            if let open = current, listen.at.timeIntervalSince(open.end) > sessionGap { close() }
            if current == nil {
                current = Session(start: listen.at, end: listen.at, weekend: calendar.isDateInWeekend(listen.at))
            }
            current?.end = listen.at
            if listen.skipped {
                current?.skips[listen.id, default: 0] += 1
                continue
            }
            let weight = max(listen.weight, 0.2)
            current?.songs[listen.id, default: 0] += weight
            current?.listens += 1
            let components = calendar.dateComponents([.hour, .minute], from: listen.at)
            let angle = (Double(components.hour ?? 0) + Double(components.minute ?? 0) / 60) / 24 * 2 * .pi
            tally.add(features[listen.id], weight: weight, angle: angle, route: listen.route, source: sourceWeight(listen.source))
        }
        close()

        let lengths = profile.sessions.map(\.listens).sorted()
        profile.typicalSessionLength = lengths.isEmpty ? 0 : lengths[lengths.count / 2]

        // The genres worth a dimension of their own: the most listened, a
        // dozen at most; the long tail shares one "other" dimension.
        var genreTotals: [String: Double] = [:]
        for session in profile.sessions {
            for (genre, share) in session.genres { genreTotals[genre, default: 0] += share * session.weight }
        }
        profile.vocabulary = genreTotals.sorted { ($0.value, $0.key) > ($1.value, $1.key) }.prefix(12).map(\.key)
        for index in profile.sessions.indices {
            profile.sessions[index].vector = profile.vector(for: profile.sessions[index])
        }
        return profile
    }

    /// Running sums for one session's sound and context.
    private struct SessionTally {
        var genres: [String: Double] = [:]
        var year = (sum: 0.0, weight: 0.0)
        var energy = (sum: 0.0, weight: 0.0)
        var dynamics = (sum: 0.0, weight: 0.0)
        var brightness = (sum: 0.0, weight: 0.0)
        var sin = 0.0, cos = 0.0, total = 0.0
        var routes: [String: Double] = [:]
        var source = 0.0
        var listens = 0.0

        var sourceAverage: Double { listens > 0 ? source / listens : 1 }

        mutating func add(_ song: SongFeatures?, weight: Double, angle: Double, route: String?, source: Double) {
            if let genre = song?.genre { genres[genre, default: 0] += weight }
            if let value = song?.year { year.sum += Double(value) * weight; year.weight += weight }
            if let value = song?.energy { energy.sum += value * weight; energy.weight += weight }
            if let value = song?.dynamics { dynamics.sum += value * weight; dynamics.weight += weight }
            if let value = song?.brightness { brightness.sum += value * weight; brightness.weight += weight }
            sin += Foundation.sin(angle) * weight
            cos += Foundation.cos(angle) * weight
            total += weight
            if let route { routes[route, default: 0] += 1 }
            self.source += source
            listens += 1
        }

        func finish(into session: inout Session) {
            session.genres = TasteProfile.normalized(genres)
            session.year = year.weight > 0 ? year.sum / year.weight : nil
            session.energy = energy.weight > 0 ? energy.sum / energy.weight : nil
            session.dynamics = dynamics.weight > 0 ? dynamics.sum / dynamics.weight : nil
            session.brightness = brightness.weight > 0 ? brightness.sum / brightness.weight : nil
            if total > 0 {
                session.hourSin = sin / total
                session.hourCos = cos / total
            }
            session.routes = TasteProfile.normalized(routes)
        }
    }

    static func normalized<Key: Hashable>(_ values: [Key: Double]) -> [Key: Double] {
        let total = values.values.reduce(0, +)
        guard total > 0 else { return [:] }
        return values.mapValues { $0 / total }
    }

    /// A session as a point: genre shares, then era, energy, dynamics,
    /// brightness, the hour on a circle, weekend and output - each scaled by how much it
    /// should count. Sound counts most: a mode is first what is played,
    /// then when and where. Unknown values take the listener's mean, so
    /// they pull no session anywhere.
    func vector(for session: Session) -> [Double] {
        var vector: [Double] = []
        vector.reserveCapacity(vocabulary.count + 12)
        var inVocabulary = 0.0
        for genre in vocabulary {
            let share = session.genres[genre] ?? 0
            inVocabulary += share
            vector.append(share)
        }
        vector.append(session.genres.isEmpty ? 0 : max(0, 1 - inVocabulary))
        // Era over five decades from 1960; energy and dynamics are 0...1.
        let year = session.year ?? meanYear ?? 1990
        vector.append((year - 1960) / 50 * 0.8)
        vector.append((session.energy ?? meanEnergy ?? 0.5) * 0.8)
        vector.append((session.dynamics ?? meanDynamics ?? 0.5) * 0.5)
        // Analysed songs only, so it counts for a little less than dynamics.
        vector.append((session.brightness ?? meanBrightness ?? 0.5) * 0.4)
        vector.append(session.hourSin * 0.4)
        vector.append(session.hourCos * 0.4)
        vector.append(session.weekend ? 0.35 : 0)
        for route in Self.routes { vector.append((session.routes[route] ?? 0) * 0.35) }
        return vector
    }

    // MARK: Reading

    /// Artists and genres by how much they are played: the top blends
    /// recent and long-run listening; rising leads recent over long-run,
    /// fading the other way round.
    func top<Key: Hashable & Comparable>(_ recent: [Key: Double], _ long: [Key: Double], count: Int = 5) -> [Key] {
        var blended: [(key: Key, value: Double)] = []
        for key in Set(recent.keys).union(long.keys) {
            let value: Double = 0.6 * (recent[key] ?? 0) + 0.4 * (long[key] ?? 0)
            blended.append((key, value))
        }
        blended.sort { ($0.value, $0.key) > ($1.value, $1.key) }
        return blended.prefix(count).map(\.key)
    }

    func rising<Key: Hashable & Comparable>(_ recent: [Key: Double], _ long: [Key: Double], count: Int = 5) -> [Key] {
        recent.filter { $0.value >= 0.02 }
            .map { ($0.key, $0.value - (long[$0.key] ?? 0)) }
            .filter { $0.1 > 0.01 }
            .sorted { ($0.1, $0.0) > ($1.1, $1.0) }.prefix(count).map(\.0)
    }

    func fading<Key: Hashable & Comparable>(_ recent: [Key: Double], _ long: [Key: Double], count: Int = 5) -> [Key] {
        long.filter { $0.value >= 0.02 }
            .map { ($0.key, $0.value - (recent[$0.key] ?? 0)) }
            .filter { $0.1 > 0.01 }
            .sorted { ($0.1, $0.0) > ($1.1, $1.0) }.prefix(count).map(\.0)
    }

    /// How alike each song is to `seeds` by when they are played: session
    /// k-nearest-neighbours over many seeds at once, each weighted - the
    /// cosine of shared sessions against how many sessions each song is in,
    /// so a song played everywhere does not top every list. A long session
    /// pairs everything with everything and counts for less, and a link
    /// seen in one session only is halved.
    func neighbours(of seeds: [String: Double], limit: Int = 300) -> [String: Double] {
        var sessionWeight: [Double] = []
        sessionWeight.reserveCapacity(sessions.count)
        for session in sessions {
            sessionWeight.append(session.songs.count > 1 ? session.weight / max(1, (Double(session.songs.count) / 20).squareRoot()) : 0)
        }
        func total(_ id: String) -> Double { (sessionsOf[id] ?? []).reduce(0) { $0 + sessionWeight[$1] } }
        var result: [String: Double] = [:]
        var totals: [String: Double] = [:]
        let seedWeight = seeds.values.reduce(0, +)
        guard seedWeight > 0 else { return [:] }
        for (seed, weight) in seeds {
            let seedTotal = total(seed)
            guard seedTotal > 0 else { continue }
            var shared: [String: (weight: Double, sessions: Int)] = [:]
            for index in sessionsOf[seed] ?? [] where sessionWeight[index] > 0 {
                for id in sessions[index].songs.keys where id != seed && seeds[id] == nil {
                    shared[id, default: (0, 0)].weight += sessionWeight[index]
                    shared[id, default: (0, 0)].sessions += 1
                }
            }
            for (id, together) in shared {
                let songTotal = totals[id] ?? total(id)
                totals[id] = songTotal
                guard songTotal > 0 else { continue }
                let cosine = together.weight / (seedTotal * songTotal).squareRoot()
                let evidence = Double(together.sessions) / Double(together.sessions + 1)
                result[id, default: 0] += cosine * evidence * weight / seedWeight
            }
        }
        guard result.count > limit else { return result }
        return Dictionary(uniqueKeysWithValues: result.sorted { ($0.value, $0.key) > ($1.value, $1.key) }.prefix(limit).map { ($0.key, $0.value) })
    }
}
