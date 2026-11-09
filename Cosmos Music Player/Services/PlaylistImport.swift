//
//  PlaylistImport.swift
//  Cosmos Music Player
//
//  Turning an M3U/M3U8 file into a Cosmos playlist, and a Cosmos playlist
//  into an M3U8 file. Parsing and matching live in PlaylistM3U.swift; this is
//  the part that reads files, talks to the database and syncs the result.
//

import Foundation
import CoreTransferable
import UniformTypeIdentifiers
@preconcurrency import GRDB

/// What an import did, for the summary sheet.
struct PlaylistImportResult: Identifiable, Sendable {
    let id = UUID()
    /// Nil when nothing matched: no empty playlist is created.
    let playlistId: Int64?
    let playlistTitle: String
    /// Song lines in the file, streams included.
    let totalEntries: Int
    /// Lines that found their song, repeats included.
    let matchedEntries: Int
    /// Lines whose song was already earlier in the playlist. A Cosmos
    /// playlist holds each song once (adding skips a song already there, and
    /// launch removes repeats), so these appear once.
    let repeatedSongs: Int
    /// What to call each line that found nothing, in playlist order.
    let unmatched: [String]
}

enum PlaylistImportError: LocalizedError {
    case unreadable
    case empty

    var errorDescription: String? {
        switch self {
        case .unreadable: return Localized.playlistImportUnreadable
        case .empty: return Localized.playlistImportEmpty
        }
    }
}

enum PlaylistImporter {
    /// `public.m3u-playlist` covers both .m3u and .m3u8.
    static let contentTypes: [UTType] = [.m3uPlaylist]

    static func isPlaylistFile(_ url: URL) -> Bool {
        ["m3u", "m3u8"].contains(url.pathExtension.lowercased())
    }

    /// Reads, matches and saves the playlist at `url` off the main thread,
    /// then pushes it to iCloud and refreshes the screens on it.
    @MainActor
    static func importPlaylist(from url: URL) async throws -> PlaylistImportResult {
        let result = try await Task.detached(priority: .userInitiated) {
            try prepareAndSave(url)
        }.value

        if let playlistId = result.playlistId {
            // The rows were written straight to the database in one
            // transaction (thousands of single adds would each schedule an
            // iCloud sync). Re-adding a song the playlist already holds is a
            // no-op for the database, and the coordinator's add then syncs the
            // playlists to iCloud once.
            if let firstSong = try? DatabaseManager.shared.getPlaylistItems(playlistId: playlistId).first {
                try? AppCoordinator.shared.addToPlaylist(playlistId: playlistId, trackStableId: firstSong.trackStableId)
            }
            NotificationCenter.default.post(name: NSNotification.Name("LibraryNeedsRefresh"), object: nil)
            // So "play <imported playlist> in Cosmos" works right away, not
            // only after the app next goes to the background.
            SiriLibraryDonations.shared.scheduleRefresh(after: 0.5)
        }
        return result
    }

    /// Everything but the iCloud push and the screen refresh. Internal for
    /// the DEBUG self-test, which must not sync its test playlists.
    nonisolated static func prepareAndSave(_ url: URL) throws -> PlaylistImportResult {
        let data = try readFile(at: url)
        let playlist = M3UParser.parse(data: data)
        guard !playlist.entries.isEmpty else { throw PlaylistImportError.empty }

        let database = DatabaseManager.shared
        let index = M3ULibraryIndex(
            tracks: try database.m3uLibraryTracks(),
            genericArtistNames: M3ULibraryIndex.defaultGenericArtists + [Localized.unknownArtist, Localized.variousArtists]
        )
        // Relative entries may point at songs beside the playlist: one saved
        // inside a music folder copied to the phone, or exported by Cosmos.
        let playlistDirectory = url.deletingLastPathComponent().path

        var matchedIds: [String] = []
        var unmatched: [String] = []
        for entry in playlist.entries {
            if let match = index.match(entry, playlistDirectory: playlistDirectory) {
                matchedIds.append(index.tracks[match.trackIndex].stableId)
            } else {
                unmatched.append(entry.displayName)
            }
        }

        let fileTitle = url.deletingPathExtension().lastPathComponent
        let requestedTitle = (playlist.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let baseTitle = requestedTitle.isEmpty ? fileTitle : requestedTitle

        guard !matchedIds.isEmpty else {
            return PlaylistImportResult(
                playlistId: nil,
                playlistTitle: baseTitle,
                totalEntries: playlist.entries.count,
                matchedEntries: 0,
                repeatedSongs: 0,
                unmatched: unmatched
            )
        }

        // Importing the same file twice gives "Name 2" rather than merging
        // into - or doubling - the playlist made the first time.
        let title = try database.availablePlaylistTitle(baseTitle.isEmpty ? Localized.playlists : baseTitle)
        let created = try database.createPlaylist(title: title)
        guard let playlistId = created.id else { throw PlaylistImportError.unreadable }
        let added = try database.appendM3UTracks(matchedIds, toPlaylist: playlistId)

        return PlaylistImportResult(
            playlistId: playlistId,
            playlistTitle: created.title,
            totalEntries: playlist.entries.count,
            matchedEntries: matchedIds.count,
            repeatedSongs: matchedIds.count - added,
            unmatched: unmatched
        )
    }

    /// The file's bytes, under its security scope when it has one (picked
    /// in Files, or opened in place from there) and through a file
    /// coordinator, which downloads an iCloud Drive file that is not on the
    /// device yet instead of failing on its placeholder.
    nonisolated private static func readFile(at url: URL) throws -> Data {
        let hasScope = url.startAccessingSecurityScopedResource()
        defer { if hasScope { url.stopAccessingSecurityScopedResource() } }

        var coordinationError: NSError?
        var readResult: Result<Data, Error> = .failure(PlaylistImportError.unreadable)
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
            readResult = Result { try Data(contentsOf: readableURL, options: .mappedIfSafe) }
        }
        if coordinationError != nil { throw PlaylistImportError.unreadable }
        guard let data = try? readResult.get() else { throw PlaylistImportError.unreadable }

        // "Copy to Cosmos" from another app drops a copy in Documents/Inbox;
        // it has served its purpose once read, and left there it would sit
        // in the app's folder in Files for good.
        if url.path.contains("/Documents/Inbox/") {
            try? FileManager.default.removeItem(at: url)
        }
        return data
    }
}

// MARK: - Database

extension DatabaseManager {
    /// Just what the matcher needs about every song, in one read: the
    /// columns it compares and every credited artist, which `getAllTracks`
    /// would not give and per-song artist lookups would make slow.
    func m3uLibraryTracks() throws -> [M3ULibraryTrack] {
        try read { db in
            let artistNames = Dictionary(
                try Row.fetchAll(db, sql: "SELECT id, name FROM artist").map { (($0["id"] as Int64), ($0["name"] as String)) },
                uniquingKeysWith: { first, _ in first }
            )
            var credits: [String: [String]] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT track_stable_id, artist_id FROM track_artist ORDER BY position") {
                let artistId: Int64 = row["artist_id"]
                if let name = artistNames[artistId] {
                    credits[row["track_stable_id"] as String, default: []].append(name)
                }
            }
            return try Row.fetchAll(db, sql: "SELECT stable_id, path, title, duration_ms, artist_id FROM track ORDER BY id").map { row in
                let stableId: String = row["stable_id"]
                var artists = credits[stableId] ?? []
                if let artistId = row["artist_id"] as Int64?, let name = artistNames[artistId], !artists.contains(name) {
                    artists.append(name)
                }
                return M3ULibraryTrack(
                    stableId: stableId,
                    path: row["path"],
                    title: row["title"],
                    artists: artists,
                    durationMs: row["duration_ms"]
                )
            }
        }
    }

    /// Appends `trackStableIds` in order in one transaction, skipping songs
    /// already in the playlist (see `PlaylistImportResult.repeatedSongs`).
    /// `addToPlaylist` does the same one song and one transaction at a time,
    /// which for a playlist of thousands is seconds of writes.
    /// - Returns: how many songs were added.
    func appendM3UTracks(_ trackStableIds: [String], toPlaylist playlistId: Int64) throws -> Int {
        try write { db in
            var present = Set(try String.fetchAll(
                db,
                sql: "SELECT track_stable_id FROM playlist_item WHERE playlist_id = ?",
                arguments: [playlistId]
            ))
            let lastPosition = try Int.fetchOne(
                db,
                sql: "SELECT MAX(position) FROM playlist_item WHERE playlist_id = ?",
                arguments: [playlistId]
            )
            var position = (lastPosition ?? -1) + 1
            var added = 0
            for stableId in trackStableIds where present.insert(stableId).inserted {
                try PlaylistItem(playlistId: playlistId, position: position, trackStableId: stableId).insert(db)
                position += 1
                added += 1
            }
            return added
        }
    }
}

// MARK: - Export

/// A playlist offered to the share sheet as an .m3u8 file. The file is only
/// written when the user actually shares, not every time the menu is drawn.
struct PlaylistM3UExport: Transferable {
    let playlistId: Int64
    let title: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .m3uPlaylist) { export in
            let playlistId = export.playlistId
            let title = export.title
            let url = try await Task.detached(priority: .userInitiated) {
                try PlaylistExporter.writeFile(playlistId: playlistId, title: title)
            }.value
            return SentTransferredFile(url)
        }
    }
}

enum PlaylistExporter {
    /// Writes the playlist as an extended M3U8 in a fresh temporary folder,
    /// named after the playlist.
    nonisolated static func writeFile(playlistId: Int64, title: String) throws -> URL {
        let database = DatabaseManager.shared
        let stableIds = try database.getPlaylistItems(playlistId: playlistId).map(\.trackStableId)
        let tracks = try database.getTracksByStableIdsPreservingOrder(stableIds)
        var fallbackArtistIds: [String: Int64] = [:]
        for track in tracks {
            if let artistId = track.artistId { fallbackArtistIds[track.stableId] = artistId }
        }
        let artistNames = (try? database.getArtistDisplayNames(
            forTrackStableIds: tracks.map(\.stableId),
            fallbackArtistIdsByStableId: fallbackArtistIds
        )) ?? [:]

        let roots = libraryRoots()
        let items = tracks.map { track in
            M3UWriter.Item(
                durationSeconds: track.durationMs.flatMap { $0 > 0 ? Int(($0 + 500) / 1000) : nil },
                artist: artistNames[track.stableId],
                title: track.title,
                location: location(for: track.path, roots: roots)
            )
        }
        let text = M3UWriter.m3u8(name: title, items: items)

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaylistExport", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileURL = folder.appendingPathComponent(fileName(for: title)).appendingPathExtension("m3u8")
        try Data(text.utf8).write(to: fileURL, options: .atomic)
        return fileURL
    }

    /// Where the library's songs live, each with the prefix its songs get in
    /// the file: none for the app's own folders (local and iCloud Drive), so
    /// "Artist/Album/01 Song.flac" works from a copy of that folder on a
    /// computer or saved back into Cosmos's folder; the folder's name for a
    /// linked folder, so the path still starts somewhere recognisable.
    private static func libraryRoots() -> [(path: String, prefix: String)] {
        var roots: [(path: String, prefix: String)] = []
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            roots.append((DatabaseManager.canonicalPath(documents.path), ""))
        }
        if let container = StateManager.shared.resolveiCloudContainerURL() {
            roots.append((DatabaseManager.canonicalPath(container.appendingPathComponent("Documents").path), ""))
        }
        for folder in LinkedFolderStore.shared.folders {
            roots.append((DatabaseManager.canonicalPath(folder.path), folder.name))
        }
        return roots
    }

    /// The song's path relative to the library folder holding it, or the
    /// full path when it is in none (a single file opened from elsewhere).
    private static func location(for path: String, roots: [(path: String, prefix: String)]) -> String {
        let canonical = DatabaseManager.canonicalPath(path)
        for root in roots where canonical.hasPrefix(root.path + "/") {
            let relative = String(canonical.dropFirst(root.path.count + 1))
            return root.prefix.isEmpty ? relative : root.prefix + "/" + relative
        }
        return canonical
    }

    /// The playlist title as a file name: characters Windows or iOS refuse
    /// in names replaced, so the file saves wherever it is shared to.
    private static func fileName(for title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        let cleaned = title.unicodeScalars
            .map { forbidden.contains($0) ? "-" : String($0) }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "Playlist" : String(cleaned.prefix(120))
    }
}
