import SwiftUI
import GRDB

struct QueueManagementView: View {
    @StateObject private var playerEngine = PlayerEngine.shared
    @StateObject private var artworkManager = ArtworkManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var draggedTrack: Track?
    @State private var settings = DeleteSettings.load()
    
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
                        
                        Spacer()
                        
                        Text(Localized.playingQueue)
                            .font(.title2)
                            .fontWeight(.semibold)
                        
                        Spacer()
                        
                        // Invisible button for balance
                        Button(Localized.done) {
                            dismiss()
                        }
                        .font(.headline)
                        .opacity(0)
                        .disabled(true)
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
                        List {
                            ForEach(Array(playerEngine.playbackQueue.enumerated()), id: \.element.stableId) { index, track in
                                QueueTrackRow(
                                    track: track,
                                    index: index,
                                    isCurrentTrack: index == playerEngine.currentIndex,
                                    isDragging: draggedTrack?.stableId == track.stableId
                                )
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets())
                            }
                            .onMove(perform: moveItems)
                        }
                        .listStyle(PlainListStyle())
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 16)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("BackgroundColorChanged"))) { _ in
            settings = DeleteSettings.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            settings = DeleteSettings.load()
        }
    }
    
    private func moveItems(from source: IndexSet, to destination: Int) {
        var newQueue = playerEngine.playbackQueue
        var newCurrentIndex = playerEngine.currentIndex
        
        // Get the source index (should be only one item)
        guard let sourceIndex = source.first else { return }
        
        // Calculate the actual destination index
        let actualDestination = sourceIndex < destination ? destination - 1 : destination
        
        // Move the item
        let movedTrack = newQueue.remove(at: sourceIndex)
        newQueue.insert(movedTrack, at: actualDestination)
        
        // Update current playing index
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
        
        // Apply changes
        playerEngine.playbackQueue = newQueue
        playerEngine.currentIndex = newCurrentIndex
    }
}

struct QueueTrackRow: View {
    let track: Track
    let index: Int
    let isCurrentTrack: Bool
    let isDragging: Bool
    
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
                
                if let artistId = track.artistId,
                   let artist = try? DatabaseManager.shared.read({ db in
                       try Artist.fetchOne(db, key: artistId)
                   }) {
                    Text(artist.name)
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
    }
    
    private func loadArtwork() {
        Task {
            artworkImage = await ArtworkManager.shared.getArtwork(for: track)
        }
    }
}

