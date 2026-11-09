import SwiftUI

// MARK: - Tokens

/// The app's shared sizes, so every screen draws the same row, the same
/// corner and the same button. Before this file the app used eight different
/// corner radii and three different Play/Shuffle button heights.
enum Design {
    enum Radius {
        /// Song-row artwork and other small thumbnails.
        static let thumbnail: CGFloat = 8
        /// Album, playlist and detail-page artwork, cards.
        static let artwork: CGFloat = 12
        /// Large artwork in the player.
        static let hero: CGFloat = 16
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Size {
        /// Apple's minimum touch target.
        static let minTouch: CGFloat = 44
        /// Artwork in every song row.
        static let rowArtwork: CGFloat = 56
        /// Play / Shuffle buttons on album, artist and playlist pages.
        static let actionButtonHeight: CGFloat = 50
        /// Largest square cover on a detail page.
        static let maxDetailCover: CGFloat = 280
        /// Minimum width of an album or playlist tile in an adaptive grid.
        static let gridTileMinWidth: CGFloat = 150
    }
}

// MARK: - Theme

/// The user's accent colour, observed once instead of every view keeping its
/// own copy of `DeleteSettings` and its own pair of notification observers.
@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    @Published private(set) var accent: Color

    private var observers: [NSObjectProtocol] = []

    private init() {
        accent = DeleteSettings.load().backgroundColorChoice.color
        for name in [Notification.Name.cosmosSettingsDidChange, Notification.Name("BackgroundColorChanged")] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    ThemeStore.shared.reload()
                }
            })
        }
    }

    private func reload() {
        let newAccent = DeleteSettings.load().backgroundColorChoice.color
        if newAccent != accent {
            accent = newAccent
        }
    }
}

// MARK: - Artwork

/// A square piece of artwork with a placeholder. The caller sets the size.
struct ArtworkView: View {
    let image: UIImage?
    var cornerRadius: CGFloat = Design.Radius.artwork
    var placeholderSymbol: String = "music.note"

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.clear)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .transition(.opacity.animation(.easeOut(duration: 0.2)))
                } else {
                    ArtworkPlaceholder(symbol: placeholderSymbol)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                // A hairline keeps white or black covers from dissolving into
                // the background in light or dark mode.
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .accessibilityHidden(true)
    }
}

/// Shown where a song or album has no cover: the accent colour as a soft
/// gradient with a symbol, so a missing cover still looks deliberate.
struct ArtworkPlaceholder: View {
    var symbol: String = "music.note"
    @ObservedObject private var theme = ThemeStore.shared

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(
                    colors: [theme.accent.opacity(0.42), theme.accent.opacity(0.14)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: symbol)
                    .font(.system(size: max(14, min(geometry.size.width, geometry.size.height) * 0.3), weight: .medium))
                    .foregroundStyle(theme.accent)
            }
        }
    }
}

// MARK: - Play / Shuffle

/// The two buttons at the top of every album, artist and playlist page.
/// Same size, same shape and same colours everywhere.
struct PlayShuffleButtons: View {
    var isDisabled: Bool = false
    let onPlay: () -> Void
    let onShuffle: () -> Void

    @ObservedObject private var theme = ThemeStore.shared

    var body: some View {
        // Side by side while both labels fit; stacked once large text would
        // cut them to "Lect…" - as in the narrow left column of an iPad
        // album page.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Design.Spacing.m) {
                button(Localized.play, systemImage: "play.fill", action: onPlay)
                button(Localized.shuffle, systemImage: "shuffle", action: onShuffle)
            }
            VStack(spacing: Design.Spacing.m) {
                button(Localized.play, systemImage: "play.fill", action: onPlay)
                button(Localized.shuffle, systemImage: "shuffle", action: onShuffle)
            }
        }
        .disabled(isDisabled)
    }

    private func button(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: Design.Size.actionButtonHeight)
                .padding(.horizontal, Design.Spacing.s)
                .foregroundStyle(theme.accent)
                // A solid fill, as Music does: a faint accent wash read as
                // disabled over the halo.
                .background(SurfaceColor.control, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle())
    }
}

/// A gentle press highlight for custom buttons, so they still answer a tap
/// the way system buttons do.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Detail header

/// The header shared by album, playlist and (fallback) artist pages: cover,
/// title, a tappable subtitle, a line of details, then Play / Shuffle.
struct DetailHeader<Cover: View>: View {
    let title: String
    var subtitle: String? = nil
    var onSubtitleTap: (() -> Void)? = nil
    var detail: String? = nil
    var isPlayDisabled: Bool = false
    let onPlay: () -> Void
    let onShuffle: () -> Void
    @ViewBuilder let cover: () -> Cover

    @ObservedObject private var theme = ThemeStore.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.isInDetailPanel) private var isInDetailPanel

    var body: some View {
        if isInDetailPanel {
            panelBody
        } else if horizontalSizeClass == .regular {
            wideBody
        } else {
            compactBody
        }
    }

    /// The left column of a two-column page: cover filling the column, then
    /// the title and buttons left-aligned under it.
    private var panelBody: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.xl) {
            cover()
                .frame(maxWidth: .infinity)
                .shadow(color: .black.opacity(0.22), radius: 22, y: 12)

            titleBlock(alignment: .leading)

            PlayShuffleButtons(isDisabled: isPlayDisabled, onPlay: onPlay, onShuffle: onShuffle)
        }
    }

    /// Phone: cover on top, everything centred beneath it.
    private var compactBody: some View {
        VStack(spacing: Design.Spacing.l) {
            cover()
                .frame(maxWidth: Design.Size.maxDetailCover)
                .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
                .padding(.horizontal, Design.Spacing.xxl * 1.5)

            titleBlock(alignment: .center)
                .pagePadding()

            PlayShuffleButtons(isDisabled: isPlayDisabled, onPlay: onPlay, onShuffle: onShuffle)
                .pagePadding()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Design.Spacing.l)
    }

    /// iPad and an unfolded foldable: cover on the left, title and buttons
    /// beside it, as Music lays out an album on a large screen.
    private var wideBody: some View {
        HStack(alignment: .bottom, spacing: Design.Spacing.xxl) {
            cover()
                .frame(width: 260, height: 260)
                .shadow(color: .black.opacity(0.22), radius: 18, y: 10)

            VStack(alignment: .leading, spacing: Design.Spacing.l) {
                titleBlock(alignment: .leading)
                PlayShuffleButtons(isDisabled: isPlayDisabled, onPlay: onPlay, onShuffle: onShuffle)
                    .frame(maxWidth: 380)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Design.Spacing.xl)
        .padding(.vertical, Design.Spacing.xl)
    }

    private func titleBlock(alignment: HorizontalAlignment) -> some View {
        let textAlignment: TextAlignment = alignment == .center ? .center : .leading
        return VStack(alignment: alignment, spacing: Design.Spacing.xs) {
            Text(title)
                .font(isInDetailPanel ? .title.weight(.bold) : horizontalSizeClass == .regular ? .largeTitle.weight(.bold) : .title2.weight(.bold))
                .multilineTextAlignment(textAlignment)
                // Beside the cover, a long title - a mix named "Karl Casey
                // and Protoje" - was cut to one line ("Karl Casey et…"):
                // up to two lines, shrinking a little before it cuts. The
                // fixed height makes the row grow for the second line rather
                // than squeeze it. The phone's centred title keeps every line.
                .lineLimit(alignment == .center ? nil : 2)
                .minimumScaleFactor(alignment == .center ? 1 : 0.75)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            if let subtitle, !subtitle.isEmpty {
                if let onSubtitleTap {
                    Button(action: onSubtitleTap) {
                        Text(subtitle)
                            .font(.title3)
                            .foregroundStyle(theme.accent)
                            .multilineTextAlignment(textAlignment)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(subtitle)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(textAlignment)
                }
            }

            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(textAlignment)
            }
        }
    }
}

// MARK: - Detail page

extension EnvironmentValues {
    /// Set inside the left column of a two-column `DetailPage`.
    @Entry var isInDetailPanel = false
    /// The screen can fold (iPhone Duo's inner display), whether or not it
    /// is folded right now.
    @Entry var isFoldableDisplay = false
    /// The fold runs top to bottom across the screen (iPhone Duo open like a
    /// book), so side-by-side columns meet it; false when it runs across.
    @Entry var foldRunsDown = false
    /// Width taken by a camera at the top trailing corner (iPhone Duo's
    /// cover screen); the tabs keep their content and bars clear of it.
    @Entry var trailingOcclusion: CGFloat = 0
    /// The full-screen player's colour for its controls, lyrics and queue.
    @Entry var playerAccent: Color? = nil
    /// The side margin of a page: the one the navigation bar gives its large
    /// title and buttons, and lists their rows - 16 points on most iPhones,
    /// 20 on iPad, iPhone Duo and the largest iPhones. A fixed 16 put the
    /// content 4 points left of the title wherever the system used 20. Read
    /// from UIKit at the root (`readsPageMargin`); see `pagePadding`.
    @Entry var pageMargin: CGFloat = Design.Spacing.l
}

// MARK: - Tab header

extension View {
    /// The top of a tab's first screen: the Cosmos icon and the screen's
    /// title on one line with the bar's buttons (settings, add...), all
    /// aligned. A large title sits on its own row under the buttons, so the
    /// icon and gear never lined up with it.
    func cosmosTabHeader(_ title: String) -> some View {
        modifier(CosmosTabHeader(title: title))
    }
}

/// The app icon beside screen titles. A listener who said they donated
/// (Settings › Support Cosmos) gets a small heart on its corner: a thank-you
/// only, on trust.
struct CosmosLogo: View {
    let size: CGFloat
    @AppStorage(SupportCosmos.supporterKey) private var isSupporter = false

    var body: some View {
        Image("AppLogo")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size / 4, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            .overlay(alignment: .bottomTrailing) {
                if isSupporter {
                    Image(systemName: "heart.fill")
                        .font(.system(size: size * 0.34, weight: .bold))
                        .foregroundStyle(.pink)
                        .padding(size * 0.07)
                        .background(SurfaceColor.card, in: Circle())
                        .offset(x: size * 0.18, y: size * 0.18)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.4, bounce: 0.4), value: isSupporter)
    }
}

private struct CosmosTabHeader: ViewModifier {
    let title: String
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.isFoldableDisplay) private var isFoldable

    /// iPad: the system's large title, on its own row under the bar. In the
    /// bar it shared one row with the floating tab bar and the buttons, and a
    /// narrower window pushed it off the leading edge. The logo is in the
    /// sidebar there anyway; iPhone Duo keeps it, its sidebar usually tucked
    /// away.
    private var usesLargeTitle: Bool {
        horizontalSizeClass == .regular && !isFoldable
    }

    func body(content: Content) -> some View {
        content
            // Still the title for the back button of pages pushed from here.
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(usesLargeTitle ? .large : .inline)
            .toolbar {
                if !usesLargeTitle {
                    // The centred inline title would repeat the one on the left.
                    ToolbarItem(placement: .principal) {
                        Color.clear.frame(width: 1, height: 1)
                            .accessibilityHidden(true)
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        HStack(spacing: Design.Spacing.s + 2) {
                            CosmosLogo(size: 32)
                                .accessibilityHidden(true)
                            Text(title)
                                .font(.title.weight(.bold))
                                .lineLimit(1)
                                .fixedSize()
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
                    .cosmosPlainBackground()
                }
            }
    }
}

// MARK: - Page margin

extension View {
    /// Reads the system's side margin into `pageMargin` for every page.
    /// Set once at the root.
    func readsPageMargin() -> some View {
        modifier(PageMarginReader())
    }

    /// The side padding of page content - section titles, grids, shelves,
    /// rows - so it lines up with the title above and the bar's buttons on
    /// every device. See `pageMargin`.
    func pagePadding(_ edges: Edge.Set = .horizontal) -> some View {
        modifier(PagePadding(edges: edges))
    }

    /// A list row's (or header's) insets on the page margin at the sides,
    /// with its own top and bottom; the list's defaults when not `isActive`.
    func pageRowInsets(top: CGFloat, bottom: CGFloat, isActive: Bool = true) -> some View {
        modifier(PageRowInsets(top: top, bottom: bottom, isActive: isActive))
    }
}

private struct PagePadding: ViewModifier {
    let edges: Edge.Set
    @Environment(\.pageMargin) private var margin

    func body(content: Content) -> some View {
        content.padding(edges, margin)
    }
}

private struct PageRowInsets: ViewModifier {
    let top: CGFloat
    let bottom: CGFloat
    let isActive: Bool
    @Environment(\.pageMargin) private var margin

    func body(content: Content) -> some View {
        content.listRowInsets(isActive ? EdgeInsets(top: top, leading: margin, bottom: bottom, trailing: margin) : nil)
    }
}

private struct PageMarginReader: ViewModifier {
    @State private var margin = Design.Spacing.l

    func body(content: Content) -> some View {
        content
            .environment(\.pageMargin, margin)
            .background {
                SystemMarginProbe { margin = $0 }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

/// An empty UIKit view that asks for the system's minimum side margin - the
/// one the navigation bar lays out its large title and buttons with. Asked
/// rather than guessed from the screen width, it is right on every iPhone,
/// iPad and iPhone Duo, and is asked again whenever the window is laid out:
/// a rotation, a resized iPad window, the Duo opening.
private struct SystemMarginProbe: UIViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.onChange = onChange
    }

    final class ProbeView: UIView {
        var onChange: ((CGFloat) -> Void)?
        private var reported: CGFloat?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            // A size class change without a new size (an iPad window
            // crossing the compact width) still asks again.
            registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (view: ProbeView, _) in
                view.setNeedsLayout()
            }
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            scheduleRead()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            scheduleRead()
        }

        /// After the current layout pass: mid-rotation the controller's
        /// margins may not have their new value yet, and SwiftUI state must
        /// not change while it lays out.
        private func scheduleRead() {
            Task { @MainActor [weak self] in
                self?.read()
            }
        }

        private func read() {
            guard let controller = window?.rootViewController else { return }
            let margin = controller.systemMinimumLayoutMargins.leading
            guard margin > 0, margin != reported else { return }
            reported = margin
            onChange?(margin)
        }
    }
}

// MARK: - Folding screens

extension View {
    /// Tells the views inside whether they are on a screen that folds. Set
    /// once at the root: the fold's division region is reported even while
    /// the device is open flat, so the answer does not flicker with the pose.
    func detectsFoldableDisplay() -> some View {
        modifier(FoldableDisplayDetector())
    }
}

private struct FoldableDisplayDetector: ViewModifier {
    @State private var isFoldable = false
    @State private var foldRunsDown = false
    @State private var trailingOcclusion: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .environment(\.isFoldableDisplay, isFoldable)
            .environment(\.foldRunsDown, foldRunsDown)
            .onGeometryChange(for: Bool.self) { proxy in
                if #available(iOS 27.1, *) {
                    return proxy.reservedRegions(kind: .division, options: .includeInactive)
                        .contains { $0.frame.height > $0.frame.width }
                }
                return false
            } action: { foldRunsDown = $0 }
            .environment(\.trailingOcclusion, trailingOcclusion)
            .onGeometryChange(for: Bool.self) { proxy in
                if #available(iOS 27.1, *) {
                    return !proxy.reservedRegions(kind: .division, options: .includeInactive).isEmpty
                }
                return false
            } action: { isFoldable = $0 }
            .onGeometryChange(for: CGFloat.self) { proxy in
                if #available(iOS 27.1, *) {
                    return Self.trailingOcclusion(in: proxy)
                }
                return 0
            } action: { trailingOcclusion = $0 }
            #if DEBUG
            .onGeometryChange(for: String.self) { proxy in
                var lines = ["size \(proxy.size) safe \(proxy.safeAreaInsets)"]
                if #available(iOS 27.1, *) {
                    for kind in [ReservedRegion.Kind.occlusion, .division] {
                        for region in proxy.reservedRegions(kind: kind, options: .includeInactive, layoutDirectionBehavior: .fixed) {
                            lines.append("\(kind == .occlusion ? "occlusion" : "division") frame \(region.frame) margins \(region.margins) active \(region.isActive)")
                        }
                    }
                }
                return lines.joined(separator: " | ")
            } action: { print("🧭 [Layout] \($0)") }
            #endif
    }

    /// How far a camera in the top trailing corner reaches in from the edge -
    /// iPhone Duo's cover screen, where the camera and the status items stack
    /// down the right side and sat on top of the settings button. A camera
    /// centred at the top (the Dynamic Island) is not counted: the safe area
    /// already handles that.
    @available(iOS 27.1, *)
    nonisolated private static func trailingOcclusion(in proxy: GeometryProxy) -> CGFloat {
        let width = proxy.size.width
        let regions = proxy.reservedRegions(kind: .occlusion, layoutDirectionBehavior: .fixed)
        var inset: CGFloat = 0
        for region in regions where region.frame.minX > width * 0.7 && region.frame.minY < proxy.size.height * 0.3 {
            inset = max(inset, width - region.frame.minX + region.margins.leading)
        }
        return min(inset, width * 0.2)
    }
}

/// A grid of tiles at least `minimum` wide, as many columns as fit. On a
/// folding screen the count is kept even, so the fold runs between two
/// columns instead of through the middle of a cover - Apple's advice for
/// grids on iPhone Duo.
struct TileGrid<Content: View>: View {
    let minimum: CGFloat
    var maximum: CGFloat = .infinity
    let spacing: CGFloat
    var rowSpacing: CGFloat? = nil
    @ViewBuilder let content: () -> Content

    @Environment(\.isFoldableDisplay) private var isFoldable
    @Environment(\.foldRunsDown) private var foldRunsDown
    @State private var width: CGFloat = 0

    private var columns: [GridItem] {
        guard width > 0 else {
            return [GridItem(.adaptive(minimum: minimum, maximum: maximum), spacing: spacing, alignment: .top)]
        }
        var count = max(1, Int((width + spacing) / (minimum + spacing)))
        // An even count only where the fold runs down the screen, between
        // columns; in portrait it runs across, and dropping to an even count
        // there only left empty space at the sides.
        if isFoldable, foldRunsDown, count > 2, count % 2 == 1 { count -= 1 }
        // Columns fill the width: the count already keeps them between about
        // one and two minimums wide. A maximum left gaps at the sides, and a
        // hard minimum let a grid that had picked too many columns grow wider
        // than the screen - then measure itself that wide again, and never
        // correct.
        return Array(repeating: GridItem(.flexible(minimum: 40), spacing: spacing, alignment: .top), count: count)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: rowSpacing ?? spacing) {
            content()
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// An album, playlist or mix page. On a phone the header scrolls at the top
/// of the song list; on iPad and an unfolded foldable the header stays in a
/// column on the left and the songs fill the right, as Music does, so the
/// width is used instead of stretching one column across the screen.
struct DetailPage<Header: View, Rows: View>: View {
    @ViewBuilder let header: () -> Header
    @ViewBuilder let rows: () -> Rows

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.isFoldableDisplay) private var isFoldable
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The narrowest the songs column may be beside the header: at the
    /// accessibility text sizes iPhone Duo's upright 370 points cut every
    /// title to a word.
    private var minimumRowsWidth: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 480 : 340
    }

    var body: some View {
        if horizontalSizeClass == .regular {
            GeometryReader { geometry in
                if #available(iOS 27.1, *), isFoldable, Self.foldDividesPage(geometry) {
                    foldingSplit
                } else if geometry.size.width - Self.headerColumnWidth(for: geometry.size.width) >= minimumRowsWidth {
                    columns(width: geometry.size.width)
                } else {
                    // Too narrow for the header column beside the songs -
                    // iPhone Duo with the sidebar open, where the page gets
                    // 400 to 600 points and the songs were left a sliver
                    // showing only their "..." buttons. One column, and
                    // the phone's header too below about 520 points or at
                    // the accessibility text sizes, where the title and
                    // buttons beside the cover were cut to "Aléat...".
                    let isNarrow = geometry.size.width < 520 || dynamicTypeSize.isAccessibilitySize
                    singleColumn
                        .environment(\.horizontalSizeClass, isNarrow ? .compact : .regular)
                }
            }
        } else {
            singleColumn
        }
    }

    /// Phone: the header scrolls at the top of the song list.
    private var singleColumn: some View {
        list {
            Section {
                header()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            rows()
        }
    }

    /// The fold runs down through the page with room for a column on each
    /// side. Not the same as the page being wider than tall: with the sidebar
    /// open the page starts 280 points in, the fold sits 175 points from its
    /// edge, and splitting there squeezed the songs into a narrow strip.
    @available(iOS 27.1, *)
    private static func foldDividesPage(_ geometry: GeometryProxy) -> Bool {
        geometry.reservedRegions(kind: .division, options: .includeInactive).contains { fold in
            fold.frame.height > fold.frame.width
                && fold.frame.minX >= 300
                && geometry.size.width - fold.frame.maxX >= 300
        }
    }

    /// iPhone Duo held open like a book: the system splits the page at the
    /// fold - cover and buttons on one half, songs on the other.
    @available(iOS 27.1, *)
    private var foldingSplit: some View {
        ArrangementView {
            ScrollView {
                header()
                    .environment(\.isInDetailPanel, true)
                    .padding(.horizontal, Design.Spacing.xl)
                    .padding(.vertical, Design.Spacing.l)
            }
            .scrollIndicators(.hidden)
        } secondary: {
            list {
                rows()
            }
        }
        .arrangementViewStyle(.split.axes(.horizontal))
    }

    private static func headerColumnWidth(for width: CGFloat) -> CGFloat {
        min(440, max(300, width * 0.36))
    }

    private func columns(width: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                header()
                    .environment(\.isInDetailPanel, true)
                    .padding(.horizontal, Design.Spacing.xl)
                    .padding(.vertical, Design.Spacing.l)
            }
            .scrollIndicators(.hidden)
            .frame(width: Self.headerColumnWidth(for: width))

            list {
                rows()
            }
        }
    }

    private func list<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        List {
            content()
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Empty states

/// The app's empty state, built on the system's so it reads and scales like
/// every other app.
struct CosmosEmptyState: View {
    let systemImage: String
    let title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message { Text(message) }
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - Section header

/// A bold section title, optionally with a trailing control.
struct SectionTitle<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Design.Spacing.s)
            trailing()
        }
        .textCase(nil)
    }
}

extension View {
    /// A SectionTitle placed as a list's first row, so it scrolls away with
    /// the rows instead of staying pinned like a plain list's header.
    func songsTitleRow() -> some View {
        modifier(SongsTitleRow())
    }
}

private struct SongsTitleRow: ViewModifier {
    @Environment(\.pageMargin) private var margin

    func body(content: Content) -> some View {
        content
            .padding(.top, Design.Spacing.l)
            .listRowInsets(EdgeInsets(top: Design.Spacing.s, leading: margin, bottom: Design.Spacing.xs, trailing: margin))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .moveDisabled(true)
            .deleteDisabled(true)
    }
}

extension SectionTitle where Trailing == EmptyView {
    init(_ title: String) {
        self.title = title
        self.trailing = { EmptyView() }
    }
}

// MARK: - Formatting

enum DurationFormatter {
    /// "3:07", or "1:02:44" past an hour.
    static func string(milliseconds: Int?) -> String? {
        guard let milliseconds, milliseconds > 0 else { return nil }
        return string(seconds: TimeInterval(milliseconds) / 1000)
    }

    static func string(seconds: TimeInterval) -> String {
        let total = Int(seconds.isFinite ? max(0, seconds) : 0)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// "48 min" or "1 hr 12 min", for a whole album or playlist.
    static func totalLength(of tracks: [Track]) -> String? {
        let totalMs = tracks.reduce(0) { $0 + ($1.durationMs ?? 0) }
        guard totalMs > 0 else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = totalMs >= 3_600_000 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .short
        return formatter.string(from: TimeInterval(totalMs) / 1000)
    }
}

extension String {
    /// Files calls the device's own storage "On My iPhone" or "On My iPad";
    /// instructions written for an iPhone pointed iPad users at a place
    /// their Files app does not have.
    @MainActor var namingThisDevice: String {
        UIDevice.current.userInterfaceIdiom == .pad ? replacingOccurrences(of: "iPhone", with: "iPad") : self
    }
}

// MARK: - Toolbar

extension ToolbarContent {
    /// Drops the Liquid Glass capsule iOS 26 draws behind grouped toolbar
    /// buttons: the app keeps glass for the system's own chrome only.
    @ToolbarContentBuilder
    func cosmosPlainBackground() -> some ToolbarContent {
        if #available(iOS 26.0, *) {
            self.sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

// MARK: - Surfaces

enum SurfaceColor {
    /// A raised, opaque card: white on light, a lifted grey on dark.
    static let card = Color(UIColor { $0.userInterfaceStyle == .dark ? .secondarySystemBackground : .systemBackground })
    /// A filled button: light grey on light, a lifted grey on dark.
    static let control = Color(UIColor.secondarySystemBackground)
}

// MARK: - Scrolling

/// A horizontal shelf. Opts out of the bottom content margin the tab stacks
/// set for the floating bars - on a horizontal scroll view that margin would
/// add the bars' height of empty space under every shelf.
struct ShelfScrollView<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            content
        }
        .contentMargins(.bottom, 0, for: .scrollContent)
    }
}

extension View {
    /// The edges of a horizontal shelf. The inner spacing is a content
    /// margin, which iOS adds on top of the safe area - so the first card
    /// starts clear of an open sidebar instead of under it. Shadows may
    /// spill above and below, but the cards stop at the shelf's sides: on
    /// iPhone Duo the status items and camera sit in the right-hand safe
    /// area, and cards drawn past the edge ran under them.
    func shelfEdges() -> some View {
        modifier(ShelfEdges())
    }

    /// Stops a horizontal scroller's content at its own sides. A scroll view
    /// draws on into the safe area beside it, and on iPhone Duo the status
    /// items and camera sit in the right-hand one: Search's category chips
    /// and an artist's albums scrolled under the Wi-Fi indicator.
    func clipsShelfSides() -> some View {
        mask(Rectangle().padding(.vertical, -40))
    }
}

/// See `shelfEdges`: the first card on the page's margin, under the title.
private struct ShelfEdges: ViewModifier {
    @Environment(\.pageMargin) private var margin

    func body(content: Content) -> some View {
        content
            .contentMargins(.horizontal, margin, for: .scrollContent)
            .scrollClipDisabled()
            .clipsShelfSides()
    }
}

extension View {
    /// Debug builds only: `-cosmosDebugScrollBottom 1` scrolls to the end a
    /// few seconds after the screen appears, to check the last rows clear the
    /// floating bars.
    func debugScrollToBottom() -> some View {
        modifier(DebugScrollToBottom())
    }
}

private struct DebugScrollToBottom: ViewModifier {
    #if DEBUG
    @State private var position = ScrollPosition()
    #endif

    func body(content: Content) -> some View {
        #if DEBUG
        let offset = UserDefaults.standard.double(forKey: "cosmosDebugScrollY")
        if UserDefaults.standard.bool(forKey: "cosmosDebugScrollBottom") || offset > 0 {
            content
                .scrollPosition($position)
                .task {
                    try? await Task.sleep(for: .seconds(4))
                    // -cosmosDebugScrollY <points> stops partway down.
                    if offset > 0 {
                        position.scrollTo(y: offset)
                    } else {
                        position.scrollTo(edge: .bottom)
                    }
                }
        } else {
            content
        }
        #else
        content
        #endif
    }
}
