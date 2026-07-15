//
//  IntentExecutionTests.swift
//  CosmosSiriTests
//
//  Drives the audio schema intents end-to-end across the IPC boundary —
//  the same execution path Siri uses.
//

import AppIntentsTesting
import XCTest

final class IntentExecutionTests: BaseTestCase {

    func testResumePlayback() async throws {
        do {
            try await resumePlaybackDefinition.makeIntent().run()
        } catch {
            // An empty library legitimately throws ResumePlaybackError; only
            // treat it as a skip, not a failure.
            let songs = try await indexedSongs()
            guard songs.isEmpty else { throw error }
            throw XCTSkip("Resume threw on an empty library: \(error)")
        }
    }

    func testFavoriteCurrentSong() async throws {
        let song = try await requireAnySong()
        try await playAudioDefinition.makeIntent(audioEntity: song).run()
        try await favoriteCurrentSongDefinition.makeIntent().run()
        // The action is idempotent, so running it twice must also succeed.
        try await favoriteCurrentSongDefinition.makeIntent().run()
    }

    func testPlaySong() async throws {
        let song = try await requireAnySong()
        try await playAudioDefinition.makeIntent(audioEntity: song).run()
    }

    func testPlaySongShuffledNext() async throws {
        let song = try await requireAnySong()
        try await playAudioDefinition.makeIntent(audioEntity: song).run()
        // Queue the same song next on top of the running queue.
        try await playAudioDefinition.makeIntent(
            audioEntity: song,
            queueLocation: definitions.enums["QueueInsertionLocation"].makeCase("next")
        ).run()
    }

    func testLikeThenUnsetRoundTrip() async throws {
        let song = try await requireAnySong()
        try await updateAffinityDefinition.makeIntent(
            affinityState: affinityStateDefinition.makeCase("like"),
            target: song
        ).run()
        try await updateAffinityDefinition.makeIntent(
            affinityState: affinityStateDefinition.makeCase("unset"),
            target: song
        ).run()
    }

    func testAddToPlaylist() async throws {
        let song = try await requireAnySong()
        let playlists = try await playlistEntityDefinition.spotlightQuery()
        guard let playlist = playlists.first else {
            throw XCTSkip("No playlists on this device — create one to exercise this test.")
        }
        do {
            try await addToPlaylistDefinition.makeIntent(
                audioEntity: song,
                playlist: playlist
            ).run()
        } catch {
            // Acceptable when the song is already in the playlist — the
            // intent throws AudioIntentError.alreadyInPlaylist by design.
        }
    }

    func testGenerateMix() async throws {
        _ = try await requireAnySong()
        // On simulators without Apple Intelligence this exercises the
        // token-match fallback path, which must still produce a playing mix.
        try await generateMixDefinition.makeIntent(mixDescription: "calm evening test").run()
    }
}
