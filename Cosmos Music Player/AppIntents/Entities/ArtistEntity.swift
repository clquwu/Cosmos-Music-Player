//
//  ArtistEntity.swift
//  Cosmos Music Player
//
//  Assistant-schema artist entity. The artist's identity is its name.
//

#if canImport(MediaIntents)
import AppIntents
import CoreSpotlight
import Foundation

@available(iOS 27.0, *)
@AppEntity(schema: .audio.artist)
struct ArtistEntity: IndexedEntity {
    static let defaultQuery = ArtistQuery()

    // MARK: Schema properties

    var name: String
    var albums: [AlbumEntity]
    var songs: [SongEntity]

    // MARK: Entity properties

    let id: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            image: DisplayRepresentation.Image(systemName: "music.microphone")
        )
    }

    /// Shallow artist used inside song/album entities to avoid cycles.
    // The @AppEntity macro generates init accessors for scalar schema
    // properties that read the entity-array storage, so `albums`/`songs`
    // must be initialized before `name`.
    init(name: String) {
        id = name
        albums = []
        songs = []
        self.name = name
    }

    init(name: String, albums: [AlbumEntity]) {
        id = name
        self.albums = albums
        songs = []
        self.name = name
    }
}

@available(iOS 27.0, *)
extension ArtistEntity: Equatable, Hashable {
    static func == (lhs: ArtistEntity, rhs: ArtistEntity) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - ArtistQuery

@available(iOS 27.0, *)
struct ArtistQuery {
    @Dependency var store: IntentEntityStore
}

@available(iOS 27.0, *)
extension ArtistQuery: EntityQuery {
    func entities(for identifiers: [ArtistEntity.ID]) async throws -> [ArtistEntity] {
        try await store.artistEntities(for: identifiers)
    }

    func suggestedEntities() async throws -> [ArtistEntity] {
        try await store.allArtistEntities(limit: 50)
    }
}

@available(iOS 27.0, *)
extension ArtistQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [ArtistEntity] {
        try await store.artistEntities(matching: string)
    }
}

@available(iOS 27.0, *)
extension ArtistQuery: IndexedEntityQuery {
    func reindexEntities(
        for identifiers: [String],
        indexDescription: CSSearchableIndexDescription
    ) async throws {
        let entities = try await store.artistEntities(for: identifiers)
        try await CSSearchableIndex(name: SpotlightLibraryIndexer.indexName).indexAppEntities(entities)
    }

    func reindexAllEntities(
        indexDescription: CSSearchableIndexDescription
    ) async throws {
        let entities = try await store.allArtistEntities()
        try await CSSearchableIndex(name: SpotlightLibraryIndexer.indexName).indexAppEntities(entities)
    }
}

#endif // canImport(MediaIntents)
