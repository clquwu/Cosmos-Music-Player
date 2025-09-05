//
//  DiscogsAPI.swift
//  Cosmos Music Player
//
//  Discogs API service for fetching artist information
//

import Foundation

// MARK: - Discogs API Models

struct DiscogsSearchResponse: Codable {
    let pagination: DiscogsPagination
    let results: [DiscogsSearchResult]
}

struct DiscogsPagination: Codable {
    let page: Int
    let pages: Int
    let perPage: Int
    let items: Int
    let urls: DiscogsUrls?
    
    enum CodingKeys: String, CodingKey {
        case page, pages, items, urls
        case perPage = "per_page"
    }
}

struct DiscogsUrls: Codable {
    let last: String?
    let next: String?
}

struct DiscogsSearchResult: Codable {
    let id: Int
    let type: String
    let userDataId: Int?
    let masterID: Int?
    let masterUrl: String?
    let uri: String
    let title: String
    let thumb: String
    let coverImage: String
    let resourceUrl: String
    
    enum CodingKeys: String, CodingKey {
        case id, type, uri, title, thumb
        case userDataId = "user_data"
        case masterID = "master_id"
        case masterUrl = "master_url"
        case coverImage = "cover_image"
        case resourceUrl = "resource_url"
    }
}

struct DiscogsArtist: Codable {
    let id: Int
    let name: String
    let resourceUrl: String
    let uri: String
    let releasesUrl: String
    let images: [DiscogsImage]
    let profile: String
    let urls: [String]?
    let nameVariations: [String]?
    let aliases: [DiscogsAlias]?
    let members: [DiscogsMember]?
    
    enum CodingKeys: String, CodingKey {
        case id, name, uri, images, profile, urls, aliases, members
        case resourceUrl = "resource_url"
        case releasesUrl = "releases_url"
        case nameVariations = "namevariations"
    }
}

struct DiscogsImage: Codable {
    let type: String
    let uri: String
    let resourceUrl: String
    let uri150: String
    let width: Int
    let height: Int
    
    enum CodingKeys: String, CodingKey {
        case type, uri, width, height
        case resourceUrl = "resource_url"
        case uri150 = "uri150"
    }
}

struct DiscogsAlias: Codable {
    let id: Int
    let name: String
    let resourceUrl: String
    
    enum CodingKeys: String, CodingKey {
        case id, name
        case resourceUrl = "resource_url"
    }
}

struct DiscogsMember: Codable {
    let id: Int
    let name: String
    let resourceUrl: String
    let active: Bool?
    
    enum CodingKeys: String, CodingKey {
        case id, name, active
        case resourceUrl = "resource_url"
    }
}

// MARK: - Cached Artist Data

class CachedArtistInfo: NSObject, Codable {
    let artistName: String
    let discogsArtist: DiscogsArtist
    let cachedAt: Date
    
    init(artistName: String, discogsArtist: DiscogsArtist, cachedAt: Date) {
        self.artistName = artistName
        self.discogsArtist = discogsArtist
        self.cachedAt = cachedAt
        super.init()
    }
    
    var isExpired: Bool {
        // Cache for 7 days
        return Date().timeIntervalSince(cachedAt) > 7 * 24 * 60 * 60
    }
}

// MARK: - Discogs API Service

class DiscogsAPIService: ObservableObject, @unchecked Sendable {
    @MainActor static let shared = DiscogsAPIService()
    
    private let consumerKey = EnvironmentLoader.shared.discogsConsumerKey
    private let consumerSecret = EnvironmentLoader.shared.discogsConsumerSecret
    private let baseURL = "https://api.discogs.com"
    
    private let cache = NSCache<NSString, CachedArtistInfo>()
    private let cacheDirectory: URL
    
    private init() {
        // Set up cache directory
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        cacheDirectory = documentsPath.appendingPathComponent("DiscogsCache")
        
        // Create cache directory if it doesn't exist
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        // Configure NSCache
        cache.countLimit = 100 // Limit to 100 cached artists
    }
    
    // MARK: - Public API
    
    func searchArtist(name: String) async throws -> DiscogsArtist? {
        print("🎵 Discogs: Searching for artist: \(name)")
        
        // Check cache first
        if let cached = getCachedArtist(name: name), !cached.isExpired {
            print("✅ Discogs: Found cached artist: \(name)")
            return cached.discogsArtist
        }
        
        // Search for artist
        let searchResults = try await performSearch(query: name, type: "artist")
        
        // Find best match (exact match or case-insensitive match)
        guard let bestMatch = findBestMatch(for: name, in: searchResults) else {
            print("❌ Discogs: No matching artist found for: \(name)")
            return nil
        }
        
        print("🎯 Discogs: Found match: \(bestMatch.title)")
        
        // Get detailed artist information
        let artist = try await getArtistDetails(from: bestMatch.resourceUrl)
        
        // Cache the result
        cacheArtist(name: name, artist: artist)
        
        return artist
    }
    
    // MARK: - Private Methods
    
    private func performSearch(query: String, type: String) async throws -> [DiscogsSearchResult] {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let urlString = "\(baseURL)/database/search?type=\(type)&q=\(encodedQuery)&per_page=5"
        
        guard let url = URL(string: urlString) else {
            throw DiscogsAPIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue("Discogs key=\(consumerKey), secret=\(consumerSecret)", forHTTPHeaderField: "Authorization")
        request.setValue("CosmosPlayer/1.0", forHTTPHeaderField: "User-Agent")
        
        print("🌐 Discogs: Making request to: \(urlString)")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            print("📡 Discogs: Response status: \(httpResponse.statusCode)")
            if httpResponse.statusCode != 200 {
                throw DiscogsAPIError.httpError(httpResponse.statusCode)
            }
        }
        
        let searchResponse = try JSONDecoder().decode(DiscogsSearchResponse.self, from: data)
        print("🔍 Discogs: Found \(searchResponse.results.count) results")
        
        return searchResponse.results
    }
    
    private func findBestMatch(for artistName: String, in results: [DiscogsSearchResult]) -> DiscogsSearchResult? {
        let normalizedName = artistName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        
        // Try exact match first
        for result in results {
            let resultName = result.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if resultName == normalizedName {
                return result
            }
        }
        
        // Try partial match
        for result in results {
            let resultName = result.title.lowercased()
            if resultName.contains(normalizedName) || normalizedName.contains(resultName) {
                return result
            }
        }
        
        // Return first result if no exact match
        return results.first
    }
    
    private func getArtistDetails(from resourceUrl: String) async throws -> DiscogsArtist {
        guard let url = URL(string: resourceUrl) else {
            throw DiscogsAPIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue("Discogs key=\(consumerKey), secret=\(consumerSecret)", forHTTPHeaderField: "Authorization")
        request.setValue("CosmosPlayer/1.0", forHTTPHeaderField: "User-Agent")
        
        print("🌐 Discogs: Fetching artist details from: \(resourceUrl)")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw DiscogsAPIError.httpError(httpResponse.statusCode)
        }
        
        return try JSONDecoder().decode(DiscogsArtist.self, from: data)
    }
    
    // MARK: - Caching
    
    private func getCachedArtist(name: String) -> CachedArtistInfo? {
        let key = NSString(string: name.lowercased())
        
        // Check memory cache first
        if let cached = cache.object(forKey: key) {
            return cached
        }
        
        // Check disk cache
        let filename = name.lowercased().replacingOccurrences(of: " ", with: "_") + ".json"
        let fileURL = cacheDirectory.appendingPathComponent(filename)
        
        guard let data = try? Data(contentsOf: fileURL),
              let cached = try? JSONDecoder().decode(CachedArtistInfo.self, from: data) else {
            return nil
        }
        
        // Store in memory cache
        cache.setObject(cached, forKey: key)
        return cached
    }
    
    private func cacheArtist(name: String, artist: DiscogsArtist) {
        let cached = CachedArtistInfo(artistName: name, discogsArtist: artist, cachedAt: Date())
        let key = NSString(string: name.lowercased())
        
        // Store in memory cache
        cache.setObject(cached, forKey: key)
        
        // Store in disk cache
        let filename = name.lowercased().replacingOccurrences(of: " ", with: "_") + ".json"
        let fileURL = cacheDirectory.appendingPathComponent(filename)
        
        do {
            let data = try JSONEncoder().encode(cached)
            try data.write(to: fileURL)
            print("💾 Discogs: Cached artist data for: \(name)")
        } catch {
            print("❌ Discogs: Failed to cache artist data: \(error)")
        }
    }
}

// MARK: - Errors

enum DiscogsAPIError: Error, LocalizedError {
    case invalidURL
    case httpError(Int)
    case decodingError(Error)
    case networkError(Error)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .httpError(let code):
            return "HTTP Error: \(code)"
        case .decodingError(let error):
            return "Decoding Error: \(error.localizedDescription)"
        case .networkError(let error):
            return "Network Error: \(error.localizedDescription)"
        }
    }
}
