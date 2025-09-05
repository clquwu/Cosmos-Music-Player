//
//  DatabaseModels.swift
//  Cosmos Music Player
//
//  Database models for the music library
//

import Foundation
@preconcurrency import GRDB

struct Artist: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var name: String
    
    static let databaseTableName = "artist"
    
    nonisolated(unsafe) static let tracks = hasMany(Track.self)
    nonisolated(unsafe) static let albums = hasMany(Album.self)
}

struct Album: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var artistId: Int64?
    var title: String
    var year: Int?
    var albumArtist: String?
    
    static let databaseTableName = "album"
    
    nonisolated(unsafe) static let artist = belongsTo(Artist.self)
    nonisolated(unsafe) static let tracks = hasMany(Track.self)
    
    enum CodingKeys: String, CodingKey {
        case id, title, year
        case artistId = "artist_id"
        case albumArtist = "album_artist"
    }
}

struct Track: Codable, FetchableRecord, PersistableRecord, Equatable {
    var id: Int64?
    var stableId: String
    var albumId: Int64?
    var artistId: Int64?
    var title: String
    var trackNo: Int?
    var discNo: Int?
    var durationMs: Int?
    var sampleRate: Int?
    var bitDepth: Int?
    var channels: Int?
    var path: String
    var fileSize: Int64?
    var replaygainTrackGain: Double?
    var replaygainAlbumGain: Double?
    var replaygainTrackPeak: Double?
    var replaygainAlbumPeak: Double?
    var hasEmbeddedArt: Bool = false
    
    static let databaseTableName = "track"
    
    nonisolated(unsafe) static let artist = belongsTo(Artist.self)
    nonisolated(unsafe) static let album = belongsTo(Album.self)
    
    enum CodingKeys: String, CodingKey {
        case id, title, path
        case stableId = "stable_id"
        case albumId = "album_id"
        case artistId = "artist_id"
        case trackNo = "track_no"
        case discNo = "disc_no"
        case durationMs = "duration_ms"
        case sampleRate = "sample_rate"
        case bitDepth = "bit_depth"
        case channels, fileSize = "file_size"
        case replaygainTrackGain = "replaygain_track_gain"
        case replaygainAlbumGain = "replaygain_album_gain"
        case replaygainTrackPeak = "replaygain_track_peak"
        case replaygainAlbumPeak = "replaygain_album_peak"
        case hasEmbeddedArt = "has_embedded_art"
    }
}

struct Favorite: Codable, FetchableRecord, PersistableRecord {
    var trackStableId: String
    
    static let databaseTableName = "favorite"
    
    enum CodingKeys: String, CodingKey {
        case trackStableId = "track_stable_id"
    }
}

struct Playlist: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var slug: String
    var title: String
    var createdAt: Int64
    var updatedAt: Int64
    var lastPlayedAt: Int64
    
    static let databaseTableName = "playlist"
    
    nonisolated(unsafe) static let items = hasMany(PlaylistItem.self)
    
    enum CodingKeys: String, CodingKey {
        case id, slug, title
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastPlayedAt = "last_played_at"
    }
}

struct PlaylistItem: Codable, FetchableRecord, PersistableRecord {
    var playlistId: Int64
    var position: Int
    var trackStableId: String
    
    static let databaseTableName = "playlist_item"
    
    nonisolated(unsafe) static let playlist = belongsTo(Playlist.self)
    
    enum CodingKeys: String, CodingKey {
        case position
        case playlistId = "playlist_id"
        case trackStableId = "track_stable_id"
    }
}