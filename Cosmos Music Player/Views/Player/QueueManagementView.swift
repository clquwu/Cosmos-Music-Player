import SwiftUI
import GRDB

struct QueueManagementView: View {
    @StateObject private var playerEngine = PlayerEngine.shared
    @StateObject private var artworkManager = ArtworkManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var draggedTrack: Track?
    @State private var settings = DeleteSettings.load()
    @State private var artistNameCache: [Int64: String] = [:]
    @State private var hasScrolledToCurrent = false

    /// Stable row ids, computed once per render so the scroll target and the
    /// ForEach agree on which id belongs to the playing track. Queues can hold
    /// the same track twice, which is why the ids are not just stable ids.
    private var queueRows: [IdentifiedTrackRow] {
        playerEngine.playbackQueue.uniquelyIdentifiedRows()
    }

    private var currentRowId: String? {
        let rows = queueRows
        guard rows.indices.contains(playerEngine.currentIndex) else { return nil }
        return rows[playerEngine.currentIndex].rowId
    }

    /// Shown inside the player, which supplies the title and background.
    var isEmbedded: Bool = false

    var body: some View {
        Group {
            if isEmbedded {
                queueContent
            } else {
                NavigationStack {
                    queueContent
                        .background(ScreenSpecificBackgroundView(screen: .player))
                        .navigationTitle(Localized.playingQueue)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(Localized.done) {
                                    dismiss()
                                }
                            }
                        }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("BackgroundColorChanged"))) { _ in
            settings = DeleteSettings.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cosmosSettingsDidChange)) { _ in
            settings = DeleteSettings.load()
        }
        .onAppear {
            loadArtistNameCache()
        }
    }

    @ViewBuilder
    private var queueContent: some View {
        if playerEngine.playbackQueue.isEmpty {
            CosmosEmptyState(systemImage: "music.note.list", title: Localized.noSongsInQueue)
        } else {
            ScrollViewReader { proxy in
                List {
                    ForEach(queueRows, id: \.rowId) { row in
                        let index = row.index
                        let track = row.track
                        QueueTrackRow(
                            track: track,
                            index: index,
                            isCurrentTrack: index == playerEngine.currentIndex,
                            isDragging: draggedTrack?.stableId == track.stableId,
                            artistName: (try? DatabaseManager.shared.getArtistDisplayName(forTrackStableId: track.stableId, fallbackArtistId: track.artistId)) ?? track.artistId.flatMap { artistNameCache[$0] },
                            onTap: {
                                jumpToTrack(at: index)
                            }
                        )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                    }
                    .onMove(perform: moveItems)
                    .onDelete(perform: deleteItems)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, isEmbedded ? Design.Spacing.s : Design.Spacing.l)
                .task {
                    // Open on the song that is playing rather than at the
                    // top - after an hour of listening the current track is
                    // hundreds of rows down. The list has to lay out before it
                    // can resolve an off-screen row id, and the panel is still
                    // animating in on the first frames, hence the short wait.
                    guard !hasScrolledToCurrent else { return }
                    hasScrolledToCurrent = true
                    try? await Task.sleep(for: .milliseconds(150))
                    scrollToCurrentTrack(with: proxy)
                }
            }
        }
    }

    private func scrollToCurrentTrack(with proxy: ScrollViewProxy) {
        guard let rowId = currentRowId else { return }
        proxy.scrollTo(rowId, anchor: .center)
    }

    private func loadArtistNameCache() {
        do {
            artistNameCache = try DatabaseManager.shared.getAllArtistNamesById()
        } catch {
            print("Failed to load queue artist cache: \(error)")
        }
    }
    
    private func moveItems(from source: IndexSet, to destination: Int) {
        // Get the source index (should be only one item)
        guard let sourceIndex = source.first else { return }

        // Calculate the actual destination index
        let actualDestination = sourceIndex < destination ? destination - 1 : destination

        // Create new queue with the move applied
        var newQueue = playerEngine.playbackQueue
        let movedTrack = newQueue.remove(at: sourceIndex)
        newQueue.insert(movedTrack, at: actualDestination)

        // Calculate new current index
        var newCurrentIndex = playerEngine.currentIndex
        if sourceIndex == playerEngine.currentIndex {
            // The currently playing track was moved
            newCurrentIndex = actualDestination
        } else if sourceIndex < playerEngine.currentIndex && actualDestination >= playerEngine.currentIndex {
            // Track moved from before current to after current
            newCurrentIndex -= 1
        } else if sourceIndex > playerEngine.currentIndex && actualDestination <= playerEngine.currentIndex {
            // Track moved from after current to before current
            newCurrentIndex += 1
        }

        // Update synchronously - SwiftUI List expects data to match immediately after onMove
        playerEngine.playbackQueue = newQueue
        playerEngine.currentIndex = newCurrentIndex
        // Gapless playback may already have handed the old successor's audio to
        // the player node; without this it plays anyway, past the reorder.
        playerEngine.queueDidChange()
        loadArtistNameCache()
    }

    private func deleteItems(at offsets: IndexSet) {
        // Filter out the currently playing track - can't delete it
        let deletableOffsets = offsets.filter { $0 != playerEngine.currentIndex }
        guard !deletableOffsets.isEmpty else { return }

        var newQueue = playerEngine.playbackQueue
        var newCurrentIndex = playerEngine.currentIndex
        var removedTrackIds: [String] = []

        // Sort descending to remove from end first
        for index in deletableOffsets.sorted().reversed() {
            removedTrackIds.append(newQueue[index].stableId)
            newQueue.remove(at: index)
            if index < newCurrentIndex {
                newCurrentIndex -= 1
            }
        }

        // Must update synchronously - SwiftUI List expects data to match immediately after onDelete
        playerEngine.playbackQueue = newQueue
        playerEngine.currentIndex = newCurrentIndex
        playerEngine.queueDidRemoveTracks(removedTrackIds)
    }

    private func jumpToTrack(at index: Int) {
        guard index >= 0 && index < playerEngine.playbackQueue.count else { return }

        Task {
            await playerEngine.playQueueTrack(at: index)
        }
    }
}

struct QueueTrackRow: View {
    let track: Track
    let index: Int
    let isCurrentTrack: Bool
    let isDragging: Bool
    let artistName: String?
    let onTap: () -> Void

    @State private var artworkImage: UIImage?
    @State private var settings = DeleteSettings.load()
    
    var body: some View {
        HStack(spacing: 12) {
            // Album artwork
            ArtworkView(image: artworkImage, cornerRadius: Design.Radius.thumbnail)
                .frame(width: 48, height: 48)
            
            // Track info
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(track.title)
                        .font(.headline)
                        .fontWeight(isCurrentTrack ? .bold : .medium)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    
                    if isCurrentTrack {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption)
                            .foregroundColor(.primary)
                            .accessibilityHidden(true)
                    }
                }
                
                if let artistName, !artistName.isEmpty {
                    Text(artistName)
                        .font(.subheadline)
                        // Not .secondary (about 0.6): the player's shade on
                        // light covers is worked out for this opacity.
                        .foregroundColor(.primary.opacity(PlayerPalette.secondaryTextOpacity))
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            // Drag indicator only
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundColor(.primary.opacity(0.5))
                .accessibilityHidden(true)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(minHeight: 60)
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.artwork, style: .continuous)
                .fill(isCurrentTrack ? Color.primary.opacity(0.12) : Color.clear)
        )
        .accessibilityElement(children: .combine)
        .accessibilityValue(isCurrentTrack ? Localized.nowPlaying : "")
        .accessibilityAddTraits(.isButton)
        .opacity(isDragging ? 0.8 : 1.0)
        .scaleEffect(isDragging ? 1.05 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isDragging)
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
        .onAppear {
            loadArtwork()
        }
        .task {
            if artworkImage == nil {
                loadArtwork()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("BackgroundColorChanged"))) { _ in
            settings = DeleteSettings.load()
        }
        .reloadsArtwork(for: track.stableId) { loadArtwork() }
    }
    
    private func loadArtwork() {
        Task {
            artworkImage = await ArtworkManager.shared.getThumbnail(for: track)
        }
    }
}
