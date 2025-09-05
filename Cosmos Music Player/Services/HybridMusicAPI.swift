//
//  HybridMusicAPI.swift
//  Cosmos Music Player
//
//  Hybrid music API service that tries Discogs first, then falls back to Spotify
//

import Foundation

// MARK: - Unified Artist Model

struct UnifiedArtist {
    let id: String
    let name: String
    let profile: String
    let images: [UnifiedImage]
    let source: MusicAPISource
    
    // Internal data for accessing original objects if needed
    let discogsArtist: DiscogsArtist?
    let spotifyArtist: SpotifyArtist?
    
    init(from discogsArtist: DiscogsArtist) {
        self.id = String(discogsArtist.id)
        self.name = discogsArtist.name
        self.profile = discogsArtist.profile
        self.images = discogsArtist.images.map { UnifiedImage(from: $0) }
        self.source = .discogs
        self.discogsArtist = discogsArtist
        self.spotifyArtist = nil
    }
    
    init(from spotifyArtist: SpotifyArtist) {
        self.id = spotifyArtist.id
        self.name = spotifyArtist.name
        self.profile = spotifyArtist.profile
        self.images = spotifyArtist.images.map { UnifiedImage(from: $0) }
        self.source = .spotify
        self.discogsArtist = nil
        self.spotifyArtist = spotifyArtist
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
}

enum MusicAPISource {
    case discogs
    case spotify
    
    var rawValue: String {
        switch self {
        case .discogs: return "discogs"
        case .spotify: return "spotify"
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
        // Cache for 7 days
        return Date().timeIntervalSince(cachedAt) > 7 * 24 * 60 * 60
    }
}

// Make UnifiedArtist and UnifiedImage Codable
extension UnifiedArtist: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, profile, images, source
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
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(profile, forKey: .profile)
        try container.encode(images, forKey: .images)
        try container.encode(source, forKey: .source)
    }
}

extension UnifiedImage: Codable {}
extension MusicAPISource: Codable {}

// MARK: - Hybrid Music API Service

class HybridMusicAPIService: ObservableObject {
    @MainActor static let shared = HybridMusicAPIService()
    
    private let discogsAPI: DiscogsAPIService
    private let spotifyAPI: SpotifyAPIService
    
    private let cache = NSCache<NSString, CachedUnifiedArtistInfo>()
    private let cacheDirectory: URL
    
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
    
    func searchArtist(name: String) async throws -> UnifiedArtist? {
        print("🎵 Hybrid: Searching for artist: \(name)")
        
        // Check cache first
        if let cached = getCachedArtist(name: name), !cached.isExpired {
            print("✅ Hybrid: Found cached artist: \(name) (source: \(cached.unifiedArtist.source))")
            return cached.unifiedArtist
        }
        
        // Try Discogs first
        print("🎯 Hybrid: Trying Discogs for: \(name)")
        do {
            if let discogsArtist = try await discogsAPI.searchArtist(name: name) {
                print("✅ Hybrid: Found on Discogs: \(discogsArtist.name)")
                let unifiedArtist = UnifiedArtist(from: discogsArtist)
                cacheArtist(name: name, artist: unifiedArtist)
                return unifiedArtist
            }
        } catch {
            print("⚠️ Hybrid: Discogs failed: \(error.localizedDescription)")
        }
        
        // Fallback to Spotify
        print("🎯 Hybrid: Falling back to Spotify for: \(name)")
        do {
            if let spotifyArtist = try await spotifyAPI.searchArtist(name: name) {
                print("✅ Hybrid: Found on Spotify: \(spotifyArtist.name)")
                let unifiedArtist = UnifiedArtist(from: spotifyArtist)
                cacheArtist(name: name, artist: unifiedArtist)
                return unifiedArtist
            }
        } catch {
            print("⚠️ Hybrid: Spotify failed: \(error.localizedDescription)")
        }
        
        print("❌ Hybrid: No artist found on either platform for: \(name)")
        return nil
    }
    
    // Search for alternative artist - try different source than current one
    func searchAlternativeArtist(name: String, currentSource: MusicAPISource?) async throws -> UnifiedArtist? {
        print("🔄 Hybrid: Searching for alternative artist: \(name), avoiding source: \(currentSource?.rawValue ?? "none")")
        
        // If current source is Discogs, try Spotify first
        if currentSource == .discogs {
            print("🎯 Hybrid: Trying Spotify as alternative for: \(name)")
            do {
                if let spotifyArtist = try await spotifyAPI.searchArtist(name: name) {
                    print("✅ Hybrid: Found alternative on Spotify: \(spotifyArtist.name)")
                    let unifiedArtist = UnifiedArtist(from: spotifyArtist)
                    cacheArtist(name: name, artist: unifiedArtist)
                    return unifiedArtist
                }
            } catch {
                print("⚠️ Hybrid: Spotify alternative failed: \(error.localizedDescription)")
            }
        }
        
        // If current source is Spotify, try Discogs
        if currentSource == .spotify {
            print("🎯 Hybrid: Trying Discogs as alternative for: \(name)")
            do {
                if let discogsArtist = try await discogsAPI.searchArtist(name: name) {
                    print("✅ Hybrid: Found alternative on Discogs: \(discogsArtist.name)")
                    let unifiedArtist = UnifiedArtist(from: discogsArtist)
                    cacheArtist(name: name, artist: unifiedArtist)
                    return unifiedArtist
                }
            } catch {
                print("⚠️ Hybrid: Discogs alternative failed: \(error.localizedDescription)")
            }
        }
        
        // If no current source or first alternative failed, try the opposite order
        if currentSource == nil {
            return try await searchArtist(name: name)
        }
        
        print("❌ Hybrid: No alternative found for: \(name)")
        return nil
    }
    
    // Search for similar/alternative artist names
    func searchSimilarArtist(originalName: String, currentSource: MusicAPISource?) async throws -> UnifiedArtist? {
        print("🔍 Hybrid: Searching for similar artist names for: \(originalName)")
        
        // Generate variations of the artist name
        let variations = generateNameVariations(originalName)
        
        for variation in variations {
            if variation == originalName { continue } // Skip original name
            
            print("🎯 Hybrid: Trying variation: \(variation)")
            do {
                if let result = try await searchAlternativeArtist(name: variation, currentSource: currentSource) {
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
    
    private func getCachedArtist(name: String) -> CachedUnifiedArtistInfo? {
        let key = NSString(string: name.lowercased())
        
        // Check memory cache first
        if let cached = cache.object(forKey: key) {
            return cached
        }
        
        // Check disk cache
        let filename = name.lowercased().replacingOccurrences(of: " ", with: "_") + ".json"
        let fileURL = cacheDirectory.appendingPathComponent(filename)
        
        guard let data = try? Data(contentsOf: fileURL),
              let cached = try? JSONDecoder().decode(CachedUnifiedArtistInfo.self, from: data) else {
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
        let filename = name.lowercased().replacingOccurrences(of: " ", with: "_") + ".json"
        let fileURL = cacheDirectory.appendingPathComponent(filename)
        
        do {
            let data = try JSONEncoder().encode(cached)
            try data.write(to: fileURL)
            print("💾 Hybrid: Cached artist data for: \(name) (source: \(artist.source))")
        } catch {
            print("❌ Hybrid: Failed to cache artist data: \(error)")
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