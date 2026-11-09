//
//  LyricsView.swift
//  Cosmos Music Player
//
//  Lyrics display with synchronized, tappable scrolling
//

import SwiftUI
import UIKit
import QuartzCore

// MARK: - Clock

/// The song position the lyrics should show at a given host instant.
///
/// The player's published position moves four times a second and reports
/// what the engine has *rendered*, not what is being heard. Lines therefore
/// changed up to a quarter-second late, word sweeps stepped, and on Bluetooth
/// or AirPlay everything ran early by the route's latency. This extrapolates
/// from the engine's anchor every frame and subtracts the output delay; the
/// user's per-song offset goes on top.
struct LyricsClock: Equatable {
    var anchor: PlaybackAnchor
    var outputDelay: TimeInterval
    /// Positive shows the lyrics earlier; see `Lyrics.userOffset`.
    var userOffset: TimeInterval
    var duration: TimeInterval

    var isRunning: Bool { anchor.rate > 0 }

    func unclampedTime(at host: CFTimeInterval) -> TimeInterval {
        anchor.heardTime(at: host, outputDelay: outputDelay) + userOffset
    }

    func time(at host: CFTimeInterval = CACurrentMediaTime()) -> TimeInterval {
        let time = max(unclampedTime(at: host), 0)
        return duration > 0 ? min(time, duration) : time
    }
}

// MARK: - Row model

/// One scrollable row of the synced view.
///
/// Instrumental breaks get a row of their own instead of leaving the last sung
/// line highlighted for half a minute, so a long intro or solo still shows the
/// song moving forward - and stays tappable like any other row.
/// One word of a lyric line, measured in both the unit time is spent in and
/// the unit the sweep is drawn in.
private struct LyricUnit: Equatable {
    /// What the singer spends: roughly constant per syllable within a phrase.
    let syllables: Double
    /// What the renderer spends: the front is drawn across glyphs.
    let characters: Double
}

/// Syllable estimation, the unit singing is actually measured in.
///
/// Characters are a poor proxy and the error is not small: "through" is seven
/// characters and one syllable, "idea" is four characters and three. Timing a
/// sweep per character holds the front on "through" for seven counts and races
/// it past "idea", which is precisely the arrhythmia this is meant to remove.
///
/// The rigorous answer is phoneme-level forced alignment against the audio, and
/// the research is unambiguous that this is what real systems do - but it needs
/// singing-adapted acoustic models, not the speech ones on the device, and it
/// is far too heavy to run per track here. Counting syllables is the same unit
/// that work uses as its quantum, arrived at from the text alone.
private enum LyricProsody {
    static func units(of line: String) -> [LyricUnit] {
        line
            .split(whereSeparator: { $0.isWhitespace })
            .map { word in
                LyricUnit(
                    syllables: Double(syllables(in: word)),
                    // Trailing space included so the front clears a word before
                    // it starts the next, rather than jumping the gap.
                    characters: Double(word.count + 1)
                )
            }
    }

    static func syllableCount(of line: String) -> Int {
        line
            .split(whereSeparator: { $0.isWhitespace })
            .reduce(0) { $0 + syllables(in: $1) }
    }

    private static let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]

    private static func syllables(in word: Substring) -> Int {
        var syllabic = 0
        var letters = ""

        for character in word.lowercased() {
            // Han, Kana and Hangul carry about a syllable each, so they are
            // counted directly instead of hunting for vowels that are not there.
            if isSyllabic(character) {
                syllabic += 1
            } else if character.isLetter {
                letters.append(character)
            }
        }

        guard !letters.isEmpty else {
            return max(syllabic, word.isEmpty ? 0 : 1)
        }

        var count = 0
        var previousWasVowel = false
        for character in letters {
            let isVowel = vowels.contains(character)
            if isVowel && !previousWasVowel { count += 1 }
            previousWasVowel = isVowel
        }

        // Endings English writes but does not sing as their own syllable.
        if letters.count > 2 {
            if letters.hasSuffix("e") {
                // ...except after a consonant + "l", where the "le" *is* the
                // syllable: "people" and "little" are two, not one.
                if !endsInConsonantLE(letters) { count -= 1 }
            } else if letters.hasSuffix("ed") {
                // "moved" is one syllable; "wanted" and "needed" are two,
                // because -ed after t or d has to be voiced.
                if !letters.hasSuffix("ted") && !letters.hasSuffix("ded") { count -= 1 }
            } else if letters.hasSuffix("es") {
                // Same shape: "makes" is one, "boxes" and "wishes" are two.
                if !Self.voicedESEndings.contains(where: letters.hasSuffix) { count -= 1 }
            }
        }

        return max(count, 1) + syllabic
    }

    private static let voicedESEndings = ["ses", "xes", "zes", "ches", "shes", "ges", "ces"]

    private static func endsInConsonantLE(_ letters: String) -> Bool {
        guard letters.count >= 3, letters.hasSuffix("le") else { return false }
        let beforeL = letters[letters.index(letters.endIndex, offsetBy: -3)]
        return !vowels.contains(beforeL)
    }

    private static func isSyllabic(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040...0x30FF,   // Hiragana, Katakana
             0x3400...0x4DBF,   // CJK extension A
             0x4E00...0x9FFF,   // CJK unified
             0xAC00...0xD7AF:   // Hangul syllables
            return true
        default:
            return false
        }
    }
}

private struct LyricRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case line(String)
        case gap
    }

    let id: Int
    let kind: Kind
    /// When this row becomes the active one.
    let start: TimeInterval
    /// When the next row takes over; `.infinity` for the last row.
    let end: TimeInterval
    /// When the words are expected to have finished being sung - which is not
    /// the same instant the next line begins. Only consulted when `words` is
    /// nil; see `perLineRates`.
    let sweepEnd: TimeInterval
    /// Exact word timings, when the source had them. Present only for Enhanced
    /// LRC; everything from lrclib falls back to the estimate above.
    var words: [LyricsWord]? = nil
    /// Word spans used by the estimated sweep when `words` is nil.
    var units: [LyricUnit] = []
}

private enum LyricRowBuilder {
    /// Breaks shorter than this read as ordinary breathing room between lines
    /// and stay invisible; anything longer earns a progress row.
    static let minimumBreak: TimeInterval = 8
    /// LRC files only carry line *start* times, so a break cannot begin the
    /// instant its preceding line does. Assume the line keeps being sung for
    /// this long before the interlude starts.
    static let lineTail: TimeInterval = 3
    /// An intro needs less slack than a mid-song break: nothing is being sung
    /// before the first line, so the whole span is genuinely instrumental.
    static let minimumIntro: TimeInterval = 5

    /// A sweep never finishes faster than this, however short the line, so a
    /// one-word lyric still reads as filling rather than snapping on.
    static let minimumSweep: TimeInterval = 0.45
    /// What the last line gets, having no successor to measure against.
    static let finalLineSweep: TimeInterval = 4

    static func rows(for lines: [LyricsLine]) -> [LyricRow] {
        // Timestamps must not go backwards: a malformed LRC would otherwise
        // break the binary search that finds the active row.
        var lineStarts: [TimeInterval] = []
        var previousStart: TimeInterval?
        for line in lines {
            let rawStart = line.timestamp ?? previousStart ?? 0
            let start = max(rawStart, previousStart ?? rawStart)
            lineStarts.append(start)
            previousStart = start
        }

        let rates = perLineRates(for: lines, starts: lineStarts)

        var built: [(kind: LyricRow.Kind, start: TimeInterval, sweepEnd: TimeInterval, words: [LyricsWord]?, units: [LyricUnit])] = []

        for (index, line) in lines.enumerated() {
            let start = lineStarts[index]

            if index > 0 {
                let previous = lineStarts[index - 1]
                if start - previous >= minimumBreak {
                    built.append((.gap, previous + lineTail, previous + lineTail, nil, []))
                }
            } else if start >= minimumIntro {
                built.append((.gap, 0, 0, nil, []))
            }

            // The gap to the *next line*, not to whatever row comes next: an
            // interlude row may be inserted in between, and the words of this
            // line are no shorter for it.
            let gapToNextLine = index + 1 < lineStarts.count
                ? lineStarts[index + 1] - start
                : TimeInterval.infinity

            built.append((
                .line(line.text),
                start,
                start + sweepDuration(
                    of: line.text,
                    gapToNextLine: gapToNextLine,
                    rate: rates[index]
                ),
                line.words,
                LyricProsody.units(of: line.text)
            ))
            previousStart = start
        }

        return built.enumerated().map { index, item in
            let end = index + 1 < built.count ? built[index + 1].start : TimeInterval.infinity
            return LyricRow(
                id: index,
                kind: item.kind,
                start: item.start,
                end: end,
                sweepEnd: item.sweepEnd,
                words: item.words,
                units: item.units
            )
        }
    }

    /// How long this line's words should take to sweep.
    private static func sweepDuration(
        of text: String,
        gapToNextLine: TimeInterval,
        rate: TimeInterval?
    ) -> TimeInterval {
        let length = Double(singableLength(text))

        guard let rate, length > 0 else {
            // No usable rhythm to work from: fall back to the old behaviour of
            // spreading the sweep across the whole gap.
            return gapToNextLine.isFinite ? max(gapToNextLine, minimumSweep) : finalLineSweep
        }

        // Syllables measure words, not held notes. A sung "Oh" is one syllable
        // and can occupy four seconds, and finishing its sweep in half a second
        // is as wrong as the old behaviour of crawling across the entire gap -
        // just in the other direction. Giving every line a floor of roughly a
        // third of its gap covers melisma without letting a line that really
        // does end early drift back to trailing the voice.
        let heldNoteFloor = gapToNextLine.isFinite
            ? min(gapToNextLine * 0.35, 2.5)
            : 0
        let estimated = max(length * rate, minimumSweep, heldNoteFloor)

        // Never past the next line, and never longer than a plausible tail on
        // the last line.
        return gapToNextLine.isFinite ? min(estimated, gapToNextLine) : min(estimated, finalLineSweep)
    }

    /// Syllables, not characters: see LyricProsody. Estimating the rate in the
    /// same unit the sweep is spent in is what keeps the two consistent, and it
    /// makes the number itself meaningful - seconds per syllable is comparable
    /// across languages in a way seconds per character is not.
    private static func singableLength(_ text: String) -> Int {
        LyricProsody.syllableCount(of: text)
    }

    /// Seconds per sung character, measured per line rather than per track.
    ///
    /// Every gap between consecutive lines is an *upper bound* on how long the
    /// earlier line took to sing - it is the singing plus whatever silence
    /// follows - so the rate sits near the bottom of the distribution of
    /// gap-over-length, not in the middle of it. A low percentile lands on the
    /// lines that run straight into the next one, which are the ones actually
    /// sung at the local pace.
    ///
    /// Measured over a sliding window rather than the whole song, because a
    /// song does not keep one pace: a fast verse into a held chorus is the
    /// normal case, and a single track-wide number makes the chorus finish
    /// early and the verse trail. The track-wide rate is kept as the fallback
    /// where a window has too little evidence, and as the bound that stops one
    /// freak gap from redefining its neighbours.
    private static let rateWindow = 3

    private static func perLineRates(
        for lines: [LyricsLine],
        starts: [TimeInterval]
    ) -> [TimeInterval?] {
        let observed: [TimeInterval?] = lines.indices.map { index in
            guard index + 1 < starts.count else { return nil }
            let gap = starts[index + 1] - starts[index]
            let length = Double(singableLength(lines[index].text))
            // Very short lines and very long gaps are both poor evidence.
            // A line of fewer than two syllables is too little to measure.
            guard gap > 0.2, gap < 15, length >= 2 else { return nil }
            return gap / length
        }

        let all = observed.compactMap { $0 }
        // Too little evidence to be better than the plain gap.
        guard all.count >= 4, let global = lowPercentile(all, 0.25) else {
            return Array(repeating: nil, count: lines.count)
        }

        return lines.indices.map { index in
            let lower = max(lines.startIndex, index - rateWindow)
            let upper = min(lines.index(before: lines.endIndex), index + rateWindow)
            let samples = (lower...upper).compactMap { observed[$0] }

            guard samples.count >= 3, let local = lowPercentile(samples, 0.3) else {
                return clampRate(global)
            }

            // A section may legitimately run slower or faster than the song's
            // overall pace, but not without limit.
            return clampRate(min(max(local, global * 0.5), global * 2.5))
        }
    }

    private static func lowPercentile(_ values: [TimeInterval], _ fraction: Double) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int(Double(sorted.count) * fraction)))
        return sorted[index]
    }

    /// Roughly 1.5 to 12 syllables a second - a slow ballad to a fast rap.
    /// Anything outside that says the estimate is being driven by something
    /// other than singing.
    private static func clampRate(_ rate: TimeInterval) -> TimeInterval {
        min(max(rate, 0.083), 0.66)
    }

    /// Index of the row covering `time`, or nil before the first row starts.
    static func activeIndex(in rows: [LyricRow], at time: TimeInterval) -> Int? {
        guard !rows.isEmpty else { return nil }

        var low = 0
        var high = rows.count - 1
        var match: Int?

        while low <= high {
            let mid = (low + high) / 2
            if rows[mid].start <= time {
                match = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        return match
    }
}

// MARK: - Embedding

private struct LyricsFadeToTransparentKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set when the lyrics sit over something other than their own black
    /// background, so their edges fade out rather than to black.
    var lyricsFadeToTransparent: Bool {
        get { self[LyricsFadeToTransparentKey.self] }
        set { self[LyricsFadeToTransparentKey.self] = newValue }
    }
}

/// Opaque in the middle, clear at the top and bottom edges.
private struct LyricsFadeMask: View {
    let top: CGFloat
    let bottom: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: top)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: bottom)
        }
    }
}

// MARK: - Lyrics View

struct LyricsView: View {
    let lyrics: Lyrics?
    let currentTime: TimeInterval
    let isLoading: Bool
    var trackTitle: String? = nil
    var trackArtist: String? = nil
    /// Seek handler for tap-to-jump. Without one the lines stay read-only.
    var onSeek: ((TimeInterval) -> Void)? = nil
    /// Re-runs the lookup, ignoring any remembered miss.
    var onRetry: (() -> Void)? = nil
    /// Loads every lrclib record for this track, best match first.
    var loadAlternatives: (() async -> [LyricsManager.LyricsCandidate])? = nil
    /// Adopts one of them.
    var onSelectAlternative: ((Int) -> Void)? = nil
    /// Shown inside the player rather than as its own screen: no background
    /// or title bar of its own, and edges that fade to transparent so the
    /// player's colour shows through instead of black bands.
    var isEmbedded: Bool = false

    @State private var settings = DeleteSettings.load()
    @State private var showVersionPicker = false
    /// This song's timing correction; see `Lyrics.userOffset`. Read from the
    /// lyrics manager rather than from `lyrics`, because the player keeps its
    /// own copy of the lyrics and that copy never sees later adjustments.
    @State private var userOffset: TimeInterval = 0
    @State private var showTimingControls = false
    /// The playback anchor. The player already re-renders this view on every
    /// position tick; the anchor itself only changes on play/pause, seeks and
    /// drift corrections.
    @ObservedObject private var progress = PlayerEngine.shared.progress
    @Environment(\.dismiss) var dismiss

    @ScaledMetric(relativeTo: .body) private var plainFontSize: CGFloat = 21

    @Environment(\.playerAccent) private var playerAccent

    /// Inside the player, the player's own colour - the cover's, or the
    /// theme's when the backdrop uses it; elsewhere the theme colour.
    private var accent: Color { playerAccent ?? settings.backgroundColorChoice.color }
    private var fadeToTransparent: Bool { isEmbedded }

    var body: some View {
        ZStack {
            if isEmbedded {
                content
                    .environment(\.lyricsFadeToTransparent, true)
                    .overlay(alignment: .topTrailing) {
                        if copyableText != nil || loadAlternatives != nil {
                            actionsMenu
                                .padding(.top, Design.Spacing.s)
                        }
                    }
            } else {
                backgroundLayers
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    header
                    content
                        // The lyrics run to the physical bottom of the screen, not
                        // to the safe-area line. Respecting it left the scroll view
                        // - and so the fade that softens its edge - stopping short
                        // above the home indicator, which read as a black band
                        // ending in mid-air with live text below it.
                        .ignoresSafeArea(edges: .bottom)
                }
            }
        }
        .preferredColorScheme(.dark)
        // The lyric type scales with the user's text size, but the two largest
        // accessibility steps leave room for barely a word per line.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .sheet(isPresented: $showVersionPicker) {
            if let loadAlternatives {
                LyricsVersionPicker(
                    accent: accent,
                    load: loadAlternatives,
                    onSelect: { id in
                        showVersionPicker = false
                        onSelectAlternative?(id)
                    }
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("BackgroundColorChanged"))) { _ in
            settings = DeleteSettings.load()
        }
        // Keyed on the lyrics' shape too, so adopting another lrclib version
        // (which starts with no offset of its own) reloads it.
        .task(id: offsetTaskKey) {
            guard let trackId else {
                userOffset = 0
                return
            }
            userOffset = await LyricsManager.shared.userOffset(for: trackId) ?? 0
        }
    }

    // MARK: - Timing

    /// These lyrics are always the current track's.
    private var trackId: String? { PlayerEngine.shared.currentTrack?.stableId }

    private var offsetTaskKey: String {
        let shape = lyrics.map { "\($0.source.rawValue)-\($0.syncedLyrics.count)-\($0.plainLyrics.count)" } ?? "none"
        return "\(trackId ?? "")|\(shape)"
    }

    private var clock: LyricsClock {
        LyricsClock(
            anchor: progress.anchor,
            outputDelay: progress.outputDelay,
            userOffset: userOffset,
            duration: PlayerEngine.shared.duration
        )
    }

    private var hasSyncedLyrics: Bool {
        guard let lyrics, !isLoading, !lyrics.isInstrumental else { return false }
        return !lyrics.syncedLyrics.isEmpty
    }

    /// Far beyond any real misalignment; only stops a runaway calibration.
    private static let maximumOffset: TimeInterval = 30

    private func setUserOffset(_ value: TimeInterval) {
        let clamped = min(max(value, -Self.maximumOffset), Self.maximumOffset)
        let rounded = (clamped * 100).rounded() / 100
        guard rounded != userOffset else { return }
        userOffset = rounded

        guard let trackId else { return }
        Task { await LyricsManager.shared.setUserOffset(rounded, for: trackId) }
    }

    /// Shifts the lyrics so the line nearest to now - the highlighted one, or
    /// the one about to be - starts at `host`, the instant the user tapped.
    /// Only those two are considered: the user is reacting to what they hear,
    /// and a line further away means they tapped on a gap, not a start.
    private func calibrate(at host: CFTimeInterval) {
        guard let lyrics else { return }
        let starts = lyrics.syncedLyrics
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .compactMap(\.timestamp)
        guard !starts.isEmpty else { return }

        let now = clock.unclampedTime(at: host)
        var candidates: [TimeInterval] = []
        if let current = starts.lastIndex(where: { $0 <= now }) {
            candidates.append(starts[current])
            if current + 1 < starts.count { candidates.append(starts[current + 1]) }
        } else {
            candidates.append(starts[0])
        }

        guard let target = candidates.min(by: { abs($0 - now) < abs($1 - now) }) else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        setUserOffset(userOffset + (target - now))
    }

    // MARK: - Background

    private var backgroundLayers: some View {
        ZStack {
            // Base dark background
            Color.black

            // Top radial glow
            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: [
                            accent.opacity(0.25),
                            accent.opacity(0.12),
                            Color.clear
                        ]),
                        center: .top,
                        startRadius: 0,
                        endRadius: 350
                    )
                )
                .frame(height: 600)
                .blur(radius: 50)
                .offset(y: -200)

            // Center diagonal gradient
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: Color.clear, location: 0.0),
                    .init(color: accent.opacity(0.08), location: 0.3),
                    .init(color: accent.opacity(0.12), location: 0.5),
                    .init(color: accent.opacity(0.08), location: 0.7),
                    .init(color: Color.clear, location: 1.0)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Bottom radial glow
            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: [
                            accent.opacity(0.2),
                            accent.opacity(0.1),
                            Color.clear
                        ]),
                        center: .bottom,
                        startRadius: 0,
                        endRadius: 300
                    )
                )
                .frame(height: 500)
                .blur(radius: 60)
                .offset(y: 200)

            // Vertical accent gradient
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: accent.opacity(0.06), location: 0.0),
                    .init(color: Color.clear, location: 0.2),
                    .init(color: Color.clear, location: 0.8),
                    .init(color: accent.opacity(0.08), location: 1.0)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(Localized.lyrics)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)

                if let subtitle = headerSubtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundColor(.white.opacity(PlayerPalette.secondaryTextOpacity))
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 8)

            if copyableText != nil || loadAlternatives != nil {
                actionsMenu
            }

            Button {
                dismiss()
            } label: {
                headerCircle(systemImage: "xmark")
            }
            .accessibilityLabel(Localized.close)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            ZStack {
                // Glass effect
                Rectangle()
                    .fill(.ultraThinMaterial)

                // Bottom border highlight
                VStack {
                    Spacer()
                    Rectangle()
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    Color.white.opacity(0.1),
                                    Color.clear,
                                    Color.white.opacity(0.1)
                                ]),
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(height: 0.5)
                }
            }
        )
    }

    private var actionsMenu: some View {
        Menu {
            if copyableText != nil {
                Button {
                    copyLyrics()
                } label: {
                    Label(Localized.lyricsCopy, systemImage: "doc.on.doc")
                }
            }

            if loadAlternatives != nil {
                Button {
                    showVersionPicker = true
                } label: {
                    Label(Localized.lyricsChooseVersion, systemImage: "text.line.first.and.arrowtriangle.forward")
                }
            }

            if hasSyncedLyrics {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        showTimingControls.toggle()
                    }
                } label: {
                    Label(Localized.lyricsAdjustTiming, systemImage: "timer")
                }
            }
        } label: {
            headerCircle(systemImage: "ellipsis")
                .frame(width: Design.Size.minTouch, height: Design.Size.minTouch)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Localized.lyricsMoreActions)
    }

    private func headerCircle(systemImage: String) -> some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 36, height: 36)

            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.8))
        }
        .contentShape(Circle())
    }

    private var headerSubtitle: String? {
        let parts = [trackTitle, trackArtist].compactMap { value -> String? in
            guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return value
        }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            LyricsStatusCard(
                icon: .progress,
                title: Localized.lyricsLoading,
                message: Localized.lyricsLoadingMessage,
                accent: accent
            )
        } else if let lyrics {
            if lyrics.isInstrumental {
                LyricsStatusCard(
                    icon: .symbol("music.note"),
                    title: Localized.lyricsInstrumental,
                    message: Localized.lyricsInstrumentalMessage,
                    accent: accent
                )
            } else if !lyrics.syncedLyrics.isEmpty {
                SyncedLyricsScroller(
                    lines: lyrics.syncedLyrics,
                    currentTime: currentTime,
                    clock: clock,
                    accent: accent,
                    bottomClearance: showTimingControls ? LyricsTimingPanel.reservedHeight : 0,
                    // A tapped line should light up the moment its audio is
                    // heard, so the seek lands where the corrected clock - not
                    // the file's raw timestamp - says that line begins.
                    onSeek: onSeek.map { seek -> (TimeInterval) -> Void in
                        { [userOffset] time in seek(max(0, time - userOffset)) }
                    }
                )
                .overlay(alignment: .bottom) {
                    if showTimingControls {
                        LyricsTimingPanel(
                            offset: userOffset,
                            accent: accent,
                            canCalibrate: clock.isRunning,
                            onAdjust: { delta in setUserOffset(userOffset + delta) },
                            onCalibrate: { host in calibrate(at: host) },
                            onReset: { setUserOffset(0) },
                            onDone: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    showTimingControls = false
                                }
                            }
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            } else if !lyrics.plainLyrics.isEmpty {
                plainLyricsView(lyrics.plainLyrics)
            } else {
                unavailableCard
            }
        } else {
            unavailableCard
        }
    }

    /// A miss is remembered for a week so reopening this screen is not three
    /// fruitless network round trips - which makes an explicit way to ask again
    /// necessary rather than merely nice, for a song whose lyrics were added
    /// upstream since, or that was looked up while offline.
    private var unavailableCard: some View {
        LyricsStatusCard(
            icon: .symbol("text.badge.xmark"),
            title: Localized.lyricsUnavailable,
            message: Localized.lyricsUnavailableMessage,
            accent: accent,
            actionTitle: onRetry == nil ? nil : Localized.lyricsSearchAgain,
            action: onRetry
        )
    }

    // MARK: - Plain Lyrics

    /// Unsynced lyrics, set to read like the synced view rather than like a
    /// text dump: the same centred column, the same weight, the same fade at
    /// the edges. Without timestamps there is no active line to lift out, so
    /// the type carries the whole job - which is why it is set at the size the
    /// synced view gives its *neighbouring* lines rather than its body size.
    private func plainLyricsView(_ text: String) -> some View {
        ZStack {
            ScrollView {
                VStack(spacing: 26) {
                    ForEach(Array(stanzas(of: text).enumerated()), id: \.offset) { _, stanza in
                        Text(stanza)
                            .font(.system(size: plainFontSize, weight: .semibold))
                            .foregroundColor(.white.opacity(0.92))
                            .lineSpacing(10)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity)
                    }
                }
                .textSelection(.enabled)
                .padding(.horizontal, 32)
                .padding(.top, 56)
                // Clears the taller bottom fade and the home indicator beneath
                // it, so the closing lines can still be scrolled fully clear.
                .padding(.bottom, 130)
            }
            .scrollIndicators(.hidden)
            .mask {
                if fadeToTransparent {
                    LyricsFadeMask(top: 60, bottom: 90)
                } else {
                    Color.black
                }
            }

            if !fadeToTransparent {
                edgeFades(top: 90, bottom: 150)
                    .allowsHitTesting(false)
            }
        }
    }

    /// The same soft edges the synced list uses, so scrolled text dissolves
    /// into the background instead of colliding with the header.
    private func edgeFades(top: CGFloat, bottom: CGFloat) -> some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [Color.black, Color.black.opacity(0.45), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: top)

            Spacer()

            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.45), Color.black],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: bottom)
        }
    }

    /// Splits on blank lines so verses and choruses keep their own breathing
    /// room instead of arriving as one undifferentiated block.
    private func stanzas(of text: String) -> [String] {
        let blocks = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return blocks.isEmpty ? [text] : blocks
    }

    // MARK: - Actions

    private var copyableText: String? {
        guard let lyrics, !isLoading, !lyrics.isInstrumental else { return nil }

        if !lyrics.plainLyrics.isEmpty {
            return lyrics.plainLyrics
        }
        if !lyrics.syncedLyrics.isEmpty {
            return lyrics.syncedLyrics.map(\.text).joined(separator: "\n")
        }
        return nil
    }

    private func copyLyrics() {
        guard let copyableText else { return }
        UIPasteboard.general.string = copyableText
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

// MARK: - Synced Lyrics

private struct SyncedLyricsScroller: View {
    let lines: [LyricsLine]
    /// The player's 4Hz position. Only the browse-resume countdown uses it;
    /// everything drawn in time with the music reads `clock`.
    let currentTime: TimeInterval
    let clock: LyricsClock
    let accent: Color
    /// Room kept free at the bottom for the timing panel.
    var bottomClearance: CGFloat = 0
    let onSeek: ((TimeInterval) -> Void)?

    /// How long after the user stops scrolling before the view takes the
    /// wheel back. Long enough to read ahead a verse, short enough that the
    /// screen never feels abandoned.
    private static let resumeDelay: TimeInterval = 4

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.lyricsFadeToTransparent) private var fadeToTransparent

    @ScaledMetric(relativeTo: .title2) private var activeFontSize: CGFloat = 28
    @ScaledMetric(relativeTo: .body) private var nearFontSize: CGFloat = 21
    @ScaledMetric(relativeTo: .callout) private var farFontSize: CGFloat = 18

    /// Built from `lines` when they change, never in `body`.
    ///
    /// This used to be computed inline at the call site, which meant rebuilding
    /// every row - including the windowed rate estimate, with its per-line sort -
    /// on every body pass, four times a second for the whole song, purely
    /// because the playback position had ticked.
    @State private var rows: [LyricRow] = []

    /// True once the user has actually dragged the list, which parks
    /// auto-scroll and offers the way back.
    @State private var isBrowsing = false
    /// Finger is down, or momentum is still running. Auto-scroll stays out of
    /// the way even for a touch that never became a drag.
    @State private var isTouching = false
    @State private var lastInteraction = Date.distantPast

    /// The row being sung, kept current every frame by `activeRowTracker`
    /// rather than recomputed from the 4Hz position, which held each new line
    /// back by up to a quarter of a second.
    @State private var activeIndex: Int?

    /// How often the clock is checked for the next line: twenty times a
    /// second places a line change within 50 ms of the voice. Lines light up
    /// whole now - the word-by-word sweep redrew the text every frame and
    /// made this the heaviest screen in the app.
    private static let frameInterval: TimeInterval = 1.0 / 20

    /// Publishes row changes the frame they happen. Paused with playback, when
    /// a seek arrives as a new anchor and re-evaluates it anyway.
    private var activeRowTracker: some View {
        TimelineView(.animation(minimumInterval: Self.frameInterval, paused: !clock.isRunning)) { _ in
            let index = LyricRowBuilder.activeIndex(in: rows, at: clock.time())
            Color.clear
                .onChange(of: index, initial: true) { _, newValue in
                    activeIndex = newValue
                }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    var body: some View {
        GeometryReader { geometry in
            // Half the viewport, so the active row can sit dead centre whether
            // it is the first line or the last.
            let inset = max(120, geometry.size.height / 2 - 40)

            ScrollViewReader { proxy in
                ZStack(alignment: .bottom) {
                    ScrollView(.vertical) {
                        VStack(spacing: 0) {
                            Color.clear.frame(height: inset)

                            ForEach(rows) { row in
                                rowButton(row, proxy: proxy)
                            }

                            Color.clear.frame(height: inset)
                        }
                    }
                    .scrollIndicators(.hidden)
                    .onScrollPhaseChange { _, phase in
                        handle(phase)
                    }
                    .mask {
                        if fadeToTransparent {
                            LyricsFadeMask(top: 100, bottom: 120)
                        } else {
                            Color.black
                        }
                    }

                    if !fadeToTransparent {
                        edgeFades
                            .allowsHitTesting(false)
                    }

                    if isBrowsing {
                        resumeButton(proxy: proxy)
                            // The list now runs under the home indicator, and
                            // an inner GeometryReader reports no safe area once
                            // its parent ignores it - so this clearance is a
                            // constant. 40pt clears the indicator and merely
                            // sits a little high on devices without one.
                            .padding(.bottom, 40 + bottomClearance)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .background(activeRowTracker)
                .onChange(of: activeIndex) { oldValue, newValue in
                    guard !isBrowsing, !isTouching else { return }
                    // The first placement is a jump, not a glide down from the top.
                    scroll(toRowAt: newValue, proxy: proxy, animated: oldValue != nil)
                }
                .onChange(of: currentTime) { _, _ in
                    // The playback tick doubles as the resume clock: no timer to
                    // cancel, and it only runs while there is something to
                    // follow along with.
                    guard isBrowsing, !isTouching else { return }
                    guard Date().timeIntervalSince(lastInteraction) >= Self.resumeDelay else { return }
                    resumeFollowing(proxy: proxy)
                }
                .onChange(of: lines, initial: true) { _, newLines in
                    rows = LyricRowBuilder.rows(for: newLines)
                }
                .onAppear {
                    scroll(toRowAt: activeIndex, proxy: proxy, animated: false)
                }
            }
        }
    }

    // MARK: Rows

    private func rowButton(_ row: LyricRow, proxy: ScrollViewProxy) -> some View {
        let isActive = activeIndex == row.id
        let distance = activeIndex.map { abs(row.id - $0) } ?? 99

        return Button {
            handleTap(row, proxy: proxy)
        } label: {
            rowContent(row, isActive: isActive, distance: distance)
        }
        .buttonStyle(LyricRowButtonStyle())
        .disabled(onSeek == nil)
        .id(row.id)
        .accessibilityLabel(accessibilityLabel(for: row))
        .accessibilityHint(onSeek == nil ? "" : Localized.lyricsSeekHint)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    @ViewBuilder
    private func rowContent(_ row: LyricRow, isActive: Bool, distance: Int) -> some View {
        Group {
            switch row.kind {
            case .line(let text):
                // Phrase by phrase: the sung line is lit as a whole, with a
                // soft glow in the player's colour; nothing redraws while it
                // is sung.
                Text(text)
                    .font(.system(
                        size: fontSize(isActive: isActive, distance: distance),
                        weight: weight(isActive: isActive, distance: distance)
                    ))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .shadow(color: isActive ? accent.opacity(0.45) : .clear, radius: 12)
            case .gap:
                // The dots of an instrumental break still fill in time, but
                // slowly - a few redraws a second, only while it is the one
                // playing.
                TimelineView(.animation(minimumInterval: 1.0 / 8, paused: !(isActive && clock.isRunning))) { _ in
                    LyricsBreakIndicator(
                        progress: breakProgress(row, at: clock.time()),
                        isActive: isActive,
                        accent: accent
                    )
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 30)
        .padding(.vertical, isActive ? 18 : 12)
        .contentShape(Rectangle())
        .opacity(lineOpacity(distance: distance, isActive: isActive))
        .animation(rowAnimation, value: isActive)
        .animation(rowAnimation, value: distance)
    }

    private func accessibilityLabel(for row: LyricRow) -> String {
        switch row.kind {
        case .line(let text): return text
        case .gap: return Localized.lyricsInstrumentalBreak
        }
    }

    private func breakProgress(_ row: LyricRow, at currentTime: TimeInterval) -> Double {
        guard row.end.isFinite, row.end > row.start else { return 0 }
        return min(max((currentTime - row.start) / (row.end - row.start), 0), 1)
    }

    // MARK: Styling

    private var rowAnimation: Animation {
        .easeInOut(duration: reduceMotion ? 0.15 : 0.3)
    }

    private var scrollAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.25)
            : .interpolatingSpring(mass: 1.0, stiffness: 170, damping: 25, initialVelocity: 0)
    }

    private func fontSize(isActive: Bool, distance: Int) -> CGFloat {
        if isActive { return activeFontSize }
        if distance <= 1 { return nearFontSize }
        return farFontSize
    }

    private func weight(isActive: Bool, distance: Int) -> Font.Weight {
        if isActive { return .bold }
        if distance <= 1 { return .semibold }
        return .medium
    }

    /// One fade curve for the whole stack. Brightness is carried here alone
    /// rather than split between a text colour and a view opacity, so the two
    /// cannot drift apart and the sweep below has a single thing to lift out of.
    private func lineOpacity(distance: Int, isActive: Bool) -> Double {
        if isActive { return 1.0 }
        switch distance {
        case 1: return 0.62
        case 2: return 0.38
        case 3: return 0.24
        case 4: return 0.15
        default: return 0.10
        }
    }

    /// Ends fully opaque at both edges rather than at 0.95: a fade that stops
    /// just short of solid leaves a faint seam where it meets the background,
    /// which is exactly the kind of edge it exists to hide.
    private var edgeFades: some View {
        VStack(spacing: 0) {
            LinearGradient(
                gradient: Gradient(colors: [
                    Color.black,
                    Color.black.opacity(0.7),
                    Color.black.opacity(0.3),
                    Color.clear
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 150)

            Spacer()

            LinearGradient(
                gradient: Gradient(colors: [
                    Color.clear,
                    Color.black.opacity(0.3),
                    Color.black.opacity(0.7),
                    Color.black
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            // Taller than the top: this one now spans the home-indicator area
            // as well, so the last line has somewhere to dissolve into.
            .frame(height: 190)
        }
    }

    // MARK: Resume affordance

    private func resumeButton(proxy: ScrollViewProxy) -> some View {
        Button {
            resumeFollowing(proxy: proxy)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "music.note")
                    .font(.system(size: 13, weight: .semibold))

                Text(Localized.lyricsBackToCurrent)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule().stroke(accent.opacity(0.5), lineWidth: 1)
                    )
            )
            .shadow(color: accent.opacity(0.35), radius: 18, y: 6)
        }
        .buttonStyle(LyricRowButtonStyle())
    }

    // MARK: Scroll coordination

    private func handle(_ phase: ScrollPhase) {
        switch phase {
        case .tracking:
            // A finger resting on the list may still turn out to be a tap on a
            // line, so hold auto-scroll without claiming the user is browsing.
            isTouching = true
            lastInteraction = Date()
        case .interacting, .decelerating:
            isTouching = true
            lastInteraction = Date()
            if !isBrowsing {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isBrowsing = true
                }
            }
        case .idle:
            isTouching = false
            if isBrowsing { lastInteraction = Date() }
        case .animating:
            break
        @unknown default:
            isTouching = false
        }
    }

    private func handleTap(_ row: LyricRow, proxy: ScrollViewProxy) {
        guard let onSeek else { return }

        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onSeek(row.start)

        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            isBrowsing = false
        }
        // Jump to the tapped row rather than waiting for the next playback
        // tick to report the new position.
        scroll(toRowID: row.id, proxy: proxy, animated: true)
    }

    private func resumeFollowing(proxy: ScrollViewProxy) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            isBrowsing = false
        }
        scroll(toRowAt: activeIndex, proxy: proxy, animated: true)
    }

    private func scroll(toRowAt index: Int?, proxy: ScrollViewProxy, animated: Bool) {
        guard let index, rows.indices.contains(index) else { return }
        scroll(toRowID: rows[index].id, proxy: proxy, animated: animated)
    }

    private func scroll(toRowID id: Int, proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(scrollAnimation) {
                proxy.scrollTo(id, anchor: .center)
            }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }
}

/// Three dots that fill across an instrumental break, so a long interlude
/// reads as progress rather than a stalled screen.
private struct LyricsBreakIndicator: View {
    let progress: Double
    let isActive: Bool
    let accent: Color

    var body: some View {
        HStack(spacing: 13) {
            ForEach(0..<3, id: \.self) { index in
                let fill = min(max((progress - Double(index) / 3) * 3, 0), 1)

                Circle()
                    .fill(
                        isActive
                        ? Color.white.opacity(0.32 + 0.68 * fill)
                        : Color.white.opacity(0.5)
                    )
                    .frame(width: 12, height: 12)
                    .scaleEffect(isActive ? 0.8 + 0.4 * fill : 0.62)
                    .shadow(color: accent.opacity(isActive ? 0.5 * fill : 0), radius: 12)
            }
        }
        .frame(height: 26)
    }
}

private struct LyricRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Timing Panel

/// Nudges this song's lyrics earlier or later, or lines them up with a tap.
///
/// Shown as a value the user reads in "later is positive" terms - the natural
/// reading of "+0.3 s" next to a Later button - while `Lyrics.userOffset`
/// keeps the LRC convention (positive = earlier). `offset` here is the stored
/// value; only the readout flips its sign.
private struct LyricsTimingPanel: View {
    /// What the scroller keeps clear beneath its resume button.
    static let reservedHeight: CGFloat = 160

    let offset: TimeInterval
    let accent: Color
    let canCalibrate: Bool
    /// Receives a change to the stored offset.
    let onAdjust: (TimeInterval) -> Void
    /// Receives the host time the finger went down.
    let onCalibrate: (CFTimeInterval) -> Void
    let onReset: () -> Void
    let onDone: () -> Void

    /// Touch-down, not the button's touch-up action: the user taps on the
    /// beat they hear, and the lift comes a tenth of a second or so later.
    @State private var pressBeganAt: CFTimeInterval?

    /// Positive = lyrics shown later.
    private var delay: TimeInterval { -offset }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(Localized.lyricsTimingEarlier)
                Spacer()
                Text(Localized.lyricsTimingLater)
            }
            .font(.caption2.weight(.semibold))
            .foregroundColor(.white.opacity(PlayerPalette.secondaryTextOpacity))
            .padding(.horizontal, 6)
            .accessibilityHidden(true)

            HStack(spacing: 4) {
                stepButton(delayChange: -0.5)
                stepButton(delayChange: -0.1)
                readout
                    .frame(maxWidth: .infinity)
                stepButton(delayChange: 0.1)
                stepButton(delayChange: 0.5)
            }

            HStack(spacing: 8) {
                Button {
                    onCalibrate(pressBeganAt ?? CACurrentMediaTime())
                    pressBeganAt = nil
                } label: {
                    Label(Localized.lyricsTimingTapLine, systemImage: "hand.tap")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: Design.Size.minTouch)
                        .background(
                            Capsule()
                                .fill(accent.opacity(0.35))
                                .overlay(Capsule().stroke(accent.opacity(0.6), lineWidth: 1))
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(PressTimestampButtonStyle { pressBeganAt = $0 })
                .disabled(!canCalibrate)
                .opacity(canCalibrate ? 1 : 0.5)
                .accessibilityHint(Localized.lyricsTimingTapLineHint)

                iconButton(systemImage: "arrow.counterclockwise", label: Localized.lyricsTimingReset, action: onReset)
                    .disabled(offset == 0)
                    .opacity(offset == 0 ? 0.5 : 1)

                iconButton(systemImage: "checkmark", label: Localized.done, action: onDone)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private var readout: some View {
        VStack(spacing: 1) {
            Text(Localized.lyricsTimingTitle)
                .font(.caption2)
                .foregroundColor(.white.opacity(PlayerPalette.secondaryTextOpacity))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(readoutText)
                .font(.system(size: 17, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .frame(minHeight: Design.Size.minTouch)
        // One adjustable element for VoiceOver: swipe up for later, down for
        // earlier, in the same 0.1 s steps as the small buttons.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Localized.lyricsTimingTitle)
        .accessibilityValue(spokenValue)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onAdjust(-0.1)
            case .decrement: onAdjust(0.1)
            @unknown default: break
            }
        }
    }

    private var readoutText: String {
        let shown = abs(delay) < 0.05 ? 0 : delay
        return Measurement(value: shown, unit: UnitDuration.seconds).formatted(
            .measurement(
                width: .narrow,
                numberFormatStyle: .number
                    .precision(.fractionLength(1))
                    .sign(strategy: .always(includingZero: false))
            )
        )
    }

    private var spokenValue: String {
        guard abs(delay) >= 0.05 else { return Localized.lyricsTimingInSync }
        let magnitude = abs(delay).formatted(.number.precision(.fractionLength(1)))
        return String(
            format: delay > 0 ? Localized.lyricsTimingValueLaterFormat : Localized.lyricsTimingValueEarlierFormat,
            magnitude
        )
    }

    /// - Parameter delayChange: in readout terms; positive moves the lyrics later.
    private func stepButton(delayChange: TimeInterval) -> some View {
        let magnitude = abs(delayChange).formatted(.number.precision(.fractionLength(1)))
        let title = (delayChange < 0 ? "\u{2212}" : "+") + magnitude

        return Button {
            onAdjust(-delayChange)
        } label: {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(.white)
                .frame(width: Design.Size.minTouch, height: Design.Size.minTouch)
                .background(Circle().fill(Color.white.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(LyricRowButtonStyle())
        .accessibilityLabel(String(
            format: delayChange < 0 ? Localized.lyricsTimingEarlierByFormat : Localized.lyricsTimingLaterByFormat,
            magnitude
        ))
    }

    private func iconButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: Design.Size.minTouch, height: Design.Size.minTouch)
                .background(Circle().fill(Color.white.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(LyricRowButtonStyle())
        .accessibilityLabel(label)
    }
}

/// Reports the instant a press begins, for the tap-to-calibrate button.
private struct PressTimestampButtonStyle: ButtonStyle {
    let onPressBegan: (CFTimeInterval) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed { onPressBegan(CACurrentMediaTime()) }
            }
    }
}

// MARK: - Status Card

/// Loading, instrumental and not-found all share one glass card so the three
/// states stay visually identical and only their contents differ.
private struct LyricsStatusCard: View {
    enum Icon {
        case symbol(String)
        case progress
    }

    let icon: Icon
    let title: String
    let message: String
    let accent: Color
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        // The tallest version that fits. The top half of iPhone Duo propped
        // up like a laptop leaves the lyrics about 320 points, and the full
        // card spilled over the player's close button and the status bar.
        ViewThatFits(in: .vertical) {
            card(isCompact: false)
            card(isCompact: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func card(isCompact: Bool) -> some View {
        VStack(spacing: isCompact ? 16 : 32) {
            if !isCompact {
                ZStack {
                    // Large outer glow
                    Circle()
                        .fill(
                            RadialGradient(
                                gradient: Gradient(colors: [
                                    accent.opacity(0.4),
                                    accent.opacity(0.2),
                                    accent.opacity(0.05),
                                    Color.clear
                                ]),
                                center: .center,
                                startRadius: 0,
                                endRadius: 100
                            )
                        )
                        .frame(width: 200, height: 200)
                        .blur(radius: 30)

                    // Glass circle
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Circle()
                                .stroke(
                                    LinearGradient(
                                        gradient: Gradient(colors: [
                                            accent.opacity(0.6),
                                            accent.opacity(0.3),
                                            accent.opacity(0.1)
                                        ]),
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 2
                                )
                        )
                        .frame(width: 120, height: 120)
                        .shadow(color: accent.opacity(0.3), radius: 25, x: 0, y: 10)

                    switch icon {
                    case .symbol(let name):
                        Image(systemName: name)
                            .font(.system(size: 50, weight: .medium))
                            .foregroundColor(.white)
                            .shadow(color: accent.opacity(0.6), radius: 15)
                    case .progress:
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.5)
                    }
                }
                .accessibilityHidden(true)
            }

            VStack(spacing: 12) {
                Text(title)
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundColor(.white)

                Text(message)
                    .font(.callout)
                    .foregroundColor(.white.opacity(PlayerPalette.secondaryTextOpacity))
                    .multilineTextAlignment(.center)
            }

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                        .background(
                            Capsule()
                                .fill(.ultraThinMaterial)
                                .overlay(Capsule().stroke(accent.opacity(0.55), lineWidth: 1))
                        )
                }
            }
        }
        .padding(isCompact ? 24 : 44)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 28)
                    .fill(.ultraThinMaterial)

                RoundedRectangle(cornerRadius: 28)
                    .stroke(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                accent.opacity(0.3),
                                Color.white.opacity(0.15),
                                accent.opacity(0.2)
                            ]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )

                RoundedRectangle(cornerRadius: 28)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                accent.opacity(0.05),
                                Color.clear,
                                accent.opacity(0.08)
                            ]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .shadow(color: accent.opacity(0.2), radius: 35, x: 0, y: 15)
        )
        .padding(.horizontal, 40)
        .accessibilityElement(children: .combine)
    }
}

/// Lets the user override the automatic match with any record lrclib holds.
///
/// Duration is shown for every row because it is usually the thing that tells
/// two records of the same song apart - a radio edit from an album cut, a live
/// take from the studio one - and it is the field the automatic scorer weighs
/// most heavily when it gets the choice wrong.
private struct LyricsVersionPicker: View {
    let accent: Color
    let load: () async -> [LyricsManager.LyricsCandidate]
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [LyricsManager.LyricsCandidate]?

    var body: some View {
        NavigationStack {
            Group {
                if let candidates {
                    if candidates.isEmpty {
                        ContentUnavailableView(
                            Localized.lyricsUnavailable,
                            systemImage: "text.badge.xmark",
                            description: Text(Localized.lyricsUnavailableMessage)
                        )
                    } else {
                        List(candidates) { candidate in
                            Button {
                                onSelect(candidate.id)
                            } label: {
                                row(for: candidate)
                            }
                            .buttonStyle(.plain)
                        }
                        .listStyle(.plain)
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(Localized.lyricsChooseVersion)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Localized.cancel) { dismiss() }
                }
            }
        }
        .task {
            candidates = await load()
        }
    }

    private func row(for candidate: LyricsManager.LyricsCandidate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(candidate.trackName)
                .font(.body)
                .fontWeight(.medium)
                .lineLimit(1)

            Text(candidate.artistName)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)

            HStack(spacing: 8) {
                if !candidate.albumName.isEmpty {
                    Text(candidate.albumName)
                        .lineLimit(1)
                }

                Text(durationText(candidate.duration))

                if candidate.isInstrumental {
                    badge(Localized.lyricsInstrumental)
                } else if candidate.hasSyncedLyrics {
                    badge(Localized.lyricsSynced)
                }
            }
            .font(.caption2)
            .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().stroke(accent.opacity(0.5), lineWidth: 1))
    }

    private func durationText(_ duration: TimeInterval) -> String {
        guard duration > 0 else { return "--:--" }
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Preview

#Preview {
    LyricsView(
        lyrics: Lyrics(
            plainLyrics: "Sample lyrics\nLine 2\nLine 3",
            syncedLyrics: [
                LyricsLine(timestamp: 12, text: "Sample lyrics"),
                LyricsLine(timestamp: 17, text: "Line 2"),
                LyricsLine(timestamp: 22, text: "Line 3"),
                LyricsLine(timestamp: 45, text: "After the solo")
            ],
            isInstrumental: false,
            source: .lrclib
        ),
        currentTime: 18.0,
        isLoading: false,
        trackTitle: "Sample Song",
        trackArtist: "Sample Artist",
        onSeek: { _ in }
    )
}
