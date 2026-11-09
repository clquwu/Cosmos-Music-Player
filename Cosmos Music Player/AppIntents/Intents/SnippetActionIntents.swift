//
//  SnippetActionIntents.swift
//  Cosmos Music Player
//
//  Hidden intents backing the buttons inside interactive result snippets.
//  Tapping a button performs one of these; the system then re-runs the
//  presenting SnippetIntent so the card re-renders with fresh state.
//

#if canImport(MediaIntents)
import AppIntents

@available(iOS 27.0, *)
struct ToggleFavoriteIntent: AppIntent {
    static let title: LocalizedStringResource = LocalizedStringResource(
        "Toggle Favorite",
        comment: "Title of the hidden intent behind the heart button in snippets."
    )
    static let isDiscoverable = false

    @Parameter(title: "Track")
    var trackStableId: String

    @Dependency var playback: IntentPlaybackService

    init() {}

    init(trackStableId: String) {
        self.trackStableId = trackStableId
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRuntime.begin("ToggleFavoriteIntent")
        defer { IntentRuntime.end("ToggleFavoriteIntent") }
        do {
            try playback.toggleFavorite(trackStableId: trackStableId)
        } catch {
            throw IntentRuntime.userFacing(error, in: "ToggleFavoriteIntent")
        }
        return .result()
    }
}

@available(iOS 27.0, *)
struct EnqueueTrackIntent: AppIntent {
    static let title: LocalizedStringResource = LocalizedStringResource(
        "Add to Queue",
        comment: "Title of the hidden intent behind the queue buttons in snippets."
    )
    static let isDiscoverable = false

    @Parameter(title: "Track")
    var trackStableId: String

    @Parameter(title: "Play Next")
    var playNext: Bool

    @Dependency var playback: IntentPlaybackService

    init() {}

    init(trackStableId: String, playNext: Bool) {
        self.trackStableId = trackStableId
        self.playNext = playNext
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRuntime.begin("EnqueueTrackIntent")
        defer { IntentRuntime.end("EnqueueTrackIntent") }
        let found: Track?
        do {
            found = try playback.tracks(forStableIds: [trackStableId]).first
        } catch {
            throw IntentRuntime.userFacing(error, in: "EnqueueTrackIntent")
        }
        guard let track = found else {
            throw AppIntentError(wrapping: AudioIntentError.noAudioEntity)
        }
        if playNext {
            await playback.insertNext([track])
        } else {
            await playback.addToQueue([track])
        }
        return .result()
    }
}

@available(iOS 27.0, *)
struct PlayPlaylistIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = LocalizedStringResource(
        "Play Playlist",
        comment: "Title of the hidden intent behind the play button on playlist snippets."
    )
    static let isDiscoverable = false

    @Parameter(title: "Playlist")
    var playlistId: String

    @Dependency var playback: IntentPlaybackService

    init() {}

    init(playlistId: String) {
        self.playlistId = playlistId
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRuntime.begin("PlayPlaylistIntent")
        defer { IntentRuntime.end("PlayPlaylistIntent") }
        guard let id = Int64(playlistId) else {
            throw AppIntentError(wrapping: AudioIntentError.noAudioEntity)
        }
        let tracks: [Track]
        do {
            tracks = try playback.tracks(inPlaylist: id)
        } catch {
            throw IntentRuntime.userFacing(error, in: "PlayPlaylistIntent")
        }
        guard !tracks.isEmpty else {
            throw AppIntentError(wrapping: AudioIntentError.noAudioEntity)
        }
        await playback.play(tracks: tracks)
        return .result()
    }
}

#endif // canImport(MediaIntents)
