//
//  AppCoordinator.swift
//  Cosmos Music Player
//
//  Main app coordinator that manages all services
//

import Foundation
import Combine

enum iCloudStatus: Equatable {
    case available
    case notSignedIn
    case containerUnavailable
    case offline
    case authenticationRequired
    case error(Error)
    
    static func == (lhs: iCloudStatus, rhs: iCloudStatus) -> Bool {
        switch (lhs, rhs) {
        case (.available, .available),
             (.notSignedIn, .notSignedIn),
             (.containerUnavailable, .containerUnavailable),
             (.offline, .offline),
             (.authenticationRequired, .authenticationRequired):
            return true
        case (.error, .error):
            return true
        default:
            return false
        }
    }
}

@MainActor
class AppCoordinator: ObservableObject {
    static let shared = AppCoordinator()
    
    @Published var isInitialized = false
    @Published var initializationError: Error?
    @Published var isiCloudAvailable = false
    @Published var iCloudStatus: iCloudStatus = .offline
    @Published var showSyncAlert = false
    
    private var isInitialSyncCompleted = false
    
    let databaseManager = DatabaseManager.shared
    let stateManager = StateManager.shared
    let libraryIndexer = LibraryIndexer.shared
    let playerEngine = PlayerEngine.shared
    let cloudDownloadManager = CloudDownloadManager.shared
    let fileCleanupManager = FileCleanupManager.shared
    
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        setupBindings()
    }
    
    func initialize() async {
        // Check iCloud status
        let status = await checkiCloudStatus()
        iCloudStatus = status
        
        // Notify CloudDownloadManager about status change
        NotificationCenter.default.post(name: NSNotification.Name("iCloudAuthStatusChanged"), object: nil)
        
        switch status {
        case .available:
            isiCloudAvailable = true
            await forceiCloudFolderCreation()
            await syncFavorites()
            await startLibraryIndexing()
            print("App initialized with iCloud sync")
            
        case .notSignedIn:
            isiCloudAvailable = false
            initializationError = AppCoordinatorError.iCloudNotSignedIn
            // Still initialize in local mode for functionality
            await startOfflineLibraryIndexing()
            print("App initialized in local mode - iCloud not signed in")
            
        case .containerUnavailable, .error(_):
            isiCloudAvailable = false
            initializationError = AppCoordinatorError.iCloudContainerInaccessible
            // Still initialize in local mode for functionality
            await startOfflineLibraryIndexing()
            print("App initialized in local mode - iCloud container unavailable")
            
        case .authenticationRequired:
            isiCloudAvailable = false
            showSyncAlert = true
            await startOfflineLibraryIndexing()
            print("App initialized in local mode - iCloud authentication required")
            
        case .offline:
            isiCloudAvailable = false
            // No error - this is true offline mode
            await startOfflineLibraryIndexing()
            print("App initialized in offline mode")
        }
        
        // Restore UI state only to show user what was playing without interrupting other apps
        Task {
            await playerEngine.restoreUIStateOnly()
        }
        
        isInitialized = true
    }
    
    private func checkiCloudStatus() async -> iCloudStatus {
        // Check if user is signed into iCloud
        guard FileManager.default.ubiquityIdentityToken != nil else {
            return .notSignedIn
        }
        
        // Check if we can get the container URL
        guard let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            return .containerUnavailable
        }
        
        // Check if we can actually access the container
        do {
            let resourceValues = try containerURL.resourceValues(forKeys: [.isUbiquitousItemKey])
            if resourceValues.isUbiquitousItem != true {
                return .containerUnavailable
            }
        } catch {
            return .error(error)
        }
        
        print("NSUbiquitousContainers:",
              Bundle.main.object(forInfoDictionaryKey: "NSUbiquitousContainers") ?? "nil")
        
        // Try to create the app folder
        do {
            let appFolderURL = containerURL.appendingPathComponent("Cosmos Player", isDirectory: true)
            
            if !FileManager.default.fileExists(atPath: appFolderURL.path) {
                try FileManager.default.createDirectory(at: appFolderURL, 
                                                     withIntermediateDirectories: true, 
                                                     attributes: nil)
            }
            
            print("iCloud container set up at: \(appFolderURL)")
            return .available
        } catch {
            return .error(error)
        }
    }
    
    private func syncFavorites() async {
        print("🔄 Starting favorites sync...")
        do {
            print("📂 Loading saved favorites from storage...")
            let savedFavorites = try stateManager.loadFavorites()
            print("🗃️ Getting favorites from database...")
            let databaseFavorites = try databaseManager.getFavorites()
            
            print("📊 Favorites sync - Saved: \(savedFavorites.count), Database: \(databaseFavorites.count)")
            print("📊 Saved favorites: \(savedFavorites)")
            print("📊 Database favorites: \(databaseFavorites)")
            
            // Only sync if we actually have saved favorites to restore
            if !savedFavorites.isEmpty {
                print("🔄 Restoring saved favorites to database...")
                // Restore any favorites that exist in saved but not in database
                for favorite in savedFavorites {
                    if !databaseFavorites.contains(favorite) {
                        try databaseManager.addToFavorites(trackStableId: favorite)
                        print("✅ Restored favorite: \(favorite)")
                    } else {
                        print("⚡ Favorite already in database: \(favorite)")
                    }
                }
                
                // Get final state after restoration
                print("🔍 Getting final state after restoration...")
                let finalFavorites = try databaseManager.getFavorites()
                print("📊 Final favorites count: \(finalFavorites.count)")
                print("📊 Final favorites list: \(finalFavorites)")
                
                // Only save if there were actual changes
                if finalFavorites != savedFavorites {
                    print("💾 Saving updated favorites...")
                    try stateManager.saveFavorites(finalFavorites)
                    print("💾 Updated saved favorites")
                } else {
                    print("✅ Favorites already in sync")
                }
            } else if !databaseFavorites.isEmpty {
                // If no saved favorites but database has some, save them
                print("💾 No saved favorites, saving database favorites to storage...")
                try stateManager.saveFavorites(databaseFavorites)
                print("💾 Saved database favorites to storage")
            } else {
                print("📭 No favorites to sync")
            }
            
        } catch {
            print("❌ Failed to sync favorites: \(error)")
        }
        
        // Mark initial sync as completed to allow future saves
        isInitialSyncCompleted = true
        print("✅ Initial favorites sync completed")
    }
    
    private func startLibraryIndexing() async {
        libraryIndexer.start()
    }
    
    private func startOfflineLibraryIndexing() async {
        // In offline mode, we don't use NSMetadataQuery (iCloud specific)
        // Instead, we scan the app's Documents directory for music files
        libraryIndexer.startOfflineMode()
    }
    
    private func setupBindings() {
        libraryIndexer.$isIndexing
            .sink { [weak self] isIndexing in
                if !isIndexing {
                    Task { @MainActor in
                        await self?.onIndexingCompleted()
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    func handleiCloudAuthenticationError() {
        guard iCloudStatus != .authenticationRequired else { return }
        
        iCloudStatus = .authenticationRequired
        isiCloudAvailable = false
        showSyncAlert = true
        
        // Stop any ongoing iCloud operations
        libraryIndexer.switchToOfflineMode()
        
        // Notify CloudDownloadManager about status change
        NotificationCenter.default.post(name: NSNotification.Name("iCloudAuthStatusChanged"), object: nil)
        
        
        print("🔐 iCloud authentication error detected - switched to offline mode")
    }
    
    private func onIndexingCompleted() async {
        do {
            let favorites = try databaseManager.getFavorites()
            
            // Only save to iCloud if we actually have favorites AND initial sync is completed
            // This prevents overwriting existing iCloud favorites with an empty array during startup
            if !favorites.isEmpty && isInitialSyncCompleted {
                try stateManager.saveFavorites(favorites)
                print("Saved \(favorites.count) favorites to iCloud")
            } else if !isInitialSyncCompleted {
                print("Skipping iCloud save - initial sync not completed yet")
            } else {
                print("Skipping iCloud save - no favorites to save (prevents overwriting existing iCloud data)")
            }
            
            // Restore playlists from iCloud after indexing is complete
            await restorePlaylistsFromiCloud()
            
            // Verify and fix any database relationship issues
            await verifyDatabaseRelationships()
            
            // Try playlist restoration again after relationships are fixed
            await retryPlaylistRestoration()
            
            // Check for orphaned files after sync completes
            print("🔄 AppCoordinator: Starting orphaned files check...")
            await fileCleanupManager.checkForOrphanedFiles()
            print("🔄 AppCoordinator: Orphaned files check completed")
        } catch {
            print("Failed to save favorites after indexing: \(error)")
        }
    }
    
    private func forceiCloudFolderCreation() async {
        do {
            try stateManager.createAppFolderIfNeeded()
            if let folderURL = stateManager.getMusicFolderURL() {
                print("🏗️ iCloud folder created/verified at: \(folderURL)")
                
                // Create test files to trigger iCloud Drive visibility (as per research)
                let tempFile = folderURL.appendingPathComponent(".cosmos-placeholder")
                let testFile = folderURL.appendingPathComponent("Welcome.txt")
                
                let tempContent = "Cosmos Music Player folder - you can delete this file"
                let welcomeContent = "Welcome to Cosmos Music Player!\n\nYou can add your FLAC music files directly to this folder in the Files app.\n\nThe app will automatically detect and index any music files you add here.\n\nEnjoy your music!"
                
                try tempContent.write(to: tempFile, atomically: true, encoding: .utf8)
                try welcomeContent.write(to: testFile, atomically: true, encoding: .utf8)
                print("📄 Created placeholder and welcome files to ensure folder visibility")
            }
        } catch {
            print("⚠️ Failed to create iCloud folder: \(error)")
        }
    }
    
    private func restorePlaylistsFromiCloud() async {
        // Skip if iCloud is not available or authentication required
        guard isiCloudAvailable && iCloudStatus == .available else {
            print("⚠️ Skipping playlist restoration - iCloud not available or authentication required")
            return
        }
        
        do {
            print("🔄 Starting playlist restoration from iCloud...")
            let playlistStates = try stateManager.getAllPlaylists()
            print("📂 Found \(playlistStates.count) playlists in iCloud storage")
            
            for playlistState in playlistStates {
                // Check if playlist already exists in database
                let existingPlaylists = try databaseManager.getAllPlaylists()
                let playlistExists = existingPlaylists.contains { $0.slug == playlistState.slug }
                
                if !playlistExists {
                    print("➕ Restoring playlist: \(playlistState.title)")
                    // Create playlist in database
                    let playlist = try databaseManager.createPlaylist(title: playlistState.title)
                    
                    // Add tracks to playlist if they exist in the database
                    guard let playlistId = playlist.id else { continue }
                    
                    for item in playlistState.items {
                        // Check if track exists in database
                        if let _ = try databaseManager.getTrack(byStableId: item.trackId) {
                            try databaseManager.addToPlaylist(playlistId: playlistId, trackStableId: item.trackId)
                            print("✅ Added track to playlist: \(item.trackId)")
                        } else {
                            print("⚠️ Track not found in database: \(item.trackId)")
                        }
                    }
                } else {
                    print("⚡ Playlist already exists: \(playlistState.title)")
                }
            }
            print("✅ Playlist restoration completed")
        } catch {
            print("❌ Failed to restore playlists from iCloud: \(error)")
            
            // Check if this is an authentication error
            if let stateError = error as? StateManagerError, stateError == .iCloudNotAvailable {
                print("🔐 StateManager authentication error - switching to offline mode")
                handleiCloudAuthenticationError()
            }
        }
    }
    
    private func verifyDatabaseRelationships() async {
        do {
            print("🔍 Verifying database relationships...")
            let tracks = try databaseManager.getAllTracks()
            let albums = try databaseManager.getAllAlbums()
            let artists = try databaseManager.getAllArtists()
            
            print("📊 Database stats - Tracks: \(tracks.count), Albums: \(albums.count), Artists: \(artists.count)")
            
            // Simple verification - just report what we have
            var tracksWithoutArtist = 0
            var tracksWithoutAlbum = 0
            var invalidArtistRefs = 0
            var invalidAlbumRefs = 0
            
            for track in tracks {
                // Check artist relationship
                if let artistId = track.artistId {
                    let artistExists = artists.contains { $0.id == artistId }
                    if !artistExists {
                        invalidArtistRefs += 1
                        print("⚠️ Track '\(track.title)' references non-existent artist ID: \(artistId)")
                    }
                } else {
                    tracksWithoutArtist += 1
                    print("⚠️ Track '\(track.title)' has no artist ID")
                }
                
                // Check album relationship  
                if let albumId = track.albumId {
                    let albumExists = albums.contains { $0.id == albumId }
                    if !albumExists {
                        invalidAlbumRefs += 1
                        print("⚠️ Track '\(track.title)' references non-existent album ID: \(albumId)")
                    }
                } else {
                    tracksWithoutAlbum += 1
                    print("⚠️ Track '\(track.title)' has no album ID")
                }
            }
            
            print("🔍 Verification complete:")
            print("   - Tracks without artist: \(tracksWithoutArtist)")
            print("   - Tracks without album: \(tracksWithoutAlbum)")
            print("   - Invalid artist refs: \(invalidArtistRefs)")
            print("   - Invalid album refs: \(invalidAlbumRefs)")
            
        } catch {
            print("❌ Failed to verify database relationships: \(error)")
        }
    }
    
    private func retryPlaylistRestoration() async {
        // Skip if iCloud is not available or authentication required
        guard isiCloudAvailable && iCloudStatus == .available else {
            print("⚠️ Skipping retry playlist restoration - iCloud not available or authentication required")
            return
        }
        
        do {
            print("🔄 Retrying playlist restoration after database fixes...")
            let playlistStates = try stateManager.getAllPlaylists()
            let existingPlaylists = try databaseManager.getAllPlaylists()
            
            for playlistState in playlistStates {
                if let existingPlaylist = existingPlaylists.first(where: { $0.slug == playlistState.slug }),
                   let playlistId = existingPlaylist.id {
                    
                    // Check if playlist is empty and try to restore tracks
                    let currentItems = try databaseManager.getPlaylistItems(playlistId: playlistId)
                    if currentItems.isEmpty {
                        print("🔄 Playlist '\(playlistState.title)' is empty, attempting to restore tracks...")
                        
                        for item in playlistState.items {
                            if let _ = try databaseManager.getTrack(byStableId: item.trackId) {
                                try databaseManager.addToPlaylist(playlistId: playlistId, trackStableId: item.trackId)
                                print("✅ Added track to playlist after fix: \(item.trackId)")
                            } else {
                                print("⚠️ Track still not found after fixes: \(item.trackId)")
                            }
                        }
                    } else {
                        print("⚡ Playlist '\(playlistState.title)' already has \(currentItems.count) items")
                    }
                }
            }
            print("✅ Playlist restoration retry completed")
        } catch {
            print("❌ Failed to retry playlist restoration: \(error)")
            
            // Check if this is an authentication error
            if let stateError = error as? StateManagerError, stateError == .iCloudNotAvailable {
                print("🔐 StateManager authentication error in retry - switching to offline mode")
                handleiCloudAuthenticationError()
            }
        }
    }
    
    
    // MARK: - Public API
    
    func getAllTracks() throws -> [Track] {
        return try databaseManager.getAllTracks()
    }
    
    func manualSync() async {
        print("🔄 Manual sync triggered - attempting library indexing")
        
        // Check if we're already indexing
        if libraryIndexer.isIndexing {
            print("⚠️ Library indexing already in progress - skipping manual sync")
            return
        }
        
        // For manual sync, always attempt to re-index to catch new files
        print("📋 Performing manual sync - user requested fresh library scan")
        await startLibraryIndexing()
    }
    
    func getAllArtists() throws -> [Artist] {
        return try databaseManager.getAllArtists()
    }
    
    func getAllAlbums() throws -> [Album] {
        return try databaseManager.getAllAlbums()
    }
    
    func toggleFavorite(trackStableId: String) throws {
        print("🔄 Toggle favorite for track: \(trackStableId)")
        
        let wasLiked = try databaseManager.isFavorite(trackStableId: trackStableId)
        print("📊 Track was liked before toggle: \(wasLiked)")
        
        if wasLiked {
            try databaseManager.removeFromFavorites(trackStableId: trackStableId)
            print("❌ Removed from favorites: \(trackStableId)")
        } else {
            try databaseManager.addToFavorites(trackStableId: trackStableId)
            print("❤️ Added to favorites: \(trackStableId)")
        }
        
        // Verify the database operation worked
        let isNowLiked = try databaseManager.isFavorite(trackStableId: trackStableId)
        print("📊 Track is now liked after toggle: \(isNowLiked)")
        
        // Get current favorites count from database
        let currentFavorites = try databaseManager.getFavorites()
        print("📊 Total favorites in database after toggle: \(currentFavorites.count)")
        
        // Always save favorites (both locally and to iCloud if available)
        Task {
            do {
                let favorites = try databaseManager.getFavorites()
                print("📊 Favorites to save: \(favorites.count) - \(favorites)")
                try stateManager.saveFavorites(favorites)
                print("💾 Favorites saved: \(favorites.count) total")
                
                // Verify save worked by loading back
                let loadedFavorites = try stateManager.loadFavorites()
                print("📊 Loaded favorites after save: \(loadedFavorites.count) - \(loadedFavorites)")
            } catch {
                print("❌ Failed to save favorites: \(error)")
            }
        }
    }
    
    func isFavorite(trackStableId: String) throws -> Bool {
        return try databaseManager.isFavorite(trackStableId: trackStableId)
    }
    
    func getFavorites() throws -> [String] {
        return try databaseManager.getFavorites()
    }
    
    // MARK: - Playlist operations
    
    func addToPlaylist(playlistId: Int64, trackStableId: String) throws {
        try databaseManager.addToPlaylist(playlistId: playlistId, trackStableId: trackStableId)
        syncPlaylistsToCloud()
    }
    
    func removeFromPlaylist(playlistId: Int64, trackStableId: String) throws {
        try databaseManager.removeFromPlaylist(playlistId: playlistId, trackStableId: trackStableId)
        syncPlaylistsToCloud()
    }
    
    func createPlaylist(title: String) throws -> Playlist {
        let playlist = try databaseManager.createPlaylist(title: title)
        syncPlaylistsToCloud()
        return playlist
    }
    
    func isTrackInPlaylist(playlistId: Int64, trackStableId: String) throws -> Bool {
        return try databaseManager.isTrackInPlaylist(playlistId: playlistId, trackStableId: trackStableId)
    }
    
    func deletePlaylist(playlistId: Int64) throws {
        // Get playlist info before deleting from database
        let playlists = try databaseManager.getAllPlaylists()
        guard let playlist = playlists.first(where: { $0.id == playlistId }) else {
            throw AppCoordinatorError.playlistNotFound
        }
        
        let playlistSlug = playlist.slug
        
        // Delete from database
        try databaseManager.deletePlaylist(playlistId: playlistId)
        
        // Delete from iCloud and local storage
        try stateManager.deletePlaylist(slug: playlistSlug)
        
        print("✅ Playlist '\(playlist.title)' deleted from database and cloud storage")
    }
    
    func updatePlaylistAccessed(playlistId: Int64) throws {
        try databaseManager.updatePlaylistAccessed(playlistId: playlistId)
    }
    
    func updatePlaylistLastPlayed(playlistId: Int64) throws {
        try databaseManager.updatePlaylistLastPlayed(playlistId: playlistId)
    }
    
    private func syncPlaylistsToCloud() {
        Task {
            do {
                let playlists = try databaseManager.getAllPlaylists()
                for playlist in playlists {
                    guard let playlistId = playlist.id else { continue }
                    
                    // Get playlist items from database
                    let dbPlaylistItems = try databaseManager.getPlaylistItems(playlistId: playlistId)
                    let stateItems = dbPlaylistItems.map { item in
                        (item.trackStableId, Date()) // Use current date as addedAt since we don't track that yet
                    }
                    
                    let playlistState = PlaylistState(
                        slug: playlist.slug,
                        title: playlist.title,
                        createdAt: Date(timeIntervalSince1970: TimeInterval(playlist.createdAt)),
                        items: stateItems
                    )
                    try stateManager.savePlaylist(playlistState)
                }
                print("✅ Playlists synced to iCloud with \(playlists.count) playlists")
            } catch {
                print("❌ Failed to sync playlists to iCloud: \(error)")
            }
        }
    }
    
    func playTrack(_ track: Track, queue: [Track] = []) async {
        await playerEngine.playTrack(track, queue: queue)
    }
}

enum AppCoordinatorError: Error {
    case iCloudNotAvailable
    case iCloudNotSignedIn
    case iCloudContainerInaccessible
    case databaseError
    case indexingError
    case playlistNotFound
    
    var localizedDescription: String {
        switch self {
        case .iCloudNotAvailable:
            return "iCloud Drive is not available on this device."
        case .iCloudNotSignedIn:
            return "Please sign in to iCloud to use this app. Go to Settings > [Your Name] > iCloud and enable iCloud Drive."
        case .iCloudContainerInaccessible:
            return "Cannot access iCloud Drive. Please check your internet connection and iCloud Drive settings."
        case .databaseError:
            return "Database error occurred."
        case .indexingError:
            return "Error indexing music library."
        case .playlistNotFound:
            return "Playlist not found."
        }
    }
}
