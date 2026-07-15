//
//  SpotlightLibraryIndexer.swift
//  Cosmos Music Player
//
//  Keeps the library's App Entities indexed in Spotlight so Siri and Apple
//  Intelligence can resolve songs, albums, artists and playlists by name.
//

#if canImport(MediaIntents)
import AppIntents
import Combine
import CoreSpotlight
import Foundation

@available(iOS 27.0, *)
@MainActor
final class SpotlightLibraryIndexer {
    static let shared = SpotlightLibraryIndexer()

    /// Named index — the `.default()` index doesn't support batch client state.
    nonisolated static let indexName = "CosmosMusicPlayer"

    private let store = IntentEntityStore()
    private var indexingObserver: AnyCancellable?
    private var pendingReindex: Task<Void, Never>?

    private init() {}

    /// Starts watching library sync completion and kicks an initial reindex.
    /// Call once, after AppCoordinator has initialized the database.
    func activate() {
        guard indexingObserver == nil else { return }
        indexingObserver = LibraryIndexer.shared.$isIndexing
            .removeDuplicates()
            .dropFirst()
            .filter { !$0 }
            .sink { [weak self] _ in
                self?.scheduleReindex()
            }
        scheduleReindex()
    }

    /// Debounced full reindex — sync completion can fire in quick succession.
    func scheduleReindex(after delay: TimeInterval = 3) {
        pendingReindex?.cancel()
        pendingReindex = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.reindexAll()
        }
    }

    func reindexAll() async {
        do {
            let songs = try store.allSongEntities()
            let albums = try store.allAlbumEntities()
            let artists = try store.allArtistEntities()
            let playlists = try store.allPlaylistEntities()

            try await CSSearchableIndex(name: Self.indexName).deleteAllSearchableItems()
            try await indexBatched(songs)
            try await indexBatched(albums)
            try await indexBatched(artists)
            try await indexBatched(playlists)
        } catch {
            print("❌ Spotlight reindex failed: \(error)")
        }
    }

    // A fresh CSSearchableIndex per send — the handle is not Sendable, so
    // reusing one across awaits trips Swift 6 region isolation.
    private func indexBatched<Entity: IndexedEntity>(
        _ entities: [Entity],
        batchSize: Int = 500
    ) async throws {
        var start = 0
        while start < entities.count {
            let end = min(start + batchSize, entities.count)
            let batch = Array(entities[start..<end])
            try await CSSearchableIndex(name: Self.indexName).indexAppEntities(batch)
            start = end
        }
    }
}

#endif // canImport(MediaIntents)
