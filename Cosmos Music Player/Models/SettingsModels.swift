import Foundation
import SwiftUI
import UIKit

extension Notification.Name {
    /// Posted only when Cosmos UI settings change. Playback persistence also
    /// writes to UserDefaults, so views must not observe the broad
    /// UserDefaults.didChangeNotification or every state save rebuilds the
    /// library hierarchy while audio is playing.
    static let cosmosSettingsDidChange = Notification.Name("CosmosSettingsDidChange")
}

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

/// How long the app waits before it will automatically rescan the library on
/// launch.
///
/// iOS terminates backgrounded apps freely, so a "cold launch" happens far
/// more often than users think - reopening after a couple of hours is usually
/// a fresh start. A short window therefore meant a full scan of a large
/// library most times the app was opened, which is slow and costs battery for
/// nothing when no files have changed. The sync button rescans on demand
/// regardless of this setting.
enum LibraryScanInterval: String, CaseIterable, Codable {
    case everyLaunch
    case hourly
    case daily
    case weekly
    case manualOnly

    /// Hours that must pass before another automatic scan. `nil` never scans
    /// automatically at all.
    var cooldownHours: Double? {
        switch self {
        case .everyLaunch: return 0
        case .hourly: return 1
        case .daily: return 24
        case .weekly: return 24 * 7
        case .manualOnly: return nil
        }
    }

    var displayName: String {
        switch self {
        case .everyLaunch: return Localized.scanEveryLaunch
        case .hourly: return Localized.scanHourly
        case .daily: return Localized.scanDaily
        case .weekly: return Localized.scanWeekly
        case .manualOnly: return Localized.scanManualOnly
        }
    }
}

/// Which artists the Artists screen lists.
///
/// A 12-track album with guests on ten of them contributes ten single-track
/// artists to the library. Listing only album artists keeps the screen to the
/// people who actually own records, the way Apple Music, Plex and foobar2000
/// do; every artist is still reachable from a track's own credits, and from
/// this screen with the mode switched.
enum ArtistListMode: String, CaseIterable, Codable {
    case albumArtists
    case allArtists

    var displayName: String {
        switch self {
        case .albumArtists: return Localized.albumArtists
        case .allArtists: return Localized.allArtists
        }
    }
}

/// How the app picks between light and dark, independent of the system.
///
/// Replaces the old `forceDarkMode` switch, which could only ever override in
/// one direction: someone on a dark-themed phone had no way to ask Cosmos for
/// a light interface.
enum AppearanceMode: String, CaseIterable, Codable {
    case system
    case light
    case dark

    var displayName: String {
        switch self {
        case .system: return Localized.appearanceSystem
        case .light: return Localized.appearanceLight
        case .dark: return Localized.appearanceDark
        }
    }

    /// nil hands the choice back to the system, which is what `.system` means.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
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
    var appearance: AppearanceMode = .system
    /// Legacy mirror of `appearance`, kept only so a build without this setting
    /// - an older version the user rolls back to - still finds the dark
    /// override where it expects it. `save()` keeps it in step; nothing reads it.
    var forceDarkMode: Bool = false
    var dsdPlaybackMode: DSDPlaybackMode = .pcm
    var deleteFromLibraryOnly: Bool = true
    var lastLibraryScanDate: Date? = nil
    var autoCreateFolderPlaylists: Bool = true
    var showLyricsButton: Bool = true
    var showSleepTimerButton: Bool = false
    var libraryScanInterval: LibraryScanInterval = .daily
    var artistListMode: ArtistListMode = .albumArtists
    /// Whether tapping a row while a search is narrowing a list queues the
    /// whole list rather than just the matches.
    var queueFullListFromSearch: Bool = false
    /// Whether a comma in an artist tag separates two artists.
    ///
    /// Off by default, and deliberately so: a comma is the one separator that
    /// is also part of real names - "Earth, Wind & Fire", "Tyler, The Creator",
    /// "Crosby, Stills & Nash" - and no text-only rule tells the two uses
    /// apart. Taggers that mean "several artists" overwhelmingly write ";" or
    /// "\\", which are split unconditionally. This is for libraries that use
    /// commas anyway.
    var splitArtistsOnComma: Bool = false

    // Home screen section visibility & order
    var homeSections: [HomeSectionItem] = HomeSectionItem.defaultSections

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasShownDeletePopup = try container.decodeIfPresent(Bool.self, forKey: .hasShownDeletePopup) ?? false
        minimalistIcons = try container.decodeIfPresent(Bool.self, forKey: .minimalistIcons) ?? false
        backgroundColorChoice = try container.decodeIfPresent(BackgroundColor.self, forKey: .backgroundColorChoice) ?? .violet
        forceDarkMode = try container.decodeIfPresent(Bool.self, forKey: .forceDarkMode) ?? false
        // Existing installs have only the old boolean. "Force dark on" becomes
        // .dark; "off" becomes .system rather than .light, because off never
        // meant "always light" - it meant "follow the system".
        appearance = try container.decodeIfPresent(AppearanceMode.self, forKey: .appearance)
            ?? (forceDarkMode ? .dark : .system)
        dsdPlaybackMode = try container.decodeIfPresent(DSDPlaybackMode.self, forKey: .dsdPlaybackMode) ?? .pcm
        // Default to app-only deletion - deleting the user's actual files
        // should always be an explicit opt-in
        deleteFromLibraryOnly = try container.decodeIfPresent(Bool.self, forKey: .deleteFromLibraryOnly) ?? true
        lastLibraryScanDate = try container.decodeIfPresent(Date.self, forKey: .lastLibraryScanDate)
        autoCreateFolderPlaylists = try container.decodeIfPresent(Bool.self, forKey: .autoCreateFolderPlaylists) ?? true
        showLyricsButton = try container.decodeIfPresent(Bool.self, forKey: .showLyricsButton) ?? true
        showSleepTimerButton = try container.decodeIfPresent(Bool.self, forKey: .showSleepTimerButton) ?? false
        // Both default to the tidier behaviour rather than the historical one:
        // rescanning a large library on nearly every launch, and listing every
        // featured guest alongside the album artists, were the reported bugs.
        libraryScanInterval = try container.decodeIfPresent(LibraryScanInterval.self, forKey: .libraryScanInterval) ?? .daily
        artistListMode = try container.decodeIfPresent(ArtistListMode.self, forKey: .artistListMode) ?? .albumArtists
        // Off by default: queueing only the matches is what the list is
        // showing, so it stays the behaviour nobody has to opt out of.
        queueFullListFromSearch = try container.decodeIfPresent(Bool.self, forKey: .queueFullListFromSearch) ?? false
        splitArtistsOnComma = try container.decodeIfPresent(Bool.self, forKey: .splitArtistsOnComma) ?? false

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
        var settings = self
        settings.forceDarkMode = (settings.appearance == .dark)

        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "DeleteSettings")
            let notify = {
                NotificationCenter.default.post(name: .cosmosSettingsDidChange, object: nil)
            }
            if Thread.isMainThread {
                notify()
            } else {
                DispatchQueue.main.async(execute: notify)
            }
        }
    }

    // MARK: - Excluded Tracks (library-only deletions)

    /// What was on disk when the user removed a track from the library.
    ///
    /// A stable id is a hash of the file's path, so a file deleted from the
    /// Music folder and copied back gets the *same* id. A filesystem resource
    /// identity distinguishes that replacement from the original file without
    /// mistaking a tag edit or an unavailable cloud path for a new song.
    struct ExcludedTrack: Codable {
        var path: String?
        var modificationDate: Int64?
        var fileIdentity: String?
    }

    private static let excludedTracksKey = "ExcludedTrackStableIds"
    private static let excludedTrackDetailsKey = "ExcludedTrackDetails"

    static func addExcludedTrack(_ stableId: String, path: String? = nil, modificationDate: Int64? = nil) {
        var excluded = excludedTracks()
        excluded[stableId] = ExcludedTrack(
            path: path,
            modificationDate: modificationDate,
            fileIdentity: path.flatMap { exclusionFileIdentity(atPath: $0) }
        )
        saveExcludedTracks(excluded)
    }

    static func isTrackExcluded(_ stableId: String) -> Bool {
        return excludedTracks()[stableId] != nil
    }

    static func removeExcludedTrack(_ stableId: String) {
        var excluded = excludedTracks()
        guard excluded.removeValue(forKey: stableId) != nil else { return }
        saveExcludedTracks(excluded)
    }

    static func excludedTrackDetails(_ stableId: String) -> ExcludedTrack? {
        return excludedTracks()[stableId]
    }

    /// Records what an exclusion refers to, for entries written before those
    /// details were stored. Without this a legacy exclusion could never be
    /// resolved either way.
    static func adoptExclusionDetails(_ stableId: String, path: String, modificationDate: Int64?) {
        var excluded = excludedTracks()
        guard excluded[stableId] != nil else { return }
        excluded[stableId] = ExcludedTrack(
            path: path,
            modificationDate: modificationDate,
            fileIdentity: exclusionFileIdentity(atPath: path)
        )
        saveExcludedTracks(excluded)
    }

    /// An opaque identity for the file currently occupying a path.
    ///
    /// The volume + inode pair is preferred, because it is the only one of the
    /// two that is meaningful once written down. Apple documents
    /// `fileResourceIdentifierKey` as **not persistent across system
    /// restarts**, and this value is persisted to UserDefaults and compared on
    /// a later launch: preferring it meant a reboot could make an unchanged
    /// file look replaced, which drops the exclusion and resurrects a track the
    /// user removed from the library.
    ///
    /// It is still recorded, as a suffix, for ubiquitous items and for document
    /// providers where no inode is available - materialising a placeholder can
    /// replace its inode without replacing the document, so inode alone is not
    /// safe there either. Consumers must therefore treat a mismatch as *weak*
    /// evidence; see `LibraryIndexer.isStillExcluded`, which also requires the
    /// modification date to have moved.
    static func exclusionFileIdentity(atPath path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [
            .fileResourceIdentifierKey,
            .isUbiquitousItemKey
        ])

        if values?.isUbiquitousItem != true,
           let attributes = try? FileManager.default.attributesOfItem(atPath: path),
           let volume = attributes[.systemNumber] as? NSNumber,
           let inode = attributes[.systemFileNumber] as? NSNumber {
            return "inode:\(volume.stringValue):\(inode.stringValue)"
        }

        if let identifier = values?.fileResourceIdentifier {
            if let data = identifier as? Data {
                return "resource:\(data.base64EncodedString())"
            }
            if let number = identifier as? NSNumber {
                return "resource:\(number.stringValue)"
            }
            if let string = identifier as? String {
                return "resource:\(string)"
            }
        }

        return nil
    }

    /// Whether an identity mismatch is trustworthy enough to act on.
    ///
    /// Only inode identities are. A `resource:` identity comes from
    /// `fileResourceIdentifierKey`, which iOS may reissue across a restart for
    /// a file nobody touched.
    static func exclusionIdentityIsDurable(_ identity: String?) -> Bool {
        identity?.hasPrefix("inode:") ?? false
    }

    private static func excludedTracks() -> [String: ExcludedTrack] {
        if let data = UserDefaults.standard.data(forKey: excludedTrackDetailsKey),
           let decoded = try? JSONDecoder().decode([String: ExcludedTrack].self, from: data) {
            return decoded
        }

        // Migrate the original flat list of ids. Their files cannot be located
        // any more, so they carry no details until a scan adopts them.
        let legacy = UserDefaults.standard.stringArray(forKey: excludedTracksKey) ?? []
        guard !legacy.isEmpty else { return [:] }
        var migrated: [String: ExcludedTrack] = [:]
        for stableId in legacy {
            migrated[stableId] = ExcludedTrack(path: nil, modificationDate: nil, fileIdentity: nil)
        }
        saveExcludedTracks(migrated)
        return migrated
    }

    private static func saveExcludedTracks(_ excluded: [String: ExcludedTrack]) {
        guard let data = try? JSONEncoder().encode(excluded) else { return }
        UserDefaults.standard.set(data, forKey: excludedTrackDetailsKey)
        // Keep the legacy key in step for anything still reading it directly.
        UserDefaults.standard.set(Array(excluded.keys), forKey: excludedTracksKey)
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
