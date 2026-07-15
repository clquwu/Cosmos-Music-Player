//
//  GenerateMixIntent.swift
//  Cosmos Music Player
//
//  "Make me a chill evening mix" — on-device Foundation Models pick songs
//  from the library, playback starts immediately, and the result snippet
//  offers saving the mix as a playlist. Siri/Shortcuts only, no in-app UI.
//

#if canImport(FoundationModels)
import AppIntents
import SwiftUI

@available(iOS 26.0, *)
struct GenerateMixIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = LocalizedStringResource(
        "Generate Mix",
        comment: "Title of the Generate Mix intent."
    )
    static let description = IntentDescription(
        LocalizedStringResource(
            "Builds a mix from your Cosmos library matching a mood or description and starts playing it.",
            comment: "Description of the Generate Mix intent shown in the Shortcuts gallery."
        ),
        categoryName: LocalizedStringResource(
            "Playback",
            comment: "Shortcuts gallery category name for Cosmos playback intents."
        )
    )

    @Parameter(
        title: LocalizedStringResource("Description", comment: "Title of the mix description parameter."),
        requestValueDialog: IntentDialog(LocalizedStringResource(
            "What kind of mix do you want?",
            comment: "Siri prompt asking what the generated mix should sound like."
        ))
    )
    var mixDescription: String

    @Dependency var playback: IntentPlaybackService

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetIntent {
        let mix = try await MixGenerator().generate(matching: mixDescription)

        await playback.play(tracks: mix.tracks)
        playback.setPendingMix(title: mix.title, tracks: mix.tracks)

        let dialog = IntentDialog(
            full: LocalizedStringResource(
                "Playing your mix: \(mix.title).",
                comment: "Spoken confirmation when a generated mix starts playing. Argument 1 is the mix title."
            ),
            supporting: LocalizedStringResource(
                "Now playing",
                comment: "Short on-screen confirmation paired with the full dialog when a generated mix starts playing."
            )
        )
        return .result(dialog: dialog, snippetIntent: MixCardSnippetIntent())
    }
}

// MARK: - Save action

@available(iOS 26.0, *)
struct SaveMixIntent: AppIntent {
    static let title: LocalizedStringResource = LocalizedStringResource(
        "Save Mix as Playlist",
        comment: "Title of the hidden intent behind the save button on mix snippets."
    )
    static let isDiscoverable = false

    @Dependency var playback: IntentPlaybackService

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try playback.savePendingMix()
        return .result()
    }
}

// MARK: - Result snippet

@available(iOS 26.0, *)
struct MixCardSnippetIntent: SnippetIntent {
    static let title: LocalizedStringResource = LocalizedStringResource(
        "Mix Card",
        comment: "Title of the snippet intent that renders a generated mix result card."
    )
    static let isDiscoverable = false

    @Dependency var playback: IntentPlaybackService

    @MainActor
    func perform() async throws -> some IntentResult & ShowsSnippetView {
        guard let mix = playback.pendingMix else {
            throw MixGenerationError.mixUnavailable
        }
        return .result(view: MixCardSnippetView(
            title: mix.title,
            trackCount: mix.tracks.count,
            isSaved: mix.savedPlaylistId != nil
        ))
    }
}

@available(iOS 26.0, *)
struct MixCardSnippetView: View {
    let title: String
    let trackCount: Int
    let isSaved: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.regularMaterial)
                Image(systemName: "wand.and.stars")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("^[\(trackCount) song](inflect: true)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if isSaved {
                Label {
                    Text("Saved", comment: "Shown on the mix snippet after the mix has been saved as a playlist.")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                }
                .font(.subheadline)
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
            } else {
                Button(intent: SaveMixIntent()) {
                    Label {
                        Text("Save", comment: "Title of the mix snippet button that saves the mix as a playlist.")
                    } icon: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .font(.subheadline)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .accessibilityLabel(Text(
                    "Save mix as playlist",
                    comment: "Accessibility label for the snippet button that saves the generated mix as a playlist."
                ))
            }
        }
        .padding()
    }
}

#endif // canImport(FoundationModels)
