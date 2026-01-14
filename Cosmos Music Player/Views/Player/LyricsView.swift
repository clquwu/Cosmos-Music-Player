//
//  LyricsView.swift
//  Cosmos Music Player
//
//  Lyrics display with synchronized scrolling
//

import SwiftUI

struct LyricsView: View {
    let lyrics: Lyrics?
    let currentTime: TimeInterval
    let isLoading: Bool
    @State private var scrollTarget: Int?
    @State private var settings = DeleteSettings.load()
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ZStack {
            // Multi-layer gradient background
            ZStack {
                // Base dark background
                Color.black

                // Top radial glow
                Circle()
                    .fill(
                        RadialGradient(
                            gradient: Gradient(colors: [
                                settings.backgroundColorChoice.color.opacity(0.25),
                                settings.backgroundColorChoice.color.opacity(0.12),
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
                        .init(color: settings.backgroundColorChoice.color.opacity(0.08), location: 0.3),
                        .init(color: settings.backgroundColorChoice.color.opacity(0.12), location: 0.5),
                        .init(color: settings.backgroundColorChoice.color.opacity(0.08), location: 0.7),
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
                                settings.backgroundColorChoice.color.opacity(0.2),
                                settings.backgroundColorChoice.color.opacity(0.1),
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
                        .init(color: settings.backgroundColorChoice.color.opacity(0.06), location: 0.0),
                        .init(color: Color.clear, location: 0.2),
                        .init(color: Color.clear, location: 0.8),
                        .init(color: settings.backgroundColorChoice.color.opacity(0.08), location: 1.0)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Glass header with blur
                HStack(spacing: 16) {
                    Text("Lyrics")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)

                    Spacer()

                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            dismiss()
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(.ultraThinMaterial)
                                .frame(width: 36, height: 36)

                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
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

                if isLoading {
                    loadingView
                } else if let lyrics = lyrics {
                    if lyrics.isInstrumental {
                        instrumentalView
                    } else if !lyrics.syncedLyrics.isEmpty {
                        syncedLyricsView(lyrics.syncedLyrics)
                    } else if !lyrics.plainLyrics.isEmpty {
                        plainLyricsView(lyrics.plainLyrics)
                    } else {
                        noLyricsView
                    }
                } else {
                    noLyricsView
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("BackgroundColorChanged"))) { _ in
            settings = DeleteSettings.load()
        }
    }

    // MARK: - Synced Lyrics

    private func syncedLyricsView(_ lines: [LyricsLine]) -> some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ZStack {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            // Reduced spacer at top - use more space
                            Spacer()
                                .frame(height: geometry.size.height / 2 - 40)

                            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                let isActive = isLineActive(line, at: index, in: lines)
                                let distance = distanceFromActive(index: index, lines: lines)

                                lyricLineView(
                                    text: line.text,
                                    isActive: isActive,
                                    distance: distance,
                                    index: index
                                )
                            }

                            // Reduced spacer at bottom - use more space
                            Spacer()
                                .frame(height: geometry.size.height / 2 - 40)
                        }
                    }
                    .disabled(true)  // Disable user scrolling - auto-scroll only

                    // Fade gradients at top and bottom
                    VStack(spacing: 0) {
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color.black.opacity(0.95),
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
                                Color.black.opacity(0.95)
                            ]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 150)
                    }
                    .allowsHitTesting(false)
                }
                .onChange(of: currentTime) { oldValue, newValue in
                    updateActiveLineAndScroll(for: lines, in: proxy)
                }
                .onAppear {
                    updateActiveLineAndScroll(for: lines, in: proxy)
                }
            }
        }
    }

    private func distanceFromActive(index: Int, lines: [LyricsLine]) -> Int {
        for (i, line) in lines.enumerated() {
            if isLineActive(line, at: i, in: lines) {
                return abs(index - i)
            }
        }
        return 99
    }

    private func lyricLineView(text: String, isActive: Bool, distance: Int, index: Int) -> some View {
        Text(text)
            .font(fontForLine(isActive: isActive, distance: distance))
            .fontWeight(isActive ? .bold : .semibold)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundColor(lineColor(distance: distance, isActive: isActive))
            .multilineTextAlignment(.center)
            .shadow(
                color: isActive ? settings.backgroundColorChoice.color.opacity(0.5) : .clear,
                radius: isActive ? 20 : 0,
                x: 0,
                y: 0
            )
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.vertical, isActive ? 24 : 16)
            .id(index)
            .scaleEffect(isActive ? 1.02 : (distance <= 1 ? 0.97 : 0.94), anchor: .center)
            .opacity(lineOpacity(distance: distance, isActive: isActive))
            .animation(
                .interpolatingSpring(
                    mass: 0.5,
                    stiffness: 200,
                    damping: 20,
                    initialVelocity: 0
                ),
                value: isActive
            )
    }

    private func fontForLine(isActive: Bool, distance: Int) -> Font {
        if isActive {
            return .system(size: 26, weight: .bold)
        } else if distance <= 1 {
            return .system(size: 19, weight: .semibold)
        } else {
            return .system(size: 16, weight: .medium)
        }
    }

    private func lineColor(distance: Int, isActive: Bool) -> Color {
        if isActive {
            return .white
        } else if distance <= 1 {
            return .white.opacity(0.7)
        } else if distance <= 2 {
            return .white.opacity(0.35)
        } else {
            return .white.opacity(0.15)
        }
    }

    private func lineOpacity(distance: Int, isActive: Bool) -> Double {
        if isActive {
            return 1.0
        } else if distance <= 1 {
            return 0.9
        } else if distance <= 2 {
            return 0.6
        } else if distance <= 3 {
            return 0.3
        } else {
            return 0.15  // Show distant lines dimly instead of hiding
        }
    }

    // MARK: - Plain Lyrics

    private func plainLyricsView(_ text: String) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // Top padding
                Spacer()
                    .frame(height: 24)

                Text(text)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .lineSpacing(10)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 16)

                // Bottom padding
                Spacer()
                    .frame(height: 40)
            }
        }
        .padding(.top, 20)
    }

    // MARK: - States

    private var instrumentalView: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 32) {
                // Animated icon with glass background
                ZStack {
                    // Large outer glow
                    Circle()
                        .fill(
                            RadialGradient(
                                gradient: Gradient(colors: [
                                    settings.backgroundColorChoice.color.opacity(0.4),
                                    settings.backgroundColorChoice.color.opacity(0.2),
                                    settings.backgroundColorChoice.color.opacity(0.05),
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
                                            settings.backgroundColorChoice.color.opacity(0.6),
                                            settings.backgroundColorChoice.color.opacity(0.3),
                                            settings.backgroundColorChoice.color.opacity(0.1)
                                        ]),
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 2
                                )
                        )
                        .frame(width: 120, height: 120)
                        .shadow(
                            color: settings.backgroundColorChoice.color.opacity(0.3),
                            radius: 25,
                            x: 0,
                            y: 10
                        )

                    Image(systemName: "music.note")
                        .font(.system(size: 50, weight: .medium))
                        .foregroundColor(.white)
                        .shadow(color: settings.backgroundColorChoice.color.opacity(0.6), radius: 15)
                }

                VStack(spacing: 12) {
                    Text("Instrumental")
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundColor(.white)

                    Text("This track has no lyrics")
                        .font(.callout)
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .padding(44)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 28)
                        .fill(.ultraThinMaterial)

                    RoundedRectangle(cornerRadius: 28)
                        .stroke(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    settings.backgroundColorChoice.color.opacity(0.3),
                                    Color.white.opacity(0.15),
                                    settings.backgroundColorChoice.color.opacity(0.2)
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
                                    settings.backgroundColorChoice.color.opacity(0.05),
                                    Color.clear,
                                    settings.backgroundColorChoice.color.opacity(0.08)
                                ]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .shadow(color: settings.backgroundColorChoice.color.opacity(0.2), radius: 35, x: 0, y: 15)
            )
            .padding(.horizontal, 40)

            Spacer()
        }
    }

    private var noLyricsView: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 32) {
                // Animated icon with glass background
                ZStack {
                    // Large outer glow
                    Circle()
                        .fill(
                            RadialGradient(
                                gradient: Gradient(colors: [
                                    settings.backgroundColorChoice.color.opacity(0.4),
                                    settings.backgroundColorChoice.color.opacity(0.2),
                                    settings.backgroundColorChoice.color.opacity(0.05),
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
                                            settings.backgroundColorChoice.color.opacity(0.6),
                                            settings.backgroundColorChoice.color.opacity(0.3),
                                            settings.backgroundColorChoice.color.opacity(0.1)
                                        ]),
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 2
                                )
                        )
                        .frame(width: 120, height: 120)
                        .shadow(
                            color: settings.backgroundColorChoice.color.opacity(0.3),
                            radius: 25,
                            x: 0,
                            y: 10
                        )

                    Image(systemName: "text.badge.xmark")
                        .font(.system(size: 50, weight: .medium))
                        .foregroundColor(.white)
                        .shadow(color: settings.backgroundColorChoice.color.opacity(0.6), radius: 15)
                }

                VStack(spacing: 12) {
                    Text("No Lyrics Available")
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundColor(.white)

                    Text("Lyrics not found for this track")
                        .font(.callout)
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .padding(44)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 28)
                        .fill(.ultraThinMaterial)

                    RoundedRectangle(cornerRadius: 28)
                        .stroke(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    settings.backgroundColorChoice.color.opacity(0.3),
                                    Color.white.opacity(0.15),
                                    settings.backgroundColorChoice.color.opacity(0.2)
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
                                    settings.backgroundColorChoice.color.opacity(0.05),
                                    Color.clear,
                                    settings.backgroundColorChoice.color.opacity(0.08)
                                ]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .shadow(color: settings.backgroundColorChoice.color.opacity(0.2), radius: 35, x: 0, y: 15)
            )
            .padding(.horizontal, 40)

            Spacer()
        }
    }

    private var loadingView: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 32) {
                // Animated loading with glass background
                ZStack {
                    // Large outer glow - animated
                    Circle()
                        .fill(
                            RadialGradient(
                                gradient: Gradient(colors: [
                                    settings.backgroundColorChoice.color.opacity(0.4),
                                    settings.backgroundColorChoice.color.opacity(0.2),
                                    settings.backgroundColorChoice.color.opacity(0.05),
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
                                            settings.backgroundColorChoice.color.opacity(0.6),
                                            settings.backgroundColorChoice.color.opacity(0.3),
                                            settings.backgroundColorChoice.color.opacity(0.1)
                                        ]),
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 2
                                )
                        )
                        .frame(width: 120, height: 120)
                        .shadow(
                            color: settings.backgroundColorChoice.color.opacity(0.3),
                            radius: 25,
                            x: 0,
                            y: 10
                        )

                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.5)
                }

                VStack(spacing: 12) {
                    Text("Loading Lyrics")
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundColor(.white)

                    Text("Fetching from metadata and online sources")
                        .font(.callout)
                        .foregroundColor(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                }
            }
            .padding(44)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 28)
                        .fill(.ultraThinMaterial)

                    RoundedRectangle(cornerRadius: 28)
                        .stroke(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    settings.backgroundColorChoice.color.opacity(0.3),
                                    Color.white.opacity(0.15),
                                    settings.backgroundColorChoice.color.opacity(0.2)
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
                                    settings.backgroundColorChoice.color.opacity(0.05),
                                    Color.clear,
                                    settings.backgroundColorChoice.color.opacity(0.08)
                                ]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .shadow(color: settings.backgroundColorChoice.color.opacity(0.2), radius: 35, x: 0, y: 15)
            )
            .padding(.horizontal, 40)

            Spacer()
        }
    }

    // MARK: - Helper Methods

    private func isLineActive(_ line: LyricsLine, at index: Int, in lines: [LyricsLine]) -> Bool {
        guard let currentTimestamp = line.timestamp else { return false }

        // Check if this is the current line
        if currentTime >= currentTimestamp {
            // Check if there's a next line
            if index + 1 < lines.count {
                if let nextTimestamp = lines[index + 1].timestamp {
                    return currentTime < nextTimestamp
                }
            }
            return true // Last line
        }

        return false
    }

    private func updateActiveLineAndScroll(for lines: [LyricsLine], in proxy: ScrollViewProxy) {
        for (index, line) in lines.enumerated() {
            if isLineActive(line, at: index, in: lines) {
                withAnimation(
                    .interpolatingSpring(
                        mass: 1.0,
                        stiffness: 170,
                        damping: 25,
                        initialVelocity: 0
                    )
                ) {
                    proxy.scrollTo(index, anchor: .center)
                }
                break
            }
        }
    }
}

// MARK: - Preview

#Preview {
    LyricsView(
        lyrics: Lyrics(
            plainLyrics: "Sample lyrics\nLine 2\nLine 3",
            syncedLyrics: [
                LyricsLine(timestamp: 0, text: "Sample lyrics"),
                LyricsLine(timestamp: 5, text: "Line 2"),
                LyricsLine(timestamp: 10, text: "Line 3")
            ],
            isInstrumental: false,
            source: .embedded
        ),
        currentTime: 6.0,
        isLoading: false
    )
}
