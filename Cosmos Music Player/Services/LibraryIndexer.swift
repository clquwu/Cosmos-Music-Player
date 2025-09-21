//
//  LibraryIndexer.swift
//  Cosmos Music Player
//
//  Indexes FLAC files in iCloud Drive using NSMetadataQuery
//

import Foundation
import CryptoKit
import AVFoundation

enum LibraryIndexerError: Error {
    case parseTimeout
    case metadataParsingFailed
}

@MainActor
class LibraryIndexer: NSObject, ObservableObject {
    static let shared = LibraryIndexer()
    
    @Published var isIndexing = false
    @Published var indexingProgress: Double = 0.0
    @Published var tracksFound = 0
    @Published var currentlyProcessing: String = ""
    @Published var queuedFiles: [String] = []
    
    private let metadataQuery = NSMetadataQuery()
    private let databaseManager = DatabaseManager.shared
    private let stateManager = StateManager.shared
    
    override init() {
        super.init()
        setupMetadataQuery()
    }
    
    private func setupMetadataQuery() {
        metadataQuery.delegate = self
        
        // Search only within the app's iCloud container
        if let musicFolderURL = stateManager.getMusicFolderURL() {
            metadataQuery.searchScopes = [musicFolderURL]
        } else {
            metadataQuery.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        }
        
        metadataQuery.predicate = NSPredicate(format: "%K LIKE '*.flac' OR %K LIKE '*.mp3'", NSMetadataItemFSNameKey, NSMetadataItemFSNameKey)
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidGatherInitialResults),
            name: NSNotification.Name.NSMetadataQueryDidFinishGathering,
            object: metadataQuery
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidUpdate),
            name: NSNotification.Name.NSMetadataQueryDidUpdate,
            object: metadataQuery
        )
    }
    
    func start() {
        guard !isIndexing else { return }
        
        // Attempt recovery from offline mode when manually syncing
        CloudDownloadManager.shared.attemptRecovery()
        
        isIndexing = true
        indexingProgress = 0.0
        tracksFound = 0
        
        // Copy any new files from share extension first
        Task {
            await copyFilesFromSharedContainer()
        }
        
        if let musicFolderURL = stateManager.getMusicFolderURL() {
            print("Starting iCloud library indexing in: \(musicFolderURL)")
            
            // Check if folder exists and list its contents
            if FileManager.default.fileExists(atPath: musicFolderURL.path) {
                do {
                    let contents = try FileManager.default.contentsOfDirectory(at: musicFolderURL, includingPropertiesForKeys: nil)
                    print("Found \(contents.count) items in Cosmos Player folder:")
                    for item in contents {
                        print("  - \(item.lastPathComponent)")
                    }
                } catch {
                    print("Error listing folder contents: \(error)")
                }
            } else {
                print("Cosmos Player folder doesn't exist yet")
            }
        } else {
            print("No music folder URL available")
        }
        
        metadataQuery.start()
        
        // Add a timeout to trigger fallback if NSMetadataQuery doesn't work
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            print("Timeout check: resultCount=\(metadataQuery.resultCount), isIndexing=\(isIndexing)")
            if metadataQuery.resultCount == 0 && isIndexing {
                print("NSMetadataQuery timeout - triggering fallback scan")
                await fallbackToDirectScan()
            }
        }
    }
    
    func startOfflineMode() {
        guard !isIndexing else { return }
        
        isIndexing = true
        indexingProgress = 0.0
        tracksFound = 0
        
        Task {
            await scanLocalDocuments()
        }
    }
    
    func stop() {
        metadataQuery.stop()
        isIndexing = false
    }
    
    func switchToOfflineMode() {
        print("🔄 Switching LibraryIndexer to offline mode")
        stop()
        startOfflineMode()
    }

    func processExternalFile(_ fileURL: URL) async {
        do {
            print("🎵 Starting to process external file: \(fileURL.lastPathComponent)")
            print("📱 Processing external file from: \(fileURL.path)")

            print("🆔 Generating stable ID for: \(fileURL.lastPathComponent)")
            let stableId = try generateStableId(for: fileURL)
            print("🆔 Generated stable ID: \(stableId)")

            // Check if track already exists in database
            if try databaseManager.getTrack(byStableId: stableId) != nil {
                print("⏭️ Track already exists in database: \(fileURL.lastPathComponent)")
                return
            }

            print("🎶 Parsing external audio file: \(fileURL.lastPathComponent)")
            let track = try await parseAudioFile(at: fileURL, stableId: stableId)
            print("✅ External audio file parsed successfully: \(track.title)")

            print("💾 Inserting external track into database: \(track.title)")
            try databaseManager.upsertTrack(track)
            print("✅ External track inserted into database: \(track.title)")

            await MainActor.run {
                tracksFound += 1
                print("📢 Posting TrackFound notification for external file: \(track.title)")
                // Notify UI immediately that a new track was found
                NotificationCenter.default.post(name: NSNotification.Name("TrackFound"), object: track)
            }

        } catch LibraryIndexerError.parseTimeout {
            print("⏰ Timeout parsing external audio file: \(fileURL.lastPathComponent)")
            print("❌ Skipping external file due to parsing timeout")
        } catch {
            print("❌ Failed to process external track at \(fileURL.lastPathComponent): \(error)")
            print("❌ Error type: \(type(of: error))")
            print("❌ Error details: \(String(describing: error))")
        }
    }
    
    @objc private func queryDidGatherInitialResults() {
        print("🔍 NSMetadataQuery gathered initial results: \(metadataQuery.resultCount) items")
        for i in 0..<metadataQuery.resultCount {
            if let item = metadataQuery.result(at: i) as? NSMetadataItem,
               let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL {
                print("  Found: \(url.lastPathComponent)")
            }
        }
        Task {
            await processQueryResults()
        }
    }
    
    @objc private func queryDidUpdate() {
        Task {
            await processQueryResults()
        }
    }
    
    private func processQueryResults() async {
        metadataQuery.disableUpdates()
        defer { metadataQuery.enableUpdates() }
        
        let itemCount = metadataQuery.resultCount
        
        if itemCount == 0 {
            print("NSMetadataQuery found 0 results, falling back to direct file system scan")
            await fallbackToDirectScan()
            return
        }
        
        var processedCount = 0
        
        for i in 0..<itemCount {
            guard let item = metadataQuery.result(at: i) as? NSMetadataItem else { continue }
            
            await processMetadataItem(item)
            
            processedCount += 1
            indexingProgress = Double(processedCount) / Double(itemCount)
        }
        
        isIndexing = false
        print("Library indexing completed. Found \(tracksFound) tracks.")
    }
    
    private func fallbackToDirectScan() async {
        print("🔄 Starting fallback direct scan of both iCloud and local folders")
        
        var allMusicFiles: [URL] = []
        
        // First, copy any new files from shared container to Documents
        await copyFilesFromSharedContainer()
        
        // Scan iCloud folder if available
        if let iCloudMusicFolderURL = stateManager.getMusicFolderURL() {
            print("📁 Scanning iCloud folder: \(iCloudMusicFolderURL.path)")
            do {
                let iCloudFiles = try await findMusicFiles(in: iCloudMusicFolderURL)
                print("📁 Found \(iCloudFiles.count) files in iCloud folder")
                allMusicFiles.append(contentsOf: iCloudFiles)
            } catch {
                print("⚠️ Failed to scan iCloud folder: \(error)")
            }
        }
        
        // Scan local Documents folder
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        print("📱 Scanning local Documents folder: \(documentsPath.path)")
        do {
            let localFiles = try await findMusicFiles(in: documentsPath)
            print("📱 Found \(localFiles.count) files in local Documents folder")
            for file in localFiles {
                print("  📄 Local file: \(file.lastPathComponent)")
            }
            allMusicFiles.append(contentsOf: localFiles)
        } catch {
            print("⚠️ Failed to scan local Documents folder: \(error)")
        }
        
        let totalFiles = allMusicFiles.count
        print("📁 Total music files found (iCloud + local): \(totalFiles)")
        
        guard totalFiles > 0 else {
            isIndexing = false
            print("❌ No music files found in any location")
            return
        }
        
        // Set initial queue
        await MainActor.run {
            queuedFiles = allMusicFiles.map { $0.lastPathComponent }
            currentlyProcessing = ""
        }
        
        for (index, url) in allMusicFiles.enumerated() {
            let fileName = url.lastPathComponent
            let isLocalFile = !url.path.contains("Mobile Documents")
            print("🎵 Processing \(index + 1)/\(totalFiles): \(fileName) \(isLocalFile ? "[LOCAL]" : "[iCLOUD]")")
            
            // Update UI to show current file being processed
            await MainActor.run {
                currentlyProcessing = fileName
                queuedFiles = Array(allMusicFiles.suffix(from: index + 1).map { $0.lastPathComponent })
            }
            
            // Skip iCloud processing if we're in offline mode due to auth issues
            if !isLocalFile && (AppCoordinator.shared.iCloudStatus == .authenticationRequired || !AppCoordinator.shared.isiCloudAvailable) {
                print("🚫 Skipping iCloud file processing - iCloud authentication required: \(fileName)")
                continue
            }
            
            await processLocalFile(url)
            
            await MainActor.run {
                indexingProgress = Double(index + 1) / Double(totalFiles)
            }
        }
        
        // Clear processing state when done
        await MainActor.run {
            currentlyProcessing = ""
            queuedFiles = []
        }
        
        isIndexing = false
        print("✅ Direct scan completed. Found \(tracksFound) tracks from both iCloud and local folders.")
    }
    
    private func scanLocalDocuments() async {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        
        do {
            let musicFiles = try await findMusicFiles(in: documentsPath)
            
            let totalFiles = musicFiles.count
            var processedFiles = 0
            
            for fileURL in musicFiles {
                await processLocalFile(fileURL)
                
                processedFiles += 1
                await MainActor.run {
                    indexingProgress = Double(processedFiles) / Double(totalFiles)
                }
            }
            
            await MainActor.run {
                isIndexing = false
                print("Offline library scan completed. Found \(tracksFound) tracks.")
            }
        } catch {
            await MainActor.run {
                isIndexing = false
                print("Offline library scan failed: \(error)")
            }
        }
    }
    
    private func findMusicFiles(in directory: URL) async throws -> [URL] {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .background).async {
                do {
                    var musicFiles: [URL] = []
                    
                    let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .nameKey]
                    let directoryEnumerator = FileManager.default.enumerator(
                        at: directory,
                        includingPropertiesForKeys: resourceKeys,
                        options: [.skipsHiddenFiles]
                    )
                    
                    guard let enumerator = directoryEnumerator else {
                        continuation.resume(returning: musicFiles)
                        return
                    }
                    
                    for case let fileURL as URL in enumerator {
                        let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
                        
                        guard let isRegularFile = resourceValues.isRegularFile, isRegularFile else {
                            continue
                        }
                        
                        let pathExtension = fileURL.pathExtension.lowercased()
                        if pathExtension == "flac" || pathExtension == "mp3" {
                            musicFiles.append(fileURL)
                        }
                    }
                    
                    continuation.resume(returning: musicFiles)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    private func processLocalFile(_ fileURL: URL) async {
        do {
            print("🎵 Starting to process file: \(fileURL.lastPathComponent)")
            
            let isLocalFile = !fileURL.path.contains("Mobile Documents")
            
            // Only try to download from iCloud if it's actually an iCloud file
            if !isLocalFile {
                let cloudDownloadManager = CloudDownloadManager.shared
                do {
                    try await cloudDownloadManager.ensureLocal(fileURL)
                    print("✅ iCloud file ensured local: \(fileURL.lastPathComponent)")
                } catch {
                    print("⚠️ Failed to ensure iCloud file is local: \(fileURL.lastPathComponent) - \(error)")
                    
                    // Check for authentication errors
                    if let cloudError = error as? CloudDownloadError {
                        switch cloudError {
                        case .authenticationRequired, .accessDenied:
                            print("🔐 Authentication error in LibraryIndexer - switching to offline mode")
                            AppCoordinator.shared.handleiCloudAuthenticationError()
                            return // Skip this file
                        default:
                            break
                        }
                    }
                    
                    // Continue processing even if download fails (for other errors)
                }
            } else {
                print("📱 Processing local file (no iCloud download needed): \(fileURL.lastPathComponent)")
            }
            
            print("🆔 Generating stable ID for: \(fileURL.lastPathComponent)")
            let stableId = try generateStableId(for: fileURL)
            print("🆔 Generated stable ID: \(stableId)")
            
            if try databaseManager.getTrack(byStableId: stableId) != nil {
                print("⏭️ Track already exists in database: \(fileURL.lastPathComponent)")
                return
            }
            
            print("🎶 Parsing audio file: \(fileURL.lastPathComponent)")
            let track = try await parseAudioFile(at: fileURL, stableId: stableId)
            print("✅ Audio file parsed successfully: \(track.title)")
            
            print("💾 Inserting track into database: \(track.title)")
            try databaseManager.upsertTrack(track)
            print("✅ Track inserted into database: \(track.title)")
            
            await MainActor.run {
                tracksFound += 1
                print("📢 Posting TrackFound notification for: \(track.title)")
                // Notify UI immediately that a new track was found
                NotificationCenter.default.post(name: NSNotification.Name("TrackFound"), object: track)
            }
            
            // Check if file is downloaded (for iCloud files)
            await checkDownloadStatus(for: fileURL)
            
        } catch LibraryIndexerError.parseTimeout {
            print("⏰ Timeout parsing audio file: \(fileURL.lastPathComponent)")
            print("❌ Skipping file due to parsing timeout")
        } catch {
            print("❌ Failed to process local track at \(fileURL.lastPathComponent): \(error)")
            print("❌ Error type: \(type(of: error))")
            print("❌ Error details: \(String(describing: error))")
        }
    }
    
    private func checkDownloadStatus(for fileURL: URL) async {
        do {
            let resourceValues = try fileURL.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey, .isUbiquitousItemKey])
            
            if let isUbiquitous = resourceValues.isUbiquitousItem, isUbiquitous {
                if let downloadStatus = resourceValues.ubiquitousItemDownloadingStatus {
                    switch downloadStatus {
                    case .notDownloaded:
                        print("File not downloaded: \(fileURL.lastPathComponent)")
                        // Trigger download
                        try FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
                    case .downloaded:
                        print("File is downloaded: \(fileURL.lastPathComponent)")
                    case .current:
                        print("File is current: \(fileURL.lastPathComponent)")
                    default:
                        print("Unknown download status for: \(fileURL.lastPathComponent)")
                    }
                }
            }
        } catch {
            print("Failed to check download status for \(fileURL.lastPathComponent): \(error)")
        }
    }
    
    private func processMetadataItem(_ item: NSMetadataItem) async {
        guard let fileURL = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { return }
        let ext = fileURL.pathExtension.lowercased()
        guard ext == "flac" || ext == "mp3" else { return }
        
        do {
            let stableId = try generateStableId(for: fileURL)
            
            if try databaseManager.getTrack(byStableId: stableId) != nil {
                return
            }
            
            try await CloudDownloadManager.shared.ensureLocal(fileURL)
            
            let track = try await parseAudioFile(at: fileURL, stableId: stableId)
            try databaseManager.upsertTrack(track)
            
            await MainActor.run {
                tracksFound += 1
                // Notify UI immediately that a new track was found
                NotificationCenter.default.post(name: NSNotification.Name("TrackFound"), object: track)
            }
            
            // Check if file is downloaded (for iCloud files)
            await checkDownloadStatus(for: fileURL)
            
        } catch {
            print("Failed to process track at \(fileURL): \(error)")
        }
    }
    
    private func generateStableId(for url: URL) throws -> String {
        // Simple stable ID based only on filename - this is truly stable
        let filename = url.lastPathComponent
        let digest = SHA256.hash(data: filename.data(using: .utf8) ?? Data())
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    private func parseAudioFile(at url: URL, stableId: String) async throws -> Track {
        print("🔍 Calling AudioMetadataParser for: \(url.lastPathComponent)")
        
        // Add timeout to prevent hanging
        let metadata = try await withThrowingTaskGroup(of: AudioMetadata.self) { group in
            group.addTask {
                return try await AudioMetadataParser.parseMetadata(from: url)
            }
            
            group.addTask {
                try await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds timeout
                throw LibraryIndexerError.parseTimeout
            }
            
            guard let result = try await group.next() else {
                throw LibraryIndexerError.parseTimeout
            }
            
            group.cancelAll()
            return result
        }
        
        print("✅ AudioMetadataParser completed for: \(url.lastPathComponent)")
        
        // Clean and normalize artist name to merge similar artists
        let cleanedArtistName = cleanArtistName(metadata.artist ?? "Unknown Artist")
        print("🎤 Creating artist with cleaned name: '\(cleanedArtistName)'")
        
        let artist = try databaseManager.upsertArtist(name: cleanedArtistName)
        let album = try databaseManager.upsertAlbum(
            title: metadata.album ?? Localized.unknownAlbum,
            artistId: artist.id,
            year: metadata.year,
            albumArtist: metadata.albumArtist
        )
        
        let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
        
        return Track(
            stableId: stableId,
            albumId: album.id,
            artistId: artist.id,
            title: metadata.title ?? url.deletingPathExtension().lastPathComponent,
            trackNo: metadata.trackNumber,
            discNo: metadata.discNumber,
            durationMs: metadata.durationMs,
            sampleRate: metadata.sampleRate,
            bitDepth: metadata.bitDepth,
            channels: metadata.channels,
            path: url.path,
            fileSize: Int64(resourceValues.fileSize ?? 0),
            replaygainTrackGain: metadata.replaygainTrackGain,
            replaygainAlbumGain: metadata.replaygainAlbumGain,
            replaygainTrackPeak: metadata.replaygainTrackPeak,
            replaygainAlbumPeak: metadata.replaygainAlbumPeak,
            hasEmbeddedArt: metadata.hasEmbeddedArt
        )
    }
    
    private func cleanArtistName(_ artistName: String) -> String {
        var cleaned = artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove common YouTube/streaming suffixes
        let suffixesToRemove = [
            " - Topic",
            " Topic",
            "- Topic", 
            ", Topic",
            " (Topic)"
        ]
        
        for suffix in suffixesToRemove {
            if cleaned.hasSuffix(suffix) {
                cleaned = String(cleaned.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        // Handle multiple artists - take the first main artist and clean up formatting
        if cleaned.contains(",") {
            let components = cleaned.components(separatedBy: ",")
            if let firstArtist = components.first?.trimmingCharacters(in: .whitespacesAndNewlines) {
                cleaned = firstArtist
            }
        }
        
        // Remove brackets and additional info that might cause duplicates
        if let bracketStart = cleaned.firstIndex(of: "[") {
            cleaned = String(cleaned[..<bracketStart]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return cleaned.isEmpty ? "Unknown Artist" : cleaned
    }
    
    func copyFilesFromSharedContainer() async {
        print("📁 Checking shared container for new music files...")

        guard let sharedContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.dev.clq.Cosmos-Music-Player") else {
            print("❌ Failed to get shared container URL")
            return
        }

        // Process shared URLs from share extension
        await processSharedURLs(from: sharedContainer)

        // Also check for legacy copied files (for backward compatibility)
        await processLegacySharedFiles(from: sharedContainer)

        // Process previously stored external bookmarks (both document picker and share extension files)
        await processStoredExternalBookmarks()
    }

    private func processSharedURLs(from sharedContainer: URL) async {
        let sharedDataURL = sharedContainer.appendingPathComponent("SharedAudioFiles.plist")

        guard FileManager.default.fileExists(atPath: sharedDataURL.path) else {
            print("📁 No shared audio files found")
            return
        }

        do {
            let data = try Data(contentsOf: sharedDataURL)
            guard let sharedFiles = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [[String: Data]] else {
                return
            }

            print("📁 Found \(sharedFiles.count) shared audio file references")

            for fileInfo in sharedFiles {
                guard let bookmarkData = fileInfo["bookmark"],
                      let filenameData = fileInfo["filename"],
                      let filename = String(data: filenameData, encoding: .utf8) else {
                    continue
                }

                do {
                    // Resolve bookmark to get access to the original file
                    var isStale = false
                    let url = try URL(resolvingBookmarkData: bookmarkData, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale)

                    if isStale {
                        print("⚠️ Bookmark is stale for: \(filename)")
                        continue
                    }

                    // Start accessing security-scoped resource
                    guard url.startAccessingSecurityScopedResource() else {
                        print("❌ Failed to access security-scoped resource for: \(filename)")
                        continue
                    }

                    defer {
                        url.stopAccessingSecurityScopedResource()
                    }

                    // Process the file directly from its original location
                    await processExternalFile(url)
                    print("✅ Processed shared file from original location: \(filename)")

                    // Store the bookmark permanently for future access after app updates
                    await storeBookmarkPermanently(bookmarkData, for: url)

                } catch {
                    print("❌ Failed to resolve bookmark for \(filename): \(error)")
                }
            }

            // Clear the shared files list after processing and storing bookmarks permanently
            try FileManager.default.removeItem(at: sharedDataURL)
            print("🗑️ Cleared shared audio files list (bookmarks moved to permanent storage)")

        } catch {
            print("❌ Failed to process shared audio files: \(error)")
        }
    }

    private func processLegacySharedFiles(from sharedContainer: URL) async {
        let sharedMusicURL = sharedContainer.appendingPathComponent("Documents").appendingPathComponent("Music")
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let localMusicURL = documentsURL.appendingPathComponent("Music")

        // Create local Music directory if it doesn't exist
        do {
            try FileManager.default.createDirectory(at: localMusicURL, withIntermediateDirectories: true, attributes: nil)
        } catch {
            print("❌ Failed to create local Music directory: \(error)")
            return
        }

        // Check if shared Music directory exists
        guard FileManager.default.fileExists(atPath: sharedMusicURL.path) else {
            print("📁 No shared Music directory found")
            return
        }

        do {
            let sharedFiles = try FileManager.default.contentsOfDirectory(at: sharedMusicURL, includingPropertiesForKeys: nil)
            let audioFiles = sharedFiles.filter { url in
                let ext = url.pathExtension.lowercased()
                return ext == "mp3" || ext == "flac" || ext == "wav"
            }

            print("📁 Found \(audioFiles.count) legacy audio files in shared container")

            for audioFile in audioFiles {
                let localDestination = localMusicURL.appendingPathComponent(audioFile.lastPathComponent)

                // Skip if file already exists in local directory
                if FileManager.default.fileExists(atPath: localDestination.path) {
                    print("⏭️ File already exists locally: \(audioFile.lastPathComponent)")
                    continue
                }

                do {
                    try FileManager.default.copyItem(at: audioFile, to: localDestination)
                    print("✅ Copied legacy file to Documents/Music: \(audioFile.lastPathComponent)")

                    // Remove from shared container after successful copy
                    try FileManager.default.removeItem(at: audioFile)
                    print("🗑️ Removed legacy file from shared container: \(audioFile.lastPathComponent)")

                } catch {
                    print("❌ Failed to copy legacy file \(audioFile.lastPathComponent): \(error)")
                }
            }

        } catch {
            print("❌ Failed to read shared container directory: \(error)")
        }
    }

    private func storeBookmarkPermanently(_ bookmarkData: Data, for url: URL) async {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let bookmarksURL = documentsURL.appendingPathComponent("ExternalFileBookmarks.plist")

        do {
            // Load existing bookmarks or create new dictionary
            var bookmarks: [String: Data] = [:]
            if FileManager.default.fileExists(atPath: bookmarksURL.path) {
                let data = try Data(contentsOf: bookmarksURL)
                if let existingBookmarks = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Data] {
                    bookmarks = existingBookmarks
                }
            }

            // Store bookmark data using the file path as key
            bookmarks[url.path] = bookmarkData

            // Save updated bookmarks
            let plistData = try PropertyListSerialization.data(fromPropertyList: bookmarks, format: .xml, options: 0)
            try plistData.write(to: bookmarksURL)

            print("💾 Stored permanent bookmark for shared file: \(url.lastPathComponent)")
        } catch {
            print("❌ Failed to store permanent bookmark for \(url.lastPathComponent): \(error)")
        }
    }

    private func processStoredExternalBookmarks() async {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let bookmarksURL = documentsURL.appendingPathComponent("ExternalFileBookmarks.plist")

        guard FileManager.default.fileExists(atPath: bookmarksURL.path) else {
            print("📁 No stored external bookmarks found")
            return
        }

        do {
            let data = try Data(contentsOf: bookmarksURL)
            guard let bookmarks = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Data] else {
                print("❌ Invalid external bookmarks format")
                return
            }

            print("📁 Found \(bookmarks.count) stored external file bookmarks")

            for (filePath, bookmarkData) in bookmarks {
                do {
                    // Resolve bookmark to get access to the file
                    var isStale = false
                    let url = try URL(resolvingBookmarkData: bookmarkData, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale)

                    if isStale {
                        print("⚠️ Bookmark is stale for: \(URL(fileURLWithPath: filePath).lastPathComponent)")
                        continue
                    }

                    // Check if this file is already in the database
                    let stableId = try generateStableId(for: url)
                    if try databaseManager.getTrack(byStableId: stableId) != nil {
                        print("⏭️ External file already in database: \(url.lastPathComponent)")
                        continue
                    }

                    // Start accessing security-scoped resource
                    guard url.startAccessingSecurityScopedResource() else {
                        print("❌ Failed to access security-scoped resource for: \(url.lastPathComponent)")
                        continue
                    }

                    defer {
                        url.stopAccessingSecurityScopedResource()
                    }

                    // Process the file
                    await processExternalFile(url)
                    print("✅ Processed stored external file: \(url.lastPathComponent)")

                } catch {
                    print("❌ Failed to resolve bookmark for \(URL(fileURLWithPath: filePath).lastPathComponent): \(error)")
                }
            }

        } catch {
            print("❌ Failed to process stored external bookmarks: \(error)")
        }
    }
}

extension LibraryIndexer: NSMetadataQueryDelegate {
    nonisolated func metadataQuery(_ query: NSMetadataQuery, replacementObjectForResultObject result: NSMetadataItem) -> Any {
        return result
    }
}

struct AudioMetadata {
    let title: String?
    let artist: String?
    let album: String?
    let albumArtist: String?
    let trackNumber: Int?
    let discNumber: Int?
    let year: Int?
    let durationMs: Int?
    let sampleRate: Int?
    let bitDepth: Int?
    let channels: Int?
    let replaygainTrackGain: Double?
    let replaygainAlbumGain: Double?
    let replaygainTrackPeak: Double?
    let replaygainAlbumPeak: Double?
    let hasEmbeddedArt: Bool
}

class AudioMetadataParser {
    static func parseMetadata(from url: URL) async throws -> AudioMetadata {
        return try await parseAudioMetadataSync(from: url)
    }
    
    private static func parseAudioMetadataSync(from url: URL) async throws -> AudioMetadata {
        let ext = url.pathExtension.lowercased()
        
        if ext == "flac" {
            return try await parseFlacMetadataSync(from: url)
        } else if ext == "mp3" {
            return try await parseMp3MetadataSync(from: url)
        } else {
            throw AudioParseError.unsupportedFormat
        }
    }
    
    private static func parseFlacMetadataSync(from url: URL) async throws -> AudioMetadata {
        var title: String?
        var artist: String?
        var album: String?
        var albumArtist: String?
        var trackNumber: Int?
        var discNumber: Int?
        var year: Int?
        var durationMs: Int?
        var sampleRate: Int?
        var bitDepth: Int?
        var channels: Int?
        var replaygainTrackGain: Double?
        var replaygainAlbumGain: Double?
        var replaygainTrackPeak: Double?
        var replaygainAlbumPeak: Double?
        var hasEmbeddedArt = false
        
        // Check if file is actually readable first
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            print("❌ FLAC file is not readable: \(url.lastPathComponent)")
            throw AudioParseError.fileNotReadable
        }
        
        // Get file size to check if reasonable
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSize = fileAttributes[.size] as? Int64 else {
            throw AudioParseError.fileNotReadable
        }
        
        print("📊 FLAC file size: \(fileSize) bytes for \(url.lastPathComponent)")
        
        // Don't try to read files that are too large (>100MB) or too small (<1KB)
        guard fileSize > 1024 && fileSize < 300_000_000 else {
            print("❌ FLAC file size is unreasonable: \(fileSize) bytes")
            throw AudioParseError.fileSizeError
        }
        
        print("📖 Reading FLAC data for: \(url.lastPathComponent)")
        
        // Use NSFileCoordinator to properly read iCloud files
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .background).async {
                var error: NSError?
                let coordinator = NSFileCoordinator()
                var coordinatedData: Data?
                var coordinatedError: Error?
                
                coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &error) { (readingURL) in
                    do {
                        // Create fresh URL to avoid stale metadata
                        let freshURL = URL(fileURLWithPath: readingURL.path)
                        print("🔄 Using NSFileCoordinator to read: \(freshURL.lastPathComponent)")
                        
                        // Check if file actually exists at path
                        guard FileManager.default.fileExists(atPath: freshURL.path) else {
                            coordinatedError = AudioParseError.fileNotReadable
                            return
                        }
                        
                        coordinatedData = try Data(contentsOf: freshURL)
                        print("✅ FLAC data read successfully via NSFileCoordinator: \(coordinatedData?.count ?? 0) bytes")
                    } catch {
                        print("❌ Failed to read FLAC data via NSFileCoordinator: \(error)")
                        coordinatedError = error
                    }
                }
                
                if let error = error {
                    print("❌ NSFileCoordinator error: \(error)")
                    continuation.resume(throwing: error)
                } else if let coordinatedError = coordinatedError {
                    continuation.resume(throwing: coordinatedError)
                } else if let data = coordinatedData {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: AudioParseError.fileNotReadable)
                }
            }
        }
        
        if data.count < 42 {
            throw AudioParseError.invalidFile
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
            
            if blockType == 0 {
                if offset + 18 <= data.count {
                    sampleRate = Int(data[offset + 10]) << 12 | Int(data[offset + 11]) << 4 | Int(data[offset + 12]) >> 4
                    channels = Int((data[offset + 12] >> 1) & 0x07) + 1
                    bitDepth = Int(((data[offset + 12] & 0x01) << 4) | (data[offset + 13] >> 4)) + 1
                    
                    let totalSamples = UInt64(data[offset + 13] & 0x0F) << 32 |
                                      UInt64(data[offset + 14]) << 24 |
                                      UInt64(data[offset + 15]) << 16 |
                                      UInt64(data[offset + 16]) << 8 |
                                      UInt64(data[offset + 17])
                    
                    if sampleRate! > 0 {
                        durationMs = Int((totalSamples * 1000) / UInt64(sampleRate!))
                    }
                }
            } else if blockType == 4 {
                let commentData = data.subdata(in: offset..<min(offset + blockSize, data.count))
                let metadata = parseVorbisComments(commentData)
                
                title = metadata["TITLE"]
                artist = metadata["ARTIST"] ?? metadata["ARTISTE"]
                album = metadata["ALBUM"]
                albumArtist = metadata["ALBUMARTIST"]
                
                if let trackStr = metadata["TRACKNUMBER"] {
                    trackNumber = Int(trackStr)
                }
                if let discStr = metadata["DISCNUMBER"] {
                    discNumber = Int(discStr)
                }
                if let dateStr = metadata["DATE"] {
                    year = Int(dateStr)
                }
                
                if let gainStr = metadata["REPLAYGAIN_TRACK_GAIN"] {
                    replaygainTrackGain = parseReplayGain(gainStr)
                }
                if let gainStr = metadata["REPLAYGAIN_ALBUM_GAIN"] {
                    replaygainAlbumGain = parseReplayGain(gainStr)
                }
                if let peakStr = metadata["REPLAYGAIN_TRACK_PEAK"] {
                    replaygainTrackPeak = Double(peakStr)
                }
                if let peakStr = metadata["REPLAYGAIN_ALBUM_PEAK"] {
                    replaygainAlbumPeak = Double(peakStr)
                }
            } else if blockType == 6 {
                // PICTURE block - embedded artwork
                hasEmbeddedArt = true
            }
            
            offset += blockSize
            
            if isLast { break }
        }
        
        return AudioMetadata(
            title: title,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            trackNumber: trackNumber,
            discNumber: discNumber,
            year: year,
            durationMs: durationMs,
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            channels: channels,
            replaygainTrackGain: replaygainTrackGain,
            replaygainAlbumGain: replaygainAlbumGain,
            replaygainTrackPeak: replaygainTrackPeak,
            replaygainAlbumPeak: replaygainAlbumPeak,
            hasEmbeddedArt: hasEmbeddedArt
        )
    }
    
    private static func parseVorbisComments(_ data: Data) -> [String: String] {
        var comments: [String: String] = [:]
        var offset = 0
        
        guard offset + 4 <= data.count else { return comments }
        
        let vendorLength = Int(data[offset]) | (Int(data[offset + 1]) << 8) | (Int(data[offset + 2]) << 16) | (Int(data[offset + 3]) << 24)
        offset += 4 + vendorLength
        
        guard offset + 4 <= data.count else { return comments }
        
        let commentCount = Int(data[offset]) | (Int(data[offset + 1]) << 8) | (Int(data[offset + 2]) << 16) | (Int(data[offset + 3]) << 24)
        offset += 4
        
        for _ in 0..<commentCount {
            guard offset + 4 <= data.count else { break }
            
            let commentLength = Int(data[offset]) | (Int(data[offset + 1]) << 8) | (Int(data[offset + 2]) << 16) | (Int(data[offset + 3]) << 24)
            offset += 4
            
            guard offset + commentLength <= data.count else { break }
            
            if let commentString = String(data: data.subdata(in: offset..<offset + commentLength), encoding: .utf8) {
                let parts = commentString.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    comments[String(parts[0]).uppercased()] = String(parts[1])
                }
            }
            
            offset += commentLength
        }
        
        return comments
    }
    
    private static func parseReplayGain(_ gainString: String) -> Double? {
        let cleaned = gainString.replacingOccurrences(of: " dB", with: "")
        return Double(cleaned)
    }
    
    private static func parseMp3MetadataSync(from url: URL) async throws -> AudioMetadata {
        print("📖 Reading MP3 metadata for: \(url.lastPathComponent)")
        
        // Use NSFileCoordinator for iCloud files (same as FLAC)
        let asset: AVURLAsset = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .background).async {
                var error: NSError?
                let coordinator = NSFileCoordinator()
                
                coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &error) { (readingURL) in
                    // Create fresh URL to avoid stale metadata
                    let freshURL = URL(fileURLWithPath: readingURL.path)
                    print("🔄 Using NSFileCoordinator for MP3: \(freshURL.lastPathComponent)")
                    
                    // Check if file actually exists at path
                    guard FileManager.default.fileExists(atPath: freshURL.path) else {
                        continuation.resume(throwing: AudioParseError.fileNotReadable)
                        return
                    }
                    
                    let asset = AVURLAsset(url: freshURL)
                    print("✅ MP3 AVURLAsset created successfully via NSFileCoordinator")
                    continuation.resume(returning: asset)
                }
                
                if let error = error {
                    print("❌ NSFileCoordinator error for MP3: \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }
        
        var title: String?
        var artist: String?
        var album: String?
        var albumArtist: String?
        var trackNumber: Int?
        var discNumber: Int?
        var year: Int?
        var hasEmbeddedArt = false
        
        // Parse ID3 metadata using async API
        do {
            let commonMetadata = try await asset.load(.commonMetadata)
            let allMetadata = try await asset.load(.metadata)
            
            // Parse common metadata
            for item in commonMetadata {
                switch item.commonKey {
                case .commonKeyTitle:
                    title = try? await item.load(.stringValue)
                case .commonKeyArtist:
                    artist = try? await item.load(.stringValue)
                    print("🎤 Found artist in common metadata: \(artist ?? "nil")")
                case .commonKeyAlbumName:
                    album = try? await item.load(.stringValue)
                case .commonKeyCreationDate:
                    if let dateString = try? await item.load(.stringValue) {
                        year = Int(String(dateString.prefix(4)))
                    }
                case .commonKeyArtwork:
                    hasEmbeddedArt = true
                default:
                    break
                }
            }
            
            // Check for additional ID3 tags
            for metadata in allMetadata {
                if let key = metadata.commonKey?.rawValue {
                    switch key {
                    case "albumArtist":
                        albumArtist = try? await metadata.load(.stringValue)
                    case "artist":
                        // Additional check for artist in common key
                        if artist == nil {
                            artist = try? await metadata.load(.stringValue)
                            print("🎤 Found artist in additional common key: \(artist ?? "nil")")
                        }
                    default:
                        break
                    }
                } else if let identifier = metadata.identifier {
                    print("🔍 Checking ID3 tag: \(identifier.rawValue)")
                    switch identifier.rawValue {
                    case "id3/TRCK":
                        if let trackString = try? await metadata.load(.stringValue) {
                            trackNumber = Int(trackString.components(separatedBy: "/").first ?? "")
                        }
                    case "id3/TPOS":
                        if let discString = try? await metadata.load(.stringValue) {
                            discNumber = Int(discString.components(separatedBy: "/").first ?? "")
                        }
                    case "id3/TPE2":
                        albumArtist = try? await metadata.load(.stringValue)
                        print("🎤 Found album artist in TPE2: \(albumArtist ?? "nil")")
                    case "id3/TPE1":
                        // Fallback for main artist if not found in common metadata
                        if artist == nil {
                            artist = try? await metadata.load(.stringValue)
                            print("🎤 Found artist in TPE1: \(artist ?? "nil")")
                        }
                    // Add more ID3 artist tag variations
                    case "id3/TIT2":
                        // Title fallback
                        if title == nil {
                            title = try? await metadata.load(.stringValue)
                        }
                    case "id3/TALB":
                        // Album fallback
                        if album == nil {
                            album = try? await metadata.load(.stringValue)
                        }
                    default:
                        // Debug: log unhandled tags that might contain artist info
                        if identifier.rawValue.contains("ART") || identifier.rawValue.contains("TPE") {
                            let value = try? await metadata.load(.stringValue)
                            print("🔍 Unhandled artist-related tag \(identifier.rawValue): \(value ?? "nil")")
                        }
                        break
                    }
                }
            }
        } catch {
            print("Failed to load asset metadata: \(error)")
        }
        
        // Get actual audio format info
        var sampleRate: Int?
        var channels: Int?
        var durationMs: Int?
        
        // Use AVAudioFile to get precise format info
        do {
            let audioFile = try AVAudioFile(forReading: url)
            let format = audioFile.processingFormat
            
            sampleRate = Int(format.sampleRate)
            channels = Int(format.channelCount)
            
            // Calculate precise duration
            let totalFrames = audioFile.length
            durationMs = Int((Double(totalFrames) / format.sampleRate) * 1000)
            
        } catch {
            // Fallback to AVAsset for duration if AVAudioFile fails
            do {
                let duration = try await asset.load(.duration)
                if duration.isValid && !duration.isIndefinite {
                    durationMs = Int(CMTimeGetSeconds(duration) * 1000)
                }
            } catch {
                print("Failed to load duration: \(error)")
            }
            
            // Use reasonable defaults for format if we can't determine
            sampleRate = sampleRate ?? 44100
            channels = channels ?? 2
        }
        
        // Fallback to filename parsing if no metadata found
        if title == nil {
            let fileName = url.deletingPathExtension().lastPathComponent
            let components = fileName.components(separatedBy: " - ")
            
            if components.count >= 2 {
                artist = artist ?? components[0].trimmingCharacters(in: .whitespaces)
                title = components[1].trimmingCharacters(in: .whitespaces)
            } else {
                title = fileName
            }
        }
        
        print("🎵 Final MP3 metadata for \(url.lastPathComponent):")
        print("   Title: \(title ?? "nil")")
        print("   Artist: \(artist ?? "nil")")
        print("   Album: \(album ?? "nil")")
        print("   Album Artist: \(albumArtist ?? "nil")")
        
        return AudioMetadata(
            title: title,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            trackNumber: trackNumber,
            discNumber: discNumber,
            year: year,
            durationMs: durationMs,
            sampleRate: sampleRate,
            bitDepth: nil, // MP3 is lossy, bit depth doesn't apply
            channels: channels,
            replaygainTrackGain: nil,
            replaygainAlbumGain: nil,
            replaygainTrackPeak: nil,
            replaygainAlbumPeak: nil,
            hasEmbeddedArt: hasEmbeddedArt
        )
    }
}

enum AudioParseError: Error {
    case invalidFile
    case unsupportedFormat
    case fileNotReadable
    case fileSizeError
}
