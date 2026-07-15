//
//  PlayAudioIntent.swift
//  Cosmos Music Player
//
//  The .audio.playAudio schema intent — Siri fills `audioEntity` from
//  Spotlight-indexed entities, the entity string queries, or
//  AudioIntentValueQuery for open-ended requests, then playback runs
//  in-process without opening the app.
//

#if canImport(MediaIntents)
import AppIntents
import Foundation
import OSLog

@available(iOS 27.0, *)
@AppIntent(schema: .audio.playAudio)
struct PlayAudioIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = LocalizedStringResource(
        "Play Music",
        comment: "Title of the Play Music intent."
    )
    static let description = IntentDescription(
        LocalizedStringResource(
            "Plays a song, album, artist or playlist from your Cosmos library.",
            comment: "Description of the Play Music intent shown in the Shortcuts gallery."
        ),
        categoryName: LocalizedStringResource(
            "Playback",
            comment: "Shortcuts gallery category name for Cosmos playback intents."
        )
    )

    // MARK: Schema parameters

    var audioEntity: AudioEntity
    @Parameter(default: [])
    var playbackAttributes: Set<PlaybackAttributes>
    var queueLocation: QueueInsertionLocation?
    var warmupAudioQueueResult: WarmupAudioQueueResult?

    // MARK: Dependencies

    @Dependency var playback: IntentPlaybackService
    @Dependency var store: IntentEntityStore

    // MARK: Perform

    @MainActor
    func perform() async throws -> some IntentResult & ShowsSnippetIntent {
        SiriDiag.log("APP PlayAudioIntent.perform entity=\(audioEntity.title) attrs=\(playbackAttributes) queueLocation=\(String(describing: queueLocation))")
        let tracks: [Track]
        do {
            switch audioEntity {
            case .song(let song):
                tracks = try playback.tracks(forStableIds: [song.id])
            case .album(let album):
                guard let albumId = Int64(album.id) else {
                    throw AudioIntentError.noAudioEntity
                }
                tracks = try playback.tracks(forAlbumId: albumId)
            case .artist(let artist):
                tracks = try playback.tracks(forArtistName: artist.name)
            case .playlist(let playlist):
                guard let playlistId = Int64(playlist.id) else {
                    throw AudioIntentError.noAudioEntity
                }
                tracks = try playback.tracks(inPlaylist: playlistId)
            }

            guard !tracks.isEmpty else {
                throw AudioIntentError.noAudioEntity
            }

            switch queueLocation {
            case .none:
                await playback.play(tracks: tracks)
                playback.setShuffle(playbackAttributes.contains(.shuffle))
                playback.setQueueRepeat(playbackAttributes.contains(.repeat))
            case .next:
                await playback.insertNext(tracks)
            case .tail:
                await playback.addToQueue(tracks)
            }
        } catch let error as AudioIntentError {
            Logger.appIntents.error("[PlayAudioIntent] \(error.localizedDescription)")
            throw AppIntentError(wrapping: error)
        } catch {
            Logger.appIntents.error("[PlayAudioIntent] Playback failed: \(error.localizedDescription)")
            throw AppIntentError(wrapping: AudioIntentError.playbackFailed(underlying: error))
        }

        return .result(snippetIntent: SongCardSnippetIntent(trackStableId: tracks[0].stableId))
    }
}

// MARK: - Errors shared by the audio schema intents

@available(iOS 27.0, *)
enum AudioIntentError: Error {
    case noAudioEntity
    case unsupportedTarget
    case alreadyInPlaylist
    case playbackFailed(underlying: Error)
}

@available(iOS 27.0, *)
extension AudioIntentError: CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noAudioEntity:
            LocalizedStringResource(
                "I couldn't find that song in your Cosmos library.",
                comment: "Spoken when Siri couldn't resolve any matching audio for a play request."
            )
        case .unsupportedTarget:
            LocalizedStringResource(
                "You can only take that action on individual songs.",
                comment: "Spoken when a song-only action is applied to an album, artist or playlist."
            )
        case .alreadyInPlaylist:
            LocalizedStringResource(
                "That song is already in this playlist.",
                comment: "Spoken when adding a song to a playlist that already contains it."
            )
        case .playbackFailed:
            LocalizedStringResource(
                "Playback failed. Please try again in the app.",
                comment: "Spoken when starting playback threw an unexpected error."
            )
        }
    }
}

@available(iOS 27.0, *)
extension Logger {
    static let appIntents = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "CosmosMusicPlayer",
        category: "AppIntents"
    )
}

#endif // canImport(MediaIntents)
