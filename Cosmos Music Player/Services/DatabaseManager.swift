//
//  DatabaseManager.swift
//  Cosmos Music Player
//
//  Database manager for the music library using GRDB
//

import Foundation
import CryptoKit
import Combine
import UIKit
@preconcurrency import GRDB

class DatabaseManager: @unchecked Sendable {
    static let shared = DatabaseManager()

    private var dbWriter: DatabaseWriter!
    private let maxRetries = 3
    private let retryDelay: UInt64 = 500_000_000 // 0.5 seconds in nanoseconds

    static func generatePathStableId(forPath path: String) -> String {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let digest = SHA256.hash(data: normalizedPath.data(using: .utf8) ?? Data())
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

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
        // The database lives in the app group container: holding a SQLite file
        // lock there while iOS suspends the process kills the app with
        // 0xdead10cc. DatabaseSuspensionCoordinator posts
        // Database.suspendNotification when the app is about to be suspended.
        configuration.observesSuspensionNotifications = true
        configuration.prepareDatabase { db in
            // Enable foreign key constraints
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        dbWriter = try DatabasePool(path: databaseURL.path, configuration: configuration)
        try createTables()
        try migrateDatabaseIfNeeded()

        // Split combined multi-artist rows ("A; B") left by the old parser
        // (issue #16), then heal libraries where deleted tracks left empty
        // artists/albums behind (issue #74). Both are idempotent and cheap,
        // and run every launch.
        do {
            try migrateSplitCombinedArtistNames()
        } catch {
            print("⚠️ Combined artist split migration failed (non-fatal): \(error)")
        }
        // After artists are split, merge albums that the old per-track-artist
        // keying broke apart (issue #81)
        do {
            try migrateMergeSplitAlbums()
        } catch {
            print("⚠️ Split album merge migration failed (non-fatal): \(error)")
        }
        do {
            try cleanupOrphanedLibraryEntries()
        } catch {
            print("⚠️ Orphaned library cleanup failed (non-fatal): \(error)")
        }
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
                    modification_date INTEGER,
                    replaygain_track_gain REAL,
                    replaygain_album_gain REAL,
                    replaygain_track_peak REAL,
                    replaygain_album_peak REAL,
                    has_embedded_art INTEGER DEFAULT 0
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS track_artist (
                    track_stable_id TEXT NOT NULL,
                    artist_id INTEGER NOT NULL REFERENCES artist(id) ON DELETE CASCADE,
                    position INTEGER NOT NULL,
                    PRIMARY KEY (track_stable_id, artist_id)
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS album_artist_link (
                    album_id INTEGER NOT NULL REFERENCES album(id) ON DELETE CASCADE,
                    artist_id INTEGER NOT NULL REFERENCES artist(id) ON DELETE CASCADE,
                    position INTEGER NOT NULL,
                    PRIMARY KEY (album_id, artist_id)
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
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_track_artist_artist ON track_artist(artist_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_track_artist_track ON track_artist(track_stable_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_album_artist_link_artist ON album_artist_link(artist_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_album_artist_link_album ON album_artist_link(album_id)")
            // Per-import lookups: path duplicate check and stale-duplicate prefilter
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_track_path ON track(path)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_track_dup_check ON track(artist_id, duration_ms, file_size)")

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
        var stableIdRemapping: [String: String] = [:]

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

            // Additive and nullable for compatibility with every existing
            // library. NULL means "not fingerprinted yet" and causes a
            // one-time metadata refresh; no existing rows or relationships
            // are rewritten by this migration.
            if try !db.columns(in: "track").contains(where: { $0.name == "modification_date" }) {
                try db.execute(sql: "ALTER TABLE track ADD COLUMN modification_date INTEGER")
                print("✅ Database: Added modification_date column to track table")
            } else {
                print("ℹ️ Database migration: modification_date column already exists")
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

            do {
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS track_artist (
                        track_stable_id TEXT NOT NULL,
                        artist_id INTEGER NOT NULL REFERENCES artist(id) ON DELETE CASCADE,
                        position INTEGER NOT NULL,
                        PRIMARY KEY (track_stable_id, artist_id)
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_track_artist_artist ON track_artist(artist_id)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_track_artist_track ON track_artist(track_stable_id)")
                try db.execute(sql: """
                    INSERT OR IGNORE INTO track_artist (track_stable_id, artist_id, position)
                    SELECT stable_id, artist_id, 0
                    FROM track
                    WHERE artist_id IS NOT NULL
                """)
                print("✅ Database: Created/backfilled track_artist table")
            } catch {
                print("⚠️ Database migration: track_artist table setup failed: \(error)")
            }

            do {
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS album_artist_link (
                        album_id INTEGER NOT NULL REFERENCES album(id) ON DELETE CASCADE,
                        artist_id INTEGER NOT NULL REFERENCES artist(id) ON DELETE CASCADE,
                        position INTEGER NOT NULL,
                        PRIMARY KEY (album_id, artist_id)
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_album_artist_link_artist ON album_artist_link(artist_id)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_album_artist_link_album ON album_artist_link(album_id)")
                try db.execute(sql: """
                    INSERT OR IGNORE INTO album_artist_link (album_id, artist_id, position)
                    SELECT id, artist_id, 0
                    FROM album
                    WHERE artist_id IS NOT NULL
                """)
                print("✅ Database: Created/backfilled album_artist_link table")
            } catch {
                print("⚠️ Database migration: album_artist_link table setup failed: \(error)")
            }

            // Migration: remove true duplicates that point at the exact same file path.
            // Do not deduplicate by filename; different album folders may legally contain same-named files.
            do {
                let allTracks = try Track.fetchAll(db)
                let groupedByPath = Dictionary(grouping: allTracks, by: { track in
                    URL(fileURLWithPath: track.path).standardizedFileURL.path
                })

                for (path, duplicates) in groupedByPath where duplicates.count > 1 {
                    let sorted = duplicates.sorted { ($0.id ?? 0) > ($1.id ?? 0) }
                    let keep = sorted.first!

                    for duplicate in sorted.dropFirst() {
                        try db.execute(
                            sql: "UPDATE OR IGNORE favorite SET track_stable_id = ? WHERE track_stable_id = ?",
                            arguments: [keep.stableId, duplicate.stableId]
                        )
                        try db.execute(
                            sql: "UPDATE playlist_item SET track_stable_id = ? WHERE track_stable_id = ?",
                            arguments: [keep.stableId, duplicate.stableId]
                        )
                        try db.execute(
                            sql: "UPDATE OR IGNORE track_artist SET track_stable_id = ? WHERE track_stable_id = ?",
                            arguments: [keep.stableId, duplicate.stableId]
                        )
                        try db.execute(sql: "DELETE FROM favorite WHERE track_stable_id = ?", arguments: [duplicate.stableId])
                        try db.execute(sql: "DELETE FROM playlist_item WHERE track_stable_id = ?", arguments: [duplicate.stableId])
                        try db.execute(sql: "DELETE FROM track_artist WHERE track_stable_id = ?", arguments: [duplicate.stableId])
                        try Track.filter(Column("id") == duplicate.id).deleteAll(db)
                    }

                    print("✅ Database: Removed \(duplicates.count - 1) duplicate track row(s) for path: \(path)")
                }
            } catch {
                print("⚠️ Database migration: Path duplicate cleanup failed: \(error)")
            }

            // Migration: filename-based stable IDs collapse same-named songs in different albums.
            // Use normalized full paths so files in different folders remain distinct even with identical filenames.
            do {
                let tracks = try Track.fetchAll(db)
                var updatedCount = 0

                for track in tracks {
                    let newStableId = Self.generatePathStableId(forPath: track.path)

                    guard track.stableId != newStableId else {
                        continue
                    }

                    try db.execute(
                        sql: "UPDATE track SET stable_id = ? WHERE id = ?",
                        arguments: [newStableId, track.id]
                    )

                    try db.execute(
                        sql: "UPDATE OR IGNORE favorite SET track_stable_id = ? WHERE track_stable_id = ?",
                        arguments: [newStableId, track.stableId]
                    )

                    try db.execute(
                        sql: "UPDATE playlist_item SET track_stable_id = ? WHERE track_stable_id = ?",
                        arguments: [newStableId, track.stableId]
                    )

                    try db.execute(
                        sql: "UPDATE OR IGNORE track_artist SET track_stable_id = ? WHERE track_stable_id = ?",
                        arguments: [newStableId, track.stableId]
                    )
                    try db.execute(sql: "DELETE FROM track_artist WHERE track_stable_id = ?", arguments: [track.stableId])

                    stableIdRemapping[track.stableId] = newStableId
                    updatedCount += 1
                }

                if updatedCount > 0 {
                    print("✅ Database: Migrated \(updatedCount) stable IDs from filename-based to path-based")
                } else {
                    print("ℹ️ Database: Stable IDs already path-based")
                }
            } catch {
                print("⚠️ Database migration: Path-based stable ID migration failed: \(error)")
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

        migrateExternalFileBookmarkKeys(stableIdRemapping)
    }

    private func migrateExternalFileBookmarkKeys(_ stableIdRemapping: [String: String]) {
        guard !stableIdRemapping.isEmpty else { return }

        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let bookmarksURL = documentsURL.appendingPathComponent("ExternalFileBookmarks.plist")

        guard FileManager.default.fileExists(atPath: bookmarksURL.path) else { return }

        do {
            let data = try Data(contentsOf: bookmarksURL)
            guard var bookmarks = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Data] else {
                return
            }

            var updatedCount = 0
            for (oldStableId, newStableId) in stableIdRemapping {
                guard let bookmarkData = bookmarks.removeValue(forKey: oldStableId) else {
                    continue
                }

                bookmarks[newStableId] = bookmarkData
                updatedCount += 1
            }

            guard updatedCount > 0 else { return }

            let updatedData = try PropertyListSerialization.data(fromPropertyList: bookmarks, format: .xml, options: 0)
            try updatedData.write(to: bookmarksURL, options: .atomic)
            print("✅ Database: Migrated \(updatedCount) external bookmark stable IDs")
        } catch {
            print("⚠️ Database migration: Failed to migrate external bookmark stable IDs: \(error)")
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
        defer { invalidateArtistDisplayNameCache() }
        try write { db in
            var trackToSave = track

            // A metadata refresh builds a new Track value with the same
            // stable ID. Reuse the existing primary key so GRDB performs an
            // UPDATE, preserving favorites, playlists and every other
            // stable-ID relationship owned by previous app versions.
            if trackToSave.id == nil,
               let existing = try Track
                .filter(Column("stable_id") == trackToSave.stableId)
                .fetchOne(db) {
                trackToSave.id = existing.id
            }

            // Safety check: Remove any duplicates with the same path but different stable_id
            // This handles edge cases where migration didn't run or failed
            let duplicates = try Track.filter(Column("path") == trackToSave.path && Column("stable_id") != trackToSave.stableId).fetchAll(db)
            if !duplicates.isEmpty {
                print("⚠️ Found \(duplicates.count) duplicate(s) for path: \(trackToSave.path)")
                for duplicate in duplicates {
                    // Transfer favorites and playlist items to the new stable_id
                    try db.execute(
                        sql: "UPDATE favorite SET track_stable_id = ? WHERE track_stable_id = ?",
                        arguments: [trackToSave.stableId, duplicate.stableId]
                    )
                    try db.execute(
                        sql: "UPDATE playlist_item SET track_stable_id = ? WHERE track_stable_id = ?",
                        arguments: [trackToSave.stableId, duplicate.stableId]
                    )
                    try db.execute(
                        sql: "UPDATE OR IGNORE track_artist SET track_stable_id = ? WHERE track_stable_id = ?",
                        arguments: [trackToSave.stableId, duplicate.stableId]
                    )
                    try db.execute(sql: "DELETE FROM track_artist WHERE track_stable_id = ?", arguments: [duplicate.stableId])
                    // Delete the duplicate
                    try Track.filter(Column("id") == duplicate.id).deleteAll(db)
                    print("🗑️ Removed duplicate track with old stable_id: \(duplicate.stableId)")
                }
            }

            try trackToSave.save(db)

            try self.cleanupStaleUnplayableDuplicates(db: db, matching: trackToSave)
        }
    }

    private func mergeTrackReferences(db: Database, from oldStableId: String, to newStableId: String) throws {
        try db.execute(
            sql: "UPDATE OR IGNORE favorite SET track_stable_id = ? WHERE track_stable_id = ?",
            arguments: [newStableId, oldStableId]
        )
        try db.execute(
            sql: "UPDATE OR IGNORE playlist_item SET track_stable_id = ? WHERE track_stable_id = ?",
            arguments: [newStableId, oldStableId]
        )
        try db.execute(
            sql: "UPDATE OR IGNORE track_artist SET track_stable_id = ? WHERE track_stable_id = ?",
            arguments: [newStableId, oldStableId]
        )
        try db.execute(sql: "DELETE FROM favorite WHERE track_stable_id = ?", arguments: [oldStableId])
        try db.execute(sql: "DELETE FROM playlist_item WHERE track_stable_id = ?", arguments: [oldStableId])
        try db.execute(sql: "DELETE FROM track_artist WHERE track_stable_id = ?", arguments: [oldStableId])
    }

    private func normalizedDuplicateTitle(_ title: String) -> String {
        title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    private func hasReliableDuplicateMetadata(_ track: Track) -> Bool {
        guard let durationMs = track.durationMs, durationMs > 0,
              let fileSize = track.fileSize, fileSize > 0 else {
            return false
        }

        return !normalizedDuplicateTitle(track.title).isEmpty
    }

    private func isStrictStaleDuplicate(_ stale: Track, of keeper: Track) -> Bool {
        guard stale.stableId != keeper.stableId,
              !FileManager.default.fileExists(atPath: stale.path),
              FileManager.default.fileExists(atPath: keeper.path),
              hasReliableDuplicateMetadata(stale),
              hasReliableDuplicateMetadata(keeper),
              stale.artistId == keeper.artistId,
              stale.durationMs == keeper.durationMs,
              stale.fileSize == keeper.fileSize else {
            return false
        }

        let staleFilename = URL(fileURLWithPath: stale.path).lastPathComponent.lowercased()
        let keeperFilename = URL(fileURLWithPath: keeper.path).lastPathComponent.lowercased()
        return staleFilename == keeperFilename &&
            normalizedDuplicateTitle(stale.title) == normalizedDuplicateTitle(keeper.title)
    }

    private func cleanupStaleUnplayableDuplicates(db: Database, matching newTrack: Track) throws {
        guard hasReliableDuplicateMetadata(newTrack),
              FileManager.default.fileExists(atPath: newTrack.path) else {
            return
        }

        // Prefilter by the strict-duplicate criteria in SQL. Fetching ALL
        // tracks here made every import O(n^2) in rows AND file-exists
        // syscalls - the main cause of watchdog kills on 2000+ file imports
        let tracks = try Track
            .filter(Column("artist_id") == newTrack.artistId
                && Column("duration_ms") == newTrack.durationMs
                && Column("file_size") == newTrack.fileSize
                && Column("stable_id") != newTrack.stableId)
            .fetchAll(db)
        for stale in tracks where isStrictStaleDuplicate(stale, of: newTrack) {
            try self.mergeTrackReferences(db: db, from: stale.stableId, to: newTrack.stableId)
            try Track.filter(Column("stable_id") == stale.stableId).deleteAll(db)
            print("🗑️ Removed strict stale duplicate: \(stale.title) at \(stale.path)")
        }
    }

    func cleanupStrictStaleDuplicatesForImportedTracks() throws {
        try write { db in
            let tracks = try Track.fetchAll(db)
            let existingRows = tracks.filter {
                FileManager.default.fileExists(atPath: $0.path) && self.hasReliableDuplicateMetadata($0)
            }
            let missingRows = tracks.filter {
                !FileManager.default.fileExists(atPath: $0.path) && self.hasReliableDuplicateMetadata($0)
            }

            for stale in missingRows {
                guard let keeper = existingRows.first(where: { self.isStrictStaleDuplicate(stale, of: $0) }) else {
                    continue
                }

                try self.mergeTrackReferences(db: db, from: stale.stableId, to: keeper.stableId)
                try Track.filter(Column("stable_id") == stale.stableId).deleteAll(db)
                print("🗑️ Removed strict stale duplicate after import: \(stale.title) at \(stale.path)")
            }
        }
    }

    func migrateTrackStableIdAndPath(oldStableId: String, newStableId: String, newPath: String) throws {
        try write { db in
            guard var oldTrack = try Track.filter(Column("stable_id") == oldStableId).fetchOne(db) else {
                return
            }

            if var existingNewTrack = try Track.filter(Column("stable_id") == newStableId).fetchOne(db) {
                existingNewTrack.path = newPath
                try existingNewTrack.update(db)
                try self.mergeTrackReferences(db: db, from: oldStableId, to: newStableId)
                try Track.filter(Column("stable_id") == oldStableId).deleteAll(db)
                print("🔁 Merged stale track ID \(oldStableId) into existing resolved ID \(newStableId)")
                return
            }

            oldTrack.stableId = newStableId
            oldTrack.path = newPath
            try oldTrack.update(db)
            try self.mergeTrackReferences(db: db, from: oldStableId, to: newStableId)
            print("🔁 Migrated track ID for moved file: \(oldStableId) -> \(newStableId)")
        }
    }

    func getTrack(byPath path: String) throws -> Track? {
        let standardizedPath = Self.standardizedPath(path)
        return try read { db in
            if let exact = try Track.filter(Column("path") == path).fetchOne(db) {
                return exact
            }

            if standardizedPath != path,
               let standardized = try Track.filter(Column("path") == standardizedPath).fetchOne(db) {
                return standardized
            }

            // Preserve compatibility for older rows whose stored URL spelling
            // differs from Foundation's standardized path representation.
            let tracks = try Track.fetchAll(db)
            return tracks.first { Self.standardizedPath($0.path) == standardizedPath }
        }
    }

    func setTrackArtists(trackStableId: String, artistIds: [Int64]) throws {
        defer { invalidateArtistDisplayNameCache() }
        try write { db in
            try db.execute(sql: "DELETE FROM track_artist WHERE track_stable_id = ?", arguments: [trackStableId])

            for (position, artistId) in artistIds.enumerated() {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO track_artist (track_stable_id, artist_id, position)
                        VALUES (?, ?, ?)
                    """,
                    arguments: [trackStableId, artistId, position]
                )
            }
        }
    }

    func setAlbumArtists(albumId: Int64, artistIds: [Int64]) throws {
        try write { db in
            try db.execute(sql: "DELETE FROM album_artist_link WHERE album_id = ?", arguments: [albumId])

            for (position, artistId) in artistIds.enumerated() {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO album_artist_link (album_id, artist_id, position)
                        VALUES (?, ?, ?)
                    """,
                    arguments: [albumId, artistId, position]
                )
            }
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

    func upsertAlbum(title: String, artistId: Int64?, year: Int?, albumArtist: String?, candidateArtistIds: [Int64] = []) throws -> Album {
        return try write { db in
            let normalizedTitle = self.normalizeAlbumTitle(title)

            // Match albums by title and primary artist. The same album title can exist for different artists.
            if let existing = try Album
                .filter(Column("title") == normalizedTitle && Column("artist_id") == artistId)
                .fetchOne(db) {
                return existing
            }

            // If no exact match, try case-insensitive and similar matches.
            // Only albums by this track's artists can match anyway, so
            // filter in SQL instead of fetching every album per track
            // (that scan made large imports quadratic)
            var relevantArtistIds = Set(candidateArtistIds)
            if let artistId { relevantArtistIds.insert(artistId) }
            let existingAlbums = try Album
                .filter(relevantArtistIds.contains(Column("artist_id")))
                .fetchAll(db)

            for existing in existingAlbums {
                let existingNormalized = self.normalizeAlbumTitle(existing.title)

                // Match by normalized title (case-insensitive)
                guard existing.artistId == artistId else { continue }

                if existingNormalized.lowercased() == normalizedTitle.lowercased() {
                    return existing
                }

                // Check for very similar titles (minor differences)
                if self.areSimilarTitles(existingNormalized, normalizedTitle) {
                    return existing
                }
            }

            // Fallback: a same-titled album whose primary artist is any of this
            // track's artists. Groups featured tracks (whose primary artist
            // differs, e.g. "Guest; Main") into the main album instead of
            // spawning one album per collab string (issue #81)
            if !candidateArtistIds.isEmpty {
                let candidates = Set(candidateArtistIds)
                for existing in existingAlbums {
                    guard let existingArtistId = existing.artistId,
                          candidates.contains(existingArtistId) else { continue }
                    // Same title but conflicting years = genuinely different albums
                    if let existingYear = existing.year, let year, existingYear != year { continue }

                    let existingNormalized = self.normalizeAlbumTitle(existing.title)
                    if existingNormalized.lowercased() == normalizedTitle.lowercased() ||
                        self.areSimilarTitles(existingNormalized, normalizedTitle) {
                        return existing
                    }
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

    func getAlbumsByArtistId(_ artistId: Int64) throws -> [Album] {
        return try read { db in
            return try Album.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT album.*
                    FROM album
                    LEFT JOIN album_artist_link ON album_artist_link.album_id = album.id
                    WHERE album.artist_id = ? OR album_artist_link.artist_id = ?
                    ORDER BY album.title
                """,
                arguments: [artistId, artistId]
            )
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

    // SwiftUI rows call getArtistDisplayName on every render - cache the
    // joined names so scrolling doesn't hit the database per visible row
    private let artistDisplayNameCacheLock = NSLock()
    private var artistDisplayNameCache: [String: String] = [:]

    func invalidateArtistDisplayNameCache() {
        artistDisplayNameCacheLock.lock()
        artistDisplayNameCache.removeAll()
        artistDisplayNameCacheLock.unlock()
    }

    func getArtistDisplayName(forTrackStableId stableId: String, fallbackArtistId: Int64?) throws -> String? {
        artistDisplayNameCacheLock.lock()
        let cached = artistDisplayNameCache[stableId]
        artistDisplayNameCacheLock.unlock()
        if let cached { return cached }

        return try read { db in
            let names = try String.fetchAll(
                db,
                sql: """
                    SELECT artist.name
                    FROM track_artist
                    JOIN artist ON artist.id = track_artist.artist_id
                    WHERE track_artist.track_stable_id = ?
                    ORDER BY track_artist.position
                """,
                arguments: [stableId]
            )

            if !names.isEmpty {
                let display = names.joined(separator: " / ")
                self.artistDisplayNameCacheLock.lock()
                self.artistDisplayNameCache[stableId] = display
                self.artistDisplayNameCacheLock.unlock()
                return display
            }

            // Fallback results depend on fallbackArtistId, so don't cache them
            guard let fallbackArtistId else { return nil }
            return try Artist.fetchOne(db, key: fallbackArtistId)?.name
        }
    }

    func getArtistDisplayNames(
        forTrackStableIds stableIds: [String],
        fallbackArtistIdsByStableId: [String: Int64] = [:]
    ) throws -> [String: String] {
        guard !stableIds.isEmpty else { return [:] }

        artistDisplayNameCacheLock.lock()
        let cachedValues = stableIds.reduce(into: [String: String]()) { result, stableId in
            if let cached = artistDisplayNameCache[stableId] {
                result[stableId] = cached
            }
        }
        artistDisplayNameCacheLock.unlock()

        let missingStableIds = stableIds.filter { cachedValues[$0] == nil }
        guard !missingStableIds.isEmpty else { return cachedValues }

        var result = cachedValues

        try read { db in
            var groupedNames: [String: [String]] = [:]
            let chunkSize = 500

            for start in stride(from: 0, to: missingStableIds.count, by: chunkSize) {
                let end = min(start + chunkSize, missingStableIds.count)
                let chunk = Array(missingStableIds[start..<end])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")

                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT track_artist.track_stable_id AS stable_id, artist.name AS artist_name
                        FROM track_artist
                        JOIN artist ON artist.id = track_artist.artist_id
                        WHERE track_artist.track_stable_id IN (\(placeholders))
                        ORDER BY track_artist.track_stable_id, track_artist.position
                    """,
                    arguments: StatementArguments(chunk)
                )

                for row in rows {
                    let stableId: String = row["stable_id"]
                    let artistName: String = row["artist_name"]
                    groupedNames[stableId, default: []].append(artistName)
                }
            }

            for (stableId, names) in groupedNames where !names.isEmpty {
                result[stableId] = names.joined(separator: " / ")
            }

            let fallbackArtistIds = Set(missingStableIds.compactMap { stableId in
                result[stableId] == nil ? fallbackArtistIdsByStableId[stableId] : nil
            })

            if !fallbackArtistIds.isEmpty {
                let artists = try Artist
                    .filter(fallbackArtistIds.contains(Column("id")))
                    .fetchAll(db)
                let namesById = Dictionary(uniqueKeysWithValues: artists.compactMap { artist in
                    artist.id.map { ($0, artist.name) }
                })

                for stableId in missingStableIds where result[stableId] == nil {
                    if let artistId = fallbackArtistIdsByStableId[stableId],
                       let name = namesById[artistId] {
                        result[stableId] = name
                    }
                }
            }
        }

        artistDisplayNameCacheLock.lock()
        for (stableId, displayName) in result {
            artistDisplayNameCache[stableId] = displayName
        }
        artistDisplayNameCacheLock.unlock()

        return result
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
            return try Track.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT track.*
                    FROM track
                    LEFT JOIN track_artist ON track_artist.track_stable_id = track.stable_id
                    WHERE track.artist_id = ? OR track_artist.artist_id = ?
                    ORDER BY track.title
                """,
                arguments: [artistId, artistId]
            )
        }
    }

    // MARK: - Search operations

    private func rankedTrackSearch(in db: Database, query: String, limit: Int?) throws -> [Track] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            var request = Track.order(Column("title"))
            if let limit { request = request.limit(limit) }
            return try request.fetchAll(db)
        }

        let literalRequest = Track
            .filter(Column("title").like("%\(trimmed)%"))
            .order(Column("title"))
        let literal = try (limit.map { literalRequest.limit($0) } ?? literalRequest).fetchAll(db)
        if !literal.isEmpty { return literal }

        // Siri transcription and spelling errors rarely survive a SQL LIKE.
        // Rank the full library only after the cheap literal lookup misses.
        let ranked = try Track.fetchAll(db).map { track in
            (track: track, score: trimmed.cosmosSearchSimilarity(to: track.title))
        }
        .filter { $0.score >= 0.58 }
        .sorted {
            if abs($0.score - $1.score) > 0.0001 { return $0.score > $1.score }
            return $0.track.title.localizedCaseInsensitiveCompare($1.track.title) == .orderedAscending
        }

        let best = ranked.first?.score ?? 0
        let closeMatches = ranked.filter { $0.score >= max(0.58, best - 0.10) }.map(\.track)
        return Array(closeMatches.prefix(limit ?? 5))
    }

    func searchTracks(query: String) throws -> [Track] {
        return try read { db in
            try self.rankedTrackSearch(in: db, query: query, limit: nil)
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
        defer { invalidateArtistDisplayNameCache() }
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

            // Remove multi-artist link rows - track_artist has no FK to track,
            // so these do NOT cascade. Leaving them kept deleted tracks'
            // artists alive forever (issue #74)
            try db.execute(sql: "DELETE FROM track_artist WHERE track_stable_id = ?", arguments: [stableId])

            // Delete the track
            return try Track.filter(Column("stable_id") == stableId).deleteAll(db)
        }
        print("🗃️ Database: Deleted \(deletedCount) track(s)")

        // Clean up orphaned albums and artists after track deletion
        try cleanupOrphanedLibraryEntries()

        // Remove stored bookmark so the file won't be re-imported
        removeExternalFileBookmark(for: stableId)
    }

    private func removeExternalFileBookmark(for stableId: String) {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let bookmarksURL = documentsURL.appendingPathComponent("ExternalFileBookmarks.plist")

        guard FileManager.default.fileExists(atPath: bookmarksURL.path) else { return }

        do {
            let data = try Data(contentsOf: bookmarksURL)
            guard var bookmarks = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Data] else { return }

            guard bookmarks.removeValue(forKey: stableId) != nil else { return }

            let plistData = try PropertyListSerialization.data(fromPropertyList: bookmarks, format: .xml, options: 0)
            try plistData.write(to: bookmarksURL)
            print("🔖 Removed external file bookmark for stableId: \(stableId)")
        } catch {
            print("⚠️ Failed to remove external file bookmark: \(error.localizedDescription)")
        }
    }

    /// Repairs libraries indexed before multi-artist splitting: artist rows
    /// like "A; B" or "A\\B" are split into individual artists and every
    /// reference re-linked (issue #16). Idempotent - split rows are deleted,
    /// so later launches find nothing to do.
    func migrateSplitCombinedArtistNames() throws {
        defer { invalidateArtistDisplayNameCache() }
        try write { db in
            let combinedArtists = try Artist.fetchAll(db).filter {
                $0.name.contains(";") || $0.name.contains("\\\\")
            }

            for combinedArtist in combinedArtists {
                guard let combinedId = combinedArtist.id else { continue }

                // Same separators as LibraryIndexer.parseArtistNames
                var parts = [combinedArtist.name]
                for delimiter in [";", "\\\\", "\u{0}"] {
                    parts = parts.flatMap { $0.components(separatedBy: delimiter) }
                }
                var seen = Set<String>()
                let names: [String] = parts.compactMap {
                    let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    let key = trimmed.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                    guard !trimmed.isEmpty, !seen.contains(key) else { return nil }
                    seen.insert(key)
                    return trimmed
                }
                guard names.count > 1 else { continue }

                var artistIds: [Int64] = []
                for name in names {
                    if let existing = try Artist.filter(Column("name") == name).fetchOne(db),
                       let id = existing.id {
                        artistIds.append(id)
                    } else if let inserted = try Artist(name: name).insertAndFetch(db),
                              let id = inserted.id {
                        artistIds.append(id)
                    }
                }
                guard let primaryId = artistIds.first else { continue }

                // Re-link track_artist rows to the individual artists
                let trackRows = try Row.fetchAll(
                    db,
                    sql: "SELECT track_stable_id, position FROM track_artist WHERE artist_id = ?",
                    arguments: [combinedId]
                )
                for row in trackRows {
                    let stableId: String = row["track_stable_id"]
                    let basePosition: Int = row["position"]
                    for (index, artistId) in artistIds.enumerated() {
                        try db.execute(
                            sql: "INSERT OR IGNORE INTO track_artist (track_stable_id, artist_id, position) VALUES (?, ?, ?)",
                            arguments: [stableId, artistId, basePosition * 100 + index]
                        )
                    }
                }
                try db.execute(sql: "DELETE FROM track_artist WHERE artist_id = ?", arguments: [combinedId])

                // Re-link album_artist_link rows
                let albumRows = try Row.fetchAll(
                    db,
                    sql: "SELECT album_id, position FROM album_artist_link WHERE artist_id = ?",
                    arguments: [combinedId]
                )
                for row in albumRows {
                    let albumId: Int64 = row["album_id"]
                    let basePosition: Int = row["position"]
                    for (index, artistId) in artistIds.enumerated() {
                        try db.execute(
                            sql: "INSERT OR IGNORE INTO album_artist_link (album_id, artist_id, position) VALUES (?, ?, ?)",
                            arguments: [albumId, artistId, basePosition * 100 + index]
                        )
                    }
                }
                try db.execute(sql: "DELETE FROM album_artist_link WHERE artist_id = ?", arguments: [combinedId])

                // Repoint primary references BEFORE deleting the combined row:
                // album.artist_id cascades on artist deletion, so a stale
                // reference would take whole albums down with it
                try db.execute(sql: "UPDATE track SET artist_id = ? WHERE artist_id = ?", arguments: [primaryId, combinedId])
                try db.execute(sql: "UPDATE album SET artist_id = ? WHERE artist_id = ?", arguments: [primaryId, combinedId])

                try db.execute(sql: "DELETE FROM artist WHERE id = ?", arguments: [combinedId])
                print("🎤 Split combined artist '\(combinedArtist.name)' into: \(names.joined(separator: ", "))")
            }
        }
    }

    /// Merges albums that were split because their tracks' artist strings
    /// differed (featured guests - issue #81): same normalized title, at
    /// least one shared artist, and no conflicting year. Keeps the entry
    /// with the most tracks. Idempotent - merged duplicates are deleted.
    func migrateMergeSplitAlbums() throws {
        try write { db in
            let albums = try Album.fetchAll(db)
            var groups: [String: [Album]] = [:]
            for album in albums {
                groups[self.normalizeAlbumTitle(album.title).lowercased(), default: []].append(album)
            }

            for (_, group) in groups where group.count > 1 {
                // An album's full artist set: primary artist, linked album
                // artists, and every artist credited on its tracks
                func artistSet(for albumId: Int64, primary: Int64?) throws -> Set<Int64> {
                    var ids = Set(try Int64.fetchAll(db, sql: """
                        SELECT artist_id FROM album_artist_link WHERE album_id = ?
                        UNION SELECT artist_id FROM track WHERE album_id = ? AND artist_id IS NOT NULL
                        UNION SELECT ta.artist_id FROM track_artist ta
                              JOIN track t ON t.stable_id = ta.track_stable_id
                              WHERE t.album_id = ?
                    """, arguments: [albumId, albumId, albumId]))
                    if let primary { ids.insert(primary) }
                    return ids
                }

                let ranked: [(album: Album, trackCount: Int)] = try group.compactMap { album in
                    guard let id = album.id else { return nil }
                    let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track WHERE album_id = ?", arguments: [id]) ?? 0
                    return (album, count)
                }.sorted { $0.trackCount > $1.trackCount }

                guard let keeper = ranked.first, let keeperId = keeper.album.id else { continue }
                var keeperArtists = try artistSet(for: keeperId, primary: keeper.album.artistId)

                for entry in ranked.dropFirst() {
                    guard let dupId = entry.album.id else { continue }
                    let dupArtists = try artistSet(for: dupId, primary: entry.album.artistId)
                    // Only merge albums that share an artist - same-titled
                    // albums by unrelated artists are legitimately separate
                    guard !keeperArtists.isDisjoint(with: dupArtists) else { continue }
                    if let keeperYear = keeper.album.year, let dupYear = entry.album.year,
                       keeperYear != dupYear { continue }

                    try db.execute(sql: "UPDATE track SET album_id = ? WHERE album_id = ?", arguments: [keeperId, dupId])
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO album_artist_link (album_id, artist_id, position)
                        SELECT ?, artist_id, position + 1000 FROM album_artist_link WHERE album_id = ?
                    """, arguments: [keeperId, dupId])
                    try db.execute(sql: "DELETE FROM album WHERE id = ?", arguments: [dupId])
                    keeperArtists.formUnion(dupArtists)
                    print("💿 Merged split album '\(entry.album.title)' into '\(keeper.album.title)'")
                }
            }
        }
    }

    /// Purges stale link rows, empty albums, and artists nothing references.
    /// Runs after every track deletion and once at startup, so libraries
    /// damaged by the old deleteTrack (which leaked track_artist rows and
    /// kept empty artists alive - issue #74) heal on next launch.
    func cleanupOrphanedLibraryEntries() throws {
        try write { db in
            // Link rows for tracks that no longer exist - track_artist has no
            // FK to track, so these never cascade and must be purged manually
            try db.execute(sql: """
                DELETE FROM track_artist
                WHERE track_stable_id NOT IN (SELECT stable_id FROM track)
            """)

            // Delete albums that have no tracks referencing them
            try db.execute(sql: """
                DELETE FROM album
                WHERE id NOT IN (
                    SELECT DISTINCT album_id
                    FROM track
                    WHERE album_id IS NOT NULL
                )
            """)

            // Link rows for albums that no longer exist - the FK cascade
            // covers this when foreign keys are on, but don't rely on it
            // (older app versions may have written without the pragma)
            try db.execute(sql: """
                DELETE FROM album_artist_link
                WHERE album_id NOT IN (SELECT id FROM album)
            """)

            // Delete artists that have no tracks referencing them
            try db.execute(sql: """
                DELETE FROM artist
                WHERE id NOT IN (
                    SELECT DISTINCT artist_id
                    FROM track
                    WHERE artist_id IS NOT NULL
                    UNION
                    SELECT DISTINCT artist_id
                    FROM track_artist
                    UNION
                    SELECT DISTINCT artist_id
                    FROM album_artist_link
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
            try self.rankedTrackSearch(in: db, query: query, limit: limit)
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

    func getAllFolderPlaylists() throws -> [Playlist] {
        return try read { db in
            try Playlist.filter(Column("is_folder_synced") == true).fetchAll(db)
        }
    }

    /// Clears the "don't recreate" tombstones so folder playlists come back
    /// on the next scan when the user re-enables auto-creation
    func clearDeletedFolderPlaylistTombstones() throws {
        try write { db in
            try db.execute(sql: "DELETE FROM deleted_folder_playlist")
        }
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

private extension String {
    var cosmosSearchNormalized: String {
        let folded = folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        let searchable = folded.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }
            .joined()
        return searchable
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .joined(separator: " ")
    }

    func cosmosSearchSimilarity(to other: String) -> Double {
        let left = Array(cosmosSearchNormalized)
        let right = Array(other.cosmosSearchNormalized)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let leftString = String(left)
        let rightString = String(right)
        if leftString == rightString { return 1 }
        if rightString.contains(leftString) { return 0.95 }

        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1] + Array(repeating: 0, count: right.count)
            for (rightIndex, rightCharacter) in right.enumerated() {
                current[rightIndex + 1] = Swift.min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                )
            }
            previous = current
        }
        return 1 - Double(previous[right.count]) / Double(max(left.count, right.count))
    }
}

// MARK: - Suspension coordination (0xdead10cc)

/// Suspends GRDB when the app is about to be suspended by iOS.
///
/// The database lives in the app group container. If SQLite still holds a
/// file lock when the process is suspended, the kernel kills the app with
/// 0xdead10cc - the most frequent crash across all shipped versions.
///
/// Background audio keeps the process alive and legitimately writing (play
/// counts, queue state), so the database is only suspended while the app is
/// backgrounded AND playback is stopped. It resumes on foregrounding or when
/// playback restarts (e.g. from the lock screen or a remote command).
@MainActor
final class DatabaseSuspensionCoordinator {
    static let shared = DatabaseSuspensionCoordinator()

    private var observers: [NSObjectProtocol] = []
    private var playbackCancellable: AnyCancellable?
    private var isInBackground = false
    private var isPlaying = false
    private var isSuspended = false

    private init() {}

    func start() {
        guard observers.isEmpty else { return }

        let backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { @Sendable _ in
            Task { @MainActor in
                let coordinator = DatabaseSuspensionCoordinator.shared
                coordinator.isInBackground = true
                coordinator.apply()
            }
        }
        observers.append(backgroundObserver)

        let foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { @Sendable _ in
            Task { @MainActor in
                let coordinator = DatabaseSuspensionCoordinator.shared
                coordinator.isInBackground = false
                coordinator.apply()
            }
        }
        observers.append(foregroundObserver)

        isPlaying = PlayerEngine.shared.isPlaying
        playbackCancellable = PlayerEngine.shared.$isPlaying
            .removeDuplicates()
            .sink { playing in
                Task { @MainActor in
                    let coordinator = DatabaseSuspensionCoordinator.shared
                    coordinator.isPlaying = playing
                    coordinator.apply()
                }
            }
    }

    private func apply() {
        let shouldSuspend = isInBackground && !isPlaying
        guard shouldSuspend != isSuspended else { return }
        isSuspended = shouldSuspend
        NotificationCenter.default.post(
            name: shouldSuspend ? Database.suspendNotification : Database.resumeNotification,
            object: nil
        )
        print(shouldSuspend
            ? "🛑 Database suspended (backgrounded, not playing)"
            : "▶️ Database resumed")
    }
}
