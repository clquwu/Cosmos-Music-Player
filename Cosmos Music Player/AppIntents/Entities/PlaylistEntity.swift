//
//  PlaylistEntity.swift
//  Cosmos Music Player
//
//  Assistant-schema playlist entity backed by the GRDB Playlist model.
//

#if canImport(MediaIntents)
import AppIntents
import CoreSpotlight
import Foundation

/// A union the playlist schema requires for its optional `owner` slot.
@available(iOS 27.0, *)
@UnionValue
enum PlaylistOwnerUnion {
    case curator(String)
    case person(IntentPerson)
}

@available(iOS 27.0, *)
@AppEntity(schema: .audio.playlist)
struct PlaylistEntity: IndexedEntity {
    static let defaultQuery = PlaylistQuery()

    // MARK: Schema properties

    var title: String
    var owner: PlaylistOwnerUnion?
    var trackCount: Int
    var totalDuration: TimeInterval
    var createdByMe: Bool?
    var curatedForMe: Bool?

    // MARK: Entity properties

    let id: String

    var displayRepresentation: DisplayRepresentation {
        let synonyms: [LocalizedStringResource] = [
            "\(title) playlist",
            "playlist \(title)"
        ]
        return DisplayRepresentation(
            title: "\(title)",
            subtitle: "^[\(trackCount) song](inflect: true)",
            image: DisplayRepresentation.Image(systemName: "music.note.list"),
            synonyms: synonyms
        )
    }

    // The @AppEntity macro turns `owner`/`title` into init-accessor
    // properties that read `trackCount`/`totalDuration`, so those plain
    // stored properties must be initialized first.
    init(playlist: Playlist, trackCount: Int, totalDuration: TimeInterval) {
        id = String(playlist.id ?? 0)
        self.trackCount = trackCount
        self.totalDuration = totalDuration
        createdByMe = true
        curatedForMe = false
        owner = nil
        title = playlist.title
    }
}

@available(iOS 27.0, *)
extension PlaylistEntity: Equatable, Hashable {
    static func == (lhs: PlaylistEntity, rhs: PlaylistEntity) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - PlaylistQuery

@available(iOS 27.0, *)
struct PlaylistQuery {
    @Dependency var store: IntentEntityStore
}

@available(iOS 27.0, *)
extension PlaylistQuery: EntityQuery {
    func entities(for identifiers: [PlaylistEntity.ID]) async throws -> [PlaylistEntity] {
        try await store.playlistEntities(for: identifiers)
    }

    func suggestedEntities() async throws -> [PlaylistEntity] {
        try await store.allPlaylistEntities()
    }
}

@available(iOS 27.0, *)
extension PlaylistQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [PlaylistEntity] {
        try await store.playlistEntities(matching: string)
    }
}

@available(iOS 27.0, *)
extension PlaylistQuery: IndexedEntityQuery {
    func reindexEntities(
        for identifiers: [String],
        indexDescription: CSSearchableIndexDescription
    ) async throws {
        let entities = try await store.playlistEntities(for: identifiers)
        try await CSSearchableIndex(name: SpotlightLibraryIndexer.indexName).indexAppEntities(entities)
    }

    func reindexAllEntities(
        indexDescription: CSSearchableIndexDescription
    ) async throws {
        let entities = try await store.allPlaylistEntities()
        try await CSSearchableIndex(name: SpotlightLibraryIndexer.indexName).indexAppEntities(entities)
    }
}

#endif // canImport(MediaIntents)
