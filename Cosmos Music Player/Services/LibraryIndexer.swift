//
//  LibraryIndexer.swift
//  Cosmos Music Player
//
//  Indexes audio files (FLAC, MP3, WAV, AAC, Opus, Vorbis, DSD) in iCloud Drive using NSMetadataQuery
//

import Foundation
import CryptoKit
import AVFoundation
import SFBAudioEngine

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
        
        // Support all audio formats according to plan
        let formats = ["*.flac", "*.mp3", "*.wav", "*.m4a", "*.aac", "*.opus", "*.ogg", "*.dsf", "*.dff"]
        let formatPredicates = formats.map { format in
            NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, format)
        }
        metadataQuery.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: formatPredicates)
        
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

        // Process folder playlists after scan completion
        await processFolderPlaylists(allMusicFiles: allMusicFiles)
    }

    private func processFolderPlaylists(allMusicFiles: [URL]) async {
        print("📁 Processing folder playlists...")

        // Group music files by their parent directory
        var folderGroups: [String: [URL]] = [:]

        for fileURL in allMusicFiles {
            let parentFolder = fileURL.deletingLastPathComponent()
            let folderPath = parentFolder.path

            // Skip if it's directly in Documents or iCloud root
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.path
            let iCloudMusicPath = stateManager.getMusicFolderURL()?.path

            if folderPath == documentsPath || folderPath == iCloudMusicPath {
                continue
            }

            if folderGroups[folderPath] == nil {
                folderGroups[folderPath] = []
            }
            folderGroups[folderPath]?.append(fileURL)
        }

        print("📁 Found \(folderGroups.count) folders with music files")

        for (folderPath, musicFiles) in folderGroups {
            await processFolderPlaylist(folderPath: folderPath, musicFiles: musicFiles)
        }

        print("✅ Folder playlist processing completed")
    }

    private func processFolderPlaylist(folderPath: String, musicFiles: [URL]) async {
        let folderURL = URL(fileURLWithPath: folderPath)
        let folderName = folderURL.lastPathComponent

        print("📂 Processing folder playlist for: \(folderName)")

        do {
            // Generate stable IDs for all music files in this folder
            var trackStableIds: [String] = []

            for musicFile in musicFiles {
                let stableId = try generateStableId(for: musicFile)
                trackStableIds.append(stableId)
            }

            print("🎵 Found \(trackStableIds.count) tracks in folder: \(folderName)")

            // Check if a folder playlist already exists for this path
            if let existingPlaylist = try databaseManager.getFolderPlaylist(forPath: folderPath) {
                print("🔄 Syncing existing folder playlist: \(existingPlaylist.title)")

                // Sync the existing playlist with current folder contents
                try databaseManager.syncPlaylistWithFolder(playlistId: existingPlaylist.id!, trackStableIds: trackStableIds)
                print("✅ Synced playlist '\(existingPlaylist.title)' with folder contents")
            } else {
                // Create new folder playlist
                print("➕ Creating new folder playlist: \(folderName)")

                let playlist = try databaseManager.createFolderPlaylist(title: folderName, folderPath: folderPath)
                try databaseManager.syncPlaylistWithFolder(playlistId: playlist.id!, trackStableIds: trackStableIds)
                print("✅ Created folder playlist '\(playlist.title)' with \(trackStableIds.count) tracks")
            }

        } catch {
            print("❌ Failed to process folder playlist for \(folderName): \(error)")
        }
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

            // Process folder playlists after offline scan
            await processFolderPlaylists(allMusicFiles: musicFiles)
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
                        let supportedExtensions = ["flac", "mp3", "wav", "m4a", "aac", "opus", "ogg", "dsf", "dff"]
                        if supportedExtensions.contains(pathExtension) {
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
        guard ext == "flac" || ext == "mp3" || ext == "wav" else { return }
        
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
    
    func generateStableId(for url: URL) throws -> String {
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
        let cleanedArtistName = cleanArtistName(metadata.artist ?? Localized.unknownArtist)
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
        
        return cleaned.isEmpty ? Localized.unknownArtist : cleaned
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

            // Group files by folder for playlist creation
            var folderGroups: [String: [URL]] = [:]
            var processedFiles: [URL] = []

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

                    // Group by folder path for playlist creation
                    if let folderPathData = fileInfo["folderPath"],
                       let folderPath = String(data: folderPathData, encoding: .utf8) {
                        if folderGroups[folderPath] == nil {
                            folderGroups[folderPath] = []
                        }
                        folderGroups[folderPath]?.append(url)
                    }

                    processedFiles.append(url)

                } catch {
                    print("❌ Failed to resolve bookmark for \(filename): \(error)")
                }
            }

            // Create folder playlists for shared files
            await processSharedFolderPlaylists(folderGroups: folderGroups)

            // Clear the shared files list after processing and storing bookmarks permanently
            try FileManager.default.removeItem(at: sharedDataURL)
            print("🗑️ Cleared shared audio files list (bookmarks moved to permanent storage)")

        } catch {
            print("❌ Failed to process shared audio files: \(error)")
        }
    }

    private func processSharedFolderPlaylists(folderGroups: [String: [URL]]) async {
        guard !folderGroups.isEmpty else { return }

        print("📁 Processing \(folderGroups.count) shared folder playlists...")

        for (folderPath, musicFiles) in folderGroups {
            let folderURL = URL(fileURLWithPath: folderPath)
            let folderName = folderURL.lastPathComponent

            print("📂 Processing shared folder playlist for: \(folderName)")

            do {
                // Generate stable IDs for all music files in this folder
                var trackStableIds: [String] = []

                for musicFile in musicFiles {
                    let stableId = try generateStableId(for: musicFile)
                    trackStableIds.append(stableId)
                }

                print("🎵 Found \(trackStableIds.count) tracks in shared folder: \(folderName)")

                // Check if a folder playlist already exists for this path
                if let existingPlaylist = try databaseManager.getFolderPlaylist(forPath: folderPath) {
                    print("🔄 Syncing existing shared folder playlist: \(existingPlaylist.title)")

                    // Sync the existing playlist with current folder contents
                    try databaseManager.syncPlaylistWithFolder(playlistId: existingPlaylist.id!, trackStableIds: trackStableIds)
                    print("✅ Synced shared playlist '\(existingPlaylist.title)' with folder contents")
                } else {
                    // Create new folder playlist for shared folder
                    print("➕ Creating new shared folder playlist: \(folderName)")

                    let playlist = try databaseManager.createFolderPlaylist(title: folderName, folderPath: folderPath)
                    try databaseManager.syncPlaylistWithFolder(playlistId: playlist.id!, trackStableIds: trackStableIds)
                    print("✅ Created shared folder playlist '\(playlist.title)' with \(trackStableIds.count) tracks")
                }

            } catch {
                print("❌ Failed to process shared folder playlist for \(folderName): \(error)")
            }
        }

        print("✅ Shared folder playlist processing completed")
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

            // Generate stableId for this file
            let stableId = try generateStableId(for: url)

            // Store bookmark data using stableId as key (survives file moves)
            bookmarks[stableId] = bookmarkData

            // Save updated bookmarks
            let plistData = try PropertyListSerialization.data(fromPropertyList: bookmarks, format: .xml, options: 0)
            try plistData.write(to: bookmarksURL)

            print("💾 Stored permanent bookmark for shared file: \(url.lastPathComponent) with stableId: \(stableId)")
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

            for (stableId, bookmarkData) in bookmarks {
                do {
                    // Resolve bookmark to get current file location
                    var isStale = false
                    let resolvedURL = try URL(resolvingBookmarkData: bookmarkData, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale)

                    if isStale {
                        print("⚠️ Bookmark is stale for stableId: \(stableId)")
                        continue
                    }

                    // Check if this file is in the database
                    if let existingTrack = try databaseManager.getTrack(byStableId: stableId) {
                        // File exists in DB - check if path has changed
                        if existingTrack.path != resolvedURL.path {
                            print("📍 File moved detected! Old: \(existingTrack.path)")
                            print("📍 File moved detected! New: \(resolvedURL.path)")

                            // Update the track's path in the database
                            try databaseManager.write { db in
                                var updatedTrack = existingTrack
                                updatedTrack.path = resolvedURL.path
                                try updatedTrack.update(db)
                            }
                            print("✅ Updated database path for: \(resolvedURL.lastPathComponent)")
                        } else {
                            print("⏭️ External file path unchanged: \(resolvedURL.lastPathComponent)")
                        }
                        continue
                    }

                    // File not in database yet - process it
                    // Start accessing security-scoped resource
                    guard resolvedURL.startAccessingSecurityScopedResource() else {
                        print("❌ Failed to access security-scoped resource for: \(resolvedURL.lastPathComponent)")
                        continue
                    }

                    defer {
                        resolvedURL.stopAccessingSecurityScopedResource()
                    }

                    // Process the file
                    await processExternalFile(resolvedURL)
                    print("✅ Processed stored external file: \(resolvedURL.lastPathComponent)")

                } catch {
                    print("❌ Failed to resolve bookmark for stableId \(stableId): \(error)")
                }
            }

        } catch {
            print("❌ Failed to process stored external bookmarks: \(error)")
        }
    }

    /// Resolve bookmark for a specific track and update database path if file moved
    func resolveBookmarkForTrack(_ track: Track) async -> URL? {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let bookmarksURL = documentsURL.appendingPathComponent("ExternalFileBookmarks.plist")

        guard FileManager.default.fileExists(atPath: bookmarksURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: bookmarksURL)
            guard let bookmarks = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Data],
                  let bookmarkData = bookmarks[track.stableId] else {
                return nil // No bookmark for this track
            }

            // Resolve bookmark to get current file location
            var isStale = false
            let resolvedURL = try URL(resolvingBookmarkData: bookmarkData, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale)

            if isStale {
                print("⚠️ Bookmark is stale for: \(track.title)")
                return nil
            }

            // Update database path if file moved
            if track.path != resolvedURL.path {
                print("📍 Playback: File moved detected! Old: \(track.path)")
                print("📍 Playback: File moved detected! New: \(resolvedURL.path)")

                try databaseManager.write { db in
                    var updatedTrack = track
                    updatedTrack.path = resolvedURL.path
                    try updatedTrack.update(db)
                }
                print("✅ Updated database path for playback: \(resolvedURL.lastPathComponent)")
            }

            return resolvedURL

        } catch {
            print("❌ Failed to resolve bookmark for track \(track.title): \(error)")
            return nil
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

        switch ext {
        // Native formats
        case "flac", "mp3", "wav", "aac":
            return try await parseNativeFormat(url)

        case "m4a":
            // Detect if AAC or Opus
            if isOpusInM4A(url) {
                return try await parseBasicMetadata(url, format: "Opus") // Opus → Basic parsing
            } else {
                return try await parseAacMetadata(url)  // AAC → Native
            }

        // SFBAudioEngine formats (but use basic parsing for metadata to avoid hangs)
        case "opus", "ogg":
            return try await parseBasicMetadata(url, format: "Opus/Vorbis")

        case "dsf", "dff":
            return try await parseDSDBasicMetadata(url)

        default:
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

    private static func parseWavMetadataSync(from url: URL) async throws -> AudioMetadata {
        print("📖 Reading WAV metadata for: \(url.lastPathComponent)")

        // For WAV files, use AVAudioFile to get format info and try AVAsset for metadata
        var sampleRate: Int?
        var channels: Int?
        var bitDepth: Int?
        var durationMs: Int?
        var title: String?
        var artist: String?
        var album: String?
        var albumArtist: String?
        var trackNumber: Int?
        var discNumber: Int?
        var year: Int?
        var hasEmbeddedArt = false

        // Get audio format info
        do {
            let audioFile = try AVAudioFile(forReading: url)
            let format = audioFile.processingFormat

            sampleRate = Int(format.sampleRate)
            channels = Int(format.channelCount)

            // Calculate duration
            let totalFrames = audioFile.length
            durationMs = Int((Double(totalFrames) / format.sampleRate) * 1000)

            // Try to get bit depth from format settings
            if let settings = audioFile.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int {
                bitDepth = settings
            }
        } catch {
            print("⚠️ Failed to read WAV audio format: \(error)")
        }

        // Try to get metadata from AVAsset (some WAV files may have ID3 tags or other metadata)
        do {
            let asset = AVURLAsset(url: url)
            let commonMetadata = try await asset.load(.commonMetadata)

            for item in commonMetadata {
                switch item.commonKey {
                case .commonKeyTitle:
                    title = try? await item.load(.stringValue)
                case .commonKeyArtist:
                    artist = try? await item.load(.stringValue)
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
        } catch {
            print("⚠️ Failed to read WAV metadata: \(error)")
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

        // Default values for WAV
        sampleRate = sampleRate ?? 44100
        channels = channels ?? 2
        bitDepth = bitDepth ?? 16

        print("🎵 Final WAV metadata for \(url.lastPathComponent):")
        print("   Title: \(title ?? "nil")")
        print("   Artist: \(artist ?? "nil")")
        print("   Sample Rate: \(sampleRate ?? 0) Hz")
        print("   Channels: \(channels ?? 0)")
        print("   Bit Depth: \(bitDepth ?? 0)")

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
            replaygainTrackGain: nil,
            replaygainAlbumGain: nil,
            replaygainTrackPeak: nil,
            replaygainAlbumPeak: nil,
            hasEmbeddedArt: hasEmbeddedArt
        )
    }

    // MARK: - New Format Support Methods

    // Unified parser for native formats (routes to existing parsers)
    private static func parseNativeFormat(_ url: URL) async throws -> AudioMetadata {
        let ext = url.pathExtension.lowercased()

        switch ext {
        case "flac":
            return try await parseFlacMetadataSync(from: url)
        case "mp3":
            return try await parseMp3MetadataSync(from: url)
        case "wav":
            return try await parseWavMetadataSync(from: url)
        case "aac":
            return try await parseAacMetadata(url)
        default:
            throw AudioParseError.unsupportedFormat
        }
    }

    // Check if M4A contains Opus codec
    private static func isOpusInM4A(_ url: URL) -> Bool {
        // Check MP4 atoms for Opus codec
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return false
        }

        // Look for 'Opus' atom in MP4 structure
        // MP4 structure: ftyp → moov → trak → mdia → minf → stbl → stsd → Opus
        let opusSignature = "Opus".data(using: .ascii)!
        return data.range(of: opusSignature, in: 0..<min(data.count, 10000)) != nil
    }

    // Parse AAC metadata using native AVFoundation
    private static func parseAacMetadata(_ url: URL) async throws -> AudioMetadata {
        print("📖 Reading AAC metadata for: \(url.lastPathComponent)")

        // Use similar logic to MP3 parsing since AAC can have similar metadata
        return try await parseMp3MetadataSync(from: url)
    }

    // Parse using SFBAudioEngine for Opus, Vorbis, etc.
    private static func parseSFBAudioFile(_ url: URL) async throws -> AudioMetadata {
        print("📖 Reading SFBAudioEngine metadata for: \(url.lastPathComponent)")

        do {
            // Create SFBAudioFile for metadata extraction
            let audioFile = try SFBAudioEngine.AudioFile(readingPropertiesAndMetadataFrom: url)

            // Extract basic properties
            let properties = audioFile.properties
            let metadata = audioFile.metadata

            let durationSeconds = properties.duration ?? 0
            let sampleRate = Int(properties.sampleRate ?? 0)
            let channels = Int(properties.channelCount ?? 0)
            let bitDepth = 0  // BitDepth not directly available from AudioProperties

            // Extract metadata
            let title = metadata.title
            let artist = metadata.artist
            let album = metadata.albumTitle
            let albumArtist = metadata.albumArtist
            let trackNumber = metadata.trackNumber
            let discNumber = metadata.discNumber
            let year = metadata.releaseDate?.components(separatedBy: "-").first.flatMap { Int($0) }

            print("🎵 SFBAudioEngine metadata for \(url.lastPathComponent):")
            print("   Title: \(title ?? "nil")")
            print("   Artist: \(artist ?? "nil")")
            print("   Sample Rate: \(sampleRate) Hz")
            print("   Channels: \(channels)")
            print("   Duration: \(durationSeconds) seconds")

            return AudioMetadata(
                title: title,
                artist: artist,
                album: album,
                albumArtist: albumArtist,
                trackNumber: trackNumber,
                discNumber: discNumber,
                year: year,
                durationMs: Int(durationSeconds * 1000),
                sampleRate: sampleRate,
                bitDepth: bitDepth > 0 ? bitDepth : nil,
                channels: channels,
                replaygainTrackGain: metadata.replayGainTrackGain,
                replaygainAlbumGain: metadata.replayGainAlbumGain,
                replaygainTrackPeak: metadata.replayGainTrackPeak,
                replaygainAlbumPeak: metadata.replayGainAlbumPeak,
                hasEmbeddedArt: await checkForEmbeddedArtwork(url: url)  // Check for embedded artwork in SFBAudioEngine files
            )

        } catch {
            print("❌ SFBAudioEngine parsing failed: \(error)")
            throw AudioParseError.invalidFile
        }
    }

    // Simple artwork detection for supported formats
    private static func checkForEmbeddedArtwork(url: URL) async -> Bool {
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let ext = url.pathExtension.lowercased()

            // Common image format signatures
            let jpegSignature = Data([0xFF, 0xD8, 0xFF])
            let pngSignature = Data([0x89, 0x50, 0x4E, 0x47])

            if ext == "opus" || ext == "ogg" {
                // Search in first 64KB of file for image data
                let searchRange = 0..<min(data.count, 65536)
                return data.range(of: jpegSignature, in: searchRange) != nil ||
                       data.range(of: pngSignature, in: searchRange) != nil
            } else if ext == "dsf" {
                // DSF files: artwork is typically stored after the format chunk
                // DSF signature: "DSD " (44 53 44 20)
                let dsfSignature = Data([0x44, 0x53, 0x44, 0x20])
                if data.starts(with: dsfSignature) {
                    // Search for image signatures in the file (DSF can contain embedded artwork)
                    let searchRange = 0..<min(data.count, 1048576) // Search first 1MB
                    return data.range(of: jpegSignature, in: searchRange) != nil ||
                           data.range(of: pngSignature, in: searchRange) != nil
                }
            } else if ext == "dff" {
                // DSDIFF files: look for ID3v2 tags or artwork chunks
                // DSDIFF signature: "FRM8" + "DSD "
                if data.count >= 12 {
                    let frm8Signature = Data([0x46, 0x52, 0x4D, 0x38]) // "FRM8"
                    let dsdSignature = Data([0x44, 0x53, 0x44, 0x20])   // "DSD "

                    if data.starts(with: frm8Signature) &&
                       data.subdata(in: 8..<12) == dsdSignature {
                        // Search for image signatures in DSDIFF file
                        let searchRange = 0..<min(data.count, 1048576) // Search first 1MB
                        return data.range(of: jpegSignature, in: searchRange) != nil ||
                               data.range(of: pngSignature, in: searchRange) != nil
                    }
                }
            }

            return false
        } catch {
            print("⚠️ Artwork detection failed for \(url.lastPathComponent): \(error)")
            return false
        }
    }

    // Parse basic metadata from filename (for SFBAudioEngine formats to avoid hangs)
    private static func parseBasicMetadata(_ url: URL, format: String) async throws -> AudioMetadata {
        print("📖 Reading basic metadata for \(format): \(url.lastPathComponent)")

        // Use filename parsing for all SFBAudioEngine formats
        let filename = url.deletingPathExtension().lastPathComponent
        var title = filename
        var artist: String? = nil

        // Try to parse "Artist - Title" format
        let components = filename.components(separatedBy: " - ")
        if components.count >= 2 {
            artist = components[0].trimmingCharacters(in: .whitespaces)
            title = components.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
        }

        // Basic properties - don't assume sample rate as it's crucial for timing
        let ext = url.pathExtension.lowercased()
        let sampleRate = 0      // Unknown - will be determined by audio engine during playback
        let channels = 0        // Unknown - will be determined during playback
        var bitDepth: Int? = nil

        switch ext {
        case "opus", "ogg", "m4a":
            bitDepth = nil      // Lossy format
        default:
            break
        }

        // Check for embedded artwork in supported formats
        var hasEmbeddedArt = false
        if ext == "opus" || ext == "ogg" {
            // These formats can have embedded artwork, check with basic methods
            hasEmbeddedArt = await checkForEmbeddedArtwork(url: url)
        }

        print("🎵 Basic metadata for \(url.lastPathComponent):")
        print("   Title: \(title)")
        print("   Artist: \(artist ?? "Unknown")")
        print("   Format: \(format)")
        print("   Sample Rate: Unknown (will be detected during playback)")
        print("   Has Artwork: \(hasEmbeddedArt)")

        return AudioMetadata(
            title: title,
            artist: artist,
            album: nil,
            albumArtist: artist,
            trackNumber: nil,
            discNumber: nil,
            year: nil,
            durationMs: 0,  // Duration will be calculated during playback
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            channels: channels,
            replaygainTrackGain: nil,
            replaygainAlbumGain: nil,
            replaygainTrackPeak: nil,
            replaygainAlbumPeak: nil,
            hasEmbeddedArt: hasEmbeddedArt
        )
    }

    // Parse DSD metadata with proper ID3v2 tag extraction from DSF files
    private static func parseDSDBasicMetadata(_ url: URL) async throws -> AudioMetadata {
        print("📖 Reading DSD metadata with ID3v2 extraction for: \(url.lastPathComponent)")

        var title: String?
        var artist: String?
        var album: String?
        var albumArtist: String?
        var trackNumber: Int?
        var discNumber: Int?
        var year: Int?
        var hasEmbeddedArt = false
        var sampleRate = 0
        var channels = 0
        let bitDepth = 1  // DSD is always 1-bit

        // Try to extract metadata from DSF file
        if url.pathExtension.lowercased() == "dsf" {
            do {
                let metadata = try await extractDSFMetadata(from: url)
                title = metadata.title
                artist = metadata.artist
                album = metadata.album
                albumArtist = metadata.albumArtist
                trackNumber = metadata.trackNumber
                discNumber = metadata.discNumber
                year = metadata.year
                hasEmbeddedArt = metadata.hasEmbeddedArt
                sampleRate = metadata.sampleRate
                channels = metadata.channels
                print("✅ Successfully extracted DSF metadata for: \(url.lastPathComponent)")
            } catch {
                print("⚠️ Failed to extract DSF metadata, falling back to filename parsing: \(error)")
            }
        }

        // Fallback to filename parsing if metadata extraction failed
        if title == nil {
            let filename = url.deletingPathExtension().lastPathComponent
            title = filename

            // Try to parse "Artist - Title" format
            let components = filename.components(separatedBy: " - ")
            if components.count >= 2 {
                artist = components[0].trimmingCharacters(in: .whitespaces)
                title = components.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
            }
        }

        // Check for embedded artwork if not already determined
        if !hasEmbeddedArt {
            hasEmbeddedArt = await checkForEmbeddedArtwork(url: url)
        }

        print("🎵 DSD metadata for \(url.lastPathComponent):")
        print("   Title: \(title ?? "Unknown")")
        print("   Artist: \(artist ?? "Unknown")")
        print("   Album: \(album ?? "Unknown")")
        print("   Track: \(trackNumber?.description ?? "Unknown")")
        print("   Sample Rate: \(sampleRate > 0 ? "\(sampleRate) Hz" : "Unknown")")
        print("   Channels: \(channels > 0 ? "\(channels)" : "Unknown")")
        print("   Has Artwork: \(hasEmbeddedArt)")

        return AudioMetadata(
            title: title,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            trackNumber: trackNumber,
            discNumber: discNumber,
            year: year,
            durationMs: 0,  // Duration will be calculated during playback
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            channels: channels,
            replaygainTrackGain: nil,
            replaygainAlbumGain: nil,
            replaygainTrackPeak: nil,
            replaygainAlbumPeak: nil,
            hasEmbeddedArt: hasEmbeddedArt
        )
    }

    // Extract metadata from DSF file using DSF format specification and ID3v2 tags
    private static func extractDSFMetadata(from url: URL) async throws -> (title: String?, artist: String?, album: String?, albumArtist: String?, trackNumber: Int?, discNumber: Int?, year: Int?, hasEmbeddedArt: Bool, sampleRate: Int, channels: Int) {

        // Add memory safety check - avoid large file loading during startup if low memory
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if fileSize > 50_000_000 { // Skip files larger than 50MB to prevent memory pressure
            print("⚠️ Skipping large DSF file during startup: \(url.lastPathComponent) (\(fileSize) bytes)")
            return (nil, nil, nil, nil, nil, nil, nil, false, 0, 0)
        }

        let data = try Data(contentsOf: url)

        // Validate DSF signature: 'D', 'S', 'D', ' ' (includes 1 space)
        guard data.count >= 28,
              data[0] == 0x44, data[1] == 0x53, data[2] == 0x44, data[3] == 0x20 else {
            throw AudioParseError.unsupportedFormat
        }

        // Read DSF header (little-endian) with safe byte-by-byte reading
        let chunkSize = readLittleEndianUInt64(from: data, offset: 4)
        let totalFileSize = readLittleEndianUInt64(from: data, offset: 12)
        let metadataPointer = readLittleEndianUInt64(from: data, offset: 20)

        print("📊 DSF Header Analysis for \(url.lastPathComponent):")
        print("   Chunk Size: \(chunkSize)")
        print("   Total File Size: \(totalFileSize)")
        print("   Metadata Pointer: \(metadataPointer)")

        // Parse format chunk to get sample rate and channels
        var sampleRate = 0
        var channels = 0

        // Look for fmt chunk after DSD chunk (at offset 28)
        if data.count >= 52 &&
           data[28] == 0x66 && data[29] == 0x6D && data[30] == 0x74 && data[31] == 0x20 { // "fmt "

            let fmtChunkSize = readLittleEndianUInt64(from: data, offset: 32)

            if fmtChunkSize >= 52 {
                let formatVersion = readLittleEndianUInt32(from: data, offset: 40)
                let formatId = readLittleEndianUInt32(from: data, offset: 44)
                let channelType = readLittleEndianUInt32(from: data, offset: 48)
                let channelNum = readLittleEndianUInt32(from: data, offset: 52)
                let sampleFrequency = readLittleEndianUInt32(from: data, offset: 56)

                sampleRate = Int(sampleFrequency)
                channels = Int(channelNum)

                print("   Format Version: \(formatVersion)")
                print("   Format ID: \(formatId)")
                print("   Channel Type: \(channelType)")
                print("   Channels: \(channels)")
                print("   Sample Rate: \(sampleRate) Hz")
            }
        }

        // Parse ID3v2 metadata if metadata pointer is valid
        var title: String?
        var artist: String?
        var album: String?
        var albumArtist: String?
        var trackNumber: Int?
        var discNumber: Int?
        var year: Int?
        var hasEmbeddedArt = false

        if metadataPointer > 0 && metadataPointer < data.count {
            let metadataOffset = Int(metadataPointer)

            // Check for ID3v2 signature at metadata pointer
            if data.count >= metadataOffset + 10 &&
               data[metadataOffset] == 0x49 && data[metadataOffset + 1] == 0x44 && data[metadataOffset + 2] == 0x33 { // "ID3"

                print("🏷️ Found ID3v2 tag at offset \(metadataOffset)")

                let id3Data = data.subdata(in: metadataOffset..<data.count)
                let parsedTags = parseID3v2Tags(from: id3Data)

                title = parsedTags.title
                artist = parsedTags.artist
                album = parsedTags.album
                albumArtist = parsedTags.albumArtist
                trackNumber = parsedTags.trackNumber
                discNumber = parsedTags.discNumber
                year = parsedTags.year
                hasEmbeddedArt = parsedTags.hasArtwork
            }
        }

        return (
            title: title,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            trackNumber: trackNumber,
            discNumber: discNumber,
            year: year,
            hasEmbeddedArt: hasEmbeddedArt,
            sampleRate: sampleRate,
            channels: channels
        )
    }

    // Parse ID3v2 tags from binary data
    private static func parseID3v2Tags(from data: Data) -> (title: String?, artist: String?, album: String?, albumArtist: String?, trackNumber: Int?, discNumber: Int?, year: Int?, hasArtwork: Bool) {

        guard data.count >= 10 else { return (nil, nil, nil, nil, nil, nil, nil, false) }

        // Read ID3v2 header
        let majorVersion = data[3]
        let revision = data[4]
        let flags = data[5]

        // Read size (synchsafe integer)
        let tagSize = Int((UInt32(data[6]) << 21) | (UInt32(data[7]) << 14) | (UInt32(data[8]) << 7) | UInt32(data[9]))

        print("🏷️ ID3v2.\(majorVersion).\(revision) tag, size: \(tagSize) bytes, flags: 0x\(String(flags, radix: 16))")

        var title: String?
        var artist: String?
        var album: String?
        var albumArtist: String?
        var trackNumber: Int?
        var discNumber: Int?
        var year: Int?
        var hasArtwork = false

        // Parse frames (starting from offset 10)
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

            _ = (UInt16(data[offset+8]) << 8) | UInt16(data[offset+9])

            // Move to frame data
            offset += 10

            guard frameSize > 0 && offset + frameSize <= endOffset else {
                break
            }

            let frameData = data.subdata(in: offset..<offset+frameSize)

            // Parse frame based on ID
            switch frameId {
            case "TIT2": // Title
                title = parseTextFrame(frameData)
            case "TPE1": // Artist
                artist = parseTextFrame(frameData)
            case "TALB": // Album
                album = parseTextFrame(frameData)
            case "TPE2": // Album Artist
                albumArtist = parseTextFrame(frameData)
            case "TRCK": // Track number
                if let trackString = parseTextFrame(frameData) {
                    trackNumber = Int(trackString.components(separatedBy: "/").first ?? "")
                }
            case "TPOS": // Disc number
                if let discString = parseTextFrame(frameData) {
                    discNumber = Int(discString.components(separatedBy: "/").first ?? "")
                }
            case "TYER", "TDRC": // Year (TYER in v2.3, TDRC in v2.4)
                if let yearString = parseTextFrame(frameData) {
                    year = Int(String(yearString.prefix(4)))
                }
            case "APIC": // Attached picture
                hasArtwork = true
                print("🎨 Found embedded artwork in ID3v2 tag")
            default:
                break
            }

            offset += frameSize
        }

        print("🎵 Parsed ID3v2 metadata:")
        print("   Title: \(title ?? "nil")")
        print("   Artist: \(artist ?? "nil")")
        print("   Album: \(album ?? "nil")")
        print("   Album Artist: \(albumArtist ?? "nil")")
        print("   Track: \(trackNumber?.description ?? "nil")")
        print("   Year: \(year?.description ?? "nil")")
        print("   Has Artwork: \(hasArtwork)")

        return (title, artist, album, albumArtist, trackNumber, discNumber, year, hasArtwork)
    }

    // Parse text frame data handling different encodings
    private static func parseTextFrame(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }

        let encoding = data[0]
        let textData = data.subdata(in: 1..<data.count)

        switch encoding {
        case 0: // ISO-8859-1
            return String(data: textData, encoding: .isoLatin1)?.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
        case 1: // UTF-16 with BOM
            return String(data: textData, encoding: .utf16)?.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
        case 2: // UTF-16BE without BOM
            return String(data: textData, encoding: .utf16BigEndian)?.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
        case 3: // UTF-8
            return String(data: textData, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
        default:
            // Fallback to UTF-8
            return String(data: textData, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
        }
    }

    // Safe byte reading helpers for DSF format (little-endian)
    private static func readLittleEndianUInt64(from data: Data, offset: Int) -> UInt64 {
        guard offset >= 0 && offset + 8 <= data.count else {
            print("⚠️ Invalid byte access: offset=\(offset), dataSize=\(data.count)")
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

    private static func readLittleEndianUInt32(from data: Data, offset: Int) -> UInt32 {
        guard offset >= 0 && offset + 4 <= data.count else {
            print("⚠️ Invalid byte access: offset=\(offset), dataSize=\(data.count)")
            return 0
        }

        let byte0 = UInt32(data[offset])
        let byte1 = UInt32(data[offset + 1]) << 8
        let byte2 = UInt32(data[offset + 2]) << 16
        let byte3 = UInt32(data[offset + 3]) << 24

        return byte0 | byte1 | byte2 | byte3
    }

    // Parse DSD metadata with SFBAudioEngine (DEPRECATED - causes hangs)
    private static func parseDSDMetadata(_ url: URL) async throws -> AudioMetadata {
        print("📖 Reading DSD metadata for: \(url.lastPathComponent)")

        do {
            // Create DSD decoder
            let decoder = try SFBAudioEngine.AudioDecoder(url: url)

            // Extract properties
            let sourceFormat = decoder.sourceFormat
            _ = decoder.processingFormat

            let sampleRate = Int(sourceFormat.sampleRate)
            let channels = Int(sourceFormat.channelCount)
            // Duration calculation for DSD - using properties if available
            let durationSeconds = 0.0  // Duration not directly available from AudioDecoder

            // DSD is 1-bit, but we report the effective resolution
            let bitDepth = 1

            print("🎵 DSD metadata for \(url.lastPathComponent):")
            print("   Sample Rate: \(sampleRate) Hz (DSD)")
            print("   Channels: \(channels)")
            print("   Duration: \(durationSeconds) seconds")
            print("   Format: DSD (1-bit)")

            // For DSD files, metadata is limited, so use filename parsing
            let filename = url.deletingPathExtension().lastPathComponent
            let title = filename

            return AudioMetadata(
                title: title,
                artist: nil,
                album: nil,
                albumArtist: nil,
                trackNumber: nil,
                discNumber: nil,
                year: nil,
                durationMs: Int(durationSeconds * 1000),
                sampleRate: sampleRate,
                bitDepth: bitDepth,
                channels: channels,
                replaygainTrackGain: nil,
                replaygainAlbumGain: nil,
                replaygainTrackPeak: nil,
                replaygainAlbumPeak: nil,
                hasEmbeddedArt: false
            )

        } catch {
            print("❌ DSD parsing failed: \(error)")
            throw AudioParseError.invalidFile
        }
    }
}

enum AudioParseError: Error {
    case invalidFile
    case unsupportedFormat
    case fileNotReadable
    case fileSizeError
}
