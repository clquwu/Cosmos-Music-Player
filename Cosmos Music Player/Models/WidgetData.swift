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

    /// Every write to the App Group container runs here, one at a time.
    ///
    /// Saves and clears are dispatched from independent detached tasks, so
    /// without this they could interleave inside `saveArtwork`/`clearArtwork`
    /// and leave the defaults describing one track while the shared image file
    /// held another's.
    private let writeQueue = DispatchQueue(label: "dev.clq.cosmos.widget-write")
    /// The newest write that has been applied. Serialising alone is not enough:
    /// the two detached tasks can reach the queue in either order, so a stale
    /// save could still land after the clear that was meant to supersede it.
    /// Callers stamp their intent on the main actor, where the ordering is real.
    private var lastAppliedSequence: UInt64 = 0

    private init() {
        // Use App Group to share data between app and widget
        userDefaults = UserDefaults(suiteName: "group.dev.clq.Cosmos-Music-Player")
    }

    /// Discards a write that a newer one has already superseded.
    /// `sequence == 0` means "unsequenced" and always applies - the widget
    /// extension and other one-off callers do not order their writes.
    private func shouldApply(_ sequence: UInt64) -> Bool {
        guard sequence != 0 else { return true }
        guard sequence > lastAppliedSequence else { return false }
        lastAppliedSequence = sequence
        return true
    }

    // MARK: - Track Data (without artwork to avoid 4MB limit)

    /// What to do with the shared artwork file on this save.
    ///
    /// `unchanged` exists because the overwhelmingly common widget update is a
    /// play/pause of the track that is already showing. Re-encoding and
    /// rewriting a multi-megabyte cover for those was pure cost - the image on
    /// disk is already the right one.
    enum ArtworkUpdate {
        case replace(Data)
        case clear
        case unchanged
    }

    /// - Parameter sequence: the caller's ordering stamp. Pass a value that
    ///   increases with the order the updates were *decided* in; a write older
    ///   than one already applied is dropped. Omit it when the write is not
    ///   racing anything.
    func saveCurrentTrack(
        _ data: WidgetTrackData,
        artwork: ArtworkUpdate = .clear,
        sequence: UInt64 = 0
    ) {
        writeQueue.sync {
            guard shouldApply(sequence) else {
                print("⏭️ Widget: Dropped a superseded track update - \(data.title)")
                return
            }

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
                switch artwork {
                case .replace(let artworkData):
                    saveArtwork(artworkData)
                case .clear:
                    clearArtwork()
                case .unchanged:
                    break
                }
            } catch {
                print("❌ Widget: Failed to encode track data - \(error)")
            }
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
    
    /// - Parameter sequence: see `saveCurrentTrack(_:artwork:sequence:)`. A
    ///   clear that an in-flight save would otherwise overwrite is exactly what
    ///   this ordering exists for.
    func clearCurrentTrack(sequence: UInt64 = 0) {
        writeQueue.sync {
            guard shouldApply(sequence) else {
                print("⏭️ Widget: Dropped a superseded clear")
                return
            }
            userDefaults?.removeObject(forKey: currentTrackKey)
            userDefaults?.synchronize()
            clearArtwork()
            print("🗑️ Widget: Cleared track data")
        }
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
    public let customCoverImagePath: String? // Custom user-selected cover image

    public init(id: String, name: String, trackCount: Int, colorHex: String, artworkPaths: [String], customCoverImagePath: String? = nil) {
        self.id = id
        self.name = name
        self.trackCount = trackCount
        self.colorHex = colorHex
        self.artworkPaths = artworkPaths
        self.customCoverImagePath = customCoverImagePath
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

