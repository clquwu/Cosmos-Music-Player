//
//  EntityQueryTests.swift
//  CosmosSiriTests
//
//  Drives the entity string queries across the IPC boundary — the same path
//  Siri uses to resolve "play <name>" against the library.
//

import AppIntentsTesting
import XCTest

final class EntityQueryTests: BaseTestCase {

    func testSongStringQueryExecutes() async throws {
        _ = try await entitiesWithRetry(songEntityDefinition, matching: "a")
    }

    func testAlbumStringQueryExecutes() async throws {
        _ = try await entitiesWithRetry(albumEntityDefinition, matching: "a")
    }

    func testArtistStringQueryExecutes() async throws {
        _ = try await entitiesWithRetry(artistEntityDefinition, matching: "a")
    }

    func testPlaylistStringQueryExecutes() async throws {
        _ = try await entitiesWithRetry(playlistEntityDefinition, matching: "a")
    }

    /// Round-trips an indexed song through the identifier query — the path
    /// Siri takes after picking a Spotlight result.
    func testSongIdentifierQueryRoundTrip() async throws {
        let song = try await requireAnySong()
        let resolved = try await songEntityDefinition.entities(identifiers: [song.identifier.instanceIdentifier])
        XCTAssertFalse(resolved.isEmpty, "Identifier query should resolve a Spotlight-indexed song")
    }
}
