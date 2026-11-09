//
//  CosmosAppShortcuts.swift
//  Cosmos Music Player
//
//  Phrases the system pre-registers with Siri so they work without any
//  Shortcuts app setup and without Apple Intelligence. French and Russian
//  phrases live in Resources/<lang>.lproj/AppShortcuts.strings.
//
//  The system allows 10 App Shortcuts; all 10 are used:
//   1 Resume            2 Liked Songs        3 Like this song
//   4 Generate a mix    5 Play a mix         6 Song radio
//   7 Shuffle (artist)  8 Sleep timer        9 Player commands
//  10 Add this song to a playlist
//  Everything else (queue a song, create a playlist, open a screen, play by
//  name) is a discoverable App Intent; plain "play <song/album/artist/
//  playlist>" goes through the SiriKit extension and the .audio schema.
//
//  Parameterised phrases (mix, artist, playlist) are refreshed by
//  SiriLibraryDonations via updateAppShortcutParameters().
//

import AppIntents

@available(iOS 26.0, *)
struct CosmosAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ResumePlaybackIntent(),
            phrases: [
                "Resume playback in \(.applicationName)",
                "Resume my music in \(.applicationName)",
                "Continue playing in \(.applicationName)"
            ],
            shortTitle: "Resume Playback",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: PlayLikedSongsIntent(),
            phrases: [
                "Play my liked songs in \(.applicationName)",
                "Play my favorites in \(.applicationName)",
                "Play my favourite songs in \(.applicationName)",
                "Shuffle my liked songs in \(.applicationName)",
                "Play my loved songs in \(.applicationName)",
                "Play the songs I like in \(.applicationName)"
            ],
            shortTitle: "Play Liked Songs",
            systemImageName: "heart.circle.fill"
        )
        AppShortcut(
            intent: FavoriteCurrentSongIntent(),
            phrases: [
                "Like this song in \(.applicationName)",
                "Add this song to favorites in \(.applicationName)",
                "Add this song to my favorites in \(.applicationName)",
                "Add this song to Liked Songs in \(.applicationName)",
                "Add the current song to favorites in \(.applicationName)"
            ],
            shortTitle: "Favorite Current Song",
            systemImageName: "heart.fill"
        )
        AppShortcut(
            intent: PlayMixIntent(),
            phrases: [
                "Play \(\.$mix) in \(.applicationName)",
                "Play the \(\.$mix) mix in \(.applicationName)",
                "Play my mix \(\.$mix) in \(.applicationName)",
                "Play a mix made for me in \(.applicationName)",
                "Play my mixes in \(.applicationName)"
            ],
            shortTitle: "Play Mix",
            systemImageName: "sparkles.rectangle.stack"
        )
        AppShortcut(
            intent: PlaySongRadioIntent(),
            phrases: [
                "Play a mix like this song in \(.applicationName)",
                "Play more like this in \(.applicationName)",
                "Start a radio from this song in \(.applicationName)",
                "Play similar songs in \(.applicationName)",
                "Play songs like this one in \(.applicationName)"
            ],
            shortTitle: "Song Mix",
            systemImageName: "dot.radiowaves.left.and.right"
        )
        AppShortcut(
            intent: PlayerCommandIntent(),
            phrases: [
                "\(\.$command) in \(.applicationName)",
                "\(\.$command) on \(.applicationName)",
                "\(.applicationName) \(\.$command)"
            ],
            shortTitle: "Control Playback",
            systemImageName: "playpause.fill"
        )
        AppShortcut(
            intent: SetSleepTimerIntent(),
            phrases: [
                "Set a sleep timer in \(.applicationName)",
                "Set a sleep timer for \(\.$duration) in \(.applicationName)",
                "Stop the music in \(\.$duration) with \(.applicationName)",
                "Sleep timer \(\.$duration) in \(.applicationName)"
            ],
            shortTitle: "Sleep Timer",
            systemImageName: "moon.zzz.fill"
        )
        #if canImport(MediaIntents)
        if #available(iOS 27.0, *) {
            AppShortcut(
                intent: ShuffleMusicIntent(),
                phrases: [
                    "Shuffle my music in \(.applicationName)",
                    "Shuffle my library in \(.applicationName)",
                    "Shuffle all my songs in \(.applicationName)",
                    "Shuffle \(\.$artist) in \(.applicationName)",
                    "Play \(\.$artist) shuffled in \(.applicationName)",
                    "Shuffle songs by \(\.$artist) in \(.applicationName)"
                ],
                shortTitle: "Shuffle Music",
                systemImageName: "shuffle"
            )
            AppShortcut(
                intent: AddCurrentSongToPlaylistIntent(),
                phrases: [
                    "Add this song to \(\.$playlist) in \(.applicationName)",
                    "Add this song to my \(\.$playlist) playlist in \(.applicationName)",
                    "Add the current song to \(\.$playlist) in \(.applicationName)"
                ],
                shortTitle: "Add to Playlist",
                systemImageName: "text.badge.plus"
            )
        }
        #endif
        #if canImport(FoundationModels)
        AppShortcut(
            intent: GenerateMixIntent(),
            phrases: [
                "Make me a mix in \(.applicationName)",
                "Generate a mix in \(.applicationName)",
                "Play me something new in \(.applicationName)"
            ],
            shortTitle: "Generate Mix",
            systemImageName: "wand.and.stars"
        )
        #endif
    }
}
