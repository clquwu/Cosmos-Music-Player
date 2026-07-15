//
//  PlaylistCardSnippetIntent.swift
//  Cosmos Music Player
//
//  Interactive playlist card shown as a Siri/Shortcuts result: title,
//  track count and duration, plus a play button.
//

#if canImport(MediaIntents)
import AppIntents
import SwiftUI

@available(iOS 27.0, *)
struct PlaylistCardSnippetIntent: SnippetIntent {
    static let title: LocalizedStringResource = LocalizedStringResource(
        "Playlist Card",
        comment: "Title of the snippet intent that renders a playlist result card."
    )
    static let isDiscoverable = false

    @Parameter(title: "Playlist")
    var playlistId: String

    @Dependency var store: IntentEntityStore

    init() {}

    init(playlistId: String) {
        self.playlistId = playlistId
    }

    @MainActor
    func perform() async throws -> some IntentResult & ShowsSnippetView {
        guard let playlist = try store.playlistEntities(for: [playlistId]).first else {
            throw AppIntentError(wrapping: AudioIntentError.noAudioEntity)
        }
        return .result(view: PlaylistCardSnippetView(
            playlistId: playlistId,
            title: playlist.title,
            trackCount: playlist.trackCount,
            totalDuration: playlist.totalDuration
        ))
    }
}

@available(iOS 27.0, *)
struct PlaylistCardSnippetView: View {
    let playlistId: String
    let title: String
    let trackCount: Int
    let totalDuration: TimeInterval

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.regularMaterial)
                Image(systemName: "music.note.list")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button(intent: PlayPlaylistIntent(playlistId: playlistId)) {
                Image(systemName: "play.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(
                "Play playlist",
                comment: "Accessibility label for the snippet button that starts playing the playlist."
            ))
        }
        .padding()
    }

    private var subtitle: LocalizedStringKey {
        let totalMinutes = Int(totalDuration) / 60
        return "^[\(trackCount) song](inflect: true) · \(totalMinutes) min"
    }
}

#endif // canImport(MediaIntents)
