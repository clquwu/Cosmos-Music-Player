import SwiftUI
import AVKit
import CoreImage

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

/// What fills the player's second area: the lyrics or the queue. On a phone
/// it replaces the artwork; on a wide screen it sits beside it.
enum PlayerPanel: Hashable {
    case lyrics
    case queue
}

/// The full-screen player.
///
/// Opens from the mini player with a zoom and closes with a swipe down, like
/// Music. The background takes its colour from the artwork. Lyrics and the
/// queue open *inside* the player instead of as sheets stacked on top of it,
/// and on iPad or an unfolded foldable they sit beside the artwork.
///
/// The controls are where they always were: artwork, title, progress, the
/// five transport buttons, then lyrics/timer/output/queue along the bottom.
struct PlayerView: View {
    @StateObject private var playerEngine = PlayerEngine.shared
    @StateObject private var artworkManager = ArtworkManager.shared
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentArtwork: UIImage?
    @State private var nextArtwork: UIImage?
    @State private var previousArtwork: UIImage?
    @State private var dragOffset: CGFloat = 0
    @State private var isAnimating = false
    @State private var isFavorite = false
    @State private var showPlaylistDialog = false
    @State private var currentLyrics: Lyrics? = nil
    @State private var isLoadingLyrics = false
    @State private var settings = DeleteSettings.load()
    @ObservedObject private var sleepTimer = SleepTimer.shared
    @State private var artistName: String?
    /// The panel shown in place of the artwork on a narrow screen.
    @State private var compactPanel: PlayerPanel?
    /// The panel shown beside the artwork on a wide screen.
    @State private var widePanel: PlayerPanel = .lyrics
    @State private var isWideLayout = false
    @State private var palette = PlayerPalette.placeholder

    private var accent: Color { settings.backgroundColorChoice.color }

    @AppStorage(PlayerBackgroundStyle.storageKey) private var backgroundStyle: PlayerBackgroundStyle = .deviceDefault

    /// The progress bar and "on" buttons follow the backdrop: the theme
    /// colour where the theme is part of it, the cover's colour otherwise.
    private var controlAccent: Color {
        switch backgroundStyle {
        case .blend, .theme: return palette.accent
        case .blurredCover: return palette.artworkAccent
        }
    }

    private var lyricsEnabled: Bool { settings.showLyricsButton }

    private var visiblePanel: PlayerPanel? {
        isWideLayout ? (lyricsEnabled ? widePanel : .queue) : compactPanel
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 700 && geometry.size.width > geometry.size.height

            ZStack {
                PlayerBackdrop(palette: palette, artwork: currentArtwork)
                    .ignoresSafeArea()

                if let track = playerEngine.currentTrack {
                    if #available(iOS 27.1, *), isFolded(geometry), geometry.size.width >= 500 {
                        foldableLayout(track: track)
                    } else if wide {
                        wideLayout(track: track, size: geometry.size)
                    } else {
                        compactLayout(track: track, size: geometry.size)
                    }
                } else {
                    emptyStateView
                }
            }
            .onAppear { isWideLayout = wide }
            .onChange(of: wide) { _, newValue in
                isWideLayout = newValue
                loadLyricsIfVisible()
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        // Lyrics and Up Next take the player's colour, not the theme's.
        .environment(\.playerAccent, controlAccent)
        // Cap Dynamic Type so large accessibility sizes don't overflow the player layout
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .sheet(isPresented: $showPlaylistDialog) {
            playlistSheet
        }
        .onAppear {
            Task {
                await loadAllArtworks()
                checkFavoriteStatus()
                loadTrackDetails()
                loadLyricsIfVisible()
            }
        }
        .onChange(of: playerEngine.currentTrack) { _, _ in
            checkFavoriteStatus()
            loadTrackDetails()

            // Clear current lyrics, and fetch the new song's if they are on
            // screen.
            currentLyrics = nil
            isLoadingLyrics = false
            loadLyricsIfVisible()

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
        // Keyed on the image itself: the track id changes before the new
        // cover arrives, so keying on the track recoloured the player with
        // the previous song's artwork and never updated once the new one
        // landed.
        .task(id: currentArtwork.map(ObjectIdentifier.init)) {
            let newPalette = await PlayerPalette.make(from: currentArtwork, fallback: UIColor(accent))
            // The cover-based backgrounds fade to the next song's colours;
            // the Theme background changes at once.
            withAnimation(backgroundStyle == .theme ? nil : .easeInOut(duration: 0.9)) {
                palette = newPalette
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("BackgroundColorChanged"))) { _ in
            settings = DeleteSettings.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cosmosSettingsDidChange)) { _ in
            settings = DeleteSettings.load()
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("CosmosDebugPlayerPanel"))) { notification in
            let panel: PlayerPanel = (notification.object as? String) == "queue" ? .queue : .lyrics
            widePanel = panel
            setCompactPanel(panel)
        }
        #endif
    }

    // MARK: - Layouts

    private func compactLayout(track: Track, size: CGSize) -> some View {
        // On a tall, wide screen (iPad or iPhone Duo in portrait) the column
        // stays a comfortable width and the cover grows with the height,
        // instead of controls stretched edge to edge under a small cover.
        let columnWidth = min(size.width, 720)
        // The cover takes the height the rest does not need - about 430
        // points for the header, title, progress, controls and bottom row -
        // so a tall screen gets a big cover instead of an empty band above it.
        let artworkSize = max(160, min(columnWidth - 48, size.height - 430))
        // Where the height is what limits the cover - iPhone Duo upright,
        // 670 points wide - the title, progress and controls line up with
        // its edges instead of running 100 points past it on each side. A
        // phone's column (under 440 points) is left as it was.
        let controlsWidth = min(columnWidth, max(artworkSize + 48, 440))

        return VStack(spacing: 0) {
            header

            if let panel = compactPanel {
                // No title row above lyrics or Up Next: they get the room.
                // The cover, title and heart are back with the same button.

                panelContent(panel)
                    .frame(maxHeight: .infinity)
                    .transition(.opacity)
            } else {
                Spacer(minLength: Design.Spacing.s)
                artworkSection(size: artworkSize)
                    .transition(.opacity)
                Spacer(minLength: Design.Spacing.l)
                titleRow(track: track)
                    .padding(.horizontal, Design.Spacing.xl)
                    .padding(.bottom, Design.Spacing.l)
            }

            controls
                .padding(.horizontal, Design.Spacing.xl)

            bottomRow
                .padding(.horizontal, Design.Spacing.xl)
                .padding(.top, Design.Spacing.m)
                .padding(.bottom, Design.Spacing.s)
        }
        .frame(maxWidth: controlsWidth)
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: compactPanel)
    }

    /// iPhone Duo's inner screen while it is actually folded - propped up
    /// or held like a book: the fold's division region is active. Open flat,
    /// the split wasted half the screen, so the usual layouts take over.
    @available(iOS 27.1, *)
    private func isFolded(_ geometry: GeometryProxy) -> Bool {
        geometry.reservedRegions(kind: .division).contains { $0.isActive }
    }

    /// iPhone Duo's inner display. The player is two halves the system
    /// arranges around the fold: the stage - the cover, or lyrics and Up
    /// Next - and the deck - title, progress and controls. Propped up like a
    /// laptop, the stage sits on the top half to be watched from a distance
    /// and the controls on the bottom half, the steady part to touch; held
    /// like a book or open flat, they sit side by side. Nothing straddles
    /// the fold.
    @available(iOS 27.1, *)
    private func foldableLayout(track: Track) -> some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Design.Spacing.l)

            ArrangementView {
                FoldStage { size in
                    VStack(spacing: Design.Spacing.s) {
                        if let panel = compactPanel {
                            panelContent(panel)
                                .frame(maxHeight: .infinity)
                                // Propped up, the stage runs the full width
                                // of the screen; the lyrics menu sat on its
                                // very edge.
                                .padding(.horizontal, Design.Spacing.l)
                        } else {
                            Spacer(minLength: 0)
                            artworkSection(size: max(160, min(size.width - 64, size.height - 48)))
                            Spacer(minLength: 0)
                        }
                    }
                    .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: compactPanel)
                }
            } secondary: {
                FoldDeck {
                    titleRow(track: track)
                        .padding(.bottom, Design.Spacing.l)
                    controls
                    bottomRow
                        .padding(.top, Design.Spacing.m)
                        .padding(.bottom, Design.Spacing.s)
                }
                .padding(.horizontal, Design.Spacing.xxl)
            }
            .arrangementViewStyle(.split)
        }
    }

    private func wideLayout(track: Track, size: CGSize) -> some View {
        let columnWidth = min(460, size.width * 0.42)
        let artworkSize = max(200, min(columnWidth, size.height * 0.48))

        return HStack(alignment: .top, spacing: Design.Spacing.xxl + 16) {
            VStack(spacing: 0) {
                header
                Spacer(minLength: Design.Spacing.s)
                artworkSection(size: artworkSize)
                Spacer(minLength: Design.Spacing.l)
                titleRow(track: track)
                    .padding(.bottom, Design.Spacing.l)
                controls
                bottomRow
                    .padding(.top, Design.Spacing.m)
                    .padding(.bottom, Design.Spacing.s)
            }
            .frame(width: columnWidth)

            VStack(alignment: .leading, spacing: Design.Spacing.m) {
                if lyricsEnabled {
                    Picker(Localized.lyrics, selection: Binding(
                        get: { widePanel },
                        set: { newValue in
                            widePanel = newValue
                            loadLyricsIfVisible()
                        }
                    )) {
                        Text(Localized.lyrics).tag(PlayerPanel.lyrics)
                        Text(Localized.upNext).tag(PlayerPanel.queue)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)
                    .padding(.top, Design.Spacing.l)
                } else {
                    Text(Localized.upNext)
                        .font(.title2.weight(.bold))
                        .padding(.top, Design.Spacing.l)
                        .accessibilityAddTraits(.isHeader)
                }

                panelContent(lyricsEnabled ? widePanel : .queue)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, Design.Spacing.xxl + 8)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.body.weight(.semibold))
                    .frame(width: Design.Size.minTouch, height: Design.Size.minTouch)
                    .background(.white.opacity(0.14), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Localized.closePlayer)

            Spacer()

            // The grab handle: the player closes with a swipe down.
            Capsule()
                .fill(.white.opacity(0.35))
                .frame(width: 40, height: 5)
                .accessibilityHidden(true)

            Spacer()

            Color.clear
                .frame(width: Design.Size.minTouch, height: Design.Size.minTouch)
        }
        .padding(.horizontal, isWideLayout ? 0 : Design.Spacing.l)
        .padding(.top, Design.Spacing.s)
    }

    // MARK: - Title row

    private func titleRow(track: Track) -> some View {
        HStack(alignment: .center, spacing: Design.Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    AppRouter.shared.openAlbum(of: track)
                } label: {
                    Text(track.title)
                        .font(.title2.weight(.bold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .disabled(track.albumId == nil)
                .accessibilityHint(track.albumId == nil ? "" : Localized.showAlbum)

                if let artistName, !artistName.isEmpty {
                    Button {
                        AppRouter.shared.openArtist(of: track)
                    } label: {
                        Text(artistName)
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .disabled(track.artistId == nil)
                    .accessibilityHint(track.artistId == nil ? "" : Localized.showArtistPage)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            likeButton
            moreMenu(track: track)
        }
    }

    /// The small artwork-and-title header that replaces the big artwork
    /// while lyrics or the queue are open on a phone. Tapping it goes back.
    private var likeButton: some View {
        Button {
            toggleFavorite()
        } label: {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .font(.body.weight(.semibold))
                .foregroundStyle(isFavorite ? Color.red : Color.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: Design.Size.minTouch, height: Design.Size.minTouch)
                .background(.white.opacity(0.14), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFavorite ? Localized.removeFromLikedSongs : Localized.addToLikedSongs)
    }

    private func moreMenu(track: Track) -> some View {
        Menu {
            // A mix grown from the song playing now; it replaces the queue,
            // starting from this song.
            Button {
                Task { await MixStore.shared.playSongMix(from: track) }
            } label: {
                Label(Localized.songMix, systemImage: "dot.radiowaves.left.and.right")
            }

            Button {
                showPlaylistDialog = true
            } label: {
                Label(Localized.addToPlaylistEllipsis, systemImage: "text.badge.plus")
            }

            if track.albumId != nil {
                Button {
                    AppRouter.shared.openAlbum(of: track)
                } label: {
                    Label(Localized.showAlbum, systemImage: "square.stack")
                }
            }

            if track.artistId != nil {
                Button {
                    AppRouter.shared.openArtist(of: track)
                } label: {
                    Label(Localized.showArtistPage, systemImage: "music.microphone")
                }
            }

            Divider()

            Menu {
                sleepTimerItems
            } label: {
                Label(Localized.sleepTimer, systemImage: sleepTimer.isActive ? "moon.zzz.fill" : "moon.zzz")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .frame(width: Design.Size.minTouch, height: Design.Size.minTouch)
                .background(.white.opacity(0.14), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Localized.moreOptions)
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: Design.Spacing.l) {
            PlayerProgressSection(
                duration: playerEngine.duration,
                formatDescription: formatDescription,
                accentColor: controlAccent,
                onSeek: { newTime in
                    await playerEngine.seek(to: newTime)
                }
            )

            HStack(spacing: 0) {
                toggleButton(
                    systemImage: "shuffle",
                    isOn: playerEngine.isShuffled,
                    label: Localized.shuffle
                ) {
                    playerEngine.toggleShuffle()
                }

                Spacer(minLength: 0)

                transportButton(systemImage: "backward.fill", size: 34, label: Localized.previousTrack) {
                    Task { await playerEngine.previousTrack() }
                }

                Spacer(minLength: 0)

                transportButton(
                    systemImage: playerEngine.isPlaying ? "pause.fill" : "play.fill",
                    size: 46,
                    label: playerEngine.isPlaying ? Localized.pause : Localized.play
                ) {
                    if playerEngine.isPlaying {
                        playerEngine.pause()
                    } else {
                        playerEngine.play()
                    }
                }

                Spacer(minLength: 0)

                transportButton(systemImage: "forward.fill", size: 34, label: Localized.nextTrack) {
                    Task { await playerEngine.nextTrack() }
                }

                Spacer(minLength: 0)

                toggleButton(
                    systemImage: playerEngine.isLoopingSong ? "repeat.1" : "repeat",
                    isOn: playerEngine.isLoopingSong || playerEngine.isRepeating,
                    label: Localized.repeatMode
                ) {
                    playerEngine.cycleLoopMode()
                }
            }

        }
    }

    private func transportButton(systemImage: String, size: CGFloat, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: max(size + 22, 60), height: max(size + 22, 60))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
    }

    /// Shuffle and repeat. Both now show "on" the same way - a filled disc
    /// behind the symbol - where shuffle used the system accent and repeat
    /// the theme colour.
    private func toggleButton(systemImage: String, isOn: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(isOn ? Color.black : Color.white.opacity(0.7))
                .frame(width: Design.Size.minTouch, height: Design.Size.minTouch)
                .background(isOn ? controlAccent : Color.clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? Localized.on : Localized.off)
    }

    // MARK: - Bottom row

    private var bottomRow: some View {
        HStack(spacing: 0) {
            if lyricsEnabled {
                panelButton(.lyrics, systemImage: "quote.bubble", label: Localized.lyrics)
            }

            if settings.showSleepTimerButton {
                Menu {
                    sleepTimerItems
                } label: {
                    bottomRowIcon(
                        systemImage: sleepTimer.isActive ? "moon.zzz.fill" : "moon.zzz",
                        isSelected: sleepTimer.isActive
                    )
                }
                .menuOrder(.fixed)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(Localized.sleepTimer)
            }

            RoutePickerButton()
                .frame(width: Design.Size.minTouch, height: Design.Size.minTouch)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(Localized.audioOutput)

            panelButton(.queue, systemImage: "list.bullet", label: Localized.upNext)
        }
    }

    private func panelButton(_ panel: PlayerPanel, systemImage: String, label: String) -> some View {
        let isSelected = visiblePanel == panel
        return Button {
            if isWideLayout {
                widePanel = panel
                loadLyricsIfVisible()
            } else {
                setCompactPanel(compactPanel == panel ? nil : panel)
            }
        } label: {
            bottomRowIcon(systemImage: systemImage, isSelected: isSelected)
                .overlay(alignment: .topTrailing) {
                    if panel == .lyrics && isLoadingLyrics {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.white)
                    }
                }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func bottomRowIcon(systemImage: String, isSelected: Bool) -> some View {
        Image(systemName: systemImage)
            .font(.title3)
            .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.85))
            .frame(width: Design.Size.minTouch, height: Design.Size.minTouch)
            .background(isSelected ? controlAccent : Color.clear, in: Circle())
            .contentShape(Circle())
    }

    /// The timer durations, as menu items. The bottom-row button lists them
    /// directly; the "…" menu nests them under "Sleep Timer".
    @ViewBuilder
    private var sleepTimerItems: some View {
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

            if sleepTimer.isActive {
                Divider()

                Button(Localized.cancelSleepTimer, role: .destructive) {
                    cancelSleepTimer()
                }
            }
    }

    // MARK: - Panels

    private func panelContent(_ panel: PlayerPanel) -> some View {
        Group {
            switch panel {
            case .lyrics:
                LiveLyricsPanel(
                    lyrics: currentLyrics,
                    isLoading: isLoadingLyrics,
                    trackTitle: playerEngine.currentTrack?.title,
                    trackArtist: artistName,
                    onRetry: { loadLyrics(forceRefresh: true) },
                    track: playerEngine.currentTrack,
                    onSelectAlternative: { id in applyLyricsAlternative(id) }
                )
            case .queue:
                QueueManagementView(isEmbedded: true)
            }
        }
        // On a very light cover the white lyrics and Up Next fell to about
        // 3:1. A shade behind them, only as dark as this backdrop needs for
        // their secondary text to reach 4.5:1, keeps them readable while the backdrop itself - and every
        // darker cover, which gets no shade - looks as chosen.
        .background {
            PanelScrim(opacity: palette.textScrim(for: backgroundStyle, hasArtwork: currentArtwork != nil))
        }
    }

    private func setCompactPanel(_ panel: PlayerPanel?) {
        compactPanel = panel
        loadLyricsIfVisible()
    }

    private var playlistSheet: some View {
        Group {
            if let currentTrack = playerEngine.currentTrack {
                PlaylistSelectionView(track: currentTrack)
                    .accentColor(accent)
            }
        }
    }

    /// "FLAC · 24-bit / 96 kHz", from the file and its stored properties.
    private var formatDescription: String? {
        guard let track = playerEngine.currentTrack else { return nil }
        var parts: [String] = []
        let ext = URL(fileURLWithPath: track.path).pathExtension.uppercased()
        if !ext.isEmpty { parts.append(ext) }
        var quality: [String] = []
        if let bitDepth = track.bitDepth, bitDepth > 0 { quality.append("\(bitDepth)-bit") }
        if let sampleRate = track.sampleRate, sampleRate > 0 {
            let khz = Double(sampleRate) / 1000
            quality.append(khz.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(khz)) kHz" : String(format: "%.1f kHz", khz))
        }
        if !quality.isEmpty { parts.append(quality.joined(separator: " / ")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Artwork Section

    private func artworkSection(size artworkSize: CGFloat) -> some View {
        GeometryReader { geometry in
            let gestureWidth = max(geometry.size.width, 1)
            let pageDistance = artworkSize + 18
            let swipeProgress = min(abs(dragOffset) / pageDistance, 1)
            let signedProgress = max(-1, min(1, dragOffset / pageDistance))
            let canNavigate = playerEngine.playbackQueue.count > 1
            // The neighbours appear only while the cover is being dragged;
            // at rest their edges peeked in from the sides of the screen.
            let neighbourVisibility = min(swipeProgress * 4, 1)

            ZStack {
                if canNavigate {
                    adjacentArtworkView(artwork: previousArtwork, size: artworkSize)
                        .offset(x: dragOffset - pageDistance)
                        .scaleEffect(0.96 + (0.04 * max(0, signedProgress)))
                        .opacity(Double(0.72 + (0.28 * max(0, signedProgress))) * neighbourVisibility)
                        .zIndex(0)
                }

                currentArtworkView(size: artworkSize)
                    .offset(x: dragOffset)
                    // The same size playing or paused: the cover used to
                    // shrink on pause, which read as the layout jumping.
                    .scaleEffect(1 - (0.025 * swipeProgress))
                    .shadow(
                        color: .black.opacity(0.35 - (0.1 * Double(swipeProgress))),
                        radius: 24 - (4 * swipeProgress),
                        x: 0,
                        y: 14 - (4 * swipeProgress)
                    )
                    .zIndex(1)

                if canNavigate {
                    adjacentArtworkView(artwork: nextArtwork, size: artworkSize)
                        .offset(x: dragOffset + pageDistance)
                        .scaleEffect(0.96 + (0.04 * max(0, -signedProgress)))
                        .opacity(Double(0.72 + (0.28 * max(0, -signedProgress))) * neighbourVisibility)
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
        .frame(height: artworkSize)
        // Clipped sideways only, to hide the neighbouring covers; clipping
        // all round cut the cover's shadow off in a hard band below it.
        .mask(Rectangle().padding(.vertical, -80))
        .accessibilityElement()
        .accessibilityLabel(Localized.artwork)
        .accessibilityHint(playerEngine.playbackQueue.count > 1 ? Localized.nextTrack : "")
        .accessibilityAction(named: Localized.nextTrack) {
            Task { await playerEngine.nextTrack() }
        }
        .accessibilityAction(named: Localized.previousTrack) {
            Task { await playerEngine.previousTrack() }
        }
    }

    private func currentArtworkView(size: CGFloat) -> some View {
        ArtworkView(image: currentArtwork, cornerRadius: Design.Radius.hero)
            .frame(width: size, height: size)
    }

    private func adjacentArtworkView(artwork: UIImage?, size: CGFloat) -> some View {
        ArtworkView(image: artwork, cornerRadius: Design.Radius.hero)
            .frame(width: size, height: size)
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

    private var emptyStateView: some View {
        VStack(spacing: Design.Spacing.l) {
            header
            Spacer()
            CosmosEmptyState(systemImage: "music.note", title: Localized.noTrackSelected)
            Spacer()
        }
    }

    // MARK: - Helper Functions

    private func startSleepTimer(minutes: Int) {
        sleepTimer.start(minutes: minutes)
    }

    private func cancelSleepTimer() {
        sleepTimer.cancel()
    }

    private func loadTrackDetails() {
        guard let track = playerEngine.currentTrack else {
            artistName = nil
            return
        }
        artistName = try? DatabaseManager.shared.getArtistDisplayName(
            forTrackStableId: track.stableId,
            fallbackArtistId: track.artistId
        )
    }

    /// Fetches lyrics only while they are on screen, as the sheet did.
    private func loadLyricsIfVisible() {
        guard visiblePanel == .lyrics, currentLyrics == nil, !isLoadingLyrics else { return }
        loadLyrics()
    }

    /// Adopts a specific lrclib record the user picked over the automatic match.
    private func applyLyricsAlternative(_ id: Int) {
        guard let currentTrack = playerEngine.currentTrack else { return }

        isLoadingLyrics = true
        Task {
            let lyrics = await LyricsManager.shared.useAlternative(id, for: currentTrack)
            await MainActor.run {
                if let lyrics { currentLyrics = lyrics }
                isLoadingLyrics = false
            }
        }
    }

    /// - Parameter forceRefresh: ignore a remembered "lrclib has nothing for
    ///   this song" and ask again. Backs the retry on the not-found card.
    private func loadLyrics(forceRefresh: Bool = false) {
        guard let currentTrack = playerEngine.currentTrack else { return }

        isLoadingLyrics = true
        if forceRefresh { currentLyrics = nil }

        Task {
            let lyrics = forceRefresh
                ? await LyricsManager.shared.refreshLyrics(for: currentTrack)
                : await LyricsManager.shared.getLyrics(for: currentTrack)

            await MainActor.run {
                // Dropped if the song changed while this was in flight.
                guard playerEngine.currentTrack?.stableId == currentTrack.stableId else { return }
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
}

/// The sleep timer, kept outside the player so it survives the player being
/// closed: it used to live in the player's own state, so after closing and
/// reopening it showed as off - still running, but impossible to cancel.
@MainActor
final class SleepTimer: ObservableObject {
    static let shared = SleepTimer()

    @Published private(set) var endDate: Date?
    private var task: Task<Void, Never>?

    private init() {}

    var isActive: Bool { endDate != nil }

    func start(minutes: Int) {
        task?.cancel()
        endDate = Date().addingTimeInterval(TimeInterval(minutes * 60))

        task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(minutes * 60) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            PlayerEngine.shared.pause()
            self?.endDate = nil
            self?.task = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        endDate = nil
    }
}

// MARK: - Artwork-tinted background

/// Two colours taken from the artwork - its top half and its bottom half -
/// darkened enough that white text on them always stays readable (at least
/// 4.5:1 against the lighter one).
/// The stage half of the folding player: hands its size to the content, so
/// the cover fills whichever half it gets.
private struct FoldStage<Content: View>: View {
    @ViewBuilder let content: (CGSize) -> Content

    var body: some View {
        GeometryReader { geometry in
            content(geometry.size)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

/// The controls half of the folding player. Stacked under the stage (the
/// laptop pose) it keeps the controls at the top of the half, close to the
/// fold and the thumbs; beside the stage it centres them vertically.
@available(iOS 27.1, *)
private struct FoldDeck<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.splitArrangementAxis) private var axis

    var body: some View {
        VStack(spacing: 0) {
            if axis != .vertical { Spacer(minLength: 0) }
            content()
                .frame(maxWidth: 560)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

struct PlayerPalette: Equatable {
    var top: Color
    var bottom: Color
    /// A lighter version of the artwork's colour for the player's halo.
    var glow: Color
    /// The theme colour, lifted to read on the dark backdrop: the second
    /// halo, the progress bar and the "on" buttons.
    var accent: Color = .white
    /// The cover's own colour for the controls, or white when the cover has
    /// no colour strong enough to carry them.
    var artworkAccent: Color = .white
    /// The bottom for the Artwork + Theme backdrop: mostly the theme colour.
    var blendBottom: Color = Color(white: 0.08)
    /// The Theme backdrop: the theme colour alone, light to deep.
    var themeTop: Color = Color(white: 0.22)
    var themeBottom: Color = Color(white: 0.08)
    /// Artwork + Theme: the cover's colour kept vivid, and the theme's, for
    /// the two ends of the blend.
    var vividArtwork: Color = Color(white: 0.3)
    var vividTheme: Color = Color(white: 0.2)
    /// How dark a shade the lyrics and Up Next need behind them on each
    /// backdrop (see `textScrim(for:hasArtwork:)`): zero unless the cover is
    /// light enough to wash out their white text.
    var blendScrim: Double = 0
    var themeScrim: Double = 0
    var coverScrim: Double = 0

    static let placeholder = PlayerPalette(top: Color(white: 0.22), bottom: Color(white: 0.08), glow: Color(white: 0.6))

    /// The shade for the backdrop on screen. Blurred Cover without a cover
    /// falls back to the dark gradient, which needs none.
    func textScrim(for style: PlayerBackgroundStyle, hasArtwork: Bool) -> Double {
        switch style {
        case .blend: return blendScrim
        case .theme: return themeScrim
        case .blurredCover: return hasArtwork ? coverScrim : 0
        }
    }

    /// How opaque the lyrics' and Up Next's secondary white text is (artist
    /// names, captions, status lines). The shade behind the panels is worked
    /// out for this text, not just for the full-white lines: aimed at white
    /// alone it left the secondary text at about 2.7:1 on a very light cover.
    static let secondaryTextOpacity = 0.7

    /// The black shade, as an opacity, that brings `color` dark enough for
    /// the panels' secondary text - white at `secondaryTextOpacity` - to read
    /// at 4.5:1, WCAG's minimum for body text, and zero when it already does.
    /// Full-white text then reads at about 6:1 or better. Very light covers
    /// measured about 1.5 to 3:1 under the lyrics and Up Next.
    static func scrimOpacity(under color: UIColor) -> Double {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return 0 }
        var opacity = 0.0
        // Black at this opacity scales each channel by (1 - opacity), as the
        // screen composites it. A white cover needs about 0.66.
        while opacity < 0.76, secondaryTextContrast(red, green, blue, scale: 1 - opacity) < 4.5 {
            opacity += 0.02
        }
        return opacity
    }

    /// Contrast of white text at `secondaryTextOpacity` over this colour, its
    /// channels scaled first: the text's own colour is the white blended
    /// over the backdrop, as the screen composites it.
    private static func secondaryTextContrast(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, scale: Double) -> Double {
        let text = secondaryTextOpacity
        let channels = [red, green, blue].map { min(max(Double($0) * scale, 0), 1) }
        let backdrop = relativeLuminance(channels)
        let ink = relativeLuminance(channels.map { text + (1 - text) * $0 })
        return (ink + 0.05) / (backdrop + 0.05)
    }

    /// WCAG relative luminance of sRGB channels in 0...1.
    private static func relativeLuminance(_ channels: [Double]) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(channels[0]) + 0.7152 * linear(channels[1]) + 0.0722 * linear(channels[2])
    }

    private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    static func make(from image: UIImage?, fallback: UIColor) async -> PlayerPalette {
        let colors: (UIColor, UIColor)? = await Task.detached(priority: .userInitiated) {
            guard let image, let cgImage = image.cgImage else { return nil }
            let ciImage = CIImage(cgImage: cgImage)
            let extent = ciImage.extent
            guard extent.width > 0, extent.height > 0 else { return nil }
            // Core Image's origin is bottom-left.
            let topHalf = CGRect(x: extent.minX, y: extent.midY, width: extent.width, height: extent.height / 2)
            let bottomHalf = CGRect(x: extent.minX, y: extent.minY, width: extent.width, height: extent.height / 2)
            guard let top = averageColor(of: ciImage, in: topHalf),
                  let bottom = averageColor(of: ciImage, in: bottomHalf) else { return nil }
            return (top, bottom)
        }.value

        let (top, bottom) = colors ?? (fallback, fallback)
        let vividArtwork = tuned(top, brightness: 0.6...0.85, saturationCap: 1)
        let vividTheme = tuned(fallback, brightness: 0.32...0.45, saturationCap: 0.85)
        let themeTop = tuned(fallback, brightness: 0.32...0.4)
        // The shades are worked out on each backdrop's lightest colour: the
        // blend's top band of cover colour; the blurred cover's average
        // under the darkening gradient over it (0.2 black at the top, 0.55 at
        // the bottom).
        let coverScrim = colors.map {
            max(scrimOpacity(under: blend($0.0, .black, amount: 0.2)), scrimOpacity(under: blend($0.1, .black, amount: 0.55)))
        } ?? 0
        // The Artwork and Blurred Cover backdrops are the cover's colours
        // alone; the theme comes in only through the Blend and Theme styles.
        return PlayerPalette(
            top: Color(tuned(top, brightness: 0.30...0.42)),
            bottom: Color(tuned(bottom, brightness: 0.10...0.18)),
            glow: Color(tuned(top, brightness: 0.75...0.9)),
            accent: Color(lifted(fallback)),
            artworkAccent: colors.map { Color(artworkAccent(from: [$0.0, $0.1])) } ?? .white,
            blendBottom: Color(tuned(blend(bottom, fallback, amount: 0.6), brightness: 0.12...0.2)),
            themeTop: Color(themeTop),
            themeBottom: Color(tuned(fallback, brightness: 0.08...0.12)),
            // The cover's own brightness, only kept from going so pale that
            // white text would vanish.
            vividArtwork: Color(vividArtwork),
            vividTheme: Color(vividTheme),
            blendScrim: max(scrimOpacity(under: vividArtwork), scrimOpacity(under: vividTheme)),
            themeScrim: scrimOpacity(under: themeTop),
            coverScrim: coverScrim
        )
    }

    /// The two colours in equal parts.
    static func mix(_ a: UIColor, _ b: UIColor) -> UIColor {
        blend(a, b, amount: 0.5)
    }

    static func blend(_ a: UIColor, _ b: UIColor, amount: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * amount, green: g1 + (g2 - g1) * amount, blue: b1 + (b2 - b1) * amount, alpha: 1)
    }

    /// The most colourful of the cover's colours, lifted to read on the dark
    /// backdrop - or white when the cover is nearly grey.
    static func artworkAccent(from colors: [UIColor]) -> UIColor {
        var best: (color: UIColor, saturation: CGFloat)?
        for color in colors {
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
            guard color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else { continue }
            if saturation > (best?.saturation ?? 0) { best = (color, saturation) }
        }
        guard let best, best.saturation >= 0.28 else { return .white }
        return lifted(best.color)
    }

    /// The theme colour, bright enough to stand out on the dark backdrop.
    private static func lifted(_ color: UIColor) -> UIColor {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        guard color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else { return .white }
        return UIColor(hue: hue, saturation: min(saturation, 0.75), brightness: max(brightness, 0.9), alpha: 1)
    }

    private static func averageColor(of image: CIImage, in rect: CGRect) -> UIColor? {
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: image,
            kCIInputExtentKey: CIVector(cgRect: rect)
        ]), let output = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )
        return UIColor(
            red: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: 1
        )
    }

    /// Keeps the hue, tames the saturation and pins the brightness to a range
    /// that white text reads well on.
    private static func tuned(_ color: UIColor, brightness range: ClosedRange<CGFloat>, saturationCap: CGFloat = 0.7) -> UIColor {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        guard color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
            return UIColor(white: range.upperBound, alpha: 1)
        }
        let adjustedBrightness = min(max(brightness, range.lowerBound), range.upperBound)
        return UIColor(hue: hue, saturation: min(saturation * 1.1, saturationCap), brightness: adjustedBrightness, alpha: 1)
    }
}

/// The shade behind the player's lyrics and Up Next. Reaching past the
/// panel and blurred, so it reads as the backdrop dimming under the text
/// rather than as a card; at full strength wherever the text runs.
private struct PanelScrim: View {
    let opacity: Double

    var body: some View {
        RoundedRectangle(cornerRadius: Design.Radius.hero * 2, style: .continuous)
            .fill(Color.black.opacity(opacity))
            .padding(-Design.Spacing.xl)
            .blur(radius: Design.Spacing.m)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// How the full-screen player is lit, chosen in Settings.
enum PlayerBackgroundStyle: String, CaseIterable, Identifiable {
    /// The cover's colour above, the theme colour below.
    case blend
    /// The theme colour alone.
    case theme
    /// The cover itself, blurred into a backdrop.
    case blurredCover

    static let storageKey = "cosmos.playerBackground"

    /// Until the listener picks one: the blurred cover on a phone, where the
    /// cover fills the screen behind the controls; the cover's colours with
    /// the theme on iPad, where a blurred cover stretched that large looks
    /// smeared.
    /// Reads a stored choice; "artwork", a style since removed, becomes the
    /// blurred cover, its closest replacement.
    init?(rawValue: String) {
        switch rawValue {
        case "blend": self = .blend
        case "theme": self = .theme
        case "blurredCover", "artwork": self = .blurredCover
        default: return nil
        }
    }

    static var deviceDefault: PlayerBackgroundStyle {
        UIDevice.current.userInterfaceIdiom == .pad ? .blend : .blurredCover
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blend: return Localized.playerBackgroundBlend
        case .theme: return Localized.playerBackgroundTheme
        case .blurredCover: return Localized.playerBackgroundBlurredCover
        }
    }
}

private struct PlayerBackdrop: View {
    let palette: PlayerPalette
    let artwork: UIImage?
    @AppStorage(PlayerBackgroundStyle.storageKey) private var style: PlayerBackgroundStyle = .deviceDefault

    var body: some View {
        switch style {
        case .blurredCover where artwork != nil:
            blurredCover
        case .blend:
            blend
        case .theme:
            backdrop(top: palette.themeTop, bottom: palette.themeBottom, glow: palette.accent, accentStrength: 0.5, accentLine: HaloLine(start: UnitPoint(x: 0, y: 1.0), end: UnitPoint(x: 1, y: 0.55)))
        default:
            backdrop(top: palette.top, bottom: palette.bottom, secondColor: palette.artworkAccent, accentStrength: 0.35, accentLine: HaloLine(start: UnitPoint(x: 0, y: 1.05), end: UnitPoint(x: 1, y: 0.7)))
        }
    }

    private func backdrop(top: Color, bottom: Color, glow: Color? = nil, secondColor: Color? = nil, animates: Bool = true, accentStrength: Double, accentLine: HaloLine) -> some View {
        LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
            .overlay(
                // The Cosmos halo, in the artwork's own colour (or the
                // theme's), crossing the top of the screen behind the cover.
                HaloBackground(
                    line: HaloLine(start: UnitPoint(x: 0, y: 0.05), end: UnitPoint(x: 1, y: 0.38)),
                    color: glow ?? palette.glow,
                    transparentBase: true,
                    intensityScale: 0.8,
                    animates: animates
                )
            )
            .overlay(
                // And one behind the controls - the theme colour, or the
                // cover's own for the Artwork style - a glow, not a fill, so
                // white text still reads.
                HaloBackground(
                    line: accentLine,
                    color: secondColor ?? palette.accent,
                    transparentBase: true,
                    intensityScale: accentStrength,
                    animates: animates
                )
            )
    }

    /// Artwork + Theme: the cover's colour and the theme's blended across the
    /// screen under a fine grain - no halo, no movement.
    private var blend: some View {
        // The cover's colour, kept bright, toward the top; the theme's toward
        // the bottom; the two meet along a soft, wandering edge rather than a
        // straight line - a mesh whose inner points are nudged off the grid,
        // and whose rows mix the colours unevenly, so it reads as one
        // organic wash. Still, as the player's other backgrounds are not.
        let top = UIColor(palette.vividArtwork), bottom = UIColor(palette.vividTheme)
        // How far up the theme reaches depends on how the two colours get
        // along. Contrasting colours (a yellow cover, a purple theme) keep
        // today's balance - each holds its own half. Colours close in hue,
        // or a greyish cover with little colour of its own, let the theme
        // rise further, since it blends in rather than fighting the cover.
        let themeStart = Self.themeStart(cover: top, theme: bottom)
        let size = 4
        // The same wobble for the same cover; a new one for the next.
        var random = SeededGenerator(seed: UInt64(truncatingIfNeeded: top.hashValue &+ bottom.hashValue))
        var points: [SIMD2<Float>] = []
        var colors: [Color] = []
        for row in 0..<size {
            for column in 0..<size {
                var x = Float(column) / Float(size - 1)
                var y = Float(row) / Float(size - 1)
                let inner = row > 0 && row < size - 1 && column > 0 && column < size - 1
                if inner {
                    x += Float.random(in: -0.14...0.14, using: &random)
                    y += Float.random(in: -0.12...0.12, using: &random)
                } else if row > 0 && row < size - 1 {
                    y += Float.random(in: -0.1...0.1, using: &random)
                }
                points.append(SIMD2(x, y))
                // A little more of the cover's colour than the theme's: the
                // theme starts rising a quarter of the way down and owns
                // the bottom.
                let t = min(max((CGFloat(row) / CGFloat(size - 1) - themeStart) / (1 - themeStart), 0), 1)
                let eased = t * t * (3 - 2 * t)
                let jitter = row == 0 || row == size - 1 ? 0 : CGFloat.random(in: -0.18...0.18, using: &random)
                colors.append(Color(PlayerPalette.blend(top, bottom, amount: min(max(eased + jitter, 0), 1))))
            }
        }
        return ZStack {
            MeshGradient(width: size, height: size, points: points, colors: colors, smoothsColors: true)
            // A little darker toward the controls, for the white text.
            LinearGradient(colors: [.clear, .black.opacity(0.2)], startPoint: .center, endPoint: .bottom)
            FilmGrain()
                .opacity(0.09)
                .blendMode(.overlay)
        }
        .animation(.easeInOut(duration: 0.9), value: palette)
    }

    /// Where down the screen the theme colour starts to rise:
    /// - colours that go together (hues within about a quarter-turn): the
    ///   original balance, about half and half (0.15);
    /// - clashing colours: the theme keeps to the bottom quarter at most
    ///   (0.5), less the more they clash, down to the minimum (0.75) for
    ///   opposite hues;
    /// - grey or black-and-white covers: the minimum (0.75);
    /// - a vivid cover, whatever its hue: the original balance, since it
    ///   stands up to the theme's own vivid colour.
    private static func themeStart(cover: UIColor, theme: UIColor) -> CGFloat {
        let original: CGFloat = 0.15, quarter: CGFloat = 0.5, minimum: CGFloat = 0.75
        var h1: CGFloat = 0, s1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var h2: CGFloat = 0, s2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        guard cover.getHue(&h1, saturation: &s1, brightness: &b1, alpha: &a1),
              theme.getHue(&h2, saturation: &s2, brightness: &b2, alpha: &a2) else { return original }
        // 0 for the same hue, 1 for opposite hues.
        let distance = min(abs(h1 - h2), 1 - abs(h1 - h2)) * 2
        // 0 while the hues sit together, 1 when they are opposite.
        let clash = min(max((distance - 0.5) / 0.5, 0), 1)
        let byHue: CGFloat
        if clash < 0.2 {
            // A short slide from the original to the quarter, so colours just
            // past "together" don't jump.
            byHue = original + (quarter - original) * (clash / 0.2)
        } else {
            byHue = quarter + (minimum - quarter) * ((clash - 0.2) / 0.8)
        }
        // A greyish cover goes to the minimum.
        let colourfulness = min(s1 / 0.35, 1)
        let start = byHue * colourfulness + minimum * (1 - colourfulness)
        // A vivid cover holds its own against the theme's vivid colour, even
        // where the two clash: it keeps the original half-and-half.
        let vividness = min(max((s1 - 0.5) / 0.25, 0), 1)
        return start + (original - start) * vividness
    }

    /// The cover, blown up and blurred, darkened toward the controls so the
    /// white text keeps its contrast.
    private var blurredCover: some View {
        ZStack {
            palette.bottom
            CrossfadingBlurredCover(image: artwork)
            LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
        }
    }
}

/// The blurred cover behind the player. A new cover fades in on top of the
/// old one, which stays fully visible underneath until it is covered - so
/// the backdrop goes from one cover to the next, never through dark.
private struct CrossfadingBlurredCover: View {
    let image: UIImage?
    /// "Animate Background" off: the next cover replaces this one at once.
    var animates = true
    @State private var base: UIImage?
    @State private var incoming: UIImage?
    @State private var incomingOpacity = 0.0

    var body: some View {
        ZStack {
            if let base { blurred(base) }
            if let incoming { blurred(incoming).opacity(incomingOpacity) }
        }
        .onAppear { base = image }
        .onChange(of: image.map(ObjectIdentifier.init)) { _, _ in
            guard let image else { return }
            guard animates else { base = image; return }
            incoming = image
            incomingOpacity = 0
            withAnimation(.easeInOut(duration: 0.9)) {
                incomingOpacity = 1
            } completion: {
                base = image
                incoming = nil
                incomingOpacity = 0
            }
        }
    }

    private func blurred(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .clipped()
            .blur(radius: 70, opaque: true)
            .saturation(1.2)
    }
}

// MARK: - System controls

/// The system AirPlay / Bluetooth output picker.
private struct RoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.tintColor = UIColor.white.withAlphaComponent(0.85)
        view.activeTintColor = .white
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

/// Owns the fast-changing progress observation so the complete PlayerView
/// (artwork, sheets and controls) is not recomputed four times per second.
private struct PlayerProgressSection: View {
    @ObservedObject private var progress = PlayerEngine.shared.progress
    let duration: TimeInterval
    let formatDescription: String?
    var accentColor: Color = .white
    let onSeek: (TimeInterval) async -> Void

    private var fraction: Double {
        guard duration > 0 else { return 0 }
        let value = progress.playbackTime / duration
        guard value.isFinite else { return 0 }
        return max(0, min(1, value))
    }

    var body: some View {
        VStack(spacing: Design.Spacing.s) {
            InteractiveProgressBar(
                progress: fraction,
                onSeek: { await onSeek($0 * duration) },
                accentColor: accentColor,
                duration: duration
            )
            .frame(height: 20)

            HStack {
                Text(DurationFormatter.string(seconds: progress.playbackTime))
                Spacer()
                if let formatDescription {
                    Text(formatDescription)
                        .lineLimit(1)
                }
                Spacer()
                Text("-" + DurationFormatter.string(seconds: max(0, duration - progress.playbackTime)))
            }
            .font(.caption.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.6))
            .accessibilityHidden(true)
        }
    }
}

/// Keeps lyric timing updates inside the lyrics content instead of
/// invalidating the player around it.
private struct LiveLyricsPanel: View {
    @ObservedObject private var progress = PlayerEngine.shared.progress
    let lyrics: Lyrics?
    let isLoading: Bool
    let trackTitle: String?
    let trackArtist: String?
    let onRetry: (() -> Void)?
    let track: Track?
    let onSelectAlternative: ((Int) -> Void)?

    var body: some View {
        LyricsView(
            lyrics: lyrics,
            currentTime: progress.playbackTime,
            isLoading: isLoading,
            trackTitle: trackTitle,
            trackArtist: trackArtist,
            onSeek: { time in
                Task { await PlayerEngine.shared.seek(to: time) }
            },
            onRetry: onRetry,
            loadAlternatives: track.map { track in
                { await LyricsManager.shared.alternatives(for: track) }
            },
            onSelectAlternative: onSelectAlternative,
            isEmbedded: true
        )
    }
}

struct InteractiveProgressBar: View {
    let progress: Double
    let onSeek: (Double) async -> Void
    let accentColor: Color
    /// Lets VoiceOver speak the position as a time and step it in seconds.
    var duration: TimeInterval = 0

    @State private var isDragging = false
    @State private var dragProgress: Double = 0

    var displayProgress: Double {
        isDragging ? dragProgress : progress
    }

    var body: some View {
        GeometryReader { geometry in
            let trackHeight: CGFloat = isDragging ? 10 : 6
            ZStack(alignment: .leading) {
                // Background track
                Capsule()
                    .fill(accentColor.opacity(0.25))
                    .frame(height: trackHeight)

                // Progress fill
                Capsule()
                    .fill(accentColor)
                    .frame(width: max(trackHeight, geometry.size.width * displayProgress), height: trackHeight)
            }
            .frame(maxHeight: .infinity)
            .animation(.easeOut(duration: 0.15), value: isDragging)
            .contentShape(Rectangle())
            .gesture(
                // A zero minimum distance handles taps as well as drags and
                // avoids launching two competing seek tasks for one touch.
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        dragProgress = max(0, min(1, value.location.x / geometry.size.width))
                    }
                    .onEnded { value in
                        let finalProgress = max(0, min(1, value.location.x / geometry.size.width))
                        dragProgress = finalProgress
                        Task { @MainActor in
                            await onSeek(finalProgress)
                            isDragging = false
                        }
                    }
            )
        }
        .accessibilityElement()
        .accessibilityLabel(Localized.nowPlaying)
        .accessibilityValue(accessibilityPosition)
        .accessibilityAdjustableAction { direction in
            // Ten seconds a step, or a twentieth of the song if the length
            // is unknown.
            let step = duration > 0 ? 10 / duration : 0.05
            let target: Double
            switch direction {
            case .increment: target = min(1, progress + step)
            case .decrement: target = max(0, progress - step)
            @unknown default: return
            }
            Task { await onSeek(target) }
        }
    }

    private var accessibilityPosition: String {
        guard duration > 0 else { return "\(Int(progress * 100))%" }
        let elapsed = DurationFormatter.string(seconds: progress * duration)
        let total = DurationFormatter.string(seconds: duration)
        return "\(elapsed) / \(total)"
    }
}

/// The mini player: a solid card above the tab bar (on iPad, at the bottom
/// of the content column). Tapping it zooms into the full-screen player.
struct MiniPlayerView: View {
    static let transitionID = "nowPlayingArtwork"

    var transitionNamespace: Namespace.ID? = nil

    @ObservedObject private var playerEngine = PlayerEngine.shared
    @ObservedObject private var theme = ThemeStore.shared
    @State private var currentArtwork: UIImage?
    @State private var artistName: String?

    var body: some View {
        if let track = playerEngine.currentTrack {
            card(for: track)
                .task(id: track.stableId) {
                    artistName = try? DatabaseManager.shared.getArtistDisplayName(
                        forTrackStableId: track.stableId,
                        fallbackArtistId: track.artistId
                    )
                    currentArtwork = await ArtworkManager.shared.getArtwork(for: track)
                }
        }
    }

    private func card(for track: Track) -> some View {
        VStack(spacing: Design.Spacing.s) {
            // A track that cannot be played says so here. Previously
            // playbackState went to .loading or .stopped and no view read it,
            // so a file that had gone missing - or an iCloud download that
            // stalled - just sat silent and selected.
            if let message = playerEngine.playbackErrorMessage {
                PlaybackErrorBanner(message: message) {
                    playerEngine.playbackErrorMessage = nil
                }
            }

            HStack(spacing: Design.Spacing.m) {
                Button(action: openPlayer) {
                    HStack(spacing: Design.Spacing.m) {
                        ArtworkView(image: currentArtwork, cornerRadius: Design.Radius.thumbnail)
                            .frame(width: 46, height: 46)
                            .transitionSource(id: Self.transitionID, in: transitionNamespace)

                        MiniPlayerLabels(title: track.title, subtitle: artistName)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(nowPlayingLabel(for: track))
                .accessibilityHint(Localized.openNowPlaying)

                // Transport. Each button has its own 44pt target so a tap
                // near the edge cannot open the player instead.
                MiniPlayerButton(
                    systemImage: playerEngine.isPlaying ? "pause.fill" : "play.fill",
                    label: playerEngine.isPlaying ? Localized.pause : Localized.play,
                    isProminent: true,
                    action: togglePlay
                )
                MiniPlayerButton(systemImage: "forward.fill", label: Localized.nextTrack, action: next)
            }
            .padding(.leading, Design.Spacing.s)
            .padding(.trailing, Design.Spacing.xs)
            .padding(.vertical, Design.Spacing.s)
            .background(alignment: .bottom) {
                MiniPlayerProgressBar(duration: playerEngine.duration, accentColor: theme.accent)
                    .padding(.horizontal, Design.Spacing.m)
                    .padding(.bottom, 1)
            }
            .modifier(SolidCardBackground())
            .gesture(
                // Swipe the card up to open the player, the way the
                // full-screen player swipes down to close.
                DragGesture(minimumDistance: 20)
                    .onEnded { value in
                        if value.translation.height < -30 { openPlayer() }
                    }
            )
        }
        .padding(.horizontal, Design.Spacing.m)
    }

    private func nowPlayingLabel(for track: Track) -> String {
        [Localized.nowPlaying, track.title, artistName].compactMap { $0 }.joined(separator: ", ")
    }

    private func openPlayer() {
        // The player would otherwise open on top of a keyboard left up by a
        // list's search field.
        dismissSearchKeyboard()
        AppRouter.shared.isPlayerPresented = true
    }

    private func togglePlay() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if playerEngine.isPlaying {
            playerEngine.pause()
        } else {
            playerEngine.play()
        }
    }

    private func next() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { await playerEngine.nextTrack() }
    }
}

/// An opaque raised card: white on light, a lifted grey on dark, with a
/// hairline edge and a soft shadow. No glass - the mini player has to read
/// the same over any content scrolling beneath it.
private struct SolidCardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            // Half glass, like the tab bar beneath it.
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            // SurfaceColor.card, not an inline `UIColor { }`:
                            // a provider closure written here inherits the
                            // modifier's main-actor isolation, SwiftUI's async
                            // renderer resolves it off the main thread while
                            // the halo animates, and Swift's isolation check
                            // traps (crash on the iPad sim, 2026-10-22).
                            .fill(SurfaceColor.card.opacity(0.6))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color(.separator).opacity(0.5), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
    }
}

private struct MiniPlayerLabels: View {
    let title: String
    let subtitle: String?
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 0 : 2) {
            Text(title)
                .font(compact ? .subheadline.weight(.semibold) : .headline)
                .foregroundStyle(.primary)
                .lineLimit(1)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(compact ? .caption : .subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        // Take the slack rather than leaving it between the labels and the
        // transport controls, so titles have as much room as possible before
        // truncating.
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MiniPlayerButton: View {
    let systemImage: String
    let label: String
    var isProminent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(isProminent ? .title2 : .title3)
                .foregroundStyle(.primary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: Design.Size.minTouch, height: Design.Size.minTouch)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct PlaybackErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Design.Spacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: Design.Size.minTouch, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Localized.close)
        }
        .padding(.leading, Design.Spacing.m)
        .padding(.vertical, Design.Spacing.xs)
        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: Design.Radius.artwork, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    /// The source of the zoom into the full-screen player, when there is a
    /// namespace to zoom within.
    @ViewBuilder
    func transitionSource(id: String, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
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


/// The one song row used by every list in the app - All Songs, Liked Songs,
/// albums, artists, playlists and search - so a song looks and behaves the
/// same wherever it appears. Before this there were five row types with
/// different artwork sizes, fonts and menus, and on album pages a menu button
/// too small to hit reliably.
struct TrackRowView: View, @MainActor Equatable {
    /// What sits at the start of the row: the artwork, or the track number on
    /// an album page where every song shares one cover.
    enum Leading: Equatable {
        case artwork
        case number(Int)
    }

    // 1. Pass these in instead of observing PlayerEngine
    let track: Track
    let activeTrackId: String?
    let isAudioPlaying: Bool
    let artistName: String?
    var leading: Leading = .artwork
    var showsDuration: Bool = false
    /// Off on the album page itself, where "Go to Album" would push a copy of
    /// the page already on screen. Same for the artist link on an artist page.
    var showsAlbumLink: Bool = true
    var showsArtistLink: Bool = true
    /// Off where the artist is already the page's subject - an album by one
    /// artist names them once in the header, not on every row.
    var showsArtist: Bool = true
    /// A grid tile - cover above title and artist - for iPad song grids.
    var isTile: Bool = false

    let onTap: () -> Void
    let playlist: Playlist?
    let showDirectDeleteButton: Bool
    let onEnterBulkMode: (() -> Void)?

    /// Everything the closures above capture that can change without any of
    /// the compared fields changing.
    ///
    /// `.equatable()` skips `body` whenever `==` answers true, and the stored
    /// view - including `onTap` - is kept as it was. So a closure that reads
    /// the parent's state acts on whatever that state held the last time this
    /// row actually re-rendered. That is how searching a list produced a queue
    /// built from the *unfiltered* list: the surviving rows compared equal, so
    /// they kept the `onTap` that had captured the pre-search track array.
    /// Anything a closure reads has to be folded in here.
    /// Composed by the parent; see `TrackListContentView.rowContextIdentity`.
    let contextIdentity: String

    @EnvironmentObject private var appCoordinator: AppCoordinator

    // Internal state only (does not trigger external redraws)
    @State private var isFavorite = false
    @State private var showPlaylistDialog = false
    @State private var artworkImage: UIImage?
    @State private var showDeleteConfirmation = false
    // Observed rather than copied into @State: `.equatable()` keeps the parent
    // from re-rendering this row, so a copy would keep the old colour after a
    // theme change. An observed object still invalidates the row itself.
    @ObservedObject private var theme = ThemeStore.shared
    @Environment(\.playerAccent) private var playerAccent

    /// In the player's Up Next, the player's colour; elsewhere the theme's.
    private var accent: Color { playerAccent ?? theme.accent }

    // 2. Computed property is now based on passed params
    private var isCurrentlyPlaying: Bool {
        activeTrackId == track.stableId
    }

    // 3. Equatable Conformance: Prevents redraws when PlayerEngine updates time
    static func == (lhs: TrackRowView, rhs: TrackRowView) -> Bool {
        return lhs.track.stableId == rhs.track.stableId &&
        lhs.track.title == rhs.track.title &&
        lhs.activeTrackId == rhs.activeTrackId &&
        lhs.isAudioPlaying == rhs.isAudioPlaying &&
        lhs.artistName == rhs.artistName &&
        lhs.leading == rhs.leading &&
        lhs.showsDuration == rhs.showsDuration &&
        lhs.showsArtist == rhs.showsArtist &&
        lhs.isTile == rhs.isTile &&
        lhs.playlist?.id == rhs.playlist?.id &&
        lhs.showDirectDeleteButton == rhs.showDirectDeleteButton &&
        lhs.contextIdentity == rhs.contextIdentity
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
        let artist = showsArtist ? resolvedArtistName() : nil

        Group {
            if isTile {
                tileBody(artist: artist)
            } else {
                rowBody(artist: artist)
            }
        }
        .sheet(isPresented: $showPlaylistDialog) {
            PlaylistSelectionView(track: track)
                .accentColor(accent)
        }
        .alert(Localized.deleteFile, isPresented: $showDeleteConfirmation) {
            Button(Localized.delete, role: .destructive) { deleteFile() }
            Button(Localized.cancel, role: .cancel) { }
        } message: {
            Text(Localized.deleteFileConfirmation(track.title))
        }
        .onAppear {
            isFavorite = (try? appCoordinator.isFavorite(trackStableId: track.stableId)) ?? false
            if artworkImage == nil, leading == .artwork { loadArtwork() }
        }
        .reloadsArtwork(for: track.stableId) {
            if leading == .artwork { loadArtwork() }
        }
    }

    /// Cover, then title and artist with the "…" menu beside them; holding
    /// the tile offers the same menu.
    private func tileBody(artist: String?) -> some View {
        VStack(alignment: .leading, spacing: Design.Spacing.xs + 2) {
            ArtworkView(image: artworkImage, cornerRadius: Design.Radius.artwork)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if isCurrentlyPlaying {
                        RoundedRectangle(cornerRadius: Design.Radius.artwork, style: .continuous)
                            .strokeBorder(accent, lineWidth: 3)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if isCurrentlyPlaying {
                        equalizer
                            .padding(Design.Spacing.s)
                            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .padding(Design.Spacing.s)
                    }
                }
                .shadow(color: .black.opacity(0.12), radius: 8, y: 4)

            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isCurrentlyPlaying ? accent : .primary)
                        .lineLimit(1)
                    if let artist, !artist.isEmpty {
                        Text(artist)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Menu {
                    menuContent
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: Design.Size.minTouch, alignment: .topTrailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Localized.moreOptions)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .contextMenu { menuContent }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(artist: artist))
        .accessibilityValue(isCurrentlyPlaying ? Localized.nowPlaying : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onTap() }
    }

    private func rowBody(artist: String?) -> some View {
        HStack(spacing: 0) {
            // MARK: - Tappable Content Area
            HStack(spacing: Design.Spacing.m) {
                leadingView

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(isCurrentlyPlaying ? accent : .primary)
                        .lineLimit(1)

                    if let artist, !artist.isEmpty {
                        Text(artist)
                            .font(.subheadline)
                            .foregroundStyle(isCurrentlyPlaying ? accent.opacity(0.85) : .secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: Design.Spacing.s)

                // The number column already shows the bars on album pages.
                if isCurrentlyPlaying, leading == .artwork {
                    equalizer
                }

                if showsDuration, let duration = DurationFormatter.string(milliseconds: track.durationMs) {
                    Text(duration)
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onTap()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel(artist: artist))
            .accessibilityValue(isCurrentlyPlaying ? Localized.nowPlaying : "")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onTap() }
            .accessibilityAction(named: Localized.playNext) { PlayerEngine.shared.insertNext(track) }
            .accessibilityAction(named: Localized.addToQueue) { PlayerEngine.shared.addToQueue(track) }
            .accessibilityAction(named: Localized.songMix) { Task { await MixStore.shared.playSongMix(from: track) } }
            .accessibilityAction(named: isFavorite ? Localized.removeFromLikedSongs : Localized.addToLikedSongs) { toggleFavorite() }

            // MARK: - Menu / Action Area
            if showDirectDeleteButton {
                Button(role: .destructive) {
                    removeFromPlaylist()
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.multicolor)
                        .frame(width: Design.Size.minTouch, height: Design.Size.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Localized.removeFromPlaylist)
            } else {
                Menu {
                    menuContent
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: Design.Size.minTouch, height: Design.Size.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Localized.moreOptions)
            }
        }
        .frame(minHeight: leading == .artwork ? 72 : 56)
        // Under the page's title, not 4 points left of it on iPad.
        .pagePadding(.leading)
        .padding(.trailing, Design.Spacing.xs)
    }

    @ViewBuilder
    private var leadingView: some View {
        switch leading {
        case .artwork:
            ArtworkView(image: artworkImage, cornerRadius: Design.Radius.thumbnail)
                .frame(width: Design.Size.rowArtwork, height: Design.Size.rowArtwork)
                .overlay {
                    if isCurrentlyPlaying {
                        RoundedRectangle(cornerRadius: Design.Radius.thumbnail, style: .continuous)
                            .strokeBorder(accent, lineWidth: 2)
                    }
                }
        case .number(let number):
            Group {
                if isCurrentlyPlaying {
                    equalizer
                } else {
                    Text("\(number)")
                        .font(.body)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 28, alignment: .center)
        }
    }

    private var equalizer: some View {
        let eqKey = "\(isAudioPlaying && isCurrentlyPlaying)-\(activeTrackId ?? "")"
        return EqualizerBarsExact(
            color: accent,
            isActive: isAudioPlaying && isCurrentlyPlaying,
            isLarge: true,
            trackId: activeTrackId
        )
        .id(eqKey)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var menuContent: some View {
        Section {
            Button {
                PlayerEngine.shared.insertNext(track)
            } label: {
                Label(Localized.playNext, systemImage: "text.line.first.and.arrowtriangle.forward")
            }

            Button {
                PlayerEngine.shared.addToQueue(track)
            } label: {
                Label(Localized.addToQueue, systemImage: "text.append")
            }

            Button {
                Task { await MixStore.shared.playSongMix(from: track) }
            } label: {
                Label(Localized.songMix, systemImage: "dot.radiowaves.left.and.right")
            }
        }

        Section {
            Button {
                toggleFavorite()
            } label: {
                Label(
                    isFavorite ? Localized.removeFromLikedSongs : Localized.addToLikedSongs,
                    systemImage: isFavorite ? "heart.slash" : "heart"
                )
            }

            Button {
                showPlaylistDialog = true
            } label: {
                Label(Localized.addToPlaylistEllipsis, systemImage: "text.badge.plus")
            }
        }

        if (showsAlbumLink && track.albumId != nil) || (showsArtistLink && track.artistId != nil) {
            Section {
                if showsAlbumLink, track.albumId != nil {
                    Button {
                        AppRouter.shared.openAlbum(of: track)
                    } label: {
                        Label(Localized.showAlbum, systemImage: "square.stack")
                    }
                }

                if showsArtistLink, track.artistId != nil {
                    Button {
                        AppRouter.shared.openArtist(of: track)
                    } label: {
                        Label(Localized.showArtistPage, systemImage: "music.microphone")
                    }
                }
            }
        }

        Section {
            if let onEnterBulkMode = onEnterBulkMode {
                Button(action: { onEnterBulkMode() }) {
                    Label(Localized.select, systemImage: "checkmark.circle")
                }
            }

            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label(Localized.deleteFile, systemImage: "trash")
            }
        }
    }

    private func accessibilityLabel(artist: String?) -> String {
        var parts = [track.title]
        if let artist, !artist.isEmpty { parts.append(artist) }
        if showsDuration, let duration = DurationFormatter.string(milliseconds: track.durationMs) {
            parts.append(duration)
        }
        return parts.joined(separator: ", ")
    }

    private func toggleFavorite() {
        do {
            try appCoordinator.toggleFavorite(trackStableId: track.stableId)
            isFavorite.toggle()
        } catch { print("Failed to toggle favorite: \(error)") }
    }

    private func loadArtwork() {
        Task {
            artworkImage = isTile
                ? await ArtworkManager.shared.getThumbnail(for: track, maxPixelSize: 480)
                : await ArtworkManager.shared.getThumbnail(for: track)
        }
    }

    private func deleteFile() {
        Task {
            do {
                let settings = DeleteSettings.load()
                if settings.deleteFromLibraryOnly {
                    DeleteSettings.addExcludedTrack(track.stableId, path: track.path, modificationDate: track.modificationDate)
                } else {
                    do {
                        try FileManager.default.removeItem(at: URL(fileURLWithPath: track.path))
                    } catch {
                        print("⚠️ Could not remove file from disk: \(error.localizedDescription)")
                    }
                }

                try await DatabaseManager.shared.deleteTrack(byStableId: track.stableId)
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

/// `TrackRowView` for lists that do not already observe the player: it reads
/// the playing track itself and hands it to the (equatable) row.
struct LiveTrackRow: View {
    let track: Track
    let artistName: String?
    var leading: TrackRowView.Leading = .artwork
    var showsDuration = false
    var showsAlbumLink = true
    var showsArtistLink = true
    var showsArtist = true
    var playlist: Playlist? = nil
    var showDirectDeleteButton = false
    var onEnterBulkMode: (() -> Void)? = nil
    /// See `TrackRowView.contextIdentity`.
    var contextIdentity: String = ""
    let onTap: () -> Void

    @ObservedObject private var playerEngine = PlayerEngine.shared

    var body: some View {
        TrackRowView(
            track: track,
            activeTrackId: playerEngine.currentTrack?.stableId,
            isAudioPlaying: playerEngine.isPlaying,
            artistName: artistName,
            leading: leading,
            showsDuration: showsDuration,
            showsAlbumLink: showsAlbumLink,
            showsArtistLink: showsArtistLink,
            showsArtist: showsArtist,
            onTap: onTap,
            playlist: playlist,
            showDirectDeleteButton: showDirectDeleteButton,
            onEnterBulkMode: onEnterBulkMode,
            contextIdentity: contextIdentity
        )
        .equatable()
    }
}

extension View {
    /// The list-row setup every song list shares: no inset (the row pads
    /// itself), a separator that starts under the text, and the swipe
    /// actions - Play Next from the leading edge, Add to Queue from the
    /// trailing edge - so they work the same in every list.
    func songListRow(
        _ track: Track,
        separatorLeading: CGFloat = Design.Spacing.l + Design.Size.rowArtwork + Design.Spacing.m,
        swipeActionsEnabled: Bool = true
    ) -> some View {
        modifier(SongListRowModifier(track: track, separatorLeading: separatorLeading, swipeActionsEnabled: swipeActionsEnabled))
    }
}

private struct SongListRowModifier: ViewModifier {
    let track: Track
    let separatorLeading: CGFloat
    let swipeActionsEnabled: Bool

    @ObservedObject private var theme = ThemeStore.shared
    @Environment(\.pageMargin) private var pageMargin
    @State private var recentlyActed = false

    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            // Callers measure from the 16-point margin; the row starts at the
            // page's, 20 points on iPad, and the separator moves with it.
            .alignmentGuide(.listRowSeparatorLeading) { _ in separatorLeading + pageMargin - Design.Spacing.l }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if swipeActionsEnabled && !recentlyActed {
                    Button {
                        PlayerEngine.shared.insertNext(track)
                        markActed()
                    } label: {
                        Label(Localized.playNext, systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    .tint(theme.accent)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if swipeActionsEnabled && !recentlyActed {
                    Button {
                        PlayerEngine.shared.addToQueue(track)
                        markActed()
                    } label: {
                        Label(Localized.addToQueue, systemImage: "text.append")
                    }
                    .tint(.blue)
                }
            }
    }

    /// A full swipe can fire twice on a fast flick; ignore repeats for a
    /// moment.
    private func markActed() {
        recentlyActed = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            recentlyActed = false
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
