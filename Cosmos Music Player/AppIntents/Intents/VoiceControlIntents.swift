//
//  VoiceControlIntents.swift
//  Cosmos Music Player
//
//  Everything else a listener does in Cosmos, reachable by voice:
//  mixes by name, song radio, player commands, sleep timer, queueing a
//  named song, creating a playlist, opening a screen and play-by-name.
//
//  The playback intents adopt AudioPlaybackIntent so they run in the
//  background without opening the app. All of them follow the IntentRuntime
//  pattern (database kept awake, spoken errors, bounded waits) and are fully
//  deterministic — none needs Apple Intelligence.
//

import AppIntents
import Foundation

// MARK: - Errors

@available(iOS 26.0, *)
enum VoiceIntentError: Error, CustomLocalizedStringResourceConvertible {
    case nothingPlaying
    case songNotFound(String)
    case nothingFound(String)
    case mixesNotReady
    case emptyLibrary
    case playbackDidNotStart

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .nothingPlaying:
            "There isn't a song playing in Cosmos right now."
        case .songNotFound(let name):
            "I couldn't find a song called \(name) in Cosmos."
        case .nothingFound(let name):
            "I couldn't find \(name) in your Cosmos library."
        case .mixesNotReady:
            "Your mixes aren't ready yet. Open Cosmos once so it can make them."
        case .emptyLibrary:
            "There's no music in your Cosmos library yet."
        case .playbackDidNotStart:
            "Playback failed. Please try again in the app."
        }
    }
}

// MARK: - Play a mix

@available(iOS 26.0, *)
struct PlayMixIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Mix"
    static let description = IntentDescription(
        "Plays one of your Made for You or Rediscover mixes.",
        categoryName: "Playback"
    )

    @Parameter(title: "Mix")
    var mix: MixAppEntity?

    @Parameter(title: "Shuffle", default: false)
    var shuffled: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$mix)") {
            \.$shuffled
        }
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        IntentRuntime.begin("PlayMixIntent")
        defer { IntentRuntime.end("PlayMixIntent") }
        SiriDiag.log("APP PlayMixIntent mix=\(mix?.id ?? "nil")")
        await CosmosSiriActions.ensureMixesLoaded(timeout: 4.5)

        let target: Mix?
        switch mix?.id {
        case nil, MixAppEntity.madeForYouId:
            target = CosmosSiriActions.firstMix(on: .madeForYou) ?? CosmosSiriActions.firstMix(on: .rediscover)
        case MixAppEntity.rediscoverId:
            target = CosmosSiriActions.firstMix(on: .rediscover)
        case let id?:
            target = MixStore.shared.mix(id: id) ?? CosmosSiriActions.mix(named: mix?.title ?? "")
        }
        guard let target else { throw VoiceIntentError.mixesNotReady }
        guard await CosmosSiriActions.play(mix: target, shuffled: shuffled) else {
            throw VoiceIntentError.playbackDidNotStart
        }
        return .result(dialog: "Playing \(target.title).")
    }
}

// MARK: - Song radio ("a mix like this song")

@available(iOS 26.0, *)
struct PlaySongRadioIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Song Mix"
    static let description = IntentDescription(
        "Plays a mix of songs like the current song, or like a song you name.",
        categoryName: "Playback"
    )

    @Parameter(title: "Song", description: "Leave empty to use the song playing now.")
    var songName: String?

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        IntentRuntime.begin("PlaySongRadioIntent")
        defer { IntentRuntime.end("PlaySongRadioIntent") }
        do {
            let seed: Track
            if let name = songName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                guard let found = try await CosmosSiriActions.track(named: name) else {
                    throw VoiceIntentError.songNotFound(name)
                }
                seed = found
            } else {
                guard let current = await CosmosSiriActions.currentTrackRestoringSession() else {
                    throw VoiceIntentError.nothingPlaying
                }
                seed = current
            }
            SiriDiag.log("APP PlaySongRadioIntent seed=\(seed.title)")
            guard await CosmosSiriActions.playSongRadio(seed: seed) else {
                throw VoiceIntentError.playbackDidNotStart
            }
            return .result(dialog: "Playing a mix based on \(seed.title).")
        } catch {
            throw IntentRuntime.userFacing(error, in: "PlaySongRadioIntent")
        }
    }
}

// MARK: - Player commands

@available(iOS 26.0, *)
struct PlayerCommandIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Control Playback"
    static let description = IntentDescription(
        "Pause, skip, go back, restart, shuffle, repeat, unlike the current song, ask what's playing or cancel the sleep timer.",
        categoryName: "Playback"
    )

    @Parameter(title: "Command")
    var command: PlayerVoiceCommand

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$command)")
    }

    init() {}

    init(command: PlayerVoiceCommand) {
        self.command = command
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        IntentRuntime.begin("PlayerCommandIntent")
        defer { IntentRuntime.end("PlayerCommandIntent") }
        SiriDiag.log("APP PlayerCommandIntent command=\(command.rawValue)")
        let engine = PlayerEngine.shared
        do {
            switch command {
            case .cancelSleepTimer:
                SleepTimer.shared.cancel()
                return .result(dialog: "Sleep timer cancelled.")
            case .pause:
                engine.pause()
                return .result(dialog: "Paused.")
            default:
                break
            }

            guard let track = await CosmosSiriActions.currentTrackRestoringSession() else {
                throw VoiceIntentError.nothingPlaying
            }

            switch command {
            case .next:
                await AppCoordinator.shared.prepareSiriAudioSession()
                await engine.nextTrack(autoplay: true)
                return .result(dialog: "Skipped.")
            case .previous:
                await AppCoordinator.shared.prepareSiriAudioSession()
                await engine.previousTrack(autoplay: true)
                return .result(dialog: "Playing the previous song.")
            case .restart:
                _ = await engine.seek(to: 0)
                if !engine.isPlaying {
                    await AppCoordinator.shared.prepareSiriAudioSession()
                    engine.play()
                }
                return .result(dialog: "Restarting \(track.title).")
            case .shuffleOn, .shuffleOff:
                let wanted = command == .shuffleOn
                if engine.isShuffled != wanted { engine.toggleShuffle() }
                return .result(dialog: wanted ? "Shuffle is on." : "Shuffle is off.")
            case .repeatOn:
                engine.isRepeating = true
                engine.isLoopingSong = false
                engine.queueDidChange()
                return .result(dialog: "Repeat is on.")
            case .repeatOne:
                engine.isRepeating = false
                engine.isLoopingSong = true
                engine.queueDidChange()
                return .result(dialog: "Repeating \(track.title).")
            case .repeatOff:
                engine.isRepeating = false
                engine.isLoopingSong = false
                engine.queueDidChange()
                return .result(dialog: "Repeat is off.")
            case .unlike:
                if try !AppCoordinator.shared.isFavorite(trackStableId: track.stableId) {
                    return .result(dialog: "\(track.title) isn't in your Liked Songs.")
                }
                try AppCoordinator.shared.toggleFavorite(trackStableId: track.stableId)
                return .result(dialog: "Removed \(track.title) from your favorites.")
            case .nowPlaying:
                let artist = track.artistId.flatMap { try? DatabaseManager.shared.getArtist(byId: $0)?.name }
                    ?? NSLocalizedString("unknown_artist", value: "Unknown Artist", comment: "")
                if engine.isPlaying {
                    return .result(dialog: "Now playing \(track.title) by \(artist).")
                }
                return .result(dialog: "\(track.title) by \(artist) is paused.")
            case .pause, .cancelSleepTimer:
                // Handled before the current-track lookup above.
                return .result(dialog: "Paused.")
            }
        } catch {
            throw IntentRuntime.userFacing(error, in: "PlayerCommandIntent")
        }
    }
}

// MARK: - Sleep timer

@available(iOS 26.0, *)
struct SetSleepTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Sleep Timer"
    static let description = IntentDescription(
        "Stops the music in Cosmos after the time you choose.",
        categoryName: "Playback"
    )
    static let supportedModes: IntentModes = .background

    @Parameter(
        title: "Duration",
        requestValueDialog: IntentDialog("For how long?")
    )
    var duration: SleepTimerDuration

    static var parameterSummary: some ParameterSummary {
        Summary("Stop the music in \(\.$duration)")
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        IntentRuntime.begin("SetSleepTimerIntent")
        defer { IntentRuntime.end("SetSleepTimerIntent") }
        SleepTimer.shared.start(minutes: duration.rawValue)
        let minutes = duration.rawValue
        return .result(dialog: "Cosmos will stop playing in \(minutes) minutes.")
    }
}

// MARK: - Queue a named song

@available(iOS 26.0, *)
struct QueueSongIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Queue Song"
    static let description = IntentDescription(
        "Plays a song you name next, or adds it to the end of the queue.",
        categoryName: "Playback"
    )

    @Parameter(title: "Song")
    var songName: String

    @Parameter(title: "Position", default: .next)
    var position: QueuePosition

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$position): \(\.$songName)")
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        IntentRuntime.begin("QueueSongIntent")
        defer { IntentRuntime.end("QueueSongIntent") }
        do {
            guard let track = try await CosmosSiriActions.track(named: songName) else {
                throw VoiceIntentError.songNotFound(songName)
            }
            if PlayerEngine.shared.currentTrack == nil {
                guard await CosmosSiriActions.play([track]) else { throw VoiceIntentError.playbackDidNotStart }
                return .result(dialog: "Playing \(track.title).")
            }
            switch position {
            case .next:
                PlayerEngine.shared.insertNext(track)
                return .result(dialog: "\(track.title) will play next.")
            case .end:
                PlayerEngine.shared.addToQueue(track)
                return .result(dialog: "Added \(track.title) to the queue.")
            }
        } catch {
            throw IntentRuntime.userFacing(error, in: "QueueSongIntent")
        }
    }
}

// MARK: - Create a playlist

@available(iOS 26.0, *)
struct CreatePlaylistIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Playlist"
    static let description = IntentDescription(
        "Creates a playlist in Cosmos, optionally starting with the song playing now.",
        categoryName: "Library"
    )
    static let supportedModes: IntentModes = .background

    @Parameter(
        title: "Name",
        requestValueDialog: IntentDialog("What should the playlist be called?")
    )
    var name: String

    @Parameter(title: "Add the current song", default: true)
    var addCurrentSong: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Create the playlist \(\.$name)") {
            \.$addCurrentSong
        }
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        IntentRuntime.begin("CreatePlaylistIntent")
        defer { IntentRuntime.end("CreatePlaylistIntent") }
        do {
            let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
            // A blank name used to create a nameless playlist: ask again.
            guard !title.isEmpty else {
                throw $name.needsValueError("What should the playlist be called?")
            }
            // Same name (any case) as an existing playlist: use that one
            // rather than making a second of the same name.
            if let existing = try DatabaseManager.shared.playlist(matchingTitle: title) {
                if addCurrentSong,
                   let track = await CosmosSiriActions.currentTrackRestoringSession(),
                   let playlistId = existing.id {
                    // Adding a song already in it is a no-op.
                    try AppCoordinator.shared.addToPlaylist(playlistId: playlistId, trackStableId: track.stableId)
                    return .result(dialog: "You already have \(existing.title). \(track.title) is in it.")
                }
                return .result(dialog: "You already have a playlist called \(existing.title).")
            }
            let playlist = try AppCoordinator.shared.createPlaylist(title: title)
            SiriLibraryDonations.shared.scheduleRefresh(after: 0.5)
            if addCurrentSong,
               let track = await CosmosSiriActions.currentTrackRestoringSession(),
               let playlistId = playlist.id {
                try AppCoordinator.shared.addToPlaylist(playlistId: playlistId, trackStableId: track.stableId)
                return .result(dialog: "Created \(title) with \(track.title).")
            }
            return .result(dialog: "Created the playlist \(title).")
        } catch {
            throw IntentRuntime.userFacing(error, in: "CreatePlaylistIntent")
        }
    }
}

// MARK: - Play by name (Shortcuts, and Siri without Apple Intelligence)

@available(iOS 26.0, *)
struct PlayByNameIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Search and Play"
    static let description = IntentDescription(
        "Plays the playlist, mix, artist, album or song that best matches what you say.",
        categoryName: "Playback"
    )

    @Parameter(
        title: "Name",
        requestValueDialog: IntentDialog("What do you want to hear?")
    )
    var query: String

    @Parameter(title: "Shuffle", default: false)
    var shuffled: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$query)") {
            \.$shuffled
        }
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        IntentRuntime.begin("PlayByNameIntent")
        defer { IntentRuntime.end("PlayByNameIntent") }
        do {
            await CosmosSiriActions.ensureMixesLoaded(timeout: 1)
            switch try await CosmosSiriActions.search(query) {
            case .mix(let mix):
                guard await CosmosSiriActions.play(mix: mix, shuffled: shuffled) else {
                    throw VoiceIntentError.playbackDidNotStart
                }
                return .result(dialog: "Playing \(mix.title).")
            case .tracks(let tracks, let source):
                guard await CosmosSiriActions.play(tracks, shuffled: shuffled || source == "artist", source: source) else { throw VoiceIntentError.playbackDidNotStart }
                return .result(dialog: "Playing \(query).")
            case nil:
                throw VoiceIntentError.nothingFound(query)
            }
        } catch {
            throw IntentRuntime.userFacing(error, in: "PlayByNameIntent")
        }
    }
}

// MARK: - Open a screen (needs the app in front)

@available(iOS 26.0, *)
struct OpenCosmosScreenIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Cosmos Screen"
    static let description = IntentDescription(
        "Opens Cosmos on Home, Library, Search, Liked Songs, Playlists, Artists, Albums, Songs or the player.",
        categoryName: "Navigation"
    )
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Screen", default: .home)
    var screen: CosmosScreen

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$screen)")
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        let router = AppRouter.shared
        switch screen {
        case .home:
            router.isPlayerPresented = false
            router.selectedTab = .home
        case .library:
            router.isPlayerPresented = false
            router.selectedTab = .library
        case .search:
            router.isPlayerPresented = false
            router.selectedTab = .search
        case .likedSongs:
            router.open(.likedSongs, in: .library, replacingStack: true)
        case .playlists:
            router.open(.playlists, in: .library, replacingStack: true)
        case .artists:
            router.open(.artists, in: .library, replacingStack: true)
        case .albums:
            router.open(.albums, in: .library, replacingStack: true)
        case .songs:
            router.open(.allSongs, in: .library, replacingStack: true)
        case .nowPlaying:
            if PlayerEngine.shared.currentTrack == nil {
                await IntentRuntime.restoreSavedSessionIfNeeded()
            }
            router.isPlayerPresented = PlayerEngine.shared.currentTrack != nil
        }
        return .result()
    }
}
