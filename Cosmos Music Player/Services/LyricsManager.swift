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
        let ext = url.pathExtension.lowercased()

        switch ext {
        case "flac":
            if let lyricsText = await extractFlacLyrics(from: url) {
                return parseLyrics(lyricsText, source: .embedded)
            }
        case "mp3":
            if let lyricsText = await extractID3Lyrics(from: url) {
                return parseLyrics(lyricsText, source: .embedded)
            }
        case "dsf":
            if let lyricsText = await extractDSFLyrics(from: url) {
                return parseLyrics(lyricsText, source: .embedded)
            }
        case "ogg", "opus":
            if let lyricsText = await extractScannedVorbisLyrics(from: url) {
                return parseLyrics(lyricsText, source: .embedded)
            }
        case "dff":
            if let lyricsText = await extractScannedID3Lyrics(from: url) {
                return parseLyrics(lyricsText, source: .embedded)
            }
        default:
            break
        }

        if let lyricsText = await extractAVFoundationLyrics(from: url) {
            return parseLyrics(lyricsText, source: .embedded)
        }

        return nil
    }

    private nonisolated func extractAVFoundationLyrics(from url: URL) async -> String? {
        let asset = AVURLAsset(url: url)

        do {
            let commonMetadata = try await asset.load(.commonMetadata)
            let allMetadata = try await asset.load(.metadata)
            let metadataGroups = [commonMetadata, allMetadata]

            for metadata in metadataGroups.flatMap({ $0 }) {
                let commonKey = metadata.commonKey?.rawValue.lowercased()
                let identifier = metadata.identifier?.rawValue.lowercased()
                let keySpace = metadata.keySpace?.rawValue.lowercased()
                let rawKey = (metadata.key as? String)?.lowercased()

                let looksLikeLyrics =
                    commonKey == "description" ||
                    commonKey == "lyrics" ||
                    rawKey?.contains("lyrics") == true ||
                    rawKey?.contains("\u{00A9}lyr") == true ||
                    identifier?.contains("lyrics") == true ||
                    identifier?.contains("uslt") == true ||
                    identifier?.contains("\u{00A9}lyr") == true ||
                    keySpace?.contains("lyrics") == true

                guard looksLikeLyrics,
                      let lyricsText = try? await metadata.load(.stringValue),
                      isUsableLyricsText(lyricsText) else {
                    continue
                }

                return lyricsText
            }
        } catch {
            print("⚠️ Failed to read AVFoundation lyrics metadata for \(url.lastPathComponent): \(error)")
        }

        return nil
    }

    private nonisolated func extractFlacLyrics(from url: URL) async -> String? {
        guard let data = await readFileData(url) else { return nil }
        guard data.count >= 4,
              data[0] == 0x66, data[1] == 0x4C, data[2] == 0x61, data[3] == 0x43 else {
            return nil
        }

        var offset = 4

        while offset + 4 <= data.count {
            let blockHeader = data[offset]
            let isLast = (blockHeader & 0x80) != 0
            let blockType = blockHeader & 0x7F
            let blockSize = Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            offset += 4

            guard blockSize >= 0, offset + blockSize <= data.count else {
                return nil
            }

            if blockType == 4 {
                let commentData = data.subdata(in: offset..<offset + blockSize)
                let comments = parseVorbisComments(commentData)
                if let lyrics = chooseVorbisLyrics(from: comments) {
                    return lyrics
                }
            }

            offset += blockSize
            if isLast { break }
        }

        return nil
    }

    private nonisolated func extractScannedVorbisLyrics(from url: URL) async -> String? {
        guard let data = await readFileData(url) else { return nil }
        return scanTextTags(
            in: data,
            keys: ["SYNCEDLYRICS", "SYNCLYRICS", "LYRICS", "UNSYNCEDLYRICS"]
        )
    }

    private nonisolated func extractID3Lyrics(from url: URL) async -> String? {
        guard let data = await readFileData(url), data.count >= 10 else { return nil }
        return parseID3Lyrics(from: data, offset: 0)
    }

    private nonisolated func extractScannedID3Lyrics(from url: URL) async -> String? {
        guard let data = await readFileData(url),
              let id3Range = data.range(of: Data([0x49, 0x44, 0x33])) else {
            return nil
        }

        return parseID3Lyrics(from: data, offset: id3Range.lowerBound)
    }

    private nonisolated func extractDSFLyrics(from url: URL) async -> String? {
        guard let data = await readFileData(url),
              data.count >= 28,
              data[0] == 0x44, data[1] == 0x53, data[2] == 0x44, data[3] == 0x20 else {
            return nil
        }

        let metadataPointer = readLittleEndianUInt64(from: data, offset: 20)
        guard metadataPointer > 0, metadataPointer < UInt64(data.count) else {
            return nil
        }

        return parseID3Lyrics(from: data, offset: Int(metadataPointer))
    }

    private nonisolated func readFileData(_ url: URL) async -> Data? {
        var coordinatorError: NSError?
        var readData: Data?
        var readError: Error?
        let coordinator = NSFileCoordinator()

        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinatorError) { readingURL in
            do {
                readData = try Data(contentsOf: readingURL, options: .mappedIfSafe)
            } catch {
                readError = error
            }
        }

        if let error = coordinatorError {
            print("⚠️ Failed to coordinate lyrics metadata read from \(url.lastPathComponent): \(error)")
        } else if let error = readError {
            print("⚠️ Failed to read lyrics metadata from \(url.lastPathComponent): \(error)")
        }

        return readData
    }

    private nonisolated func parseVorbisComments(_ data: Data) -> [String: [String]] {
        var comments: [String: [String]] = [:]
        var offset = 0

        guard offset + 4 <= data.count else { return comments }

        let vendorLength = readLittleEndianUInt32(from: data, offset: offset)
        offset += 4 + Int(vendorLength)

        guard offset + 4 <= data.count else { return comments }

        let commentCount = Int(readLittleEndianUInt32(from: data, offset: offset))
        offset += 4

        for _ in 0..<commentCount {
            guard offset + 4 <= data.count else { break }

            let commentLength = Int(readLittleEndianUInt32(from: data, offset: offset))
            offset += 4

            guard commentLength >= 0, offset + commentLength <= data.count else { break }

            if let commentString = String(data: data.subdata(in: offset..<offset + commentLength), encoding: .utf8) {
                let parts = commentString.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if parts.count == 2 {
                    let key = String(parts[0]).uppercased()
                    let value = String(parts[1])
                    comments[key, default: []].append(value)
                }
            }

            offset += commentLength
        }

        return comments
    }

    private nonisolated func chooseVorbisLyrics(from comments: [String: [String]]) -> String? {
        for key in ["SYNCEDLYRICS", "SYNCLYRICS", "LYRICS", "UNSYNCEDLYRICS"] {
            if let value = comments[key]?.first(where: isUsableLyricsText) {
                return value
            }
        }

        return nil
    }

    private nonisolated func scanTextTags(in data: Data, keys: [String]) -> String? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }

        for key in keys {
            guard let keyRange = text.range(of: "\(key)=", options: [.caseInsensitive]) else {
                continue
            }

            let valueStart = keyRange.upperBound
            let remaining = String(text[valueStart...])
            let nextTagRange = remaining.range(
                of: #"(?i)(SYNCEDLYRICS|SYNCLYRICS|UNSYNCEDLYRICS|LYRICS|TITLE|ARTIST|ALBUM|TRACKNUMBER|DATE)="#,
                options: .regularExpression
            )
            let rawValue = nextTagRange.map { String(remaining[..<$0.lowerBound]) } ?? remaining
            let cleanedValue = rawValue.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))

            if isUsableLyricsText(cleanedValue) {
                return cleanedValue
            }
        }

        return nil
    }

    private nonisolated func parseID3Lyrics(from data: Data, offset: Int) -> String? {
        guard offset >= 0,
              offset + 10 <= data.count,
              data[offset] == 0x49, data[offset + 1] == 0x44, data[offset + 2] == 0x33 else {
            return nil
        }

        let majorVersion = data[offset + 3]
        guard majorVersion == 3 || majorVersion == 4 else {
            return nil
        }

        let tagSize = readSynchsafeUInt32(from: data, offset: offset + 6)
        var frameOffset = offset + 10
        let endOffset = min(data.count, offset + 10 + Int(tagSize))

        while frameOffset + 10 <= endOffset {
            let frameId = String(data: data.subdata(in: frameOffset..<frameOffset + 4), encoding: .ascii) ?? ""
            if frameId.trimmingCharacters(in: .controlCharacters).isEmpty {
                break
            }

            let frameSize: UInt32
            if majorVersion == 4 {
                frameSize = readSynchsafeUInt32(from: data, offset: frameOffset + 4)
            } else {
                frameSize = readBigEndianUInt32(from: data, offset: frameOffset + 4)
            }

            frameOffset += 10

            guard frameSize > 0, frameOffset + Int(frameSize) <= endOffset else {
                break
            }

            let frameData = data.subdata(in: frameOffset..<frameOffset + Int(frameSize))

            if frameId == "USLT", let lyrics = parseUnsyncedLyricsFrame(frameData), isUsableLyricsText(lyrics) {
                return lyrics
            }

            if frameId == "SYLT", let lyrics = parseSimpleSyncedLyricsFrame(frameData), isUsableLyricsText(lyrics) {
                return lyrics
            }

            frameOffset += Int(frameSize)
        }

        return nil
    }

    private nonisolated func parseUnsyncedLyricsFrame(_ data: Data) -> String? {
        guard data.count > 4 else { return nil }

        let encoding = data[0]
        let payloadStart = 4

        guard let descriptorEnd = findStringTerminator(in: data, from: payloadStart, encoding: encoding) else {
            return nil
        }

        let lyricsStart = descriptorEnd + terminatorLength(for: encoding)
        guard lyricsStart < data.count else { return nil }

        return decodeText(data.subdata(in: lyricsStart..<data.count), encoding: encoding)
    }

    private nonisolated func parseSimpleSyncedLyricsFrame(_ data: Data) -> String? {
        guard data.count > 6 else { return nil }

        let encoding = data[0]
        let timestampFormat = data[4]
        guard timestampFormat == 2 else { return nil }

        var offset = 6

        guard let descriptorEnd = findStringTerminator(in: data, from: offset, encoding: encoding) else {
            return nil
        }

        offset = descriptorEnd + terminatorLength(for: encoding)
        var lrcLines: [String] = []

        while offset < data.count {
            guard let textEnd = findStringTerminator(in: data, from: offset, encoding: encoding) else {
                break
            }

            let textData = data.subdata(in: offset..<textEnd)
            offset = textEnd + terminatorLength(for: encoding)

            guard offset + 4 <= data.count else { break }

            let timestampMs = readBigEndianUInt32(from: data, offset: offset)
            offset += 4

            guard let text = decodeText(textData, encoding: encoding), !text.isEmpty else {
                continue
            }

            let timestamp = Double(timestampMs) / 1000.0
            let minutes = Int(timestamp / 60)
            let seconds = Int(timestamp.truncatingRemainder(dividingBy: 60))
            let centiseconds = Int((timestamp - floor(timestamp)) * 100)
            lrcLines.append(String(format: "[%02d:%02d.%02d]%@", minutes, seconds, centiseconds, text))
        }

        return lrcLines.isEmpty ? nil : lrcLines.joined(separator: "\n")
    }

    private nonisolated func findStringTerminator(in data: Data, from start: Int, encoding: UInt8) -> Int? {
        guard start < data.count else { return nil }

        if terminatorLength(for: encoding) == 2 {
            var index = start
            while index + 1 < data.count {
                if data[index] == 0, data[index + 1] == 0 {
                    return index
                }
                index += 2
            }
        } else {
            var index = start
            while index < data.count {
                if data[index] == 0 {
                    return index
                }
                index += 1
            }
        }

        return nil
    }

    private nonisolated func terminatorLength(for encoding: UInt8) -> Int {
        encoding == 1 || encoding == 2 ? 2 : 1
    }

    private nonisolated func decodeText(_ data: Data, encoding: UInt8) -> String? {
        let decoded: String?

        switch encoding {
        case 0:
            decoded = String(data: data, encoding: .isoLatin1)
        case 1:
            decoded = String(data: data, encoding: .utf16)
        case 2:
            decoded = String(data: data, encoding: .utf16BigEndian)
        case 3:
            decoded = String(data: data, encoding: .utf8)
        default:
            decoded = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        }

        return decoded?.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
    }

    private nonisolated func isUsableLyricsText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
        guard !trimmed.isEmpty else { return false }

        // Avoid treating generic metadata descriptions as lyrics.
        return trimmed.contains("\n") || trimmed.contains("[") || trimmed.count > 40
    }

    private nonisolated func readLittleEndianUInt64(from data: Data, offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= data.count else { return 0 }

        return UInt64(data[offset]) |
               UInt64(data[offset + 1]) << 8 |
               UInt64(data[offset + 2]) << 16 |
               UInt64(data[offset + 3]) << 24 |
               UInt64(data[offset + 4]) << 32 |
               UInt64(data[offset + 5]) << 40 |
               UInt64(data[offset + 6]) << 48 |
               UInt64(data[offset + 7]) << 56
    }

    private nonisolated func readLittleEndianUInt32(from data: Data, offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }

        return UInt32(data[offset]) |
               UInt32(data[offset + 1]) << 8 |
               UInt32(data[offset + 2]) << 16 |
               UInt32(data[offset + 3]) << 24
    }

    private nonisolated func readBigEndianUInt32(from data: Data, offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }

        return UInt32(data[offset]) << 24 |
               UInt32(data[offset + 1]) << 16 |
               UInt32(data[offset + 2]) << 8 |
               UInt32(data[offset + 3])
    }

    private nonisolated func readSynchsafeUInt32(from data: Data, offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }

        return UInt32(data[offset]) << 21 |
               UInt32(data[offset + 1]) << 14 |
               UInt32(data[offset + 2]) << 7 |
               UInt32(data[offset + 3])
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
        // Check if lyrics are synced (contain timestamps like [00:12.34] or [00:12.345])
        let timestampPattern = #"\[(\d{1,3}):(\d{2})(?:\.(\d{1,3}))?\]"#
        let hasSyncedLyrics = text.range(of: timestampPattern, options: .regularExpression) != nil

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
        let pattern = #"\[(\d{1,3}):(\d{2})(?:\.(\d{1,3}))?\]\s*(.*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return lines
        }

        for line in lrcText.components(separatedBy: .newlines) {
            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)

            // Match common [mm:ss], [mm:ss.xx], and [mm:ss.xxx] timestamp formats.
            if let match = regex.firstMatch(in: line, range: range) {
                let minutes = Double(nsLine.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(nsLine.substring(with: match.range(at: 2))) ?? 0
                let fractionRange = match.range(at: 3)
                let fractionText = fractionRange.location == NSNotFound ? "0" : nsLine.substring(with: fractionRange)
                let fractionDivisor = pow(10.0, Double(fractionText.count))
                let fraction = (Double(fractionText) ?? 0) / fractionDivisor
                let textRange = match.range(at: 4)
                let text = textRange.location == NSNotFound ? "" : nsLine.substring(with: textRange)

                let timestamp = (minutes * 60) + seconds + fraction
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
