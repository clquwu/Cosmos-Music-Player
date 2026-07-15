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

private enum ArtworkSwipeDirection: Equatable {
    case previous
    case next

    var offsetSign: CGFloat {
        switch self {
        case .previous: return 1
        case .next: return -1
        }
    }
}

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
    @State private var showLyricsSheet = false
    @State private var currentLyrics: Lyrics? = nil
    @State private var isLoadingLyrics = false
    @State private var settings = DeleteSettings.load()
    @State private var sleepTimerTask: Task<Void, Never>?
    @State private var sleepTimerEndDate: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    var body: some View {
        ZStack {
            ScreenSpecificBackgroundView(screen: .player)
            mainContent
        }
        // Cap Dynamic Type so large accessibility sizes don't overflow the player layout
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private var mainContent: some View {
        contentView
            .padding(.horizontal, max(16, min(20, UIScreen.main.bounds.width * 0.05)))
            .padding(.vertical)
            .onChange(of: playerEngine.currentTrack) { _, _ in
                guard !isAnimating else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    dragOffset = 0
                }
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
            .onReceive(NotificationCenter.default.publisher(for: .cosmosSettingsDidChange)) { _ in
                settings = DeleteSettings.load()
            }
            .sheet(isPresented: $showPlaylistDialog) {
                playlistSheet
            }
            .sheet(isPresented: $showQueueSheet) {
                queueSheet
            }
            .sheet(isPresented: $showLyricsSheet) {
                lyricsSheet
            }
            .onChange(of: playerEngine.currentTrack) { oldValue, newValue in
                // Clear current lyrics
                currentLyrics = nil

                // If lyrics sheet is open, load lyrics for new track
                if showLyricsSheet {
                    loadLyrics()
                } else {
                    isLoadingLyrics = false
                }
            }
    }

    private var contentView: some View {
        VStack(spacing: UIScreen.main.scale < UIScreen.main.nativeScale ? 16 : 20) {
            if let currentTrack = playerEngine.currentTrack {
                VStack(spacing: UIScreen.main.scale < UIScreen.main.nativeScale ? 20 : 25) {
                    artworkSection
                    titleAndArtistSection(track: currentTrack)
                }

                progressBarSection
                controlsSection
            } else {
                emptyStateView
            }
        }
    }

    private var playlistSheet: some View {
        Group {
            if let currentTrack = playerEngine.currentTrack {
                PlaylistSelectionView(track: currentTrack)
                    .accentColor(settings.backgroundColorChoice.color)
            }
        }
    }

    private var queueSheet: some View {
        QueueManagementView()
            .accentColor(settings.backgroundColorChoice.color)
    }

    private var lyricsSheet: some View {
        LiveLyricsSheet(lyrics: currentLyrics, isLoading: isLoadingLyrics)
    }

    // MARK: - Artwork Section

    private var artworkSection: some View {
        GeometryReader { geometry in
            let maxWidth = min(geometry.size.width - 40, 360)
            let artworkSize = min(maxWidth, geometry.size.height)
            let gestureWidth = max(geometry.size.width, 1)
            let pageDistance = artworkSize + 18
            let swipeProgress = min(abs(dragOffset) / pageDistance, 1)
            let signedProgress = max(-1, min(1, dragOffset / pageDistance))
            let canNavigate = playerEngine.playbackQueue.count > 1

            ZStack {
                if canNavigate {
                    adjacentArtworkView(artwork: previousArtwork, size: artworkSize)
                        .offset(x: dragOffset - pageDistance)
                        .scaleEffect(0.96 + (0.04 * max(0, signedProgress)))
                        .opacity(Double(0.72 + (0.28 * max(0, signedProgress))))
                        .shadow(color: .black.opacity(0.16), radius: 8, x: 0, y: 5)
                        .zIndex(0)
                }

                currentArtworkView(size: artworkSize)
                    .offset(x: dragOffset)
                    .scaleEffect(1 - (0.025 * swipeProgress))
                    .shadow(
                        color: .black.opacity(0.2 - (0.06 * Double(swipeProgress))),
                        radius: 10 - (2 * swipeProgress),
                        x: 0,
                        y: 6 - (2 * swipeProgress)
                    )
                    .zIndex(1)
                    .onTapGesture {
                        NotificationCenter.default.post(name: NSNotification.Name("MinimizePlayer"), object: nil)
                    }

                if canNavigate {
                    adjacentArtworkView(artwork: nextArtwork, size: artworkSize)
                        .offset(x: dragOffset + pageDistance)
                        .scaleEffect(0.96 + (0.04 * max(0, -signedProgress)))
                        .opacity(Double(0.72 + (0.28 * max(0, -signedProgress))))
                        .shadow(color: .black.opacity(0.16), radius: 8, x: 0, y: 5)
                        .zIndex(0)
                }
            }
            .frame(width: geometry.size.width, height: artworkSize)
            .contentShape(Rectangle())
            .gesture(
                artworkDragGesture(
                    gestureWidth: gestureWidth,
                    pageDistance: pageDistance
                )
            )
        }
        .frame(height: min(360, UIScreen.main.bounds.width - 80))
        .clipped()
    }

    private func currentArtworkView(size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.1))
                .frame(width: size, height: size)

            if let artwork = currentArtwork {
                Image(uiImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: min(80, size * 0.2)))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func adjacentArtworkView(artwork: UIImage?, size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.1))
                .frame(width: size, height: size)

            if let artwork = artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: min(80, size * 0.2)))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func artworkDragGesture(gestureWidth: CGFloat, pageDistance: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard !isAnimating else { return }
                guard abs(value.translation.width) > abs(value.translation.height) else { return }

                let canNavigate = playerEngine.playbackQueue.count > 1
                let proposedOffset = canNavigate
                    ? value.translation.width
                    : value.translation.width * 0.16
                let limit = pageDistance
                var transaction = Transaction()
                transaction.isContinuous = true
                withTransaction(transaction) {
                    dragOffset = max(-limit, min(limit, proposedOffset))
                }
            }
            .onEnded { value in
                guard !isAnimating else { return }
                guard playerEngine.playbackQueue.count > 1 else {
                    resetArtworkDrag()
                    return
                }

                let translation = value.translation.width
                let projectedTranslation = value.predictedEndTranslation.width
                let distanceThreshold = gestureWidth * 0.22
                let projectionThreshold = gestureWidth * 0.34
                let shouldCommit = abs(translation) > distanceThreshold ||
                    abs(projectedTranslation) > projectionThreshold

                guard shouldCommit else {
                    resetArtworkDrag()
                    return
                }

                let directionValue = abs(projectedTranslation) > abs(translation)
                    ? projectedTranslation
                    : translation

                if directionValue > 0 {
                    completeArtworkSwipe(.previous, pageDistance: pageDistance)
                } else {
                    completeArtworkSwipe(.next, pageDistance: pageDistance)
                }
            }
    }

    private func resetArtworkDrag() {
        let animation: Animation = reduceMotion
            ? .easeOut(duration: 0.14)
            : .spring(response: 0.36, dampingFraction: 0.82)
        withAnimation(animation) {
            dragOffset = 0
        }
    }

    private func completeArtworkSwipe(_ direction: ArtworkSwipeDirection, pageDistance: CGFloat) {
        // "Previous" restarts the current track after three seconds. Keep the
        // artwork honest in that case instead of briefly showing another song.
        if direction == .previous && playerEngine.playbackTime > 3 {
            resetArtworkDrag()
            Task {
                await playerEngine.previousTrack()
            }
            return
        }

        isAnimating = true
        let oldTrackId = playerEngine.currentTrack?.stableId
        let outgoingArtwork = currentArtwork
        let incomingArtwork = direction == .next ? nextArtwork : previousArtwork
        // Exactly one page: the adjacent card lands at x == 0. Any overrun
        // here causes a visible jump when the buffers are normalized.
        let targetOffset = direction.offsetSign * pageDistance

        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        let commitAnimation: Animation = reduceMotion
            ? .easeOut(duration: 0.14)
            : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.24)
        withAnimation(commitAnimation) {
            dragOffset = targetOffset
        }

        Task { @MainActor in
            let animationDelay: UInt64 = reduceMotion ? 140_000_000 : 240_000_000
            try? await Task.sleep(nanoseconds: animationDelay)

            switch direction {
            case .previous:
                await playerEngine.previousTrack()
            case .next:
                await playerEngine.nextTrack()
            }

            guard playerEngine.currentTrack?.stableId != oldTrackId else {
                isAnimating = false
                resetArtworkDrag()
                return
            }

            // The incoming card is already centered. Replace the artwork
            // buffers and reset coordinates without animation, so there is no
            // jump or flash while the engine finishes changing tracks.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                currentArtwork = incomingArtwork
                switch direction {
                case .previous:
                    nextArtwork = outgoingArtwork
                case .next:
                    previousArtwork = outgoingArtwork
                }
                dragOffset = 0
            }

            if currentArtwork == nil {
                await loadCurrentArtwork()
            }

            isAnimating = false
            await loadNextArtwork()
            await loadPreviousArtwork()
        }
    }

    // MARK: - Title and Artist Section

    private func titleAndArtistSection(track: Track) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                titleButton(track: track)
                artistButton(track: track)
            }

            Spacer()

            HStack(spacing: UIScreen.main.scale < UIScreen.main.nativeScale ? 16 : 20) {
                likeButton
                addToPlaylistButton
            }
        }
        .padding(.horizontal, 8)
    }

    private func titleButton(track: Track) -> some View {
        Group {
            if let albumId = track.albumId,
               let album = try? DatabaseManager.shared.read({ db in
                   try Album.fetchOne(db, key: albumId)
               }) {
                Button(action: {
                    let userInfo = ["album": album, "allTracks": allTracks] as [String : Any]
                    NotificationCenter.default.post(name: NSNotification.Name("NavigateToAlbumFromPlayer"), object: nil, userInfo: userInfo)
                }) {
                    Text(track.title)
                        .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title3 : .title2)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .multilineTextAlignment(.leading)
                        .foregroundColor(.primary)
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                Text(track.title)
                    .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title3 : .title2)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    private func artistButton(track: Track) -> some View {
        Group {
            if let artistId = track.artistId,
               let artist = try? DatabaseManager.shared.read({ db in
                   try Artist.fetchOne(db, key: artistId)
               }) {
                Button(action: {
                    let userInfo = ["artist": artist, "allTracks": allTracks] as [String : Any]
                    NotificationCenter.default.post(name: NSNotification.Name("NavigateToArtistFromPlayer"), object: nil, userInfo: userInfo)
                }) {
                    Text((try? DatabaseManager.shared.getArtistDisplayName(forTrackStableId: track.stableId, fallbackArtistId: track.artistId)) ?? artist.name)
                        .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .caption : .subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    private var likeButton: some View {
        Button(action: {
            toggleFavorite()
        }) {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title3 : .title2)
                .foregroundColor(isFavorite ? .red : .primary)
        }
    }

    private var addToPlaylistButton: some View {
        Button(action: {
            showPlaylistDialog = true
        }) {
            Image(systemName: "plus.circle")
                .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title3 : .title2)
                .foregroundColor(.primary)
        }
    }

    // MARK: - Progress Bar Section

    private var progressBarSection: some View {
        PlayerProgressSection(
            duration: playerEngine.duration,
            accentColor: settings.backgroundColorChoice.color,
            onSeek: { newTime in
                Task {
                    await playerEngine.seek(to: newTime)
                }
            }
        )
    }

    // MARK: - Controls Section

    private var controlsSection: some View {
        VStack(spacing: UIScreen.main.scale < UIScreen.main.nativeScale ? 20 : 25) {
            playbackControlsView
            additionalControlsView
        }
    }

    private var playbackControlsView: some View {
        HStack(spacing: min(35, UIScreen.main.bounds.width * 0.08)) {
            shuffleButton
            previousButton
            playPauseButton
            nextButton
            loopButton
        }
        .padding(.horizontal, min(21, UIScreen.main.bounds.width * 0.055))
        .padding(.vertical, 21)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 25))
        .overlay(
            RoundedRectangle(cornerRadius: 25)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
    }

    private var shuffleButton: some View {
        Button(action: {
            playerEngine.toggleShuffle()
        }) {
            Image(systemName: playerEngine.isShuffled ? "shuffle.circle.fill" : "shuffle.circle")
                .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title2 : .title)
                .foregroundColor(playerEngine.isShuffled ? .accentColor : .primary)
        }
    }

    private var previousButton: some View {
        Button(action: {
            Task {
                await playerEngine.previousTrack()
            }
        }) {
            Image(systemName: "backward.fill")
                .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title2 : .title)
        }
    }

    private var playPauseButton: some View {
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
    }

    private var nextButton: some View {
        Button(action: {
            Task {
                await playerEngine.nextTrack()
            }
        }) {
            Image(systemName: "forward.fill")
                .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title2 : .title)
        }
    }

    private var loopButton: some View {
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

    private var additionalControlsView: some View {
        HStack(spacing: 12) {
            queueButton
            middleControlButton
            airPlayButton
        }
        .padding(.horizontal, 5)
    }

    @ViewBuilder
    private var middleControlButton: some View {
        if settings.showSleepTimerButton {
            sleepTimerButton
        } else if settings.showLyricsButton {
            lyricsButton
        }
    }

    private var queueButton: some View {
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
    }

    private var airPlayButton: some View {
        Button(action: {
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

    private var emptyStateView: some View {
        VStack {
            Image(systemName: "music.note")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text(Localized.noTrackSelected)
                .font(.headline)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Helper Functions

    private var lyricsButton: some View {
        Button(action: {
            showLyricsSheet = true
            if currentLyrics == nil && !isLoadingLyrics {
                loadLyrics()
            }
        }) {
            ZStack {
                Image(systemName: "quote.bubble")
                    .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title2 : .title)
                    .foregroundColor(.primary)

                if isLoadingLyrics {
                    ProgressView()
                        .scaleEffect(0.7)
                        .offset(x: 15, y: -10)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 30)
            .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
    }

    private var sleepTimerButton: some View {
        Menu {
            Button(Localized.sleepTimer15Minutes) {
                startSleepTimer(minutes: 15)
            }
            Button(Localized.sleepTimer30Minutes) {
                startSleepTimer(minutes: 30)
            }
            Button(Localized.sleepTimer45Minutes) {
                startSleepTimer(minutes: 45)
            }
            Button(Localized.sleepTimer60Minutes) {
                startSleepTimer(minutes: 60)
            }

            if sleepTimerEndDate != nil {
                Divider()

                Button(Localized.cancelSleepTimer, role: .destructive) {
                    cancelSleepTimer()
                }
            }
        } label: {
            Image(systemName: sleepTimerEndDate == nil ? "timer" : "timer.circle.fill")
                .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title2 : .title)
                .foregroundColor(sleepTimerEndDate == nil ? .primary : settings.backgroundColorChoice.color)
                .frame(maxWidth: .infinity, minHeight: 30)
                .padding(.vertical, 16)
        }
        .menuOrder(.fixed)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(Localized.sleepTimer)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
    }

    private func startSleepTimer(minutes: Int) {
        sleepTimerTask?.cancel()
        let endDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTimerEndDate = endDate

        sleepTimerTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(minutes * 60) * 1_000_000_000)

            guard !Task.isCancelled else { return }

            await MainActor.run {
                playerEngine.pause()
                sleepTimerEndDate = nil
                sleepTimerTask = nil
            }
        }
    }

    private func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerEndDate = nil
    }

    private func loadLyrics() {
        guard let currentTrack = playerEngine.currentTrack else { return }

        isLoadingLyrics = true

        Task {
            let lyrics = await LyricsManager.shared.getLyrics(for: currentTrack)

            await MainActor.run {
                currentLyrics = lyrics
                isLoadingLyrics = false
            }
        }
    }
    
    private func loadAllArtworks() async {
        await loadCurrentArtwork()
        await loadNextArtwork()
        await loadPreviousArtwork()
    }
    
    private func loadCurrentArtwork() async {
        guard let track = playerEngine.currentTrack else {
            currentArtwork = nil
            return
        }

        let trackId = track.stableId
        let artwork = await artworkManager.getArtwork(for: track)
        guard playerEngine.currentTrack?.stableId == trackId else { return }
        currentArtwork = artwork
    }
    
    private func loadNextArtwork() async {
        let currentTrackId = playerEngine.currentTrack?.stableId
        let nextTrack = getNextTrack()
        guard let track = nextTrack else {
            guard playerEngine.currentTrack?.stableId == currentTrackId else { return }
            nextArtwork = nil
            return
        }

        let nextTrackId = track.stableId
        let artwork = await artworkManager.getArtwork(for: track)
        guard playerEngine.currentTrack?.stableId == currentTrackId,
              getNextTrack()?.stableId == nextTrackId else { return }
        nextArtwork = artwork
    }
    
    private func loadPreviousArtwork() async {
        let currentTrackId = playerEngine.currentTrack?.stableId
        let prevTrack = getPreviousTrack()
        guard let track = prevTrack else {
            guard playerEngine.currentTrack?.stableId == currentTrackId else { return }
            previousArtwork = nil
            return
        }

        let previousTrackId = track.stableId
        let artwork = await artworkManager.getArtwork(for: track)
        guard playerEngine.currentTrack?.stableId == currentTrackId,
              getPreviousTrack()?.stableId == previousTrackId else { return }
        previousArtwork = artwork
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

/// Owns the fast-changing progress observation so the complete PlayerView
/// (artwork, sheets and controls) is not recomputed four times per second.
private struct PlayerProgressSection: View {
    @ObservedObject private var progress = PlayerEngine.shared.progress
    let duration: TimeInterval
    let accentColor: Color
    let onSeek: (TimeInterval) -> Void

    private var fraction: Double {
        guard duration > 0 else { return 0 }
        let value = progress.playbackTime / duration
        guard value.isFinite else { return 0 }
        return max(0, min(1, value))
    }

    var body: some View {
        VStack(spacing: UIScreen.main.scale < UIScreen.main.nativeScale ? 12 : 16) {
            InteractiveProgressBar(
                progress: fraction,
                onSeek: { onSeek($0 * duration) },
                accentColor: accentColor
            )
            .frame(height: 1)

            HStack {
                Text(formatTime(progress.playbackTime))
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Text(formatTime(duration))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 8)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let safeTime = time.isFinite ? max(0, time) : 0
        let minutes = Int(safeTime) / 60
        let seconds = Int(safeTime) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// Keeps lyric timing updates inside the presented lyrics content instead of
/// invalidating the player and any underlying list.
private struct LiveLyricsSheet: View {
    @ObservedObject private var progress = PlayerEngine.shared.progress
    let lyrics: Lyrics?
    let isLoading: Bool

    var body: some View {
        LyricsView(
            lyrics: lyrics,
            currentTime: progress.playbackTime,
            isLoading: isLoading
        )
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
                            
                            MiniPlayerProgressBar(
                                duration: playerEngine.duration,
                                accentColor: settings.backgroundColorChoice.color
                            )
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
                .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NavigateToAlbumFromPlayer"))) { _ in
                    // Minimize the player when album navigation is requested
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                        isExpanded = false
                        dragOffset = 0
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("MinimizePlayer"))) { _ in
                    // Minimize the player when artwork is tapped
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                        isExpanded = false
                        dragOffset = 0
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("BackgroundColorChanged"))) { _ in
                    settings = DeleteSettings.load()
                }
            }
        }
    }
}

/// A render-only progress leaf. Scaling a full-width rectangle changes only
/// its transform; it does not resize the safe-area inset or ask the underlying
/// Library List to perform a collection diff on every playback tick.
private struct MiniPlayerProgressBar: View {
    @ObservedObject private var progress = PlayerEngine.shared.progress
    let duration: TimeInterval
    let accentColor: Color

    private var fraction: CGFloat {
        guard duration > 0 else { return 0 }
        let value = progress.playbackTime / duration
        return CGFloat(max(0, min(1, value.isFinite ? value : 0)))
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color.secondary.opacity(0.2))

            Rectangle()
                .fill(accentColor)
                .scaleEffect(x: fraction, y: 1, anchor: .leading)
                .animation(.linear(duration: 0.25), value: fraction)
        }
        .frame(height: 2)
        .clipped()
    }
}


struct TrackRowView: View, @MainActor Equatable {
    // 1. Pass these in instead of observing PlayerEngine
    let track: Track
    let activeTrackId: String?
    let isAudioPlaying: Bool
    let artistName: String?
    
    let onTap: () -> Void
    let playlist: Playlist?
    let showDirectDeleteButton: Bool
    let onEnterBulkMode: (() -> Void)?
    
    @EnvironmentObject private var appCoordinator: AppCoordinator
    
    // Internal state only (does not trigger external redraws)
    @State private var isFavorite = false
    @State private var isPressed = false
    @State private var showPlaylistDialog = false
    @State private var artworkImage: UIImage?
    @State private var showDeleteConfirmation = false
    @State private var deleteSettings = DeleteSettings.load()
    
    // 2. Computed property is now based on passed params
    private var isCurrentlyPlaying: Bool {
        activeTrackId == track.stableId
    }
    
    // 3. Equatable Conformance: Prevents redraws when PlayerEngine updates time
    static func == (lhs: TrackRowView, rhs: TrackRowView) -> Bool {
        return lhs.track.stableId == rhs.track.stableId &&
        lhs.activeTrackId == rhs.activeTrackId &&
        lhs.isAudioPlaying == rhs.isAudioPlaying &&
        lhs.artistName == rhs.artistName &&
        lhs.playlist?.id == rhs.playlist?.id
    }

    private func resolvedArtistName() -> String? {
        if let artistName, !artistName.isEmpty {
            return artistName
        }

        return try? DatabaseManager.shared.getArtistDisplayName(
            forTrackStableId: track.stableId,
            fallbackArtistId: track.artistId
        )
    }
    
    var body: some View {
        HStack(spacing: 0) {
            // MARK: - Tappable Content Area
            HStack(spacing: 12) {
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
                    
                    if let resolvedArtistName = resolvedArtistName() {
                        Text(resolvedArtistName)
                            .font(.body)
                            .foregroundColor(isCurrentlyPlaying ? deleteSettings.backgroundColorChoice.color.opacity(0.8) : .secondary)
                            .lineLimit(1)
                    }
                }
                
                Spacer()
                
                // Equalizer uses passed params
                if isCurrentlyPlaying {
                    let eqKey = "\(isAudioPlaying && isCurrentlyPlaying)-\(activeTrackId ?? "")"
                    
                    EqualizerBarsExact(
                        color: deleteSettings.backgroundColorChoice.color,
                        isActive: isAudioPlaying && isCurrentlyPlaying,
                        isLarge: true,
                        trackId: activeTrackId
                    )
                    .id(eqKey)
                    .padding(.trailing, 8)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onTap()
            }
            
            // MARK: - Menu / Action Area
            if showDirectDeleteButton {
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
                    if let onEnterBulkMode = onEnterBulkMode {
                        Button(action: { onEnterBulkMode() }) {
                            Label(Localized.select, systemImage: "checkmark.circle")
                        }
                    }
                    
                    Button(action: {
                        do {
                            try appCoordinator.toggleFavorite(trackStableId: track.stableId)
                            isFavorite.toggle()
                        } catch { print("Failed to toggle favorite: \(error)") }
                    }) {
                        HStack {
                            Image(systemName: isFavorite ? "heart.slash" : "heart")
                            Text(isFavorite ? Localized.removeFromLikedSongs : Localized.addToLikedSongs)
                        }
                    }
                    
                    if let artistId = track.artistId,
                       let artist = try? DatabaseManager.shared.read({ db in try Artist.fetchOne(db, key: artistId) }),
                       let allArtistTracks = try? DatabaseManager.shared.getTracksByArtistId(artistId) {
                        NavigationLink(destination: ArtistDetailScreen(artist: artist, allTracks: allArtistTracks)) {
                            Label(Localized.showArtistPage, systemImage: "person.circle")
                        }
                    }
                    
                    Button(action: { showPlaylistDialog = true }) {
                        Label(Localized.addToPlaylistEllipsis, systemImage: "rectangle.stack.badge.plus")
                    }
                    
                    Button(action: { showDeleteConfirmation = true }) {
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
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(deleteSettings.backgroundColorChoice.color.opacity(0.12))
                .scaleEffect(isPressed ? 1.0 : 0.01)
                .opacity(isPressed ? 1.0 : 0.0)
        )
        .sheet(isPresented: $showPlaylistDialog) {
            PlaylistSelectionView(track: track)
                .accentColor(deleteSettings.backgroundColorChoice.color)
        }
        .alert(Localized.deleteFile, isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) { deleteFile() }
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
            artworkImage = await ArtworkManager.shared.getThumbnail(for: track)
        }
    }
    
    private func deleteFile() {
        Task {
            do {
                let settings = DeleteSettings.load()
                if settings.deleteFromLibraryOnly {
                    DeleteSettings.addExcludedTrack(track.stableId)
                } else {
                    do {
                        try FileManager.default.removeItem(at: URL(fileURLWithPath: track.path))
                    } catch {
                        print("⚠️ Could not remove file from disk: \(error.localizedDescription)")
                    }
                }

                try DatabaseManager.shared.deleteTrack(byStableId: track.stableId)
                NotificationCenter.default.post(name: NSNotification.Name("LibraryNeedsRefresh"), object: nil)
            } catch {
                print("❌ Failed to delete track: \(error)")
            }
        }
    }
    
    private func removeFromPlaylist() {
        guard let playlist = playlist, let playlistId = playlist.id else { return }
        Task {
            do {
                try appCoordinator.removeFromPlaylist(playlistId: playlistId, trackStableId: track.stableId)
                NotificationCenter.default.post(name: NSNotification.Name("LibraryNeedsRefresh"), object: nil)
            } catch { print("❌ Failed to remove from playlist: \(error)") }
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
