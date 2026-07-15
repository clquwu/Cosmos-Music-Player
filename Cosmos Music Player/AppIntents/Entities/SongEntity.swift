//
//  SongEntity.swift
//  Cosmos Music Player
//
//  Assistant-schema song entity backed by the GRDB Track model. The entity id
//  is the track's stableId so it survives database rebuilds.
//

#if canImport(MediaIntents)
import AppIntents
import CoreSpotlight
import Foundation

@available(iOS 27.0, *)
@AppEntity(schema: .audio.song)
struct SongEntity: IndexedEntity {
    static let defaultQuery = SongQuery()

    // MARK: Schema properties

    var title: String
    var artistName: String
    var albumTitle: String?
    var composerName: String?
    var internationalStandardRecordingCode: String?
    var album: AlbumEntity?
    var artists: [ArtistEntity]
    var composers: [ArtistEntity]
    var duration: TimeInterval

    // MARK: Entity properties

    let id: String

    var displayRepresentation: DisplayRepresentation {
        let synonyms: [LocalizedStringResource] = [
            "\(title) by \(artistName)"
        ]
        return DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(artistName)",
            image: DisplayRepresentation.Image(systemName: "music.note"),
            synonyms: synonyms
        )
    }

    // The @AppEntity macro turns most schema properties into init-accessor
    // properties whose accessors read the plain stored `duration`, so it
    // must be initialized first.
    init(track: Track, artistName: String, album: AlbumEntity?) {
        id = track.stableId
        duration = TimeInterval(track.durationMs ?? 0) / 1000.0
        self.album = album
        artists = [ArtistEntity(name: artistName)]
        composers = []
        title = track.title
        self.artistName = artistName
        albumTitle = album?.title
        composerName = nil
        internationalStandardRecordingCode = nil
    }
}

@available(iOS 27.0, *)
extension SongEntity: Equatable, Hashable {
    static func == (lhs: SongEntity, rhs: SongEntity) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - SongQuery

@available(iOS 27.0, *)
struct SongQuery {
    @Dependency var store: IntentEntityStore
}

@available(iOS 27.0, *)
extension SongQuery: EntityQuery {
    func entities(for identifiers: [SongEntity.ID]) async throws -> [SongEntity] {
        SiriDiag.log("APP SongQuery.entities(for:) ids=\(identifiers)")
        return try await store.songEntities(for: identifiers)
    }

    func suggestedEntities() async throws -> [SongEntity] {
        try await store.suggestedSongEntities()
    }
}

@available(iOS 27.0, *)
extension SongQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [SongEntity] {
        let results = try await store.songEntities(matching: string)
        SiriDiag.log("APP SongQuery.entities(matching:) query=\(string) results=\(results.count)")
        return results
    }
}

@available(iOS 27.0, *)
extension SongQuery: IndexedEntityQuery {
    func reindexEntities(
        for identifiers: [String],
        indexDescription: CSSearchableIndexDescription
    ) async throws {
        let entities = try await store.songEntities(for: identifiers)
        try await CSSearchableIndex(name: SpotlightLibraryIndexer.indexName).indexAppEntities(entities)
    }

    func reindexAllEntities(
        indexDescription: CSSearchableIndexDescription
    ) async throws {
        let entities = try await store.allSongEntities()
        try await CSSearchableIndex(name: SpotlightLibraryIndexer.indexName).indexAppEntities(entities)
    }
}

#endif // canImport(MediaIntents)
