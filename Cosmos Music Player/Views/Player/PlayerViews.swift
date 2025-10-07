import SwiftUI
import AVKit

struct EqualizerBarsExact: View {
    let color: Color
    let isActive: Bool
    let isLarge: Bool
    let trackId: String?

    private var minH: CGFloat { isLarge ? 2 : 1 }
    private var targetH: [CGFloat] { isLarge ? [4, 12, 8, 16] : [3, 8, 6, 10] }
    private let durations: [Double] = [0.6, 0.8, 0.4, 0.7]

    @State private var kick = false
    @Environment(\.scenePhase) private var scenePhase

    private var restartKey: String { "\(isActive)-\(trackId ?? "")" }

    var body: some View {
        HStack(alignment: .bottom, spacing: 1) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(color)
                    .frame(width: isLarge ? 2 : 1.5)
                    .frame(height: isActive && kick ? targetH[i] : minH)
                    .animation(
                        isActive
                        ? .easeInOut(duration: durations[i]).repeatForever(autoreverses: true)
                        : .easeInOut(duration: 0.2),
                        value: kick
                    )
            }
        }
        .frame(width: isLarge ? 12 : 10, height: isLarge ? 20 : 12)
        .id(restartKey)                 // force view identity reset on key change
        .task(id: restartKey) { restart() } // runs on mount and when key changes
        .onChange(of: scenePhase) { p in
            if p == .active { restart() }   // recover after app foregrounding
        }
    }

    private func restart() {
        kick = false
        DispatchQueue.main.async {
            if isActive { kick = true }     // start a fresh repeatForever cycle
        }
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
import GRDB

struct PlayerView: View {
    @StateObject private var playerEngine = PlayerEngine.shared
    @StateObject private var artworkManager = ArtworkManager.shared
    @StateObject private var cloudDownloadManager = CloudDownloadManager.shared
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var currentArtwork: UIImage?
    @State private var nextArtwork: UIImage?
    @State private var previousArtwork: UIImage?
    @State private var dragOffset: CGFloat = 0
    @State private var isAnimating = false
    @State private var allTracks: [Track] = []
    @State private var isFavorite = false
    @State private var showPlaylistDialog = false
    @State private var showQueueSheet = false
    @State private var settings = DeleteSettings.load()
    
    var body: some View {
        ZStack {
            ScreenSpecificBackgroundView(screen: .player)
            
            VStack(spacing: UIScreen.main.scale < UIScreen.main.nativeScale ? 16 : 20) {
                if let currentTrack = playerEngine.currentTrack {
                    VStack(spacing: UIScreen.main.scale < UIScreen.main.nativeScale ? 20 : 25) {
                        // Album artwork with hidden adjacent images that appear during swipe
                        GeometryReader { geometry in
                            let maxWidth = min(geometry.size.width - 40, 360) // Cap max width at 360
                            let artworkSize = min(maxWidth, geometry.size.height) // Keep it square
                            
                            ZStack {
                                // Current track image (always visible)
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.gray.opacity(0.1))
                                        .frame(width: artworkSize, height: artworkSize)
                                    
                                    if let artwork = currentArtwork {
                                        Image(uiImage: artwork)
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .frame(width: artworkSize, height: artworkSize)
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                    } else {
                                        Image(systemName: "music.note")
                                            .font(.system(size: min(80, artworkSize * 0.2)))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .offset(x: dragOffset)
                                .animation(.easeOut(duration: 0.3), value: dragOffset)
                                
                                // Previous track image (only visible when swiping right)
                                if dragOffset > 0, previousArtwork != nil {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(Color.gray.opacity(0.1))
                                            .frame(width: artworkSize, height: artworkSize)
                                        
                                        if let artwork = previousArtwork {
                                            Image(uiImage: artwork)
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                                .frame(width: artworkSize, height: artworkSize)
                                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                        } else {
                                            Image(systemName: "music.note")
                                                .font(.system(size: min(80, artworkSize * 0.2)))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .offset(x: dragOffset - geometry.size.width) // Position from left screen edge
                                    .animation(.easeOut(duration: 0.3), value: dragOffset)
                                }
                                
                                // Next track image (only visible when swiping left)
                                if dragOffset < 0, nextArtwork != nil {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(Color.gray.opacity(0.1))
                                            .frame(width: artworkSize, height: artworkSize)
                                        
                                        if let artwork = nextArtwork {
                                            Image(uiImage: artwork)
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                                .frame(width: artworkSize, height: artworkSize)
                                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                        } else {
                                            Image(systemName: "music.note")
                                                .font(.system(size: min(80, artworkSize * 0.2)))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .offset(x: dragOffset + geometry.size.width) // Position from right screen edge
                                    .animation(.easeOut(duration: 0.3), value: dragOffset)
                                }
                            }
                            .frame(width: geometry.size.width, height: artworkSize)
                        }
                        .frame(height: min(360, UIScreen.main.bounds.width - 80))
                        .clipped()
                        .shadow(radius: 8)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    if !isAnimating {
                                        dragOffset = value.translation.width
                                    }
                                }
                                .onEnded { value in
                                    let threshold: CGFloat = 80
                                    
                                    if value.translation.width > threshold {
                                        // Swipe right - previous track
                                        isAnimating = true
                                        withAnimation(.easeInOut(duration: 0.3)) {
                                            dragOffset = UIScreen.main.bounds.width // Move to right edge
                                        }
                                        
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                            Task {
                                                await playerEngine.previousTrack()
                                            }
                                            dragOffset = 0
                                            isAnimating = false
                                        }
                                        
                                    } else if value.translation.width < -threshold {
                                        // Swipe left - next track
                                        isAnimating = true
                                        withAnimation(.easeInOut(duration: 0.3)) {
                                            dragOffset = -UIScreen.main.bounds.width // Move to left edge
                                        }
                                        
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                            Task {
                                                await playerEngine.nextTrack()
                                            }
                                            dragOffset = 0
                                            isAnimating = false
                                        }
                                        
                                    } else {
                                        // Return to center
                                        withAnimation(.easeOut(duration: 0.2)) {
                                            dragOffset = 0
                                        }
                                    }
                                }
                        )
                        
                        // Compact horizontal layout: title/artist on left, buttons on right
                        HStack(alignment: .center, spacing: 16) {
                            // Left side: Title and Artist
                            VStack(alignment: .leading, spacing: 4) {
                                Text(currentTrack.title)
                                    .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title3 : .title2)
                                    .fontWeight(.semibold)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                
                                if let artistId = currentTrack.artistId,
                                   let artist = try? DatabaseManager.shared.read({ db in
                                       try Artist.fetchOne(db, key: artistId)
                                   }) {
                                    Button(action: {
                                        // Post notification to navigate to artist and minimize player
                                        let userInfo = ["artist": artist, "allTracks": allTracks] as [String : Any]
                                        NotificationCenter.default.post(name: NSNotification.Name("NavigateToArtistFromPlayer"), object: nil, userInfo: userInfo)
                                    }) {
                                        Text(artist.name)
                                            .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .caption : .subheadline)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }
                            
                            Spacer()
                            
                            // Right side: Like and Add to Playlist buttons
                            HStack(spacing: UIScreen.main.scale < UIScreen.main.nativeScale ? 16 : 20) {
                                // Like button
                                Button(action: {
                                    toggleFavorite()
                                }) {
                                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                                        .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title3 : .title2)
                                        .foregroundColor(isFavorite ? .red : .primary)
                                }
                                
                                // Add to playlist button
                                Button(action: {
                                    showPlaylistDialog = true
                                }) {
                                    Image(systemName: "plus.circle")
                                        .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title3 : .title2)
                                        .foregroundColor(.primary)
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                    
                    // Interactive progress bar with matching width
                    VStack(spacing: UIScreen.main.scale < UIScreen.main.nativeScale ? 12 : 16) {
                        InteractiveProgressBar(
                            progress: playerEngine.duration > 0 ? playerEngine.playbackTime / playerEngine.duration : 0,
                            onSeek: { progress in
                                let newTime = progress * playerEngine.duration
                                Task {
                                    await playerEngine.seek(to: newTime)
                                }
                            },
                            accentColor: settings.backgroundColorChoice.color
                        )
                        .frame(height: 1)
                        
                        HStack {
                            Text(formatTime(playerEngine.playbackTime))
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Spacer()
                            
                            Text(formatTime(playerEngine.duration))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    
                    VStack(spacing: UIScreen.main.scale < UIScreen.main.nativeScale ? 20 : 25) {
                        // Main playback controls
                        HStack(spacing: min(35, UIScreen.main.bounds.width * 0.08)) {
                            // Shuffle button (left of previous)
                            Button(action: {
                                playerEngine.toggleShuffle()
                            }) {
                                Image(systemName: playerEngine.isShuffled ? "shuffle.circle.fill" : "shuffle.circle")
                                    .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title2 : .title)
                                    .foregroundColor(playerEngine.isShuffled ? .accentColor : .primary)
                            }
                            
                            // Previous track button
                            Button(action: {
                                Task {
                                    await playerEngine.previousTrack()
                                }
                            }) {
                                Image(systemName: "backward.fill")
                                    .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title2 : .title)
                            }
                            
                            // Play/Pause button (center, larger)
                            Button(action: {
                                if playerEngine.isPlaying {
                                    playerEngine.pause()
                                } else {
                                    playerEngine.play()
                                }
                            }) {
                                Image(systemName: playerEngine.isPlaying ? "pause.fill" : "play.fill")
                                    .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title : .largeTitle)
                            }
                            
                            // Next track button
                            Button(action: {
                                Task {
                                    await playerEngine.nextTrack()
                                }
                            }) {
                                Image(systemName: "forward.fill")
                                    .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title2 : .title)
                            }
                            
                            // Loop button (right of next) - cycles through Off → Queue Loop → Song Loop → Off
                            Button(action: {
                                playerEngine.cycleLoopMode()
                            }) {
                                Group {
                                    if playerEngine.isLoopingSong {
                                        Image(systemName: "repeat.1.circle.fill")
                                            .foregroundColor(settings.backgroundColorChoice.color)
                                    } else if playerEngine.isRepeating {
                                        Image(systemName: "repeat.circle.fill")
                                            .foregroundColor(settings.backgroundColorChoice.color)
                                    } else {
                                        Image(systemName: "repeat.circle")
                                            .foregroundColor(.primary)
                                    }
                                }
                                .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title2 : .title)
                            }
                        }
                        .padding(.horizontal, min(21, UIScreen.main.bounds.width * 0.055))
                        .padding(.vertical, 21)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 25))
                        .overlay(
                            RoundedRectangle(cornerRadius: 25)
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        )
                        
                        // List and AirPlay buttons below - separated
                        HStack(spacing: 16) {
                            // List button for song order
                            Button(action: {
                                showQueueSheet = true
                            }) {
                                Image(systemName: "list.bullet")
                                    .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title2 : .title)
                                    .foregroundColor(.primary)
                                    .frame(maxWidth: .infinity, minHeight: 30)
                                    .padding(.vertical, 16)
                            }
                            .frame(maxWidth: .infinity)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20)
                                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
                            )
                            
                            // AirPlay button
                            Button(action: {
                                // Open AirPlay picker
                                showAirPlayPicker()
                            }) {
                                Image(systemName: "airplayaudio")
                                    .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title2 : .title)
                                    .foregroundColor(.primary)
                                    .frame(maxWidth: .infinity, minHeight: 25)
                                    .padding(.vertical, 16)
                            }
                            .frame(maxWidth: .infinity)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20)
                                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
                            )
                        }
                        .padding(.horizontal, 5)
                    }
                } else {
                    VStack {
                        Image(systemName: "music.note")
                            .font(.system(size: 60))
                            .foregroundColor(.secondary)
                        
                        Text(Localized.noTrackSelected)
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, max(16, min(20, UIScreen.main.bounds.width * 0.05)))
            .padding(.vertical)
            .onChange(of: playerEngine.currentTrack) { _, newTrack in
                Task {
                    await loadAllArtworks()
                }
            }
            .onAppear {
                Task {
                    await loadAllArtworks()
                    await loadTracks()
                    checkFavoriteStatus()
                }
            }
            .onChange(of: playerEngine.currentTrack) { _, newTrack in
                checkFavoriteStatus()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("BackgroundColorChanged"))) { _ in
                settings = DeleteSettings.load()
            }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                settings = DeleteSettings.load()
            }
            .sheet(isPresented: $showPlaylistDialog) {
                if let currentTrack = playerEngine.currentTrack {
                    PlaylistSelectionView(track: currentTrack)
                        .accentColor(settings.backgroundColorChoice.color)
                }
            }
            .sheet(isPresented: $showQueueSheet) {
                QueueManagementView()
                    .accentColor(settings.backgroundColorChoice.color)
            }
        }
    }
    
    private func loadAllArtworks() async {
        await loadCurrentArtwork()
        await loadNextArtwork()
        await loadPreviousArtwork()
    }
    
    private func loadCurrentArtwork() async {
        if let track = playerEngine.currentTrack {
            currentArtwork = await artworkManager.getArtwork(for: track)
        } else {
            currentArtwork = nil
        }
    }
    
    private func loadNextArtwork() async {
        let nextTrack = getNextTrack()
        if let track = nextTrack {
            nextArtwork = await artworkManager.getArtwork(for: track)
        } else {
            nextArtwork = nil
        }
    }
    
    private func loadPreviousArtwork() async {
        let prevTrack = getPreviousTrack()
        if let track = prevTrack {
            previousArtwork = await artworkManager.getArtwork(for: track)
        } else {
            previousArtwork = nil
        }
    }
    
    private func getNextTrack() -> Track? {
        let queue = playerEngine.playbackQueue
        let currentIndex = playerEngine.currentIndex
        
        guard !queue.isEmpty else { return nil }
        
        if currentIndex < queue.count - 1 {
            // Normal next track
            return queue[currentIndex + 1]
        } else {
            // Wraparound to first track
            return queue[0]
        }
    }
    
    private func getPreviousTrack() -> Track? {
        let queue = playerEngine.playbackQueue
        let currentIndex = playerEngine.currentIndex
        
        guard !queue.isEmpty else { return nil }
        
        if currentIndex > 0 {
            // Normal previous track
            return queue[currentIndex - 1]
        } else {
            // Wraparound to last track
            return queue[queue.count - 1]
        }
    }
    
    @MainActor
    private func loadTracks() async {
        do {
            allTracks = try appCoordinator.getAllTracks()
            print("✅ Loaded \(allTracks.count) tracks for artist navigation")
        } catch {
            print("❌ Failed to load tracks: \(error)")
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    private func checkFavoriteStatus() {
        guard let currentTrack = playerEngine.currentTrack else {
            isFavorite = false
            return
        }
        
        do {
            isFavorite = try DatabaseManager.shared.isFavorite(trackStableId: currentTrack.stableId)
        } catch {
            print("Failed to check favorite status: \(error)")
            isFavorite = false
        }
    }
    
    private func toggleFavorite() {
        guard let currentTrack = playerEngine.currentTrack else { return }
        
        do {
            try appCoordinator.toggleFavorite(trackStableId: currentTrack.stableId)
            isFavorite.toggle()
        } catch {
            print("Failed to toggle favorite: \(error)")
        }
    }
    
    private func showAirPlayPicker() {
        let routePickerView = AVRoutePickerView()
        routePickerView.prioritizesVideoDevices = false
        
        // Find the button inside the route picker and simulate a tap
        for subview in routePickerView.subviews {
            if let button = subview as? UIButton {
                button.sendActions(for: .touchUpInside)
                break
            }
        }
    }
}

struct InteractiveProgressBar: View {
    let progress: Double
    let onSeek: (Double) -> Void
    let accentColor: Color
    
    @State private var isDragging = false
    @State private var dragProgress: Double = 0
    
    var displayProgress: Double {
        isDragging ? dragProgress : progress
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.gray.opacity(0.3))
                    .frame(height: 4)
                
                // Progress fill
                RoundedRectangle(cornerRadius: 2)
                    .fill(accentColor)
                    .frame(width: geometry.size.width * displayProgress, height: 4)
                
                // Thumb/Handle
                Circle()
                    .fill(accentColor)
                    .frame(width: 12, height: 12)
                    .offset(x: (geometry.size.width * displayProgress) - 6)
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                let newProgress = max(0, min(1, location.x / geometry.size.width))
                onSeek(newProgress)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        dragProgress = max(0, min(1, value.location.x / geometry.size.width))
                    }
                    .onEnded { value in
                        let finalProgress = max(0, min(1, value.location.x / geometry.size.width))
                        onSeek(finalProgress)
                        isDragging = false
                    }
            )
        }
    }
}

struct MiniPlayerView: View {
    @StateObject private var playerEngine = PlayerEngine.shared
    @StateObject private var artworkManager = ArtworkManager.shared
    @State private var isExpanded = false
    @State private var currentArtwork: UIImage?
    @State private var dragOffset: CGFloat = 0
    @State private var settings = DeleteSettings.load()
    
    var body: some View {
        Group {
            if playerEngine.currentTrack != nil {
                // Mini player that shows sheet when tapped
                VStack(spacing: 0) {
                    // Mini player content
                    HStack(spacing: 12) {
                        // Album artwork
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.gray.opacity(0.2))
                                .frame(width: 60, height: 60)
                            
                            if let artwork = currentArtwork {
                                Image(uiImage: artwork)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 60, height: 60)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            } else {
                                Image(systemName: "music.note")
                                    .font(.title2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        // Track info
                        VStack(alignment: .leading, spacing: 4) {
                            Text(playerEngine.currentTrack?.title ?? "")
                                .font(.headline)
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            
                            if let artistId = playerEngine.currentTrack?.artistId,
                               let artist = try? DatabaseManager.shared.read({ db in
                                   try Artist.fetchOne(db, key: artistId)
                               }) {
                                Text(artist.name)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        
                        Spacer()
                        
                        // Play/Pause button
                        Button(action: {
                            if playerEngine.isPlaying {
                                playerEngine.pause()
                            } else {
                                playerEngine.play()
                            }
                        }) {
                            Image(systemName: playerEngine.isPlaying ? "pause.circle" : "play.circle")
                                .font(.title)
                                .foregroundColor(.primary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        // Very strong glassy background
                        RoundedRectangle(cornerRadius: 16)
                            .fill(.regularMaterial)
                            .opacity(0.98)
                    )
                    .overlay(
                        // Progress bar integrated into the mini player background
                        VStack(spacing: 0) {
                            Spacer()
                            
                            ZStack(alignment: .leading) {
                                // Background track
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.2))
                                    .frame(height: 2)
                                
                                // Progress fill with selected accent color
                                GeometryReader { geometry in
                                    Rectangle()
                                        .fill(settings.backgroundColorChoice.color)
                                        .frame(width: geometry.size.width * (playerEngine.duration > 0 ? playerEngine.playbackTime / playerEngine.duration : 0), height: 2)
                                }
                            }
                            .frame(height: 2)
                        }
                    )
                    .cornerRadius(16)
                    .shadow(color: settings.backgroundColorChoice.color.opacity(0.3), radius: 8, x: 0, y: 4)
                    .padding(.horizontal, 12)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isExpanded = true
                    }
                }
                .sheet(isPresented: $isExpanded) {
                    // Full screen player as sheet
                    PlayerView()
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                        .interactiveDismissDisabled(false)
                        .accentColor(settings.backgroundColorChoice.color)
                }
                .task(id: playerEngine.currentTrack?.stableId) {
                    if let track = playerEngine.currentTrack {
                        currentArtwork = await artworkManager.getArtwork(for: track)
                    } else {
                        currentArtwork = nil
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NavigateToArtistFromPlayer"))) { _ in
                    // Minimize the player when artist navigation is requested
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                        isExpanded = false
                        dragOffset = 0 // Reset drag offset immediately
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("BackgroundColorChanged"))) { _ in
                    settings = DeleteSettings.load()
                }
            }
        }
    }
}

struct TrackRowView: View {
    let track: Track
    let onTap: () -> Void
    let playlist: Playlist?
    let showDirectDeleteButton: Bool
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @StateObject private var cloudDownloadManager = CloudDownloadManager.shared
    @StateObject private var playerEngine = PlayerEngine.shared
    
    @State private var isFavorite = false
    @State private var isPressed = false
    @State private var showPlaylistDialog = false
    @State private var isMenuInteracting = false
    @State private var artworkImage: UIImage?
    @State private var showDeleteConfirmation = false
    @State private var deleteSettings = DeleteSettings.load()
    @State private var selectedArtist: Artist?
    @State private var dragStartLocation: CGPoint = .zero
    @State private var gestureTimer: Timer?
    @State private var isDeleteButtonInteracting = false

    init(track: Track, onTap: @escaping () -> Void, playlist: Playlist? = nil, showDirectDeleteButton: Bool = false) {
        self.track = track
        self.onTap = onTap
        self.playlist = playlist
        self.showDirectDeleteButton = showDirectDeleteButton
    }

    private var isCurrentlyPlaying: Bool {
        playerEngine.currentTrack?.stableId == track.stableId
    }
    
    var body: some View {
        HStack {
            // Album artwork thumbnail
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
                
                // Overlay playing indicator on artwork for currently playing track
                if isCurrentlyPlaying {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(deleteSettings.backgroundColorChoice.color, lineWidth: 2)
                        .frame(width: 60, height: 60)
                }
            }
            
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
            
            // Currently playing indicator (Deezer-style equalizer)
            if isCurrentlyPlaying {
                let eqKey = "\(playerEngine.isPlaying && isCurrentlyPlaying)-\(playerEngine.currentTrack?.stableId ?? "")"
                
                EqualizerBarsExact(
                    color: deleteSettings.backgroundColorChoice.color,
                    isActive: playerEngine.isPlaying && isCurrentlyPlaying,
                    isLarge: true,
                    trackId: playerEngine.currentTrack?.stableId
                )
                .id(eqKey)
            }
            
            // Show either direct delete button or menu based on context
            if showDirectDeleteButton {
                Button(action: {
                    removeFromPlaylist()
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
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            isDeleteButtonInteracting = true
                        }
                        .onEnded { _ in
                            // Reset after a short delay to ensure button interaction is complete
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                isDeleteButtonInteracting = false
                            }
                        }
                )
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
                                .foregroundColor(isFavorite ? .red : .primary)
                            Text(isFavorite ? Localized.removeFromLikedSongs : Localized.addToLikedSongs)
                                .foregroundColor(.primary)
                        }
                    }

                    if let artistId = track.artistId,
                       let artist = try? DatabaseManager.shared.read({ db in
                           try Artist.fetchOne(db, key: artistId)
                       }),
                       let allArtistTracks = try? DatabaseManager.shared.read({ db in
                           try Track.filter(Column("artist_id") == artistId).fetchAll(db)
                       }) {
                        NavigationLink(destination: ArtistDetailScreen(artist: artist, allTracks: allArtistTracks)) {
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
                        .frame(width: 30, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            isMenuInteracting = true
                        }
                        .onEnded { _ in
                            // Reset after a short delay to ensure menu interaction is complete
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                isMenuInteracting = false
                            }
                        }
                )
            }
        }
        .frame(height: 80)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(deleteSettings.backgroundColorChoice.color.opacity(0.12))
                .scaleEffect(isPressed ? 1.0 : 0.01)
                .animation(.easeOut(duration: 0.20), value: isPressed)
                .opacity(isPressed ? 1.0 : 0.0)
        )
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
        .contentShape(Rectangle())
        .onTapGesture {
            if !isMenuInteracting && !isDeleteButtonInteracting {
                onTap()
            }
        }
        .onAppear {
            isFavorite = (try? appCoordinator.isFavorite(trackStableId: track.stableId)) ?? false
            loadArtwork()
        }
        .task {
            // Ensure artwork loads even if onAppear doesn't trigger
            if artworkImage == nil {
                loadArtwork()
            }
        }
    }
    
    private func loadArtwork() {
        Task {
            do {
                artworkImage = await ArtworkManager.shared.getArtwork(for: track)
            }
        }
    }
    
    private func deleteFile() {
        Task {
            do {
                let url = URL(fileURLWithPath: track.path)
                
                // Delete file from storage
                try FileManager.default.removeItem(at: url)
                print("🗑️ Deleted file from storage: \(track.title)")
                
                // Delete from database with cleanup of orphaned relations
                try DatabaseManager.shared.deleteTrack(byStableId: track.stableId)
                print("✅ Database deletion completed successfully")
                
                // Notify UI to refresh
                NotificationCenter.default.post(name: NSNotification.Name("LibraryNeedsRefresh"), object: nil)
                
            } catch {
                print("❌ Failed to delete file: \(error)")
            }
        }
    }

    private func removeFromPlaylist() {
        guard let playlist = playlist, let playlistId = playlist.id else {
            print("❌ No playlist or playlist ID available")
            return
        }

        Task {
            do {
                try appCoordinator.removeFromPlaylist(playlistId: playlistId, trackStableId: track.stableId)
                print("✅ Removed '\(track.title)' from playlist '\(playlist.title)'")

                // Notify UI to refresh
                NotificationCenter.default.post(name: NSNotification.Name("LibraryNeedsRefresh"), object: nil)

            } catch {
                print("❌ Failed to remove from playlist: \(error)")
            }
        }
    }

}

struct WaveformView: View {
    let isPlaying: Bool
    let color: Color
    @State private var waveHeights: [CGFloat] = Array(repeating: 2, count: 6)
    @State private var timer: Timer?
    @State private var animationTrigger = false
    
    var body: some View {
        HStack(alignment: .center, spacing: 1) {
            ForEach(0..<waveHeights.count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(color.opacity(0.8))
                    .frame(width: 2, height: waveHeights[index])
                    .animation(
                        .easeInOut(duration: 0.3)
                        .repeatForever(autoreverses: true),
                        value: animationTrigger
                    )
            }
        }
        .onAppear {
            startWaveform()
        }
        .onDisappear {
            stopWaveform()
        }
        .onChange(of: isPlaying) { newValue in
            if newValue {
                startWaveform()
            } else {
                stopWaveform()
            }
        }
    }
    
    private func startWaveform() {
        guard timer == nil && isPlaying else { return }
        
        // Start with animated heights
        updateWaveHeights()
        
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            Task { @MainActor in
                if isPlaying {
                    updateWaveHeights()
                    animationTrigger.toggle()
                }
            }
        }
    }
    
    private func stopWaveform() {
        timer?.invalidate()
        timer = nil
        
        // Animate to flat line when stopped
        withAnimation(.easeOut(duration: 0.4)) {
            waveHeights = Array(repeating: 2, count: waveHeights.count)
        }
    }
    
    private func updateWaveHeights() {
        guard isPlaying else { return }
        
        let newHeights: [CGFloat] = [
            CGFloat.random(in: 3...12),
            CGFloat.random(in: 6...14),
            CGFloat.random(in: 2...10),
            CGFloat.random(in: 8...16),
            CGFloat.random(in: 4...11),
            CGFloat.random(in: 5...13)
        ]
        
        withAnimation(.easeInOut(duration: 0.3)) {
            waveHeights = newHeights
        }
    }
}
