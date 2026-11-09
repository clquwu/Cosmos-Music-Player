//
//  PlayerVoiceCommands.swift
//  Cosmos Music Player
//
//  App enums whose values appear inside App Shortcut phrases:
//  "<command> dans Cosmos" and "minuterie de <durée> dans Cosmos". Siri
//  matches the spoken words against each case's title and synonyms, which
//  are localized in Localizable.strings (EN/FR/RU).
//

import AppIntents

@available(iOS 26.0, *)
enum PlayerVoiceCommand: String, AppEnum {
    case pause
    case next
    case previous
    case restart
    case shuffleOn
    case shuffleOff
    case repeatOn
    case repeatOne
    case repeatOff
    case unlike
    case nowPlaying
    case cancelSleepTimer

    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Player Command", comment: "Type name of the Cosmos player command enum.")
    )

    static let caseDisplayRepresentations: [PlayerVoiceCommand: DisplayRepresentation] = [
        .pause: DisplayRepresentation(
            title: "Pause the music",
            synonyms: ["Pause", "Stop the music", "Pause playback"]
        ),
        .next: DisplayRepresentation(
            title: "Next song",
            synonyms: ["Skip this song", "Skip", "Play the next song"]
        ),
        .previous: DisplayRepresentation(
            title: "Previous song",
            synonyms: ["Go back", "Play the previous song", "Previous"]
        ),
        .restart: DisplayRepresentation(
            title: "Restart this song",
            synonyms: ["Play this song again", "Start the song over"]
        ),
        .shuffleOn: DisplayRepresentation(
            title: "Turn on shuffle",
            synonyms: ["Shuffle on", "Shuffle the queue", "Shuffle"]
        ),
        .shuffleOff: DisplayRepresentation(
            title: "Turn off shuffle",
            synonyms: ["Shuffle off", "Stop shuffling"]
        ),
        .repeatOn: DisplayRepresentation(
            title: "Turn on repeat",
            synonyms: ["Repeat on", "Repeat the queue", "Repeat all"]
        ),
        .repeatOne: DisplayRepresentation(
            title: "Repeat this song",
            synonyms: ["Loop this song", "Repeat one"]
        ),
        .repeatOff: DisplayRepresentation(
            title: "Turn off repeat",
            synonyms: ["Repeat off", "Stop repeating"]
        ),
        .unlike: DisplayRepresentation(
            title: "Unlike this song",
            synonyms: ["Remove this song from favorites", "Remove this song from Liked Songs", "I don't like this song"]
        ),
        .nowPlaying: DisplayRepresentation(
            title: "What's playing",
            synonyms: ["What song is this", "What's this song", "Who sings this"]
        ),
        .cancelSleepTimer: DisplayRepresentation(
            title: "Cancel the sleep timer",
            synonyms: ["Turn off the sleep timer", "Stop the sleep timer"]
        )
    ]
}

@available(iOS 26.0, *)
enum SleepTimerDuration: Int, AppEnum {
    case minutes5 = 5
    case minutes10 = 10
    case minutes15 = 15
    case minutes20 = 20
    case minutes30 = 30
    case minutes45 = 45
    case minutes60 = 60
    case minutes90 = 90
    case minutes120 = 120

    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Sleep Timer Duration", comment: "Type name of the sleep timer duration enum.")
    )

    static let caseDisplayRepresentations: [SleepTimerDuration: DisplayRepresentation] = [
        .minutes5: DisplayRepresentation(title: "5 minutes", synonyms: ["five minutes"]),
        .minutes10: DisplayRepresentation(title: "10 minutes", synonyms: ["ten minutes"]),
        .minutes15: DisplayRepresentation(title: "15 minutes", synonyms: ["fifteen minutes", "a quarter of an hour"]),
        .minutes20: DisplayRepresentation(title: "20 minutes", synonyms: ["twenty minutes"]),
        .minutes30: DisplayRepresentation(title: "30 minutes", synonyms: ["thirty minutes", "half an hour"]),
        .minutes45: DisplayRepresentation(title: "45 minutes", synonyms: ["forty-five minutes", "three quarters of an hour"]),
        .minutes60: DisplayRepresentation(title: "1 hour", synonyms: ["an hour", "one hour", "60 minutes"]),
        .minutes90: DisplayRepresentation(title: "90 minutes", synonyms: ["an hour and a half", "one and a half hours"]),
        .minutes120: DisplayRepresentation(title: "2 hours", synonyms: ["two hours", "120 minutes"])
    ]
}

@available(iOS 26.0, *)
enum QueuePosition: String, AppEnum {
    case next
    case end

    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Queue Position", comment: "Type name of the queue position enum.")
    )

    static let caseDisplayRepresentations: [QueuePosition: DisplayRepresentation] = [
        .next: DisplayRepresentation(title: "Play next", synonyms: ["next", "after this song"]),
        .end: DisplayRepresentation(title: "Add to queue", synonyms: ["later", "at the end of the queue"])
    ]
}

@available(iOS 26.0, *)
enum CosmosScreen: String, AppEnum {
    case home
    case library
    case search
    case likedSongs
    case playlists
    case artists
    case albums
    case songs
    case nowPlaying

    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Screen", comment: "Type name of the Cosmos screen enum.")
    )

    static let caseDisplayRepresentations: [CosmosScreen: DisplayRepresentation] = [
        .home: DisplayRepresentation(title: "Home"),
        .library: DisplayRepresentation(title: "Library", synonyms: ["my library"]),
        .search: DisplayRepresentation(title: "Search"),
        .likedSongs: DisplayRepresentation(title: "Liked Songs", synonyms: ["favorites"]),
        .playlists: DisplayRepresentation(title: "Playlists"),
        .artists: DisplayRepresentation(title: "Artists"),
        .albums: DisplayRepresentation(title: "Albums"),
        .songs: DisplayRepresentation(title: "Songs", synonyms: ["all songs"]),
        .nowPlaying: DisplayRepresentation(title: "Now Playing", synonyms: ["the player"])
    ]
}
