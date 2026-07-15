//
//  SongCardSnippetIntent.swift
//  Cosmos Music Player
//
//  Interactive song card shown as a Siri/Shortcuts result: artwork, title,
//  artist, a heart button and queue buttons. The system re-runs this intent
//  after any button fires, so the card always renders current state.
//

#if canImport(MediaIntents)
import AppIntents
import SwiftUI

@available(iOS 27.0, *)
struct SongCardSnippetIntent: SnippetIntent {
    static let title: LocalizedStringResource = LocalizedStringResource(
        "Song Card",
        comment: "Title of the snippet intent that renders a song result card."
    )
    static let isDiscoverable = false

    @Parameter(title: "Track")
    var trackStableId: String

    @Dependency var playback: IntentPlaybackService
    @Dependency var store: IntentEntityStore

    init() {}

    init(trackStableId: String) {
        self.trackStableId = trackStableId
    }

    @MainActor
    func perform() async throws -> some IntentResult & ShowsSnippetView {
        guard let track = try playback.tracks(forStableIds: [trackStableId]).first,
              let song = try store.songEntities(from: [track]).first else {
            throw AppIntentError(wrapping: AudioIntentError.noAudioEntity)
        }
        let isLiked = try playback.isFavorite(trackStableId: track.stableId)
        let artwork = await ArtworkManager.shared.getThumbnail(for: track, maxPixelSize: 256)

        return .result(view: SongCardSnippetView(
            trackStableId: track.stableId,
            title: song.title,
            artistName: song.artistName,
            isLiked: isLiked,
            artwork: artwork
        ))
    }
}

@available(iOS 27.0, *)
struct SongCardSnippetView: View {
    let trackStableId: String
    let title: String
    let artistName: String
    let isLiked: Bool
    let artwork: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            artworkView
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(artistName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            HStack(spacing: 14) {
                Button(intent: EnqueueTrackIntent(trackStableId: trackStableId, playNext: true)) {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                        .font(.body)
                }
                .accessibilityLabel(Text(
                    "Play next",
                    comment: "Accessibility label for the snippet button that queues the song right after the current one."
                ))

                Button(intent: EnqueueTrackIntent(trackStableId: trackStableId, playNext: false)) {
                    Image(systemName: "text.append")
                        .font(.body)
                }
                .accessibilityLabel(Text(
                    "Add to queue",
                    comment: "Accessibility label for the snippet button that appends the song to the queue."
                ))

                Button(intent: ToggleFavoriteIntent(trackStableId: trackStableId)) {
                    Image(systemName: isLiked ? "heart.fill" : "heart")
                        .font(.title3)
                        .foregroundStyle(isLiked ? Color.pink : Color.secondary)
                }
                .accessibilityLabel(isLiked
                    ? Text("Remove from favorites", comment: "Accessibility label for the snippet heart button when the song is a favorite.")
                    : Text("Add to favorites", comment: "Accessibility label for the snippet heart button when the song is not a favorite."))
            }
            .buttonStyle(.plain)
        }
        .padding()
    }

    @ViewBuilder
    private var artworkView: some View {
        if let artwork {
            Image(uiImage: artwork)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.regularMaterial)
                Image(systemName: "music.note")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#endif // canImport(MediaIntents)
