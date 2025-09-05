//
//  DatabaseManager.swift
//  Cosmos Music Player
//
//  Database manager for the music library using GRDB
//

import Foundation
@preconcurrency import GRDB

class DatabaseManager: @unchecked Sendable {
    static let shared = DatabaseManager()
    
    private var dbWriter: DatabaseWriter!
    
    private init() {
        setupDatabase()
    }
    
    private func setupDatabase() {
        do {
            let databaseURL = try getDatabaseURL()
            dbWriter = try DatabaseQueue(path: databaseURL.path)
            try createTables()
        } catch {
            fatalError("Failed to setup database: \(error)")
        }
    }
    
    private func getDatabaseURL() throws -> URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory,
                                                   in: .userDomainMask).first!
        return documentsPath.appendingPathComponent("MusicLibrary.sqlite")
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
                    last_played_at INTEGER DEFAULT 0
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
            
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_track_album ON track(album_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_track_artist ON track(artist_id)")
            
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
        let clean1 = title1.lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
        let clean2 = title2.lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
        
        // If they're identical after removing all non-alphanumeric characters, consider them the same
        if clean1 == clean2 {
            return true
        }
        
        // Check if one is a substring of the other (for cases like "Album" vs "Album - Extended")
        if clean1.contains(clean2) || clean2.contains(clean1) {
            let lengthDiff = abs(clean1.count - clean2.count)
            // Only consider similar if the difference is small
            return lengthDiff <= 10
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
    
    func deleteTrack(byStableId stableId: String) throws {
        print("🗃️ Database: Deleting track with stable ID - \(stableId)")
        let deletedCount = try write { db in
            return try Track.filter(Column("stable_id") == stableId).deleteAll(db)
        }
        print("🗃️ Database: Deleted \(deletedCount) track(s)")
    }
    
    // MARK: - Playlist operations
    
    func createPlaylist(title: String) throws -> Playlist {
        return try write { db in
            let slug = title.lowercased().replacingOccurrences(of: " ", with: "-")
            let now = Int64(Date().timeIntervalSince1970)
            let playlist = Playlist(id: nil, slug: slug, title: title, createdAt: now, updatedAt: now, lastPlayedAt: 0)
            return try playlist.insertAndFetch(db)!
        }
    }
    
    func getAllPlaylists() throws -> [Playlist] {
        return try read { db in
            return try Playlist.order(Column("last_played_at").desc, Column("updated_at").desc).fetchAll(db)
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
            return try Playlist.filter(Column("id") == playlistId).deleteAll(db)
        }
        print("🗑️ Database: Deleted \(deletedCount) playlist(s)")
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
}
