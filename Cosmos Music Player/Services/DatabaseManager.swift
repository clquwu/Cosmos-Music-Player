//
//  DatabaseManager.swift
//  Cosmos Music Player
//
//  Database manager for the music library using GRDB
//

import Foundation
import CryptoKit
@preconcurrency import GRDB

class DatabaseManager: @unchecked Sendable {
    static let shared = DatabaseManager()

    private var dbWriter: DatabaseWriter!
    private let maxRetries = 3
    private let retryDelay: UInt64 = 500_000_000 // 0.5 seconds in nanoseconds

    private init() {
        setupDatabaseWithRetry()
    }

    private func setupDatabaseWithRetry() {
        var lastError: Error?

        for attempt in 1...maxRetries {
            do {
                try setupDatabase()
                print("✅ Database initialized successfully on attempt \(attempt)")
                return
            } catch {
                lastError = error
                print("⚠️ Database setup failed on attempt \(attempt)/\(maxRetries): \(error)")

                if attempt < maxRetries {
                    // Wait before retrying
                    Thread.sleep(forTimeInterval: Double(retryDelay) / 1_000_000_000.0)
                }
            }
        }

        // If all retries failed, try to recover
        if let error = lastError {
            print("❌ Database setup failed after \(maxRetries) attempts. Attempting recovery...")
            attemptDatabaseRecovery(error: error)
        }
    }

    private func setupDatabase() throws {
        let databaseURL = try getDatabaseURL()

        // Use DatabasePool instead of DatabaseQueue to support concurrent reads
        // This is essential for CarPlay and other multi-threaded scenarios
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            // Enable foreign key constraints
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        dbWriter = try DatabasePool(path: databaseURL.path, configuration: configuration)
        try createTables()
        try migrateDatabaseIfNeeded()
    }

    private func attemptDatabaseRecovery(error: Error) {
        print("🔧 Attempting database recovery...")

        do {
            let databaseURL = try getDatabaseURL()
            let backupURL = databaseURL.deletingLastPathComponent()
                .appendingPathComponent("cosmos_music_backup_\(Int(Date().timeIntervalSince1970)).db")

            // Try to backup the corrupted database
            if FileManager.default.fileExists(atPath: databaseURL.path) {
                try? FileManager.default.moveItem(at: databaseURL, to: backupURL)
                print("📦 Backed up corrupted database to: \(backupURL.path)")
            }

            // Try to create a fresh database
            try setupDatabase()
            print("✅ Database recovery successful - created fresh database")
        } catch {
            // Last resort: create an in-memory database to prevent crashes
            print("❌ Database recovery failed: \(error)")
            print("⚠️ Creating in-memory database as fallback")

            do {
                var configuration = Configuration()
                configuration.prepareDatabase { db in
                    try db.execute(sql: "PRAGMA foreign_keys = ON")
                }

                // Create in-memory database
                dbWriter = try DatabaseQueue(configuration: configuration)
                try createTables()
                print("✅ In-memory database created successfully")
            } catch {
                // Absolute last resort - this should never happen
                fatalError("Critical error: Unable to initialize any database: \(error)")
            }
        }
    }
    
    private func getDatabaseURL() throws -> URL {
        // Try to use app group container first for sharing with Siri extension
        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.dev.clq.Cosmos-Music-Player") {
            return containerURL.appendingPathComponent("cosmos_music.db")
        } else {
            // Fallback to documents directory
            let documentsPath = FileManager.default.urls(for: .documentDirectory,
                                                       in: .userDomainMask).first!
            return documentsPath.appendingPathComponent("MusicLibrary.sqlite")
        }
    }
    
    private func createTables() throws {
        try dbWriter.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS artist (
                    id INTEGER PRIMARY KEY,
                    name TEXT NOT NULL COLLATE NOCASE
                )
            """)
            
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS album (
                    id INTEGER PRIMARY KEY,
                    artist_id INTEGER REFERENCES artist(id) ON DELETE CASCADE,
                    title TEXT NOT NULL COLLATE NOCASE,
                    year INTEGER,
                    album_artist TEXT COLLATE NOCASE
                )
            """)
            
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS track (
                    id INTEGER PRIMARY KEY,
                    stable_id TEXT NOT NULL UNIQUE,
                    album_id INTEGER REFERENCES album(id) ON DELETE SET NULL,
                    artist_id INTEGER REFERENCES artist(id) ON DELETE SET NULL,
                    title TEXT NOT NULL COLLATE NOCASE,
                    track_no INTEGER,
                    disc_no INTEGER,
                    duration_ms INTEGER,
                    sample_rate INTEGER,
                    bit_depth INTEGER,
                    channels INTEGER,
                    path TEXT NOT NULL,
                    file_size INTEGER,
                    replaygain_track_gain REAL,
                    replaygain_album_gain REAL,
                    replaygain_track_peak REAL,
                    replaygain_album_peak REAL,
                    has_embedded_art INTEGER DEFAULT 0
                )
            """)
            
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS favorite (
                    track_stable_id TEXT PRIMARY KEY
                )
            """)
            
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS playlist (
                    id INTEGER PRIMARY KEY,
                    slug TEXT NOT NULL UNIQUE,
                    title TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    last_played_at INTEGER DEFAULT 0,
                    folder_path TEXT,
                    is_folder_synced BOOLEAN DEFAULT 0,
                    last_folder_sync INTEGER
                )
            """)
            
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS playlist_item (
                    playlist_id INTEGER REFERENCES playlist(id) ON DELETE CASCADE,
                    position INTEGER NOT NULL,
                    track_stable_id TEXT NOT NULL,
                    PRIMARY KEY (playlist_id, position)
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS deleted_folder_playlist (
                    folder_path TEXT PRIMARY KEY,
                    deleted_at INTEGER NOT NULL
                )
            """)

            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_track_album ON track(album_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_track_artist ON track(artist_id)")

            // EQ Tables
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS eq_preset (
                    id INTEGER PRIMARY KEY,
                    name TEXT NOT NULL UNIQUE,
                    is_built_in INTEGER DEFAULT 0,
                    is_active INTEGER DEFAULT 0,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS eq_band (
                    id INTEGER PRIMARY KEY,
                    preset_id INTEGER NOT NULL REFERENCES eq_preset(id) ON DELETE CASCADE,
                    frequency REAL NOT NULL,
                    gain REAL NOT NULL DEFAULT 0.0,
                    bandwidth REAL NOT NULL DEFAULT 0.5,
                    band_index INTEGER NOT NULL
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS eq_settings (
                    id INTEGER PRIMARY KEY,
                    is_enabled INTEGER DEFAULT 0,
                    active_preset_id INTEGER REFERENCES eq_preset(id) ON DELETE SET NULL,
                    global_gain REAL DEFAULT 0.0,
                    updated_at INTEGER NOT NULL
                )
            """)

            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_eq_band_preset ON eq_band(preset_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_eq_band_index ON eq_band(band_index)")

            // Migration: Add last_played_at column if it doesn't exist
            do {
                try db.execute(sql: """
                    ALTER TABLE playlist ADD COLUMN last_played_at INTEGER DEFAULT 0
                """)
                print("✅ Database: Added last_played_at column to playlist table")
            } catch {
                // Column may already exist, which is fine
                print("ℹ️ Database migration: last_played_at column already exists or migration failed: \(error)")
            }

            // Migration: Add preset_type column to eq_preset if it doesn't exist
            do {
                try db.execute(sql: """
                    ALTER TABLE eq_preset ADD COLUMN preset_type TEXT DEFAULT 'imported'
                """)
                print("✅ Database: Added preset_type column to eq_preset table")
            } catch {
                // Column may already exist, which is fine
                print("ℹ️ Database migration: preset_type column already exists or migration failed: \(error)")
            }
        }
    }

    private func migrateDatabaseIfNeeded() throws {
        try write { db in
            // Migration: Add folder sync columns to playlist table
            do {
                try db.execute(sql: "ALTER TABLE playlist ADD COLUMN folder_path TEXT")
                print("✅ Database: Added folder_path column to playlist table")
            } catch {
                // Column may already exist, which is fine
                print("ℹ️ Database migration: folder_path column already exists or migration failed: \(error)")
            }

            do {
                try db.execute(sql: "ALTER TABLE playlist ADD COLUMN is_folder_synced BOOLEAN DEFAULT 0")
                print("✅ Database: Added is_folder_synced column to playlist table")
            } catch {
                // Column may already exist, which is fine
                print("ℹ️ Database migration: is_folder_synced column already exists or migration failed: \(error)")
            }

            do {
                try db.execute(sql: "ALTER TABLE playlist ADD COLUMN last_folder_sync INTEGER")
                print("✅ Database: Added last_folder_sync column to playlist table")
            } catch {
                // Column may already exist, which is fine
                print("ℹ️ Database migration: last_folder_sync column already exists or migration failed: \(error)")
            }

            // Migration: Add custom_cover_image_path column to playlist table
            do {
                try db.execute(sql: "ALTER TABLE playlist ADD COLUMN custom_cover_image_path TEXT")
                print("✅ Database: Added custom_cover_image_path column to playlist table")
            } catch {
                // Column may already exist, which is fine
                print("ℹ️ Database migration: custom_cover_image_path column already exists or migration failed: \(error)")
            }

            // Migration: Create deleted_folder_playlist table to prevent recreation of deleted folder playlists
            do {
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS deleted_folder_playlist (
                        folder_path TEXT PRIMARY KEY,
                        deleted_at INTEGER NOT NULL
                    )
                """)
                print("✅ Database: Created deleted_folder_playlist table")
            } catch {
                print("ℹ️ Database migration: deleted_folder_playlist table already exists or migration failed: \(error)")
            }

            // First, deduplicate by filename before updating stable IDs
            do {
                let allTracks = try Track.fetchAll(db)

                // Group by filename (what the new stable_id will be)
                let groupedByFilename = Dictionary(grouping: allTracks, by: { track -> String in
                    let url = URL(fileURLWithPath: track.path)
                    return url.lastPathComponent
                })

                var removedCount = 0

                for (filename, duplicates) in groupedByFilename where duplicates.count > 1 {
                    print("⚠️ Found \(duplicates.count) tracks with same filename: \(filename)")

                    // Keep the most recent one (highest ID = most recently added)
                    let sorted = duplicates.sorted { ($0.id ?? 0) > ($1.id ?? 0) }
                    let keep = sorted.first!
                    let remove = Array(sorted.dropFirst())

                    print("✅ Keeping track ID \(keep.id ?? 0): \(keep.title)")

                    for duplicate in remove {
                        // Transfer favorites to the kept track
                        try db.execute(
                            sql: "UPDATE OR IGNORE favorite SET track_stable_id = ? WHERE track_stable_id = ?",
                            arguments: [keep.stableId, duplicate.stableId]
                        )

                        // Transfer playlist items to the kept track
                        try db.execute(
                            sql: "UPDATE OR IGNORE playlist_item SET track_stable_id = ? WHERE track_stable_id = ?",
                            arguments: [keep.stableId, duplicate.stableId]
                        )

                        // Delete remaining orphaned references
                        try db.execute(
                            sql: "DELETE FROM favorite WHERE track_stable_id = ?",
                            arguments: [duplicate.stableId]
                        )
                        try db.execute(
                            sql: "DELETE FROM playlist_item WHERE track_stable_id = ?",
                            arguments: [duplicate.stableId]
                        )

                        // Delete the duplicate track
                        try Track.filter(Column("id") == duplicate.id).deleteAll(db)
                        print("🗑️ Removed duplicate track ID \(duplicate.id ?? 0): \(duplicate.title)")
                        removedCount += 1
                    }
                }

                if removedCount > 0 {
                    print("✅ Removed \(removedCount) duplicate tracks by filename")
                } else {
                    print("ℹ️ No duplicate tracks found by filename")
                }

            } catch {
                print("⚠️ Filename deduplication failed: \(error)")
            }

            // Now update stable IDs from path-based to filename-based
            do {
                let tracks = try Track.fetchAll(db)
                var updatedCount = 0

                for track in tracks {
                    // Generate new stable ID based on filename only
                    let url = URL(fileURLWithPath: track.path)
                    let filename = url.lastPathComponent
                    let newStableId = SHA256.hash(data: filename.data(using: .utf8) ?? Data())
                        .compactMap { String(format: "%02x", $0) }.joined()

                    // Only update if stable ID changed
                    if track.stableId != newStableId {
                        // Update track
                        try db.execute(
                            sql: "UPDATE track SET stable_id = ? WHERE id = ?",
                            arguments: [newStableId, track.id]
                        )

                        // Update favorites references
                        try db.execute(
                            sql: "UPDATE favorite SET track_stable_id = ? WHERE track_stable_id = ?",
                            arguments: [newStableId, track.stableId]
                        )

                        // Update playlist item references
                        try db.execute(
                            sql: "UPDATE playlist_item SET track_stable_id = ? WHERE track_stable_id = ?",
                            arguments: [newStableId, track.stableId]
                        )

                        updatedCount += 1
                    }
                }

                if updatedCount > 0 {
                    print("✅ Database: Migrated \(updatedCount) stable IDs from path-based to filename-based")
                } else {
                    print("ℹ️ Database: Stable IDs already filename-based")
                }
            } catch {
                print("⚠️ Database migration: Stable ID migration failed: \(error)")
                // Don't throw - allow app to continue and re-index will handle it
            }

            // Add UNIQUE constraint to stable_id to prevent duplicates
            do {
                try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS idx_track_stable_id ON track(stable_id)")
                print("✅ Database: Created UNIQUE index on track.stable_id")
            } catch {
                print("⚠️ Database migration: Failed to create UNIQUE index on stable_id: \(error)")
            }
        }
    }

    func read<T>(_ operation: @escaping (Database) throws -> T) throws -> T {
        return try dbWriter.read(operation)
    }
    
    func write<T>(_ operation: @escaping (Database) throws -> T) throws -> T {
        return try dbWriter.write(operation)
    }
    
    // MARK: - Track operations
    
    func upsertTrack(_ track: Track) throws {
        try write { db in
            // Safety check: Remove any duplicates with the same path but different stable_id
            // This handles edge cases where migration didn't run or failed
            let duplicates = try Track.filter(Column("path") == track.path && Column("stable_id") != track.stableId).fetchAll(db)
            if !duplicates.isEmpty {
                print("⚠️ Found \(duplicates.count) duplicate(s) for path: \(track.path)")
                for duplicate in duplicates {
                    // Transfer favorites and playlist items to the new stable_id
                    try db.execute(
                        sql: "UPDATE favorite SET track_stable_id = ? WHERE track_stable_id = ?",
                        arguments: [track.stableId, duplicate.stableId]
                    )
                    try db.execute(
                        sql: "UPDATE playlist_item SET track_stable_id = ? WHERE track_stable_id = ?",
                        arguments: [track.stableId, duplicate.stableId]
                    )
                    // Delete the duplicate
                    try Track.filter(Column("id") == duplicate.id).deleteAll(db)
                    print("🗑️ Removed duplicate track with old stable_id: \(duplicate.stableId)")
                }
            }

            try track.save(db)
        }
    }
    
    func getAllTracks() throws -> [Track] {
        return try read { db in
            return try Track.order(Column("id").desc).fetchAll(db)
        }
    }
    
    func getTrack(byStableId stableId: String) throws -> Track? {
        return try read { db in
            return try Track.filter(Column("stable_id") == stableId).fetchOne(db)
        }
    }
    
    // MARK: - Artist operations
    
    func upsertArtist(name: String) throws -> Artist {
        return try write { db in
            if let existing = try Artist.filter(Column("name") == name).fetchOne(db) {
                return existing
            }
            
            let artist = Artist(name: name)
            return try artist.insertAndFetch(db)!
        }
    }
    
    func getAllArtists() throws -> [Artist] {
        return try read { db in
            return try Artist.order(Column("name")).fetchAll(db)
        }
    }

    func searchArtists(query: String, limit: Int = 20) throws -> [Artist] {
        return try read { db in
            let pattern = "%\(query)%"
            return try Artist
                .filter(Column("name").like(pattern))
                .order(Column("name"))
                .limit(limit)
                .fetchAll(db)
        }
    }
    
    // MARK: - Album operations
    
    func upsertAlbum(title: String, artistId: Int64?, year: Int?, albumArtist: String?) throws -> Album {
        return try write { db in
            let normalizedTitle = self.normalizeAlbumTitle(title)
            
            // More efficient query: try exact match first
            if let existing = try Album
                .filter(Column("title") == normalizedTitle)
                .fetchOne(db) {
                return existing
            }
            
            // If no exact match, try case-insensitive and similar matches
            let existingAlbums = try Album.fetchAll(db)
            
            for existing in existingAlbums {
                let existingNormalized = self.normalizeAlbumTitle(existing.title)
                
                // Match by normalized title (case-insensitive)
                if existingNormalized.lowercased() == normalizedTitle.lowercased() {
                    return existing
                }
                
                // Check for very similar titles (minor differences)
                if self.areSimilarTitles(existingNormalized, normalizedTitle) {
                    return existing
                }
            }
            
            // No existing match found, create new album
            let album = Album(artistId: artistId, title: normalizedTitle, year: year, albumArtist: albumArtist)
            return try album.insertAndFetch(db)!
        }
    }
    
    private func areSimilarTitles(_ title1: String, _ title2: String) -> Bool {
        // Use folding to handle diacritics while preserving all Unicode characters
        let clean1 = title1.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .components(separatedBy: .punctuationCharacters).joined()
            .components(separatedBy: .whitespaces).joined()
        let clean2 = title2.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .components(separatedBy: .punctuationCharacters).joined()
            .components(separatedBy: .whitespaces).joined()

        // If they're identical after removing punctuation and whitespace, consider them the same
        if clean1 == clean2 {
            return true
        }

        // Only check substring matching if the strings are both non-empty and share the same script
        // This prevents Thai albums from matching English albums
        guard !clean1.isEmpty && !clean2.isEmpty else {
            return false
        }

        // Check if both strings use similar character sets (prevent cross-script matching)
        let hasLatin1 = clean1.rangeOfCharacter(from: .letters) != nil && clean1.rangeOfCharacter(from: CharacterSet(charactersIn: "a"..."z")) != nil
        let hasLatin2 = clean2.rangeOfCharacter(from: .letters) != nil && clean2.rangeOfCharacter(from: CharacterSet(charactersIn: "a"..."z")) != nil

        // Only allow substring matching if both are Latin or both are non-Latin
        if hasLatin1 != hasLatin2 {
            return false
        }

        // Check if one is a substring of the other (for cases like "Album" vs "Album - Extended")
        if clean1.contains(clean2) || clean2.contains(clean1) {
            let lengthDiff = abs(clean1.count - clean2.count)
            // Only consider similar if the difference is small (less than 30% difference)
            let maxLength = max(clean1.count, clean2.count)
            return lengthDiff <= max(3, maxLength / 3)
        }

        return false
    }
    
    private func normalizeAlbumTitle(_ title: String) -> String {
        var normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove common variations that cause duplicates
        let patternsToRemove = [
            " (Deluxe Edition)",
            " (Deluxe)",
            " (Extended Version)",
            " (Remastered)",
            " [Explicit]",
            " - EP",
            " EP"
        ]
        
        for pattern in patternsToRemove {
            if normalized.hasSuffix(pattern) {
                normalized = String(normalized.dropLast(pattern.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        // Remove extra whitespace
        normalized = normalized.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        
        return normalized.isEmpty ? title : normalized
    }
    
    func getAllAlbums() throws -> [Album] {
        return try read { db in
            return try Album.order(Column("title")).fetchAll(db)
        }
    }

    func searchAlbums(query: String, limit: Int = 30) throws -> [Album] {
        return try read { db in
            let pattern = "%\(query)%"
            return try Album
                .filter(Column("title").like(pattern))
                .order(Column("title"))
                .limit(limit)
                .fetchAll(db)
        }
    }

    func getArtist(byId id: Int64) throws -> Artist? {
        return try read { db in
            return try Artist.filter(Column("id") == id).fetchOne(db)
        }
    }

    func getTracksByStableIds(_ stableIds: [String]) throws -> [Track] {
        return try read { db in
            return try Track.filter(stableIds.contains(Column("stable_id"))).order(Column("id").desc).fetchAll(db)
        }
    }

    func getTracksByStableIdsPreservingOrder(_ stableIds: [String]) throws -> [Track] {
        guard !stableIds.isEmpty else { return [] }

        let tracks = try getTracksByStableIds(stableIds)
        let tracksByStableId = Dictionary(uniqueKeysWithValues: tracks.map { ($0.stableId, $0) })
        return stableIds.compactMap { tracksByStableId[$0] }
    }

    func getAllArtistNamesById() throws -> [Int64: String] {
        return try read { db in
            let artists = try Artist.fetchAll(db)
            var result: [Int64: String] = [:]
            result.reserveCapacity(artists.count)

            for artist in artists {
                if let id = artist.id {
                    result[id] = artist.name
                }
            }

            return result
        }
    }

    func getFavoriteTracks(excludingFormats: [String] = []) throws -> [Track] {
        let favoriteIds = try getFavorites()
        let orderedTracks = try getTracksByStableIdsPreservingOrder(favoriteIds)
        guard !excludingFormats.isEmpty else { return orderedTracks }

        let excludedFormats = Set(excludingFormats.map { $0.lowercased() })
        return orderedTracks.filter { track in
            let ext = URL(fileURLWithPath: track.path).pathExtension.lowercased()
            return !excludedFormats.contains(ext)
        }
    }

    func getTracksPaginated(limit: Int, offset: Int, excludingFormats: [String] = []) throws -> [Track] {
        return try read { db in
            let sanitizedFormats = excludingFormats
                .map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
                .filter { !$0.isEmpty }

            var sql = "SELECT * FROM track"
            if !sanitizedFormats.isEmpty {
                let formatClauses = sanitizedFormats.map { "LOWER(path) NOT LIKE '%.\($0)'" }
                sql += " WHERE " + formatClauses.joined(separator: " AND ")
            }

            sql += " ORDER BY title LIMIT \(max(limit, 0)) OFFSET \(max(offset, 0))"
            return try Track.fetchAll(db, sql: sql)
        }
    }

    func getTrackCount(excludingFormats: [String] = []) throws -> Int {
        return try read { db in
            let sanitizedFormats = excludingFormats
                .map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
                .filter { !$0.isEmpty }

            var sql = "SELECT COUNT(*) FROM track"
            if !sanitizedFormats.isEmpty {
                let formatClauses = sanitizedFormats.map { "LOWER(path) NOT LIKE '%.\($0)'" }
                sql += " WHERE " + formatClauses.joined(separator: " AND ")
            }

            return try Int.fetchOne(db, sql: sql) ?? 0
        }
    }

    func getTracksByAlbumId(_ albumId: Int64) throws -> [Track] {
        return try read { db in
            // Fetch all tracks for this album
            let tracks = try Track
                .filter(Column("album_id") == albumId)
                .fetchAll(db)

            // Sort in Swift to ensure proper integer sorting
            let sortedTracks = tracks.sorted { track1, track2 in
                // Sort by track number only (ignore disc number)
                let trackNo1 = track1.trackNo ?? 999
                let trackNo2 = track2.trackNo ?? 999

                if trackNo1 != trackNo2 {
                    return trackNo1 < trackNo2
                }

                // Tiebreaker: sort by title
                return track1.title < track2.title
            }

            return sortedTracks
        }
    }

    func getTracksByArtistId(_ artistId: Int64) throws -> [Track] {
        return try read { db in
            return try Track
                .filter(Column("artist_id") == artistId)
                .order(Column("title"))
                .fetchAll(db)
        }
    }

    // MARK: - Search operations

    func searchTracks(query: String) throws -> [Track] {
        return try read { db in
            let searchPattern = "%\(query)%"
            return try Track
                .filter(Column("title").like(searchPattern))
                .order(Column("title"))
                .fetchAll(db)
        }
    }

    func searchAlbums(query: String) throws -> [Album] {
        return try read { db in
            let searchPattern = "%\(query)%"
            return try Album
                .filter(Column("title").like(searchPattern))
                .order(Column("title"))
                .fetchAll(db)
        }
    }

    func searchArtists(query: String) throws -> [Artist] {
        return try read { db in
            let searchPattern = "%\(query)%"
            return try Artist
                .filter(Column("name").like(searchPattern))
                .order(Column("name"))
                .fetchAll(db)
        }
    }

    func searchPlaylists(query: String) throws -> [Playlist] {
        return try read { db in
            let searchPattern = "%\(query)%"
            return try Playlist
                .filter(Column("title").like(searchPattern))
                .order(Column("title"))
                .fetchAll(db)
        }
    }

    // MARK: - Favorites operations
    
    func addToFavorites(trackStableId: String) throws {
        print("🗃️ Database: Adding to favorites - \(trackStableId)")
        try write { db in
            let favorite = Favorite(trackStableId: trackStableId)
            try favorite.insert(db)
            print("🗃️ Database: Successfully inserted favorite")
        }
    }
    
    func removeFromFavorites(trackStableId: String) throws {
        print("🗃️ Database: Removing from favorites - \(trackStableId)")
        let deletedCount = try write { db in
            return try Favorite.filter(Column("track_stable_id") == trackStableId).deleteAll(db)
        }
        print("🗃️ Database: Deleted \(deletedCount) favorite(s)")
    }
    
    func isFavorite(trackStableId: String) throws -> Bool {
        return try read { db in
            return try Favorite.filter(Column("track_stable_id") == trackStableId).fetchOne(db) != nil
        }
    }
    
    func getFavorites() throws -> [String] {
        let favorites = try read { db in
            return try Favorite.fetchAll(db).map { $0.trackStableId }
        }
        print("🗃️ Database: Retrieved \(favorites.count) favorites - \(favorites)")
        return favorites
    }

    func deduplicatePlaylistItems() throws {
        print("🔍 Checking for duplicate playlist items...")

        let removedCount = try write { db in
            let playlists = try Playlist.fetchAll(db)
            var totalRemoved = 0

            for playlist in playlists {
                guard let playlistId = playlist.id else { continue }

                // Get all items for this playlist
                let items = try PlaylistItem.filter(Column("playlist_id") == playlistId).fetchAll(db)

                // Group by track path (need to join with track table)
                var seenPaths: Set<String> = [] // paths we've already seen
                var itemsToRemove: [PlaylistItem] = []

                for item in items {
                    // Get the track for this item
                    if let track = try Track.filter(Column("stable_id") == item.trackStableId).fetchOne(db) {
                        if seenPaths.contains(track.path) {
                            // Duplicate found - mark for removal
                            itemsToRemove.append(item)
                            print("⚠️ Playlist '\(playlist.title)': Found duplicate for '\(track.title)' at position \(item.position)")
                        } else {
                            // First occurrence - keep it
                            seenPaths.insert(track.path)
                        }
                    }
                }

                // Remove duplicates
                for item in itemsToRemove {
                    try PlaylistItem
                        .filter(Column("playlist_id") == playlistId && Column("position") == item.position)
                        .deleteAll(db)
                    totalRemoved += 1
                }

                if itemsToRemove.count > 0 {
                    print("✅ Removed \(itemsToRemove.count) duplicate items from playlist '\(playlist.title)'")

                    // Reorder remaining items to fill gaps
                    let remainingItems = try PlaylistItem
                        .filter(Column("playlist_id") == playlistId)
                        .order(Column("position"))
                        .fetchAll(db)

                    for (index, item) in remainingItems.enumerated() {
                        try db.execute(
                            sql: "UPDATE playlist_item SET position = ? WHERE playlist_id = ? AND track_stable_id = ? AND position = ?",
                            arguments: [index, playlistId, item.trackStableId, item.position]
                        )
                    }
                }
            }

            return totalRemoved
        }

        if removedCount > 0 {
            print("✅ Removed \(removedCount) duplicate playlist items across all playlists")
        } else {
            print("✅ No duplicate playlist items found")
        }
    }

    func cleanupOrphanedPlaylistItems() throws {
        print("🧹 Cleaning up orphaned playlist items...")

        // SAFETY CHECK: Verify database is healthy before cleanup
        let trackCount = try read { db in
            try Track.fetchCount(db)
        }

        if trackCount == 0 {
            print("⚠️ SAFETY: Skipping playlist cleanup - no tracks in database (possible database error)")
            print("⚠️ This prevents accidental deletion of all playlist items")
            return
        }

        let deletedCount = try write { db in
            // Get all playlist items
            let allItems = try PlaylistItem.fetchAll(db)
            var orphanedCount = 0

            print("🔍 Checking \(allItems.count) playlist items against \(trackCount) tracks")

            for item in allItems {
                // Check if track still exists
                let trackExists = try Track.filter(Column("stable_id") == item.trackStableId).fetchOne(db) != nil

                if !trackExists {
                    // Remove orphaned item
                    try PlaylistItem
                        .filter(Column("playlist_id") == item.playlistId && Column("track_stable_id") == item.trackStableId)
                        .deleteAll(db)
                    orphanedCount += 1
                    print("🗑️ Removed orphaned playlist item: \(item.trackStableId)")
                }
            }

            return orphanedCount
        }

        if deletedCount > 0 {
            print("✅ Cleaned up \(deletedCount) orphaned playlist items")
        } else {
            print("✅ No orphaned playlist items found")
        }
    }

    func deleteTrack(byStableId stableId: String) throws {
        print("🗃️ Database: Deleting track with stable ID - \(stableId)")
        let deletedCount = try write { db in
            // Remove from playlist items first
            let playlistItemsDeleted = try PlaylistItem.filter(Column("track_stable_id") == stableId).deleteAll(db)
            if playlistItemsDeleted > 0 {
                print("🗑️ Removed track from \(playlistItemsDeleted) playlist position(s)")
            }

            // Remove from favorites if it exists
            let favoritesDeleted = try Favorite.filter(Column("track_stable_id") == stableId).deleteAll(db)
            if favoritesDeleted > 0 {
                print("🗃️ Database: Removed \(favoritesDeleted) favorite entries for track")
            }

            if playlistItemsDeleted > 0 {
                print("🗃️ Database: Removed \(playlistItemsDeleted) playlist entries for track")
            }

            // Delete the track
            return try Track.filter(Column("stable_id") == stableId).deleteAll(db)
        }
        print("🗃️ Database: Deleted \(deletedCount) track(s)")

        // Clean up orphaned albums and artists after track deletion
        try cleanupOrphanedAlbums()
        try cleanupOrphanedArtists()
    }

    func cleanupOrphanedAlbums() throws {
        try write { db in
            // Delete albums that have no tracks referencing them
            try db.execute(sql: """
                DELETE FROM album
                WHERE id NOT IN (
                    SELECT DISTINCT album_id
                    FROM track
                    WHERE album_id IS NOT NULL
                )
            """)
        }
    }

    func cleanupOrphanedArtists() throws {
        try write { db in
            // Delete artists that have no tracks referencing them
            try db.execute(sql: """
                DELETE FROM artist
                WHERE id NOT IN (
                    SELECT DISTINCT artist_id
                    FROM track
                    WHERE artist_id IS NOT NULL
                )
            """)
        }
    }
    
    // MARK: - Playlist operations
    
    func createPlaylist(title: String) throws -> Playlist {
        return try write { db in
            let slug = title.lowercased().replacingOccurrences(of: " ", with: "-")
            let now = Int64(Date().timeIntervalSince1970)
            let playlist = Playlist(
                id: nil,
                slug: slug,
                title: title,
                createdAt: now,
                updatedAt: now,
                lastPlayedAt: 0,
                folderPath: nil,
                isFolderSynced: false,
                lastFolderSync: nil
            )
            return try playlist.insertAndFetch(db)!
        }
    }

    func createFolderPlaylist(title: String, folderPath: String) throws -> Playlist {
        return try write { db in
            // Normalize folder path by using just the folder name for comparison
            // This avoids issues with changing container UUIDs
            let folderName = URL(fileURLWithPath: folderPath).lastPathComponent

            // Check if this folder was previously deleted by the user
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM deleted_folder_playlist WHERE folder_path = ?",
                arguments: [folderName]
            ) ?? 0

            if count > 0 {
                print("⛔ Folder playlist '\(folderName)' was previously deleted by user, skipping recreation")
                throw DatabaseError.folderPlaylistDeleted
            }

            let slug = title.lowercased().replacingOccurrences(of: " ", with: "-")
            let now = Int64(Date().timeIntervalSince1970)

            // Check if a folder-synced playlist already exists for this path
            if let existingPlaylist = try Playlist.filter(Column("folder_path") == folderPath).fetchOne(db) {
                print("📁 Folder playlist already exists: \(existingPlaylist.title)")
                return existingPlaylist
            }

            // CRITICAL: Check if a manual playlist with the same title/slug already exists
            // This prevents data loss by not overwriting user-created playlists
            if let existingManualPlaylist = try Playlist.filter(Column("slug") == slug).fetchOne(db) {
                if !existingManualPlaylist.isFolderSynced {
                    print("⚠️ Manual playlist '\(title)' already exists - converting to folder-synced playlist")
                    // Update the existing playlist to be folder-synced
                    var updatedPlaylist = existingManualPlaylist
                    updatedPlaylist.folderPath = folderPath
                    updatedPlaylist.isFolderSynced = true
                    updatedPlaylist.lastFolderSync = now
                    updatedPlaylist.updatedAt = now
                    try updatedPlaylist.update(db)
                    print("✅ Converted manual playlist '\(title)' to folder-synced")
                    return updatedPlaylist
                } else {
                    // Another folder playlist with same name but different path
                    print("⚠️ Folder playlist '\(title)' already exists with different path")
                    return existingManualPlaylist
                }
            }

            let playlist = Playlist(
                id: nil,
                slug: slug,
                title: title,
                createdAt: now,
                updatedAt: now,
                lastPlayedAt: 0,
                folderPath: folderPath,
                isFolderSynced: true,
                lastFolderSync: now
            )
            print("📁 Creating folder-synced playlist: \(title) -> \(folderPath)")
            return try playlist.insertAndFetch(db)!
        }
    }

    enum DatabaseError: Error {
        case folderPlaylistDeleted
    }

    func getAllPlaylists() throws -> [Playlist] {
        return try read { db in
            return try Playlist.order(Column("last_played_at").desc, Column("updated_at").desc).fetchAll(db)
        }
    }

    func searchPlaylists(query: String, limit: Int = 15) throws -> [Playlist] {
        return try read { db in
            let pattern = "%\(query)%"
            return try Playlist
                .filter(Column("title").like(pattern))
                .order(Column("title"))
                .limit(limit)
                .fetchAll(db)
        }
    }

    func searchTracks(query: String, limit: Int = 50) throws -> [Track] {
        return try read { db in
            let pattern = "%\(query)%"
            return try Track
                .filter(Column("title").like(pattern))
                .order(Column("title"))
                .limit(limit)
                .fetchAll(db)
        }
    }

    func getFolderPlaylist(forPath folderPath: String) throws -> Playlist? {
        return try read { db in
            return try Playlist.filter(Column("folder_path") == folderPath && Column("is_folder_synced") == true).fetchOne(db)
        }
    }
    
    func addToPlaylist(playlistId: Int64, trackStableId: String) throws {
        print("🎵 Adding track \(trackStableId) to playlist \(playlistId)")
        try write { db in
            // Check if track is already in playlist
            let existingItem = try PlaylistItem
                .filter(Column("playlist_id") == playlistId && Column("track_stable_id") == trackStableId)
                .fetchOne(db)
            
            if existingItem != nil {
                print("⚠️ Track already in playlist")
                return
            }
            
            // Get the next position in the playlist
            let maxPosition = try PlaylistItem
                .filter(Column("playlist_id") == playlistId)
                .select(max(Column("position")))
                .asRequest(of: Int.self)
                .fetchOne(db) ?? 0
            
            let playlistItem = PlaylistItem(playlistId: playlistId, position: maxPosition + 1, trackStableId: trackStableId)
            print("🎵 Creating playlist item with position \(maxPosition + 1)")
            try playlistItem.insert(db)
            print("✅ Successfully added track to playlist")
        }
    }
    
    func removeFromPlaylist(playlistId: Int64, trackStableId: String) throws {
        try write { db in
            _ = try PlaylistItem
                .filter(Column("playlist_id") == playlistId && Column("track_stable_id") == trackStableId)
                .deleteAll(db)
        }
    }

    func reorderPlaylistItems(playlistId: Int64, from sourceIndex: Int, to destinationIndex: Int) throws {
        print("🔄 Database: Reordering playlist items from \(sourceIndex) to \(destinationIndex)")
        try write { db in
            // Get all playlist items ordered by position
            let items = try PlaylistItem
                .filter(Column("playlist_id") == playlistId)
                .order(Column("position"))
                .fetchAll(db)

            guard sourceIndex >= 0 && sourceIndex < items.count &&
                  destinationIndex >= 0 && destinationIndex < items.count else {
                print("❌ Invalid indices for reordering")
                return
            }

            // Remove the item from the source position
            var mutableItems = items
            let movedItem = mutableItems.remove(at: sourceIndex)

            // Insert at the destination position
            mutableItems.insert(movedItem, at: destinationIndex)

            // Two-phase update to avoid UNIQUE constraint violations:
            // Phase 1: Shift all positions by +10000 (temporary offset)
            print("🔄 Phase 1: Shifting positions to avoid conflicts")
            for (index, item) in mutableItems.enumerated() {
                _ = try PlaylistItem
                    .filter(Column("playlist_id") == playlistId &&
                           Column("track_stable_id") == item.trackStableId)
                    .updateAll(db, Column("position").set(to: index + 10000))
            }

            // Phase 2: Set final positions
            print("🔄 Phase 2: Setting final positions")
            for (index, item) in mutableItems.enumerated() {
                _ = try PlaylistItem
                    .filter(Column("playlist_id") == playlistId &&
                           Column("track_stable_id") == item.trackStableId)
                    .updateAll(db, Column("position").set(to: index))
            }

            print("✅ Successfully reordered playlist items")
        }
    }

    func getPlaylistItems(playlistId: Int64) throws -> [PlaylistItem] {
        return try read { db in
            return try PlaylistItem
                .filter(Column("playlist_id") == playlistId)
                .order(Column("position"))
                .fetchAll(db)
        }
    }
    
    func isTrackInPlaylist(playlistId: Int64, trackStableId: String) throws -> Bool {
        return try read { db in
            return try PlaylistItem
                .filter(Column("playlist_id") == playlistId && Column("track_stable_id") == trackStableId)
                .fetchOne(db) != nil
        }
    }
    
    func deletePlaylist(playlistId: Int64) throws {
        print("🗑️ Database: Deleting playlist with ID - \(playlistId)")
        let deletedCount = try write { db in
            // Check if this is a folder-synced playlist
            if let playlist = try Playlist.filter(Column("id") == playlistId).fetchOne(db),
               let folderPath = playlist.folderPath,
               playlist.isFolderSynced {
                // Normalize to just the folder name to avoid container UUID issues
                let folderName = URL(fileURLWithPath: folderPath).lastPathComponent

                // Add to deleted folder playlists table to prevent recreation
                let now = Int64(Date().timeIntervalSince1970)
                try db.execute(
                    sql: "INSERT OR REPLACE INTO deleted_folder_playlist (folder_path, deleted_at) VALUES (?, ?)",
                    arguments: [folderName, now]
                )
                print("📝 Marked folder playlist '\(folderName)' as deleted to prevent recreation")
            }

            return try Playlist.filter(Column("id") == playlistId).deleteAll(db)
        }
        print("🗑️ Database: Deleted \(deletedCount) playlist(s)")
    }

    func renamePlaylist(playlistId: Int64, newTitle: String) throws {
        print("✏️ Database: Renaming playlist \(playlistId) to '\(newTitle)'")
        let now = Int64(Date().timeIntervalSince1970)
        let updatedCount = try write { db in
            return try Playlist
                .filter(Column("id") == playlistId)
                .updateAll(db,
                    Column("title").set(to: newTitle),
                    Column("updated_at").set(to: now)
                )
        }
        print("✏️ Database: Updated \(updatedCount) playlist(s)")
    }

    func syncPlaylistWithFolder(playlistId: Int64, trackStableIds: [String]) throws {
        print("🔄 Syncing playlist \(playlistId) with folder tracks (additive-only sync)")

        try write { db in
            // Get current playlist items
            let currentItems = try PlaylistItem.filter(Column("playlist_id") == playlistId).fetchAll(db)
            let currentTrackIds = Set(currentItems.map { $0.trackStableId })
            let newTrackIds = Set(trackStableIds)

            // Only add tracks that are in the folder but not in the playlist
            // This preserves user additions and doesn't remove files (files deleted from
            // library will be cleaned up automatically by database constraints)
            let tracksToAdd = newTrackIds.subtracting(currentTrackIds)

            print("🔄 Folder sync: Adding \(tracksToAdd.count) new tracks from folder")

            // Add new tracks from folder
            let maxPositionQuery = try PlaylistItem
                .filter(Column("playlist_id") == playlistId)
                .select(max(Column("position")))
                .asRequest(of: Int?.self)
                .fetchOne(db)

            let maxPosition: Int
            if let position = maxPositionQuery, let unwrappedPosition = position {
                maxPosition = unwrappedPosition
            } else {
                maxPosition = -1
            }

            var position = maxPosition + 1
            for trackId in tracksToAdd {
                let item = PlaylistItem(playlistId: playlistId, position: position, trackStableId: trackId)
                try item.insert(db)
                position += 1
            }

            // Update last folder sync timestamp
            let now = Int64(Date().timeIntervalSince1970)
            _ = try Playlist
                .filter(Column("id") == playlistId)
                .updateAll(db, Column("last_folder_sync").set(to: now))
        }
    }

    func getFolderSyncedPlaylists() throws -> [Playlist] {
        return try read { db in
            return try Playlist.filter(Column("is_folder_synced") == true).fetchAll(db)
        }
    }

    func updatePlaylistAccessed(playlistId: Int64) throws {
        print("⏰ Database: Updating playlist \(playlistId) last accessed time")
        let now = Int64(Date().timeIntervalSince1970)
        let updatedCount = try write { db in
            return try Playlist
                .filter(Column("id") == playlistId)
                .updateAll(db, Column("updated_at").set(to: now))
        }
        print("⏰ Database: Updated \(updatedCount) playlist(s)")
    }
    
    func updatePlaylistLastPlayed(playlistId: Int64) throws {
        print("🎵 Database: Updating playlist \(playlistId) last played time")
        let now = Int64(Date().timeIntervalSince1970)
        let updatedCount = try write { db in
            return try Playlist
                .filter(Column("id") == playlistId)
                .updateAll(db, Column("last_played_at").set(to: now))
        }
        print("🎵 Database: Updated \(updatedCount) playlist(s) last played time")
    }

    func updatePlaylistCustomCover(playlistId: Int64, imagePath: String?) throws {
        print("🎨 Database: Updating playlist \(playlistId) custom cover to '\(imagePath ?? "nil")'")
        let now = Int64(Date().timeIntervalSince1970)
        let updatedCount = try write { db in
            return try Playlist
                .filter(Column("id") == playlistId)
                .updateAll(db,
                    Column("custom_cover_image_path").set(to: imagePath),
                    Column("updated_at").set(to: now)
                )
        }
        print("🎨 Database: Updated \(updatedCount) playlist(s) custom cover")
    }

    // MARK: - EQ Operations

    func getAllEQPresets() async throws -> [EQPreset] {
        return try read { db in
            return try EQPreset.order(Column("name")).fetchAll(db)
        }
    }

    func getEQPreset(id: Int64) async throws -> EQPreset? {
        return try read { db in
            return try EQPreset.filter(Column("id") == id).fetchOne(db)
        }
    }

    func saveEQPreset(_ preset: EQPreset) async throws -> EQPreset {
        return try write { db in
            return try preset.insertAndFetch(db) ?? preset
        }
    }

    func deleteEQPreset(_ preset: EQPreset) async throws {
        _ = try write { db in
            try preset.delete(db)
        }
    }

    func getBands(for preset: EQPreset) async throws -> [EQBand] {
        guard let presetId = preset.id else { return [] }
        return try read { db in
            return try EQBand
                .filter(Column("preset_id") == presetId)
                .order(Column("band_index"))
                .fetchAll(db)
        }
    }

    func saveEQBand(_ band: EQBand) async throws {
        try write { db in
            try band.save(db)
        }
    }

    func getEQSettings() async throws -> EQSettings? {
        return try read { db in
            return try EQSettings.fetchOne(db)
        }
    }

    func saveEQSettings(_ settings: EQSettings) async throws {
        try write { db in
            // Delete existing settings first (there should only be one row)
            try EQSettings.deleteAll(db)
            try settings.save(db)
        }
    }
}
