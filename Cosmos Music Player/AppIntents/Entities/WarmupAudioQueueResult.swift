//
//  WarmupAudioQueueResult.swift
//  Cosmos Music Player
//
//  Marker entity for the audio-domain warmup contract; PlayAudioIntent
//  carries it as an optional parameter. No payload.
//

#if canImport(MediaIntents)
import AppIntents

@available(iOS 27.0, *)
@AppEntity(schema: .audio.warmupAudioQueueResult)
struct WarmupAudioQueueResult: TransientAppEntity {
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: LocalizedStringResource(
                "Warmup Audio Queue Result",
                comment: "Diagnostic title for the audio-domain warmup result entity."
            )
        )
    }

    init() {}
}

#endif // canImport(MediaIntents)
