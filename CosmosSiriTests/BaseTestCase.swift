//
//  BaseTestCase.swift
//  CosmosSiriTests
//
//  Shared XCUITest base exposing typed accessors for the app's intents,
//  entities and enums via the AppIntentsTesting framework. Tests drive the
//  real app across the IPC boundary, so the library on the test device
//  determines how much each test can exercise — helpers skip gracefully
//  when the library is empty.
//

import AppIntentsTesting
import XCTest

class BaseTestCase: XCTestCase {

    @MainActor
    let app = XCUIApplication()

    let definitions = IntentDefinitions(bundleIdentifier: "dev.clq.Cosmos-Music-Player")

    // MARK: - Intent definitions

    var resumePlaybackDefinition: AppIntentDefinition {
        definitions.intents["ResumePlaybackIntent"]
    }

    var favoriteCurrentSongDefinition: AppIntentDefinition {
        definitions.intents["FavoriteCurrentSongIntent"]
    }

    var playAudioDefinition: AppIntentDefinition {
        definitions.intents["PlayAudioIntent"]
    }

    var updateAffinityDefinition: AppIntentDefinition {
        definitions.intents["UpdateAudioAffinityIntent"]
    }

    var addToPlaylistDefinition: AppIntentDefinition {
        definitions.intents["AddToPlaylistIntent"]
    }

    var generateMixDefinition: AppIntentDefinition {
        definitions.intents["GenerateMixIntent"]
    }

    // MARK: - Test-support intents (DEBUG builds only)

    var clearSpotlightDefinition: AppIntentDefinition {
        definitions.intents["ClearSpotlightIntent"]
    }

    var reindexSpotlightDefinition: AppIntentDefinition {
        definitions.intents["ReindexSpotlightIntent"]
    }

    // MARK: - Entity definitions

    var songEntityDefinition: AppEntityDefinition {
        definitions.entities["SongEntity"]
    }

    var albumEntityDefinition: AppEntityDefinition {
        definitions.entities["AlbumEntity"]
    }

    var artistEntityDefinition: AppEntityDefinition {
        definitions.entities["ArtistEntity"]
    }

    var playlistEntityDefinition: AppEntityDefinition {
        definitions.entities["PlaylistEntity"]
    }

    // MARK: - Enum definitions

    var affinityStateDefinition: AppEnumDefinition {
        definitions.enums["AffinityState"]
    }

    // MARK: - Setup

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        app.launch()
    }

    // MARK: - Helpers

    /// The first IPC call after a fresh install can race the system's
    /// ingestion of the app's App Intents metadata (403 from
    /// AppIntentsServicesMetadataErrorDomain) — wait and retry once.
    func entitiesWithRetry(
        _ definition: AppEntityDefinition,
        matching string: String
    ) async throws -> [AnyAppEntity] {
        do {
            return try await definition.entities(matching: string)
        } catch {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            return try await definition.entities(matching: string)
        }
    }

    /// Returns Spotlight-indexed songs, forcing a reindex once if the index
    /// is empty (fresh simulator install).
    func indexedSongs() async throws -> [AnyAppEntity] {
        var songs = try await songEntityDefinition.spotlightQuery()
        if songs.isEmpty {
            try await reindexSpotlightDefinition.makeIntent().run()
            songs = try await songEntityDefinition.spotlightQuery()
        }
        return songs
    }

    /// First indexed song, or skips the test when the library is empty.
    func requireAnySong() async throws -> AnyAppEntity {
        let songs = try await indexedSongs()
        guard let song = songs.first else {
            throw XCTSkip("The library on this device is empty — add music to exercise this test.")
        }
        return song
    }
}
