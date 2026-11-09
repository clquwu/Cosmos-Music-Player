//
//  PlayLikedSongsIntent.swift
//  Cosmos Music Player
//
//  "Play my liked songs in Cosmos". SiriKit hears "my favourites" as a bare
//  "my music" with no name, which played the whole library; a phrase of the
//  app's own is the reliable way to reach Liked Songs.
//

import AppIntents

@available(iOS 26.0, *)
struct PlayLikedSongsIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Liked Songs"
    static let description = IntentDescription(
        "Plays the songs you liked, shuffled.",
        categoryName: "Playback"
    )

    @Dependency
    var playback: IntentPlaybackService

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRuntime.begin("PlayLikedSongsIntent")
        defer { IntentRuntime.end("PlayLikedSongsIntent") }
        do {
            let tracks = try await CosmosSiriActions.likedTracks()
            guard !tracks.isEmpty else { throw PlayLikedSongsError.noLikedSongs }
            await playback.play(tracks: tracks.shuffled())
            return .result()
        } catch let error as PlayLikedSongsError {
            throw error
        } catch {
            throw IntentRuntime.userFacing(error, in: "PlayLikedSongsIntent")
        }
    }
}

@available(iOS 26.0, *)
enum PlayLikedSongsError: Error, CustomLocalizedStringResourceConvertible {
    case noLikedSongs

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noLikedSongs:
            return "You haven't liked any songs in Cosmos yet."
        }
    }
}
