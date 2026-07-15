//
//  CosmosAppShortcuts.swift
//  Cosmos Music Player
//
//  Phrases the system pre-registers with Siri so they work without any
//  Shortcuts app setup. Localized phrases (FR) land in the Phase 5 pass.
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
