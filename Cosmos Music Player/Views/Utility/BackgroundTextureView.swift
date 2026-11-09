import SwiftUI
import Combine
import UIKit
import UIKit.UIGestureRecognizerSubclass

enum ScreenType {
    case library
    case albums
    case albumDetail
    case artists
    case artistDetail
    case playlists
    case playlistDetail
    case allSongs
    case likedSongs
    case player
    case miniPlayer
}

/// The Cosmos halo behind every screen.
///
/// Same lines as always - each screen keeps its own diagonal, from the same
/// corner to the same edge - drawn the modern way: instead of a hard band
/// blurred until its edges disappear, the light falls off smoothly across the
/// line (a bell curve), with a fainter, wider glow underneath for depth, and
/// the whole thing drifts very slowly so the screen feels alive rather than
/// printed. Still with Reduce Motion, softer with Reduce Transparency.
struct ScreenSpecificBackgroundView: View {
    let screen: ScreenType

    var body: some View {
        HaloBackground(line: HaloLine(for: screen))
    }
}

/// Where a screen's halo runs, in unit coordinates of the screen.
struct HaloLine: Equatable {
    var start: UnitPoint
    var end: UnitPoint

    init(start: UnitPoint, end: UnitPoint) {
        self.start = start
        self.end = end
    }

    /// The lines the screens have always used.
    init(for screen: ScreenType) {
        switch screen {
        case .library, .miniPlayer:
            self.init(start: .topLeading, end: UnitPoint(x: 1, y: 0.5))
        case .albums, .albumDetail, .playlists, .playlistDetail:
            self.init(start: .bottomLeading, end: UnitPoint(x: 1, y: 0.5))
        case .allSongs:
            self.init(start: .topTrailing, end: UnitPoint(x: 0, y: 0.5))
        case .artists, .artistDetail, .likedSongs:
            self.init(start: .bottomTrailing, end: UnitPoint(x: 0, y: 0.5))
        case .player:
            self.init(start: UnitPoint(x: 0, y: 0.7), end: UnitPoint(x: 1, y: 0.2))
        }
    }
}

/// The look of the halo, chosen in Settings.
enum HaloStyle: String, CaseIterable, Identifiable {
    /// Ribbons of light with a fine sheen line, slowly flowing.
    case silk
    /// Wide, soft curtains of colour, no lines.
    case aurora
    /// Fine diagonal lines with a faint glow.
    case lines
    /// The original: one still, soft band across the diagonal.
    case classic
    /// A soft glow from one corner.
    case glow
    /// No halo: the plain system background.
    case none

    static let storageKey = "cosmos.haloStyle"
    static let motionKey = "cosmos.haloMotion"
    /// True for the small bands (the original size); the default spreads
    /// them across most of the screen.
    static let miniKey = "cosmos.haloMini"
    /// The shape of the full-size course: 0 picks one at random on each
    /// screen and launch, 1-3 always use that one.
    static let formKey = "cosmos.haloForm"
    static let formCount = 3

    var id: String { rawValue }

    var title: String {
        switch self {
        case .silk: return Localized.haloSilk
        case .aurora: return Localized.haloAurora
        case .lines: return Localized.haloLines
        case .classic: return Localized.haloClassic
        case .glow: return Localized.haloGlow
        case .none: return Localized.haloNone
        }
    }
}

struct HaloBackground: View {
    let line: HaloLine
    /// Overrides the accent colour (the player tints its halo from the artwork).
    var color: Color? = nil
    /// Draw only the halo, over a background supplied by the caller.
    var transparentBase = false
    /// Scales the halo's strength, for places that need it quieter.
    var intensityScale: Double = 1

    /// Overrides the Settings choice, for the previews in Settings.
    var styleOverride: HaloStyle? = nil
    /// Overrides the Settings shape (0 random, 1-3), for the shape previews.
    var formOverride: Int? = nil
    /// Overrides the Settings size, for the shape previews.
    var miniOverride: Bool? = nil
    /// Whether this halo may move at all. Settings shows six previews at
    /// once; only the selected one needs to animate.
    var animates = true

    @ObservedObject private var theme = ThemeStore.shared
    @AppStorage(HaloStyle.storageKey) private var storedStyle: HaloStyle = .silk
    @AppStorage(HaloStyle.miniKey) private var storedMini = false
    @AppStorage(HaloStyle.formKey) private var storedForm = 0
    private var isMini: Bool { miniOverride ?? storedMini }
    /// Drawn once per appearance: with Random, each screen opened gets its
    /// own course, and keeps it while it is shown.
    @State private var courseSeed = UInt64.random(in: 0...UInt64.max)
    private var form: Int { formOverride ?? storedForm }
    @AppStorage(HaloStyle.motionKey) private var allowsMotion = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    @State private var isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var isHot = HaloBackground.isThermallyConstrained
    @ObservedObject private var activity = HaloActivity.shared

    private var style: HaloStyle { styleOverride ?? storedStyle }
    /// Low Power Mode holds the halo still too: the drift is decoration, and
    /// a full-screen animation that never stops is exactly what the user
    /// asked the phone to stop doing.
    /// A phone that is already hot gets the same treatment: the halo is
    /// constant GPU work, and shedding it is cheaper than iOS throttling
    /// the audio decode or the UI.
    private var isStill: Bool { reduceMotion || !allowsMotion || isLowPower || isHot || !animates }

    private static var isThermallyConstrained: Bool {
        ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    }
    /// Nothing to animate for while the halo cannot be seen: the app is
    /// inactive or in the background, or the screen it belongs to is
    /// covered by a pushed one, another tab or the player. It used to keep
    /// redrawing at 30 fps underneath all of them.
    ///
    /// Also still once nobody has touched the app for a while (see
    /// `HaloActivity`): an untouched screen - Home left open, the player
    /// watched while listening - drew it for nothing.
    private var isPaused: Bool { scenePhase != .active || !isVisible || activity.isIdle }

    /// The drift is a few points a second - under a point and a half per
    /// frame at 15 fps even on an iPad's short side, on a band blurred by
    /// tens of points - so 15 frames a second still reads as continuous.
    /// Measured on the iPad simulator (app + render server, idle Home):
    /// 30 fps full-resolution ~38% of a core, 20 fps ~31%, 15 fps ~22%.
    private static let frameInterval: TimeInterval = 1.0 / 15
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var intensity: Double {
        let base = (colorScheme == .dark ? 0.55 : 0.40) * intensityScale
        return reduceTransparency ? base * 0.5 : base
    }

    var body: some View {
        ZStack {
            if !transparentBase {
                Color(.systemBackground)
            }

            if style != .none {
                // A new colour - the next song's artwork - blends from the
                // old one. (Cross-fading two halos dimmed through the middle.)
                InterpolatedColor(color ?? theme.accent) { color in
                    haloLayer(color)
                }
                .animation(.easeInOut(duration: 0.9), value: color ?? theme.accent)

                // Fine film grain: breaks up gradient banding and makes the glow
                // read as light rather than a flat fill.
                FilmGrain()
                    .opacity(colorScheme == .dark ? 0.07 : 0.05)
                    .blendMode(.overlay)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            isVisible = true
            // Opening a screen counts as using the app.
            HaloActivity.shared.noteActivity()
        }
        .onDisappear { isVisible = false }
        .onReceive(
            NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
                .receive(on: RunLoop.main)
        ) { _ in
            isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .onReceive(
            NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
                .receive(on: RunLoop.main)
        ) { _ in
            isHot = Self.isThermallyConstrained
        }
    }

    private func haloLayer(_ color: Color) -> some View {
        GeometryReader { geometry in
            if isStill {
                HaloSilk(style: style, isMini: isMini, form: form, courseSeed: courseSeed, line: line, color: color, intensity: intensity, isDark: colorScheme == .dark, size: geometry.size, phase: 0)
            } else {
                TimelineView(.animation(minimumInterval: Self.frameInterval, paused: isPaused)) { context in
                    // One event per drawn frame: Points of Interest then shows
                    // the halo's real frame rate, and that it stops when hidden.
                    let _ = Perf.event("Halo frame")
                    HaloSilk(
                        style: style,
                        isMini: isMini,
                        form: form,
                        courseSeed: courseSeed,
                        line: line,
                        color: color,
                        intensity: intensity,
                        isDark: colorScheme == .dark,
                        size: geometry.size,
                        // The drift clock, not the wall clock: it stands
                        // still while the app is idle, so the halo picks up
                        // where it stopped instead of jumping ahead.
                        phase: activity.driftTime(at: context.date)
                    )
                }
            }
        }
    }
}

/// Hands its content a colour that animates channel by channel, so a change
/// passes through the colours in between rather than through a fade.
private struct InterpolatedColor<Content: View>: View, @MainActor Animatable {
    var components: AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>>
    let content: (Color) -> Content

    init(_ color: Color, @ViewBuilder content: @escaping (Color) -> Content) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        components = AnimatablePair(AnimatablePair(red, green), AnimatablePair(blue, alpha))
        self.content = content
    }

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>> {
        get { components }
        set { components = newValue }
    }

    var body: some View {
        content(Color(
            .sRGB,
            red: components.first.first,
            green: components.first.second,
            blue: components.second.first,
            opacity: components.second.second
        ))
    }
}

/// The halo as silk: three ribbons of light flowing along the screen's
/// diagonal. Each ribbon is a band whose width swells and narrows as if the
/// fabric were turning, drawn twice - once heavily blurred for the glow,
/// once as a fine sheen line along its edge - so the screen keeps the
/// diagonal "lines" of the original halo, now soft and moving.
private struct HaloSilk: View {
    let style: HaloStyle
    /// The original, smaller bands; otherwise they spread across most of
    /// the screen.
    let isMini: Bool
    /// 0 random, 1-3 a chosen shape.
    var form: Int = 0
    /// Picks the random course (and shape, with Random).
    var courseSeed: UInt64 = 0
    let line: HaloLine
    let color: Color
    let intensity: Double
    let isDark: Bool
    let size: CGSize
    let phase: TimeInterval

    private struct Ribbon {
        /// Offset across the diagonal, in units of the screen's short side.
        let offset: CGFloat
        /// Widest point, in units of the short side.
        let width: CGFloat
        let hueShift: CGFloat
        let speed: Double
        let seed: Double
        let strength: Double
    }

    private static let silk = [
        Ribbon(offset: 0, width: 0.30, hueShift: 0, speed: 0.20, seed: 0, strength: 1),
        Ribbon(offset: -0.16, width: 0.18, hueShift: -0.05, speed: 0.15, seed: 2.1, strength: 0.7),
        Ribbon(offset: 0.15, width: 0.14, hueShift: 0.06, speed: 0.25, seed: 4.3, strength: 0.55),
    ]

    private static let aurora = [
        Ribbon(offset: 0, width: 0.6, hueShift: 0, speed: 0.22, seed: 0, strength: 0.9),
        Ribbon(offset: -0.3, width: 0.4, hueShift: -0.08, speed: 0.17, seed: 1.7, strength: 0.6),
        Ribbon(offset: 0.32, width: 0.36, hueShift: 0.09, speed: 0.27, seed: 3.9, strength: 0.5),
    ]

    // Three lines, evenly spaced and calm: six read as busy.
    private static let lines = (0..<3).map { index in
        Ribbon(offset: CGFloat(index) * 0.08 - 0.08, width: 0.05, hueShift: CGFloat(index) * 0.02 - 0.02,
               speed: 0.12, seed: Double(index) * 0.4, strength: 1 - Double(index) * 0.15)
    }

    private static let classic = [
        Ribbon(offset: 0, width: 0.5, hueShift: 0, speed: 0, seed: 0, strength: 0.85),
    ]

    private var baseRibbons: [Ribbon] {
        switch style {
        case .silk: return Self.silk
        case .aurora: return Self.aurora
        case .lines: return Self.lines
        case .classic: return Self.classic
        case .glow, .none: return []
        }
    }

    /// The same fine ribbons at either size; at full size they follow a
    /// long winding path across the whole screen instead of one diagonal.
    private var ribbons: [Ribbon] { baseRibbons }

    /// Blur of the glow, in units of the short side.
    private var glowBlur: CGFloat {
        // Full size keeps the bands crisper, so the winding course reads.
        if !isMini {
            switch style {
            case .lines: return 0.03
            // Classic is the soft one: its course melts into the screen.
            case .classic: return 0.11
            default: return 0.035
            }
        }
        switch style {
        case .aurora: return 0.08
        case .lines: return 0.04
        case .classic: return 0.12
        default: return 0.07
        }
    }

    /// The fine lines keep their mini width at full size - that finesse is
    /// the point; only Lines, where the lines are the whole pattern, are
    /// drawn a little bolder.
    private var sheenWidth: CGFloat {
        style == .lines && !isMini ? 1.5 : 1
    }

    /// Strength of the fine line along each ribbon; none for the soft styles.
    private var sheenStrength: Double {
        switch style {
        case .silk: return isDark ? 0.45 : 0.35
        case .lines: return isDark ? 0.9 : 0.75
        default: return 0
        }
    }

    /// The bands fill properly now (they were open outlines that only
    /// showed where they curved), so the soft styles are drawn quieter.
    private var glowStrength: Double {
        switch style {
        case .lines: return 0.3
        // The winding course spreads the same light over far more of the
        // screen, so it is drawn stronger to read as clearly as the mini.
        // Silk's narrow ribbon concentrates its colour, so it stays softer.
        case .silk: return isMini ? 0.7 : 0.6
        // Aurora at full size: a light veil, not a block of colour.
        case .aurora: return isMini ? 0.7 : 0.55
        default: return isMini ? 1 : 1.3
        }
    }

    /// The glow is drawn at a quarter of the screen's size and scaled up.
    /// It is blurred by tens of points, so it holds no detail a quarter-size
    /// bitmap would lose - but filling and blurring a full-resolution,
    /// full-screen layer every frame was most of the halo's GPU cost.
    private static let glowDownscale: CGFloat = 4

    var body: some View {
        let short = max(min(size.width, size.height), 1)
        if style == .glow {
            Canvas { context, canvasSize in
                drawCornerGlow(in: &context, size: canvasSize, short: short)
            }
            .drawingGroup()
        } else {
            // Each ribbon's outline once per frame, shared by glow and sheen.
            let geometries = ribbons.map { band(for: $0, short: short, in: size) }
            let tone = HaloTone(color)
            ZStack(alignment: .topLeading) {
                glowLayer(geometries, tone: tone, short: short)
                if sheenStrength > 0 {
                    sheenLayer(geometries, tone: tone)
                }
            }
        }
    }

    private typealias BandGeometry = (band: Path, edge: Path, from: CGPoint, to: CGPoint)

    private func glowLayer(_ geometries: [BandGeometry], tone: HaloTone, short: CGFloat) -> some View {
        let scale = Self.glowDownscale
        let shrink = CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)
        return Canvas { context, _ in
            var glow = context
            glow.addFilter(.blur(radius: short * glowBlur / scale))
            if isDark { glow.blendMode = .plusLighter }
            for (ribbon, geometry) in zip(ribbons, geometries) {
                glow.fill(geometry.band.applying(shrink), with: .linearGradient(
                    gradient(for: ribbon, tone: tone, opacity: intensity * ribbon.strength * glowStrength),
                    startPoint: geometry.from.applying(shrink), endPoint: geometry.to.applying(shrink)
                ))
            }
        }
        .frame(width: size.width / scale, height: size.height / scale)
        // Rasterise at the small size first, then scale the bitmap up.
        .drawingGroup()
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// The sheen: a fine, slightly softened line along each ribbon. Sharp
    /// enough that it has to stay at full resolution.
    private func sheenLayer(_ geometries: [BandGeometry], tone: HaloTone) -> some View {
        Canvas { context, _ in
            var sheen = context
            sheen.addFilter(.blur(radius: style == .lines ? 0.8 : 1.2))
            for (ribbon, geometry) in zip(ribbons, geometries) {
                sheen.stroke(geometry.edge, with: .linearGradient(
                    gradient(for: ribbon, tone: tone, opacity: intensity * ribbon.strength * sheenStrength, lighten: true),
                    startPoint: geometry.from, endPoint: geometry.to
                ), lineWidth: sheenWidth)
            }
        }
        .drawingGroup()
    }

    /// A soft pool of light from where the screen's line starts.
    private func drawCornerGlow(in context: inout GraphicsContext, size canvas: CGSize, short: CGFloat) {
        // Breathing: the pool swells and dims over about twelve seconds, and
        // drifts a little off its corner.
        let breath = sin(phase * 0.5)
        let centre = CGPoint(
            x: line.start.x * canvas.width + CGFloat(sin(phase * 0.13)) * short * 0.08,
            y: line.start.y * canvas.height + CGFloat(cos(phase * 0.11)) * short * 0.08
        )
        let radius = max(canvas.width, canvas.height) * (0.75 + 0.06 * CGFloat(breath))
        let intensity = self.intensity * (0.82 + 0.18 * breath)
        let rect = CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: rect), with: .radialGradient(
            Gradient(stops: [
                .init(color: color.opacity(intensity * 0.9), location: 0),
                .init(color: color.opacity(intensity * 0.35), location: 0.45),
                .init(color: color.opacity(0), location: 1),
            ]),
            center: centre, startRadius: 0, endRadius: radius
        ))
    }

    /// The ribbon's colour along its length: transparent at both ends, so it
    /// enters and leaves the screen without an edge.
    private func gradient(for ribbon: Ribbon, tone base: HaloTone, opacity: Double, lighten: Bool = false) -> Gradient {
        let hue = base.hue, saturation = base.saturation, brightness = base.brightness
        func tone(_ shift: CGFloat, _ alpha: Double) -> Color {
            var h = hue + ribbon.hueShift + shift
            h -= floor(h)
            let lift: CGFloat = lighten ? 0.25 : 0
            return Color(UIColor(
                hue: h,
                saturation: max(0, saturation * (lighten ? 0.6 : 1)),
                brightness: min(1, brightness + lift),
                alpha: 1
            )).opacity(alpha)
        }
        let drift = CGFloat(sin(phase * 0.1 + ribbon.seed)) * 0.03
        if style == .aurora {
            // Curtains: bright folds travel slowly along each band, the way
            // an aurora ripples, instead of one even wash.
            return Gradient(stops: (0...12).map { step in
                let location = Double(step) / 12
                // Full size: bright along almost the whole run, which now
                // spans the screen; mini: brightest in the middle.
                let envelope = isMini ? sin(location * .pi) : min(1, sin(location * .pi) * 2.2)
                let fold = 0.45 + 0.55 * (0.5 + 0.5 * sin(location * 16 - phase * 0.7 + ribbon.seed * 3))
                return .init(color: tone(CGFloat(location - 0.5) * 0.12 + drift, opacity * envelope * fold), location: location)
            })
        }
        // Fading over the first and last quarter suits one ribbon across the
        // middle; repeated across the screen, the ribbons run far longer and
        // that fade left most of the screen dim - so they hold their
        // brightness until close to the ends.
        let rise = isMini ? 0.25 : 0.12
        return Gradient(stops: [
            .init(color: tone(-0.04 + drift, 0), location: 0),
            .init(color: tone(-0.02 + drift, opacity * 0.8), location: rise),
            .init(color: tone(drift, opacity), location: 0.5),
            .init(color: tone(0.03 + drift, opacity * 0.8), location: 1 - rise),
            .init(color: tone(0.05 + drift, 0), location: 1),
        ])
    }

    private func band(for ribbon: Ribbon, short: CGFloat, in canvas: CGSize) -> BandGeometry {
        if !isMini { return windingBand(for: ribbon, short: short, in: canvas) }
        let start = CGPoint(x: line.start.x * canvas.width, y: line.start.y * canvas.height)
        let end = CGPoint(x: line.end.x * canvas.width, y: line.end.y * canvas.height)
        let dx = end.x - start.x, dy = end.y - start.y
        let length = max(hypot(dx, dy), 1)
        let unit = CGPoint(x: dx / length, y: dy / length)
        let normal = CGPoint(x: -unit.y, y: unit.x)
        // Run past both ends so the ribbon fades out off screen.
        let extra = length * 0.2
        let extendedStart = CGPoint(x: start.x - unit.x * extra, y: start.y - unit.y * extra)
        let span = length + extra * 2

        let time = phase * ribbon.speed + ribbon.seed
        let steps = 72
        var upper: [CGPoint] = []
        var lower: [CGPoint] = []
        var centre: [CGPoint] = []
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let along = span * t
            // A slow wave across the diagonal, and a width that swells and
            // pinches as if the silk were twisting.
            // Long, slow curves: on a wide screen short waves read as kinks.
            let wave: CGFloat
            if style == .classic {
                // The original straight band, swaying slowly as a whole.
                wave = CGFloat(sin(phase * 0.12)) * short * 0.06
            } else {
                let waveScale: CGFloat = style == .lines ? 0.7 : style == .aurora ? 1.4 : 1
                wave = (CGFloat(sin(Double(t) * 3.0 + time)) * short * 0.09
                    + CGFloat(sin(Double(t) * 1.3 - time * 0.6)) * short * 0.06) * waveScale
            }
            let across = ribbon.offset * short + wave
            let twist: CGFloat
            switch style {
            case .silk: twist = 0.35 + 0.65 * abs(CGFloat(sin(Double(t) * 2.6 + time * 0.8)))
            case .aurora: twist = 0.7 + 0.3 * CGFloat(sin(Double(t) * 2 + time * 0.7))
            case .classic: twist = 1 + 0.1 * CGFloat(sin(phase * 0.18))
            default: twist = 1
            }
            let halfWidth = ribbon.width * short * 0.5 * twist
            let c = CGPoint(
                x: extendedStart.x + unit.x * along + normal.x * across,
                y: extendedStart.y + unit.y * along + normal.y * across
            )
            centre.append(c)
            upper.append(CGPoint(x: c.x + normal.x * halfWidth, y: c.y + normal.y * halfWidth))
            lower.append(CGPoint(x: c.x - normal.x * halfWidth, y: c.y - normal.y * halfWidth))
        }

        // One closed outline: `addLines` twice would start a second
        // subpath, leaving two open lines with no area between them.
        var band = Path()
        band.move(to: upper[0])
        for point in upper.dropFirst() { band.addLine(to: point) }
        for point in lower.reversed() { band.addLine(to: point) }
        band.closeSubpath()

        var edge = Path()
        edge.addLines(upper)

        return (band, edge, extendedStart, CGPoint(x: extendedStart.x + unit.x * span, y: extendedStart.y + unit.y * span))
    }
}

extension HaloSilk {
    /// The bends of a style's course, in unit coordinates - random, drawn
    /// from a seed each screen picks when it appears, so every screen opened
    /// moves its own way and keeps it while shown. Each style keeps its own
    /// character:
    /// Silk falls down the screen in wide S-turns, Lines sweeps across it in
    /// long arcs, Aurora drifts sideways along the top half, Classic makes
    /// one slow, gentle curve.
    private static func course(for style: HaloStyle, line: HaloLine, form chosen: Int, seed: UInt64) -> [CGPoint] {
        let salt: UInt64
        switch style {
        case .silk: salt = 11
        case .lines: salt = 23
        case .aurora: salt = 37
        default: salt = 53
        }
        let screen = UInt64(line.start.x * 7 + line.start.y * 13 + line.end.x * 17 + line.end.y * 19)
        var random = SeededGenerator(seed: seed ^ (salt &* 0x9E37_79B9) ^ (screen &* 0x85EB_CA6B))
        func value(_ range: ClosedRange<CGFloat>) -> CGFloat { CGFloat.random(in: range, using: &random) }

        // Each style has a few forms, picked at random like the bends.
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        let randomForm = Int.random(in: 0..<HaloStyle.formCount, using: &random)
        let form = (1...HaloStyle.formCount).contains(chosen) ? chosen - 1 : randomForm
        let flip = Bool.random(using: &random)
        var points: [CGPoint]
        switch (style, form) {
        case (.silk, 0):
            // Down the screen in wide S-turns.
            points = [p(-0.15, value(-0.1...0.05)), p(value(0.68...0.85), value(0.18...0.28)),
                      p(value(0.15...0.32), value(0.45...0.55)), p(value(0.68...0.85), value(0.72...0.82)),
                      p(1.15, value(0.95...1.1))]
        case (.silk, 1):
            // Across the screen in wide S-turns, up and down.
            points = [p(-0.15, value(0.15...0.3)), p(value(0.25...0.35), value(0.7...0.82)),
                      p(value(0.5...0.6), value(0.2...0.32)), p(value(0.75...0.85), value(0.68...0.8)),
                      p(1.15, value(0.25...0.4))]
        case (.silk, _):
            // Corner to corner, rippling gently.
            points = [p(-0.15, value(-0.1...0.05)), p(value(0.25...0.35), value(0.25...0.35)),
                      p(value(0.45...0.55), value(0.4...0.5)), p(value(0.65...0.75), value(0.62...0.72)),
                      p(1.15, value(0.95...1.1))]
        case (.lines, 0):
            // A long, shallow wave straight across.
            let centre = value(0.3...0.7)
            points = [p(-0.2, centre + value(-0.1...0.1)), p(0.25, centre - 0.1), p(0.5, centre + 0.08),
                      p(0.75, centre - 0.08), p(1.2, centre + value(-0.1...0.1))]
        case (.lines, 1):
            // One long arc from a lower corner up across the screen.
            points = [p(-0.2, value(0.75...0.95)), p(value(0.35...0.5), value(0.35...0.5)), p(1.2, value(0.05...0.25))]
        case (.lines, _):
            // A swoosh: down, a broad turn, and away.
            points = [p(value(0.1...0.3), -0.15), p(value(0.3...0.45), value(0.45...0.55)),
                      p(value(0.65...0.8), value(0.68...0.78)), p(1.2, value(0.6...0.75))]
        case (.aurora, 0):
            // Curtains waving right across the screen, top to bottom.
            points = [p(-0.2, value(0.1...0.2)), p(0.25, value(0.45...0.55)), p(0.5, value(0.2...0.3)),
                      p(0.75, value(0.7...0.8)), p(1.2, value(0.45...0.6))]
        case (.aurora, 1):
            // One broad sweep from a top corner to the opposite bottom one.
            points = [p(-0.2, value(-0.05...0.1)), p(0.35, value(0.3...0.4)), p(0.65, value(0.6...0.7)), p(1.2, value(0.95...1.1))]
        case (.aurora, _):
            // Two soft waves across the upper half.
            points = [p(-0.2, value(0.3...0.4)), p(0.3, value(0.15...0.22)), p(0.65, value(0.38...0.45)), p(1.2, value(0.2...0.3))]
        case (_, 0):
            // Classic: one slow curve corner to corner.
            points = [p(-0.15, value(-0.1...0.15)), p(value(0.35...0.65), value(0.4...0.6)), p(1.15, value(0.85...1.1))]
        case (_, 1):
            // Classic: corner to corner in one gentle S.
            points = [p(-0.15, value(-0.1...0.05)), p(value(0.3...0.4), value(0.38...0.45)),
                      p(value(0.6...0.7), value(0.55...0.62)), p(1.15, value(0.95...1.1))]
        default:
            // Classic: a broad arc bowing out from the top across to the
            // bottom of the far side.
            points = [p(-0.15, value(0.05...0.2)), p(value(0.55...0.7), value(0.2...0.3)), p(value(0.85...0.95), value(0.6...0.7)), p(value(0.75...0.9), 1.15)]
        }
        if flip { points = points.map { CGPoint(x: 1 - $0.x, y: $0.y) } }
        return points
    }

    /// Full size: the ribbons keep their mini fineness but run one long,
    /// continuous course that winds back and forth down the whole screen -
    /// turning, like a ribbon dropped from above - instead of crossing it
    /// once. The bends drift slowly, so the path itself is alive. Each
    /// screen's own diagonal decides which corner it starts from, so the
    /// screens still differ.
    private func windingBand(for ribbon: Ribbon, short: CGFloat, in canvas: CGSize) -> BandGeometry {
        let w = canvas.width, h = canvas.height
        let time = phase * ribbon.speed + ribbon.seed
        let slow = phase * 0.05
        let controls = Self.course(for: style, line: line, form: form, seed: courseSeed).enumerated().map { index, point -> CGPoint in
            // Each bend breathes a little over time, so the path is alive.
            let x = point.x + CGFloat(sin(slow + Double(index) * 1.7)) * 0.05
            let y = point.y + CGFloat(cos(slow * 0.8 + Double(index) * 2.3)) * 0.03
            return CGPoint(x: x * w, y: y * h)
        }
        func curve(_ t: CGFloat) -> CGPoint {
            // Catmull-Rom through the bends: smooth turns, no corners.
            let segments = CGFloat(controls.count - 1)
            let position = min(max(t, 0), 1) * segments
            let i = min(Int(position), controls.count - 2)
            let u = position - CGFloat(i)
            let p0 = controls[max(i - 1, 0)], p1 = controls[i], p2 = controls[i + 1], p3 = controls[min(i + 2, controls.count - 1)]
            func blend(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
                0.5 * ((2 * b) + (-a + c) * u + (2 * a - 5 * b + 4 * c - d) * u * u + (-a + 3 * b - 3 * c + d) * u * u * u)
            }
            return CGPoint(x: blend(p0.x, p1.x, p2.x, p3.x), y: blend(p0.y, p1.y, p2.y, p3.y))
        }

        let steps = 220
        var upper: [CGPoint] = []
        var lower: [CGPoint] = []
        upper.reserveCapacity(steps + 1)
        lower.reserveCapacity(steps + 1)
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let c = curve(t)
            let ahead = curve(min(t + 0.004, 1)), behind = curve(max(t - 0.004, 0))
            let tx = ahead.x - behind.x, ty = ahead.y - behind.y
            let length = max(hypot(tx, ty), 0.0001)
            let normal = CGPoint(x: -ty / length, y: tx / length)
            // The strands of one style travel together, side by side, with
            // a gentle ripple of their own.
            // Lines stay smooth and parallel; the softer styles ripple.
            let ripple = style == .classic || style == .lines ? 0 : CGFloat(sin(Double(t) * 18 + time)) * short * 0.012
            let across = ribbon.offset * short * 0.55 + ripple
            let twist: CGFloat
            switch style {
            case .silk: twist = 0.35 + 0.65 * abs(CGFloat(sin(Double(t) * 9 + time * 0.8)))
            case .aurora: twist = 0.7 + 0.3 * CGFloat(sin(Double(t) * 7 + time * 0.7))
            default: twist = 1
            }
            // Aurora's and Classic's bands are wide by nature; along a long
            // course they are kept a little narrower so the turns read.
            let narrowing: CGFloat = style == .aurora ? 0.7 : style == .classic ? 0.85 : 1
            let halfWidth = ribbon.width * narrowing * short * 0.5 * twist
            let centre = CGPoint(x: c.x + normal.x * across, y: c.y + normal.y * across)
            upper.append(CGPoint(x: centre.x + normal.x * halfWidth, y: centre.y + normal.y * halfWidth))
            lower.append(CGPoint(x: centre.x - normal.x * halfWidth, y: centre.y - normal.y * halfWidth))
        }

        var band = Path()
        band.move(to: upper[0])
        for point in upper.dropFirst() { band.addLine(to: point) }
        for point in lower.reversed() { band.addLine(to: point) }
        band.closeSubpath()
        var edge = Path()
        edge.addLines(upper)
        // The colour runs from one end of the course to the other.
        return (band, edge, curve(0), curve(1))
    }
}

/// A colour as hue, saturation and brightness, converted once per frame
/// rather than once per gradient (it goes through UIColor each time).
private struct HaloTone {
    var hue: CGFloat = 0
    var saturation: CGFloat = 0
    var brightness: CGFloat = 0

    init(_ color: Color) {
        var alpha: CGFloat = 0
        UIColor(color).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
    }
}

/// A tile of random monochrome noise, generated once.
struct FilmGrain: View {
    private static let tile: UIImage = {
        let side = 128
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        var generator = SystemRandomNumberGenerator()
        for i in 0..<(side * side) {
            let value = UInt8.random(in: 0...255, using: &generator)
            pixels[i * 4] = value
            pixels[i * 4 + 1] = value
            pixels[i * 4 + 2] = value
            pixels[i * 4 + 3] = 255
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        return UIImage(cgImage: image, scale: 2, orientation: .up)
    }()

    var body: some View {
        Image(uiImage: Self.tile)
            .resizable(resizingMode: .tile)
    }
}

/// A page lit by its own artwork, as Music colours an album page: a wash of
/// the cover's colour at the top fading into the background, and the halo in
/// the same colour. A cover with no real colour gets a quiet grey instead of
/// the theme, so the page still belongs to the album.
struct ArtworkBackground: View {
    let image: UIImage?
    let line: HaloLine

    @Environment(\.colorScheme) private var colorScheme
    @State private var tint: Color?

    var body: some View {
        ZStack(alignment: .top) {
            Color(.systemBackground)
            if let tint {
                LinearGradient(
                    colors: [tint.opacity(colorScheme == .dark ? 0.45 : 0.3), tint.opacity(0)],
                    startPoint: .top,
                    endPoint: UnitPoint(x: 0.5, y: 0.6)
                )
                .transition(.opacity)
            }
            HaloBackground(line: line, color: tint ?? Color(white: 0.6), transparentBase: true, intensityScale: 0.8)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(.easeInOut(duration: 0.5), value: tint)
        .task(id: image.map(ObjectIdentifier.init)) {
            guard let image else { tint = nil; return }
            let palette = await PlayerPalette.make(from: image, fallback: .gray)
            // artworkAccent is white when the cover is nearly grey.
            tint = palette.artworkAccent == .white ? Color(white: 0.6) : palette.artworkAccent
        }
    }
}

// MARK: - Idle

/// Whether the app is being used, for the halo: it drifts for
/// `idleDelay` after the last touch or screen change, then holds still until
/// the next one. Measured on an iPhone 16e, the drift was nearly all of an
/// idle screen's processor use - 9.5% of a core moving, 0.1% still - and a
/// screen nobody touches (Home left open, the player watched while
/// listening) gains nothing from it.
@MainActor
final class HaloActivity: ObservableObject {
    static let shared = HaloActivity()
    static let idleDelay: TimeInterval = 30

    @Published private(set) var isIdle = false
    private var lastActivity = Date()
    private var idleSince: Date?
    /// Time spent idle so far, taken off the drift clock.
    private var idleTotal: TimeInterval = 0
    private var idleTimer: Timer?

    private init() {
        // Coming back to the app counts too: unlocking onto Cosmos involves
        // no touch inside it.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in HaloActivity.shared.noteActivity() }
        }
    }

    /// A touch, or a screen opening. Cheap: called on every touch.
    func noteActivity() {
        let now = Date()
        lastActivity = now
        if isIdle {
            if let idleSince { idleTotal += now.timeIntervalSince(idleSince) }
            idleSince = nil
            isIdle = false
        }
        scheduleIdleCheck()
    }

    /// Seconds for the halo's drift: wall-clock time without the idle spells,
    /// frozen at the moment the current one began.
    func driftTime(at date: Date) -> TimeInterval {
        let effective = idleSince.map { min(date, $0) } ?? date
        return effective.timeIntervalSinceReferenceDate - idleTotal
    }

    private func scheduleIdleCheck() {
        guard idleTimer == nil else { return }
        let timer = Timer(fire: lastActivity.addingTimeInterval(Self.idleDelay), interval: 0, repeats: false) { _ in
            Task { @MainActor in HaloActivity.shared.checkIdle() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    private func checkIdle() {
        idleTimer = nil
        // Touched since the timer was set: wait out the rest from then.
        if lastActivity.addingTimeInterval(Self.idleDelay).timeIntervalSinceNow > 0.5 {
            scheduleIdleCheck()
            return
        }
        idleSince = Date()
        isIdle = true
    }

    /// Watches every window of every scene for touches, without taking part
    /// in them. Call when a scene's root appears.
    func watchTouches() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows
            where !(window.gestureRecognizers ?? []).contains(where: { $0 is ActivityTouchRecognizer }) {
                window.addGestureRecognizer(ActivityTouchRecognizer())
            }
        }
        noteActivity()
    }
}

/// Sees each touch begin and steps aside at once: it never recognises, never
/// cancels or delays a touch, and lets every other gesture run alongside.
private final class ActivityTouchRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        HaloActivity.shared.noteActivity()
        state = .failed
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
