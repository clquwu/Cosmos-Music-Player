import SwiftUI
import GRDB
import PhotosUI
import WidgetKit
#if canImport(FoundationModels)
import FoundationModels
#endif

fileprivate extension UIImage {
    func squarePlaylistCover(targetSize: CGFloat = 1024) -> UIImage {
        guard size.width > 0, size.height > 0 else {
            return self
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let outputSize = CGSize(width: targetSize, height: targetSize)

        return UIGraphicsImageRenderer(size: outputSize, format: format).image { _ in
            let fillScale = max(targetSize / size.width, targetSize / size.height)
            let drawSize = CGSize(width: size.width * fillScale, height: size.height * fillScale)
            let drawOrigin = CGPoint(
                x: (targetSize - drawSize.width) / 2,
                y: (targetSize - drawSize.height) / 2
            )

            draw(in: CGRect(origin: drawOrigin, size: drawSize))
        }
    }
}

struct PlaylistsScreen: View {
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var playlists: [Playlist] = []
    @State private var isEditMode: Bool = false
    @State private var playlistToEdit: Playlist?
    @State private var playlistToDelete: Playlist?
    @State private var showEditDialog = false
    @State private var showDeleteConfirmation = false
    @State private var editPlaylistName = ""
    @State private var showAIPlaylistSheet = false
    @State private var showCreatePlaylist = false
    @State private var newPlaylistName = ""
    @StateObject private var search = LibrarySearchState()
    /// Each playlist's songs, loaded with the list. The grid used to query
    /// the database for every card on every render.
    @State private var playlistTracks: [Int64: [Track]] = [:]

    private var visiblePlaylists: [Playlist] {
        let terms = LibrarySearch.terms(in: search.text)
        guard !terms.isEmpty else { return playlists }
        return playlists.filter { LibrarySearch.matches(terms: terms, in: $0.title) }
    }

    var body: some View {
        Group {
            if visiblePlaylists.isEmpty {
                if playlists.isEmpty {
                    CosmosEmptyState(
                        systemImage: "music.note.list",
                        title: Localized.noPlaylistsYet,
                        message: Localized.createPlaylistsInstruction,
                        actionTitle: Localized.createPlaylist
                    ) {
                        newPlaylistName = ""
                        showCreatePlaylist = true
                    }
                } else {
                    ContentUnavailableView.search(text: search.text)
                }
            } else {
                ScrollView {
                    TileGrid(minimum: Design.Size.gridTileMinWidth, maximum: 260, spacing: Design.Spacing.l, rowSpacing: Design.Spacing.xl) {
                        ForEach(visiblePlaylists, id: \.id) { playlist in
                            let tracks = playlist.id.flatMap { playlistTracks[$0] } ?? []
                            if isEditMode {
                                PlaylistCardView(playlist: playlist, allTracks: tracks, isEditMode: true, onEdit: {
                                    playlistToEdit = playlist
                                    editPlaylistName = playlist.title
                                    showEditDialog = true
                                }, onDelete: {
                                    playlistToDelete = playlist
                                    showDeleteConfirmation = true
                                })
                            } else if let playlistId = playlist.id {
                                NavigationLink(value: LibraryRoute.playlist(id: playlistId)) {
                                    PlaylistCardView(playlist: playlist, allTracks: tracks)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        MixStore.shared.playPlaylistMix(playlistId: playlistId)
                                    } label: {
                                        Label(Localized.playlistMix, systemImage: "dot.radiowaves.left.and.right")
                                    }
                                    .disabled(tracks.isEmpty)
                                }
                            }
                        }
                    }
                    .padding(.vertical, Design.Spacing.l)
                    .pagePadding()
                }
            }
        }
        .background(ScreenSpecificBackgroundView(screen: .playlists))
        .navigationTitle(Localized.playlists)
        .navigationBarTitleDisplayMode(.large)
        .librarySearchField(search, prompt: Localized.searchPlaylists)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                LibrarySearchButton(state: search)
                if !playlists.isEmpty {
                    Button(isEditMode ? Localized.done : Localized.edit) {
                        withAnimation {
                            isEditMode.toggle()
                        }
                    }
                }
                createButton
            }
            .cosmosPlainBackground()
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
        .sheet(isPresented: $showAIPlaylistSheet) {
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *) {
                AIPlaylistSheet {
                    loadPlaylists()
                }
                .environmentObject(appCoordinator)
            }
            #endif
        }
    }

    /// "New Playlist" lives in the toolbar where iOS puts creation, instead of
    /// only inside Edit mode. It is a menu: a new playlist, the AI generator
    /// when Apple Intelligence is available (that used to be a floating action
    /// button, an Android pattern that also covered the last row of the grid),
    /// and importing an M3U playlist from a computer.
    private var createButton: some View {
        Menu {
            Button {
                newPlaylistName = ""
                showCreatePlaylist = true
            } label: {
                Label(Localized.newPlaylist, systemImage: "plus")
            }

            if isAIAvailable {
                Button {
                    showAIPlaylistSheet = true
                } label: {
                    Label(Localized.aiPlaylistButton, systemImage: "wand.and.stars")
                }
            }

            PlaylistImportMenuButton()
        } label: {
            Label(Localized.newPlaylist, systemImage: "plus")
        }
    }

    /// Only offer the AI playlist button when Apple Intelligence is actually
    /// usable on this device (model downloaded and enabled), not merely when
    /// the OS version supports it.
    private var isAIAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability {
                return true
            }
        }
        #endif
        return false
    }

    private func getAllPlaylistTracks(_ playlist: Playlist) -> [Track] {
        guard let playlistId = playlist.id else { return [] }
        do {
            let playlistItems = try appCoordinator.databaseManager.getPlaylistItems(playlistId: playlistId)
            let trackIds = playlistItems.map { $0.trackStableId }
            return try appCoordinator.databaseManager.getTracksByStableIdsPreservingOrder(trackIds)
        } catch {
            print("Failed to get playlist tracks: \(error)")
            return []
        }
    }

    private func loadPlaylists() {
        let signpost = Perf.begin("Playlists load")
        defer { Perf.end("Playlists load", signpost) }
        do {
            playlists = try appCoordinator.databaseManager.getAllPlaylists()
            // One query for every playlist's songs, not two per playlist.
            let found = (try? appCoordinator.databaseManager.getTracksForPlaylists(playlists.compactMap(\.id))) ?? [:]
            var tracksById: [Int64: [Track]] = [:]
            for playlist in playlists {
                guard let playlistId = playlist.id else { continue }
                tracksById[playlistId] = found[playlistId] ?? []
            }
            playlistTracks = tracksById
        } catch {
            print("Failed to load playlists: \(error)")
        }
    }

    private func createPlaylist() {
        let title = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            // A playlist by that name (any case) already exists: it is
            // already in the list, and a second of the same name would only confuse.
            if try DatabaseManager.shared.playlist(matchingTitle: title) == nil {
                _ = try appCoordinator.createPlaylist(title: title)
            }
            loadPlaylists()
            newPlaylistName = ""
        } catch {
            print("Failed to create playlist: \(error)")
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

#if canImport(FoundationModels)
/// Bottom sheet behind the playlists screen's floating AI button: describe a
/// playlist, the on-device model picks tracks (MixGenerator), and the result
/// is saved as a regular playlist.
@available(iOS 26.0, *)
struct AIPlaylistSheet: View {
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var prompt = ""
    @State private var isGenerating = false
    @State private var showError = false
    @State private var showCreated = false
    @State private var createdTitle = ""
    @State private var createdTracks: [Track] = []
    @FocusState private var promptFocused: Bool

    var onCreated: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text(Localized.aiPlaylistDescription)
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                TextField(Localized.aiPlaylistPlaceholder, text: $prompt, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                    .focused($promptFocused)
                    .disabled(isGenerating)
                    .onSubmit(generate)

                if showError {
                    Text(Localized.aiPlaylistFailed)
                        .font(.footnote)
                        .foregroundColor(.red)
                }

                Button(action: generate) {
                    HStack {
                        if isGenerating {
                            ProgressView()
                                .tint(.white)
                            Text(Localized.aiPlaylistGenerating)
                        } else {
                            Image(systemName: "wand.and.stars")
                            Text(Localized.aiPlaylistGenerate)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isGenerating || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()
            }
            .padding(20)
            .navigationTitle(Localized.aiPlaylistTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Localized.cancel) { dismiss() }
                        .disabled(isGenerating)
                }
            }
            .onAppear { promptFocused = true }
            .alert(Localized.aiPlaylistCreatedTitle, isPresented: $showCreated) {
                Button(Localized.play) {
                    let tracks = createdTracks
                    Task { @MainActor in
                        if let first = tracks.first {
                            await appCoordinator.playTrack(first, queue: tracks)
                        }
                        dismiss()
                    }
                }
                Button(Localized.done, role: .cancel) { dismiss() }
            } message: {
                Text(Localized.aiPlaylistCreatedMessage(createdTitle, createdTracks.count))
            }
        }
        .presentationDetents([.medium])
    }

    private func generate() {
        let request = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !isGenerating else { return }
        isGenerating = true
        showError = false

        Task { @MainActor in
            do {
                let mix = try await MixGenerator().generate(matching: request)
                guard !mix.tracks.isEmpty else { throw MixGenerationError.emptyLibrary }

                // The model may pick a name already taken; never merge the
                // mix into the listener's playlist, give it its own name.
                let title = try DatabaseManager.shared.availablePlaylistTitle(mix.title)
                let playlist = try appCoordinator.createPlaylist(title: title)
                if let playlistId = playlist.id {
                    for track in mix.tracks {
                        try appCoordinator.addToPlaylist(playlistId: playlistId, trackStableId: track.stableId)
                    }
                }
                onCreated()
                createdTitle = playlist.title
                createdTracks = mix.tracks
                isGenerating = false
                showCreated = true
            } catch {
                print("❌ AI playlist generation failed: \(error)")
                showError = true
                isGenerating = false
            }
        }
    }
}
#endif // canImport(FoundationModels)

/// Trailing tile in the playlists grid, shown only while editing. Mirrors
/// PlaylistCardView's geometry (square artwork area plus two text lines) so the
/// grid rows stay aligned alongside real playlist cards.
struct NewPlaylistCardView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.2))
                    .aspectRatio(1, contentMode: .fit)

                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .foregroundColor(.secondary.opacity(0.5))
                    .aspectRatio(1, contentMode: .fit)

                Image(systemName: "plus")
                    .font(.system(size: 40, weight: .light))
                    .foregroundColor(.secondary)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 2) {
                Text(Localized.createPlaylist)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                // Keeps this tile the same height as the playlist cards, which
                // carry a song-count caption on their second line.
                Text(" ")
                    .font(.caption)
                    .hidden()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Localized.createPlaylist)
        .accessibilityAddTraits(.isButton)
    }
}

/// A playlist's cover: the user's own image, or a 2x2 mosaic of its first
/// four songs' artwork, or one cover for a short playlist. Fills whatever
/// width it is given.
struct PlaylistCoverView: View {
    let customCover: UIImage?
    let artworks: [UIImage]
    let trackCount: Int

    var body: some View {
        RoundedRectangle(cornerRadius: Design.Radius.artwork, style: .continuous)
            .fill(Color.secondary.opacity(0.15))
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let customCover {
                    Image(uiImage: customCover)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if trackCount >= 4 {
                    GeometryReader { geometry in
                        let side = (geometry.size.width - 1) / 2
                        VStack(spacing: 1) {
                            HStack(spacing: 1) {
                                tile(at: 0, side: side)
                                tile(at: 1, side: side)
                            }
                            HStack(spacing: 1) {
                                tile(at: 2, side: side)
                                tile(at: 3, side: side)
                            }
                        }
                    }
                } else if trackCount > 0 {
                    GeometryReader { geometry in
                        tile(at: 0, side: geometry.size.width)
                    }
                } else {
                    ArtworkPlaceholder(symbol: "music.note.list")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Design.Radius.artwork, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Design.Radius.artwork, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func tile(at index: Int, side: CGFloat) -> some View {
        if index < artworks.count {
            Image(uiImage: artworks[index])
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: side, height: side)
                .clipped()
        } else {
            ArtworkPlaceholder()
                .frame(width: side, height: side)
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
        VStack(alignment: .leading, spacing: Design.Spacing.xs + 2) {
            PlaylistCoverView(customCover: customCoverImage, artworks: artworks, trackCount: allTracks.count)
                .overlay {
                    if isEditMode {
                        editOverlay
                    }
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(playlist.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(Localized.songsCount(allTracks.count))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: isEditMode ? .contain : .combine)
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

    /// Rename, delete and change-cover controls, shown over the cover while
    /// the grid is being edited.
    private var editOverlay: some View {
        ZStack {
            Color.black.opacity(0.25)

            VStack {
                HStack {
                    editButton(systemImage: "pencil", label: Localized.editPlaylist, tint: .primary) {
                        onEdit?()
                    }
                    Spacer()
                    editButton(systemImage: "trash", label: Localized.deletePlaylist, tint: .red) {
                        onDelete?()
                    }
                }
                Spacer()
            }
            .padding(Design.Spacing.s)

            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(.black.opacity(0.55), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Localized.changeCoverImage)
        }
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius.artwork, style: .continuous))
    }

    private func editButton(systemImage: String, label: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: Design.Size.minTouch, height: Design.Size.minTouch)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func loadArtworks() async {
        var loadedArtworks: [UIImage] = []
        let tracksToLoad = Array(allTracks.prefix(4))

        for track in tracksToLoad {
            if let artwork = await artworkManager.getThumbnail(for: track, maxPixelSize: 256) {
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
        let coverImage = image.squarePlaylistCover()

        // Save a normalized square image so all playlist covers match standard artwork sizing.
        guard let jpegData = coverImage.jpegData(compressionQuality: 0.85) else {
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
            customCoverImage = coverImage

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
    @State private var pickerAfterDialog: CoverPicker?
    @State private var showingCoverFileImporter = false

    private enum CoverPicker { case photos, files }
    @State private var artistNameCache: [Int64: String] = [:]
    @State private var artistDisplayNameCache: [String: String] = [:]
    @StateObject private var search = LibrarySearchState()
    @State private var searchIndex = TrackSearchIndex()

    private var isSearching: Bool { search.isSearching }

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

    // Subscribed, not merely read: the list has to be rebuilt when the route
    // changes. Reading the singleton without subscribing meant connecting could
    // leave incompatible formats on screen and disconnecting left Opus/DSD
    // missing until some other refresh happened to fire.
    //
    // Deliberately CarPlayRouteState and not SFBAudioEngineManager: that class
    // also publishes `currentTime` from a 0.1s timer, so observing it rebuilt
    // this whole list ten times a second for the duration of every
    // Opus/Vorbis/DSD track.
    @ObservedObject private var carPlayState = CarPlayRouteState.shared

    private var playableTracks: [Track] {
        // Filter out incompatible formats when connected to CarPlay
        guard carPlayState.isConnected else { return tracks }
        return tracks.filter { track in
            let ext = URL(fileURLWithPath: track.path).pathExtension.lowercased()
            let incompatibleFormats = ["ogg", "oga", "opus", "dsf", "dff"]
            return !incompatibleFormats.contains(ext)
        }
    }

    private var sortedTracks: [Track] {
        sorted(searchIndex.filter(playableTracks, query: search.text))
    }

    /// The same playlist in the same order, with the search not applied.
    /// Evaluated only inside a tap handler - see `queueSource`.
    private var fullSortedTracks: [Track] {
        sorted(playableTracks)
    }

    private func sorted(_ filteredTracks: [Track]) -> [Track] {
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
        case .artistAZ:
            // Pre-fetch all artist names for performance
            let artistCache = buildArtistCache(for: filteredTracks)
            return filteredTracks.sorted { track1, track2 in
                let artist1 = artistCache[track1.artistId ?? -1] ?? ""
                let artist2 = artistCache[track2.artistId ?? -1] ?? ""
                return artist1.lowercased() < artist2.lowercased()
            }
        case .artistZA:
            // Pre-fetch all artist names for performance
            let artistCache = buildArtistCache(for: filteredTracks)
            return filteredTracks.sorted { track1, track2 in
                let artist1 = artistCache[track1.artistId ?? -1] ?? ""
                let artist2 = artistCache[track2.artistId ?? -1] ?? ""
                return artist1.lowercased() > artist2.lowercased()
            }
        case .sizeLargest:
            return filteredTracks.sorted { ($0.fileSize ?? 0) > ($1.fileSize ?? 0) }
        case .sizeSmallest:
            return filteredTracks.sorted { ($0.fileSize ?? 0) < ($1.fileSize ?? 0) }
        }
    }

    private func buildArtistCache(for tracks: [Track]) -> [Int64: String] {
        // Get unique artist IDs
        let artistIds = Set(tracks.compactMap { $0.artistId })

        // Fetch all artists in one query
        var cache: [Int64: String] = [:]
        do {
            try DatabaseManager.shared.read { db in
                let artists = try Artist.filter(artistIds.contains(Column("id"))).fetchAll(db)
                for artist in artists {
                    if let id = artist.id {
                        cache[id] = artist.name
                    }
                }
            }
        } catch {
            print("Failed to build artist cache: \(error)")
        }
        return cache
    }

    /// "12 songs · 48 min"
    private var detailLine: String {
        var parts = [Localized.songsCountOnly(tracks.count)]
        if let length = DurationFormatter.totalLength(of: tracks) { parts.append(length) }
        return parts.joined(separator: " · ")
    }

    /// Identity for the rows' Equatable check - see
    /// `TrackRowView.contextIdentity`. Each tap handler captures its row's
    /// *position*, so the whole visible order goes in: moving a song in the
    /// middle of the list leaves count, first and last unchanged, and every
    /// row would otherwise keep a handler pointing at its old position.
    private func rowContextIdentity(for rows: [IdentifiedTrackRow]) -> String {
        var hasher = Hasher()
        for row in rows { hasher.combine(row.rowId) }
        return "\(rows.count)-\(hasher.finalize())|\(sortOption.rawValue)|\(isSearching)|\(isEditMode)"
    }

    var body: some View {
        // Sorted once per pass. Reading `sortedTracks` inside the ForEach
        // re-sorted the playlist - and, for the artist sorts, re-queried the
        // database - once per row.
        let visibleRows = sortedTracks.uniquelyIdentifiedRows()
        let contextIdentity = rowContextIdentity(for: visibleRows)

        return DetailPage {
            DetailHeader(
                title: playlist.title,
                detail: detailLine,
                isPlayDisabled: tracks.isEmpty,
                onPlay: {
                    if let first = sortedTracks.first {
                        Task {
                            await playerEngine.playTrack(first, queue: sortedTracks)
                        }
                    }
                },
                onShuffle: {
                    guard !sortedTracks.isEmpty else { return }
                    let shuffled = sortedTracks.shuffled()
                    Task {
                        await playerEngine.playTrack(shuffled[0], queue: shuffled)
                    }
                }
            ) {
                PlaylistCoverView(customCover: customCoverImage, artworks: artworks, trackCount: tracks.count)
                    .overlay {
                        // Edit mode: a button to change the cover.
                        if isEditMode {
                            Button {
                                showCoverOptions = true
                            } label: {
                                Image(systemName: "photo")
                                    .font(.title)
                                    .foregroundStyle(.white)
                                    .frame(width: 72, height: 72)
                                    .background(.black.opacity(0.55), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Localized.playlistCover)
                            // On the button, so on iPad the choices open
                            // beside the cover; on the page they floated at
                            // the top, pointing at the tab bar.
                            .confirmationDialog(Localized.playlistCover, isPresented: $showCoverOptions) {
                                coverOptions
                            }
                            // The choices take the tint; the accent pink
                            // was hard to read on the dialog's glass. In the
                            // label colour, as a menu's items are.
                            .tint(Color.primary)
                        }
                    }
            }
        } rows: {
            // Track list section
            if !visibleRows.isEmpty {
                Section {
                    // A row, not the section header: a plain list pins its
                    // header, and "Songs" with its sort button stayed stuck
                    // over the songs while scrolling.
                    SectionTitle(title: Localized.songs) {
                        sortMenu
                    }
                    .songsTitleRow()
                    ForEach(visibleRows, id: \.rowId) { row in
                        let track = row.track
                        LiveTrackRow(
                            track: track,
                            artistName: artistDisplayNameCache[track.stableId] ?? track.artistId.flatMap { artistNameCache[$0] },
                            playlist: playlist,
                            showDirectDeleteButton: isEditMode,
                            contextIdentity: contextIdentity
                        ) {
                            guard !isEditMode else { return }
                            dismissSearchKeyboard()
                            Task {
                                guard let playlistId = playlist.id else { return }
                                try? appCoordinator.updatePlaylistAccessed(playlistId: playlistId)
                                try? appCoordinator.updatePlaylistLastPlayed(playlistId: playlistId)

                                let visible = sortedTracks
                                let queue = LibrarySearch.queueSource(
                                    filtered: visible,
                                    full: fullSortedTracks,
                                    isSearching: search.isSearching
                                )
                                // A playlist may hold the same track twice, so the
                                // tapped copy has to be located by position rather
                                // than by stable ID.
                                let start = queue.count == visible.count
                                    ? row.index
                                    : LibrarySearch.fullListIndex(
                                        ofFiltered: row.index,
                                        in: visible,
                                        within: queue
                                    )
                                await playerEngine.playTrack(at: start, in: queue)
                            }
                        }
                        .songListRow(track, swipeActionsEnabled: !isEditMode)
                    }
                    .onMove(perform: sortOption == .playlistOrder && !isSearching ? { source, destination in
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
                }
            } else {
                Section {
                    Group {
                        if isSearching {
                            ContentUnavailableView.search(text: search.text)
                        } else {
                            CosmosEmptyState(
                                systemImage: "music.note",
                                title: Localized.noSongsFound,
                                message: Localized.yourMusicWillAppearHere.namingThisDevice
                            )
                        }
                    }
                    .padding(.vertical, Design.Spacing.xl)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
        }
        .environment(\.editMode, .constant(isEditMode ? .active : .inactive))
        .background(ScreenSpecificBackgroundView(screen: .playlistDetail))
        .navigationTitle(playlist.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTitleDisplayMode(.inline)
        .librarySearchField(search, prompt: Localized.searchSongs)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                LibrarySearchButton(state: search)
                // A mix grown from the whole playlist: mostly songs beyond it.
                if !isEditMode, let playlistId = playlist.id {
                    Button {
                        MixStore.shared.playPlaylistMix(playlistId: playlistId)
                    } label: {
                        Label(Localized.playlistMix, systemImage: "dot.radiowaves.left.and.right")
                    }
                    .disabled(tracks.isEmpty)
                }
                // Edit lives in "…" with Export; while editing, Done takes
                // its place in the bar.
                if isEditMode {
                    Button(Localized.done) {
                        withAnimation {
                            isEditMode = false
                        }
                    }
                } else {
                    PlaylistMoreMenu(playlist: playlist, hasSongs: !tracks.isEmpty) {
                        withAnimation {
                            isEditMode = true
                        }
                    }
                }
            }
            .cosmosPlainBackground()
        }
        .onAppear {
            loadPlaylistTracks()
            loadSortPreference()
            loadCustomCover()
            loadArtistNameCache()
        }
        #if DEBUG
        // -cosmosDebugEdit 1 opens the playlist in edit mode, and `cover`
        // with the cover choices up - for screenshots.
        .task {
            guard let mode = UserDefaults.standard.string(forKey: "cosmosDebugEdit"), !tracks.isEmpty else { return }
            isEditMode = true
            if mode == "cover" {
                try? await Task.sleep(for: .milliseconds(600))
                showCoverOptions = true
            }
        }
        #endif
        // See TrackListView: the rebuild is asynchronous, so one .task covers
        // both the first appearance and every later change of the row set.
        .task(id: TrackSearchIndex.identity(for: tracks)) {
            let rebuilt = await TrackSearchIndex.rebuilt(from: searchIndex, for: tracks)
            // See TrackListView: a superseded build must not overwrite the one
            // that replaced it.
            guard !Task.isCancelled else { return }
            searchIndex = rebuilt
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LibraryNeedsRefresh"))) { _ in
            loadPlaylistTracks()
            Task {
                searchIndex = await TrackSearchIndex.rebuilt(
                    from: searchIndex,
                    for: tracks,
                    force: true
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("BackgroundColorChanged"))) { _ in
            settings = DeleteSettings.load()
        }
        .onChange(of: showCoverOptions) { _, isShown in
            guard !isShown, let picker = pickerAfterDialog else { return }
            pickerAfterDialog = nil
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                switch picker {
                case .photos: showingImagePicker = true
                case .files: showingCoverFileImporter = true
                }
            }
        }
        .fileImporter(isPresented: $showingCoverFileImporter, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return }
            Task { await saveCustomCover(image) }
        }
        .photosPicker(isPresented: $showingImagePicker, selection: $selectedPhotoItem, matching: .images)
        .onChange(of: selectedPhotoItem) { newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    await saveCustomCover(image)
                }
                // Lets the same photo be picked again later.
                selectedPhotoItem = nil
            }
        }
    }

    @ViewBuilder
    private var coverOptions: some View {
        // A plain button, with the picker presented from the screen below.
        // A PhotosPicker inside the dialog is torn down with the dialog
        // the moment it is tapped, so the picker never appeared.
        // Each picker is presented once the dialog has finished closing:
        // asking for it while the dialog was still on its way out was
        // silently refused (iOS 27), and nothing opened.
        Button(Localized.chooseCoverFromPhotos) {
            pickerAfterDialog = .photos
        }
        Button(Localized.chooseCoverFromFiles) {
            pickerAfterDialog = .files
        }

        if customCoverImage != nil {
            Button(Localized.removeCustomCover, role: .destructive) {
                removeCustomCover()
            }
        }

        Button(Localized.cancel, role: .cancel) { }
    }

    private var sortMenu: some View {
        Menu {
            Picker(selection: Binding(
                get: { sortOption },
                set: { option in
                    sortOption = option
                    saveSortPreference()
                }
            )) {
                ForEach(TrackSortOption.allCases, id: \.self) { option in
                    Text(option.localizedString).tag(option)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.body.weight(.semibold))
                .foregroundStyle(settings.backgroundColorChoice.color)
                .frame(width: Design.Size.minTouch, height: Design.Size.minTouch)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Localized.sortBy)
    }

    private func loadPlaylistTracks() {
        guard let playlistId = playlist.id else { return }
        let signpost = Perf.begin("Playlist page load")
        defer { Perf.end("Playlist page load", signpost) }

        do {
            let playlistItems = try appCoordinator.databaseManager.getPlaylistItems(playlistId: playlistId)
            let trackIds = playlistItems.map { $0.trackStableId }
            tracks = try appCoordinator.databaseManager.getTracksByStableIdsPreservingOrder(trackIds)
            loadArtistNameCache()

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
            if let artwork = await artworkManager.getThumbnail(for: track, maxPixelSize: 256) {
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

    private func loadArtistNameCache() {
        do {
            artistNameCache = try DatabaseManager.shared.getAllArtistNamesById()
            let fallbackArtistIds = tracks.reduce(into: [String: Int64]()) { result, track in
                if let artistId = track.artistId {
                    result[track.stableId] = artistId
                }
            }
            artistDisplayNameCache = try DatabaseManager.shared.getArtistDisplayNames(
                forTrackStableIds: tracks.map(\.stableId),
                fallbackArtistIdsByStableId: fallbackArtistIds
            )
        } catch {
            print("Failed to load playlist artist cache: \(error)")
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
        let coverImage = image.squarePlaylistCover()

        // Save a normalized square image so all playlist covers match standard artwork sizing.
        guard let jpegData = coverImage.jpegData(compressionQuality: 0.85) else {
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
            customCoverImage = coverImage

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

struct PlaylistListView: View {
    let playlists: [Playlist]
    let onPlaylistTap: (Playlist) -> Void

    var body: some View {
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
        NavigationStack {
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
                ToolbarItem(placement: .topBarTrailing) {
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
        let title = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }

        do {
            // Same name as an existing playlist (any case): add to that one
            // rather than making a second of the same name.
            let playlist: Playlist
            if let existing = try DatabaseManager.shared.playlist(matchingTitle: title) {
                playlist = existing
            } else {
                playlist = try appCoordinator.createPlaylist(title: title)
                playlists.append(playlist)
            }
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
        NavigationStack {
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
                ToolbarItem(placement: .topBarTrailing) {
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
