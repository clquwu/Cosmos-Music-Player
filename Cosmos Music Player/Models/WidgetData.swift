//
//  WidgetData.swift
//  Cosmos Music Player
//
//  Shared data models for widget communication
//

import Foundation
import UIKit

// MARK: - Widget Track Data
struct WidgetTrackData: Codable {
    let trackId: String
    let title: String
    let artist: String
    let isPlaying: Bool
    let lastUpdated: Date
    let backgroundColorHex: String
    
    init(trackId: String, title: String, artist: String, isPlaying: Bool, backgroundColorHex: String) {
        self.trackId = trackId
        self.title = title
        self.artist = artist
        self.isPlaying = isPlaying
        self.lastUpdated = Date()
        self.backgroundColorHex = backgroundColorHex
    }
}

// MARK: - Widget Data Manager
final class WidgetDataManager: @unchecked Sendable {
    static let shared = WidgetDataManager()
    
    private let userDefaults: UserDefaults?
    private let currentTrackKey = "widget.currentTrack"
    private let artworkFileName = "widget_artwork.jpg"
    
    private init() {
        // Use App Group to share data between app and widget
        userDefaults = UserDefaults(suiteName: "group.dev.clq.Cosmos-Music-Player")
    }
    
    // MARK: - Track Data (without artwork to avoid 4MB limit)
    
    func saveCurrentTrack(_ data: WidgetTrackData, artworkData: Data? = nil) {
        guard let userDefaults = userDefaults else {
            print("⚠️ Widget: Failed to access shared UserDefaults")
            return
        }
        
        do {
            // Save track data to UserDefaults (small, < 1KB)
            let encoded = try JSONEncoder().encode(data)
            userDefaults.set(encoded, forKey: currentTrackKey)
            userDefaults.synchronize()
            print("✅ Widget: Saved track data - \(data.title) (\(encoded.count) bytes)")
            
            // Save artwork to shared file (can be > 4MB)
            if let artworkData = artworkData {
                saveArtwork(artworkData)
            } else {
                clearArtwork()
            }
        } catch {
            print("❌ Widget: Failed to encode track data - \(error)")
        }
    }
    
    func getCurrentTrack() -> WidgetTrackData? {
        print("📱 Widget: Attempting to retrieve track data...")
        print("📱 Widget: Using suite: group.dev.clq.Cosmos-Music-Player")
        
        guard let userDefaults = userDefaults else {
            print("⚠️ Widget: Failed to access shared UserDefaults - userDefaults is nil")
            return nil
        }
        
        guard let data = userDefaults.data(forKey: currentTrackKey) else {
            print("ℹ️ Widget: No track data found in UserDefaults for key: \(currentTrackKey)")
            print("ℹ️ Widget: Available keys: \(userDefaults.dictionaryRepresentation().keys)")
            return nil
        }
        
        print("📦 Widget: Found data, size: \(data.count) bytes")
        
        do {
            let decoded = try JSONDecoder().decode(WidgetTrackData.self, from: data)
            print("✅ Widget: Retrieved track data - \(decoded.title) by \(decoded.artist)")
            print("✅ Widget: Playing: \(decoded.isPlaying), Color: \(decoded.backgroundColorHex)")
            return decoded
        } catch {
            print("❌ Widget: Failed to decode track data - \(error)")
            print("❌ Widget: Data: \(String(data: data, encoding: .utf8) ?? "unable to decode")")
            return nil
        }
    }
    
    func clearCurrentTrack() {
        userDefaults?.removeObject(forKey: currentTrackKey)
        userDefaults?.synchronize()
        clearArtwork()
        print("🗑️ Widget: Cleared track data")
    }
    
    // MARK: - Artwork File Storage (avoids 4MB UserDefaults limit)
    
    private func getSharedContainerURL() -> URL? {
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.dev.clq.Cosmos-Music-Player")
    }
    
    private func saveArtwork(_ data: Data) {
        guard let containerURL = getSharedContainerURL() else {
            print("⚠️ Widget: Failed to get shared container URL")
            return
        }
        
        let fileURL = containerURL.appendingPathComponent(artworkFileName)
        
        do {
            try data.write(to: fileURL, options: .atomic)
            print("✅ Widget: Saved artwork to file (\(data.count) bytes)")
        } catch {
            print("❌ Widget: Failed to save artwork - \(error)")
        }
    }
    
    public func getArtwork() -> Data? {
        guard let containerURL = getSharedContainerURL() else {
            print("⚠️ Widget: Failed to get shared container URL")
            return nil
        }
        
        let fileURL = containerURL.appendingPathComponent(artworkFileName)
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("ℹ️ Widget: No artwork file found")
            return nil
        }
        
        do {
            let data = try Data(contentsOf: fileURL)
            print("✅ Widget: Loaded artwork from file (\(data.count) bytes)")
            return data
        } catch {
            print("❌ Widget: Failed to load artwork - \(error)")
            return nil
        }
    }
    
    private func clearArtwork() {
        guard let containerURL = getSharedContainerURL() else { return }
        
        let fileURL = containerURL.appendingPathComponent(artworkFileName)
        
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: fileURL)
            print("🗑️ Widget: Cleared artwork file")
        }
    }
}

// MARK: - Widget Playlist Data
public struct WidgetPlaylistData: Codable {
    public let id: String
    public let name: String
    public let trackCount: Int
    public let colorHex: String
    public let artworkPaths: [String] // Filenames of artwork files in shared container

    public init(id: String, name: String, trackCount: Int, colorHex: String, artworkPaths: [String]) {
        self.id = id
        self.name = name
        self.trackCount = trackCount
        self.colorHex = colorHex
        self.artworkPaths = artworkPaths
    }
}

// MARK: - Playlist Data Manager
public final class PlaylistDataManager: @unchecked Sendable {
    public static let shared = PlaylistDataManager()

    private let userDefaults: UserDefaults?
    private let playlistsKey = "widget.playlists"

    private init() {
        userDefaults = UserDefaults(suiteName: "group.dev.clq.Cosmos-Music-Player")
    }

    public func savePlaylists(_ playlists: [WidgetPlaylistData]) {
        guard let userDefaults = userDefaults else {
            print("⚠️ Widget: Failed to access shared UserDefaults for playlists")
            return
        }

        do {
            let encoded = try JSONEncoder().encode(playlists)
            userDefaults.set(encoded, forKey: playlistsKey)
            userDefaults.synchronize()
            print("✅ Widget: Saved \(playlists.count) playlists")
        } catch {
            print("❌ Widget: Failed to encode playlists - \(error)")
        }
    }

    public func getPlaylists() -> [WidgetPlaylistData] {
        guard let userDefaults = userDefaults else {
            print("⚠️ Widget: Failed to access shared UserDefaults for playlists")
            return []
        }

        guard let data = userDefaults.data(forKey: playlistsKey) else {
            print("ℹ️ Widget: No playlist data found")
            return []
        }

        do {
            let decoded = try JSONDecoder().decode([WidgetPlaylistData].self, from: data)
            print("✅ Widget: Retrieved \(decoded.count) playlists")
            return decoded
        } catch {
            print("❌ Widget: Failed to decode playlists - \(error)")
            return []
        }
    }

    public func clearPlaylists() {
        userDefaults?.removeObject(forKey: playlistsKey)
        userDefaults?.synchronize()
        print("🗑️ Widget: Cleared playlists")
    }
}

