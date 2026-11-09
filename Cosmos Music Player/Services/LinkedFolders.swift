//
//  LinkedFolders.swift
//  Cosmos Music Player
//
//  Music folders linked from the Files app (GitHub #73): which locations may
//  be linked, the security-scoped bookmarks that keep them readable, and the
//  database work for adding, moving and removing them.
//

import Foundation
@preconcurrency import GRDB

/// A folder the user linked from Files. Its songs are indexed where they are -
/// nothing is copied - and read under the folder's security scope.
struct LinkedFolder: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    /// Canonical path the bookmark last resolved to. The songs' stored paths
    /// sit under it.
    var path: String
    var bookmark: Data
    var addedAt: Date
    /// Where the folder used to be, when its bookmark has followed it to a new
    /// place (renamed, moved in iCloud Drive) but the songs' rows still carry
    /// the old paths. The next scan moves them and clears this.
    var formerPaths: [String]
}

// MARK: - Which locations may be linked

/// Decides whether a folder picked in Files can be linked.
///
/// Only places whose files are really on the device, or that iCloud keeps
/// there, scan reliably: On My iPhone, iCloud Drive and drives plugged into
/// the device. Every other provider - Google Drive, OneDrive, Dropbox, SMB
/// servers - hands out a partial, on-demand view of the folder: a walk finds
/// only what happens to be cached, and the next walk finds something else.
/// That is exactly the evidence the deletion safeguards cannot tell from
/// "the user deleted half their library", so those are refused outright.
enum LinkedFolderPolicy {
    enum Verdict: Equatable {
        case allowed
        /// The app's own Documents or iCloud folder, which every scan already reads.
        case alreadyInLibrary
        /// Another provider or a network share.
        case unsupportedLocation
    }

    private static let localStorageGroup = "group.com.apple.FileProvider.LocalStorage"

    static func classify(_ url: URL, appRoots: [URL]) -> Verdict {
        let path = DatabaseManager.canonicalPath(url.path)

        for root in appRoots {
            let rootPath = DatabaseManager.canonicalPath(root.path)
            if path == rootPath || path.hasPrefix(rootPath + "/") {
                return .alreadyInLibrary
            }
        }

        // iCloud Drive, including other apps' folders in it. These are
        // ubiquitous too, which is why this comes before that check below.
        if path.contains("/Mobile Documents/") {
            return .allowed
        }

        let values = try? url.resourceValues(forKeys: [
            .volumeIsLocalKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ])

        // A network volume, whatever presents it.
        if values?.volumeIsLocal == false {
            return .unsupportedLocation
        }

        // Replicated File Provider domains (the modern Google Drive, OneDrive
        // and Dropbox integrations) live under CloudStorage.
        if path.contains("/Library/CloudStorage/") {
            return .unsupportedLocation
        }

        // Drives plugged into the device and servers connected in Files both
        // appear under LiveFiles, named after the file system that serves
        // them: com.apple.filesystems.userfsd/<drive> for a USB drive,
        // com.apple.filesystems.smbclientd/<server> for a share.
        let components = path.split(separator: "/").map(String.init)
        if let index = components.firstIndex(of: "LiveFiles"), index + 1 < components.count {
            let fileSystem = components[index + 1].lowercased()
            let isNetwork = ["smb", "nfs", "webdav", "afp", "ftp"].contains { fileSystem.contains($0) }
            return isNetwork ? .unsupportedLocation : .allowed
        }
        if values?.volumeIsRemovable == true || values?.volumeIsEjectable == true {
            return .allowed
        }

        // On My iPhone and the older third-party providers both keep their
        // files under an app group's "File Provider Storage". Where the group's
        // container metadata can be read it names its owner outright.
        if let owner = fileProviderStorageOwner(ofPath: path) {
            return owner == localStorageGroup ? .allowed : .unsupportedLocation
        }

        // Where it cannot: a sync provider's items are evictable - ubiquitous,
        // with a download status - and outside iCloud Drive nothing else on
        // the device is.
        if values?.isUbiquitousItem == true || values?.ubiquitousItemDownloadingStatus != nil {
            return .unsupportedLocation
        }

        return .allowed
    }

    /// The app group that owns a ".../AppGroup/<UUID>/File Provider Storage/..."
    /// path, when the sandbox lets us read its container metadata.
    private static func fileProviderStorageOwner(ofPath path: String) -> String? {
        guard let range = path.range(of: "/File Provider Storage") else { return nil }
        let groupRoot = URL(fileURLWithPath: String(path[..<range.lowerBound]))
        let metadataURL = groupRoot.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
        guard let data = try? Data(contentsOf: metadataURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        return plist["MCMMetadataIdentifier"] as? String
    }
}

// MARK: - When a missing song proves nothing

/// The extra evidence a linked folder's missing song needs before it counts as
/// deleted.
///
/// Linked iCloud Drive folders get none of the app container's protection:
/// ICloudDeletionMonitor's query and its "iCloud lists far fewer files" rules
/// only watch the app's own container. A linked folder that is still
/// materialising - after a restore, on a new device, with sync paused - is
/// readable and walks "completely" while most of its songs are not there yet,
/// which is exactly what a deletion looks like on disk.
enum LinkedFolderAbsence {
    /// True when `path` (a song under the linked folder at `rootPath`) may
    /// still be on its way rather than deleted: the file has a `.name.icloud`
    /// placeholder, or a folder between it and the root is itself a
    /// placeholder, or is an iCloud item that is downloading or whose
    /// contents are not on the device yet. Off the main actor: a stat and a
    /// resource-value read per ancestor.
    static func mayStillBeSyncing(_ path: String, within rootPath: String) -> Bool {
        let fileManager = FileManager.default
        let root = DatabaseManager.canonicalPath(rootPath)
        let fileURL = URL(fileURLWithPath: path)
        if fileManager.fileExists(atPath: placeholder(for: fileURL).path) { return true }

        var ancestor = fileURL.deletingLastPathComponent()
        while true {
            let ancestorPath = DatabaseManager.canonicalPath(ancestor.path)
            guard ancestorPath == root || ancestorPath.hasPrefix(root + "/") else { break }
            if fileManager.fileExists(atPath: ancestor.path) {
                if isStillSyncing(ancestor) { return true }
            } else if fileManager.fileExists(atPath: placeholder(for: ancestor).path) {
                // A whole album folder iCloud has not materialised yet.
                return true
            }
            let next = ancestor.deletingLastPathComponent()
            guard ancestorPath != root, next.path != ancestor.path else { break }
            ancestor = next
        }
        return false
    }

    /// Too much of one linked folder missing at once to be read as deletions:
    /// every row of it (the walk found none of its songs - an empty,
    /// not-yet-synced folder looks exactly like that), or more than half of a
    /// folder with more than one missing. The same rule the app container
    /// gets in FileCleanupManager.withholdingMassICloudAbsence, for the same
    /// reason: nothing on disk tells a partially synced folder from the user
    /// deleting most of it, and losing the folder's favourites and playlists
    /// is far worse than keeping ghosts. The cost, accepted: someone who
    /// really empties a linked folder (or most of it) keeps those rows until
    /// they remove them by hand or unlink the folder.
    ///
    /// A one-song folder on the device or a drive is exempt: under "every
    /// row of it" its song could never go once deleted. Every caller only
    /// asks once the folder root itself resolves and is readable (a complete
    /// walk, or `reopen`), so an empty folder there really was emptied. Not
    /// in iCloud Drive: a folder that has not synced yet is readable and
    /// empty too, often without any placeholder to tell, so its one song is
    /// kept - a ghost row is far better than losing its favourites and
    /// playlists to a slow sync. Only the listener removes it (or unlinking
    /// the folder): the iCloud monitor leaves linked folders alone.
    static func isUnsettled(missing: Int, total: Int, folderPath: String) -> Bool {
        guard missing > 0 else { return false }
        guard total > 1 else { return isInICloudDrive(folderPath) }
        return missing >= total || (missing > 1 && missing * 2 > total)
    }

    static func isInICloudDrive(_ path: String) -> Bool {
        path.contains("/Mobile Documents/")
    }

    private static func placeholder(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
    }

    private static func isStillSyncing(_ directory: URL) -> Bool {
        guard let values = try? directory.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemIsDownloadingKey,
            .ubiquitousItemDownloadingStatusKey
        ]), values.isUbiquitousItem == true else { return false }
        if values.ubiquitousItemIsDownloading == true { return true }
        // A dataless folder: iCloud knows it, its contents are not listed here yet.
        return values.ubiquitousItemDownloadingStatus == .notDownloaded
    }
}

// MARK: - Bookmarks and access

/// The linked folders, their bookmarks and the security scopes held on them.
///
/// Scopes are opened once per folder and held for the life of the process
/// rather than per read. Songs are opened by their stored path from many
/// places - playback, the gapless prefetch, artwork, lyrics, analysis - and
/// a URL built under a folder carries no scope of its own, so only an open
/// folder scope makes those paths readable. `ensureAccess(forPath:)` opens it
/// lazily on the first read after launch; `activateAll()` re-checks every
/// folder at the start of a scan.
///
/// A lock rather than an actor: `DatabaseManager.localFileURL` is synchronous
/// and is the one funnel every reader goes through.
final class LinkedFolderStore: @unchecked Sendable {
    static let shared = LinkedFolderStore()
    static let didChangeNotification = Notification.Name("LinkedMusicFoldersDidChange")

    enum AddError: Error {
        case alreadyLinked
    }

    private let lock = NSLock()
    private var records: [LinkedFolder] = []
    /// URLs whose security scope is open, by folder.
    private var openScopes: [UUID: URL] = [:]
    /// Folders whose bookmark no longer resolves to a readable folder. Their
    /// songs stay in the library untouched until the user reconnects or
    /// removes them.
    private var unreachable: Set<UUID> = []
    private let fileURL: URL

    private init() {
        // Application Support rather than Documents: the bookmark list is not
        // something to show in Files under the app's folder.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("LinkedMusicFolders.plist")

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? PropertyListDecoder().decode([LinkedFolder].self, from: data) {
            records = decoded
        }
    }

    var folders: [LinkedFolder] {
        lock.withLock { records }
    }

    func needsReconnect(_ id: UUID) -> Bool {
        lock.withLock { unreachable.contains(id) }
    }

    /// The linked folder a stored path belongs to, former locations included.
    func folder(containing path: String) -> LinkedFolder? {
        let path = Self.quickCanonical(path)
        return lock.withLock { records.first { Self.folder($0, contains: path) } }
    }

    /// Opens the security scope of the linked folder holding `path`, if any
    /// and not already open. Cheap when there is nothing to do: one prefix
    /// test per linked folder.
    func ensureAccess(forPath path: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !records.isEmpty else { return }

        let path = Self.quickCanonical(path)
        guard let index = records.firstIndex(where: { Self.folder($0, contains: path) }) else { return }
        let id = records[index].id
        // An unreachable folder is retried by the next scan or a reconnect,
        // not by every read of every one of its songs.
        guard openScopes[id] == nil, !unreachable.contains(id) else { return }
        _ = openLocked(at: index)
    }

    /// Opens (or re-checks) every folder for a scan and returns the readable
    /// ones, with the URL to walk each by.
    func activateAll() -> [(folder: LinkedFolder, url: URL)] {
        lock.lock()
        defer { lock.unlock() }
        var result: [(folder: LinkedFolder, url: URL)] = []
        for index in records.indices {
            if let url = openLocked(at: index, recheck: true) {
                result.append((records[index], url))
            }
        }
        return result
    }

    /// Opens (or re-checks) one folder and returns the URL to read it by, or
    /// nil if it is not a readable folder right now (unplugged, bookmark
    /// broken). For a removal pass between scans: like a scan, it must know
    /// the folder is still there, not that it once was.
    func reopen(_ id: UUID) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = records.firstIndex(where: { $0.id == id }) else { return nil }
        return openLocked(at: index, recheck: true)
    }

    /// Links a folder the user just picked. Call while the picker's URL has
    /// its security scope open.
    func add(_ url: URL) throws -> LinkedFolder {
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let path = DatabaseManager.canonicalPath(url.path)

        let folder: LinkedFolder = try lock.withLock {
            if records.contains(where: { $0.path == path || path.hasPrefix($0.path + "/") }) {
                throw AddError.alreadyLinked
            }
            // A folder that contains folders already linked takes them over:
            // their songs simply sit under the new one.
            for nested in records where nested.path.hasPrefix(path + "/") {
                closeScopeLocked(nested.id)
            }
            records.removeAll { $0.path.hasPrefix(path + "/") }

            let folder = LinkedFolder(
                id: UUID(),
                name: url.lastPathComponent,
                path: path,
                bookmark: bookmark,
                addedAt: Date(),
                formerPaths: []
            )
            records.append(folder)
            persistLocked()
            _ = openLocked(at: records.count - 1)
            return folder
        }
        postChange()
        return folder
    }

    /// Points a folder whose bookmark broke at the folder the user picked
    /// again. Call while the picker's URL has its scope open.
    func reconnect(_ id: UUID, to url: URL) throws {
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        lock.withLock {
            guard let index = records.firstIndex(where: { $0.id == id }) else { return }
            closeScopeLocked(id)
            unreachable.remove(id)
            records[index].bookmark = bookmark
            persistLocked()
            _ = openLocked(at: index)
        }
        postChange()
    }

    /// Unlinks a folder. Its songs' rows are the caller's to remove.
    @discardableResult
    func remove(_ id: UUID) -> LinkedFolder? {
        let removed: LinkedFolder? = lock.withLock {
            guard let index = records.firstIndex(where: { $0.id == id }) else { return nil }
            closeScopeLocked(id)
            unreachable.remove(id)
            let folder = records.remove(at: index)
            persistLocked()
            return folder
        }
        postChange()
        return removed
    }

    /// Forgets a former location once the songs under it have been moved.
    func clearFormerPath(_ formerPath: String, of id: UUID) {
        lock.withLock {
            guard let index = records.firstIndex(where: { $0.id == id }) else { return }
            records[index].formerPaths.removeAll { $0 == formerPath }
            persistLocked()
        }
    }

    // MARK: Private

    /// Resolves a folder's bookmark and opens its scope. Must hold `lock`.
    /// - Parameter recheck: re-verify a folder whose scope is already open
    ///   (a scan wants to know it is still there, not that it once was).
    private func openLocked(at index: Int, recheck: Bool = false) -> URL? {
        let id = records[index].id

        if let open = openScopes[id] {
            if !recheck || Self.isReadableDirectory(open) {
                return open
            }
            // Unplugged, deleted or moved since: resolve afresh below.
            closeScopeLocked(id)
        }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: records[index].bookmark,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            markUnreachableLocked(id)
            return nil
        }

        let started = url.startAccessingSecurityScopedResource()
        guard Self.isReadableDirectory(url) else {
            if started { url.stopAccessingSecurityScopedResource() }
            markUnreachableLocked(id)
            return nil
        }

        openScopes[id] = url
        if unreachable.remove(id) != nil {
            postChange()
        }

        var changed = false
        // Stale but resolved: the URL is good for now, fresh bytes keep it so.
        if isStale,
           let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            records[index].bookmark = fresh
            changed = true
        }

        // The bookmark followed the folder somewhere else. Keep matching the
        // old place until the scan has moved the songs' rows across.
        let resolvedPath = DatabaseManager.canonicalPath(url.path)
        if resolvedPath != records[index].path {
            if !records[index].formerPaths.contains(records[index].path) {
                records[index].formerPaths.append(records[index].path)
            }
            records[index].path = resolvedPath
            records[index].name = url.lastPathComponent
            changed = true
        }

        if changed {
            persistLocked()
        }
        return url
    }

    private func closeScopeLocked(_ id: UUID) {
        if let url = openScopes.removeValue(forKey: id) {
            url.stopAccessingSecurityScopedResource()
        }
    }

    private func markUnreachableLocked(_ id: UUID) {
        if unreachable.insert(id).inserted {
            print("🔗 Linked music folder needs reconnecting: \(records.first { $0.id == id }?.name ?? id.uuidString)")
            postChange()
        }
    }

    private func persistLocked() {
        do {
            let data = try PropertyListEncoder().encode(records)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("⚠️ Could not save linked music folders: \(error)")
        }
    }

    private func postChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    private static func folder(_ folder: LinkedFolder, contains path: String) -> Bool {
        if path == folder.path || path.hasPrefix(folder.path + "/") { return true }
        return folder.formerPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private static func isReadableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && FileManager.default.isReadableFile(atPath: url.path)
    }

    /// `DatabaseManager.canonicalPath` without the filesystem call behind
    /// `standardizedFileURL`: stored paths are canonical already, and this
    /// runs on every read of every song.
    private static func quickCanonical(_ path: String) -> String {
        for prefix in ["/private/var/", "/private/tmp/"] where path.hasPrefix(prefix) {
            return String(path.dropFirst("/private".count))
        }
        return path
    }
}

// MARK: - Database

extension DatabaseManager {
    /// Fingerprints of the songs stored under a folder, by path, so a rescan
    /// can pass over unchanged files without a database read each.
    struct StoredFileFingerprint {
        let modificationDate: Int64?
        let fileSize: Int64?
        let durationMs: Int?
        let sampleRate: Int?
        let channels: Int?
        let tagRefreshPending: Bool
    }

    func storedFingerprints(underPath rootPath: String) throws -> [String: StoredFileFingerprint] {
        let prefix = Self.canonicalPath(rootPath) + "/"
        return try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT path, modification_date, file_size, duration_ms, sample_rate, channels, tag_refresh_pending
                    FROM track WHERE substr(path, 1, length(?)) = ?
                """,
                arguments: [prefix, prefix]
            )
            var result: [String: StoredFileFingerprint] = [:]
            result.reserveCapacity(rows.count)
            for row in rows {
                let path: String = row["path"]
                result[path] = StoredFileFingerprint(
                    modificationDate: row["modification_date"],
                    fileSize: row["file_size"],
                    durationMs: row["duration_ms"],
                    sampleRate: row["sample_rate"],
                    channels: row["channels"],
                    tagRefreshPending: ((row["tag_refresh_pending"] as Int?) ?? 0) != 0
                )
            }
            return result
        }
    }

    /// The rows stored under a folder (not the folder's own path).
    func tracks(underPath rootPath: String) throws -> [Track] {
        let prefix = Self.canonicalPath(rootPath) + "/"
        return try read { db in
            try Track.fetchAll(
                db,
                sql: "SELECT * FROM track WHERE substr(path, 1, length(?)) = ?",
                arguments: [prefix, prefix]
            )
        }
    }

    /// Removes every song stored under a folder from the library - its
    /// favourites and playlist entries with it - in one transaction. The
    /// files themselves are not touched. Returns the removed stable IDs.
    @discardableResult
    func deleteTracks(underPath rootPath: String) throws -> [String] {
        let prefix = Self.canonicalPath(rootPath) + "/"
        let condition = "substr(path, 1, length(?)) = ?"
        let removed: [String] = try write { db in
            let ids = try String.fetchAll(
                db,
                sql: "SELECT stable_id FROM track WHERE \(condition)",
                arguments: [prefix, prefix]
            )
            guard !ids.isEmpty else { return [] }
            for table in ["playlist_item", "favorite", "track_artist"] {
                try db.execute(
                    sql: "DELETE FROM \(table) WHERE track_stable_id IN (SELECT stable_id FROM track WHERE \(condition))",
                    arguments: [prefix, prefix]
                )
            }
            try db.execute(sql: "DELETE FROM track WHERE \(condition)", arguments: [prefix, prefix])
            return ids
        }
        invalidateArtistDisplayNameCache()
        if !removed.isEmpty {
            try cleanupOrphanedLibraryEntries()
        }
        return removed
    }

    /// Removes the folder playlists made for a folder and its subfolders -
    /// the playlists a scan creates from a linked folder's albums - and
    /// returns their slugs. Without a "deleted" tombstone, unlike the user
    /// deleting one: linking the folder again should bring them back.
    /// Unlinking used to leave them behind, empty, in the Playlists list.
    @discardableResult
    func deleteFolderPlaylists(underPath rootPath: String) throws -> [String] {
        let root = Self.canonicalPath(rootPath)
        return try write { db in
            let playlists = try Playlist.filter(Column("is_folder_synced") == true).fetchAll(db).filter { playlist in
                guard let folderPath = playlist.folderPath else { return false }
                let path = Self.canonicalPath(folderPath)
                return path == root || path.hasPrefix(root + "/")
            }
            for playlist in playlists {
                guard let id = playlist.id else { continue }
                try db.execute(sql: "DELETE FROM playlist_item WHERE playlist_id = ?", arguments: [id])
                try Playlist.filter(Column("id") == id).deleteAll(db)
            }
            return playlists.map(\.slug)
        }
    }

    /// Moves the rows of a folder that was renamed or moved onto its new
    /// location, keeping favourites, playlists and covers. Only rows whose
    /// file is really at the new place move; the rest wait for a later scan.
    @discardableResult
    func relocateTracks(fromRoot oldRoot: String, toRoot newRoot: String) throws -> Int {
        let oldPrefix = Self.canonicalPath(oldRoot) + "/"
        let newRootPath = Self.canonicalPath(newRoot)
        let rows = try read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT stable_id, path FROM track WHERE substr(path, 1, length(?)) = ?",
                arguments: [oldPrefix, oldPrefix]
            ).map { (stableId: $0["stable_id"] as String, path: $0["path"] as String) }
        }

        var moved = 0
        for row in rows {
            let relative = String(row.path.dropFirst(oldPrefix.count))
            let newPath = newRootPath + "/" + relative
            guard FileManager.default.fileExists(atPath: newPath) else { continue }
            try migrateTrackStableIdAndPath(
                oldStableId: row.stableId,
                newStableId: Self.generatePathStableId(forPath: newPath),
                newPath: newPath
            )
            moved += 1
        }
        return moved
    }
}
