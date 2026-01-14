//
//  LyricsManager.swift
//  Cosmos Music Player
//
//  Manages lyrics fetching from embedded metadata and lrclib.net
//

import Foundation
import AVFoundation

struct LyricsLine: Equatable, Codable {
    let timestamp: TimeInterval?
    let text: String
}

struct Lyrics: Codable {
    let plainLyrics: String
    let syncedLyrics: [LyricsLine]
    let isInstrumental: Bool
    let source: LyricsSource

    enum LyricsSource: String, Codable {
        case embedded
        case lrclib
        case none
    }
}

actor LyricsManager {
    static let shared = LyricsManager()

    private var cache: [String: Lyrics] = [:]
    private let baseURL = "https://lrclib.net/api"
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        Task {
            await loadCacheFromDisk()
        }
    }

    // MARK: - Public API

    func getLyrics(for track: Track) async -> Lyrics? {
        // Check memory cache first
        if let cached = cache[track.stableId] {
            print("📝 Using cached lyrics for: \(track.title)")
            return cached
        }

        // Check disk cache
        if let diskCached = await loadLyricsFromDisk(trackId: track.stableId) {
            print("📝 Loaded lyrics from disk for: \(track.title)")
            cache[track.stableId] = diskCached
            return diskCached
        }

        // Try embedded lyrics first
        if let embedded = await getEmbeddedLyrics(for: track) {
            print("📝 Found embedded lyrics for: \(track.title)")
            cache[track.stableId] = embedded
            await saveLyricsToDisk(lyrics: embedded, trackId: track.stableId)
            return embedded
        }

        // Fallback to lrclib.net
        if let fetched = await fetchFromLRCLib(for: track) {
            print("📝 Fetched lyrics from lrclib.net for: \(track.title)")
            cache[track.stableId] = fetched
            await saveLyricsToDisk(lyrics: fetched, trackId: track.stableId)
            return fetched
        }

        print("⚠️ No lyrics found for: \(track.title)")
        return nil
    }

    func clearCache() {
        cache.removeAll()

        // Clear disk cache
        Task {
            await clearDiskCache()
        }

        print("🗑️ Lyrics cache cleared")
    }

    // MARK: - Embedded Lyrics

    private func getEmbeddedLyrics(for track: Track) async -> Lyrics? {
        let url = URL(fileURLWithPath: track.path)

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let asset = AVAsset(url: url)
                let metadata = asset.commonMetadata

                // Check for lyrics in metadata
                for item in metadata {
                    if item.commonKey == .commonKeyDescription ||
                       item.identifier?.rawValue.contains("lyrics") == true {
                        if let lyricsText = item.stringValue, !lyricsText.isEmpty {
                            let lyrics = self.parseLyrics(lyricsText, source: .embedded)
                            continuation.resume(returning: lyrics)
                            return
                        }
                    }
                }

                continuation.resume(returning: nil)
            }
        }
    }

    // MARK: - LRCLIB API

    private func fetchFromLRCLib(for track: Track) async -> Lyrics? {
        guard let artistName = try? getArtistName(for: track),
              let albumName = try? getAlbumName(for: track),
              !artistName.isEmpty else {
            print("⚠️ Missing metadata for lrclib.net lookup")
            return nil
        }

        let durationSeconds = Double((track.durationMs ?? 0)) / 1000.0

        // Try direct get first
        if let lyrics = await fetchDirectFromLRCLib(
            trackName: track.title,
            artistName: artistName,
            albumName: albumName,
            duration: durationSeconds
        ) {
            // If we got synced lyrics, return immediately
            if !lyrics.syncedLyrics.isEmpty {
                print("✅ Got synced lyrics from /api/get")
                return lyrics
            }

            // We got plain lyrics, but let's try to find synced via search
            print("⚠️ Got plain lyrics, searching for synced version...")
        }

        // Try search to find synced lyrics
        if let syncedLyrics = await searchForSyncedLyrics(
            trackName: track.title,
            artistName: artistName,
            duration: durationSeconds
        ) {
            print("✅ Found synced lyrics via /api/search")
            return syncedLyrics
        }

        // Return whatever we got from direct fetch (could be plain lyrics or nil)
        return await fetchDirectFromLRCLib(
            trackName: track.title,
            artistName: artistName,
            albumName: albumName,
            duration: durationSeconds
        )
    }

    private func fetchDirectFromLRCLib(
        trackName: String,
        artistName: String,
        albumName: String,
        duration: Double
    ) async -> Lyrics? {
        var components = URLComponents(string: "\(baseURL)/get")
        components?.queryItems = [
            URLQueryItem(name: "track_name", value: trackName),
            URLQueryItem(name: "artist_name", value: artistName),
            URLQueryItem(name: "album_name", value: albumName),
            URLQueryItem(name: "duration", value: String(format: "%.0f", duration))
        ]

        guard let url = components?.url else {
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue("Cosmos Music Player/1.0 (https://github.com/clquwu/Cosmos-Music-Player)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return nil
            }

            if httpResponse.statusCode == 404 {
                return nil
            }

            guard httpResponse.statusCode == 200 else {
                return nil
            }

            let lrcResponse = try decoder.decode(LRCLibResponse.self, from: data)
            return parseLRCLibResponse(lrcResponse)

        } catch {
            print("❌ Failed to fetch from lrclib.net: \(error)")
            return nil
        }
    }

    private func searchForSyncedLyrics(
        trackName: String,
        artistName: String,
        duration: Double
    ) async -> Lyrics? {
        var components = URLComponents(string: "\(baseURL)/search")
        components?.queryItems = [
            URLQueryItem(name: "track_name", value: trackName),
            URLQueryItem(name: "artist_name", value: artistName)
        ]

        guard let url = components?.url else {
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue("Cosmos Music Player/1.0 (https://github.com/clquwu/Cosmos-Music-Player)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }

            let results = try decoder.decode([LRCLibResponse].self, from: data)

            // Filter and prioritize:
            // 1. Must have synced lyrics
            // 2. Prefer duration match (within ±2 seconds)
            // 3. Pick the first matching result

            let syncedResults = results.filter {
                $0.syncedLyrics != nil && !($0.syncedLyrics?.isEmpty ?? true)
            }

            // Try exact duration match first (±2 seconds)
            if let exactMatch = syncedResults.first(where: {
                abs($0.duration - duration) <= 2
            }) {
                print("📝 Found exact duration match with synced lyrics")
                return parseLRCLibResponse(exactMatch)
            }

            // Otherwise take first synced result
            if let firstSynced = syncedResults.first {
                print("📝 Using first synced lyrics result (duration mismatch)")
                return parseLRCLibResponse(firstSynced)
            }

            return nil

        } catch {
            print("❌ Failed to search lrclib.net: \(error)")
            return nil
        }
    }

    // MARK: - Helper Methods

    private func getArtistName(for track: Track) throws -> String? {
        guard let artistId = track.artistId else { return nil }
        return try DatabaseManager.shared.read { db in
            try Artist.fetchOne(db, key: artistId)?.name
        }
    }

    private func getAlbumName(for track: Track) throws -> String? {
        guard let albumId = track.albumId else { return nil }
        return try DatabaseManager.shared.read { db in
            try Album.fetchOne(db, key: albumId)?.title
        }
    }

    private func parseLyrics(_ text: String, source: Lyrics.LyricsSource) -> Lyrics {
        // Check if lyrics are synced (contain timestamps like [00:12.34])
        let timestampPattern = /\[(\d{2}):(\d{2})\.(\d{2})\]/
        let hasSyncedLyrics = text.contains(timestampPattern)

        if hasSyncedLyrics {
            let syncedLines = parseSyncedLyrics(text)
            let plainText = syncedLines.map { $0.text }.joined(separator: "\n")
            return Lyrics(plainLyrics: plainText, syncedLyrics: syncedLines, isInstrumental: false, source: source)
        } else {
            return Lyrics(plainLyrics: text, syncedLyrics: [], isInstrumental: false, source: source)
        }
    }

    private func parseSyncedLyrics(_ lrcText: String) -> [LyricsLine] {
        var lines: [LyricsLine] = []

        for line in lrcText.components(separatedBy: .newlines) {
            // Match [mm:ss.xx] timestamp format
            let pattern = /\[(\d{2}):(\d{2})\.(\d{2})\]\s*(.+)/

            if let match = try? pattern.firstMatch(in: line) {
                let minutes = Double(match.1) ?? 0
                let seconds = Double(match.2) ?? 0
                let centiseconds = Double(match.3) ?? 0
                let text = String(match.4)

                let timestamp = (minutes * 60) + seconds + (centiseconds / 100)
                lines.append(LyricsLine(timestamp: timestamp, text: text))
            }
        }

        return lines.sorted { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) }
    }

    private func parseLRCLibResponse(_ response: LRCLibResponse) -> Lyrics {
        if response.instrumental {
            return Lyrics(plainLyrics: "", syncedLyrics: [], isInstrumental: true, source: .lrclib)
        }

        let plainLyrics = response.plainLyrics ?? ""
        var syncedLines: [LyricsLine] = []

        if let syncedText = response.syncedLyrics {
            syncedLines = parseSyncedLyrics(syncedText)
        }

        return Lyrics(plainLyrics: plainLyrics, syncedLyrics: syncedLines, isInstrumental: false, source: .lrclib)
    }

    // MARK: - Disk Cache

    private func getLyricsCacheDirectory() -> URL? {
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let cacheDir = documentsURL.appendingPathComponent("lyrics-cache", isDirectory: true)

        // Create directory if it doesn't exist
        if !fileManager.fileExists(atPath: cacheDir.path) {
            try? fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        }

        return cacheDir
    }

    private func getLyricsFileURL(trackId: String) -> URL? {
        guard let cacheDir = getLyricsCacheDirectory() else { return nil }
        return cacheDir.appendingPathComponent("\(trackId).json")
    }

    private func saveLyricsToDisk(lyrics: Lyrics, trackId: String) async {
        guard let fileURL = getLyricsFileURL(trackId: trackId) else {
            print("❌ Failed to get lyrics cache file URL")
            return
        }

        do {
            let data = try encoder.encode(lyrics)
            try data.write(to: fileURL, options: .atomic)
            print("💾 Saved lyrics to disk: \(fileURL.lastPathComponent)")
            print("   📍 Path: \(fileURL.path)")
        } catch {
            print("❌ Failed to save lyrics to disk: \(error)")
        }
    }

    private func loadLyricsFromDisk(trackId: String) async -> Lyrics? {
        guard let fileURL = getLyricsFileURL(trackId: trackId) else {
            print("⚠️ Failed to get lyrics file URL for: \(trackId)")
            return nil
        }

        guard fileManager.fileExists(atPath: fileURL.path) else {
            print("⚠️ Lyrics file not found on disk for: \(trackId)")
            return nil
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let lyrics = try decoder.decode(Lyrics.self, from: data)
            print("✅ Loaded lyrics from disk: \(fileURL.lastPathComponent)")
            return lyrics
        } catch {
            print("❌ Failed to load lyrics from disk: \(error)")
            print("   File: \(fileURL.path)")
            // Delete corrupted file
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
    }

    private func loadCacheFromDisk() async {
        guard let cacheDir = getLyricsCacheDirectory() else {
            print("❌ Failed to get lyrics cache directory")
            return
        }

        print("📁 Loading lyrics cache from: \(cacheDir.path)")

        do {
            let files = try fileManager.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)
            print("📁 Found \(files.count) total files in lyrics cache")

            let jsonFiles = files.filter { $0.pathExtension == "json" }
            print("📁 Found \(jsonFiles.count) JSON files")

            var loadedCount = 0

            for fileURL in jsonFiles {
                let trackId = fileURL.deletingPathExtension().lastPathComponent

                if let lyrics = await loadLyricsFromDisk(trackId: trackId) {
                    cache[trackId] = lyrics
                    loadedCount += 1
                }
            }

            if loadedCount > 0 {
                print("💾 Successfully loaded \(loadedCount) lyrics from disk cache")
            } else {
                print("💾 No lyrics loaded from disk cache")
            }
        } catch {
            print("❌ Failed to load lyrics cache from disk: \(error)")
        }
    }

    private func clearDiskCache() async {
        guard let cacheDir = getLyricsCacheDirectory() else { return }

        do {
            try fileManager.removeItem(at: cacheDir)
            try fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            print("💾 Cleared lyrics disk cache")
        } catch {
            print("❌ Failed to clear lyrics disk cache: \(error)")
        }
    }
}

// MARK: - API Models

private struct LRCLibResponse: Codable {
    let id: Int
    let trackName: String
    let artistName: String
    let albumName: String
    let duration: Double
    let instrumental: Bool
    let plainLyrics: String?
    let syncedLyrics: String?
}
