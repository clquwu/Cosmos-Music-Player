//
//  PlaySomethingForNowIntent.swift
//  Cosmos Music Player
//
//  "Play something for now" / "for tonight": the mix of the listening mode
//  that fits the moment - its time of day, weekday or weekend, and the
//  output playing now - the way Made for You picks today's modes. Without
//  modes yet, the time-of-day mix, else a Made for You mix.
//
//  Not an App Shortcut: the app already has the ten the system allows. The
//  spoken phrases reach the same code through the SiriKit extension
//  (identifiers mode_now / mode_tonight, SiriPlayRouter); this intent is
//  for Shortcuts and for Siri by the action's name. No Apple Intelligence.
//

import AppIntents
import Foundation

@available(iOS 26.0, *)
struct PlaySomethingForNowIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Something for Now"
    static let description = IntentDescription(
        "Plays the mix for the way you usually listen at this time of day, on the speaker or headphones playing now.",
        categoryName: "Playback"
    )

    @Parameter(title: "For Tonight", default: false)
    var tonight: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Play something for now") {
            \.$tonight
        }
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        IntentRuntime.begin("PlaySomethingForNowIntent")
        defer { IntentRuntime.end("PlaySomethingForNowIntent") }
        let moment: CosmosSiriActions.Moment = tonight ? .tonight : .now
        // Loading the mixes (4.5 s at most), perhaps building one mode's mix
        // and starting it (4 s): bounded, so Siri hears an answer in time.
        let played = await IntentRuntime.withDeadline(10) {
            await CosmosSiriActions.playSomething(for: moment)
        }
        guard let mix = played ?? nil else {
            let empty = ((try? await CosmosSiriActions.read { try $0.getTrackCount() }) ?? 0) == 0
            throw empty ? VoiceIntentError.emptyLibrary : VoiceIntentError.mixesNotReady
        }
        return .result(dialog: "Playing \(mix.title).")
    }
}
