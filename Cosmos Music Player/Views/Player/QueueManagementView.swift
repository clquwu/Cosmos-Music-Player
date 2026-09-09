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

    var body: some View {
        NavigationView {
            ZStack {
                ScreenSpecificBackgroundView(screen: .player)

                VStack(spacing: 20) {
                    // Header
                    HStack {
                        Button(Localized.done) {
                            dismiss()
                        }
                        .font(.headline)
                        .frame(minWidth: 64, alignment: .leading)

                        Spacer()

                        Text(Localized.playingQueue)
                            .font(.title2)
                            .fontWeight(.semibold)

                        Spacer()

                        // Empty counterweight so the title stays centred
                        // against the leading Done button.
                        Color.clear.frame(width: 64, height: 0)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    
                    if playerEngine.playbackQueue.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "music.note.list")
                                .font(.system(size: 60))
                                .foregroundColor(.secondary)
                            
                            Text(Localized.noSongsInQueue)
                                .font(.headline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                            .listStyle(PlainListStyle())
                            .scrollContentBackground(.hidden)
                            .padding(.horizontal, 16)
                            .task {
                                // Open on the song that is playing rather than
                                // at the top - after an hour of listening the
                                // current track is hundreds of rows down. The
                                // list has to lay out before it can resolve an
                                // off-screen row id, and the sheet is still
                                // animating in on the first frames, hence the
                                // short wait.
                                guard !hasScrolledToCurrent else { return }
                                hasScrolledToCurrent = true
                                try? await Task.sleep(for: .milliseconds(150))
                                scrollToCurrentTrack(with: proxy)
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
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 50, height: 50)
                
                if let image = artworkImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 50, height: 50)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: "music.note")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
            }
            
            // Track info
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(track.title)
                        .font(.headline)
                        .fontWeight(isCurrentTrack ? .bold : .medium)
                        .foregroundColor(isCurrentTrack ? settings.backgroundColorChoice.color : .primary)
                        .lineLimit(1)
                    
                    if isCurrentTrack {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption)
                            .foregroundColor(settings.backgroundColorChoice.color)
                    }
                }
                
                if let artistName, !artistName.isEmpty {
                    Text(artistName)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            // Drag indicator only
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.6))
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isCurrentTrack ? settings.backgroundColorChoice.color.opacity(0.15) : Color.clear)
        )
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
