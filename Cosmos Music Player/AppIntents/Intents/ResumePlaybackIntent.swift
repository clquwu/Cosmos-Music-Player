//
//  ResumePlaybackIntent.swift
//  Cosmos Music Player
//
//  Proof-of-chain intent for the new App Intents stack: runs in-process,
//  resolves IntentPlaybackService via @Dependency, and starts audio without
//  opening the app UI.
//

import AppIntents

@available(iOS 26.0, *)
struct ResumePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Resume Playback"
    static let description = IntentDescription(
        "Resumes playing your music where you left off.",
        categoryName: "Playback"
    )

    @Dependency
    var playback: IntentPlaybackService

    @MainActor
    func perform() async throws -> some IntentResult {
        SiriDiag.log("APP ResumePlaybackIntent.perform currentTrack=\(playback.currentTrack?.title ?? "nil")")
        if playback.currentTrack != nil {
            playback.resume()
            return .result()
        }

        // Nothing loaded (cold launch in background): fall back to the library
        let tracks = try playback.allTracks()
        guard !tracks.isEmpty else {
            throw ResumePlaybackError.emptyLibrary
        }
        await playback.play(tracks: tracks)
        return .result()
    }
}

@available(iOS 26.0, *)
enum ResumePlaybackError: Error, CustomLocalizedStringResourceConvertible {
    case emptyLibrary

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .emptyLibrary:
            return "There's no music in your Cosmos library yet."
        }
    }
}
