//
//  AffinityState.swift
//  Cosmos Music Player
//
//  Like/dislike/cleared state for a song. Cosmos only has favorites, so
//  `like` maps to adding a favorite and `dislike`/`unset` both remove it.
//

#if canImport(MediaIntents)
import AppIntents

@available(iOS 27.0, *)
@AppEnum(schema: .audio.affinityState)
enum AffinityState: String {
    case like
    case dislike
    case unset

    static let caseDisplayRepresentations: [AffinityState: DisplayRepresentation] = [
        .like: DisplayRepresentation(
            title: LocalizedStringResource(
                "Like",
                comment: "AffinityState case label: the person has liked the track."
            )
        ),
        .dislike: DisplayRepresentation(
            title: LocalizedStringResource(
                "Dislike",
                comment: "AffinityState case label: the person has disliked the track."
            )
        ),
        .unset: DisplayRepresentation(
            title: LocalizedStringResource(
                "Unset",
                comment: "AffinityState case label: no affinity expressed for the track."
            )
        )
    ]
}

#endif // canImport(MediaIntents)
