import Foundation

// MARK: - Listening modes

/// A way the listener listens that keeps coming back: a group of sessions
/// that sound alike and often happen at the same time or place - piano on
/// weekend mornings, rap in the car. Found in the log by `TasteModes`, never
/// chosen from a list: a listener has as many modes as their sessions show,
/// and none until there is enough history to tell.
struct ListeningMode: Codable, Equatable, Identifiable {
    /// "mode-" and a hash of what the mode is (`TasteModes.signature`), so
    /// the same habit keeps its id - and its name - from day to day.
    var id: String
    /// Genre shares over the mode's listening, the leading few.
    var genres: [String: Double]
    var year: Double?
    /// How far the mode's sessions spread around `year`, in years.
    var yearSpread: Double?
    var energy: Double?
    var dynamics: Double?
    /// 0 morning, 1 afternoon, 2 evening, 3 night - when its sessions
    /// gather around one time of day, nil when they are spread out.
    var dayPart: Int?
    /// True for a weekend habit, false for a weekday one, nil for both.
    var weekend: Bool?
    /// The output it is played on, when that sets it apart.
    var route: String?
    /// Artists most heard in it, the first leading.
    var topArtists: [Int64]
    var sessions: Int
    var listens: Int
    /// Its share of all listening, recent sessions counting more.
    var share: Double
    var firstPlayed: Date
    var lastPlayed: Date
    /// Sessions in the four weeks before the build.
    var recentSessions: Int
    /// Songs heard in it, by how much: completion and recency.
    var songs: [String: Double]
    /// When each of those was last heard in it.
    var songLast: [String: Date]
    /// Songs skipped early in it, with how often.
    var skips: [String: Int]
    /// Mean brightness of its listening (`MusicFeatures.brightness`), once
    /// enough of it is analysed. Last, with a default, so saved modes from
    /// before it still decode.
    var brightness: Double? = nil

    /// How close a song sits to the mode's sound, 0...1: its genre's share
    /// in the mode first, then era, energy, dynamics and brightness. A song
    /// with no tags at all scores in the middle - neither in nor out.
    func closeness(genre: String?, year: Int?, energy: Double?, dynamics: Double?, brightness: Double? = nil) -> Double {
        var score = 0.0
        if let top = genres.values.max(), top > 0 {
            if let genre { score += 0.5 * min((genres[genre] ?? 0) / top, 1) } else { score += 0.15 }
        } else {
            score += 0.25
        }
        if let year, let center = self.year {
            let tolerance = max(8, (yearSpread ?? 8) * 1.5)
            score += 0.2 * max(0, 1 - abs(Double(year) - center) / tolerance)
        } else {
            score += 0.08
        }
        if let energy, let center = self.energy {
            score += 0.2 * max(0, 1 - abs(energy - center) * 2.5)
        } else {
            score += 0.08
        }
        if let dynamics, let center = self.dynamics {
            score += 0.1 * max(0, 1 - abs(dynamics - center) * 2.5)
        } else {
            score += 0.04
        }
        // Only where both sides were analysed, and as a small share: songs
        // not analysed yet keep exactly the score they had, so the
        // thresholds callers apply (0.6, 0.75) mean what they meant.
        if let brightness, let center = self.brightness {
            score = score * 0.92 + 0.08 * max(0, 1 - abs(brightness - center) * 2.5)
        }
        return score
    }

    func closeness(_ song: SongFeatures?) -> Double {
        closeness(genre: song?.genre, year: song?.year, energy: song?.energy, dynamics: song?.dynamics, brightness: song?.brightness)
    }

    /// "calm", "mellow", "upbeat" or "intense".
    var energyLabel: String? {
        energy.map { $0 < 0.25 ? "calm" : $0 < 0.5 ? "mellow" : $0 < 0.75 ? "upbeat" : "intense" }
    }

    /// Played in the four weeks before the build.
    var isActive: Bool { recentSessions > 0 }

    /// The mode's sound, as a centre other songs can be measured against:
    /// a playlist's or a single song's, built the same way as a mode's.
    static func centroid(of songs: [(features: SongFeatures?, weight: Double)]) -> ListeningMode {
        var genres: [String: Double] = [:]
        var year = (0.0, 0.0), energy = (0.0, 0.0), dynamics = (0.0, 0.0), brightness = (0.0, 0.0)
        var years: [(Double, Double)] = []
        for (song, weight) in songs {
            guard let song else { continue }
            if let genre = song.genre { genres[genre, default: 0] += weight }
            if let value = song.year { year.0 += Double(value) * weight; year.1 += weight; years.append((Double(value), weight)) }
            if let value = song.energy { energy.0 += value * weight; energy.1 += weight }
            if let value = song.dynamics { dynamics.0 += value * weight; dynamics.1 += weight }
            if let value = song.brightness { brightness.0 += value * weight; brightness.1 += weight }
        }
        let meanYear = year.1 > 0 ? year.0 / year.1 : nil
        let spread = meanYear.map { mean in
            (years.reduce(0) { $0 + $1.1 * pow($1.0 - mean, 2) } / max(year.1, 0.001)).squareRoot()
        }
        return ListeningMode(
            id: "centroid", genres: TasteProfile.normalized(genres), year: meanYear, yearSpread: spread,
            energy: energy.1 > 0 ? energy.0 / energy.1 : nil, dynamics: dynamics.1 > 0 ? dynamics.0 / dynamics.1 : nil,
            dayPart: nil, weekend: nil, route: nil, topArtists: [], sessions: 0, listens: 0, share: 0,
            firstPlayed: .distantPast, lastPlayed: .distantPast, recentSessions: 0, songs: [:], songLast: [:], skips: [:],
            brightness: brightness.1 > 0 ? brightness.0 / brightness.1 : nil
        )
    }
}

/// The listener at a glance, for the on-device model and the debug view.
struct TasteSummary: Codable, Equatable {
    var topArtists: [String] = []
    var risingArtists: [String] = []
    var fadingArtists: [String] = []
    var topGenres: [String] = []
    var risingGenres: [String] = []
    var fadingGenres: [String] = []
    var noveltySeeking = 0.4
    var repeatTendency = 0.0
    var typicalSessionLength = 0
    var sessions = 0
    /// How well the sessions split into modes (silhouette), and into how many.
    var silhouette = 0.0
    var clusters = 0
}

/// Finds the listener's modes: k-means over the session vectors, recent
/// sessions weighing more, with k from 2 to 6 chosen by the silhouette -
/// how much closer each session is to its own group than to the next. When
/// no split stands out, there are no modes, and Made for You falls back to
/// artist clusters. Seeded, so the same log always gives the same modes.
enum TasteModes {
    static let minimumSessions = 5
    static let minimumSongs = 20
    /// Below this, the groups k-means returns are not really there.
    static let minimumSilhouette = 0.12
    /// Sessions considered, the most recent: k-means on a few thousand
    /// points with a few iterations takes milliseconds.
    static let sessionLimit = 3000

    struct Result {
        var modes: [ListeningMode] = []
        /// Per session of the profile, the mode it belongs to, by index.
        var membership: [Int: Int] = [:]
        var silhouette = 0.0
        var clusters = 0
    }

    static func find(in profile: TasteProfile, features: [String: SongFeatures], now: Date, calendar: Calendar) -> Result {
        // Sessions of three listens or more: one or two songs say little
        // about a way of listening.
        let eligible = profile.sessions.indices.filter { profile.sessions[$0].listens >= 3 }.suffix(sessionLimit)
        let indices = Array(eligible)
        guard indices.count >= minimumSessions * 2 else { return Result() }
        let points = indices.map { profile.sessions[$0].vector }
        let weights = indices.map { profile.sessions[$0].weight }

        var best: (k: Int, assignment: [Int], score: Double)?
        let maxK = min(6, indices.count / minimumSessions)
        guard maxK >= 2 else { return Result() }
        for k in 2...maxK {
            let assignment = cluster(points, weights: weights, k: k)
            // A mild cost per group: of two splits nearly as clear, the
            // simpler one is the truer.
            let score = silhouette(points, assignment: assignment) - 0.01 * Double(k)
            if best == nil || score > best!.score { best = (k, assignment, score) }
        }
        guard let best, best.score + 0.01 * Double(best.k) >= minimumSilhouette else {
            return Result(silhouette: best.map { $0.score + 0.01 * Double($0.k) } ?? 0, clusters: 0)
        }

        var groups: [Int: [Int]] = [:]
        for (slot, group) in best.assignment.enumerated() { groups[group, default: []].append(indices[slot]) }
        let totalWeight = weights.reduce(0, +)
        var result = Result(silhouette: best.score + 0.01 * Double(best.k), clusters: best.k)
        var usedIds = Set<String>()
        for group in groups.keys.sorted() {
            guard let members = groups[group], members.count >= minimumSessions,
                  var mode = describe(members, in: profile, features: features, totalWeight: totalWeight, now: now, calendar: calendar),
                  mode.songs.count >= minimumSongs else { continue }
            mode.id = uniqueId(for: mode, taken: &usedIds)
            let index = result.modes.count
            for member in members { result.membership[member] = index }
            result.modes.append(mode)
        }
        return result
    }

    // MARK: Clustering

    /// Weighted k-means (Lloyd), started by k-means++ from a fixed seed and
    /// run twice from different starts, keeping the tighter result.
    static func cluster(_ points: [[Double]], weights: [Double], k: Int) -> [Int] {
        var bestAssignment: [Int] = []
        var bestCost = Double.infinity
        for attempt in 0..<2 {
            var random = TasteRandom(seed: 0x7A57E_0000 &+ UInt64(k * 7 + attempt))
            var centers = seedCenters(points, weights: weights, k: k, random: &random)
            var assignment = [Int](repeating: 0, count: points.count)
            for _ in 0..<20 {
                var changed = false
                for (index, point) in points.enumerated() {
                    let nearest = nearestCenter(point, centers)
                    if nearest != assignment[index] { assignment[index] = nearest; changed = true }
                }
                var sums = [[Double]](repeating: [Double](repeating: 0, count: points[0].count), count: k)
                var mass = [Double](repeating: 0, count: k)
                for (index, point) in points.enumerated() {
                    let group = assignment[index]
                    mass[group] += weights[index]
                    for d in point.indices { sums[group][d] += point[d] * weights[index] }
                }
                for group in 0..<k where mass[group] > 0 {
                    centers[group] = sums[group].map { $0 / mass[group] }
                }
                if !changed { break }
            }
            var cost = 0.0
            for (index, point) in points.enumerated() { cost += weights[index] * distance(point, centers[assignment[index]]) }
            if cost < bestCost {
                bestCost = cost
                bestAssignment = assignment
            }
        }
        return bestAssignment
    }

    private static func seedCenters(_ points: [[Double]], weights: [Double], k: Int, random: inout TasteRandom) -> [[Double]] {
        var centers = [points[Int(random.next() % UInt64(points.count))]]
        var nearest = points.map { distance($0, centers[0]) }
        while centers.count < k {
            let total = zip(nearest, weights).reduce(0) { $0 + $1.0 * $1.1 }
            guard total > 0 else { centers.append(points[Int(random.next() % UInt64(points.count))]); continue }
            var target = random.unit() * total
            var chosen = points.count - 1
            for index in points.indices {
                target -= nearest[index] * weights[index]
                if target <= 0 { chosen = index; break }
            }
            centers.append(points[chosen])
            for index in points.indices { nearest[index] = min(nearest[index], distance(points[index], points[chosen])) }
        }
        return centers
    }

    private static func nearestCenter(_ point: [Double], _ centers: [[Double]]) -> Int {
        var best = 0
        var bestDistance = Double.infinity
        for (index, center) in centers.enumerated() {
            let value = distance(point, center)
            if value < bestDistance { bestDistance = value; best = index }
        }
        return best
    }

    /// Squared Euclidean distance.
    static func distance(_ a: [Double], _ b: [Double]) -> Double {
        var total = 0.0
        for index in a.indices {
            let difference = a[index] - b[index]
            total += difference * difference
        }
        return total
    }

    /// The mean silhouette over at most 400 sessions spread evenly through
    /// the log: for each, (b - a) / max(a, b), with a its mean distance to
    /// its own group and b to the nearest other group.
    static func silhouette(_ points: [[Double]], assignment: [Int]) -> Double {
        let step = max(1, points.count / 400)
        let sample = Array(stride(from: 0, to: points.count, by: step))
        let groups = Set(sample.map { assignment[$0] })
        guard groups.count > 1 else { return 0 }
        var total = 0.0
        var counted = 0
        for i in sample {
            var sums: [Int: (Double, Int)] = [:]
            for j in sample where j != i {
                let value = distance(points[i], points[j]).squareRoot()
                sums[assignment[j], default: (0, 0)].0 += value
                sums[assignment[j], default: (0, 0)].1 += 1
            }
            guard let own = sums[assignment[i]], own.1 > 0 else { continue }
            let a = own.0 / Double(own.1)
            let b = sums.filter { $0.key != assignment[i] && $0.value.1 > 0 }.map { $0.value.0 / Double($0.value.1) }.min() ?? a
            let largest = max(a, b)
            total += largest > 0 ? (b - a) / largest : 0
            counted += 1
        }
        return counted > 0 ? total / Double(counted) : 0
    }

    // MARK: Describing

    /// What a group of sessions is: sound, time, place, artists and songs,
    /// all read off its own sessions.
    static func describe(_ members: [Int], in profile: TasteProfile, features: [String: SongFeatures],
                         totalWeight: Double, now: Date, calendar: Calendar) -> ListeningMode? {
        guard let first = members.first else { return nil }
        var genres: [String: Double] = [:]
        var year = (0.0, 0.0), energy = (0.0, 0.0), dynamics = (0.0, 0.0), brightness = (0.0, 0.0)
        var years: [(Double, Double)] = []
        var sin = 0.0, cos = 0.0, weight = 0.0
        var weekendCount = 0
        var routes: [String: Double] = [:]
        var songs: [String: Double] = [:]
        var songLast: [String: Date] = [:]
        var skips: [String: Int] = [:]
        var artists: [Int64: Double] = [:]
        var listens = 0
        var firstPlayed = profile.sessions[first].start
        var lastPlayed = profile.sessions[first].end
        var recent = 0
        let month = now.addingTimeInterval(-28 * 86_400)
        for index in members {
            let session = profile.sessions[index]
            let w = session.weight
            weight += w
            for (genre, share) in session.genres { genres[genre, default: 0] += share * w }
            if let value = session.year { year.0 += value * w; year.1 += w; years.append((value, w)) }
            if let value = session.energy { energy.0 += value * w; energy.1 += w }
            if let value = session.dynamics { dynamics.0 += value * w; dynamics.1 += w }
            if let value = session.brightness { brightness.0 += value * w; brightness.1 += w }
            sin += session.hourSin * w
            cos += session.hourCos * w
            if session.weekend { weekendCount += 1 }
            for (route, share) in session.routes { routes[route, default: 0] += share }
            for (id, amount) in session.songs {
                songs[id, default: 0] += amount * w
                songLast[id] = max(songLast[id] ?? .distantPast, session.end)
                if let artist = features[id]?.artist { artists[artist, default: 0] += amount * w }
            }
            for (id, count) in session.skips { skips[id, default: 0] += count }
            listens += session.listens
            firstPlayed = min(firstPlayed, session.start)
            lastPlayed = max(lastPlayed, session.end)
            if session.end >= month { recent += 1 }
        }
        guard weight > 0 else { return nil }
        let meanYear = year.1 > 0 ? year.0 / year.1 : nil
        let spread = meanYear.map { mean in
            (years.reduce(0) { $0 + $1.1 * pow($1.0 - mean, 2) } / max(year.1, 0.001)).squareRoot()
        }

        // A time of day only when the sessions gather there: the mean
        // resultant length of their hours on the circle is high.
        let resultant = (sin * sin + cos * cos).squareRoot() / weight
        var dayPart: Int?
        if resultant >= 0.5 {
            var hour = atan2(sin, cos) / (2 * .pi) * 24
            if hour < 0 { hour += 24 }
            dayPart = Self.dayPart(ofHour: Int(hour))
        }
        // Weekends hold about 2/7 of the days; a mode is a weekend one only
        // when its share is well above the listener's own.
        let weekendShare = Double(weekendCount) / Double(members.count)
        var weekend: Bool?
        if weekendShare >= max(0.6, profile.weekendShare + 0.25) {
            weekend = true
        } else if weekendShare <= 0.08, profile.weekendShare >= 0.2 {
            weekend = false
        }
        // An output only when it sets the mode apart from listening overall.
        let routeTotal = routes.values.reduce(0, +)
        var route: String?
        if routeTotal > 0, let top = routes.max(by: { ($0.value, $0.key) < ($1.value, $1.key) }) {
            let share = top.value / routeTotal
            if share >= 0.6, share >= (profile.routeShare[top.key] ?? 0) + 0.2 { route = top.key }
        }

        let keptSongs = songs.sorted { ($0.value, $0.key) > ($1.value, $1.key) }.prefix(300)
        let keptIds = Set(keptSongs.map(\.key))
        return ListeningMode(
            id: "",
            genres: Dictionary(uniqueKeysWithValues: TasteProfile.normalized(genres)
                .sorted { ($0.value, $0.key) > ($1.value, $1.key) }.prefix(6).filter { $0.value >= 0.04 }.map { ($0.key, $0.value) }),
            year: meanYear,
            yearSpread: spread,
            energy: energy.1 > 0 ? energy.0 / energy.1 : nil,
            dynamics: dynamics.1 > 0 ? dynamics.0 / dynamics.1 : nil,
            dayPart: dayPart,
            weekend: weekend,
            route: route,
            topArtists: artists.sorted { ($0.value, $0.key) > ($1.value, $1.key) }.prefix(6).map(\.key),
            sessions: members.count,
            listens: listens,
            share: totalWeight > 0 ? weight / totalWeight : 0,
            firstPlayed: firstPlayed,
            lastPlayed: lastPlayed,
            recentSessions: recent,
            songs: Dictionary(uniqueKeysWithValues: keptSongs.map { ($0.key, $0.value) }),
            songLast: songLast.filter { keptIds.contains($0.key) },
            skips: skips,
            brightness: brightness.1 > 0 ? brightness.0 / brightness.1 : nil
        )
    }

    static func dayPart(ofHour hour: Int) -> Int {
        switch hour {
        case 5..<12: return 0
        case 12..<18: return 1
        case 18..<23: return 2
        default: return 3
        }
    }

    /// What the mode is in a few words - leading genre or artist, time,
    /// weekend, output - for its id. Small shifts in its songs leave this
    /// alone, so the id holds while the habit does.
    static func signature(of mode: ListeningMode, depth: Int = 1) -> String {
        let genres = mode.genres.sorted { ($0.value, $0.key) > ($1.value, $1.key) }.map(\.key)
        var sound = Array(genres.prefix(depth))
        if sound.isEmpty { sound = mode.topArtists.prefix(depth).map { "a\($0)" } }
        if depth > 1 { sound += mode.topArtists.prefix(1).map { "a\($0)" } }
        let time = mode.dayPart.map(String.init) ?? "x"
        let days = mode.weekend.map { $0 ? "we" : "wd" } ?? ""
        return ([sound.joined(separator: "+"), time, days, mode.route ?? ""]).joined(separator: "|")
    }

    private static func uniqueId(for mode: ListeningMode, taken: inout Set<String>) -> String {
        for depth in 1...3 {
            let id = "mode-" + hash(signature(of: mode, depth: depth))
            if taken.insert(id).inserted { return id }
        }
        var id = "mode-" + hash(signature(of: mode, depth: 3))
        var suffix = 2
        while !taken.insert("\(id)-\(suffix)").inserted { suffix += 1 }
        id += "-\(suffix)"
        return id
    }

    /// FNV-1a: the same text gives the same id on every launch, which
    /// Swift's own hashing does not promise.
    static func hash(_ text: String) -> String {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return String(value & 0xFFFF_FFFF, radix: 16)
    }
}

/// SplitMix64, kept here so the profile code stands on its own.
struct TasteRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
