//
//  LyricsManager.swift
//  Cosmos Music Player
//
//  Manages lyrics fetching from embedded metadata and lrclib.net
//

import Foundation
import AVFoundation

/// One timed word from an Enhanced LRC ("A2") line.
///
/// A trailing entry with empty text is kept rather than discarded: the format
/// conventionally closes a line with a bare `<mm:ss.xx>` marking where the last
/// word *ends*, and that is the only place that information exists.
struct LyricsWord: Equatable, Codable {
    let timestamp: TimeInterval
    let text: String
}

struct LyricsLine: Equatable, Codable {
    let timestamp: TimeInterval?
    let text: String
    /// Word timings, when the source carried them. lrclib is line-level only,
    /// so in practice these come from a file's own embedded lyrics.
    var words: [LyricsWord]? = nil
}

struct Lyrics: Codable {
    let plainLyrics: String
    let syncedLyrics: [LyricsLine]
    let isInstrumental: Bool
    let source: LyricsSource
    /// The user's own correction for this song, in seconds; positive shows the
    /// lyrics earlier (the LRC `[offset:]` convention, in seconds). Optional so
    /// cache files written before it existed still decode, and kept here rather
    /// than anywhere else so it rides the existing per-song disk cache.
    var userOffset: TimeInterval? = nil

    enum LyricsSource: String, Codable {
        case embedded
        /// A `<song>.lrc` file beside the audio file.
        case sidecar
        case lrclib
        case none
    }
}

actor LyricsManager {
    static let shared = LyricsManager()

    private var cache: [String: Lyrics] = [:]
    /// Tracks whose folder had no sidecar `.lrc`, with that folder's
    /// modification date when it was looked at. Lets a cache hit skip the
    /// folder listing `sidecarLyricsURL` falls back to - adding, removing or
    /// renaming a file changes the folder's date, so a newly dropped-in
    /// `.lrc` is still noticed on the next open.
    private var noSidecarFolderDates: [String: Date] = [:]
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

    /// Lyrics for a track, from the fastest source that has them.
    ///
    /// Anything found is written to disk, so a track whose lyrics have been
    /// opened once keeps them with no connection afterwards. A confirmed
    /// *absence* is recorded too, with a shorter life, so a song lrclib simply
    /// does not have stops costing three network round trips every time its
    /// screen is opened.
    func getLyrics(for track: Track) async -> Lyrics? {
        let signpost = Perf.begin("Lyrics load")
        defer { Perf.end("Lyrics load", signpost) }
        if let cached = cache[track.stableId], !isCachedDescription(cached) {
            print("📝 Using cached lyrics for: \(track.title)")
            return await preferringNewerSidecar(over: cached, for: track)
        }

        if let diskCached = await loadLyricsFromDisk(trackId: track.stableId), !isCachedDescription(diskCached) {
            print("📝 Loaded lyrics from disk for: \(track.title)")
            cache[track.stableId] = diskCached
            return await preferringNewerSidecar(over: diskCached, for: track)
        }

        // Lyrics on the device need no network and are the user's own copy, so
        // they outrank anything lrclib could answer.
        if let local = await getLocalLyrics(for: track) {
            print("📝 Found local (\(local.source.rawValue)) lyrics for: \(track.title)")
            await store(local, for: track.stableId)
            return local
        }

        if isMissRemembered(for: track.stableId) {
            print("📝 Skipping lrclib - no match remembered for: \(track.title)")
            return nil
        }

        switch await fetchFromLRCLib(for: track) {
        case .found(let lyrics):
            print("📝 Fetched lyrics from lrclib.net for: \(track.title)")
            await store(lyrics, for: track.stableId)
            return lyrics

        case .noMatch:
            print("⚠️ No lyrics found for: \(track.title)")
            await rememberMiss(for: track.stableId)
            return nil

        case .unreachable:
            // Offline, or lrclib is down. That is not evidence the song has no
            // lyrics, so nothing is remembered and the next attempt tries again.
            print("📴 Could not reach lrclib for: \(track.title)")
            return nil
        }
    }

    /// Forces a fresh lookup, ignoring any remembered miss, and keeps whatever
    /// it finds for offline use. Backs the retry the lyrics screen offers when
    /// a track came back empty.
    @discardableResult
    func refreshLyrics(for track: Track) async -> Lyrics? {
        cache.removeValue(forKey: track.stableId)
        forgetMiss(for: track.stableId)

        if let local = await getLocalLyrics(for: track) {
            await store(local, for: track.stableId)
            return local
        }

        guard case .found(let lyrics) = await fetchFromLRCLib(for: track) else {
            return nil
        }

        await store(lyrics, for: track.stableId)
        return lyrics
    }

    /// Whether this track's lyrics are already on disk and will open offline.
    func hasOfflineLyrics(for track: Track) -> Bool {
        if cache[track.stableId] != nil { return true }
        guard let fileURL = getLyricsFileURL(trackId: track.stableId) else { return false }
        return fileManager.fileExists(atPath: fileURL.path)
    }

    private func store(_ lyrics: Lyrics, for stableId: String) async {
        cache[stableId] = lyrics
        forgetMiss(for: stableId)
        await saveLyricsToDisk(lyrics: lyrics, trackId: stableId)
    }

    // MARK: - User timing offset

    /// The per-song correction last saved for this track, if any.
    func userOffset(for stableId: String) async -> TimeInterval? {
        if let cached = cache[stableId] { return cached.userOffset }
        return await loadLyricsFromDisk(trackId: stableId)?.userOffset
    }

    /// Saves the user's timing correction alongside the song's cached lyrics,
    /// so it survives relaunches and offline use without a store of its own.
    /// Zero is stored as nil, which keeps an untouched song's file unchanged.
    func setUserOffset(_ offset: TimeInterval, for stableId: String) async {
        var lyrics: Lyrics
        if let cached = cache[stableId] {
            lyrics = cached
        } else if let diskCached = await loadLyricsFromDisk(trackId: stableId) {
            lyrics = diskCached
        } else {
            return
        }

        let normalized: TimeInterval? = abs(offset) < 0.001 ? nil : offset
        guard lyrics.userOffset != normalized else { return }
        lyrics.userOffset = normalized
        cache[stableId] = lyrics
        await saveLyricsToDisk(lyrics: lyrics, trackId: stableId)
    }

    func clearCache() {
        cache.removeAll()
        noSidecarFolderDates.removeAll()

        // Clear disk cache
        Task {
            await clearDiskCache()
        }

        print("🗑️ Lyrics cache cleared")
    }

    // MARK: - Local Lyrics

    /// Lyrics from the device, best first: embedded synced, a sidecar `.lrc`,
    /// then embedded unsynced. A sidecar is something the user put there on
    /// purpose, usually precisely because the file's own tag is plain text, so
    /// it outranks that - but not a synced tag, which is the track's own copy.
    private func getLocalLyrics(for track: Track) async -> Lyrics? {
        let embedded = await getEmbeddedLyrics(for: track)
        if let embedded, !embedded.syncedLyrics.isEmpty {
            return embedded
        }

        let sidecar = await getSidecarLyrics(for: track)
        if let sidecar, !sidecar.syncedLyrics.isEmpty {
            return sidecar
        }

        return embedded ?? sidecar
    }

    /// Swaps a cached lrclib (or older sidecar) result for a sidecar `.lrc`
    /// that appeared or changed after it was cached.
    ///
    /// Everything is cached forever per song, so without this an `.lrc` the
    /// user drops in to fix a wrong lrclib match would never be read. The
    /// modification-date test is what keeps a version the user explicitly
    /// picked from the lrclib list winning over an older sidecar.
    private func preferringNewerSidecar(over cached: Lyrics, for track: Track) async -> Lyrics {
        guard cached.source == .lrclib || cached.source == .sidecar else { return cached }

        let audioURL = DatabaseManager.localFileURL(forStoredPath: track.path)
        // Cache hits stay cheap: one stat of the folder instead of listing it
        // every time the lyrics are opened.
        let folderDate = Self.modificationDate(of: audioURL.deletingLastPathComponent())
        if let folderDate, noSidecarFolderDates[track.stableId] == folderDate {
            return cached
        }
        guard let sidecarURL = Self.sidecarLyricsURL(for: audioURL) else {
            if let folderDate {
                noSidecarFolderDates[track.stableId] = folderDate
            }
            return cached
        }
        noSidecarFolderDates[track.stableId] = nil
        guard let sidecarDate = Self.modificationDate(of: sidecarURL),
              let cacheURL = getLyricsFileURL(trackId: track.stableId),
              let cachedDate = Self.modificationDate(of: cacheURL),
              sidecarDate > cachedDate,
              let sidecar = await readSidecarLyrics(at: sidecarURL),
              !sidecar.syncedLyrics.isEmpty || cached.syncedLyrics.isEmpty else {
            return cached
        }

        print("📝 Using newer sidecar lyrics for: \(track.title)")
        await store(sidecar, for: track.stableId)
        return sidecar
    }

    // MARK: - Sidecar Lyrics

    /// Larger than any real lyrics file; anything bigger is not one.
    private static let maximumSidecarSize = 1_000_000

    private func getSidecarLyrics(for track: Track) async -> Lyrics? {
        // Same resolution as the embedded read: follows the app container if
        // iOS moved it. A security-scoped external file's sibling is not
        // covered by that file's own bookmark, so for those this finds nothing
        // unless the folder itself was granted.
        let audioURL = DatabaseManager.localFileURL(forStoredPath: track.path)
        guard let sidecarURL = Self.sidecarLyricsURL(for: audioURL) else { return nil }
        return await readSidecarLyrics(at: sidecarURL)
    }

    private func readSidecarLyrics(at url: URL) async -> Lyrics? {
        guard let data = await readFileData(url),
              !data.isEmpty, data.count <= Self.maximumSidecarSize,
              let text = Self.decodeSidecarText(data) else {
            return nil
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lyrics = parseLyrics(trimmed, source: .sidecar)
        guard !lyrics.syncedLyrics.isEmpty || !lyrics.plainLyrics.isEmpty else { return nil }
        print("📝 Read sidecar lyrics: \(url.lastPathComponent)")
        return lyrics
    }

    /// `<basename>.lrc` beside the audio file, matching the extension in any
    /// case. Also recognises an iCloud placeholder (`.<name>.lrc.icloud`) for
    /// one that has not been downloaded yet; the coordinated read fetches it.
    private nonisolated static func sidecarLyricsURL(for audioURL: URL) -> URL? {
        let directory = audioURL.deletingLastPathComponent()
        let baseName = audioURL.deletingPathExtension().lastPathComponent
        let fileManager = FileManager.default

        // The usual spellings first, so the common case costs no listing.
        for ext in ["lrc", "LRC"] {
            let candidate = directory.appendingPathComponent(baseName).appendingPathExtension(ext)
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
        }

        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return nil }
        let wantedBase = baseName.precomposedStringWithCanonicalMapping

        for name in names {
            var realName = name
            if realName.hasPrefix("."), realName.lowercased().hasSuffix(".icloud") {
                realName = String(realName.dropFirst().dropLast(".icloud".count))
            }

            let nameURL = URL(fileURLWithPath: realName)
            guard nameURL.pathExtension.lowercased() == "lrc",
                  nameURL.deletingPathExtension().lastPathComponent
                    .precomposedStringWithCanonicalMapping == wantedBase else {
                continue
            }
            return directory.appendingPathComponent(realName)
        }

        return nil
    }

    private nonisolated static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// LRC files in the wild are UTF-8 (with or without a BOM), UTF-16 from
    /// Windows tools, or a legacy single-byte code page.
    private nonisolated static func decodeSidecarText(_ data: Data) -> String? {
        let text: String?
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16)
        } else {
            text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .windowsCP1252)
                ?? String(data: data, encoding: .isoLatin1)
        }
        guard var text else { return nil }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text
    }

    // MARK: - Embedded Lyrics

    private func getEmbeddedLyrics(for track: Track) async -> Lyrics? {
        let url = DatabaseManager.localFileURL(forStoredPath: track.path)
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
        case "ogg", "oga", "opus":
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
        var entries: [(timestampMs: UInt32, text: String)] = []

        while offset < data.count {
            guard let textEnd = findStringTerminator(in: data, from: offset, encoding: encoding) else {
                break
            }

            let textData = data.subdata(in: offset..<textEnd)
            offset = textEnd + terminatorLength(for: encoding)

            guard offset + 4 <= data.count else { break }

            let timestampMs = readBigEndianUInt32(from: data, offset: offset)
            offset += 4

            // Untrimmed: in word-level frames the spaces and line breaks around
            // each entry are the only record of where words and lines divide.
            guard let text = decodeRawText(textData, encoding: encoding) else { continue }
            entries.append((timestampMs, text))
        }

        let isWordLevel = entries.contains { entry in
            entry.text.first.map(\.isNewline) == true || entry.text.last.map(\.isNewline) == true
        }

        let lrcLines = isWordLevel
            ? Self.mergeWordLevelSYLT(entries)
            : entries.compactMap { entry -> String? in
                let text = entry.text.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
                return text.isEmpty ? nil : "[\(Self.lrcStamp(milliseconds: entry.timestampMs))]\(text)"
            }

        return lrcLines.isEmpty ? nil : lrcLines.joined(separator: "\n")
    }

    /// Rebuilds lines from a word-level SYLT frame.
    ///
    /// Karaoke taggers write one entry per word or syllable and mark a new line
    /// with a leading (sometimes trailing) line break. Emitting each entry as a
    /// line of its own turned a verse into a column of single words; this joins
    /// them back into lines and keeps every word's time as Enhanced LRC, which
    /// the line parser already turns into exact word timings.
    private nonisolated static func mergeWordLevelSYLT(_ entries: [(timestampMs: UInt32, text: String)]) -> [String] {
        var lines: [String] = []
        var current: [(timestampMs: UInt32, text: String)] = []

        func closeLine() {
            defer { current.removeAll() }
            guard let first = current.first else { return }
            let body = current
                .map { "<\(lrcStamp(milliseconds: $0.timestampMs))>\($0.text)" }
                .joined()
            lines.append("[\(lrcStamp(milliseconds: first.timestampMs))]\(body)")
        }

        for entry in entries {
            var text = entry.text.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")

            if text.first == "\n" {
                closeLine()
                text = String(text.drop(while: { $0 == "\n" }))
            }

            let endsLine = text.last == "\n"
            // Any break left inside the entry is still a line break in it.
            let segments = text.split(separator: "\n", omittingEmptySubsequences: false)

            for (index, segment) in segments.enumerated() {
                if index > 0 { closeLine() }
                var word = String(segment)
                // A line's first word does not carry the space that separated
                // it from the previous line.
                if current.isEmpty {
                    word = String(word.drop(while: { $0.isWhitespace }))
                }
                guard !word.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                current.append((entry.timestampMs, word))
            }

            if endsLine { closeLine() }
        }

        closeLine()
        return lines
    }

    private nonisolated static func lrcStamp(milliseconds: UInt32) -> String {
        let total = Int(milliseconds)
        return String(format: "%02d:%02d.%03d", total / 60_000, (total / 1000) % 60, total % 1000)
    }

    /// `decodeText` without the trimming, for formats where surrounding
    /// whitespace is meaningful.
    private nonisolated func decodeRawText(_ data: Data, encoding: UInt8) -> String? {
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

        return decoded?.replacingOccurrences(of: "\u{FEFF}", with: "")
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
        guard trimmed.contains("\n") || trimmed.contains("[") || trimmed.count > 40 else { return false }

        // Liner notes and store descriptions end up in lyrics tags too, often
        // as HTML. Lyrics are short lines; a description is markup or prose.
        let lower = trimmed.lowercased()
        if ["<p>", "</p>", "<br", "</div>", "<div", "&nbsp;"].contains(where: lower.contains) {
            return false
        }
        if !trimmed.contains("[") {
            let lines = trimmed.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let averageLength = Double(trimmed.count) / Double(max(lines.count, 1))
            if averageLength > 120 { return false }
        }
        return true
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

    enum LookupOutcome {
        case found(Lyrics)
        /// lrclib answered, and nothing it returned is this song.
        case noMatch
        /// We never got an answer - offline, timeout, or lrclib is down.
        case unreachable
    }

    private func fetchFromLRCLib(for track: Track) async -> LookupOutcome {
        // Album and duration are both optional. I checked /api/get against the
        // live service rather than assuming: it answers 200 with neither
        // parameter, and supplying an album only changes *which* record wins
        // (Bohemian Rhapsody returns id 19079 bare, 19080 with the album). So
        // the exact-match endpoint is worth trying for every track, not only
        // for one carrying a full set of tags.
        guard let artistName = try? getArtistName(for: track), !artistName.isEmpty else {
            print("⚠️ No artist tag - cannot look up lyrics")
            return .noMatch
        }
        let albumName = (try? getAlbumName(for: track)) ?? nil
        let duration = await knownDuration(of: track)

        var reachedServer = false

        // 1. /api/get is an exact match. When it hits it is authoritative, so
        //    take synced lyrics from it and stop. Previously gated on having an
        //    album, which skipped it entirely for loose files and most singles -
        //    exactly the tracks whose tags are least likely to survive a search.
        var directHit: Lyrics?
        switch await fetchDirect(
            trackName: track.title,
            artistName: artistName,
            albumName: albumName,
            duration: duration
        ) {
        case .found(let lyrics):
            reachedServer = true
            if !lyrics.syncedLyrics.isEmpty || lyrics.isInstrumental {
                return .found(lyrics)
            }
            // Plain-only: hold on to it, but see if search has a synced copy.
            directHit = lyrics
        case .noMatch:
            reachedServer = true
        case .unreachable:
            break
        }

        // 2. Search by track+artist, then by a free-text query. Results are
        //    scored rather than taken in order - the old code accepted
        //    `first`, which happily returned a different song by a different
        //    artist whenever the tags were slightly off.
        let queries: [[URLQueryItem]] = [
            [URLQueryItem(name: "track_name", value: track.title),
             URLQueryItem(name: "artist_name", value: artistName)],
            [URLQueryItem(name: "q", value: "\(track.title) \(artistName)")]
        ]

        var best: (candidate: LRCLibResponse, score: Double)?

        queryLoop: for query in queries {
            switch await search(query) {
            case .unreachable:
                continue
            case .noMatch:
                reachedServer = true
                continue
            case .found(let results):
                reachedServer = true
                for result in results {
                    // Timestamps from a different cut of the song are wrong by
                    // exactly the difference, so a synced record has to match
                    // our running time far more closely than its words do. Its
                    // plain text may still be the right lyrics, so it stays in
                    // the running as a plain-only candidate.
                    let candidate = Self.hasSynced(result) && !Self.isSyncCompatible(result.duration, duration)
                        ? result.droppingSyncedLyrics()
                        : result
                    guard candidate.instrumental
                            || Self.hasSynced(candidate)
                            || !(candidate.plainLyrics?.isEmpty ?? true) else { continue }
                    let score = Self.matchScore(
                        candidate: candidate,
                        title: track.title,
                        artist: artistName,
                        album: albumName,
                        duration: duration
                    )
                    guard score >= Self.minimumMatchScore else { continue }
                    // A synced copy is the whole reason to keep looking.
                    let weighted = score + Self.syncedBonus(for: candidate, target: duration)
                    if best == nil || weighted > best!.score {
                        best = (candidate, weighted)
                    }
                }
                // A confident synced match ends the search; a weaker one still
                // lets the free-text query have a turn. Labelled: a bare
                // `break` here only left the switch, so the search never
                // actually stopped early.
                if let best, Self.hasSynced(best.candidate), best.score >= Self.confidentMatchScore {
                    break queryLoop
                }
            }
        }

        if let best {
            let lyrics = parseLRCLibResponse(best.candidate)
            // Never trade a synced result for a plain one.
            if !lyrics.syncedLyrics.isEmpty || directHit == nil {
                print("✅ lrclib match: \(best.candidate.artistName) - \(best.candidate.trackName) (score \(String(format: "%.2f", best.score)))")
                return .found(lyrics)
            }
        }

        if let directHit {
            return .found(directHit)
        }

        return reachedServer ? .noMatch : .unreachable
    }

    // MARK: Alternate versions

    /// One lyrics record lrclib holds for roughly this song.
    struct LyricsCandidate: Identifiable, Equatable, Sendable {
        let id: Int
        let trackName: String
        let artistName: String
        let albumName: String
        let duration: TimeInterval
        let hasSyncedLyrics: Bool
        let isInstrumental: Bool
    }

    /// Every record lrclib can offer for a track, best match first.
    ///
    /// Automatic matching has to pick one and be silent about the rest, and
    /// when it picks wrong - a live version, a cover, the wrong edit - there
    /// was nothing the user could do about it. The search results were already
    /// being fetched and thrown away; this hands them over instead.
    func alternatives(for track: Track) async -> [LyricsCandidate] {
        guard let artistName = try? getArtistName(for: track), !artistName.isEmpty else {
            return []
        }
        let albumName = (try? getAlbumName(for: track)) ?? nil
        let duration = await knownDuration(of: track)

        var queries: [[URLQueryItem]] = []
        if let albumName, !albumName.isEmpty {
            // Verified against the live service: /api/search does accept an
            // album, and it discriminates between records of the same song.
            queries.append([
                URLQueryItem(name: "track_name", value: track.title),
                URLQueryItem(name: "artist_name", value: artistName),
                URLQueryItem(name: "album_name", value: albumName)
            ])
        }
        queries.append([
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: artistName)
        ])
        queries.append([URLQueryItem(name: "q", value: "\(track.title) \(artistName)")])

        var seen: Set<Int> = []
        var scored: [(candidate: LyricsCandidate, score: Double, bonus: Double)] = []

        for query in queries {
            guard case .found(let results) = await search(query) else { continue }

            for response in results where !seen.contains(response.id) {
                seen.insert(response.id)
                scored.append((
                    LyricsCandidate(
                        id: response.id,
                        trackName: response.trackName,
                        artistName: response.artistName,
                        albumName: response.albumName,
                        duration: response.duration,
                        hasSyncedLyrics: Self.hasSynced(response),
                        isInstrumental: response.instrumental
                    ),
                    Self.matchScore(
                        candidate: response,
                        title: track.title,
                        artist: artistName,
                        album: albumName,
                        duration: duration
                    ),
                    Self.syncedBonus(for: response, target: duration)
                ))
            }
        }

        // Deliberately not filtered by `minimumMatchScore`: this list exists
        // precisely for when the automatic choice was wrong, so a record the
        // scorer rejected may be the one the user is looking for. Synced
        // records still sort above plain ones of equal quality.
        return scored
            .sorted { ($0.score + $0.bonus) > ($1.score + $1.bonus) }
            .prefix(25)
            .map(\.candidate)
    }

    /// Adopts a specific lrclib record and keeps it for offline use.
    ///
    /// Uses /api/get/{id}, which the automatic path never touches. Writing it
    /// through the normal cache is what makes the choice stick: every later
    /// lookup is a cache hit, so it survives relaunches without any separate
    /// notion of a "user override" to keep in sync.
    @discardableResult
    func useAlternative(_ id: Int, for track: Track) async -> Lyrics? {
        let components = URLComponents(string: "\(baseURL)/get/\(id)")

        guard case .found(let response) = await perform(components, decoding: LRCLibResponse.self) else {
            return nil
        }

        let lyrics = parseLRCLibResponse(response)
        await store(lyrics, for: track.stableId)
        print("📝 Adopted lrclib record \(id) for: \(track.title)")
        return lyrics
    }

    // MARK: Scoring

    /// Below this a candidate is not this song, and showing it would be worse
    /// than showing nothing.
    private static let minimumMatchScore = 0.62
    /// Good enough to stop looking for a better one.
    private static let confidentMatchScore = 0.85

    private static func hasSynced(_ response: LRCLibResponse) -> Bool {
        !(response.syncedLyrics?.isEmpty ?? true)
    }

    /// How far a synced record's running time may stray from ours before its
    /// timestamps are unusable. lrclib's own /api/get tolerance is 2s; a little
    /// more absorbs differing silence at the ends without admitting another
    /// edit of the song.
    private static let syncedDurationTolerance: TimeInterval = 4

    private static func isSyncCompatible(_ candidate: Double, _ target: Double) -> Bool {
        // Nothing to compare against: as before, take the record on trust.
        guard target > 0, candidate > 0 else { return true }
        return abs(candidate - target) <= syncedDurationTolerance
    }

    /// The preference for synced lyrics. It used to be a flat 0.15 - more than
    /// the whole duration component can move a score - so a synced record of
    /// a different recording beat a plain one of this one. Now it is earned
    /// only by a record that is the same length to within lrclib's tolerance.
    private static func syncedBonus(for response: LRCLibResponse, target: Double) -> Double {
        guard hasSynced(response) else { return 0 }
        guard target > 0, response.duration > 0 else { return 0.15 }
        return abs(response.duration - target) <= 2 ? 0.15 : 0
    }

    /// The track's running time in seconds, or 0 when it cannot be had.
    ///
    /// `durationMs` is missing for rows the scanner could not time, and
    /// without it neither the duration filter nor lrclib's exact-match query
    /// can do anything - which is how wrong-length synced lyrics got through.
    /// AVFoundation can usually tell from the header alone.
    private func knownDuration(of track: Track) async -> Double {
        if let durationMs = track.durationMs, durationMs > 0 {
            return Double(durationMs) / 1000.0
        }

        let url = DatabaseManager.localFileURL(forStoredPath: track.path)
        guard let time = try? await AVURLAsset(url: url).load(.duration),
              time.isNumeric else {
            return 0
        }
        let seconds = time.seconds
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    private static func matchScore(
        candidate: LRCLibResponse,
        title: String,
        artist: String,
        album: String?,
        duration: Double
    ) -> Double {
        let titleScore = similarity(candidate.trackName, title)
        let artistScore = similarity(candidate.artistName, artist)

        // A different artist is a different song, whatever the title says.
        guard artistScore >= 0.5 else { return 0 }

        // Nor is a title with essentially nothing in common, however well the
        // artist and the running time line up - that is just another track from
        // the same album.
        guard titleScore >= 0.34 else { return 0 }

        // A recording this far from ours is a different one: a live take, an
        // extended mix, or simply the wrong entry. The words might still be
        // right, but synced timestamps from it would be nonsense, and from here
        // there is no telling which of the two we are about to accept.
        if duration > 0, candidate.duration > 0, abs(candidate.duration - duration) > 25 {
            return 0
        }

        var score = titleScore * 0.45 + artistScore * 0.35 + durationScore(candidate.duration, duration) * 0.20

        // Album agreement is a bonus, never a requirement: lrclib's album names
        // come from whoever uploaded the lyrics.
        if let album, !album.isEmpty, similarity(candidate.albumName, album) >= 0.8 {
            score += 0.05
        }

        return min(score, 1)
    }

    private static func durationScore(_ candidate: Double, _ target: Double) -> Double {
        // No duration to compare against - stay neutral rather than punishing.
        guard target > 0, candidate > 0 else { return 0.5 }

        let delta = abs(candidate - target)
        if delta <= 2 { return 1 }          // lrclib's own tolerance for /api/get
        if delta >= 15 { return 0 }
        return 1 - ((delta - 2) / 13)
    }

    /// 1 for the same string once decoration is discounted, tapering to 0.
    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let a = matchKey(lhs)
        let b = matchKey(rhs)

        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }

        let aTokens = Set(a.split(separator: " "))
        let bTokens = Set(b.split(separator: " "))
        guard !aTokens.isEmpty, !bTokens.isEmpty else { return 0 }

        // One title containing the other is the normal shape of "Song" vs
        // "Song (Radio Edit)" once the parenthetical survived stripping.
        if aTokens.isSubset(of: bTokens) || bTokens.isSubset(of: aTokens) {
            return 0.9
        }

        let overlap = Double(aTokens.intersection(bTokens).count)
        return overlap / Double(aTokens.union(bTokens).count)
    }

    /// Comparison form of a title or artist: lower-cased, accent-folded, and
    /// stripped of the decoration tag editors and stores add - featured
    /// artists, remaster and edition markers, bracketed qualifiers - none of
    /// which lrclib's contributors spell the same way we do.
    private static func matchKey(_ raw: String) -> String {
        var value = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)

        // "feat." in any of its spellings, to the end of its clause.
        value = value.replacingOccurrences(
            of: #"[\(\[]?\s*(feat|ft|featuring|with)\.?\s+[^\)\]]*[\)\]]?"#,
            with: " ",
            options: [.regularExpression]
        )

        // Trailing edition markers, whether parenthesised or after a dash.
        value = value.replacingOccurrences(
            of: #"[\(\[\-]\s*[^\)\]]*\b(remaster(ed)?|remix|version|edit|mono|stereo|deluxe|bonus|live|instrumental|explicit|clean|anniversary|expanded|reissue)\b[^\)\]]*[\)\]]?"#,
            with: " ",
            options: [.regularExpression]
        )

        // Everything that is not a letter, digit or space, then collapse runs.
        value = value.replacingOccurrences(of: #"[^\p{L}\p{N}\s]"#, with: " ", options: [.regularExpression])
        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: [.regularExpression])

        return value.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Requests

    private enum RequestOutcome<T> {
        case found(T)
        case noMatch
        case unreachable
    }

    private func fetchDirect(
        trackName: String,
        artistName: String,
        albumName: String?,
        duration: Double
    ) async -> RequestOutcome<Lyrics> {
        var components = URLComponents(string: "\(baseURL)/get")
        var query = [
            URLQueryItem(name: "track_name", value: trackName),
            URLQueryItem(name: "artist_name", value: artistName)
        ]
        // Sent only when known. An empty album_name is not the same as no
        // album_name, and a zero duration would exclude every real record.
        if let albumName, !albumName.isEmpty {
            query.append(URLQueryItem(name: "album_name", value: albumName))
        }
        if duration > 0 {
            query.append(URLQueryItem(name: "duration", value: String(format: "%.0f", duration)))
        }
        components?.queryItems = query

        switch await perform(components, decoding: LRCLibResponse.self) {
        case .found(let response): return .found(parseLRCLibResponse(response))
        case .noMatch: return .noMatch
        case .unreachable: return .unreachable
        }
    }

    private func search(_ queryItems: [URLQueryItem]) async -> RequestOutcome<[LRCLibResponse]> {
        var components = URLComponents(string: "\(baseURL)/search")
        components?.queryItems = queryItems

        switch await perform(components, decoding: [LRCLibResponse].self) {
        case .found(let results): return results.isEmpty ? .noMatch : .found(results)
        case .noMatch: return .noMatch
        case .unreachable: return .unreachable
        }
    }

    private func perform<T: Decodable>(
        _ components: URLComponents?,
        decoding: T.Type
    ) async -> RequestOutcome<T> {
        guard let url = components?.url else { return .noMatch }

        var request = URLRequest(url: url)
        request.setValue(
            "Cosmos Music Player/1.0 (https://github.com/clquwu/Cosmos-Music-Player)",
            forHTTPHeaderField: "User-Agent"
        )
        // Lyrics are cosmetic and the caller is a screen the user is looking at.
        request.timeoutInterval = 8

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse else { return .unreachable }
            if http.statusCode == 404 { return .noMatch }
            // 5xx and rate limiting are the server's problem, not proof of
            // absence - remembering them as a miss would hide lyrics that exist.
            guard http.statusCode != 429, !(500...599).contains(http.statusCode) else {
                return .unreachable
            }
            guard http.statusCode == 200 else { return .noMatch }

            return .found(try decoder.decode(T.self, from: data))

        } catch let error as URLError {
            print("📴 lrclib request failed: \(error.code)")
            return .unreachable
        } catch {
            // Reached the server, could not read what it said.
            print("❌ Could not decode lrclib response: \(error)")
            return .noMatch
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
        let timestampPattern = #"\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]"#
        let hasSyncedLyrics = text.range(of: timestampPattern, options: .regularExpression) != nil

        if hasSyncedLyrics {
            let syncedLines = parseSyncedLyrics(text)
            let plainText = syncedLines.map { $0.text }.joined(separator: "\n")
            return Lyrics(plainLyrics: plainText, syncedLyrics: syncedLines, isInstrumental: false, source: source)
        } else {
            return Lyrics(plainLyrics: text, syncedLyrics: [], isInstrumental: false, source: source)
        }
    }

    private nonisolated static let leadingTimestampRegex = try? NSRegularExpression(
        pattern: #"^\s*\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]"#
    )

    private nonisolated static let offsetTagRegex = try? NSRegularExpression(
        pattern: #"^\s*\[offset:\s*([+-]?\d+)\s*\]"#,
        options: [.caseInsensitive, .anchorsMatchLines]
    )

    /// Parses LRC into time-ordered lines.
    ///
    /// Two parts of the format used to be dropped. A line may carry several
    /// leading timestamps - `[00:12.00][01:40.00]chorus` is how most files
    /// avoid repeating a chorus - and only the first was kept, so every repeat
    /// after it went missing and the previous line stayed lit through it. And
    /// `[offset:N]`, which shifts the whole file by N ms (positive = lyrics
    /// earlier), was ignored, so files that rely on it ran late or early by
    /// exactly that much.
    private func parseSyncedLyrics(_ lrcText: String) -> [LyricsLine] {
        guard let timestampRegex = Self.leadingTimestampRegex else { return [] }

        let offset = Self.fileOffset(in: lrcText)
        var lines: [(order: Int, line: LyricsLine)] = []

        for line in lrcText.components(separatedBy: .newlines) {
            let ns = line as NSString
            var cursor = 0
            var timestamps: [TimeInterval] = []

            // Consume every leading [mm:ss], [mm:ss.xx] or [mm:ss.xxx].
            while let match = timestampRegex.firstMatch(
                in: line,
                range: NSRange(location: cursor, length: ns.length - cursor)
            ), match.range.location == cursor {
                timestamps.append(Self.seconds(of: match, in: ns))
                cursor = match.range.upperBound
            }

            guard let first = timestamps.first else { continue }

            let body = ns.substring(from: cursor).trimmingCharacters(in: .whitespaces)
            let parsed = Self.parseEnhancedBody(body, lineStart: first)

            for timestamp in timestamps {
                // Word times belong to the first occurrence; a repeat sings the
                // same words shifted by however far apart the two lines are.
                let shift = timestamp - first
                let words = parsed.words?.map {
                    LyricsWord(timestamp: max(0, $0.timestamp + shift - offset), text: $0.text)
                }
                lines.append((lines.count, LyricsLine(
                    timestamp: max(0, timestamp - offset),
                    text: parsed.text,
                    words: words
                )))
            }
        }

        // Stable, so lines sharing a timestamp keep the order the file gave.
        return lines
            .sorted { lhs, rhs in
                let l = lhs.line.timestamp ?? 0
                let r = rhs.line.timestamp ?? 0
                return l == r ? lhs.order < rhs.order : l < r
            }
            .map(\.line)
    }

    /// The `[offset:N]` tag, in seconds. Per the LRC spec N is milliseconds and
    /// a positive value makes the lyrics appear sooner.
    private nonisolated static func fileOffset(in lrcText: String) -> TimeInterval {
        guard let regex = offsetTagRegex else { return 0 }
        let ns = lrcText as NSString
        guard let match = regex.firstMatch(in: lrcText, range: NSRange(location: 0, length: ns.length)),
              let milliseconds = Double(ns.substring(with: match.range(at: 1))) else {
            return 0
        }
        return milliseconds / 1000
    }

    private nonisolated static let wordTimestampRegex = try? NSRegularExpression(
        pattern: #"<(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?>"#
    )

    /// Splits an Enhanced LRC line body into its timed words.
    ///
    /// Enhanced LRC (the "A2" extension) puts a `<mm:ss.xx>` before each word,
    /// inside a line that still carries its ordinary `[mm:ss.xx]` start. Those
    /// inline tags were previously left in the text and rendered literally, so
    /// a track with word-timed embedded lyrics displayed
    /// `<00:12.00>Never <00:12.45>gonna` on screen. Stripping them is a fix in
    /// its own right; keeping what they said is what makes an exact sweep
    /// possible instead of an estimated one.
    ///
    /// - Returns: the text with the tags removed, and the words when the line
    ///   actually carried any.
    nonisolated static func parseEnhancedBody(
        _ body: String,
        lineStart: TimeInterval
    ) -> (text: String, words: [LyricsWord]?) {
        guard let regex = wordTimestampRegex else { return (body, nil) }

        let ns = body as NSString
        let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return (body, nil) }

        var words: [LyricsWord] = []
        var text = ""

        // Anything before the first tag is sung from the line's own start.
        let prefix = ns.substring(with: NSRange(location: 0, length: matches[0].range.location))
        if !prefix.trimmingCharacters(in: .whitespaces).isEmpty {
            words.append(LyricsWord(timestamp: lineStart, text: prefix))
            text += prefix
        }

        for (index, match) in matches.enumerated() {
            let from = match.range.upperBound
            let to = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            guard to >= from else { continue }

            let chunk = ns.substring(with: NSRange(location: from, length: to - from))
            words.append(LyricsWord(timestamp: seconds(of: match, in: ns), text: chunk))
            text += chunk
        }

        return (text, words.isEmpty ? nil : words)
    }

    private nonisolated static func seconds(of match: NSTextCheckingResult, in text: NSString) -> TimeInterval {
        let minutes = Double(text.substring(with: match.range(at: 1))) ?? 0
        let seconds = Double(text.substring(with: match.range(at: 2))) ?? 0

        let fractionRange = match.range(at: 3)
        guard fractionRange.location != NSNotFound else {
            return minutes * 60 + seconds
        }

        let fractionText = text.substring(with: fractionRange)
        let fraction = (Double(fractionText) ?? 0) / pow(10, Double(fractionText.count))
        return minutes * 60 + seconds + fraction
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

    /// Liner notes cached as lyrics before the stricter text check existed:
    /// treated as not cached, so the song is looked up again and the new
    /// result overwrites them.
    private func isCachedDescription(_ lyrics: Lyrics) -> Bool {
        lyrics.source == .embedded && lyrics.syncedLyrics.isEmpty
            && !lyrics.plainLyrics.isEmpty && !isUsableLyricsText(lyrics.plainLyrics)
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

    // MARK: - Remembered misses

    /// How long a confirmed "lrclib does not have this song" is trusted.
    /// Short enough that lyrics added upstream are picked up before long,
    /// long enough that reopening a screen is not three network round trips.
    private static let missLifetime: TimeInterval = 7 * 24 * 60 * 60

    /// Kept beside the hits but under a different extension, so `loadCacheFromDisk`
    /// (which only reads `.json`) ignores them and older builds are unaffected.
    private func missFileURL(trackId: String) -> URL? {
        getLyricsCacheDirectory()?.appendingPathComponent("\(trackId).miss")
    }

    private func isMissRemembered(for stableId: String) -> Bool {
        guard let url = missFileURL(trackId: stableId),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let recordedAt = attributes[.modificationDate] as? Date else {
            return false
        }

        guard Date().timeIntervalSince(recordedAt) < Self.missLifetime else {
            try? fileManager.removeItem(at: url)
            return false
        }

        return true
    }

    private func rememberMiss(for stableId: String) async {
        guard let url = missFileURL(trackId: stableId) else { return }
        try? Data().write(to: url, options: .atomic)
    }

    private func forgetMiss(for stableId: String) {
        guard let url = missFileURL(trackId: stableId) else { return }
        try? fileManager.removeItem(at: url)
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

    /// Moves cached lyrics onto new stable IDs after the library re-keys tracks.
    ///
    /// Both the memory cache and the on-disk `lyrics-cache/<stableId>.json`
    /// are keyed by stable ID, outside the database, so nothing carried them
    /// across a re-key. A re-keyed track silently lost its lyrics and re-fetched
    /// them from lrclib on next open.
    func migrateStableIds(_ remapping: [String: String]) {
        guard let cacheDir = getLyricsCacheDirectory() else { return }
        var movedCount = 0

        for (oldStableId, newStableId) in remapping where oldStableId != newStableId {
            if let cached = cache.removeValue(forKey: oldStableId), cache[newStableId] == nil {
                cache[newStableId] = cached
            }

            // The miss marker is re-keyed too, or a re-keyed track pays for the
            // same three fruitless requests again.
            let oldMiss = cacheDir.appendingPathComponent("\(oldStableId).miss")
            if fileManager.fileExists(atPath: oldMiss.path) {
                let newMiss = cacheDir.appendingPathComponent("\(newStableId).miss")
                try? fileManager.removeItem(at: newMiss)
                try? fileManager.moveItem(at: oldMiss, to: newMiss)
            }

            let oldURL = cacheDir.appendingPathComponent("\(oldStableId).json")
            let newURL = cacheDir.appendingPathComponent("\(newStableId).json")

            guard fileManager.fileExists(atPath: oldURL.path) else { continue }

            // The surviving row's own lyrics win; this one is then redundant.
            if fileManager.fileExists(atPath: newURL.path) {
                try? fileManager.removeItem(at: oldURL)
                continue
            }

            do {
                try fileManager.moveItem(at: oldURL, to: newURL)
                movedCount += 1
            } catch {
                print("⚠️ Failed to re-key cached lyrics \(oldStableId): \(error)")
            }
        }

        if movedCount > 0 {
            print("🔁 Lyrics cache: re-keyed \(movedCount) entr(ies)")
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

    /// The same record with only its plain text, for one whose timestamps
    /// belong to a different recording.
    func droppingSyncedLyrics() -> LRCLibResponse {
        LRCLibResponse(
            id: id,
            trackName: trackName,
            artistName: artistName,
            albumName: albumName,
            duration: duration,
            instrumental: instrumental,
            plainLyrics: plainLyrics,
            syncedLyrics: nil
        )
    }
}
