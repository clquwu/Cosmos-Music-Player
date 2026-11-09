import Foundation

// MARK: - Taste in the mixes

/// Everything the taste profile gives one build: worked out once and shared
/// by Made for You and Rediscover.
struct TasteContext {
    let features: [String: SongFeatures]
    let profile: TasteProfile
    /// Every mode found, active or faded.
    let modes: [ListeningMode]
    let summary: TasteSummary
}

/// Made for You, with the longer list each mode mix was cut from - what the
/// on-device model may re-rank (`TasteCurator.rerank`).
struct MadeForYouResult {
    var mixes: [Mix]
    var shortlists: [String: [String]] = [:]
}

extension MixEngine {
    /// Every song's features: its own tags, else its artist's.
    func songFeatures(traits: [Int64: Traits]) -> [String: SongFeatures] {
        var result: [String: SongFeatures] = [:]
        result.reserveCapacity(tracks.count)
        var genreCache: [String: String?] = [:]
        // Once per artist, not once per song.
        let mainGenre = traits.compactMapValues { $0.genres.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key }
        for track in tracks {
            let artistTraits = track.artistId.flatMap { traits[$0] }
            // An artist's decade stands for the middle of it.
            let year = MusicFeatures.year(of: track, albumYear: track.albumId.flatMap { albumYears[$0] })
                ?? artistTraits?.decade.map { $0 + 5 }
            result[track.stableId] = SongFeatures(
                artist: track.artistId,
                genre: Self.genre(track.genre, cache: &genreCache) ?? track.artistId.flatMap { mainGenre[$0] },
                year: year,
                energy: MusicFeatures.energy(of: track) ?? artistTraits?.energy,
                dynamics: MusicFeatures.dynamics(of: track) ?? artistTraits?.dynamics,
                brightness: MusicFeatures.brightness(of: track) ?? artistTraits?.brightness
            )
        }
        return result
    }

    /// The profile without the modes: what a song or playlist mix needs.
    func tasteProfile() -> (features: [String: SongFeatures], profile: TasteProfile) {
        var byArtist: [Int64: [Track]] = [:]
        for track in tracks {
            if let artistId = track.artistId { byArtist[artistId, default: []].append(track) }
        }
        let features = songFeatures(traits: traits(for: byArtist))
        let listens = events.sorted { $0.at < $1.at }.map {
            TasteListen(id: $0.id, at: $0.at, weight: $0.weight, heard: $0.heard, skipped: $0.isSkip, source: $0.source, route: $0.route)
        }
        let profile = TasteProfile.build(
            listens: listens,
            features: features,
            lifetime: lifetime.mapValues { $0.score(at: now) },
            now: now,
            calendar: calendar
        )
        return (features, profile)
    }

    func tasteContext() -> TasteContext {
        let (features, profile) = tasteProfile()
        let found = TasteModes.find(in: profile, features: features, now: now, calendar: calendar)
        func names(_ ids: [Int64]) -> [String] {
            var seen = Set<String>()
            return ids.compactMap { artistNames[$0] }.filter { seen.insert(ArtistProfileStore.key(for: $0)).inserted }
        }
        var summary = TasteSummary()
        summary.topArtists = names(profile.top(profile.recentArtists, profile.longArtists))
        summary.risingArtists = names(profile.rising(profile.recentArtists, profile.longArtists))
        summary.fadingArtists = names(profile.fading(profile.recentArtists, profile.longArtists))
        summary.topGenres = profile.top(profile.recentGenres, profile.longGenres)
        summary.risingGenres = profile.rising(profile.recentGenres, profile.longGenres, count: 3)
        summary.fadingGenres = profile.fading(profile.recentGenres, profile.longGenres, count: 3)
        summary.noveltySeeking = profile.noveltySeeking
        summary.repeatTendency = profile.repeatTendency
        summary.typicalSessionLength = profile.typicalSessionLength
        summary.sessions = profile.sessions.count
        summary.silhouette = found.silhouette
        summary.clusters = found.clusters
        return TasteContext(features: features, profile: profile, modes: found.modes, summary: summary)
    }

    /// How much of a mix should be songs never played, from how readily
    /// this listener takes to new songs: 10 % for someone who skips most
    /// first listens, up to 45 % for someone who finishes them.
    static func noveltyShare(_ noveltySeeking: Double) -> Double {
        min(max(0.1 + 0.35 * noveltySeeking, 0.1), 0.45)
    }

    // MARK: Modes today

    /// The active modes, those that fit now first: a mode's share of the
    /// listening, raised when its usual time, days or output are now's, and
    /// by how much it was played lately.
    func modesForToday(_ modes: [ListeningMode]) -> [ListeningMode] {
        Self.modesFitting(modes, dayPart: Self.dayPart(of: now, calendar: calendar),
                          weekend: calendar.isDateInWeekend(now), route: currentRoute)
    }

    /// `modesForToday` for any moment: "something for tonight" asks about
    /// the evening while it is still afternoon.
    static func modesFitting(_ modes: [ListeningMode], dayPart part: Int, weekend: Bool, route currentRoute: String?) -> [ListeningMode] {
        modes.filter(\.isActive).map { mode -> (ListeningMode, Double) in
            var fit = 1.0
            if mode.dayPart == part { fit += 0.6 }
            if let modeWeekend = mode.weekend { fit += modeWeekend == weekend ? 0.3 : -0.3 }
            if let route = mode.route, route == currentRoute { fit += 0.4 }
            let lately = 0.5 + Double(min(mode.recentSessions, 10)) / 10
            return (mode, mode.share * fit * lately)
        }
        .sorted { ($0.1, $0.0.id) > ($1.1, $1.0.id) }
        .map(\.0)
    }

    /// Where a mode mix finds its songs: the mixable library, by artist and
    /// by genre, worked out once for all the modes.
    struct ModePool {
        let byId: [String: Track]
        let byArtist: [Int64: [Track]]
        let byGenre: [String: [Track]]
    }

    // MARK: Mode mixes

    /// A mix for one listening mode. Its songs come from what was heard in
    /// the mode's sessions, songs played in the same sittings as its core
    /// songs (session k-nearest-neighbours), and songs - unplayed ones too -
    /// by its artists and in its genres that sound like it. Each is scored
    /// on how close it sits to the mode's sound, how it was received in the
    /// mode, and how much the listener likes it; songs skipped in the mode
    /// stay out. The pick weighs fit against repetition (MMR), gives new
    /// songs the share this listener likes, and is ordered to flow.
    func modeMix(
        _ mode: ListeningMode,
        title: String,
        taste: TasteContext,
        signals: Signals,
        pool: ModePool,
        excluding used: Set<String>,
        lessons: Set<Int64>
    ) -> (mix: Mix, shortlist: [String])? {
        let seedHash = mode.id.utf8.reduce(UInt64(0)) { $0 &* 31 &+ UInt64($1) }
        var generator = SeededGenerator(seed: Self.daySeed(now) ^ seedHash)
        let twoDays = now.addingTimeInterval(-2 * 86_400)

        // The mode's core: its most heard songs, and what is played with them.
        let core = mode.songs.sorted { ($0.value, $0.key) > ($1.value, $1.key) }.prefix(12)
        let neighbours = taste.profile.neighbours(of: Dictionary(uniqueKeysWithValues: core.map { ($0.key, $0.value) }), limit: 200)
        let heardTop = core.first?.value ?? 1

        var ids = Set(mode.songs.keys).union(neighbours.keys)
        for artist in mode.topArtists.prefix(6) {
            for track in pool.byArtist[artist] ?? [] { ids.insert(track.stableId) }
        }
        let leading = mode.genres.sorted { ($0.value, $0.key) > ($1.value, $1.key) }.prefix(2).map(\.key)
        for genre in leading {
            // Library order, capped: a genre holding half of 50 000 songs
            // still costs a few milliseconds.
            for track in (pool.byGenre[genre] ?? []).prefix(4000) { ids.insert(track.stableId) }
        }

        var candidates: [Candidate] = []
        var fresh = Set<String>()
        for id in ids {
            guard !used.contains(id), !signals.rejected.contains(id), let track = pool.byId[id] else { continue }
            if let artist = track.artistId, lessons.contains(artist) { continue }
            let features = taste.features[id]
            let closeness = mode.closeness(features)
            let heard = min((mode.songs[id] ?? 0) / max(heardTop, 0.001) * 3, 1)
            let together = min((neighbours[id] ?? 0) * 2, 1)
            let skips = mode.skips[id] ?? 0
            // Skipped here more than once and never heard here: not this mode's.
            if skips >= 2 && heard == 0 { continue }
            // Neither heard in the mode nor played alongside it: it must at
            // least sound like it, or the mix drifts out of the mode.
            if heard == 0 && together < 0.1 && closeness < 0.6 { continue }
            var score = 1.2 * closeness + 0.9 * heard + 0.8 * together
            score += 0.15 * min(max(signals.trackScore[id] ?? 0, -1), 3)
            if favorites.contains(id) { score += 0.3 }
            score -= 0.4 * Double(skips)
            if (signals.lastPlayed[id] ?? .distantPast) > twoDays { score -= 0.3 }
            score += Double.random(in: 0..<0.25, using: &generator)
            if signals.plays[id] == nil && !favorites.contains(id) { fresh.insert(id) }
            candidates.append(Candidate(track: track, relevance: score, genre: features?.genre, year: features?.year, energy: features?.energy))
        }
        guard candidates.count >= 15 else { return nil }
        candidates.sort { ($0.relevance, $0.track.stableId) > ($1.relevance, $1.track.stableId) }

        // New songs: the listener's own appetite for them, and what this
        // mix's new songs taught - the mean of the two.
        let share = (Self.noveltyShare(taste.profile.noveltySeeking) + signals.discoveryShare(for: mode.id)) / 2
        let shortlistSize = 60
        let picked = Self.pickVaried(
            Array(candidates.prefix(400)),
            count: shortlistSize,
            fresh: fresh,
            freshLimit: Int((Double(shortlistSize) * share).rounded()),
            artistLimit: max(5, Self.mixSize / 4)
        )
        guard picked.count >= 15 else { return nil }
        let familiar = Set(signals.trackScore.filter { $0.value > 0 }.keys).union(favorites)
        let ordered = Self.flowOrder(Array(picked.prefix(Self.mixSize)), familiar: familiar, generator: &generator)

        var mix = Self.mix(id: mode.id, title: title, subtitle: "", tracks: ordered, hue: Double(seedHash % 360) / 360)
        mix.why = TasteWords.modeWhy(mode)
        mix.subtitle = mix.why ?? ""
        var albums: [String] = []
        for track in ordered {
            guard albums.count < 3, let album = track.albumId.flatMap({ albumTitles[$0] }), !albums.contains(album) else { continue }
            albums.append(album)
        }
        // Keyed by the mode, so a name given once stays with the habit.
        mix.naming = MixNamingContext(
            key: mode.id,
            artists: Array(mode.topArtists.prefix(4).compactMap { artistNames[$0] }),
            songs: ordered.prefix(8).map(\.title),
            albums: albums,
            styles: leading,
            decade: mode.year.map { Int($0) / 10 * 10 },
            energy: mode.energyLabel
        )
        return (mix, picked.map(\.stableId))
    }

    /// One mode's mix outside a Made for You build - for "play something
    /// for now" when the mode that fits has no mix on the shelf today. The
    /// profile without the clustering (the mode is already known), and no
    /// songs held back for other mixes: this one plays on its own.
    func modeMix(for mode: ListeningMode) -> Mix? {
        let (features, profile) = tasteProfile()
        let taste = TasteContext(features: features, profile: profile, modes: [mode], summary: TasteSummary())
        let signals = self.signals()
        var byId: [String: Track] = [:]
        var byArtist: [Int64: [Track]] = [:]
        var byGenre: [String: [Track]] = [:]
        for track in mixable where !signals.rejected.contains(track.stableId) {
            byId[track.stableId] = track
            if let artist = track.artistId { byArtist[artist, default: []].append(track) }
            if let genre = features[track.stableId]?.genre { byGenre[genre, default: []].append(track) }
        }
        let lessons = (mixLessons[mode.id] ?? []).union(learnedMixLessons()[mode.id] ?? [])
        return modeMix(mode, title: modeTitles([mode])[mode.id] ?? Localized.madeForYou, taste: taste, signals: signals,
                       pool: ModePool(byId: byId, byArtist: byArtist, byGenre: byGenre), excluding: [], lessons: lessons)?.mix
    }

    /// A name for each mode's mix without the model: its leading genre,
    /// else when or where it is played, else its leading artist - and, when
    /// two modes would share a name, the time or a second genre for the
    /// later one.
    func modeTitles(_ modes: [ListeningMode]) -> [String: String] {
        var titles: [String: String] = [:]
        var taken = Set<String>()
        for mode in modes {
            let genres = mode.genres.sorted { ($0.value, $0.key) > ($1.value, $1.key) }.map(\.key)
            var options: [String] = []
            if let genre = genres.first { options.append(String(format: Localized.mixFormat, MusicFeatures.displayGenre(genre))) }
            if let context = Self.modeContextTitle(mode) { options.append(context) }
            if genres.count >= 2, mode.genres[genres[1]] ?? 0 >= 0.15 {
                options.append(String(format: Localized.mixPairFormat, MusicFeatures.displayGenre(genres[0]), MusicFeatures.displayGenre(genres[1])))
            }
            if let artist = mode.topArtists.first.flatMap({ artistNames[$0] }) { options.append(String(format: Localized.mixFormat, artist)) }
            let title = options.first { !taken.contains($0.lowercased()) } ?? options.first ?? Localized.madeForYou
            taken.insert(title.lowercased())
            titles[mode.id] = title
        }
        return titles
    }

    /// As `TasteWords.contextPhrase`: the car first, then the time, then the output.
    static func modeContextTitle(_ mode: ListeningMode) -> String? {
        if mode.route == "car" { return contextTitle("route-car") }
        if let part = mode.dayPart {
            if mode.weekend == true { return contextTitle("weekend-\(part)") }
            return [Localized.yourMornings, Localized.yourAfternoons, Localized.yourEvenings, Localized.yourNights][part]
        }
        return mode.route.flatMap { contextTitle("route-\($0)") }
    }

    /// MMR as in `pickVaried`, without a seed, and with a cap on songs not
    /// played yet and on any one artist: each next song is the best 0.7 x
    /// fit - 0.3 x its overlap with the closest song already in.
    static func pickVaried(_ candidates: [Candidate], count: Int, fresh: Set<String>, freshLimit: Int, artistLimit: Int) -> [Track] {
        let lambda = 0.7
        let top = max(candidates.map(\.relevance).max() ?? 1, 0.001)
        var overlap = [Double](repeating: 0, count: candidates.count)
        var open = Array(candidates.indices)
        var chosen: [Track] = []
        var perAlbum: [Int64: Int] = [:]
        var perArtist: [Int64: Int] = [:]
        var freshCount = 0
        var versions = VersionGuard()
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
            let isFresh = fresh.contains(track.stableId)
            if isFresh, freshCount >= freshLimit { continue }
            if let artist = track.artistId, perArtist[artist, default: 0] >= artistLimit { continue }
            if let albumId = track.albumId, perAlbum[albumId, default: 0] >= 3 { continue }
            guard versions.admit(track) else { continue }
            if let albumId = track.albumId { perAlbum[albumId, default: 0] += 1 }
            if let artist = track.artistId { perArtist[artist, default: 0] += 1 }
            if isFresh { freshCount += 1 }
            chosen.append(track)
            for index in open { overlap[index] = max(overlap[index], candidates[index].overlap(with: picked)) }
        }
        return chosen
    }

    // MARK: Fresh Finds

    /// The mode Fresh Finds and "something for now" lean on when nothing
    /// else decides: the active mode with the largest share, played lately.
    static func strongestMode(_ modes: [ListeningMode]) -> ListeningMode? {
        modes.filter(\.isActive).max { a, b in
            func weight(_ mode: ListeningMode) -> Double { mode.share * (0.5 + Double(min(mode.recentSessions, 10)) / 10) }
            return (weight(a), a.id) < (weight(b), b.id)
        }
    }

    /// Songs in the library never played - not once, not even skipped -
    /// that sound like the way the listener listens most these days: their
    /// strongest recent mode, or, before there are modes, the songs they
    /// play and like most. Ranked by how close each sits to that sound, then
    /// by how much the listener loves its artist and album - a new song by a
    /// favourite is the safest first listen there is - picked for variety
    /// (MMR, three per album at most) and ordered to flow. Nil when fewer
    /// than 15 fit: a thin Fresh Finds is a list of leftovers.
    func freshFindsMix(taste: TasteContext?, signals: Signals, tracks: [Track], traits: [Int64: Traits],
                       excluding used: Set<String>) -> Mix? {
        let features = taste?.features ?? songFeatures(traits: traits)
        let mode = taste.flatMap { Self.strongestMode($0.modes) }

        // How much each artist and album is loved: plays (with recency, as
        // trackScore weighs them) and likes, each scaled to the most loved.
        var artistLove: [Int64: Double] = [:]
        var albumLove: [Int64: Double] = [:]
        let byId = self.byId
        func love(_ id: String, _ amount: Double) {
            guard amount > 0, let track = byId[id] else { return }
            if let artist = track.artistId { artistLove[artist, default: 0] += amount }
            if let album = track.albumId { albumLove[album, default: 0] += amount }
        }
        for (id, score) in signals.trackScore { love(id, score) }
        for id in favorites { love(id, 1) }
        let topArtistLove = max(artistLove.values.max() ?? 1, 0.001)
        let topAlbumLove = max(albumLove.values.max() ?? 1, 0.001)

        // What to sound like: the mode, or the sound of the most loved songs.
        let target: ListeningMode
        if let mode {
            target = mode
        } else {
            var loved = signals.trackScore.filter { $0.value > 0 }
            for id in favorites { loved[id, default: 0] += 1 }
            guard loved.count >= 5 else { return nil }
            let leading = loved.sorted { ($0.value, $0.key) > ($1.value, $1.key) }.prefix(200)
            target = ListeningMode.centroid(of: leading.map { (features[$0.key], $0.value) })
        }
        let modeArtists = Set(mode?.topArtists ?? [])

        var generator = SeededGenerator(seed: Self.daySeed(now) ^ 0xF4E5)
        var candidates: [Candidate] = []
        for track in tracks {
            let id = track.stableId
            // firstPlayed holds every song with any listen, skips and the
            // lifetime record included: never played means none at all.
            guard signals.firstPlayed[id] == nil, !favorites.contains(id), !used.contains(id) else { continue }
            let song = features[id]
            let closeness = target.closeness(song)
            let artist = track.artistId.map { (artistLove[$0] ?? 0) / topArtistLove } ?? 0
            let album = track.albumId.map { min((albumLove[$0] ?? 0) / topAlbumLove * 3, 1) } ?? 0
            // Something to go on: the sound, or an artist or album already loved.
            guard closeness >= 0.6 || artist >= 0.1 || album > 0 else { continue }
            var score = 1.4 * closeness + 0.7 * min(artist * 2, 1) + 0.4 * album
            if let artistId = track.artistId, modeArtists.contains(artistId) { score += 0.3 }
            score += Double.random(in: 0..<0.2, using: &generator)
            candidates.append(Candidate(track: track, relevance: score, genre: song?.genre, year: song?.year, energy: song?.energy))
        }
        guard candidates.count >= 15 else { return nil }
        candidates.sort { ($0.relevance, $0.track.stableId) > ($1.relevance, $1.track.stableId) }
        let picked = Self.pickVaried(Array(candidates.prefix(400)), count: Self.mixSize, fresh: [], freshLimit: 0,
                                     artistLimit: max(5, Self.mixSize / 6))
        guard picked.count >= 15 else { return nil }
        let ordered = Self.flowOrder(picked, generator: &generator)

        // "Never played, in the spirit of what you play in the evening ·
        // mostly piano · 12 by artists you love".
        var parts: [String] = []
        if let mode {
            parts.append(TasteWords.contextPhrase(dayPart: mode.dayPart, weekend: mode.weekend, route: mode.route)
                .map { String(format: Localized.whyFreshModeFormat, $0) } ?? Localized.whyFreshModeAny)
        } else {
            parts.append(Localized.whyFreshTaste)
        }
        if let sound = TasteWords.sound(genres: target.genres, year: target.year, spread: target.yearSpread) { parts.append(sound) }
        let byLoved = ordered.filter { track in track.artistId.map { (artistLove[$0] ?? 0) > 0 } ?? false }.count
        if byLoved > 0 { parts.append(String(format: Localized.whyFreshLovedFormat, byLoved)) }
        let why = parts.joined(separator: " · ")

        // No naming context: "Fresh Finds" stays what it is called, so it
        // can be found again, and asked for by name.
        var mix = Self.mix(id: "fresh-finds", title: Localized.freshFinds, subtitle: why, tracks: ordered, hue: 0.36)
        mix.why = why
        return mix
    }

    // MARK: Playlist mix

    /// A mix grown from a whole playlist, like a song mix from many seeds:
    /// songs played in the same sittings as its songs (session k-nearest-
    /// neighbours over all of them, the ones played and finished most
    /// counting most), songs by its artists and the artists closest to
    /// them, and songs that sound like the playlist as a whole. Mostly songs
    /// not in it - at most 30 % of the mix is the playlist's own - picked
    /// for variety and ordered to flow. Returns the mix and a few spares.
    func playlistMix(seeds: [Track], size: Int = 40) -> (queue: [Track], spares: [Track]) {
        guard !seeds.isEmpty else { return ([], []) }
        let mixableTracks = mixable
        let signals = self.signals()
        let (features, profile) = tasteProfile()
        let pickable = Dictionary(mixableTracks.map { ($0.stableId, $0) }, uniquingKeysWith: { first, _ in first })
        let seedIds = Set(seeds.map(\.stableId))
        let seedHash = seeds.prefix(20).reduce(UInt64(seeds.count)) { hash, track in
            track.stableId.utf8.reduce(hash) { $0 &* 31 &+ UInt64($1) }
        }
        var generator = SeededGenerator(seed: Self.daySeed(now) ^ seedHash)

        // How much each seed counts: how much it is played and finished.
        var seedWeight: [String: Double] = [:]
        for track in seeds {
            seedWeight[track.stableId] = 1 + min(max(signals.trackScore[track.stableId] ?? 0, 0), 4) + (favorites.contains(track.stableId) ? 1 : 0)
        }
        let leadingSeeds = Dictionary(uniqueKeysWithValues: seedWeight.sorted { ($0.value, $0.key) > ($1.value, $1.key) }.prefix(40).map { ($0.key, $0.value) })
        let neighbours = profile.neighbours(of: leadingSeeds, limit: 300)
        let centre = ListeningMode.centroid(of: seeds.map { (features[$0.stableId], seedWeight[$0.stableId] ?? 1) })

        var byArtist: [Int64: [Track]] = [:]
        for track in mixableTracks {
            if let artistId = track.artistId { byArtist[artistId, default: []].append(track) }
        }
        var playlistArtists: [Int64: Double] = [:]
        for track in seeds {
            if let artistId = track.artistId { playlistArtists[artistId, default: 0] += seedWeight[track.stableId] ?? 1 }
        }
        let artistTotal = max(playlistArtists.values.reduce(0, +), 0.001)
        // Artists close to the playlist's: linked by sessions, playlists and
        // albums (`artistLinks`), against how linked each is overall.
        let together = artistLinks(byId: pickable)
        var closeArtists: [Int64: Double] = [:]
        for (artist, weight) in playlistArtists {
            let links = together[artist] ?? [:]
            let total = max(links.values.reduce(0, +), 0.001)
            for (other, value) in links where playlistArtists[other] == nil {
                closeArtists[other, default: 0] += value / total * weight / artistTotal
            }
        }

        var ids = Set(neighbours.keys).union(seedIds)
        for artist in playlistArtists.keys.sorted(by: { (playlistArtists[$0] ?? 0, $0) > (playlistArtists[$1] ?? 0, $1) }).prefix(30) {
            for track in byArtist[artist] ?? [] { ids.insert(track.stableId) }
        }
        for (artist, _) in closeArtists.sorted(by: { ($0.value, $0.key) > ($1.value, $1.key) }).prefix(15) {
            for track in byArtist[artist] ?? [] { ids.insert(track.stableId) }
        }
        let leading = centre.genres.sorted { ($0.value, $0.key) > ($1.value, $1.key) }.prefix(2).map(\.key)
        if !leading.isEmpty {
            var taken = 0
            for track in mixableTracks where taken < 3000 {
                if let genre = features[track.stableId]?.genre, leading.contains(genre) {
                    ids.insert(track.stableId)
                    taken += 1
                }
            }
        }

        var candidates: [Candidate] = []
        var fresh = Set<String>()
        for id in ids {
            guard !signals.rejected.contains(id), let track = pickable[id] else { continue }
            let song = features[id]
            let closeness = centre.closeness(song)
            let together = min((neighbours[id] ?? 0) * 2, 1)
            let artistShare = track.artistId.map { (playlistArtists[$0] ?? 0) / artistTotal } ?? 0
            let nearArtist = track.artistId.map { min((closeArtists[$0] ?? 0) * 3, 1) } ?? 0
            // Something to go on first: unrelated songs stay out.
            guard together > 0.05 || closeness >= 0.6 || artistShare > 0 || nearArtist > 0.1 else { continue }
            var score = 2.5 * together + 1.5 * closeness + 1.0 * min(artistShare * 4, 1) + 0.8 * nearArtist
            score += 0.15 * min(max(signals.trackScore[id] ?? 0, -1), 3)
            if favorites.contains(id) { score += 0.3 }
            score += Double.random(in: 0..<0.35, using: &generator)
            if signals.plays[id] == nil && !favorites.contains(id) && !seedIds.contains(id) { fresh.insert(id) }
            candidates.append(Candidate(track: track, relevance: score, genre: song?.genre, year: song?.year, energy: song?.energy))
        }
        candidates.sort { ($0.relevance, $0.track.stableId) > ($1.relevance, $1.track.stableId) }

        // The playlist's own songs at most 30 %, the rest beyond it.
        let total = size + 15
        let ownLimit = Int(Double(size) * 0.3)
        let own = candidates.filter { seedIds.contains($0.track.stableId) }
        let beyond = candidates.filter { !seedIds.contains($0.track.stableId) }
        let share = Self.noveltyShare(noveltySeeking ?? profile.noveltySeeking)
        var picked = Self.pickVaried(
            Array(beyond.prefix(400)), count: total - min(ownLimit, own.count),
            fresh: fresh, freshLimit: Int((Double(total) * share).rounded()), artistLimit: max(4, size / 6)
        )
        let pickedIds = Set(picked.map(\.stableId))
        picked += Self.pickVaried(
            own.filter { !pickedIds.contains($0.track.stableId) }, count: min(ownLimit, own.count),
            fresh: [], freshLimit: 0, artistLimit: max(4, size / 6)
        )
        // Short of songs beyond the playlist: the playlist itself fills in.
        if picked.count < min(size, 15) { picked = Self.varied(seeds.shuffled(using: &generator), limit: size) }
        let familiar = Set(signals.trackScore.filter { $0.value > 0 }.keys).union(favorites)
        let queue = Self.flowOrder(Array(picked.prefix(size)).shuffled(using: &generator), familiar: familiar, generator: &generator)
        return (queue, Array(picked.dropFirst(size)))
    }

    // MARK: Song mix

    /// The mode a song belongs to: the one it is heard in most, else the
    /// one it sounds closest to, if any is close.
    func mode(for seed: Track, features: SongFeatures?) -> ListeningMode? {
        if let heard = modes.compactMap({ mode in mode.songs[seed.stableId].map { (mode, $0) } }).max(by: { $0.1 < $1.1 }) {
            return heard.0
        }
        let nearest = modes.map { ($0, $0.closeness(features)) }.max { $0.1 < $1.1 }
        return nearest.flatMap { $0.1 >= 0.75 ? $0.0 : nil }
    }

    // MARK: Rediscover

    /// Rediscover entries the profile makes possible: a mode played a lot
    /// and not for weeks, songs that fell out of a mode still played, and
    /// artists played on repeat for a while and then dropped. Each comes
    /// with how much its songs have faded from memory (ACT-R), for ranking.
    func tasteRediscoveries(
        taste: TasteContext,
        available: [Track],
        memory: [String: Memory],
        signals: Signals,
        byId: [String: Track]
    ) -> [(id: String, title: String, subtitle: String, tracks: [Track], hue: Double)] {
        var result: [(id: String, title: String, subtitle: String, tracks: [Track], hue: Double)] = []
        let availableById = Dictionary(available.map { ($0.stableId, $0) }, uniquingKeysWith: { first, _ in first })
        let month = now.addingTimeInterval(-30 * 86_400)
        func byFading(_ ids: [String]) -> [Track] {
            ids.compactMap { availableById[$0] }
                .map { ($0, memory[$0.stableId]?.faded ?? 0) }
                .sorted { ($0.1, $0.0.stableId) > ($1.1, $1.0.stableId) }
                .map(\.0)
        }
        let titles = modeTitles(taste.modes)

        // A mode set aside: four weeks or more without a session.
        for mode in taste.modes where !mode.isActive && mode.sessions >= TasteModes.minimumSessions {
            let songs = byFading(Array(mode.songs.keys))
            guard songs.count >= 10 else { continue }
            let weeks = max(4, Int(now.timeIntervalSince(mode.lastPlayed) / (7 * 86_400)))
            let subtitle = [Localized.whyFaded(weeks: weeks), TasteWords.modeWhy(mode)].joined(separator: " · ")
            let hash = mode.id.utf8.reduce(UInt64(0)) { $0 &* 31 &+ UInt64($1) }
            result.append(("faded-\(mode.id)", titles[mode.id] ?? Localized.madeForYou, subtitle, Array(songs.prefix(60)), Double(hash % 360) / 360))
        }

        // Out of rotation: songs heard a lot in a mode still played, but
        // not in that mode - nor anywhere - for a month.
        var lapsed: [String] = []
        var lapsedModes: [String: Int] = [:]
        for mode in taste.modes where mode.isActive {
            let median = mode.songs.values.sorted().dropFirst(mode.songs.count / 2).first ?? 0
            for (id, score) in mode.songs where score >= median {
                guard (mode.songLast[id] ?? .distantFuture) < month, (signals.lastPlayed[id] ?? .distantPast) < month else { continue }
                lapsed.append(id)
                lapsedModes[mode.id, default: 0] += 1
            }
        }
        let lapsedSongs = byFading(Array(Set(lapsed)))
        if lapsedSongs.count >= 10 {
            let leading = lapsedModes.max { ($0.value, $0.key) < ($1.value, $1.key) }
            let mode = taste.modes.first { $0.id == leading?.key }
            // Named after the mode only when most of the songs come from it.
            let phrase = mode.flatMap { mode in
                Double(lapsedModes[mode.id] ?? 0) >= Double(lapsed.count) * 0.6
                    ? TasteWords.contextPhrase(dayPart: mode.dayPart, weekend: mode.weekend, route: mode.route) : nil
            }
            let subtitle = phrase.map { String(format: Localized.whyLapsedFormat, $0) } ?? Localized.whyLapsedAny
            result.append(("lapsed", Localized.whyLapsedTitle, subtitle, Array(lapsedSongs.prefix(60)), 0.88))
        }

        // Brief obsessions: an artist with eight or more plays packed into
        // three weeks - most of all their plays - and none in a month.
        var playsByArtist: [Int64: [Date]] = [:]
        for event in events where !event.isSkip {
            if let artist = byId[event.id]?.artistId { playsByArtist[artist, default: []].append(event.at) }
        }
        var obsessions: [(Int64, Double)] = []
        for (artist, dates) in playsByArtist where dates.count >= 8 {
            let sorted = dates.sorted()
            guard let last = sorted.last, last < month else { continue }
            var best = 0
            var start = 0
            for end in sorted.indices {
                while sorted[end].timeIntervalSince(sorted[start]) > 21 * 86_400 { start += 1 }
                best = max(best, end - start + 1)
            }
            let lifetimePlays = sorted.count
            guard best >= 8, Double(best) >= Double(lifetimePlays) * 0.6 else { continue }
            obsessions.append((artist, Double(best)))
        }
        if !obsessions.isEmpty {
            var songs: [Track] = []
            let artists = obsessions.sorted { ($0.1, $0.0) > ($1.1, $1.0) }.map(\.0)
            let artistSet = Set(artists)
            var perArtist: [Int64: [Track]] = [:]
            for track in available { if let artist = track.artistId, artistSet.contains(artist) { perArtist[artist, default: []].append(track) } }
            for artist in artists where songs.count < 60 {
                songs += byFading((perArtist[artist] ?? []).map(\.stableId)).prefix(6)
            }
            if songs.count >= 10 {
                result.append(("obsessions", Localized.whyObsessionsTitle, Localized.whyObsessionsDescription, songs, 0.05))
            }
        }
        return result
    }
}

// MARK: - Why this mix

/// The line under a mix that says where it comes from, built from the
/// listener's own numbers: "What you play on weekend mornings · mostly piano
/// and soundtrack from the 2010s · 62 listens".
enum TasteWords {
    static func partPhrase(_ part: Int) -> String {
        [Localized.whyInMorning, Localized.whyInAfternoon, Localized.whyInEvening, Localized.whyAtNight][min(max(part, 0), 3)]
    }

    /// When or where, as the end of "What you play ...": the car when the
    /// habit belongs to it - the clearest context there is - else the days
    /// and time of day, else the output.
    static func contextPhrase(dayPart: Int?, weekend: Bool?, route: String?) -> String? {
        if route == "car" { return Localized.whyRouteCar }
        if let time = timePhrase(dayPart: dayPart, weekend: weekend) { return time }
        switch route {
        case "headphones": return Localized.whyRouteHeadphones
        case "bluetooth": return Localized.whyRouteBluetooth
        case "speaker": return Localized.whyRouteSpeaker
        case "airplay": return Localized.whyRouteAirplay
        default: return nil
        }
    }

    static func timePhrase(dayPart: Int?, weekend: Bool?) -> String? {
        switch (weekend, dayPart) {
        case (true?, let part?):
            return [Localized.whyWeekendMorning, Localized.whyWeekendAfternoon, Localized.whyWeekendEvening, Localized.whyWeekendNight][part]
        case (false?, let part?):
            return [Localized.whyWeekdayMorning, Localized.whyWeekdayAfternoon, Localized.whyWeekdayEvening, Localized.whyWeekdayNight][part]
        case (nil, let part?): return partPhrase(part)
        case (true?, nil): return Localized.whyOnWeekends
        case (false?, nil): return Localized.whyOnWeekdays
        case (nil, nil): return nil
        }
    }

    static func listens(_ count: Int) -> String {
        Localized.whyListens(count)
    }

    static func list(_ items: [String]) -> String {
        ListFormatter.localizedString(byJoining: items)
    }

    /// The sound part: the leading genres - a second one only when it is a
    /// real part of the mode - and the decade when the mode keeps to one.
    static func sound(genres: [String: Double], year: Double?, spread: Double?) -> String? {
        let ranked = genres.sorted { ($0.value, $0.key) > ($1.value, $1.key) }
        var names: [String] = []
        if let first = ranked.first, first.value >= 0.2 { names.append(first.key) }
        if names.count == 1, ranked.count > 1, ranked[1].value >= 0.15 { names.append(ranked[1].key) }
        let decade = year.flatMap { year in (spread ?? 99) <= 9 ? MixEngine.decadeLabel(Int(year) / 10 * 10) : nil }
        switch (names.isEmpty, decade) {
        case (false, let decade?): return String(format: Localized.whyMostlyEraFormat, list(names), decade)
        case (false, nil): return String(format: Localized.whyMostlyFormat, list(names))
        case (true, let decade?): return String(format: Localized.whyEraFormat, decade)
        case (true, nil): return nil
        }
    }

    static func modeWhy(_ mode: ListeningMode) -> String {
        let context = contextPhrase(dayPart: mode.dayPart, weekend: mode.weekend, route: mode.route)
        var parts = [context.map { String(format: Localized.whyPlayFormat, $0) } ?? Localized.whyPlayOften]
        if let sound = sound(genres: mode.genres, year: mode.year, spread: mode.yearSpread) { parts.append(sound) }
        parts.append(listens(mode.listens))
        return parts.joined(separator: " · ")
    }

    /// For a mix grown from artists: who it is around, and how much of
    /// them the listener played - or, new here, how much of them is in the
    /// library.
    static func artistsWhy(_ names: [String], listens count: Int, songs: Int) -> String {
        var parts: [String] = []
        if !names.isEmpty { parts.append(String(format: Localized.whyArtistsFormat, list(Array(names.prefix(3))))) }
        parts.append(count > 0 ? listens(count) : Localized.whyLibrary(songs: songs))
        return parts.joined(separator: " · ")
    }
}
