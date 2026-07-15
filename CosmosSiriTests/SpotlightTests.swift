//
//  SpotlightTests.swift
//  CosmosSiriTests
//
//  Verifies the Spotlight index lifecycle via the DEBUG-only clear and
//  reindex intents: clear empties the named index, reindex repopulates it
//  from the library.
//

import AppIntentsTesting
import XCTest

final class SpotlightTests: BaseTestCase {

    func testClearAndReindexRoundTrip() async throws {
        try await clearSpotlightDefinition.makeIntent().run()

        let cleared = try await songEntityDefinition.spotlightQuery()
        XCTAssertTrue(cleared.isEmpty, "Clearing should empty the Spotlight index")

        try await reindexSpotlightDefinition.makeIntent().run()

        let reindexed = try await songEntityDefinition.spotlightQuery()
        let library = try await songEntityDefinition.entities(matching: "a")
        if reindexed.isEmpty && library.isEmpty {
            throw XCTSkip("The library on this device is empty — reindex has nothing to index.")
        }
        XCTAssertFalse(reindexed.isEmpty, "Reindexing should restore the library to the Spotlight index")
    }
}
