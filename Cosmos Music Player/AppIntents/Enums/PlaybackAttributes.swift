//
//  PlaybackAttributes.swift
//  Cosmos Music Player
//
//  Modifiers the system passes to PlayAudioIntent so a person can say
//  "Play X shuffled" or "Play X on repeat".
//

#if canImport(MediaIntents)
import AppIntents

@available(iOS 27.0, *)
@AppEnum(schema: .audio.playbackAttributes)
enum PlaybackAttributes: String {
    case shuffle
    case `repeat`

    static let caseDisplayRepresentations: [PlaybackAttributes: DisplayRepresentation] = [
        .shuffle: DisplayRepresentation(
            title: LocalizedStringResource(
                "Shuffle",
                comment: "PlaybackAttributes case label: shuffle the queue."
            )
        ),
        .repeat: DisplayRepresentation(
            title: LocalizedStringResource(
                "Repeat",
                comment: "PlaybackAttributes case label: repeat the queue."
            )
        )
    ]
}

#endif // canImport(MediaIntents)
