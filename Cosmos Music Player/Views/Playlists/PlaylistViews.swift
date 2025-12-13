import SwiftUI
import GRDB
import PhotosUI
import WidgetKit


struct PlaylistsScreen: View {
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var playlists: [Playlist] = []
    @State private var isEditMode: Bool = false
    @State private var playlistToEdit: Playlist?
    @State private var playlistToDelete: Playlist?
    @State private var showEditDialog = false
    @State private var showDeleteConfirmation = false
    @State private var editPlaylistName = ""
    
    var body: some View {
        ZStack {
            ScreenSpecificBackgroundView(screen: .playlists)
            
            VStack {
                if playlists.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        
                        Text(Localized.noPlaylistsYet)
                            .font(.headline)
                        
                        Text(Localized.createPlaylistsInstruction)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [
                            GridItem(.flexible(), spacing: 8),
                            GridItem(.flexible(), spacing: 8)
                        ], spacing: 16) {
                            ForEach(playlists, id: \.id) { playlist in
                                if isEditMode {
                                    PlaylistCardView(playlist: playlist, allTracks: getAllPlaylistTracks(playlist), isEditMode: true, onEdit: {
                                        playlistToEdit = playlist
                                        editPlaylistName = playlist.title
                                        showEditDialog = true
                                    }, onDelete: {
                                        playlistToDelete = playlist
                                        showDeleteConfirmation = true
                                    })
                                } else {
                                    NavigationLink {
                                        PlaylistDetailScreen(playlist: playlist)
                                    } label: {
                                        PlaylistCardView(playlist: playlist, allTracks: getAllPlaylistTracks(playlist))
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }
                        }
                        .padding(16)
                        .padding(.bottom, 100) // Add padding for mini player
                    }
                }
            }
            .navigationTitle(Localized.playlists)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(isEditMode ? Localized.done : Localized.edit) {
                        withAnimation {
                            isEditMode.toggle()
                        }
                    }
                    .disabled(playlists.isEmpty)
                }
            }
            .alert(Localized.editPlaylist, isPresented: $showEditDialog) {
                TextField(Localized.playlistNamePlaceholder, text: $editPlaylistName)
                Button(Localized.save) {
                    if let playlist = playlistToEdit, !editPlaylistName.isEmpty {
                        editPlaylist(playlist, newName: editPlaylistName)
                    }
                }
                .disabled(editPlaylistName.isEmpty)
                Button(Localized.cancel, role: .cancel) { }
            } message: {
                Text(Localized.enterNewName)
            }
            .alert(Localized.deletePlaylist, isPresented: $showDeleteConfirmation) {
                Button(Localized.delete, role: .destructive) {
                    if let playlist = playlistToDelete {
                        deletePlaylist(playlist)
                    }
                }
                Button(Localized.cancel, role: .cancel) { }
            } message: {
                if let playlist = playlistToDelete {
                    Text(Localized.deletePlaylistConfirmation(playlist.title))
                }
            }
            .onAppear {
                loadPlaylists()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LibraryNeedsRefresh"))) { _ in
                loadPlaylists()
            }
        }
    }
    
    private func getAllPlaylistTracks(_ playlist: Playlist) -> [Track] {
        guard let playlistId = playlist.id else { return [] }
        do {
            let playlistItems = try appCoordinator.databaseManager.getPlaylistItems(playlistId: playlistId)
            var tracks: [Track] = []
            for item in playlistItems {
                if let track = try appCoordinator.databaseManager.getTrack(byStableId: item.trackStableId) {
                    tracks.append(track)
                }
            }
            return tracks
        } catch {
            print("Failed to get playlist tracks: \(error)")
            return []
        }
    }
    
    private func loadPlaylists() {
        do {
            playlists = try appCoordinator.databaseManager.getAllPlaylists()
        } catch {
            print("Failed to load playlists: \(error)")
        }
    }

    private func editPlaylist(_ playlist: Playlist, newName: String) {
        guard let playlistId = playlist.id else { return }
        do {
            try appCoordinator.renamePlaylist(playlistId: playlistId, newTitle: newName)
            loadPlaylists()
            playlistToEdit = nil
            editPlaylistName = ""
        } catch {
            print("Failed to rename playlist: \(error)")
        }
    }

    private func deletePlaylist(_ playlist: Playlist) {
        guard let playlistId = playlist.id else { return }
        do {
            try appCoordinator.deletePlaylist(playlistId: playlistId)
            loadPlaylists()
            playlistToDelete = nil
        } catch {
            print("Failed to delete playlist: \(error)")
        }
    }
}

struct PlaylistCardView: View {
    let playlist: Playlist
    let allTracks: [Track]
    let isEditMode: Bool
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?
    @StateObject private var artworkManager = ArtworkManager.shared
    @State private var artworks: [UIImage] = []
    @State private var customCoverImage: UIImage?
    @State private var showingImagePicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?

    init(playlist: Playlist, allTracks: [Track], isEditMode: Bool = false, onEdit: (() -> Void)? = nil, onDelete: (() -> Void)? = nil) {
        self.playlist = playlist
        self.allTracks = allTracks
        self.isEditMode = isEditMode
        self.onEdit = onEdit
        self.onDelete = onDelete
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Artwork area
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.2))
                    .aspectRatio(1, contentMode: .fit)

                // Edit mode overlay with buttons - always on top
                if isEditMode {
                    VStack {
                        HStack {
                            Button(action: {
                                onEdit?()
                            }) {
                                Image(systemName: "pencil")
                                    .font(.title2)
                                    .foregroundColor(.black)
                                    .frame(width: 36, height: 36)
                                    .background(.ultraThinMaterial, in: Circle())
                                    .overlay(
                                        Circle()
                                            .stroke(.black.opacity(0.3), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(PlainButtonStyle())

                            Spacer()

                            Button(action: {
                                onDelete?()
                            }) {
                                Image(systemName: "trash")
                                    .font(.title2)
                                    .foregroundColor(.red)
                                    .frame(width: 36, height: 36)
                                    .background(.ultraThinMaterial, in: Circle())
                                    .overlay(
                                        Circle()
                                            .stroke(.red.opacity(0.3), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        Spacer()

                        // Centered photo icon for changing cover
                        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                            Image(systemName: "photo")
                                .font(.system(size: 32, weight: .light))
                                .foregroundColor(.white)
                                .frame(width: 64, height: 64)
                                .background(Color.black.opacity(0.6))
                                .clipShape(Circle())
                        }
                        .buttonStyle(PlainButtonStyle())

                        Spacer()
                    }
                    .padding(8)
                    .zIndex(1000)
                }
                
                // Artwork content - same in both edit and normal mode
                // Show custom cover if available, otherwise show auto-generated mashup
                if let customCover = customCoverImage {
                    Image(uiImage: customCover)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fit)
                        .clipped()
                } else if allTracks.count >= 4 {
                    // 2x2 mashup for 4+ songs
                    GeometryReader { geometry in
                        let size = (geometry.size.width - 2) / 2
                        VStack(spacing: 2) {
                            HStack(spacing: 2) {
                                artworkView(at: 0, size: size)
                                artworkView(at: 1, size: size)
                            }
                            HStack(spacing: 2) {
                                artworkView(at: 2, size: size)
                                artworkView(at: 3, size: size)
                            }
                        }
                    }
                } else if !allTracks.isEmpty {
                    // Single artwork for 1-3 songs
                    GeometryReader { geometry in
                        artworkView(at: 0, size: geometry.size.width)
                    }
                } else {
                    // Default icon for empty playlist
                    Image(systemName: "music.note.list")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))

            // Text info
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.title)
                    .font(.headline)
                    .lineLimit(1)
                
                Text(Localized.songsCount(allTracks.count))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .task {
            await loadCustomCover()
            await loadArtworks()
        }
        .onChange(of: selectedPhotoItem) { newItem in
            Task {
                if let data = try? await newItem?.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    await saveCustomCover(image)
                }
            }
        }
    }
    
    @ViewBuilder
    private func artworkView(at index: Int, size: CGFloat?) -> some View {
        if index < artworks.count {
            Image(uiImage: artworks[index])
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: index < 4 && allTracks.count >= 4 ? 6 : 12))
        } else if index < allTracks.count {
            RoundedRectangle(cornerRadius: index < 4 && allTracks.count >= 4 ? 6 : 12)
                .fill(Color.gray.opacity(0.3))
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "music.note")
                        .foregroundColor(.secondary)
                        .font(.system(size: size != nil ? size!/4 : 40))
                )
        }
    }
    
    private func loadArtworks() async {
        var loadedArtworks: [UIImage] = []
        let tracksToLoad = Array(allTracks.prefix(4))

        for track in tracksToLoad {
            if let artwork = await artworkManager.getArtwork(for: track) {
                loadedArtworks.append(artwork)
            }
        }

        await MainActor.run {
            artworks = loadedArtworks
        }
    }

    private func loadCustomCover() async {
        // Check if playlist has a custom cover path
        guard let customPath = playlist.customCoverImagePath,
              !customPath.isEmpty else { return }

        // Load image from shared container
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.dev.clq.Cosmos-Music-Player"
        ) else { return }

        let fileURL = containerURL.appendingPathComponent(customPath)
        if let data = try? Data(contentsOf: fileURL),
           let image = UIImage(data: data) {
            await MainActor.run {
                customCoverImage = image
            }
        }
    }

    @MainActor
    private func saveCustomCover(_ image: UIImage) async {
        guard let playlistId = playlist.id else { return }

        // Get shared container
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.dev.clq.Cosmos-Music-Player"
        ) else {
            print("❌ Failed to get shared container URL")
            return
        }

        // Create unique filename for this playlist cover
        let filename = "playlist_cover_\(playlistId).jpg"
        let fileURL = containerURL.appendingPathComponent(filename)

        // Convert image to JPEG data with compression
        guard let jpegData = image.jpegData(compressionQuality: 0.8) else {
            print("❌ Failed to convert image to JPEG")
            return
        }

        do {
            // Save image to shared container
            try jpegData.write(to: fileURL)
            print("✅ Saved custom cover to \(filename)")

            // Update database with custom cover path
            try DatabaseManager.shared.updatePlaylistCustomCover(
                playlistId: playlistId,
                imagePath: filename
            )

            // Update UI
            customCoverImage = image

            // Notify widgets to refresh
            WidgetCenter.shared.reloadAllTimelines()

            // Refresh the playlist list
            NotificationCenter.default.post(name: NSNotification.Name("LibraryNeedsRefresh"), object: nil)

            print("✅ Custom cover saved and database updated")
        } catch {
            print("❌ Failed to save custom cover: \(error)")
        }
    }
}

struct PlaylistDetailScreen: View {
    let playlist: Playlist
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var tracks: [Track] = []
    @State private var isEditMode: Bool = false
    @State private var artworks: [UIImage] = []
    @State private var settings = DeleteSettings.load()
    @State private var sortOption: TrackSortOption = .playlistOrder
    @State private var showSortMenu = false
    @State private var recentlyActedTracks: Set<String> = []
    @StateObject private var artworkManager = ArtworkManager.shared
    @State private var showingImagePicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var customCoverImage: UIImage?
    @State private var showCoverOptions = false

    private var playerEngine: PlayerEngine {
        appCoordinator.playerEngine
    }

    private func markAsActed(_ trackId: String) {
        recentlyActedTracks.insert(trackId)
        // Remove after 1 second so user can swipe again if needed
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            recentlyActedTracks.remove(trackId)
        }
    }

    private var sortedTracks: [Track] {
        // Filter out incompatible formats when connected to CarPlay
        let filteredTracks: [Track]
        if SFBAudioEngineManager.shared.isCarPlayEnvironment {
            filteredTracks = tracks.filter { track in
                let ext = URL(fileURLWithPath: track.path).pathExtension.lowercased()
                let incompatibleFormats = ["ogg", "opus", "dsf", "dff"]
                return !incompatibleFormats.contains(ext)
            }
        } else {
            filteredTracks = tracks
        }

        switch sortOption {
        case .playlistOrder:
            // Respect the playlist position order (tracks are already loaded in position order)
            return filteredTracks
        case .dateNewest:
            return filteredTracks.sorted { ($0.id ?? 0) > ($1.id ?? 0) }
        case .dateOldest:
            return filteredTracks.sorted { ($0.id ?? 0) < ($1.id ?? 0) }
        case .nameAZ:
            return filteredTracks.sorted { $0.title.lowercased() < $1.title.lowercased() }
        case .nameZA:
            return filteredTracks.sorted { $0.title.lowercased() > $1.title.lowercased() }
        case .sizeLargest:
            return filteredTracks.sorted { ($0.fileSize ?? 0) > ($1.fileSize ?? 0) }
        case .sizeSmallest:
            return filteredTracks.sorted { ($0.fileSize ?? 0) < ($1.fileSize ?? 0) }
        }
    }

    var body: some View {
        ZStack {
            ScreenSpecificBackgroundView(screen: .playlistDetail)

            List {
                // Header section with artwork and buttons
                Section {
                    VStack(spacing: 16) {
                        // Four-song grid artwork
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.gray.opacity(0.2))
                                .frame(width: 250, height: 250)

                            // Show custom cover if available, otherwise show auto-generated mashup
                            if let customCover = customCoverImage {
                                Image(uiImage: customCover)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 250, height: 250)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            } else if tracks.count >= 4 {
                                // 2x2 mashup for 4+ songs
                                VStack(spacing: 2) {
                                    HStack(spacing: 2) {
                                        artworkView(at: 0, size: 124)
                                        artworkView(at: 1, size: 124)
                                    }
                                    HStack(spacing: 2) {
                                        artworkView(at: 2, size: 124)
                                        artworkView(at: 3, size: 124)
                                    }
                                }
                                .frame(width: 250, height: 250)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            } else if !tracks.isEmpty {
                                // Single artwork for 1-3 songs
                                artworkView(at: 0, size: 250)
                            } else {
                                // Default icon for empty playlist
                                Image(systemName: "music.note.list")
                                    .font(.system(size: 50))
                                    .foregroundColor(.secondary)
                            }

                            // Edit mode: Show large centered photo icon
                            if isEditMode {
                                VStack {
                                    Spacer()
                                    HStack {
                                        Spacer()
                                        Button(action: {
                                            showCoverOptions = true
                                        }) {
                                            Image(systemName: "photo")
                                                .font(.system(size: 40, weight: .light))
                                                .foregroundColor(.white)
                                                .frame(width: 80, height: 80)
                                                .background(Color.black.opacity(0.6))
                                                .clipShape(Circle())
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                        Spacer()
                                    }
                                    Spacer()
                                }
                                .frame(width: 250, height: 250)
                            }
                        }
                        .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
                        .frame(maxWidth: .infinity, alignment: .center)

                        VStack(spacing: 8) {
                            Text(playlist.title)
                                .font(.title2)
                                .fontWeight(.bold)
                                .multilineTextAlignment(.center)

                            Text(Localized.songsCount(tracks.count))
                                .font(.title3)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)

                        // Play and Shuffle buttons
                        HStack(spacing: 12) {
                            Button {
                                if let first = sortedTracks.first {
                                    Task {
                                        await playerEngine.playTrack(first, queue: sortedTracks)
                                    }
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "play.fill")
                                    Text(Localized.play)
                                }
                                .font(.title3.weight(.semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 56)
                                .background(settings.backgroundColorChoice.color)
                                .cornerRadius(28)
                            }
                            .disabled(tracks.isEmpty)

                            Button {
                                guard !sortedTracks.isEmpty else { return }
                                let shuffled = sortedTracks.shuffled()
                                Task {
                                    await playerEngine.playTrack(shuffled[0], queue: shuffled)
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "shuffle")
                                    Text(Localized.shuffle)
                                }
                                .font(.title3.weight(.semibold))
                                .foregroundColor(settings.backgroundColorChoice.color)
                                .frame(maxWidth: .infinity)
                                .frame(height: 56)
                                .background(settings.backgroundColorChoice.color.opacity(0.1))
                                .cornerRadius(28)
                            }
                            .disabled(tracks.isEmpty)
                        }
                    }
                    .padding(.vertical)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())

                // Track list section
                if !sortedTracks.isEmpty {
                    Section {
                        ForEach(Array(sortedTracks.enumerated()), id: \.element.stableId) { index, track in
                            PlaylistTrackRowView(
                                track: track,
                                playlist: playlist,
                                isEditMode: isEditMode,
                                onTap: {
                                    Task {
                                        guard let playlistId = playlist.id else { return }
                                        try? appCoordinator.updatePlaylistAccessed(playlistId: playlistId)
                                        try? appCoordinator.updatePlaylistLastPlayed(playlistId: playlistId)
                                        await playerEngine.playTrack(track, queue: sortedTracks)
                                    }
                                }
                            )
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                if !recentlyActedTracks.contains(track.stableId) {
                                    Button {
                                        playerEngine.insertNext(track)
                                        markAsActed(track.stableId)
                                    } label: {
                                        Label(Localized.playNext, systemImage: "text.line.first.and.arrowtriangle.forward")
                                    }
                                    .tint(settings.backgroundColorChoice.color)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                if !recentlyActedTracks.contains(track.stableId) {
                                    Button {
                                        playerEngine.addToQueue(track)
                                        markAsActed(track.stableId)
                                    } label: {
                                        Label(Localized.addToQueue, systemImage: "text.append")
                                    }
                                    .tint(.blue)
                                }
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(index < sortedTracks.count - 1 ? .visible : .hidden)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        }
                        .onMove(perform: sortOption == .playlistOrder ? { source, destination in
                            guard let playlistId = playlist.id else { return }
                            do {
                                // Calculate actual destination index
                                let sourceIndex = source.first ?? 0
                                let destinationIndex = sourceIndex < destination ? destination - 1 : destination

                                try appCoordinator.reorderPlaylistItems(
                                    playlistId: playlistId,
                                    from: sourceIndex,
                                    to: destinationIndex
                                )

                                // Reload tracks from database to reflect new order
                                loadPlaylistTracks()
                            } catch {
                                print("Failed to reorder tracks: \(error)")
                            }
                        } : nil)
                    } header: {
                        HStack {
                            Text(Localized.songs)
                                .font(.title3.weight(.bold))
                                .foregroundColor(.primary)
                            Spacer()

                            // Sort menu button
                            Menu {
                                ForEach(TrackSortOption.allCases, id: \.self) { option in
                                    Button(action: {
                                        sortOption = option
                                        saveSortPreference()
                                    }) {
                                        HStack {
                                            Text(option.localizedString)
                                            if sortOption == option {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            } label: {
                                Image(systemName: "arrow.up.arrow.down")
                                    .foregroundColor(settings.backgroundColorChoice.color)
                            }
                        }
                        .textCase(nil)
                        .padding(.horizontal, 16)
                    }
                } else {
                    Section {
                        VStack(spacing: 16) {
                            Image(systemName: "music.note")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary)

                            Text(Localized.noSongsFound)
                                .font(.headline)

                            Text(Localized.yourMusicWillAppearHere)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
            }
            .listStyle(PlainListStyle())
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(isEditMode ? .active : .inactive))
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(isEditMode ? Localized.done : Localized.edit) {
                    withAnimation {
                        isEditMode.toggle()
                    }
                }
                .disabled(tracks.isEmpty)
            }
        }
        .onAppear {
            loadPlaylistTracks()
            loadSortPreference()
            loadCustomCover()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LibraryNeedsRefresh"))) { _ in
            loadPlaylistTracks()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("BackgroundColorChanged"))) { _ in
            settings = DeleteSettings.load()
        }
        .confirmationDialog("Playlist Cover", isPresented: $showCoverOptions) {
            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                Text("Change Cover Image")
            }

            if customCoverImage != nil {
                Button("Remove Custom Cover", role: .destructive) {
                    removeCustomCover()
                }
            }

            Button("Cancel", role: .cancel) { }
        }
        .onChange(of: selectedPhotoItem) { newItem in
            Task {
                if let data = try? await newItem?.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    await saveCustomCover(image)
                }
            }
        }
    }

    @ViewBuilder
    private func artworkView(at index: Int, size: CGFloat) -> some View {
        if index < artworks.count {
            Image(uiImage: artworks[index])
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipped()
        } else if index < tracks.count {
            RoundedRectangle(cornerRadius: 0)
                .fill(Color.gray.opacity(0.3))
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "music.note")
                        .foregroundColor(.secondary)
                        .font(.system(size: size/4))
                )
        }
    }

    private func loadPlaylistTracks() {
        guard let playlistId = playlist.id else { return }

        do {
            let playlistItems = try appCoordinator.databaseManager.getPlaylistItems(playlistId: playlistId)
            let allTracks = try appCoordinator.getAllTracks()

            tracks = playlistItems.compactMap { item in
                allTracks.first { $0.stableId == item.trackStableId }
            }

            // Load artworks for the first 4 tracks
            Task {
                await loadArtworks()
            }
        } catch {
            print("Failed to load playlist tracks: \(error)")
        }
    }

    private func loadArtworks() async {
        var loadedArtworks: [UIImage] = []
        let tracksToLoad = Array(tracks.prefix(4))

        for track in tracksToLoad {
            if let artwork = await artworkManager.getArtwork(for: track) {
                loadedArtworks.append(artwork)
            }
        }

        await MainActor.run {
            artworks = loadedArtworks
        }
    }

    private func loadSortPreference() {
        guard let playlistId = playlist.id else { return }
        let key = "sortPreference_playlist_\(playlistId)"
        if let savedRawValue = UserDefaults.standard.string(forKey: key),
           let saved = TrackSortOption(rawValue: savedRawValue) {
            sortOption = saved
        }
    }

    private func saveSortPreference() {
        guard let playlistId = playlist.id else { return }
        let key = "sortPreference_playlist_\(playlistId)"
        UserDefaults.standard.set(sortOption.rawValue, forKey: key)
    }

    private func loadCustomCover() {
        // Check if playlist has a custom cover path
        guard let customPath = playlist.customCoverImagePath,
              !customPath.isEmpty else { return }

        // Load image from shared container
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.dev.clq.Cosmos-Music-Player"
        ) else {
            print("❌ Failed to get shared container URL")
            return
        }

        let fileURL = containerURL.appendingPathComponent(customPath)
        if let data = try? Data(contentsOf: fileURL),
           let image = UIImage(data: data) {
            customCoverImage = image
            print("✅ Loaded custom playlist cover from \(customPath)")
        }
    }

    @MainActor
    private func saveCustomCover(_ image: UIImage) async {
        guard let playlistId = playlist.id else { return }

        // Get shared container
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.dev.clq.Cosmos-Music-Player"
        ) else {
            print("❌ Failed to get shared container URL")
            return
        }

        // Create unique filename for this playlist cover
        let filename = "playlist_cover_\(playlistId).jpg"
        let fileURL = containerURL.appendingPathComponent(filename)

        // Convert image to JPEG data with compression
        guard let jpegData = image.jpegData(compressionQuality: 0.8) else {
            print("❌ Failed to convert image to JPEG")
            return
        }

        do {
            // Save image to shared container
            try jpegData.write(to: fileURL)
            print("✅ Saved custom cover to \(filename)")

            // Update database with custom cover path
            try appCoordinator.databaseManager.updatePlaylistCustomCover(
                playlistId: playlistId,
                imagePath: filename
            )

            // Update UI
            customCoverImage = image

            // Notify widgets to refresh
            WidgetCenter.shared.reloadAllTimelines()

            print("✅ Custom cover saved and database updated")
        } catch {
            print("❌ Failed to save custom cover: \(error)")
        }
    }

    private func removeCustomCover() {
        guard let playlistId = playlist.id else { return }

        // Remove from database
        do {
            try appCoordinator.databaseManager.updatePlaylistCustomCover(
                playlistId: playlistId,
                imagePath: nil
            )

            // Remove file from shared container if it exists
            if let customPath = playlist.customCoverImagePath,
               !customPath.isEmpty,
               let containerURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: "group.dev.clq.Cosmos-Music-Player"
               ) {
                let fileURL = containerURL.appendingPathComponent(customPath)
                try? FileManager.default.removeItem(at: fileURL)
                print("✅ Removed custom cover file")
            }

            // Update UI
            customCoverImage = nil

            // Notify widgets to refresh
            WidgetCenter.shared.reloadAllTimelines()

            print("✅ Custom cover removed")
        } catch {
            print("❌ Failed to remove custom cover: \(error)")
        }
    }
}

struct PlaylistTrackRowView: View {
    let track: Track
    let playlist: Playlist?
    let isEditMode: Bool
    let onTap: () -> Void
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @StateObject private var playerEngine = PlayerEngine.shared
    @State private var isFavorite = false
    @State private var showPlaylistDialog = false
    @State private var showDeleteConfirmation = false
    @State private var deleteSettings = DeleteSettings.load()
    @State private var artworkImage: UIImage?
    @StateObject private var artworkManager = ArtworkManager.shared

    // Check if this track is currently playing
    private var isCurrentlyPlaying: Bool {
        playerEngine.currentTrack?.stableId == track.stableId
    }

    var body: some View {
        HStack(spacing: 0) {
            // MARK: - Tappable Content Area
            HStack(spacing: 12) {
                // Album artwork thumbnail (matching TrackRowView exactly)
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 60, height: 60)

                    if let image = artworkImage {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Image(systemName: "music.note")
                            .font(.title2)
                            .foregroundColor(.secondary)
                    }

                    // Stroke when playing (matching TrackRowView)
                    if isCurrentlyPlaying {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(deleteSettings.backgroundColorChoice.color, lineWidth: 2)
                            .frame(width: 60, height: 60)
                    }
                }

                // Track info (matching TrackRowView exactly)
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.title3)
                        .fontWeight(.medium)
                        .foregroundColor(isCurrentlyPlaying ? deleteSettings.backgroundColorChoice.color : .primary)
                        .lineLimit(1)

                    if let artistId = track.artistId,
                       let artist = try? DatabaseManager.shared.read({ db in
                           try Artist.fetchOne(db, key: artistId)
                       }) {
                        Text(artist.name)
                            .font(.body)
                            .foregroundColor(isCurrentlyPlaying ? deleteSettings.backgroundColorChoice.color.opacity(0.8) : .secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Equalizer animation when playing (matching TrackRowView)
                if isCurrentlyPlaying {
                    EqualizerBarsExact(
                        color: deleteSettings.backgroundColorChoice.color,
                        isActive: playerEngine.isPlaying && isCurrentlyPlaying,
                        isLarge: true,
                        trackId: playerEngine.currentTrack?.stableId
                    )
                    .id("\(playerEngine.isPlaying && isCurrentlyPlaying)-\(playerEngine.currentTrack?.stableId ?? "")")
                    .padding(.trailing, 8)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if !isEditMode {
                    onTap()
                }
            }

            // MARK: - Menu / Action Area
            // Show delete button in edit mode, otherwise menu
            if isEditMode, let playlist = playlist {
                Button(action: {
                    removeFromPlaylist()
                }) {
                    Image(systemName: "trash")
                        .font(.title2)
                        .foregroundColor(.red)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().stroke(.red.opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.leading, 8)
            } else {
                Menu {
                    Button(action: {
                        do {
                            try appCoordinator.toggleFavorite(trackStableId: track.stableId)
                            isFavorite.toggle()
                        } catch {
                            print("Failed to toggle favorite: \(error)")
                        }
                    }) {
                        HStack {
                            Image(systemName: isFavorite ? "heart.slash" : "heart")
                            Text(isFavorite ? Localized.removeFromLikedSongs : Localized.addToLikedSongs)
                        }
                    }

                    if let artistId = track.artistId,
                       let artist = try? DatabaseManager.shared.read({ db in
                               try Artist.fetchOne(db, key: artistId)
                           }),
                       let allArtistTracks = try? DatabaseManager.shared.read({ db in
                           try Track.filter(Column("artist_id") == artistId).fetchAll(db)
                       }) {
                        NavigationLink(destination: ArtistDetailScreenWrapper(artistName: artist.name, allTracks: allArtistTracks)) {
                            Label(Localized.showArtistPage, systemImage: "person.circle")
                        }
                    }

                    Button(action: {
                        showPlaylistDialog = true
                    }) {
                        Label(Localized.addToPlaylistEllipsis, systemImage: "rectangle.stack.badge.plus")
                    }

                    Button(action: {
                        showDeleteConfirmation = true
                    }) {
                        Label(Localized.deleteFile, systemImage: "trash")
                    }
                    .foregroundColor(.red)
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundColor(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .frame(height: 80)
        .padding(.horizontal, 12)
        .sheet(isPresented: $showPlaylistDialog) {
            PlaylistSelectionView(track: track)
                .accentColor(deleteSettings.backgroundColorChoice.color)
        }
        .alert(Localized.deleteFile, isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                deleteFile()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(Localized.deleteFileConfirmation(track.title))
        }
        .onAppear {
            isFavorite = (try? appCoordinator.isFavorite(trackStableId: track.stableId)) ?? false
            if artworkImage == nil { loadArtwork() }
        }
    }

    private func loadArtwork() {
        Task {
            artworkImage = await ArtworkManager.shared.getArtwork(for: track)
        }
    }

    private func deleteFile() {
        Task {
            do {
                let url = URL(fileURLWithPath: track.path)
                try FileManager.default.removeItem(at: url)
                try DatabaseManager.shared.deleteTrack(byStableId: track.stableId)
                NotificationCenter.default.post(name: NSNotification.Name("LibraryNeedsRefresh"), object: nil)
            } catch {
                print("❌ Failed to delete file: \(error)")
            }
        }
    }

    private func removeFromPlaylist() {
        guard let playlist = playlist, let playlistId = playlist.id else { return }
        Task {
            do {
                try appCoordinator.removeFromPlaylist(playlistId: playlistId, trackStableId: track.stableId)
                NotificationCenter.default.post(name: NSNotification.Name("LibraryNeedsRefresh"), object: nil)
            } catch {
                print("❌ Failed to remove from playlist: \(error)")
            }
        }
    }
}

struct PlaylistListView: View {
    let playlists: [Playlist]
    let onPlaylistTap: (Playlist) -> Void
    
    var body: some View {
        if playlists.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary)
                
                Text("No playlists yet")
                    .font(.headline)
                
                Text("Create playlists by adding songs to them from the library")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(playlists, id: \.id) { playlist in
                HStack {
                    Image(systemName: "music.note.list")
                        .foregroundColor(.green)
                        .frame(width: 24, height: 24)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(playlist.title)
                            .font(.headline)
                        
                        Text(Localized.playlist)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                .frame(height: 66)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
                .onTapGesture {
                    onPlaylistTap(playlist)
                }
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
            }
            .listStyle(PlainListStyle())
        }
    }
}

struct PlaylistSelectionView: View {
    let track: Track
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var playlists: [Playlist] = []
    @State private var showCreatePlaylist = false
    @State private var newPlaylistName = ""
    @State private var showDeleteConfirmation = false
    @State private var playlistToDelete: Playlist?
    @State private var settings = DeleteSettings.load()
    
    var sortedPlaylists: [Playlist] {
        // Sort playlists: first those where song is NOT in playlist (sorted by most recent played), 
        // then those where song IS in playlist (also sorted by most recent played)
        return playlists.sorted { playlist1, playlist2 in
            let isInPlaylist1 = (try? appCoordinator.isTrackInPlaylist(playlistId: playlist1.id ?? 0, trackStableId: track.stableId)) ?? false
            let isInPlaylist2 = (try? appCoordinator.isTrackInPlaylist(playlistId: playlist2.id ?? 0, trackStableId: track.stableId)) ?? false
            
            // If one is not in playlist and the other is, prioritize the one not in playlist
            if !isInPlaylist1 && isInPlaylist2 {
                return true
            } else if isInPlaylist1 && !isInPlaylist2 {
                return false
            } else {
                // Both are in same category, sort by most recent played (lastPlayedAt desc, then by title)
                if playlist1.lastPlayedAt != playlist2.lastPlayedAt {
                    return playlist1.lastPlayedAt > playlist2.lastPlayedAt
                } else {
                    return playlist1.title.localizedCaseInsensitiveCompare(playlist2.title) == .orderedAscending
                }
            }
        }
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Text(Localized.addToPlaylist)
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text(track.title)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                if playlists.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        
                        Text(Localized.noPlaylistsYet)
                            .font(.headline)
                        
                        Text(Localized.createFirstPlaylist)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(sortedPlaylists, id: \.id) { playlist in
                            let isInPlaylist = (try? appCoordinator.isTrackInPlaylist(playlistId: playlist.id ?? 0, trackStableId:
                                                                                        track.stableId)) ?? false
                            
                            HStack(spacing: 8) {
                                // Main clickable area for add/remove
                                HStack {
                                    Image(systemName: "music.note.list")
                                        .foregroundColor(settings.backgroundColorChoice.color)
                                    
                                    Text(playlist.title)
                                        .foregroundColor(.primary)
                                    
                                    Spacer()
                                    
                                    // Status indicator (not clickable, just visual feedback)
                                    if isInPlaylist {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                    } else {
                                        Image(systemName: "plus.circle")
                                            .foregroundColor(settings.backgroundColorChoice.color)
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if isInPlaylist {
                                        removeFromPlaylist(playlist)
                                    } else {
                                        addToPlaylist(playlist)
                                    }
                                }
                                
                                // Separator line
                                Divider()
                                    .frame(height: 30)
                                
                                // Delete button - clearly separated
                                Button(action: {
                                    playlistToDelete = playlist
                                    showDeleteConfirmation = true
                                }) {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                        .frame(width: 32, height: 32)
                                        .background(Color.red.opacity(0.1))
                                        .cornerRadius(8)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                
                Button(Localized.createNewPlaylist) {
                    showCreatePlaylist = true
                }
                .buttonStyle(.borderedProminent)
                .padding()
            }
            .padding()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(Localized.cancel) {
                        dismiss()
                    }
                }
            }
        }
        .alert(Localized.createPlaylist, isPresented: $showCreatePlaylist) {
            TextField(Localized.playlistNamePlaceholder, text: $newPlaylistName)
            Button(Localized.create) {
                createPlaylist()
            }
            .disabled(newPlaylistName.isEmpty)
            Button(Localized.cancel, role: .cancel) { }
        } message: {
            Text(Localized.enterPlaylistName)
        }
        .alert(Localized.deletePlaylist, isPresented: $showDeleteConfirmation) {
            Button(Localized.delete, role: .destructive) {
                deletePlaylistInSelection()
            }
            Button(Localized.cancel, role: .cancel) { }
        } message: {
            if let playlist = playlistToDelete {
                Text(Localized.deletePlaylistConfirmation(playlist.title))
            }
        }
        .onAppear {
            loadPlaylists()
        }
    }
    
    private func loadPlaylists() {
        do {
            playlists = try DatabaseManager.shared.getAllPlaylists()
        } catch {
            print("Failed to load playlists: \(error)")
        }
    }
    
    private func createPlaylist() {
        guard !newPlaylistName.isEmpty else { return }
        
        do {
            let playlist = try appCoordinator.createPlaylist(title: newPlaylistName)
            playlists.append(playlist)
            newPlaylistName = ""
            
            // Automatically add the track to the new playlist
            guard let playlistId = playlist.id else {
                print("Error: Created playlist has no ID")
                return
            }
            try appCoordinator.addToPlaylist(playlistId: playlistId, trackStableId: track.stableId)
            dismiss()
        } catch {
            print("Failed to create playlist: \(error)")
        }
    }
    
    private func addToPlaylist(_ playlist: Playlist) {
        do {
            guard let playlistId = playlist.id else {
                print("Error: Playlist has no ID")
                return
            }
            try appCoordinator.addToPlaylist(playlistId: playlistId, trackStableId: track.stableId)
            dismiss()
        } catch {
            print("Failed to add to playlist: \(error)")
        }
    }
    
    private func removeFromPlaylist(_ playlist: Playlist) {
        do {
            guard let playlistId = playlist.id else {
                print("Error: Playlist has no ID")
                return
            }
            try appCoordinator.removeFromPlaylist(playlistId: playlistId, trackStableId: track.stableId)
            dismiss()
        } catch {
            print("Failed to remove from playlist: \(error)")
        }
    }
    
    private func deletePlaylistInSelection() {
        guard let playlist = playlistToDelete,
              let playlistId = playlist.id else { return }
        
        do {
            try appCoordinator.deletePlaylist(playlistId: playlistId)
            playlists.removeAll { $0.id == playlistId }
            playlistToDelete = nil
        } catch {
            print("Failed to delete playlist: \(error)")
        }
    }
}

struct PlaylistManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var playlists: [Playlist] = []
    @State private var playlistToDelete: Playlist?
    @State private var showDeleteConfirmation = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                if playlists.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        
                        Text(Localized.noPlaylistsYet)
                            .font(.headline)
                        
                        Text(Localized.createPlaylistsInstruction)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(playlists, id: \.id) { playlist in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(playlist.title)
                                        .font(.headline)
                                    
                                    Text(Localized.createdDate(formatDate(Date(timeIntervalSince1970: TimeInterval(playlist.createdAt)))))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                                
                                Button(action: {
                                    playlistToDelete = playlist
                                    showDeleteConfirmation = true
                                }) {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .padding()
            .navigationTitle(Localized.managePlaylists)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(Localized.done) {
                        dismiss()
                    }
                }
            }
        }
        .alert(Localized.deletePlaylist, isPresented: $showDeleteConfirmation) {
            Button(Localized.delete, role: .destructive) {
                deletePlaylist()
            }
            Button(Localized.cancel, role: .cancel) { }
        } message: {
            if let playlist = playlistToDelete {
                Text(Localized.deletePlaylistConfirmation(playlist.title))
            }
        }
        .onAppear {
            loadPlaylists()
        }
    }
    
    private func loadPlaylists() {
        do {
            playlists = try DatabaseManager.shared.getAllPlaylists()
        } catch {
            print("Failed to load playlists: \(error)")
        }
    }
    
    private func deletePlaylist() {
        guard let playlist = playlistToDelete,
              let playlistId = playlist.id else { return }
        
        do {
            try appCoordinator.deletePlaylist(playlistId: playlistId)
            playlists.removeAll { $0.id == playlistId }
            playlistToDelete = nil
        } catch {
            print("Failed to delete playlist: \(error)")
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
}
