//
//  PlaylistWidget.swift
//  PlayerWidget
//
//  Horizontal scrollable playlist browser widget with album art mashup
//

import WidgetKit
import SwiftUI

// MARK: - Color Extension (fix for crash)
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

// MARK: - Playlist Widget Provider
struct PlaylistWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlaylistWidgetEntry {
        PlaylistWidgetEntry(
            date: Date(),
            playlists: [
                WidgetPlaylistData(id: "1", name: "Favorites", trackCount: 25, colorHex: "FF6B9D", artworkPaths: [])
            ]
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (PlaylistWidgetEntry) -> Void) {
        let playlists = PlaylistDataManager.shared.getPlaylists()
        let entry = PlaylistWidgetEntry(date: Date(), playlists: playlists)
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PlaylistWidgetEntry>) -> Void) {
        print("🔄 Playlist Widget Timeline: getTimeline called")

        let playlists = PlaylistDataManager.shared.getPlaylists()
        let entry = PlaylistWidgetEntry(date: Date(), playlists: playlists)

        // Refresh every hour
        let nextUpdate = Date().addingTimeInterval(3600)
        print("⏰ Playlist Widget Timeline: Next update in 1 hour, \(playlists.count) playlists")
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

// MARK: - Playlist Widget Entry
struct PlaylistWidgetEntry: TimelineEntry {
    let date: Date
    let playlists: [WidgetPlaylistData]
}

// MARK: - Playlist Widget View
struct PlaylistWidgetView: View {
    let entry: PlaylistWidgetEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        MediumPlaylistView(playlists: entry.playlists)
    }
}

// MARK: - Medium Playlist View
struct MediumPlaylistView: View {
    let playlists: [WidgetPlaylistData]

    private var themeColor: Color {
        // Use the theme color from settings (stored in playlist data)
        if let firstPlaylist = playlists.first {
            return Color(hex: firstPlaylist.colorHex)
        } else {
            return Color(hex: "b11491") // Default violet
        }
    }

    var body: some View {
        ZStack {
            // Gradient background matching PlayerWidget design - EXACT SAME
            LinearGradient(
                gradient: Gradient(colors: [
                    themeColor.opacity(0.2),
                    themeColor.opacity(0.05)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Glass effect overlay - EXACT SAME
            Color.white.opacity(0.1)

            // Fixed grid of playlists (widgets don't support scrolling)
            if playlists.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 32, weight: .light))
                        .foregroundColor(.secondary.opacity(0.5))

                    Text("No playlists yet")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Show up to 3 playlists in a horizontal layout
                HStack(spacing: 12) {
                    ForEach(Array(playlists.prefix(3)), id: \.id) { playlist in
                        PlaylistCard(playlist: playlist, themeColor: themeColor)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Playlist Card
struct PlaylistCard: View {
    let playlist: WidgetPlaylistData
    let themeColor: Color

    var body: some View {
        Link(destination: URL(string: "cosmos-music://playlist/\(playlist.id)")!) {
            VStack(spacing: 8) {
                // Album cover mashup (2x2 grid) - matching app's design
                VStack(spacing: 2) {
                    HStack(spacing: 2) {
                        // Top left
                        artworkTile(index: 0, opacity: 0.6)
                        // Top right
                        artworkTile(index: 1, opacity: 0.5)
                    }
                    HStack(spacing: 2) {
                        // Bottom left
                        artworkTile(index: 2, opacity: 0.45)
                        // Bottom right
                        artworkTile(index: 3, opacity: 0.55)
                    }
                }
                .frame(width: 100, height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)

                // Playlist title and song count
                VStack(spacing: 2) {
                    Text(playlist.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .frame(width: 100)

                    Text("\(playlist.trackCount) \(playlist.trackCount == 1 ? "song" : "songs")")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func artworkTile(index: Int, opacity: Double) -> some View {
        // Ensure each tile shows a DIFFERENT artwork - no duplicates
        if index < playlist.artworkPaths.count, !playlist.artworkPaths[index].isEmpty {
            // Load artwork from shared container file
            if let artworkData = loadArtworkFromFile(playlist.artworkPaths[index]),
               let uiImage = UIImage(data: artworkData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 49, height: 49)
                    .clipped()
            } else {
                placeholderTile(opacity: opacity)
            }
        } else {
            // Show placeholder if we don't have enough unique artworks
            placeholderTile(opacity: opacity)
        }
    }

    @ViewBuilder
    private func placeholderTile(opacity: Double) -> some View {
        ZStack {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [themeColor.opacity(opacity), themeColor.opacity(opacity * 0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 49, height: 49)

            Image(systemName: "music.note")
                .font(.system(size: 16, weight: .light))
                .foregroundColor(.white.opacity(0.7))
        }
    }

    private func loadArtworkFromFile(_ filename: String) -> Data? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.dev.clq.Cosmos-Music-Player"
        ) else {
            return nil
        }

        let fileURL = containerURL.appendingPathComponent(filename)
        return try? Data(contentsOf: fileURL)
    }
}

// MARK: - Playlist Widget Configuration
struct PlaylistWidget: Widget {
    let kind: String = "PlaylistWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PlaylistWidgetProvider()) { entry in
            PlaylistWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    Color.clear
                }
        }
        .configurationDisplayName("My Playlists")
        .description("Quick access to your 3 most recently played playlists")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

// MARK: - Preview
#Preview(as: .systemMedium) {
    PlaylistWidget()
} timeline: {
    PlaylistWidgetEntry(
        date: Date(),
        playlists: [
            WidgetPlaylistData(id: "1", name: "Favorites", trackCount: 25, colorHex: "FF6B9D", artworkPaths: []),
            WidgetPlaylistData(id: "2", name: "Chill Vibes", trackCount: 30, colorHex: "FF6B9D", artworkPaths: []),
            WidgetPlaylistData(id: "3", name: "Workout Mix", trackCount: 45, colorHex: "FF6B9D", artworkPaths: [])
        ]
    )
}
