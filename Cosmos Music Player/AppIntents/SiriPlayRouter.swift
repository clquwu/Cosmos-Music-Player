//
//  SiriPlayRouter.swift
//  Cosmos Music Player
//
//  App side of the legacy SiriKit path. SiriIntentsExtension resolves a
//  spoken request into an identifier (contract documented at the top of
//  SiriIntentsExtension/IntentHandler.swift) and hands INPlayMediaIntent to
//  the app; AppCoordinator.handleSiriPlaybackIntent asks this router first
//  and keeps its own branches for the older identifiers.
//
//  Also applies what Siri asked for alongside the media — shuffle, repeat
//  and "play next" / "add to queue" — which the older branches ignored.
//

import Foundation
import Intents

@MainActor
enum SiriPlayRouter {

    /// Wraps a completion so that a successful start also applies the
    /// request's shuffle/repeat options.
    static func applyingPlaybackOptions(
        of intent: INPlayMediaIntent,
        to completion: @escaping (INIntentResponse) -> Void
    ) -> (INIntentResponse) -> Void {
        { response in
            if (response as? INPlayMediaIntentResponse)?.code == .success {
                applyModes(of: intent)
            }
            completion(response)
        }
    }

    private static func applyModes(of intent: INPlayMediaIntent) {
        let engine = PlayerEngine.shared
        if let shuffled = intent.playShuffled, engine.isShuffled != shuffled {
            engine.toggleShuffle()
        }
        switch intent.playbackRepeatMode {
        case .all:
            engine.isRepeating = true
            engine.isLoopingSong = false
            engine.queueDidChange()
        case .one:
            engine.isRepeating = false
            engine.isLoopingSong = true
            engine.queueDidChange()
        case .none:
            if engine.isRepeating || engine.isLoopingSong {
                engine.isRepeating = false
                engine.isLoopingSong = false
                engine.queueDidChange()
            }
        default:
            break
        }
    }

    /// Handles the identifiers this router owns. Returns false to let the
    /// caller's own branches run.
    static func handle(
        _ intent: INPlayMediaIntent,
        identifier: String,
        completion: @escaping (INIntentResponse) -> Void
    ) async -> Bool {
        func finish(_ ok: Bool) {
            SiriDiag.log("APP SiriPlayRouter \(identifier) -> \(ok ? "success" : "failure")")
            completion(INPlayMediaIntentResponse(code: ok ? .success : .failure, userActivity: nil))
        }

        do {
            // "Play X next" / "add X to my queue" for a resolved song.
            if intent.playbackQueueLocation == .next || intent.playbackQueueLocation == .later,
               !identifier.contains("_"),
               let ids = intent.mediaItems?.compactMap(\.identifier), !ids.isEmpty {
                let tracks = try await CosmosSiriActions.read { try $0.getTracksByStableIdsPreservingOrder(Array(ids.prefix(1))) }
                guard let track = tracks.first else { return false }
                if PlayerEngine.shared.currentTrack == nil {
                    finish(await CosmosSiriActions.play([track]))
                } else if intent.playbackQueueLocation == .next {
                    PlayerEngine.shared.insertNext(track)
                    finish(true)
                } else {
                    PlayerEngine.shared.addToQueue(track)
                    finish(true)
                }
                return true
            }

            switch identifier {
            case "liked_songs":
                let tracks = try await CosmosSiriActions.likedTracks()
                finish(await CosmosSiriActions.play(tracks, shuffled: true, source: "liked"))
                return true

            case "music_all":
                let tracks = try await CosmosSiriActions.read { try $0.getAllTracks() }
                finish(await CosmosSiriActions.play(tracks, shuffled: true))
                return true

            case "radio_current":
                guard let seed = await CosmosSiriActions.currentTrackRestoringSession() else {
                    finish(false)
                    return true
                }
                finish(await CosmosSiriActions.playSongRadio(seed: seed))
                return true

            case "artist_current":
                guard let current = await CosmosSiriActions.currentTrackRestoringSession(),
                      let artistId = current.artistId else {
                    finish(false)
                    return true
                }
                let tracks = try await CosmosSiriActions.read { try $0.getTracksByArtistId(artistId) }
                finish(await CosmosSiriActions.play(tracks, shuffled: true, source: "artist"))
                return true

            case "mixkind_madeForYou", "mixkind_rediscover":
                await CosmosSiriActions.ensureMixesLoaded()
                let shelf: CosmosSiriActions.MixShelf = identifier.hasSuffix("rediscover") ? .rediscover : .madeForYou
                guard let mix = CosmosSiriActions.firstMix(on: shelf) else {
                    finish(false)
                    return true
                }
                finish(await CosmosSiriActions.play(mix: mix, shuffled: intent.playShuffled ?? false))
                return true

            case "mode_now", "mode_tonight":
                let moment: CosmosSiriActions.Moment = identifier == "mode_tonight" ? .tonight : .now
                finish(await CosmosSiriActions.playSomething(for: moment) != nil)
                return true

            default:
                break
            }

            if identifier.hasPrefix("mix_") {
                await CosmosSiriActions.ensureMixesLoaded()
                let id = String(identifier.dropFirst(4))
                let title = intent.mediaItems?.first?.title ?? ""
                guard let mix = MixStore.shared.mix(id: id) ?? CosmosSiriActions.mix(named: title) else {
                    finish(false)
                    return true
                }
                finish(await CosmosSiriActions.play(mix: mix, shuffled: intent.playShuffled ?? false))
                return true
            }

            if identifier.hasPrefix("radio_song_") {
                let stableId = String(identifier.dropFirst(11))
                guard let seed = try await CosmosSiriActions.read({ try $0.getTrack(byStableId: stableId) }) else {
                    finish(false)
                    return true
                }
                finish(await CosmosSiriActions.playSongRadio(seed: seed))
                return true
            }

            if identifier.hasPrefix("radio_artist_") {
                finish(try await CosmosSiriActions.playArtistRadio(spoken: String(identifier.dropFirst(13))))
                return true
            }

            if identifier.hasPrefix("album_"), let albumId = Int64(identifier.dropFirst(6)) {
                let tracks = try await CosmosSiriActions.read { try $0.getTracksByAlbumId(albumId) }
                finish(await CosmosSiriActions.play(tracks, source: "album"))
                return true
            }

            if identifier.hasPrefix("generate_") {
                let text = String(identifier.dropFirst(9))
                finish(await playGenerated(text))
                return true
            }
        } catch {
            SiriDiag.log("APP SiriPlayRouter \(identifier) failed: \(error)")
            finish(false)
            return true
        }
        return false
    }

    /// "Play something calm": the on-device mix generator when available
    /// (bounded to Siri's window), otherwise a plain search, otherwise the
    /// whole library shuffled.
    private static func playGenerated(_ text: String) async -> Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *),
           let mix = try? await MixGenerator().generate(matching: text, budget: .siri),
           !mix.tracks.isEmpty {
            return await CosmosSiriActions.play(mix.tracks, source: "generated")
        }
        #endif
        if let hits = try? await CosmosSiriActions.read({ try $0.searchTracks(query: text) }), !hits.isEmpty {
            return await CosmosSiriActions.play(hits, shuffled: true)
        }
        let all = (try? await CosmosSiriActions.read { try $0.getAllTracks() }) ?? []
        return await CosmosSiriActions.play(all, shuffled: true)
    }
}
