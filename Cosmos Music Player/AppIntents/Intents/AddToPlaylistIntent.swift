//
//  AddToPlaylistIntent.swift
//  Cosmos Music Player
//
//  "Add this song to my <playlist>" via the .audio.addToPlaylist schema.
//

#if canImport(MediaIntents)
import AppIntents

@available(iOS 27.0, *)
@AppIntent(schema: .audio.addToPlaylist)
struct AddToPlaylistIntent {

    static let title: LocalizedStringResource = LocalizedStringResource(
        "Add to Playlist",
        comment: "Title of the Add to Playlist intent."
    )

    // MARK: Schema parameters

    var audioEntity: AudioEntity
    var playlist: PlaylistEntity

    // MARK: Dependencies

    @Dependency var playback: IntentPlaybackService

    // MARK: Perform

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetIntent {
        guard case .song(let song) = audioEntity else {
            throw AppIntentError(wrapping: AudioIntentError.unsupportedTarget)
        }
        guard let playlistId = Int64(playlist.id) else {
            throw AppIntentError(wrapping: AudioIntentError.noAudioEntity)
        }

        let added = try playback.addToPlaylist(playlistId: playlistId, trackStableId: song.id)
        guard added else {
            throw AppIntentError(wrapping: AudioIntentError.alreadyInPlaylist)
        }

        let dialog = IntentDialog(
            full: LocalizedStringResource(
                "Added \(song.title) to \(playlist.title).",
                comment: "Spoken confirmation when a song is added to a playlist. Argument 1 is the song title, argument 2 the playlist title."
            ),
            supporting: LocalizedStringResource(
                "Added",
                comment: "Short on-screen confirmation paired with the full dialog when a song is added to a playlist."
            )
        )
        return .result(
            dialog: dialog,
            snippetIntent: PlaylistCardSnippetIntent(playlistId: playlist.id)
        )
    }
}

#endif // canImport(MediaIntents)
