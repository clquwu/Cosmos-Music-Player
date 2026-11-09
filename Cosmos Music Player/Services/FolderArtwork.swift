//
//  FolderArtwork.swift
//  Cosmos Music Player
//
//  Covers kept as image files next to the songs (cover.jpg, folder.png...),
//  for songs that carry no embedded artwork.
//

import Foundation
@preconcurrency import GRDB

/// Finds the cover image in a song's folder, once per folder.
///
/// Only names are looked at: the scan lists the folder and never opens an
/// image, so nothing in iCloud is downloaded to find a cover. ArtworkManager
/// reads the file when the cover is first drawn.
///
/// Results are cached per folder against the folder's modification date,
/// which changes whenever a file in it is added, removed or renamed - the
/// only things that can change the answer. A rescan of an unchanged library
/// therefore stats each folder and lists none of them.
final class FolderArtworkIndex: @unchecked Sendable {
    static let shared = FolderArtworkIndex()

    /// In priority order: the first name that exists wins.
    static let preferredNames = ["cover", "folder", "front", "album", "albumart", "artwork"]
    static let imageExtensions = ["jpg", "jpeg", "png", "webp"]

    private struct Entry: Codable {
        let folderModification: Int64?
        /// The parent's, for a disc folder whose cover may live one level up.
        let parentModification: Int64?
        let artworkPath: String?
    }

    /// What a folder's cover is, or that the folder could not be read - which
    /// must not be mistaken for "has no cover" and clear one already known.
    enum Lookup: Equatable {
        case found(String?)
        case unreadable
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var isDirty = false
    private let fileURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("FolderArtworkCache.plist")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? PropertyListDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        }
    }

    /// The cover image for the song at `trackPath`, or nil when its folder
    /// has none or cannot be read.
    func artworkPath(forTrackAt trackPath: String) -> String? {
        let folder = URL(fileURLWithPath: trackPath).deletingLastPathComponent()
        if case .found(let path) = lookup(folder: folder) {
            return path
        }
        return nil
    }

    /// The cover image for a folder of songs.
    func lookup(folder: URL) -> Lookup {
        let key = DatabaseManager.canonicalPath(folder.path)
        guard let folderModification = Self.modificationDate(of: folder) else {
            return .unreadable
        }

        let isDiscFolder = Self.isDiscFolder(folder.lastPathComponent)
        let parent = folder.deletingLastPathComponent()
        let parentModification = isDiscFolder ? Self.modificationDate(of: parent) : nil

        if let cached = lock.withLock({ entries[key] }),
           cached.folderModification == folderModification,
           cached.parentModification == parentModification {
            return .found(cached.artworkPath)
        }

        var image = Self.coverImage(in: folder)
        // "CD1", "Disc 2": the album's cover usually sits beside the disc
        // folders rather than in each of them.
        if image == nil, isDiscFolder {
            image = Self.coverImage(in: parent)
        }

        let entry = Entry(
            folderModification: folderModification,
            parentModification: parentModification,
            artworkPath: image.map { DatabaseManager.canonicalPath($0.path) }
        )
        lock.withLock {
            entries[key] = entry
            isDirty = true
        }
        return .found(entry.artworkPath)
    }

    /// Brings `artwork_path` up to date for every song under `roots` whose
    /// folder gained, lost or changed its cover. Songs with embedded artwork
    /// never get one - their own cover comes first.
    /// - Returns: the stable IDs whose folder cover changed, with the new path
    ///   (nil when it went away).
    func refresh(roots: [URL]) -> [String: String?] {
        let rootPrefixes = roots.map { DatabaseManager.canonicalPath($0.path) + "/" }
        guard !rootPrefixes.isEmpty else { return [:] }

        let rows: [(stableId: String, path: String, hasEmbeddedArt: Bool, artworkPath: String?)]
        do {
            rows = try DatabaseManager.shared.read { db in
                try Row.fetchAll(db, sql: "SELECT stable_id, path, has_embedded_art, artwork_path FROM track").map {
                    (
                        stableId: $0["stable_id"] as String,
                        path: $0["path"] as String,
                        hasEmbeddedArt: (($0["has_embedded_art"] as Int?) ?? 0) != 0,
                        artworkPath: $0["artwork_path"] as String?
                    )
                }
            }
        } catch {
            print("⚠️ Folder artwork: could not read tracks: \(error)")
            return [:]
        }

        let byFolder = Dictionary(grouping: rows.filter { row in
            rootPrefixes.contains { row.path.hasPrefix($0) }
        }) { row in
            (row.path as NSString).deletingLastPathComponent
        }

        var changes: [String: String?] = [:]
        for (folderPath, folderRows) in byFolder {
            guard case .found(let artwork) = lookup(folder: URL(fileURLWithPath: folderPath, isDirectory: true)) else {
                continue
            }
            for row in folderRows {
                let wanted = row.hasEmbeddedArt ? nil : artwork
                if wanted != row.artworkPath {
                    changes[row.stableId] = wanted
                }
            }
        }

        if !changes.isEmpty {
            do {
                try DatabaseManager.shared.write { db in
                    for (stableId, path) in changes {
                        try db.execute(
                            sql: "UPDATE track SET artwork_path = ? WHERE stable_id = ?",
                            arguments: [path, stableId]
                        )
                    }
                }
                print("🖼️ Folder artwork: updated \(changes.count) song(s)")
            } catch {
                print("⚠️ Folder artwork: could not save: \(error)")
                return [:]
            }
        }

        flush()
        return changes
    }

    /// Writes the per-folder cache if it changed.
    func flush() {
        let snapshot: [String: Entry]? = lock.withLock {
            guard isDirty else { return nil }
            isDirty = false
            return entries
        }
        guard let snapshot else { return }
        do {
            let data = try PropertyListEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("⚠️ Folder artwork: could not save cache: \(error)")
        }
    }

    // MARK: Finding the image

    /// The folder's cover by name priority, else its only image.
    static func coverImage(in folder: URL) -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let images = contents.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
        guard !images.isEmpty else { return nil }

        for name in preferredNames {
            for ext in imageExtensions {
                if let match = images.first(where: {
                    $0.deletingPathExtension().lastPathComponent.lowercased() == name
                        && $0.pathExtension.lowercased() == ext
                }) {
                    return match
                }
            }
        }

        // An unconventionally named scan is still the cover when it is the
        // only picture there; with several, any guess could be the back.
        return images.count == 1 ? images[0] : nil
    }

    /// "CD1", "CD 2", "Disc 1", "Disk 03", "Disc 2 - Live"...
    static func isDiscFolder(_ name: String) -> Bool {
        name.range(
            of: #"^(cd|disc|disk)[\s._-]*\d+"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func modificationDate(of folder: URL) -> Int64? {
        guard let date = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
            return nil
        }
        return Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
    }
}
