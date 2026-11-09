//
//  ResumePlaybackIntent.swift
//  Cosmos Music Player
//
//  Proof-of-chain intent for the new App Intents stack: runs in-process,
//  resolves IntentPlaybackService via @Dependency, and starts audio without
//  opening the app UI.
//

import AppIntents
import UIKit

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
        IntentRuntime.begin("ResumePlaybackIntent")
        defer { IntentRuntime.end("ResumePlaybackIntent") }
        SiriDiag.log("APP ResumePlaybackIntent.perform currentTrack=\(playback.currentTrack?.title ?? "nil")")
        do {
            if playback.currentTrack != nil {
                // Siri usually reaches a backgrounded app whose audio session
                // went inactive on pause; play() alone then starts nothing.
                if UIApplication.shared.applicationState == .active {
                    playback.resume()
                } else {
                    await playback.resumeRestoredSession()
                }
                return .result()
            }

            // Cold launch in the background: nothing has restored the saved
            // session yet. Falling straight to the library played its first song
            // and replaced the user's queue (and with it their repeat setting).
            // Bounded, so a slow restore can't outlive Siri's response window.
            // Longer than other intents' bound: on a cold launch the database
            // may still be opening, and giving up early is what used to start
            // the library from its first song.
            await IntentRuntime.restoreSavedSessionIfNeeded(timeout: 6)
            if playback.currentTrack != nil {
                await playback.resumeRestoredSession()
                return .result()
            }

            // A session was saved but could not be read in time. Say so
            // rather than replacing the user's queue with the whole library.
            if PlayerEngine.shared.savedSessionIsPendingRestore {
                throw IntentFailure.libraryUnavailable
            }

            // Nothing saved at all: fall back to the library
            let tracks = try playback.allTracks()
            guard !tracks.isEmpty else {
                throw ResumePlaybackError.emptyLibrary
            }
            await playback.play(tracks: tracks)
            return .result()
        } catch {
            throw IntentRuntime.userFacing(error, in: "ResumePlaybackIntent")
        }
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
