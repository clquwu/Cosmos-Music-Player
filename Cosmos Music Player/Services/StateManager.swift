//
//  StateManager.swift
//  Cosmos Music Player
//
//  Manages JSON state files for favorites and playlists in iCloud Drive
//

import Foundation

class StateManager: @unchecked Sendable {
    static let shared = StateManager()
    
    private var iCloudContainerURL: URL?
    private let customFolderLock = NSLock()
    /// Holds the URL while security-scoped access is active for the custom library folder.
    private var customFolderScopedURL: URL?

    private init() {
        // Only set if iCloud is available
        if FileManager.default.ubiquityIdentityToken != nil {
            iCloudContainerURL = FileManager.default.url(forUbiquityContainerIdentifier: nil)
        }
    }

    /// Call after changing custom folder settings so the next resolve re-applies security scope.
    func invalidateCustomFolderAccess() {
        customFolderLock.lock()
        defer { customFolderLock.unlock() }
        customFolderScopedURL?.stopAccessingSecurityScopedResource()
        customFolderScopedURL = nil
    }

    private func defaultICloudAppFolderURL() -> URL? {
        guard let containerURL = iCloudContainerURL else { return nil }
        return containerURL.appendingPathComponent("Documents", isDirectory: true)
    }

    /// Resolves the user’s custom folder bookmark when enabled; starts security-scoped access for this process.
    private func resolvedCustomFolderURLIfEnabled() -> URL? {
        let settings = DeleteSettings.load()
        guard settings.useCustomAppFolder, let data = settings.customAppFolderBookmarkData else {
            customFolderLock.lock()
            let hadAccess = customFolderScopedURL != nil
            customFolderLock.unlock()
            if hadAccess { invalidateCustomFolderAccess() }
            return nil
        }
        guard let pair = SecurityScopedFolderBookmark.resolveURL(from: data) else {
            return nil
        }
        if pair.isStale {
            print("⚠️ StateManager: custom app folder bookmark is stale — re-select the folder in Settings")
            return nil
        }
        let url = pair.url
        customFolderLock.lock()
        defer { customFolderLock.unlock() }
        if customFolderScopedURL == url {
            return url
        }
        customFolderScopedURL?.stopAccessingSecurityScopedResource()
        guard url.startAccessingSecurityScopedResource() else {
            print("⚠️ StateManager: could not start security-scoped access for custom folder")
            customFolderScopedURL = nil
            return nil
        }
        customFolderScopedURL = url
        return url
    }

    /// Active data folder: custom security-scoped folder when configured and valid, otherwise iCloud `Documents` under the ubiquity container.
    private func resolvedAppFolderURL() -> URL? {
        if let custom = resolvedCustomFolderURLIfEnabled() {
            return custom
        }
        return defaultICloudAppFolderURL()
    }

    func createAppFolderIfNeeded() throws {
        guard let appFolderURL = resolvedAppFolderURL() else {
            throw StateManagerError.iCloudNotAvailable
        }
        if !FileManager.default.fileExists(atPath: appFolderURL.path) {
            try FileManager.default.createDirectory(at: appFolderURL,
                                                 withIntermediateDirectories: true,
                                                 attributes: nil)
        }
    }
    
    // MARK: - Favorites
    
    func saveFavorites(_ favorites: [String]) throws {
        print("💾 StateManager: Saving \(favorites.count) favorites - \(favorites)")
        let favoritesState = FavoritesState(favorites: favorites)
        
        // Always save to local Documents first (survives app reinstall)
        try saveToLocalDocuments(favoritesState)
        
        // Also try to save to iCloud Drive if available
        do {
            try createAppFolderIfNeeded()
            guard let appFolderURL = resolvedAppFolderURL() else {
                print("⚠️ iCloud not available, favorites saved locally only")
                return
            }
            
            let favoritesURL = appFolderURL.appendingPathComponent("favorites.json")
            try saveJSONAtomically(favoritesState, to: favoritesURL)
            print("✅ Favorites saved to both local and iCloud")
        } catch {
            print("⚠️ Failed to save to iCloud, but local save succeeded: \(error)")
        }
    }
    
    private func saveToLocalDocuments(_ favoritesState: FavoritesState) throws {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let localFavoritesURL = documentsURL.appendingPathComponent("cosmos-favorites.json")
        try saveJSONAtomically(favoritesState, to: localFavoritesURL)
        print("📱 Favorites saved locally to: \(localFavoritesURL.path)")
    }
    
    func loadFavorites() throws -> [String] {
        print("📂 StateManager: Loading favorites...")
        
        // Try loading from local Documents first (survives app reinstall)
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let localFavoritesURL = documentsURL.appendingPathComponent("cosmos-favorites.json")
        
        print("📂 StateManager: Checking local file at: \(localFavoritesURL.path)")
        
        if FileManager.default.fileExists(atPath: localFavoritesURL.path) {
            do {
                let data = try Data(contentsOf: localFavoritesURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let favoritesState = try decoder.decode(FavoritesState.self, from: data)
                print("📱 Loaded favorites from local storage: \(favoritesState.favorites.count) items - \(favoritesState.favorites)")
                
                // If local file exists but has no favorites, still try iCloud as fallback
                // (this handles the case where a new app installation created an empty local file)
                if favoritesState.favorites.isEmpty {
                    print("📂 Local file has 0 favorites, checking iCloud for any existing favorites...")
                    // Don't return here - continue to iCloud fallback
                } else {
                    return favoritesState.favorites
                }
            } catch {
                print("⚠️ Failed to load local favorites: \(error)")
            }
        } else {
            print("📂 StateManager: Local file does not exist")
        }
        
        // Fallback to iCloud Drive if local doesn't exist
        guard let appFolderURL = resolvedAppFolderURL() else {
            print("📭 No favorites found (neither local nor iCloud)")
            return []
        }
        
        let favoritesURL = appFolderURL.appendingPathComponent("favorites.json")
        print("📂 StateManager: Checking iCloud file at: \(favoritesURL.path)")
        
        guard FileManager.default.fileExists(atPath: favoritesURL.path) else {
            print("📭 No iCloud favorites file found")
            return []
        }
        
        do {
            // Check if this is an iCloud file and ensure it's downloaded
            let resourceValues = try favoritesURL.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
            
            if let isUbiquitous = resourceValues.isUbiquitousItem, isUbiquitous {
                print("☁️ iCloud favorites file detected, checking download status...")
                
                if let downloadingStatus = resourceValues.ubiquitousItemDownloadingStatus {
                    print("📊 iCloud favorites download status: \(downloadingStatus)")
                    
                    if downloadingStatus == .notDownloaded {
                        print("🔽 iCloud favorites file needs downloading, starting download...")
                        try FileManager.default.startDownloadingUbiquitousItem(at: favoritesURL)
                        
                        // Wait a moment for download to start
                        Thread.sleep(forTimeInterval: 0.5)
                    }
                }
            }
            
            // Use NSFileCoordinator for proper iCloud file access
            var coordinatorError: NSError?
            var data: Data?
            
            let coordinator = NSFileCoordinator()
            coordinator.coordinate(readingItemAt: favoritesURL, options: .withoutChanges, error: &coordinatorError) { (url) in
                do {
                    data = try Data(contentsOf: url)
                    print("☁️ Successfully read favorites from iCloud via NSFileCoordinator")
                } catch {
                    print("❌ Failed to read iCloud favorites via coordinator: \(error)")
                }
            }
            
            if let coordinatorError = coordinatorError {
                print("❌ NSFileCoordinator error: \(coordinatorError)")
                return []
            }
            
            guard let favoritesData = data else {
                print("❌ No data read from iCloud favorites file")
                return []
            }
            
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let favoritesState = try decoder.decode(FavoritesState.self, from: favoritesData)
            print("☁️ Loaded favorites from iCloud: \(favoritesState.favorites.count) items - \(favoritesState.favorites)")
            return favoritesState.favorites
        } catch {
            print("❌ Failed to load favorites from iCloud: \(error)")
            return []
        }
    }
    
    // MARK: - Playlists
    
    func savePlaylist(_ playlist: PlaylistState) throws {
        // Always save to local Documents first (survives app reinstall)
        try savePlaylistToLocalDocuments(playlist)
        
        // Also try to save to iCloud Drive if available
        do {
            try createAppFolderIfNeeded()
            guard let appFolderURL = resolvedAppFolderURL() else {
                print("⚠️ iCloud not available, playlist saved locally only")
                return
            }
            
            let playlistsFolder = appFolderURL.appendingPathComponent("playlists", isDirectory: true)
            if !FileManager.default.fileExists(atPath: playlistsFolder.path) {
                try FileManager.default.createDirectory(at: playlistsFolder, 
                                                     withIntermediateDirectories: true, 
                                                     attributes: nil)
            }
            
            let playlistURL = playlistsFolder.appendingPathComponent("playlist-\(playlist.slug).json")
            try saveJSONAtomically(playlist, to: playlistURL)
            print("✅ Playlist saved to both local and iCloud")
        } catch {
            print("⚠️ Failed to save playlist to iCloud, but local save succeeded: \(error)")
        }
    }
    
    private func savePlaylistToLocalDocuments(_ playlist: PlaylistState) throws {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let localPlaylistsFolder = documentsURL.appendingPathComponent("cosmos-playlists", isDirectory: true)
        
        if !FileManager.default.fileExists(atPath: localPlaylistsFolder.path) {
            try FileManager.default.createDirectory(at: localPlaylistsFolder, 
                                                 withIntermediateDirectories: true, 
                                                 attributes: nil)
        }
        
        let localPlaylistURL = localPlaylistsFolder.appendingPathComponent("playlist-\(playlist.slug).json")
        try saveJSONAtomically(playlist, to: localPlaylistURL)
        print("📱 Playlist saved locally to: \(localPlaylistURL.path)")
    }
    
    func loadPlaylist(slug: String) throws -> PlaylistState? {
        if let localPlaylist = try? loadPlaylistFromLocalDocuments(slug: slug) {
            return localPlaylist
        }
        guard let appFolderURL = resolvedAppFolderURL() else {
            return nil
        }

        let playlistsFolder = appFolderURL.appendingPathComponent("playlists", isDirectory: true)
        let playlistURL = playlistsFolder.appendingPathComponent("playlist-\(slug).json")

        guard FileManager.default.fileExists(atPath: playlistURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: playlistURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(PlaylistState.self, from: data)
        } catch {
            print("⚠️ Failed to load playlist '\(slug)': \(error)")
            return nil
        }
    }

    private func loadPlaylistFromLocalDocuments(slug: String) throws -> PlaylistState? {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let localPlaylistsFolder = documentsURL.appendingPathComponent("cosmos-playlists", isDirectory: true)
        let localPlaylistURL = localPlaylistsFolder.appendingPathComponent("playlist-\(slug).json")

        guard FileManager.default.fileExists(atPath: localPlaylistURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: localPlaylistURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PlaylistState.self, from: data)
    }
    
    func getAllPlaylists() throws -> [PlaylistState] {
        var playlists: [PlaylistState] = []
        var seenSlugs = Set<String>()
        var corruptedFiles: [URL] = []
        var primaryPlaylistsFolder: URL?
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let appFolderURL = resolvedAppFolderURL() {
            let playlistsFolder = appFolderURL.appendingPathComponent("playlists", isDirectory: true)
            primaryPlaylistsFolder = playlistsFolder
            if FileManager.default.fileExists(atPath: playlistsFolder.path) {
                let playlistFiles = try FileManager.default.contentsOfDirectory(at: playlistsFolder,
                                                                              includingPropertiesForKeys: nil)
                for fileURL in playlistFiles where fileURL.pathExtension == "json" {
                    do {
                        let data = try Data(contentsOf: fileURL)
                        let playlist = try decoder.decode(PlaylistState.self, from: data)
                        playlists.append(playlist)
                        seenSlugs.insert(playlist.slug)
                    } catch {
                        if let nsError = error as NSError? {
                            if nsError.domain == NSPOSIXErrorDomain && nsError.code == 81 {
                                print("🔐 Authentication required for playlist file: \(fileURL.lastPathComponent)")
                                throw StateManagerError.iCloudNotAvailable
                            }
                        }
                        print("⚠️ Failed to read playlist file \(fileURL.lastPathComponent): \(error)")
                        let slug = fileURL.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "playlist-", with: "")
                        if let recoveredPlaylist = try? loadPlaylistFromLocalDocuments(slug: slug) {
                            print("✅ Recovered playlist from local backup: \(slug)")
                            playlists.append(recoveredPlaylist)
                            seenSlugs.insert(recoveredPlaylist.slug)
                            try? savePlaylist(recoveredPlaylist)
                        } else {
                            corruptedFiles.append(fileURL)
                            print("❌ Unable to recover playlist: \(fileURL.lastPathComponent)")
                        }
                    }
                }
            }
        }

        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let localPlaylistsFolder = documentsURL.appendingPathComponent("cosmos-playlists", isDirectory: true)
        if FileManager.default.fileExists(atPath: localPlaylistsFolder.path) {
            let localFiles = try FileManager.default.contentsOfDirectory(at: localPlaylistsFolder,
                                                                        includingPropertiesForKeys: nil)
            for fileURL in localFiles where fileURL.pathExtension == "json" {
                let slug = fileURL.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "playlist-", with: "")
                guard !seenSlugs.contains(slug) else { continue }
                do {
                    let data = try Data(contentsOf: fileURL)
                    let playlist = try decoder.decode(PlaylistState.self, from: data)
                    playlists.append(playlist)
                    seenSlugs.insert(playlist.slug)
                } catch {
                    print("⚠️ Failed to read local playlist file \(fileURL.lastPathComponent): \(error)")
                }
            }
        }

        if !corruptedFiles.isEmpty, let folder = primaryPlaylistsFolder {
            try? quarantineCorruptedFiles(corruptedFiles, in: folder)
        }

        return playlists.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func quarantineCorruptedFiles(_ files: [URL], in folder: URL) throws {
        let quarantineFolder = folder.appendingPathComponent("corrupted", isDirectory: true)

        if !FileManager.default.fileExists(atPath: quarantineFolder.path) {
            try FileManager.default.createDirectory(at: quarantineFolder,
                                                 withIntermediateDirectories: true,
                                                 attributes: nil)
        }

        for file in files {
            let destination = quarantineFolder.appendingPathComponent(file.lastPathComponent)
            try? FileManager.default.moveItem(at: file, to: destination)
            print("🗄️ Moved corrupted file to quarantine: \(file.lastPathComponent)")
        }
    }
    
    func deletePlaylist(slug: String) throws {
        // Delete from local Documents first
        try deletePlaylistFromLocalDocuments(slug: slug)
        
        // Also try to delete from iCloud Drive if available
        do {
            guard let appFolderURL = resolvedAppFolderURL() else {
                print("⚠️ iCloud not available, playlist deleted locally only")
                return
            }
            
            let playlistsFolder = appFolderURL.appendingPathComponent("playlists", isDirectory: true)
            let playlistURL = playlistsFolder.appendingPathComponent("playlist-\(slug).json")
            
            if FileManager.default.fileExists(atPath: playlistURL.path) {
                try FileManager.default.removeItem(at: playlistURL)
                print("☁️ Playlist deleted from iCloud: \(playlistURL.path)")
            }
        } catch {
            print("⚠️ Failed to delete playlist from iCloud, but local delete succeeded: \(error)")
        }
    }
    
    private func deletePlaylistFromLocalDocuments(slug: String) throws {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let localPlaylistsFolder = documentsURL.appendingPathComponent("cosmos-playlists", isDirectory: true)
        let localPlaylistURL = localPlaylistsFolder.appendingPathComponent("playlist-\(slug).json")
        
        if FileManager.default.fileExists(atPath: localPlaylistURL.path) {
            try FileManager.default.removeItem(at: localPlaylistURL)
            print("📱 Playlist deleted locally: \(localPlaylistURL.path)")
        }
    }
    
    // MARK: - Helper methods
    
    private func saveJSONAtomically<T: Codable>(_ object: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        
        let data = try encoder.encode(object)
        
        let tempURL = url.appendingPathExtension("tmp")
        try data.write(to: tempURL)
        _ = try FileManager.default.replaceItem(at: url, withItemAt: tempURL, 
                                              backupItemName: nil, options: [], 
                                              resultingItemURL: nil)
    }
    
    func getMusicFolderURL() -> URL? {
        return resolvedAppFolderURL()
    }
    
    func checkiCloudAvailability() -> Bool {
        // Check if user is signed into iCloud
        guard FileManager.default.ubiquityIdentityToken != nil else {
            return false
        }
        
        // Check if we can get the container URL
        guard let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            return false
        }
        
        // Update our cached URL if needed
        if iCloudContainerURL == nil {
            iCloudContainerURL = containerURL
        }
        
        return true
    }
}

// MARK: - Player State Persistence

struct PlayerState: Codable {
    let currentTrackStableId: String?
    let playbackTime: TimeInterval
    let isPlaying: Bool
    let queueTrackIds: [String]
    let currentIndex: Int
    let isRepeating: Bool
    let isShuffled: Bool
    let isLoopingSong: Bool
    let originalQueueTrackIds: [String]
    let lastSavedAt: Date
}

extension StateManager {
    func savePlayerState(_ playerState: PlayerState) throws {
        print("💾 StateManager: Saving player state - track: \(playerState.currentTrackStableId ?? "nil"), time: \(playerState.playbackTime)")
        
        // Always save to local Documents first (survives app reinstall)
        try savePlayerStateToLocalDocuments(playerState)
        
        // Also try to save to iCloud Drive if available
        do {
            try createAppFolderIfNeeded()
            guard let appFolderURL = resolvedAppFolderURL() else {
                print("⚠️ iCloud not available, player state saved locally only")
                return
            }
            
            let playerStateURL = appFolderURL.appendingPathComponent("player-state.json")
            try saveJSONAtomically(playerState, to: playerStateURL)
            print("✅ Player state saved to both local and iCloud")
        } catch {
            print("⚠️ Failed to save player state to iCloud, but local save succeeded: \(error)")
        }
    }
    
    private func savePlayerStateToLocalDocuments(_ playerState: PlayerState) throws {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let localPlayerStateURL = documentsURL.appendingPathComponent("cosmos-player-state.json")
        try saveJSONAtomically(playerState, to: localPlayerStateURL)
        print("📱 Player state saved locally to: \(localPlayerStateURL.path)")
    }
    
    func loadPlayerState() throws -> PlayerState? {
        print("📂 StateManager: Loading player state...")
        
        // Try loading from local Documents first (survives app reinstall)
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let localPlayerStateURL = documentsURL.appendingPathComponent("cosmos-player-state.json")
        
        print("📂 StateManager: Checking local player state at: \(localPlayerStateURL.path)")
        
        if FileManager.default.fileExists(atPath: localPlayerStateURL.path) {
            do {
                let data = try Data(contentsOf: localPlayerStateURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let playerState = try decoder.decode(PlayerState.self, from: data)
                print("📱 Loaded player state from local storage - track: \(playerState.currentTrackStableId ?? "nil"), time: \(playerState.playbackTime)")
                return playerState
            } catch {
                print("⚠️ Failed to load local player state: \(error)")
            }
        } else {
            print("📂 StateManager: Local player state file does not exist")
        }
        
        // Fallback to iCloud Drive if local doesn't exist
        guard let appFolderURL = resolvedAppFolderURL() else {
            print("📭 No player state found (neither local nor iCloud)")
            return nil
        }
        
        let playerStateURL = appFolderURL.appendingPathComponent("player-state.json")
        print("📂 StateManager: Checking iCloud player state at: \(playerStateURL.path)")
        
        guard FileManager.default.fileExists(atPath: playerStateURL.path) else {
            print("📭 No iCloud player state file found")
            return nil
        }
        
        do {
            // Check if this is an iCloud file and ensure it's downloaded
            let resourceValues = try playerStateURL.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
            
            if let isUbiquitous = resourceValues.isUbiquitousItem, isUbiquitous {
                print("☁️ iCloud player state file detected, checking download status...")
                
                if let downloadingStatus = resourceValues.ubiquitousItemDownloadingStatus {
                    print("📊 iCloud player state download status: \(downloadingStatus)")
                    
                    if downloadingStatus == .notDownloaded {
                        print("🔽 iCloud player state file needs downloading, starting download...")
                        try FileManager.default.startDownloadingUbiquitousItem(at: playerStateURL)
                        
                        // Wait a moment for download to start
                        Thread.sleep(forTimeInterval: 0.5)
                    }
                }
            }
            
            // Use NSFileCoordinator for proper iCloud file access
            var coordinatorError: NSError?
            var data: Data?
            
            let coordinator = NSFileCoordinator()
            coordinator.coordinate(readingItemAt: playerStateURL, options: .withoutChanges, error: &coordinatorError) { (url) in
                do {
                    data = try Data(contentsOf: url)
                    print("☁️ Successfully read player state from iCloud via NSFileCoordinator")
                } catch {
                    print("❌ Failed to read iCloud player state via coordinator: \(error)")
                }
            }
            
            if let coordinatorError = coordinatorError {
                print("❌ NSFileCoordinator error: \(coordinatorError)")
                return nil
            }
            
            guard let playerStateData = data else {
                print("❌ No data read from iCloud player state file")
                return nil
            }
            
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let playerState = try decoder.decode(PlayerState.self, from: playerStateData)
            print("☁️ Loaded player state from iCloud - track: \(playerState.currentTrackStableId ?? "nil"), time: \(playerState.playbackTime)")
            return playerState
        } catch {
            print("❌ Failed to load player state from iCloud: \(error)")
            return nil
        }
    }
}

enum StateManagerError: Error {
    case iCloudNotAvailable
    case fileNotFound
    case invalidData
}