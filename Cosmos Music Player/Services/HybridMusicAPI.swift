//
//  HybridMusicAPI.swift
//  Cosmos Music Player
//
//  Artist information for artist pages, merged from several sources:
//  Spotify (photos, when its keys work) -> MusicBrainz (who the artist is)
//  -> Wikipedia / Wikimedia Commons (bio and photo, in the device language
//  when possible) -> Discogs (bio and photo when Wikipedia has none).
//  On devices with Apple Intelligence, ArtistKnowledgeAgent can afterwards
//  settle namesakes and shorten long or foreign-language bios.
//

import Foundation

// MARK: - Unified Artist Model

/// Where one piece of an artist page came from. Shown on the page: Wikipedia
/// text and Commons photos are CC BY-SA and must be credited.
enum ArtistInfoSource: String, Codable, Sendable {
    case spotify, musicBrainz, wikipedia, discogs

    var displayName: String {
        switch self {
        case .spotify: return "Spotify"
        case .musicBrainz: return "MusicBrainz"
        case .wikipedia: return "Wikipedia"
        case .discogs: return "Discogs"
        }
    }
}

struct UnifiedArtist {
    var id: String
    var name: String
    /// The bio shown on the page.
    var profile: String
    var images: [UnifiedImage]
    /// The source that identified the artist.
    var source: MusicAPISource

    // Internal data for accessing original objects if needed
    var discogsArtist: DiscogsArtist?
    var spotifyArtist: SpotifyArtist?

    // Everything below was added with MusicBrainz/Wikipedia. Each decodes as
    // absent from entries cached before it existed.

    var bioSource: ArtistInfoSource?
    /// BCP 47 code of `profile`, e.g. "fr". Nil when unknown.
    var bioLanguage: String?
    /// The page the bio came from, linked from its credit.
    var bioURL: String?
    /// `profile` is the on-device model's summary of `fullBio`.
    var bioIsSummarized = false
    /// The text as fetched, kept when `profile` is a summary of it so the
    /// expanded bio still shows everything.
    var fullBio: String?

    var imageSource: ArtistInfoSource?
    /// The photo's own page (a Commons file page), for crediting it.
    var imagePageURL: String?

    var musicBrainzID: String?
    var disambiguation: String?
    var genres: [String] = []
    var country: String?
    /// e.g. "1987–1994".
    var activeYears: String?
    var spotifyURL: String?

    /// Other MusicBrainz artists with the same name, best first.
    var alternativeMusicBrainzIDs: [String] = []
    /// Several namesakes and the library's albums did not say which is meant.
    var isAmbiguous = false
    /// The on-device model has looked at this artist; it runs once per
    /// cached artist.
    var aiReviewed = false
    /// Which lookup produced this entry. Entries from an older lookup are
    /// rebuilt when next opened (and kept if that fails).
    var infoVersion = 0

    init(from discogsArtist: DiscogsArtist) {
        self.id = String(discogsArtist.id)
        self.name = discogsArtist.name
        self.profile = DiscogsAPIService.cleanProfile(discogsArtist.profile)
        self.images = discogsArtist.images.map { UnifiedImage(from: $0) }
        self.source = .discogs
        self.discogsArtist = discogsArtist
        self.spotifyArtist = nil
        self.bioSource = profile.isEmpty ? nil : .discogs
        self.bioURL = discogsArtist.uri
        self.imageSource = images.isEmpty ? nil : .discogs
    }

    init(from spotifyArtist: SpotifyArtist) {
        self.id = spotifyArtist.id
        self.name = spotifyArtist.name
        self.profile = spotifyArtist.profile
        self.images = spotifyArtist.images.map { UnifiedImage(from: $0) }
        self.source = .spotify
        self.discogsArtist = nil
        self.spotifyArtist = spotifyArtist
        self.bioSource = .spotify
        self.imageSource = images.isEmpty ? nil : .spotify
        self.genres = spotifyArtist.genres
        self.spotifyURL = spotifyArtist.externalUrls.spotify
    }
}

struct UnifiedImage {
    let url: String
    let width: Int?
    let height: Int?

    init(from discogsImage: DiscogsImage) {
        self.url = discogsImage.uri
        self.width = discogsImage.width
        self.height = discogsImage.height
    }

    init(from spotifyImage: SpotifyImage) {
        self.url = spotifyImage.url
        self.width = spotifyImage.width
        self.height = spotifyImage.height
    }

    init(url: String, width: Int? = nil, height: Int? = nil) {
        self.url = url
        self.width = width
        self.height = height
    }
}

enum MusicAPISource {
    case discogs
    case spotify
    case musicBrainz

    var rawValue: String {
        switch self {
        case .discogs: return "discogs"
        case .spotify: return "spotify"
        case .musicBrainz: return "musicbrainz"
        }
    }
}

// MARK: - Cached Unified Artist Data

class CachedUnifiedArtistInfo: NSObject, Codable {
    let artistName: String
    let unifiedArtist: UnifiedArtist
    let cachedAt: Date

    init(artistName: String, unifiedArtist: UnifiedArtist, cachedAt: Date) {
        self.artistName = artistName
        self.unifiedArtist = unifiedArtist
        self.cachedAt = cachedAt
        super.init()
    }

    var isExpired: Bool {
        // Seven days, as before, for entries that may still pick up Spotify.
        // MusicBrainz/Wikipedia entries hardly change, so they keep a month
        // and the services are asked far less often.
        let days: Double = unifiedArtist.infoVersion >= HybridMusicAPIService.infoVersion ? 30 : 7
        return Date().timeIntervalSince(cachedAt) > days * 24 * 60 * 60
    }
}

// Make UnifiedArtist and UnifiedImage Codable
extension UnifiedArtist: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, profile, images, source
        case bioSource, bioLanguage, bioURL, bioIsSummarized, fullBio
        case imageSource, imagePageURL
        case musicBrainzID, disambiguation, genres, country, activeYears, spotifyURL
        case alternativeMusicBrainzIDs, isAmbiguous, aiReviewed, infoVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        profile = try container.decode(String.self, forKey: .profile)
        images = try container.decode([UnifiedImage].self, forKey: .images)
        source = try container.decode(MusicAPISource.self, forKey: .source)
        discogsArtist = nil
        spotifyArtist = nil

        // Entries cached before these fields existed have none of them: the
        // credit then follows the one source such an entry came from.
        let legacySource: ArtistInfoSource = source == .spotify ? .spotify : .discogs
        bioSource = try container.decodeIfPresent(ArtistInfoSource.self, forKey: .bioSource) ?? (profile.isEmpty ? nil : legacySource)
        bioLanguage = try container.decodeIfPresent(String.self, forKey: .bioLanguage)
        bioURL = try container.decodeIfPresent(String.self, forKey: .bioURL)
        bioIsSummarized = try container.decodeIfPresent(Bool.self, forKey: .bioIsSummarized) ?? false
        fullBio = try container.decodeIfPresent(String.self, forKey: .fullBio)
        imageSource = try container.decodeIfPresent(ArtistInfoSource.self, forKey: .imageSource) ?? (images.isEmpty ? nil : legacySource)
        imagePageURL = try container.decodeIfPresent(String.self, forKey: .imagePageURL)
        musicBrainzID = try container.decodeIfPresent(String.self, forKey: .musicBrainzID)
        disambiguation = try container.decodeIfPresent(String.self, forKey: .disambiguation)
        genres = try container.decodeIfPresent([String].self, forKey: .genres) ?? []
        country = try container.decodeIfPresent(String.self, forKey: .country)
        activeYears = try container.decodeIfPresent(String.self, forKey: .activeYears)
        spotifyURL = try container.decodeIfPresent(String.self, forKey: .spotifyURL)
        alternativeMusicBrainzIDs = try container.decodeIfPresent([String].self, forKey: .alternativeMusicBrainzIDs) ?? []
        isAmbiguous = try container.decodeIfPresent(Bool.self, forKey: .isAmbiguous) ?? false
        aiReviewed = try container.decodeIfPresent(Bool.self, forKey: .aiReviewed) ?? false
        infoVersion = try container.decodeIfPresent(Int.self, forKey: .infoVersion) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(profile, forKey: .profile)
        try container.encode(images, forKey: .images)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(bioSource, forKey: .bioSource)
        try container.encodeIfPresent(bioLanguage, forKey: .bioLanguage)
        try container.encodeIfPresent(bioURL, forKey: .bioURL)
        try container.encode(bioIsSummarized, forKey: .bioIsSummarized)
        try container.encodeIfPresent(fullBio, forKey: .fullBio)
        try container.encodeIfPresent(imageSource, forKey: .imageSource)
        try container.encodeIfPresent(imagePageURL, forKey: .imagePageURL)
        try container.encodeIfPresent(musicBrainzID, forKey: .musicBrainzID)
        try container.encodeIfPresent(disambiguation, forKey: .disambiguation)
        try container.encode(genres, forKey: .genres)
        try container.encodeIfPresent(country, forKey: .country)
        try container.encodeIfPresent(activeYears, forKey: .activeYears)
        try container.encodeIfPresent(spotifyURL, forKey: .spotifyURL)
        try container.encode(alternativeMusicBrainzIDs, forKey: .alternativeMusicBrainzIDs)
        try container.encode(isAmbiguous, forKey: .isAmbiguous)
        try container.encode(aiReviewed, forKey: .aiReviewed)
        try container.encode(infoVersion, forKey: .infoVersion)
    }
}

extension UnifiedImage: Codable {}
extension MusicAPISource: Codable {}

// MARK: - Hybrid Music API Service

class HybridMusicAPIService: ObservableObject, @unchecked Sendable {
    @MainActor static let shared = HybridMusicAPIService()

    /// Bumped when the lookup changes enough that cached artists should be
    /// rebuilt. 1 = Spotify/Discogs only; 2 = MusicBrainz + Wikipedia.
    static let infoVersion = 2

    private let discogsAPI: DiscogsAPIService

    /// Spotify answers 403 to every request while the account that owns the
    /// app's keys has no Premium subscription (its rule for Web API apps).
    /// Asking anyway cost a token and a refused search before every artist
    /// page fell back to Discogs, so after a 403 Spotify rests for six hours.
    private static let spotifyRestKey = "cosmos.spotifyRestUntil"
    /// Cached artists already re-tried on Spotify this launch.
    private static let spotifyRetried = RetriedNames()

    private final class RetriedNames: @unchecked Sendable {
        private var names = Set<String>()
        private let lock = NSLock()
        /// True the first time a name is seen.
        func insert(_ name: String) -> (inserted: Bool, memberAfterInsert: String) {
            lock.lock(); defer { lock.unlock() }
            return names.insert(name)
        }
    }

    private static var spotifyIsResting: Bool {
        UserDefaults.standard.double(forKey: spotifyRestKey) > Date().timeIntervalSince1970
    }

    private static func restSpotify() {
        UserDefaults.standard.set(Date().addingTimeInterval(6 * 3600).timeIntervalSince1970, forKey: spotifyRestKey)
    }
    private let spotifyAPI: SpotifyAPIService
    private let musicBrainz = MusicBrainzAPIService.shared

    private let cache = NSCache<NSString, CachedUnifiedArtistInfo>()
    private let cacheDirectory: URL

    /// Names no source knew, this session. Without it an unknown artist cost
    /// the same round of requests every time its page was opened. Only
    /// lookups that reached every service land here, never offline ones.
    private var unknownNames: Set<String> = []
    private let unknownLock = NSLock()

    @MainActor
    private init() {
        // Initialize APIs
        self.discogsAPI = DiscogsAPIService.shared
        self.spotifyAPI = SpotifyAPIService.shared

        // Set up cache directory
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        cacheDirectory = documentsPath.appendingPathComponent("HybridMusicCache")

        // Create cache directory if it doesn't exist
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        // Configure NSCache
        cache.countLimit = 100 // Limit to 100 cached artists
    }

    // MARK: - Public API

    /// The artist page's information. `albumHints` are the library's album
    /// titles by this artist; they pick the right one of several namesakes.
    func searchArtist(name: String, albumHints: [String] = []) async throws -> UnifiedArtist? {
        print("🎵 Hybrid: Searching for artist: \(name)")

        let cachedArtist = getCachedArtist(name: name)
        if let cached = cachedArtist, cached.unifiedArtist.infoVersion >= Self.infoVersion {
            var artist = cached.unifiedArtist
            // A cached entry without Spotify gets one more try at Spotify's
            // photo while Spotify is answering; the rest stays as cached.
            // Not for an artist the listener or the model chose among
            // namesakes - a search by name would bring the wrong one's photo
            // back - and once per launch at most, not on every page open.
            guard artist.spotifyURL == nil, !Self.spotifyIsResting, !artist.aiReviewed,
                  artist.alternativeMusicBrainzIDs.isEmpty,
                  Self.spotifyRetried.insert(name.lowercased()).inserted else {
                print("✅ Hybrid: Found cached artist: \(name)")
                return artist
            }
            if let spotify = await trySpotify(name: name) {
                artist.applySpotify(spotify)
                cacheArtist(name: name, artist: artist)
            }
            return artist
        }

        if isKnownUnknown(name) { return cachedArtist?.unifiedArtist }

        let (built, complete) = await buildArtistHonouringCorrection(name: name, albumHints: albumHints)
        if let built {
            cacheArtist(name: name, artist: built)
            return built
        }
        if complete { markUnknown(name) }

        // Offline, or every service failed: an entry from the older lookup
        // still beats an empty header.
        if let cached = cachedArtist {
            print("✅ Hybrid: Reusing older cached artist: \(name)")
            return cached.unifiedArtist
        }
        print("❌ Hybrid: No artist found on any platform for: \(name)")
        return nil
    }

    /// "Wrong artist?": the next MusicBrainz namesake when there is one,
    /// otherwise whatever a different source has under this name. The
    /// answer is cached, and the choice is also remembered permanently
    /// (ArtistCorrections): the cache expires after a month and was then
    /// rebuilt from scratch, bringing the rejected namesake back.
    func searchAlternativeArtist(name: String, current: UnifiedArtist?, albumHints: [String] = []) async throws -> UnifiedArtist? {
        print("🔄 Hybrid: Searching for alternative artist: \(name), avoiding source: \(current?.source.rawValue ?? "none")")
        guard let current else { return try await searchArtist(name: name, albumHints: albumHints) }
        let found = try await findAlternativeArtist(name: name, current: current, albumHints: albumHints)
        if let found {
            ArtistCorrections.record(name: name, chosen: found.musicBrainzID, rejected: current.musicBrainzID)
        }
        return found
    }

    private func findAlternativeArtist(name: String, current: UnifiedArtist, albumHints: [String]) async throws -> UnifiedArtist? {
        // With Apple Intelligence the agent goes first: it checks which
        // artist actually released the listener's albums - among namesakes,
        // other spellings, the name in its original script - where cycling
        // to the next namesake only guessed. Without it, or when it is not
        // sure, the steps below run as before.
        if let found = await findReplacementWithOnDeviceModel(name: name, rejected: current, albumHints: albumHints) {
            return found
        }

        if let next = current.alternativeMusicBrainzIDs.first {
            let (built, _) = await buildArtist(name: name, albumHints: albumHints, musicBrainzID: next)
            if var built {
                // The one just rejected goes to the back of the line, so
                // asking again cycles through every namesake.
                built.alternativeMusicBrainzIDs = Array(current.alternativeMusicBrainzIDs.dropFirst())
                    + [current.musicBrainzID].compactMap { $0 }
                built.isAmbiguous = false
                // The listener chose; the model must not choose again.
                built.aiReviewed = true
                cacheArtist(name: name, artist: built)
                return built
            }
        }

        if current.source != .discogs {
            print("🎯 Hybrid: Trying Discogs as alternative for: \(name)")
            do {
                if let discogsArtist = try await discogsAPI.searchArtist(name: name),
                   String(discogsArtist.id) != current.id {
                    var unifiedArtist = UnifiedArtist(from: discogsArtist)
                    unifiedArtist.infoVersion = Self.infoVersion
                    unifiedArtist.aiReviewed = true
                    cacheArtist(name: name, artist: unifiedArtist)
                    return unifiedArtist
                }
            } catch {
                print("⚠️ Hybrid: Discogs alternative failed: \(error.localizedDescription)")
            }
            return nil
        }

        // Currently Discogs: what Spotify or MusicBrainz say instead.
        let (built, _) = await buildArtist(name: name, albumHints: albumHints)
        guard var built, built.source != .discogs else { return nil }
        built.aiReviewed = true
        cacheArtist(name: name, artist: built)
        return built
    }

    // Search for similar/alternative artist names
    func searchSimilarArtist(originalName: String, current: UnifiedArtist?) async throws -> UnifiedArtist? {
        print("🔍 Hybrid: Searching for similar artist names for: \(originalName)")

        // Generate variations of the artist name
        let variations = generateNameVariations(originalName)

        for variation in variations {
            if variation == originalName { continue } // Skip original name

            print("🎯 Hybrid: Trying variation: \(variation)")
            do {
                if let result = try await searchAlternativeArtist(name: variation, current: current) {
                    print("✅ Hybrid: Found artist with variation '\(variation)': \(result.name)")
                    return result
                }
            } catch {
                print("⚠️ Hybrid: Variation '\(variation)' failed: \(error.localizedDescription)")
            }
        }

        print("❌ Hybrid: No similar artist found for: \(originalName)")
        return nil
    }

    // MARK: - On-device refinement

    /// "Wrong artist?" with nobody else of that name: asks the on-device
    /// agent for a different artist. Only an id its tools actually returned,
    /// with at least medium confidence, is taken; the bio only when it is
    /// grounded in text fetched for that artist. Nil without Apple
    /// Intelligence or when the model is not sure.
    private func findReplacementWithOnDeviceModel(name: String, rejected current: UnifiedArtist, albumHints: [String]) async -> UnifiedArtist? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return nil }
        let language = WikipediaAPI.preferredLanguages.first ?? "en"
        guard ArtistKnowledgeAgent.isAvailable(language: language) else {
            print("🧠 Hybrid: On-device model unavailable for \(language); 'Wrong artist?' uses the usual steps")
            return nil
        }
        print("🧠 Hybrid: Asking the on-device model for the right \(name) (rejected \(current.source.rawValue) match \(current.musicBrainzID ?? current.id))")
        guard let outcome = await ArtistKnowledgeAgent.run(
            name: name, albumHints: albumHints, current: current, language: language, discogs: discogsAPI, rejected: true
        ), outcome.confidence != .low, let chosen = outcome.musicBrainzID, chosen != current.musicBrainzID else {
            print("🧠 Hybrid: On-device search found no other artist for \(name)")
            return nil
        }
        print("🧠 Hybrid: On-device search picked \(chosen) instead of \(current.musicBrainzID ?? "-") for \(name)")
        let (built, _) = await buildArtist(name: name, albumHints: albumHints, musicBrainzID: chosen)
        guard var built else { return nil }
        if let bio = outcome.bio, outcome.groundedSources.contains(where: { $0.musicBrainzID == chosen }), built.profile.isEmpty {
            built.profile = bio
            built.bioIsSummarized = true
            built.bioLanguage = language
        }
        // The rejected one stays reachable by asking again.
        built.alternativeMusicBrainzIDs = [current.musicBrainzID].compactMap { $0 }
        built.isAmbiguous = false
        // The listener chose; the model must not choose again.
        built.aiReviewed = true
        cacheArtist(name: name, artist: built)
        return built
        #else
        return nil
        #endif
    }

    /// Asks the on-device model to settle namesakes or shorten a long or
    /// foreign-language bio, when the device has Apple Intelligence and the
    /// artist needs it. Returns the improved artist (already cached), or nil
    /// when nothing changed. Never needed: the page already shows the
    /// deterministic result while this runs.
    ///
    /// `userInitiated` is true for a page the listener opened; background
    /// prefetching passes false and is then limited by `LocalModelBudget`.
    func refineWithOnDeviceModel(name: String, artist: UnifiedArtist, albumHints: [String], userInitiated: Bool) async -> UnifiedArtist? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return nil }
        let language = WikipediaAPI.preferredLanguages.first ?? "en"
        #if DEBUG
        // -cosmosDebugArtistAI 1: review every artist page, to try the agent.
        let forced = UserDefaults.standard.bool(forKey: "cosmosDebugArtistAI")
        #else
        let forced = false
        #endif
        guard !artist.aiReviewed || forced else {
            print("🧠 Hybrid: \(name) already reviewed on device")
            return nil
        }
        guard forced || Self.needsReview(artist, language: language) else {
            print("🧠 Hybrid: \(name) needs no review (bio \(artist.bioSource?.rawValue ?? "none"), \(artist.profile.count) chars, \(artist.bioLanguage ?? "?") vs \(language), namesakes \(artist.alternativeMusicBrainzIDs.count))")
            return nil
        }
        guard ArtistKnowledgeAgent.isAvailable(language: language) else {
            print("🧠 Hybrid: on-device model unavailable for \(language): \(ArtistKnowledgeAgent.availabilityDescription)")
            return nil
        }
        print("🧠 Hybrid: asking the on-device model about \(name)")
        if !userInitiated {
            guard await LocalModelBudget.spend() else { return nil }
        }

        var reviewed = artist
        reviewed.aiReviewed = true
        guard let outcome = await ArtistKnowledgeAgent.run(
            name: name, albumHints: albumHints, current: artist, language: language, discogs: discogsAPI
        ) else {
            // Failed or timed out: keep the plain result, and try again on a
            // later visit - a run cut short (the model still loading, a slow
            // network) says nothing about the artist. Marking it reviewed
            // here meant one timeout stopped the agent for good.
            return nil
        }
        print("🧠 Hybrid: On-device review of \(name): \(outcome.confidence), id \(outcome.musicBrainzID ?? "-")")

        guard outcome.confidence != .low else {
            cacheArtist(name: name, artist: reviewed)
            return nil
        }

        var result = reviewed
        // Switching artist needs high confidence and an id the tools
        // actually returned; anything else keeps the deterministic choice.
        if outcome.confidence == .high, let chosen = outcome.musicBrainzID, chosen != artist.musicBrainzID {
            let (built, _) = await buildArtist(name: name, albumHints: albumHints, musicBrainzID: chosen)
            if var built {
                built.alternativeMusicBrainzIDs = (artist.alternativeMusicBrainzIDs.filter { $0 != chosen })
                    + [artist.musicBrainzID].compactMap { $0 }
                built.isAmbiguous = false
                built.aiReviewed = true
                result = built
            }
        }

        // The summary replaces the shown text only when it is grounded in
        // text the tools fetched for the artist finally chosen.
        if let bio = outcome.bio, outcome.groundedSources.contains(where: { $0.musicBrainzID == nil || $0.musicBrainzID == result.musicBrainzID }) {
            let original = result.fullBio ?? result.profile
            result.fullBio = original.isEmpty ? nil : original
            result.profile = bio
            result.bioIsSummarized = true
            result.bioLanguage = language
            if let used = outcome.groundedSources.first(where: { $0.source == result.bioSource }) ?? outcome.groundedSources.first {
                result.bioSource = used.source
                result.bioURL = used.url ?? result.bioURL
            }
        }

        cacheArtist(name: name, artist: result)
        return result
        #else
        return nil
        #endif
    }

    /// Worth a model run: several namesakes, or a bio too long for the page
    /// or not in the listener's language.
    private static func needsReview(_ artist: UnifiedArtist, language: String) -> Bool {
        guard artist.musicBrainzID != nil || artist.bioSource == .discogs else { return false }
        if artist.isAmbiguous && !artist.alternativeMusicBrainzIDs.isEmpty { return true }
        guard artist.bioSource == .wikipedia || artist.bioSource == .discogs else { return false }
        if artist.profile.count > 600 { return true }
        if let bioLanguage = artist.bioLanguage, bioLanguage != language { return true }
        return false
    }

    // MARK: - Lookup chain

    private func trySpotify(name: String) async -> SpotifyArtist? {
        guard !Self.spotifyIsResting else {
            print("ℹ️ Hybrid: Spotify refused recently; skipping it for: \(name)")
            return nil
        }
        do {
            return try await spotifyAPI.searchArtist(name: name)
        } catch {
            print("⚠️ Hybrid: Spotify failed: \(error.localizedDescription)")
            if case SpotifyAPIError.forbidden = error { Self.restSpotify() }
            return nil
        }
    }

    /// `buildArtist`, keeping a correction the listener made with "Wrong
    /// artist?": the chosen MusicBrainz artist is built directly, and a
    /// rejected one is never picked again by the name search.
    private func buildArtistHonouringCorrection(name: String, albumHints: [String]) async -> (UnifiedArtist?, complete: Bool) {
        guard let correction = ArtistCorrections.correction(for: name) else {
            return await buildArtist(name: name, albumHints: albumHints)
        }
        func asCorrected(_ artist: UnifiedArtist) -> UnifiedArtist {
            var artist = artist
            // Rejected ones stay reachable by asking again, as before.
            artist.alternativeMusicBrainzIDs = artist.alternativeMusicBrainzIDs.filter {
                !correction.rejected.contains($0) && $0 != artist.musicBrainzID
            } + correction.rejected.filter { $0 != artist.musicBrainzID }
            artist.isAmbiguous = false
            // The listener chose; the model must not choose again.
            artist.aiReviewed = true
            return artist
        }

        if let chosen = correction.chosen {
            let (built, complete) = await buildArtist(name: name, albumHints: albumHints, musicBrainzID: chosen)
            if let built { return (asCorrected(built), complete) }
            // Offline or the id is gone: say nothing rather than fall back to
            // a name search that may bring the rejected namesake back.
            if !complete { return (nil, false) }
        }

        let (built, complete) = await buildArtist(name: name, albumHints: albumHints)
        guard let built, let id = built.musicBrainzID, correction.rejected.contains(id) else {
            return (built.map(asCorrected), complete)
        }
        // The search picked a namesake the listener rejected: the next one
        // they have not, as "Wrong artist?" would.
        if let next = built.alternativeMusicBrainzIDs.first(where: { !correction.rejected.contains($0) }) {
            let (alternative, alternativeComplete) = await buildArtist(name: name, albumHints: albumHints, musicBrainzID: next)
            if let alternative { return (asCorrected(alternative), alternativeComplete) }
        }
        if let discogsArtist = try? await discogsAPI.searchArtist(name: name) {
            var unifiedArtist = UnifiedArtist(from: discogsArtist)
            unifiedArtist.infoVersion = Self.infoVersion
            return (asCorrected(unifiedArtist), complete)
        }
        return (asCorrected(built), complete)
    }

    /// Runs the whole chain. `complete` is false when a service could not be
    /// reached, so a nil result is not taken to mean "no such artist".
    /// `musicBrainzID` skips the search and builds that exact artist.
    private func buildArtist(name: String, albumHints: [String], musicBrainzID: String? = nil) async -> (UnifiedArtist?, complete: Bool) {
        // A specific MusicBrainz artist (chosen among namesakes) is not
        // looked up on Spotify by name: Spotify would answer with whichever
        // namesake it knows, and its photo and link would cover the choice.
        var complete = true
        let spotify = musicBrainzID == nil ? await trySpotify(name: name) : nil

        var details: MusicBrainzArtistDetails?
        var alternatives: [MusicBrainzArtistCandidate] = []
        var isAmbiguous = false
        do {
            if let musicBrainzID {
                details = try await musicBrainz.artist(id: musicBrainzID)
            } else if let resolution = try await musicBrainz.resolve(name: name, albumHints: albumHints) {
                details = resolution.chosen
                alternatives = resolution.alternatives
                isAmbiguous = resolution.isAmbiguous
            }
        } catch {
            complete = false
            print("⚠️ Hybrid: MusicBrainz failed: \(error.localizedDescription)")
        }

        var summary: WikipediaSummary?
        var commonsImage: (url: String, page: String?)?
        if let details {
            do {
                summary = try await WikipediaAPI.bestSummary(wikidataID: details.wikidataID, articleURL: details.wikipediaURL)
                if summary?.imageURL == nil {
                    let file: String?
                    if let page = details.commonsImagePage {
                        file = page.components(separatedBy: "File:").last?.removingPercentEncoding
                    } else if let wikidataID = details.wikidataID {
                        file = try await WikipediaAPI.commonsImageFile(wikidataID: wikidataID)
                    } else {
                        file = nil
                    }
                    if let file, let url = WikipediaAPI.commonsImageURL(file: file) {
                        commonsImage = (url, WikipediaAPI.commonsFilePage(file: file))
                    }
                }
            } catch {
                complete = false
                print("⚠️ Hybrid: Wikipedia failed: \(error.localizedDescription)")
            }
        }

        // Discogs only fills what is still missing. With a MusicBrainz match
        // it is asked by the id MusicBrainz links, never by name when the
        // name is shared, so a namesake's bio cannot slip in.
        let hasImage = !(spotify?.images.isEmpty ?? true) || summary?.imageURL != nil || commonsImage != nil
        var discogs: DiscogsArtist?
        if summary == nil || !hasImage {
            do {
                if let discogsID = details?.discogsID {
                    discogs = try await discogsAPI.artist(id: discogsID)
                } else if details == nil || !isAmbiguous {
                    discogs = try await discogsAPI.searchArtist(name: name)
                }
            } catch {
                complete = false
                print("⚠️ Hybrid: Discogs failed: \(error.localizedDescription)")
            }
        }

        guard spotify != nil || details != nil || discogs != nil else { return (nil, complete) }

        // Identity: Spotify when it answered (its logo and link are shown),
        // then MusicBrainz, then Discogs.
        var artist: UnifiedArtist
        if let spotify {
            artist = UnifiedArtist(from: spotify)
        } else if let discogs, details == nil {
            artist = UnifiedArtist(from: discogs)
        } else {
            artist = UnifiedArtist(from: discogs ?? Self.placeholderDiscogs)
            artist.source = .musicBrainz
            artist.discogsArtist = discogs
            if let details { artist.id = details.candidate.id }
        }
        // The library's spelling: MusicBrainz often files Japanese artists
        // under their native script.
        if details != nil { artist.name = name }
        artist.infoVersion = Self.infoVersion

        if let details {
            let candidate = details.candidate
            artist.musicBrainzID = candidate.id
            artist.disambiguation = candidate.disambiguation
            artist.country = candidate.country
            artist.activeYears = candidate.activeYears
            let tags = details.genres.isEmpty ? Array(candidate.tags.prefix(5)) : Array(details.genres.prefix(5))
            artist.genres = artist.genres.isEmpty ? tags : artist.genres
            artist.alternativeMusicBrainzIDs = alternatives.map(\.id)
            artist.isAmbiguous = isAmbiguous
        }

        // Bio: Wikipedia, then Discogs, then Spotify's genre sentence.
        if let summary {
            artist.profile = summary.extract
            artist.bioSource = .wikipedia
            artist.bioLanguage = summary.language
            artist.bioURL = summary.pageURL
        } else if let discogs, !DiscogsAPIService.cleanProfile(discogs.profile).isEmpty {
            artist.profile = DiscogsAPIService.cleanProfile(discogs.profile)
            artist.bioSource = .discogs
            artist.bioLanguage = "en"
            artist.bioURL = discogs.uri
        } else if spotify == nil {
            artist.profile = ""
            artist.bioSource = nil
        }

        // Photo: Spotify, then Wikipedia/Commons, then Discogs.
        if spotify?.images.isEmpty ?? true {
            if let url = summary?.imageURL {
                artist.images = [UnifiedImage(url: url)]
                artist.imageSource = .wikipedia
                artist.imagePageURL = summary?.imagePageURL
            } else if let commonsImage {
                artist.images = [UnifiedImage(url: commonsImage.url)]
                artist.imageSource = .wikipedia
                artist.imagePageURL = commonsImage.page
            } else if let discogs, !discogs.images.isEmpty {
                artist.images = discogs.images.map { UnifiedImage(from: $0) }
                artist.imageSource = .discogs
                artist.imagePageURL = discogs.uri
            } else {
                artist.images = []
                artist.imageSource = nil
            }
        }

        print("✅ Hybrid: Built \(name): id \(artist.source.rawValue), bio \(artist.bioSource?.rawValue ?? "-"), photo \(artist.imageSource?.rawValue ?? "-")\(isAmbiguous ? ", ambiguous" : "")")
        return (artist, complete)
    }

    /// The Discogs initializer is the only one that takes no Spotify data;
    /// MusicBrainz-identified artists start from an empty one.
    private static let placeholderDiscogs = DiscogsArtist(
        id: 0, name: "", resourceUrl: "", uri: "", releasesUrl: "", images: [], profile: "",
        urls: nil, nameVariations: nil, aliases: nil, members: nil
    )

    private func isKnownUnknown(_ name: String) -> Bool {
        unknownLock.lock(); defer { unknownLock.unlock() }
        return unknownNames.contains(name.lowercased())
    }

    private func markUnknown(_ name: String) {
        unknownLock.lock(); defer { unknownLock.unlock() }
        unknownNames.insert(name.lowercased())
    }

    // MARK: - Helper Methods

    private func generateNameVariations(_ originalName: String) -> [String] {
        var variations: [String] = []

        // Remove common suffixes like "- Topic", ", the", etc.
        let commonSuffixes = ["- Topic", " - Topic", ", The", ", the", " (Official)", " Official"]
        for suffix in commonSuffixes {
            if originalName.contains(suffix) {
                let cleaned = originalName.replacingOccurrences(of: suffix, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty && cleaned != originalName {
                    variations.append(cleaned)
                }
            }
        }

        // Remove brackets and parentheses content
        let bracketsPattern = "\\[[^\\]]*\\]|\\([^\\)]*\\)"
        if let regex = try? NSRegularExpression(pattern: bracketsPattern, options: []) {
            let range = NSRange(location: 0, length: originalName.count)
            let cleaned = regex.stringByReplacingMatches(in: originalName, options: [], range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty && cleaned != originalName {
                variations.append(cleaned)
            }
        }

        // Try with "The" prefix if not present, or without if present
        if originalName.lowercased().hasPrefix("the ") {
            let withoutThe = String(originalName.dropFirst(4))
            variations.append(withoutThe)
        } else {
            variations.append("The " + originalName)
        }

        // Remove duplicates and return first 3 variations
        return Array(Set(variations)).prefix(3).map { $0 }
    }

    // MARK: - Caching

    private func cacheFileURL(for name: String) -> URL {
        // See String.cacheFilename: "AC/DC" would otherwise name a file in a
        // missing "AC" folder, and "AC/DC" and "AC_DC" share one entry.
        cacheDirectory.appendingPathComponent(name.cacheFilename + ".json")
    }

    private func getCachedArtist(name: String) -> CachedUnifiedArtistInfo? {
        let key = NSString(string: name.lowercased())

        // Check memory cache first
        if let cached = cache.object(forKey: key), !cached.isExpired {
            return cached
        }

        // Check disk cache
        let fileURL = cacheFileURL(for: name)

        guard let data = try? Data(contentsOf: fileURL),
              let cached = try? JSONDecoder().decode(CachedUnifiedArtistInfo.self, from: data) else {
            return nil
        }

        // Reclaim the file as soon as it is known to be stale. Callers discard
        // expired entries anyway, and previously the file was left behind
        // until it happened to be overwritten by a fresh lookup.
        if cached.isExpired {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }

        // Store in memory cache
        cache.setObject(cached, forKey: key)
        return cached
    }

    private func cacheArtist(name: String, artist: UnifiedArtist) {
        let cached = CachedUnifiedArtistInfo(artistName: name, unifiedArtist: artist, cachedAt: Date())
        let key = NSString(string: name.lowercased())

        // Store in memory cache
        cache.setObject(cached, forKey: key)

        // Store in disk cache
        let fileURL = cacheFileURL(for: name)

        do {
            let data = try JSONEncoder().encode(cached)
            try data.write(to: fileURL, options: .atomic)
            print("💾 Hybrid: Cached artist data for: \(name) (source: \(artist.source))")
        } catch {
            print("❌ Hybrid: Failed to cache artist data: \(error)")
        }
    }

    /// Deletes cache files whose contents have expired. Entries were only ever
    /// checked for staleness on read and then ignored, so the directory grew
    /// without bound - including for artists no longer in the library.
    func purgeExpiredDiskCache() async {
        // Walking the directory and decoding each entry is file work, so keep
        // it off the main thread - this runs during post-index maintenance,
        // alongside the UI.
        let directory = cacheDirectory
        await Task.detached(priority: .utility) {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )) ?? []

            var removed = 0
            for fileURL in files where fileURL.pathExtension == "json" {
                guard let data = try? Data(contentsOf: fileURL) else { continue }

                // Undecodable entries are stale by definition (format changed
                // or the file is truncated) and can never be served, so drop
                // them too.
                let cached = try? JSONDecoder().decode(CachedUnifiedArtistInfo.self, from: data)
                guard cached == nil || cached!.isExpired else { continue }

                do {
                    try FileManager.default.removeItem(at: fileURL)
                    removed += 1
                } catch {
                    print("❌ Hybrid: Failed to remove expired cache file: \(error)")
                }
            }

            if removed > 0 {
                print("🗑️ Hybrid: Removed \(removed) expired cache file(s)")
            }
        }.value
    }
}

/// The listener's "Wrong artist?" choices, kept for good. The artist cache
/// entry they were stored in expires after 30 days and is rebuilt from a
/// fresh name search, which picked the rejected namesake again.
private enum ArtistCorrections {
    struct Correction: Codable {
        /// The MusicBrainz artist chosen; nil when the choice was another
        /// source (Discogs) with no MusicBrainz id.
        var chosen: String?
        var rejected: [String]
    }

    private static let defaultsKey = "cosmos.artistCorrections"
    private static let lock = NSLock()

    static func correction(for name: String) -> Correction? {
        lock.lock(); defer { lock.unlock() }
        return load()[name.lowercased()]
    }

    static func record(name: String, chosen: String?, rejected: String?) {
        lock.lock(); defer { lock.unlock() }
        var all = load()
        let key = name.lowercased()
        var correction = all[key] ?? Correction(chosen: nil, rejected: [])
        if let rejected, rejected != chosen, !correction.rejected.contains(rejected) {
            correction.rejected.append(rejected)
        }
        // Cycling back to an earlier namesake un-rejects it.
        correction.rejected.removeAll { $0 == chosen }
        correction.chosen = chosen
        all[key] = correction
        guard let data = try? JSONEncoder().encode(all) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private static func load() -> [String: Correction] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: Correction].self, from: data) else {
            return [:]
        }
        return decoded
    }
}

private extension UnifiedArtist {
    /// Spotify's photo and link added to an artist found elsewhere. Its
    /// generated genre sentence never replaces a real bio.
    mutating func applySpotify(_ spotify: SpotifyArtist) {
        spotifyArtist = spotify
        spotifyURL = spotify.externalUrls.spotify
        source = .spotify
        if !spotify.images.isEmpty {
            images = spotify.images.map { UnifiedImage(from: $0) }
            imageSource = .spotify
            imagePageURL = nil
        }
        if genres.isEmpty { genres = spotify.genres }
        if profile.isEmpty {
            profile = spotify.profile
            bioSource = .spotify
        }
    }
}

// MARK: - Errors

enum HybridMusicAPIError: Error, LocalizedError {
    case noArtistFound
    case allServicesFailed([Error])

    var errorDescription: String? {
        switch self {
        case .noArtistFound:
            return "No artist found on any platform"
        case .allServicesFailed(let errors):
            return "All services failed: \(errors.map { $0.localizedDescription }.joined(separator: ", "))"
        }
    }
}
