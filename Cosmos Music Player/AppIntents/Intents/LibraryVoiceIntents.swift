//
//  LibraryVoiceIntents.swift
//  Cosmos Music Player
//
//  Voice intents that take the iOS 27 assistant-schema entities as
//  parameters, so their names can appear in App Shortcut phrases:
//  "Mélange <artiste> dans Cosmos", "Ajoute ce morceau à <playlist> dans
//  Cosmos".
//

#if canImport(MediaIntents)
import AppIntents
import Foundation

@available(iOS 27.0, *)
struct ShuffleMusicIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Shuffle Music"
    static let description = IntentDescription(
        "Shuffles your whole Cosmos library, or one artist.",
        categoryName: "Playback"
    )

    @Parameter(title: "Artist")
    var artist: ArtistEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Shuffle \(\.$artist)")
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        IntentRuntime.begin("ShuffleMusicIntent")
        defer { IntentRuntime.end("ShuffleMusicIntent") }
        SiriDiag.log("APP ShuffleMusicIntent artist=\(artist?.name ?? "nil")")
        do {
            if let artist {
                let name = artist.name
                let tracks = try await CosmosSiriActions.read { try $0.tracksForSpokenArtist(name) }
                guard !tracks.isEmpty else { throw VoiceIntentError.nothingFound(name) }
                guard await CosmosSiriActions.play(tracks, shuffled: true, source: "artist") else { throw VoiceIntentError.playbackDidNotStart }
                return .result(dialog: "Shuffling \(name).")
            }
            let tracks = try await CosmosSiriActions.read { try $0.getAllTracks() }
            guard !tracks.isEmpty else { throw VoiceIntentError.emptyLibrary }
            guard await CosmosSiriActions.play(tracks, shuffled: true) else { throw VoiceIntentError.playbackDidNotStart }
            return .result(dialog: "Shuffling your library.")
        } catch {
            throw IntentRuntime.userFacing(error, in: "ShuffleMusicIntent")
        }
    }
}

@available(iOS 27.0, *)
struct AddCurrentSongToPlaylistIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Current Song to Playlist"
    static let description = IntentDescription(
        "Adds the song playing in Cosmos to one of your playlists.",
        categoryName: "Library"
    )
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Playlist")
    var playlist: PlaylistEntity

    @Dependency var playback: IntentPlaybackService

    static var parameterSummary: some ParameterSummary {
        Summary("Add the current song to \(\.$playlist)")
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        IntentRuntime.begin("AddCurrentSongToPlaylistIntent")
        defer { IntentRuntime.end("AddCurrentSongToPlaylistIntent") }
        do {
            guard let track = await CosmosSiriActions.currentTrackRestoringSession() else {
                throw VoiceIntentError.nothingPlaying
            }
            guard let playlistId = Int64(playlist.id) else {
                throw VoiceIntentError.nothingFound(playlist.title)
            }
            let title = playlist.title
            if try !playback.addToPlaylist(playlistId: playlistId, trackStableId: track.stableId) {
                return .result(dialog: "\(track.title) is already in \(title).")
            }
            return .result(dialog: "Added \(track.title) to \(title).")
        } catch {
            throw IntentRuntime.userFacing(error, in: "AddCurrentSongToPlaylistIntent")
        }
    }
}

#endif // canImport(MediaIntents)
