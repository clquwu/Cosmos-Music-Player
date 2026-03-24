import Foundation
import SwiftUI
import UIKit

enum BackgroundColor: String, CaseIterable, Codable {
    case violet = "b11491"
    case red = "e74c3c"
    case blue = "3498db" 
    case green = "27ae60"
    case orange = "f39c12"
    case pink = "e91e63"
    case teal = "1abc9c"
    case purple = "9b59b6"
    
    var name: String {
        switch self {
        case .violet: return "Violet (Default)"
        case .red: return "Red"
        case .blue: return "Blue"
        case .green: return "Green"
        case .orange: return "Orange"
        case .pink: return "Pink"
        case .teal: return "Teal"
        case .purple: return "Purple"
        }
    }
    
    var color: Color {
        return Color(hex: self.rawValue)
    }
}

enum DSDPlaybackMode: String, CaseIterable, Codable {
    case auto = "auto"
    case pcm = "pcm"
    case dop = "dop"

    var displayName: String {
        switch self {
        case .auto: return Localized.dsdModeAuto
        case .pcm: return Localized.dsdModePCM
        case .dop: return Localized.dsdModeDoP
        }
    }

    var description: String {
        switch self {
        case .auto: return Localized.dsdModeAutoDescription
        case .pcm: return Localized.dsdModePCMDescription
        case .dop: return Localized.dsdModeDoDescription
        }
    }
}

enum HomeSectionId: String, Codable, CaseIterable {
    case allSongs
    case likedSongs
    case playlists
    case artists
    case albums
    case addSongs

    var displayName: String {
        switch self {
        case .allSongs: return Localized.allSongs
        case .likedSongs: return Localized.likedSongs
        case .playlists: return Localized.playlists
        case .artists: return Localized.artists
        case .albums: return Localized.albums
        case .addSongs: return Localized.addSongs
        }
    }

    var icon: String {
        switch self {
        case .allSongs: return "music.note"
        case .likedSongs: return "heart.fill"
        case .playlists: return "music.note.list"
        case .artists: return "person.2.fill"
        case .albums: return "opticaldisc.fill"
        case .addSongs: return "plus.circle.fill"
        }
    }
}

struct HomeSectionItem: Codable, Identifiable, Equatable {
    var id: HomeSectionId
    var isVisible: Bool

    static let defaultSections: [HomeSectionItem] = [
        HomeSectionItem(id: .allSongs, isVisible: true),
        HomeSectionItem(id: .likedSongs, isVisible: true),
        HomeSectionItem(id: .playlists, isVisible: true),
        HomeSectionItem(id: .artists, isVisible: true),
        HomeSectionItem(id: .albums, isVisible: true),
        HomeSectionItem(id: .addSongs, isVisible: true),
    ]
}

struct DeleteSettings: Codable {
    var hasShownDeletePopup: Bool = false
    var minimalistIcons: Bool = false
    var backgroundColorChoice: BackgroundColor = .violet
    var forceDarkMode: Bool = false
    var dsdPlaybackMode: DSDPlaybackMode = .pcm
    var deleteFromLibraryOnly: Bool = false
    var lastLibraryScanDate: Date? = nil

    // Home screen section visibility & order
    var homeSections: [HomeSectionItem] = HomeSectionItem.defaultSections

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasShownDeletePopup = try container.decodeIfPresent(Bool.self, forKey: .hasShownDeletePopup) ?? false
        minimalistIcons = try container.decodeIfPresent(Bool.self, forKey: .minimalistIcons) ?? false
        backgroundColorChoice = try container.decodeIfPresent(BackgroundColor.self, forKey: .backgroundColorChoice) ?? .violet
        forceDarkMode = try container.decodeIfPresent(Bool.self, forKey: .forceDarkMode) ?? false
        dsdPlaybackMode = try container.decodeIfPresent(DSDPlaybackMode.self, forKey: .dsdPlaybackMode) ?? .pcm
        deleteFromLibraryOnly = try container.decodeIfPresent(Bool.self, forKey: .deleteFromLibraryOnly) ?? false
        lastLibraryScanDate = try container.decodeIfPresent(Date.self, forKey: .lastLibraryScanDate)

        var decoded = try container.decodeIfPresent([HomeSectionItem].self, forKey: .homeSections) ?? HomeSectionItem.defaultSections
        // Ensure any new sections added in future updates are included
        let existingIds = Set(decoded.map(\.id))
        for defaultSection in HomeSectionItem.defaultSections where !existingIds.contains(defaultSection.id) {
            decoded.append(defaultSection)
        }
        homeSections = decoded
    }

    static func load() -> DeleteSettings {
        guard let data = UserDefaults.standard.data(forKey: "DeleteSettings"),
              let settings = try? JSONDecoder().decode(DeleteSettings.self, from: data) else {
            return DeleteSettings()
        }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "DeleteSettings")
        }
    }

    // MARK: - Excluded Tracks (library-only deletions)

    private static let excludedTracksKey = "ExcludedTrackStableIds"

    static func addExcludedTrack(_ stableId: String) {
        var excluded = excludedTrackIds()
        excluded.insert(stableId)
        UserDefaults.standard.set(Array(excluded), forKey: excludedTracksKey)
    }

    static func isTrackExcluded(_ stableId: String) -> Bool {
        return excludedTrackIds().contains(stableId)
    }

    static func removeExcludedTrack(_ stableId: String) {
        var excluded = excludedTrackIds()
        excluded.remove(stableId)
        UserDefaults.standard.set(Array(excluded), forKey: excludedTracksKey)
    }

    private static func excludedTrackIds() -> Set<String> {
        let array = UserDefaults.standard.stringArray(forKey: excludedTracksKey) ?? []
        return Set(array)
    }
}

// MARK: - Color Extension for Widget
extension Color {
    func toHex() -> String {
        #if canImport(UIKit)
        let components = UIColor(self).cgColor.components
        let r = Float(components?[0] ?? 0)
        let g = Float(components?[1] ?? 0)
        let b = Float(components?[2] ?? 0)

        return String(format: "%02lX%02lX%02lX",
                      lroundf(r * 255),
                      lroundf(g * 255),
                      lroundf(b * 255))
        #else
        return "b11491" // Default violet
        #endif
    }
}
