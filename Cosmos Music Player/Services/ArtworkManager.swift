//
//  ArtworkManager.swift
//  Cosmos Music Player
//
//  Manages album artwork extraction and caching
//

import Foundation
import UIKit
import SwiftUI
import AVFoundation
import CryptoKit
import ImageIO
import SFBAudioEngine

@MainActor
class ArtworkManager: ObservableObject {
    static let shared = ArtworkManager()

    // Memory cache for quick access
    private let memoryCache = NSCache<NSString, UIImage>()
    // Small row/grid-sized artwork, keyed by "\(stableId)-\(pixelSize)"
    private let thumbnailCache = NSCache<NSString, UIImage>()
    private var cachedTrackIds: Set<String> = []
    private var notificationObservers: [NSObjectProtocol] = []

    // Persistent disk cache directory
    private let diskCacheURL: URL

    // Mapping file URL (maps track.stableId -> artwork hash)
    private let mappingFileURL: URL

    // In-memory mapping cache
    private var artworkMapping: [String: String] = [:]

    private let maxMemoryCacheItems = 250
    private let maxMemoryCacheCost = 40 * 1024 * 1024

    /// Tracks whose cover is waiting on an iCloud download to finish.
    private var pendingCloudArtworkIds: Set<String> = []
    /// Tracks whose file has been read and genuinely has no cover.
    ///
    /// Nothing was remembering this, so a track without artwork was re-parsed
    /// for every request in a session - the row, the player, the widget, each
    /// re-entry - and each attempt is now two full tag reads, the format
    /// parser plus the TagLib fallback. In memory only, and deliberately not
    /// cleared alongside the image caches: those are dropped on backgrounding
    /// and memory warnings, which would bring the churn straight back. A file
    /// that later gains a cover is picked up by `forceRefreshArtwork`, which
    /// the scanner calls when a file's fingerprint changes.
    private var knownArtworkless: Set<String> = []
    /// Scrolling a large un-downloaded library must not spawn one waiting task
    /// per row. Rows that miss a slot are retried by their next `.onAppear` or
    /// by the end-of-scan refresh, so nothing is lost by capping this.
    private static let maxPendingCloudArtworkRetries = 8
    private static let cloudArtworkStallTimeout: TimeInterval = 45

    private init() {
        // Create artwork cache directory
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        diskCacheURL = documentsURL.appendingPathComponent("ArtworkCache", isDirectory: true)
        mappingFileURL = documentsURL.appendingPathComponent("ArtworkMapping.plist")

        memoryCache.countLimit = maxMemoryCacheItems
        memoryCache.totalCostLimit = maxMemoryCacheCost
        thumbnailCache.countLimit = 600
        thumbnailCache.totalCostLimit = 30 * 1024 * 1024

        // Create directory if needed
        try? FileManager.default.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)

        // Load mapping
        loadMapping()

        let notificationCenter = NotificationCenter.default
        notificationObservers.append(
            notificationCenter.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.clearCache()
                }
            }
        )
        notificationObservers.append(
            notificationCenter.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.clearCache()
                }
            }
        )

        print("📁 ArtworkManager initialized - Disk cache: \(diskCacheURL.path)")
    }

    private func loadMapping() {
        guard FileManager.default.fileExists(atPath: mappingFileURL.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: mappingFileURL)
            if let mapping = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: String] {
                artworkMapping = mapping
                print("📊 Loaded artwork mapping: \(artworkMapping.count) entries")
            }
        } catch {
            print("⚠️ Failed to load artwork mapping: \(error)")
        }
    }

    private func saveMapping() {
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: artworkMapping, format: .xml, options: 0)
            try data.write(to: mappingFileURL, options: .atomic)
        } catch {
            print("⚠️ Failed to save artwork mapping: \(error)")
        }
    }

    func clearCache() {
        memoryCache.removeAllObjects()
        thumbnailCache.removeAllObjects()
        cachedTrackIds.removeAll()
        print("🗑️ ArtworkManager memory cache cleared")
    }

    func clearDiskCache() {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: diskCacheURL, includingPropertiesForKeys: nil)
            for file in files {
                try FileManager.default.removeItem(at: file)
            }
            memoryCache.removeAllObjects()
            thumbnailCache.removeAllObjects()
            cachedTrackIds.removeAll()
            knownArtworkless.removeAll()
            artworkMapping.removeAll()
            saveMapping()
            print("🗑️ Cleared \(files.count) artwork files from disk cache")
        } catch {
            print("❌ Failed to clear disk cache: \(error)")
        }
    }

    func forceRefreshArtwork(for track: Track) async -> UIImage? {
        // Remove from memory cache and mapping to force re-extraction
        memoryCache.removeObject(forKey: track.stableId as NSString)
        // Thumbnail keys are size-suffixed and NSCache can't enumerate, so drop them all
        thumbnailCache.removeAllObjects()
        cachedTrackIds.remove(track.stableId)

        // Note: We don't delete the actual artwork file as other tracks might use it
        // Just remove the mapping for this track
        artworkMapping.removeValue(forKey: track.stableId)
        knownArtworkless.remove(track.stableId)
        saveMapping()

        print("🔄 Force refreshing artwork for: \(track.title)")
        let refreshed = await getArtwork(for: track)
        notifyArtworkChanged(for: track.stableId)
        return refreshed
    }

    /// Pre-process and cache artwork during library indexing (background operation)
    func cacheArtwork(for track: Track) async {
        // Skip if already mapped (already has cached artwork)
        if artworkMapping[track.stableId] != nil {
            return
        }

        print("💾 Pre-caching artwork for: \(track.title)")

        // Through the bookmark, like every other read: an external file is not
        // openable by path alone. See beginReadAccess.
        let access = await beginReadAccess(for: track)
        defer { access.relinquish() }

        await extractAndStoreArtwork(for: track.stableId, at: access.url)
    }

    /// Posted when a track's cover has been extracted for the first time or
    /// replaced. `userInfo["trackStableId"]` carries the track's stable ID.
    ///
    /// Anything holding a rendered copy of the cover has to be told, because
    /// nothing about the track itself changes when this happens. The widget in
    /// particular writes the cover into the App Group container and then skips
    /// that write for as long as the same track is showing; without this it
    /// would keep displaying whatever it wrote at the moment the track
    /// started - most visibly nothing at all, for a track first played before
    /// the scan had got round to extracting its artwork.
    static let artworkChangedNotification = Notification.Name("TrackArtworkChanged")

    private func notifyArtworkChanged(for stableId: String) {
        NotificationCenter.default.post(
            name: Self.artworkChangedNotification,
            object: nil,
            userInfo: ["trackStableId": stableId]
        )
    }

    func getArtwork(for track: Track) async -> UIImage? {
        // 1. Check memory cache first (fastest)
        if let cachedImage = memoryCache.object(forKey: track.stableId as NSString) {
            return cachedImage
        }

        // 2. Check disk cache (fast)
        if let diskImage = await loadFromDiskCache(stableId: track.stableId) {
            // Store in memory cache for next time
            cacheImage(diskImage, for: track.stableId)
            return diskImage
        }

        if knownArtworkless.contains(track.stableId) {
            return nil
        }

        // 3. Read the file itself. This is the only step that can fill the two
        // caches above, so everything it needs must be in place here or the
        // track has no cover for the rest of the app's life: the scan
        // deliberately does not pre-extract (see LibraryIndexer.saveParsedFile),
        // and nothing else writes ArtworkCache.
        //
        // Two things can stand between us and the bytes, and they need opposite
        // answers. Permission is taken first, because an external file cannot
        // be opened by path at all. Residency is only requested - `downloadTimeout: 0`
        // asks iCloud to start fetching and returns immediately, since a cover
        // must never block a row from drawing - and if the bytes are genuinely
        // still in flight the wait is handed to the retry below.
        let access = await beginReadAccess(for: track)
        defer { access.relinquish() }
        let url = access.url

        try? await CloudDownloadManager.shared.ensureLocal(url, downloadTimeout: 0)

        if let image = await extractAndStoreArtwork(for: track.stableId, at: url) {
            return image
        }

        // Nothing was read. If that is only because the bytes have not landed
        // yet, keep waiting off to one side instead of answering "no cover" for
        // the rest of the session.
        if isAwaitingCloudDownload(url) {
            scheduleCloudArtworkRetryIfNeeded(for: track, at: url)
        } else {
            // The file was readable and has no cover. Do not ask it again.
            knownArtworkless.insert(track.stableId)
        }
        return nil
    }

    /// A file open for reading, plus whatever has to be handed back afterwards.
    private struct ScopedFile {
        let url: URL
        private let stopAccessing: Bool

        init(url: URL, stopAccessing: Bool = false) {
            self.url = url
            self.stopAccessing = stopAccessing
        }

        func relinquish() {
            guard stopAccessing else { return }
            url.stopAccessingSecurityScopedResource()
        }
    }

    /// Opens a track's file for reading, through its security-scoped bookmark
    /// when the file lives outside the app's own container.
    ///
    /// A song added from Files - anywhere in iCloud Drive, or another provider -
    /// is never copied in; the app stores a bookmark and nothing else. Reading
    /// `track.path` directly is then denied by the sandbox, and confusingly so:
    /// `fileExists` answers false (it cannot even stat the path) and AVAsset
    /// reports NSCocoaErrorDomain 257 "you do not have permission". Both look
    /// like a missing or corrupt file rather than a missing entitlement.
    ///
    /// `PlayerEngine.performLoadTrack` has always resolved the bookmark before
    /// opening a track, which is why playing a song showed its cover while the
    /// list next to it could not - the list's reader was the only one going in
    /// without permission.
    ///
    /// Deliberately read-only: unlike `LibraryIndexer.resolveBookmarkForTrack`
    /// this never migrates identity or writes to the database. Drawing a cover
    /// must not rewrite the library, and a stale bookmark is simply declined -
    /// the playback path owns repairing that.
    private func beginReadAccess(for track: Track) async -> ScopedFile {
        let databaseURL = URL(fileURLWithPath: track.path)

        guard let bookmarkData = try? await ExternalBookmarkStore.shared.bookmarkData(for: track.stableId) else {
            return ScopedFile(url: databaseURL)
        }

        var isStale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withoutUI,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ), !isStale else {
            return ScopedFile(url: databaseURL)
        }

        guard resolved.startAccessingSecurityScopedResource() else {
            print("⚠️ Could not take security-scoped access for cover: \(resolved.lastPathComponent)")
            return ScopedFile(url: resolved)
        }

        return ScopedFile(url: resolved, stopAccessing: true)
    }

    /// Extracts, downsamples and stores a cover, then tells every view drawing
    /// this track to redraw.
    ///
    /// The notification is the point: rows and cover cards load their artwork
    /// once, from `.onAppear`. Without it the only view that ever sees a
    /// freshly extracted cover is the one whose own call produced it, and every
    /// other row showing the same track keeps its placeholder until something
    /// rebuilds it.
    @discardableResult
    private func extractAndStoreArtwork(for stableId: String, at url: URL) async -> UIImage? {
        guard let extracted = await extractArtwork(from: url) else { return nil }

        let image = await Self.downsampledOffMain(extracted, maxPixelSize: Self.maxFullArtworkPixelSize)
        // Store in both caches
        cacheImage(image, for: stableId)
        await saveToDiskCache(image: image, stableId: stableId)
        notifyArtworkChanged(for: stableId)
        return image
    }

    /// A cover that could not be read because its file is still an iCloud
    /// placeholder is not "no cover" - it is "not yet".
    ///
    /// `getArtwork` only ever *requests* the download and returns, because a
    /// cover must never block a row from drawing. So the first attempt on a
    /// freshly added track reliably lands on zero bytes - and nothing re-asked
    /// afterwards: the row had already been handed nil, `.onAppear` does not
    /// fire again while it stays on screen, and the next launch simply repeated
    /// the same too-early attempt. The one path that did produce a cover was
    /// playing the song, because `loadTrack` waits for the download for real
    /// before the player asks for artwork - which is exactly why the cover
    /// appeared the moment the track was tapped, and only then.
    private func scheduleCloudArtworkRetryIfNeeded(for track: Track, at url: URL) {
        let stableId = track.stableId

        guard !pendingCloudArtworkIds.contains(stableId),
              pendingCloudArtworkIds.count < Self.maxPendingCloudArtworkRetries else {
            return
        }

        pendingCloudArtworkIds.insert(stableId)
        print("⏳ Cover is waiting on an iCloud download: \(url.lastPathComponent)")

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pendingCloudArtworkIds.remove(stableId) }

            do {
                try await CloudDownloadManager.shared.waitUntilLocal(
                    url,
                    stallTimeout: Self.cloudArtworkStallTimeout
                )
            } catch {
                print("⚠️ Gave up waiting for cover bytes: \(url.lastPathComponent) (\(error))")
                return
            }

            // Playback, a rescan or another row may have cached it meanwhile.
            guard self.artworkMapping[stableId] == nil else { return }

            // Access was relinquished when the original read returned, so an
            // external file has to be opened again for this second attempt.
            let access = await self.beginReadAccess(for: track)
            defer { access.relinquish() }
            await self.extractAndStoreArtwork(for: stableId, at: access.url)
        }
    }

    /// True only for a cloud file whose bytes have genuinely not arrived yet.
    private func isAwaitingCloudDownload(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ]) else {
            // Unreadable even for a metadata query: not a download problem.
            return false
        }

        guard values.isUbiquitousItem == true else { return false }
        return values.ubiquitousItemDownloadingStatus != .current
            && !CloudDownloadManager.isLocallyResident(url)
    }

    /// Small artwork for list rows and grid cells. Decoding and holding these
    /// instead of full-size art keeps scrolling smooth and memory low.
    func getThumbnail(for track: Track, maxPixelSize: CGFloat = 160) async -> UIImage? {
        let key = "\(track.stableId)-\(Int(maxPixelSize))" as NSString
        if let cached = thumbnailCache.object(forKey: key) {
            return cached
        }

        // Fast path: downsample straight from the disk cache file
        if let artworkHash = artworkMapping[track.stableId],
           let thumbnail = await loadThumbnailFromDisk(artworkHash: artworkHash, maxPixelSize: maxPixelSize) {
            thumbnailCache.setObject(thumbnail, forKey: key)
            return thumbnail
        }

        // Slow path: full pipeline (extracts and fills the disk cache), then shrink
        guard let fullImage = await getArtwork(for: track) else { return nil }
        let thumbnail = await Self.downsampledOffMain(fullImage, maxPixelSize: maxPixelSize)
        thumbnailCache.setObject(thumbnail, forKey: key)
        return thumbnail
    }

    private nonisolated func loadThumbnailFromDisk(artworkHash: String, maxPixelSize: CGFloat) async -> UIImage? {
        let diskFile = diskCacheURL.appendingPathComponent("\(artworkHash).jpg")
        return Self.downsampledImage(at: diskFile, maxPixelSize: maxPixelSize)
    }

    // MARK: - Downsampling

    /// Ceiling for artwork kept in memory or written to the disk cache; big
    /// enough for the full-screen player, ~10-30x smaller than raw embedded art
    private nonisolated static let maxFullArtworkPixelSize: CGFloat = 1024

    private nonisolated static func downsampledImage(at url: URL, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private nonisolated static func downsampled(_ image: UIImage, maxPixelSize: CGFloat) -> UIImage {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let largestSide = max(pixelWidth, pixelHeight)
        guard largestSide > maxPixelSize else { return image }

        let ratio = maxPixelSize / largestSide
        let targetSize = CGSize(width: pixelWidth * ratio, height: pixelHeight * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    /// Runs the resize on the global executor so large images never block the main thread
    private nonisolated static func downsampledOffMain(_ image: UIImage, maxPixelSize: CGFloat) async -> UIImage {
        downsampled(image, maxPixelSize: maxPixelSize)
    }

    func updateVisibleArtworkWindow(visibleTrackIds: [String], prefetchTrackIds: [String] = []) {
        let keepTrackIds = Set(visibleTrackIds + prefetchTrackIds)
        guard !keepTrackIds.isEmpty else {
            clearCache()
            return
        }

        let staleTrackIds = cachedTrackIds.subtracting(keepTrackIds)
        for staleTrackId in staleTrackIds {
            memoryCache.removeObject(forKey: staleTrackId as NSString)
            cachedTrackIds.remove(staleTrackId)
        }
    }

    private func cacheImage(_ image: UIImage, for stableId: String) {
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? Int(image.size.width * image.size.height * 4)
        memoryCache.setObject(image, forKey: stableId as NSString, cost: max(cost, 1))
        cachedTrackIds.insert(stableId)
    }

    // MARK: - Disk Cache Management

    private nonisolated func loadFromDiskCache(stableId: String) async -> UIImage? {
        // Get artwork hash from mapping
        guard let artworkHash = await getArtworkHash(for: stableId) else {
            return nil
        }

        let diskFile = diskCacheURL.appendingPathComponent("\(artworkHash).jpg")

        guard FileManager.default.fileExists(atPath: diskFile.path) else {
            return nil
        }

        // Decode at a capped size — legacy cache files may still be full resolution
        return Self.downsampledImage(at: diskFile, maxPixelSize: Self.maxFullArtworkPixelSize)
    }

    private func getArtworkHash(for stableId: String) async -> String? {
        return artworkMapping[stableId]
    }

    private nonisolated func saveToDiskCache(image: UIImage, stableId: String) async {
        // Cap stored size; anything larger only costs decode time and memory
        let cappedImage = Self.downsampled(image, maxPixelSize: Self.maxFullArtworkPixelSize)
        // Compress to JPEG at 85% quality for faster loading and smaller size
        guard let imageData = cappedImage.jpegData(compressionQuality: 0.85) else {
            print("❌ Failed to compress artwork to JPEG")
            return
        }

        // Compute hash of artwork data to deduplicate
        let artworkHash = SHA256.hash(data: imageData)
        let hashString = artworkHash.compactMap { String(format: "%02x", $0) }.joined()

        let diskFile = diskCacheURL.appendingPathComponent("\(hashString).jpg")

        // Check if artwork already exists
        if FileManager.default.fileExists(atPath: diskFile.path) {
            // Artwork already cached, just update mapping
            await updateMapping(stableId: stableId, artworkHash: hashString)
            print("♻️ Reused existing artwork: \(hashString).jpg for track \(stableId)")
            return
        }

        // Save new artwork file
        do {
            try imageData.write(to: diskFile, options: .atomic)
            await updateMapping(stableId: stableId, artworkHash: hashString)
            print("💾 Saved artwork to disk cache: \(hashString).jpg (\(imageData.count / 1024) KB)")
        } catch {
            print("❌ Failed to save artwork to disk: \(error)")
        }
    }

    private func updateMapping(stableId: String, artworkHash: String) async {
        artworkMapping[stableId] = artworkHash
        saveMapping()
    }

    /// Moves cached covers onto new stable IDs after the library re-keys tracks.
    ///
    /// `ArtworkMapping.plist` is keyed by stable ID and lives outside the
    /// database, so `mergeTrackReferences` - which carries favourites, playlist
    /// entries and artist links across a re-key - never touched it. A re-keyed
    /// track therefore lost its cover twice over: the mapping entry no longer
    /// matched any row, and `cleanupOrphanedArtwork` then deleted both that
    /// entry and the JPEG it was the last reference to.
    func migrateStableIds(_ remapping: [String: String]) {
        var movedCount = 0

        for (oldStableId, newStableId) in remapping where oldStableId != newStableId {
            guard let artworkHash = artworkMapping.removeValue(forKey: oldStableId) else { continue }

            // Never overwrite a cover the new ID already has: that one was
            // extracted for the row that survives.
            if artworkMapping[newStableId] == nil {
                artworkMapping[newStableId] = artworkHash
            }

            memoryCache.removeObject(forKey: oldStableId as NSString)
            cachedTrackIds.remove(oldStableId)
            if knownArtworkless.remove(oldStableId) != nil {
                knownArtworkless.insert(newStableId)
            }
            movedCount += 1
        }

        guard movedCount > 0 else { return }

        // Thumbnail keys carry a size suffix and NSCache cannot be enumerated,
        // so the only way to drop the stale ones is to drop them all.
        thumbnailCache.removeAllObjects()
        saveMapping()
        print("🔁 Artwork cache: re-keyed \(movedCount) cover(s)")
    }

    /// Clean up artwork files for tracks that no longer exist
    func cleanupOrphanedArtwork(validStableIds: Set<String>) async {
        // First, clean up mapping entries for deleted tracks
        var removedMappings = 0
        for stableId in artworkMapping.keys {
            if !validStableIds.contains(stableId) {
                artworkMapping.removeValue(forKey: stableId)
                removedMappings += 1
            }
        }

        if removedMappings > 0 {
            saveMapping()
            print("🗑️ Removed \(removedMappings) orphaned mapping entries")
        }

        // Build set of artwork hashes still in use
        let usedHashes = Set(artworkMapping.values)

        // Clean up artwork files that are no longer referenced
        do {
            let files = try FileManager.default.contentsOfDirectory(at: diskCacheURL, includingPropertiesForKeys: nil)
            var removedCount = 0

            for fileURL in files {
                let artworkHash = fileURL.deletingPathExtension().lastPathComponent
                if !usedHashes.contains(artworkHash) {
                    try FileManager.default.removeItem(at: fileURL)
                    removedCount += 1
                }
            }

            if removedCount > 0 {
                print("🗑️ Cleaned up \(removedCount) unused artwork files")
            }
        } catch {
            print("❌ Failed to cleanup orphaned artwork: \(error)")
        }
    }

    private nonisolated func extractArtwork(from url: URL) async -> UIImage? {
        let ext = url.pathExtension.lowercased()

        // Ogg containers are deliberately handled whole by extractGenericArtwork:
        // it reads TagLib FIRST and only then falls back to the byte scan, because
        // that scan corrupts any picture spanning more than one Ogg page (#75).
        // Reversing that order here would hand the broken reader the first word
        // again, so this branch returns directly and never reaches the fallback
        // below - which would be a second, pointless TagLib read anyway.
        if ext == "opus" || ext == "ogg" || ext == "oga" {
            return await extractGenericArtwork(from: url)
        }

        let formatSpecific: UIImage?
        switch ext {
        case "flac":
            formatSpecific = await extractFlacArtwork(from: url)
        case "mp3":
            formatSpecific = await extractMp3Artwork(from: url)
        // WAV carries its cover in a RIFF `id3 ` chunk, which AVAsset surfaces
        // as commonKeyArtwork exactly like it does for MP4. It had no branch at
        // all here, so every WAV fell straight through to `return nil` - on
        // every launch, for ever, because nothing about the file was going to
        // change. The library scanner does read it (parseWavMetadataSync sets
        // hasEmbeddedArt from the same key) and so does the player, which is why
        // the cover appeared on the Now Playing screen but never in a list.
        case "m4a", "mp4", "aac", "wav", "aiff", "aif":
            formatSpecific = await extractAVAssetArtwork(from: url)
        case "dsf", "dff":
            formatSpecific = await extractDSDArtwork(from: url)
        default:
            formatSpecific = nil
        }

        if let formatSpecific {
            return formatSpecific
        }

        // Universal last resort, so a format can never again be indexable but
        // silently unreadable here: LibraryIndexer decides what enters the
        // library, this method decided what could show a cover, and the two
        // lists were free to drift apart. TagLib reads every container the app
        // indexes, so it also rescues a file whose bespoke parser above simply
        // could not find a picture the tag really does contain.
        if let tagged = Self.extractArtworkWithTagLib(from: url) {
            print("🎨 Extracted artwork via TagLib fallback: \(url.lastPathComponent)")
            return tagged
        }

        return nil
    }

    /// Reads the cover through SFBAudioEngine's TagLib-backed metadata reader.
    /// Format-agnostic: whatever the app can index, this can read.
    private nonisolated static func extractArtworkWithTagLib(from url: URL) -> UIImage? {
        do {
            let audioFile = try AudioFile(readingPropertiesAndMetadataFrom: url)
            let pictures = audioFile.metadata.attachedPictures
            let preferred = pictures.first(where: { $0.type == .frontCover }) ?? pictures.first
            guard let preferred, let image = UIImage(data: preferred.imageData) else {
                return nil
            }
            return image
        } catch {
            print("⚠️ TagLib artwork read failed for \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    private nonisolated func extractMp3Artwork(from url: URL) async -> UIImage? {
        return await withCheckedContinuation { continuation in
            Task {
                let asset = AVURLAsset(url: url)

                do {
                    let metadata = try await asset.load(.commonMetadata)

                    for item in metadata {
                        if item.commonKey == .commonKeyArtwork {
                            do {
                                if let data = try await item.load(.dataValue),
                                   let image = UIImage(data: data) {
                                    continuation.resume(returning: image)
                                    return
                                }
                            } catch {
                                print("Failed to load artwork data: \(error)")
                            }
                        }
                    }

                    continuation.resume(returning: nil)
                } catch {
                    print("Failed to load MP3 metadata: \(error)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private nonisolated func extractFlacArtwork(from url: URL) async -> UIImage? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)

                    if data.count < 42 {
                        continuation.resume(returning: nil)
                        return
                    }

                    var offset = 4

                    while offset < data.count {
                        let blockHeader = data[offset]
                        let isLast = (blockHeader & 0x80) != 0
                        let blockType = blockHeader & 0x7F

                        offset += 1

                        guard offset + 3 <= data.count else { break }

                        let blockSize = Int(data[offset]) << 16 | Int(data[offset + 1]) << 8 | Int(data[offset + 2])
                        offset += 3

                        if blockType == 6 { // PICTURE block
                            if let image = Self.parseFlacPictureBlock(data: data, offset: offset, size: blockSize) {
                                continuation.resume(returning: image)
                                return
                            }
                        }

                        offset += blockSize

                        if isLast { break }
                    }

                    continuation.resume(returning: nil)

                } catch {
                    print("Failed to extract FLAC artwork: \(error)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private nonisolated static func parseFlacPictureBlock(data: Data, offset: Int, size: Int) -> UIImage? {
        var pos = offset

        // Skip picture type (4 bytes)
        pos += 4

        guard pos + 4 <= data.count else { return nil }

        // Get MIME type length
        let mimeLength = Int(data[pos]) << 24 | Int(data[pos + 1]) << 16 | Int(data[pos + 2]) << 8 | Int(data[pos + 3])
        pos += 4 + mimeLength

        guard pos + 4 <= data.count else { return nil }

        // Get description length
        let descLength = Int(data[pos]) << 24 | Int(data[pos + 1]) << 16 | Int(data[pos + 2]) << 8 | Int(data[pos + 3])
        pos += 4 + descLength

        // Skip width, height, color depth, indexed colors (16 bytes total)
        pos += 16

        guard pos + 4 <= data.count else { return nil }

        // Get picture data length
        let pictureLength = Int(data[pos]) << 24 | Int(data[pos + 1]) << 16 | Int(data[pos + 2]) << 8 | Int(data[pos + 3])
        pos += 4

        guard pos + pictureLength <= data.count else { return nil }

        // Extract picture data
        let pictureData = data.subdata(in: pos..<pos + pictureLength)
        return UIImage(data: pictureData)
    }

    // MARK: - M4A/AAC Artwork Extraction

    /// Common-metadata artwork, for every container AVFoundation reads natively
    /// - MP4/M4A/AAC and RIFF WAV/AIFF alike.
    ///
    /// Deliberately the same reader the scanner uses to decide `hasEmbeddedArt`
    /// (`parseWavMetadataSync`): the async `load(.commonMetadata)`, matched on
    /// `commonKey`. The synchronous `asset.commonMetadata` this replaced is not
    /// merely deprecated - it answers with whatever happens to be loaded, so it
    /// can report no artwork on a file the scanner has already flagged as
    /// having some. Detection and extraction now agree by construction.
    private nonisolated func extractAVAssetArtwork(from url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)

        do {
            let commonMetadata = try await asset.load(.commonMetadata)

            for item in commonMetadata where item.commonKey == .commonKeyArtwork {
                if let data = try await item.load(.dataValue),
                   let image = UIImage(data: data) {
                    print("🎨 Extracted artwork via AVAsset: \(url.lastPathComponent)")
                    return image
                }
            }

            print("⚠️ No AVAsset artwork found in: \(url.lastPathComponent)")
            return nil
        } catch {
            print("⚠️ AVAsset artwork read failed for \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    // MARK: - DSD Artwork Extraction

    private nonisolated func extractDSDArtwork(from url: URL) async -> UIImage? {
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)

            // For DSF files, try ID3v2 APIC frame extraction first
            if url.pathExtension.lowercased() == "dsf" {
                if let artwork = extractDSFArtworkFromID3(data: data, filename: url.lastPathComponent) {
                    return artwork
                }
            }

            // Fallback to binary signature search for both DSF and DFF files
            print("⚠️ No ID3v2 artwork found, searching for binary signatures in: \(url.lastPathComponent)")

            // Image signatures to look for
            let jpegSignature = Data([0xFF, 0xD8, 0xFF])
            let pngSignature = Data([0x89, 0x50, 0x4E, 0x47])

            // Search for embedded images in DSD files
            let searchRange = 0..<min(data.count, 2097152) // Search first 2MB

            // Look for JPEG images
            if let jpegRange = data.range(of: jpegSignature, in: searchRange) {
                let startOffset = jpegRange.lowerBound

                // Look for JPEG end marker (FF D9)
                let jpegEndSignature = Data([0xFF, 0xD9])
                if let endRange = data.range(of: jpegEndSignature, in: startOffset..<min(data.count, startOffset + 1048576)) {
                    let endOffset = endRange.upperBound
                    let imageData = data.subdata(in: startOffset..<endOffset)

                    if let image = UIImage(data: imageData) {
                        print("🎨 Extracted JPEG artwork from DSD file (binary search): \(url.lastPathComponent)")
                        return image
                    }
                }
            }

            // Look for PNG images
            if let pngRange = data.range(of: pngSignature, in: searchRange) {
                let startOffset = pngRange.lowerBound

                // PNG files end with IEND chunk (49 45 4E 44)
                let pngEndSignature = Data([0x49, 0x45, 0x4E, 0x44])
                if let endRange = data.range(of: pngEndSignature, in: startOffset..<min(data.count, startOffset + 1048576)) {
                    let endOffset = endRange.upperBound + 4 // Include CRC after IEND
                    let imageData = data.subdata(in: startOffset..<min(endOffset, data.count))

                    if let image = UIImage(data: imageData) {
                        print("🎨 Extracted PNG artwork from DSD file (binary search): \(url.lastPathComponent)")
                        return image
                    }
                }
            }

            print("⚠️ No artwork found in DSD file: \(url.lastPathComponent)")
            return nil
        } catch {
            print("❌ DSD artwork extraction failed: \(error)")
            return nil
        }
    }

    // Extract artwork from DSF file using ID3v2 APIC frames
    private nonisolated func extractDSFArtworkFromID3(data: Data, filename: String) -> UIImage? {
        // Validate DSF signature: 'D', 'S', 'D', ' ' (includes 1 space)
        guard data.count >= 28,
              data[0] == 0x44, data[1] == 0x53, data[2] == 0x44, data[3] == 0x20 else {
            print("⚠️ Invalid DSF signature in: \(filename)")
            return nil
        }

        // Read metadata pointer from DSF header (little-endian at offset 20)
        let metadataPointer = readLittleEndianUInt64(from: data, offset: 20)

        guard metadataPointer > 0 && metadataPointer < data.count else {
            print("⚠️ No metadata pointer in DSF file: \(filename)")
            return nil
        }

        let metadataOffset = Int(metadataPointer)

        // Check for ID3v2 signature at metadata pointer
        guard data.count >= metadataOffset + 10,
              data[metadataOffset] == 0x49, // 'I'
              data[metadataOffset + 1] == 0x44, // 'D'
              data[metadataOffset + 2] == 0x33 else { // '3'
            print("⚠️ No ID3v2 tag found at metadata pointer in: \(filename)")
            return nil
        }

        print("🏷️ Found ID3v2 tag in DSF file: \(filename)")

        let id3Data = data.subdata(in: metadataOffset..<data.count)
        return extractArtworkFromID3v2(data: id3Data, filename: filename)
    }

    // Extract artwork from ID3v2 APIC frame
    private nonisolated func extractArtworkFromID3v2(data: Data, filename: String) -> UIImage? {
        guard data.count >= 10 else { return nil }

        // Read ID3v2 header
        let majorVersion = data[3]
        let tagSize = Int((UInt32(data[6]) << 21) | (UInt32(data[7]) << 14) | (UInt32(data[8]) << 7) | UInt32(data[9]))

        print("🏷️ Searching for APIC frame in ID3v2.\(majorVersion) tag, size: \(tagSize) bytes")

        // Parse frames to find APIC (attached picture)
        var offset = 10
        let endOffset = min(data.count, 10 + tagSize)

        while offset < endOffset - 10 {
            // Read frame header (10 bytes for v2.3/v2.4)
            let frameId = String(data: data.subdata(in: offset..<offset+4), encoding: .ascii) ?? ""

            let frameSize: Int
            if majorVersion >= 4 {
                // ID3v2.4 uses synchsafe integers for frame size
                frameSize = Int((UInt32(data[offset+4]) << 21) | (UInt32(data[offset+5]) << 14) | (UInt32(data[offset+6]) << 7) | UInt32(data[offset+7]))
            } else {
                // ID3v2.3 uses regular 32-bit big-endian integer
                frameSize = Int((UInt32(data[offset+4]) << 24) | (UInt32(data[offset+5]) << 16) | (UInt32(data[offset+6]) << 8) | UInt32(data[offset+7]))
            }

            // Move to frame data
            offset += 10

            guard frameSize > 0 && offset + frameSize <= endOffset else {
                break
            }

            if frameId == "APIC" {
                print("🎨 Found APIC frame in \(filename), size: \(frameSize) bytes")

                let frameData = data.subdata(in: offset..<offset+frameSize)

                // Parse APIC frame structure:
                // [Encoding] [MIME type] [Picture type] [Description] [Picture data]
                var frameOffset = 1 // Skip encoding byte

                // Skip MIME type (null-terminated string)
                while frameOffset < frameData.count && frameData[frameOffset] != 0 {
                    frameOffset += 1
                }
                frameOffset += 1 // Skip null terminator

                // Skip picture type (1 byte)
                frameOffset += 1

                // Skip description (null-terminated string, encoding-dependent)
                let encoding = frameData[0]
                if encoding == 1 || encoding == 2 { // UTF-16
                    // Look for double null bytes
                    while frameOffset < frameData.count - 1 && !(frameData[frameOffset] == 0 && frameData[frameOffset + 1] == 0) {
                        frameOffset += 1
                    }
                    frameOffset += 2 // Skip double null
                } else {
                    // Single byte encoding
                    while frameOffset < frameData.count && frameData[frameOffset] != 0 {
                        frameOffset += 1
                    }
                    frameOffset += 1 // Skip null terminator
                }

                // Extract image data
                guard frameOffset < frameData.count else {
                    print("⚠️ Invalid APIC frame structure in: \(filename)")
                    break
                }

                let imageData = frameData.subdata(in: frameOffset..<frameData.count)

                if let image = UIImage(data: imageData) {
                    print("✅ Successfully extracted artwork from ID3v2 APIC frame: \(filename)")
                    return image
                } else {
                    print("⚠️ Could not create UIImage from APIC data in: \(filename)")
                }
            }

            offset += frameSize
        }

        print("⚠️ No APIC frame found in ID3v2 tag: \(filename)")
        return nil
    }

    // Safe byte reading helper for DSF format (little-endian)
    private nonisolated func readLittleEndianUInt64(from data: Data, offset: Int) -> UInt64 {
        guard offset >= 0 && offset + 8 <= data.count else {
            print("⚠️ Invalid byte access in artwork: offset=\(offset), dataSize=\(data.count)")
            return 0
        }

        let byte0 = UInt64(data[offset])
        let byte1 = UInt64(data[offset + 1]) << 8
        let byte2 = UInt64(data[offset + 2]) << 16
        let byte3 = UInt64(data[offset + 3]) << 24
        let byte4 = UInt64(data[offset + 4]) << 32
        let byte5 = UInt64(data[offset + 5]) << 40
        let byte6 = UInt64(data[offset + 6]) << 48
        let byte7 = UInt64(data[offset + 7]) << 56

        return byte0 | byte1 | byte2 | byte3 | byte4 | byte5 | byte6 | byte7
    }

    // MARK: - Generic Artwork Extraction (Opus, OGG, etc.)

    private nonisolated func extractGenericArtwork(from url: URL) async -> UIImage? {
        // Use SFBAudioEngine's TagLib-backed metadata reader. The previous
        // hand-rolled byte scan corrupted any METADATA_BLOCK_PICTURE larger
        // than one Ogg page (~64KB): the base64 payload is interleaved with
        // Ogg page headers, which the scan couldn't strip (issue #75).
        do {
            let audioFile = try AudioFile(readingPropertiesAndMetadataFrom: url)
            let pictures = audioFile.metadata.attachedPictures
            let preferred = pictures.first(where: { $0.type == .frontCover }) ?? pictures.first
            if let preferred, let image = UIImage(data: preferred.imageData) {
                print("✅ Extracted artwork via SFBAudioEngine metadata: \(url.lastPathComponent) (\(preferred.imageData.count) bytes)")
                return image
            }
        } catch {
            print("⚠️ SFBAudioEngine metadata read failed for \(url.lastPathComponent): \(error)")
        }

        // Fallback: legacy Vorbis comment scan (works for single-page pictures)
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            if let artwork = extractVorbisCommentArtwork(from: data, filename: url.lastPathComponent) {
                return artwork
            }

            print("⚠️ No artwork found in Vorbis comments: \(url.lastPathComponent)")
            return nil
        } catch {
            print("❌ Generic artwork extraction failed: \(error)")
            return nil
        }
    }

    // Extract artwork from Vorbis Comments (OGG/Opus)
    private nonisolated func extractVorbisCommentArtwork(from data: Data, filename: String) -> UIImage? {
        // In Vorbis comments, each field has format: [4 bytes length][field name]=[field value]
        // We need to read the length to get the complete value, not just stop at null byte

        // Search for "METADATA_BLOCK_PICTURE=" tag
        guard let pictureTagData = "METADATA_BLOCK_PICTURE=".data(using: .utf8) else {
            return nil
        }

        guard let tagRange = data.range(of: pictureTagData) else {
            print("⚠️ No METADATA_BLOCK_PICTURE tag found in: \(filename)")
            return nil
        }

        // The value starts right after the "=" sign
        let valueStart = tagRange.upperBound

        // In Vorbis comments, the length is stored BEFORE the tag name
        // Go back to read the length field (4 bytes little-endian before tag name starts)
        let lengthOffset = tagRange.lowerBound - 4

        var valueLength: Int
        if lengthOffset >= 0 && lengthOffset + 4 <= data.count {
            // Read 4-byte little-endian length
            valueLength = Int(readLittleEndianUInt32(from: data, offset: lengthOffset))
            // Subtract the tag name length ("METADATA_BLOCK_PICTURE=".count)
            valueLength = valueLength - pictureTagData.count
            print("🔍 Read Vorbis comment length field: \(valueLength) bytes")
        } else {
            // Fallback: find null byte terminator
            var valueEnd = valueStart
            while valueEnd < data.count {
                let byte = data[valueEnd]
                if byte == 0x00 {
                    break
                }
                valueEnd += 1
            }
            valueLength = valueEnd - valueStart
            print("🔍 Using null-terminated length: \(valueLength) bytes")
        }

        guard valueLength > 0 && valueStart + valueLength <= data.count else {
            print("⚠️ Invalid METADATA_BLOCK_PICTURE length in: \(filename)")
            return nil
        }

        // Extract the value data with correct length
        let valueData = data.subdata(in: valueStart..<valueStart + valueLength)

        // Check if this is binary data (starts with 0x00 0x00 0x00) or base64 text
        // Binary format starts with picture type as 4 bytes (usually 0x00000003 for front cover)
        // Base64 will start with ASCII letters like 'A' (0x41)
        let isBinary = valueData.count >= 4 &&
                      valueData[0] == 0x00 &&
                      valueData[1] == 0x00 &&
                      valueData[2] == 0x00

        let pictureBlockData: Data

        if isBinary {
            // Data is already in binary format (some tools store it this way)
            print("🔍 Detected binary METADATA_BLOCK_PICTURE format (starts with 0x00) in: \(filename)")
            pictureBlockData = valueData
        } else {
            // Try to decode as base64-encoded (standard format)
            // Filter data to only valid base64 characters (A-Z, a-z, 0-9, +, /, =)
            // This handles cases where null bytes or other characters are mixed in
            let validBase64Chars: Set<UInt8> = Set(
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=".utf8
            )

            var filteredData = Data(valueData.filter { validBase64Chars.contains($0) })
            print("🔍 Filtered base64 data: \(valueData.count) → \(filteredData.count) bytes")

            // Add padding to make length a multiple of 4 (required for base64)
            let remainder = filteredData.count % 4
            if remainder > 0 {
                let paddingNeeded = 4 - remainder
                let paddingBytes = Data(repeating: UInt8(ascii: "="), count: paddingNeeded)
                filteredData.append(paddingBytes)
                print("🔍 Added \(paddingNeeded) padding bytes, new length: \(filteredData.count)")
            }

            // Try to decode the filtered and padded data
            if let decoded = Data(base64Encoded: filteredData, options: .ignoreUnknownCharacters) {
                print("🔍 Successfully decoded base64 METADATA_BLOCK_PICTURE, size: \(decoded.count) bytes")
                pictureBlockData = decoded
            } else {
                print("⚠️ Failed to decode filtered base64, treating as binary in: \(filename)")
                // Last resort: treat as binary data
                pictureBlockData = valueData
            }
        }

        print("🎨 Found METADATA_BLOCK_PICTURE in \(filename), size: \(pictureBlockData.count) bytes")

        // Parse FLAC picture block structure
        return parseFLACPictureBlock(data: pictureBlockData, filename: filename)
    }

    // Parse FLAC picture block structure (RFC 9639)
    private nonisolated func parseFLACPictureBlock(data: Data, filename: String) -> UIImage? {
        var offset = 0

        guard data.count >= 32 else {
            print("⚠️ METADATA_BLOCK_PICTURE too small: \(filename)")
            return nil
        }

        // Read picture type (32 bits, big-endian)
        let pictureType = readBigEndianUInt32(from: data, offset: offset)
        offset += 4
        print("🖼️ Picture type: \(pictureType)")

        // Read MIME type length (32 bits, big-endian)
        let mimeLength = Int(readBigEndianUInt32(from: data, offset: offset))
        offset += 4

        guard offset + mimeLength <= data.count else {
            print("⚠️ Invalid MIME type length in: \(filename)")
            return nil
        }

        // Read MIME type string
        let mimeData = data.subdata(in: offset..<offset + mimeLength)
        let mimeType = String(data: mimeData, encoding: .utf8) ?? ""
        offset += mimeLength
        print("🖼️ MIME type: \(mimeType)")

        // Read description length (32 bits, big-endian)
        guard offset + 4 <= data.count else {
            print("⚠️ Not enough data for description length field")
            return nil
        }
        let descLength = Int(readBigEndianUInt32(from: data, offset: offset))
        offset += 4
        print("🖼️ Description length: \(descLength)")

        // Skip description
        guard offset + descLength <= data.count else {
            print("⚠️ Invalid description length")
            return nil
        }
        offset += descLength

        // Skip width, height, color depth, number of colors (4 × 32 bits = 16 bytes)
        guard offset + 16 <= data.count else {
            print("⚠️ Not enough data for image dimensions")
            return nil
        }
        offset += 16

        // Read picture data length (32 bits, big-endian)
        guard offset + 4 <= data.count else {
            print("⚠️ Not enough data for picture length field")
            return nil
        }
        let pictureLength = Int(readBigEndianUInt32(from: data, offset: offset))
        offset += 4

        print("🖼️ Picture data length field: \(pictureLength) bytes")
        print("🖼️ Current offset: \(offset), Total data size: \(data.count), Remaining: \(data.count - offset)")

        // Extract picture data - use remaining data if length field is incorrect
        let actualPictureLength: Int
        if offset + pictureLength <= data.count {
            actualPictureLength = pictureLength
        } else {
            // Length field is wrong - just use all remaining data
            actualPictureLength = data.count - offset
            print("⚠️ Picture length field incorrect, using all remaining \(actualPictureLength) bytes")
        }

        // Extract picture data
        let pictureData = data.subdata(in: offset..<offset + actualPictureLength)

        if let image = UIImage(data: pictureData) {
            print("✅ Successfully extracted \(mimeType) artwork from Vorbis comments: \(filename)")
            return image
        } else {
            print("⚠️ Could not create UIImage from picture data in: \(filename)")
            return nil
        }
    }

    // Read 32-bit big-endian unsigned integer
    private nonisolated func readBigEndianUInt32(from data: Data, offset: Int) -> UInt32 {
        guard offset >= 0 && offset + 4 <= data.count else {
            return 0
        }

        let byte0 = UInt32(data[offset]) << 24
        let byte1 = UInt32(data[offset + 1]) << 16
        let byte2 = UInt32(data[offset + 2]) << 8
        let byte3 = UInt32(data[offset + 3])

        return byte0 | byte1 | byte2 | byte3
    }

    // Read 32-bit little-endian unsigned integer (for Vorbis comments)
    private nonisolated func readLittleEndianUInt32(from data: Data, offset: Int) -> UInt32 {
        guard offset >= 0 && offset + 4 <= data.count else {
            return 0
        }

        let byte0 = UInt32(data[offset])
        let byte1 = UInt32(data[offset + 1]) << 8
        let byte2 = UInt32(data[offset + 2]) << 16
        let byte3 = UInt32(data[offset + 3]) << 24

        return byte0 | byte1 | byte2 | byte3
    }
}

extension View {
    /// Reloads a view's cover when the library extracts or replaces it.
    ///
    /// Rows and cover cards load their artwork exactly once, from `.onAppear`,
    /// and only when they are still showing nothing. A track indexed moments
    /// before its row appeared has no cover yet, so `getThumbnail` answers nil,
    /// the placeholder is drawn - and nothing ever asks again. `.onAppear` does
    /// not fire a second time while the row stays on screen, so newly added
    /// songs kept their placeholder for as long as the list was open, while the
    /// player and the lock screen (which already observe this notification)
    /// showed the cover correctly.
    ///
    /// - Parameter stableId: the track whose cover this view draws. For an
    ///   album, playlist or artist card that is the track its cover is taken
    ///   from. `nil` never matches, so a view with nothing to draw stays quiet.
    func reloadsArtwork(for stableId: String?, perform reload: @escaping () -> Void) -> some View {
        onReceive(
            NotificationCenter.default.publisher(for: ArtworkManager.artworkChangedNotification)
        ) { notification in
            guard let stableId,
                  notification.userInfo?["trackStableId"] as? String == stableId else { return }
            reload()
        }
        // Also retry at the end of a scan. The notification above only fires
        // when a cover is actually extracted or replaced, so it cannot rescue
        // the case that matters most: a row whose first extraction attempt
        // found an iCloud placeholder and answered nil. By the time the scan
        // reports in, the bytes have usually landed. `loadArtwork` is a cache
        // hit whenever the cover is already known, so the retry is cheap.
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSNotification.Name("LibraryNeedsRefresh")
            )
        ) { _ in
            reload()
        }
    }
}
