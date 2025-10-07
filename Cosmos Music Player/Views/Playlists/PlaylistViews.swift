import SwiftUI


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
                    }
                    .padding(8)
                    .zIndex(1000)
                }
                
                // Artwork content - same in both edit and normal mode
                if allTracks.count >= 4 {
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
            await loadArtworks()
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
}

struct PlaylistDetailScreen: View {
    let playlist: Playlist
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var tracks: [Track] = []
    @State private var isEditMode: Bool = false

    var body: some View {
        TrackListView(tracks: tracks, playlist: playlist, isEditMode: isEditMode)
            .background(ScreenSpecificBackgroundView(screen: .playlistDetail))
            .navigationTitle(playlist.title)
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
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LibraryNeedsRefresh"))) { _ in
                loadPlaylistTracks()
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
        } catch {
            print("Failed to load playlist tracks: \(error)")
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
