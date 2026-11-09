//
//  FavoriteCurrentSongIntent.swift
//  Cosmos Music Player
//
//  Explicit App Shortcut for phrases such as "Like this song in Cosmos".
//  The audio affinity schema can handle named SongEntity values on iOS 27,
//  but Siri does not consistently bind "this song" to the current Cosmos
//  track. This parameter-free intent makes that use case deterministic.
//

import AppIntents

@available(iOS 26.0, *)
struct FavoriteCurrentSongIntent: AppIntent {
    static let title: LocalizedStringResource = "Favorite Current Song"
    static let description = IntentDescription(
        "Adds the currently playing Cosmos song to Liked Songs.",
        categoryName: "Playback"
    )
    static let openAppWhenRun = false

    @Dependency var playback: IntentPlaybackService

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        IntentRuntime.begin("FavoriteCurrentSongIntent")
        defer { IntentRuntime.end("FavoriteCurrentSongIntent") }
        do {
            // A cold launch has no current track until the saved session is
            // back; "this song" means the one the person last listened to.
            await IntentRuntime.restoreSavedSessionIfNeeded()
            guard let track = playback.currentTrack else {
                throw FavoriteCurrentSongError.nothingPlaying
            }

            SiriDiag.log("APP FavoriteCurrentSongIntent.perform track=\(track.title)")

            if try playback.isFavorite(trackStableId: track.stableId) {
                return .result(dialog: IntentDialog(
                    "\(track.title) is already in your Liked Songs."
                ))
            }

            try playback.setFavorite(trackStableId: track.stableId, isFavorite: true)
            return .result(dialog: IntentDialog(
                "Added \(track.title) to your Liked Songs."
            ))
        } catch {
            throw IntentRuntime.userFacing(error, in: "FavoriteCurrentSongIntent")
        }
    }
}

@available(iOS 26.0, *)
enum FavoriteCurrentSongError: Error, CustomLocalizedStringResourceConvertible {
    case nothingPlaying

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .nothingPlaying:
            "There isn't a song playing in Cosmos right now."
        }
    }
}
