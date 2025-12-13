//
//  PlayerWidget.swift
//  PlayerWidget
//
//  Now Playing Widget for Cosmos Music Player
//

import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Color Extension
fileprivate extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 255, 107, 157)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}

// MARK: - Widget Timeline Provider
struct PlayerWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> WidgetEntry {
        WidgetEntry(
            date: Date(),
            trackData: WidgetTrackData(
                trackId: "placeholder",
                title: "Song Title",
                artist: "Artist Name",
                isPlaying: false,
                backgroundColorHex: "FF6B9D"
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (WidgetEntry) -> Void) {
        let entry: WidgetEntry
        if let trackData = WidgetDataManager.shared.getCurrentTrack() {
            entry = WidgetEntry(date: Date(), trackData: trackData)
        } else {
            entry = WidgetEntry(
                date: Date(),
                trackData: WidgetTrackData(
                    trackId: "none",
                    title: "No Music Playing",
                    artist: "Open Cosmos to start",
                    isPlaying: false,
                    backgroundColorHex: "FF6B9D"
                )
            )
        }
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        print("🔄 Widget Timeline: getTimeline called")
        let currentDate = Date()
        let entry: WidgetEntry

        if let trackData = WidgetDataManager.shared.getCurrentTrack() {
            print("✅ Widget Timeline: Got track data - \(trackData.title)")
            entry = WidgetEntry(date: currentDate, trackData: trackData)
        } else {
            print("⚠️ Widget Timeline: No track data available, showing placeholder")
            entry = WidgetEntry(
                date: currentDate,
                trackData: WidgetTrackData(
                    trackId: "none",
                    title: "No Music Playing",
                    artist: "Open Cosmos to start",
                    isPlaying: false,
                    backgroundColorHex: "FF6B9D"
                )
            )
        }

        // Refresh every 15 seconds when music is playing
        let nextUpdate = entry.trackData.isPlaying ? Date().addingTimeInterval(15) : Date().addingTimeInterval(60)
        print("⏰ Widget Timeline: Next update in \(entry.trackData.isPlaying ? "15" : "60") seconds")
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

// MARK: - Widget Entry
struct WidgetEntry: TimelineEntry {
    let date: Date
    let trackData: WidgetTrackData
}

// MARK: - Widget View
struct PlayerWidgetView: View {
    let entry: WidgetEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemMedium:
            MediumWidgetView(entry: entry)
        default:
            MediumWidgetView(entry: entry)
        }
    }
}

// MARK: - Medium Widget (Main)
struct MediumWidgetView: View {
    let entry: WidgetEntry

    private var themeColor: Color {
        Color(hex: entry.trackData.backgroundColorHex)
    }

    var body: some View {
        ZStack {
            // Gradient background matching app design
            LinearGradient(
                gradient: Gradient(colors: [
                    themeColor.opacity(0.2),
                    themeColor.opacity(0.05)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Glass effect overlay
            Color.white.opacity(0.1)

            // Content
            HStack(spacing: 16) {
                // Album Artwork (Left) - loaded from file to avoid 4MB UserDefaults limit
                if let artworkData = WidgetDataManager.shared.getArtwork(),
                   let uiImage = UIImage(data: artworkData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 130, height: 130)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        themeColor.opacity(0.4),
                                        themeColor.opacity(0.2)
                                    ]),
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        Image(systemName: "music.note")
                            .font(.system(size: 40, weight: .light))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .frame(width: 130, height: 130)
                    .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
                }

                // Track Info and Controls (Right)
                VStack(alignment: .leading, spacing: 10) {
                    // Track info
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.trackData.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)

                        Text(entry.trackData.artist)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    // Status indicator
                    HStack(spacing: 8) {
                        if entry.trackData.isPlaying {
                            Image(systemName: "waveform")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [themeColor, themeColor.opacity(0.8)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .symbolEffect(.variableColor.iterative, isActive: true)

                            Text("Now Playing")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(themeColor)
                        } else {
                            Image(systemName: "pause.circle.fill")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.secondary)

                            Text("Paused")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .padding(16)
        }
    }
}

// MARK: - Widget Configuration
struct PlayerWidget: Widget {
    let kind: String = "PlayerWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PlayerWidgetProvider()) { entry in
            PlayerWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    Color.clear
                }
        }
        .configurationDisplayName("Now Playing")
        .description("Control your music playback from your home screen")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}
