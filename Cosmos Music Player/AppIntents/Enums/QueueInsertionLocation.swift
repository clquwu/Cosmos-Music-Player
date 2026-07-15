//
//  QueueInsertionLocation.swift
//  Cosmos Music Player
//
//  Where PlayAudioIntent places the requested tracks in the playback queue.
//

#if canImport(MediaIntents)
import AppIntents

@available(iOS 27.0, *)
@AppEnum(schema: .audio.queueInsertionLocation)
enum QueueInsertionLocation: String {
    case next
    case tail

    static let caseDisplayRepresentations: [QueueInsertionLocation: DisplayRepresentation] = [
        .next: DisplayRepresentation(
            title: LocalizedStringResource(
                "Next",
                comment: "QueueInsertionLocation case label: insert right after the current track."
            )
        ),
        .tail: DisplayRepresentation(
            title: LocalizedStringResource(
                "Last",
                comment: "QueueInsertionLocation case label: append to the end of the queue."
            )
        )
    ]
}

#endif // canImport(MediaIntents)
