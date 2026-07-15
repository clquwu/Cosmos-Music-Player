//
//  AlbumEntity.swift
//  Cosmos Music Player
//
//  Assistant-schema album entity backed by the GRDB Album model.
//

#if canImport(MediaIntents)
import AppIntents
import CoreSpotlight
import Foundation

@available(iOS 27.0, *)
@AppEntity(schema: .audio.album)
struct AlbumEntity: IndexedEntity {
    static let defaultQuery = AlbumQuery()

    // MARK: Schema properties

    var title: String
    var artistName: String
    var artists: [ArtistEntity]
    var songs: [SongEntity]
    var universalProductCode: String?

    // MARK: Entity properties

    let id: String

    var displayRepresentation: DisplayRepresentation {
        let synonyms: [LocalizedStringResource] = [
            "album \(title)",
            "\(title) by \(artistName)"
        ]
        return DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(artistName)",
            image: DisplayRepresentation.Image(systemName: "opticaldisc"),
            synonyms: synonyms
        )
    }

    /// `songs` stays empty on the shallow path to avoid song/album cycles.
    init(album: Album, artistName: String, songs: [SongEntity] = []) {
        id = String(album.id ?? 0)
        self.songs = songs
        title = album.title
        self.artistName = artistName
        artists = [ArtistEntity(name: artistName)]
        universalProductCode = nil
    }
}

@available(iOS 27.0, *)
extension AlbumEntity: Equatable, Hashable {
    static func == (lhs: AlbumEntity, rhs: AlbumEntity) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - AlbumQuery

@available(iOS 27.0, *)
struct AlbumQuery {
    @Dependency var store: IntentEntityStore
}

@available(iOS 27.0, *)
extension AlbumQuery: EntityQuery {
    func entities(for identifiers: [AlbumEntity.ID]) async throws -> [AlbumEntity] {
        try await store.albumEntities(for: identifiers)
    }

    func suggestedEntities() async throws -> [AlbumEntity] {
        try await store.allAlbumEntities(limit: 50)
    }
}

@available(iOS 27.0, *)
extension AlbumQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [AlbumEntity] {
        try await store.albumEntities(matching: string)
    }
}

@available(iOS 27.0, *)
extension AlbumQuery: IndexedEntityQuery {
    func reindexEntities(
        for identifiers: [String],
        indexDescription: CSSearchableIndexDescription
    ) async throws {
        let entities = try await store.albumEntities(for: identifiers)
        try await CSSearchableIndex(name: SpotlightLibraryIndexer.indexName).indexAppEntities(entities)
    }

    func reindexAllEntities(
        indexDescription: CSSearchableIndexDescription
    ) async throws {
        let entities = try await store.allAlbumEntities()
        try await CSSearchableIndex(name: SpotlightLibraryIndexer.indexName).indexAppEntities(entities)
    }
}

#endif // canImport(MediaIntents)
