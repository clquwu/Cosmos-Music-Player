//
//  SelfTestsFiles.swift
//  Cosmos Music Player
//
//  DEBUG-only self-test suites for files coming and going: M3U import and
//  export, a song added, renamed and deleted in the iCloud music folder while
//  the app is open, and a linked folder (added, vanishing like an unplugged
//  drive, coming back, renamed, one song deleted, unlinked).
//
//  Unlike the other suites these write to the real library, so each one
//  works only with things it made itself - test playlists named
//  "Cosmos Self-Test M3U <token>", copies of songs whose names start with
//  "zz Cosmos Self-Test" - and removes them again at the end, whatever
//  happened in between. The user's own songs are only ever read (copied).
//
//  `files` runs all three, interleaved so the linked folder's 15-minute
//  second look for a deleted song is waited out while the others run.
//

#if DEBUG
import Foundation
import GRDB
import UIKit

extension SelfTests {

    // MARK: - Shared

    /// The library's roots, canonical, longest first.
    static func libraryRootPaths() -> [String] {
        var roots: [String] = []
        if let music = StateManager.shared.getMusicFolderURL() {
            roots.append(DatabaseManager.canonicalPath(music.path))
        }
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            roots.append(DatabaseManager.canonicalPath(documents.path))
        }
        for folder in LinkedFolderStore.shared.folders {
            roots.append(DatabaseManager.canonicalPath(folder.path))
        }
        return roots.sorted { $0.count > $1.count }
    }

    static func relativeLibraryPath(_ path: String, roots: [String]) -> String {
        let canonical = DatabaseManager.canonicalPath(path)
        for root in roots where canonical.hasPrefix(root + "/") {
            return String(canonical.dropFirst(root.count + 1))
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    static func fileName(_ track: Track) -> String {
        URL(fileURLWithPath: track.path).lastPathComponent
    }

    /// Rows whose file is called `name` (anywhere).
    static func rows(named name: String) async -> [Track] {
        await allTracks().filter { $0.path.hasSuffix("/" + name) }
    }

    /// Rows stored under `folderPath`.
    static func rows(under folderPath: String) async -> [Track] {
        let prefix = DatabaseManager.canonicalPath(folderPath) + "/"
        return await allTracks().filter { DatabaseManager.canonicalPath($0.path).hasPrefix(prefix) }
    }

    /// Waits for any scan in progress, runs a full one (as pull-to-refresh
    /// does) and waits for it to finish. Returns its length.
    @discardableResult
    static func scanAndWait() async -> TimeInterval {
        _ = await waitUntil(300) { !LibraryIndexer.shared.isIndexing }
        let start = Date()
        await AppCoordinator.shared.manualSync()
        _ = await waitUntil(2) { LibraryIndexer.shared.isIndexing }
        _ = await waitUntil(300) { !LibraryIndexer.shared.isIndexing }
        // Reconciliation and folder work finish just after the flag drops.
        try? await Task.sleep(for: .seconds(2))
        return Date().timeIntervalSince(start)
    }

    /// Polls `condition` (async) every second.
    static func waitFor(_ timeout: TimeInterval, _ condition: () async -> Bool) async -> (ok: Bool, after: TimeInterval) {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if await condition() { return (true, Date().timeIntervalSince(start)) }
            try? await Task.sleep(for: .seconds(1))
        }
        return (await condition(), Date().timeIntervalSince(start))
    }

    /// Downloaded songs on this device, smallest first, one per file name.
    static func smallestLocalSongs(_ tracks: [Track], under root: String? = nil) -> [Track] {
        var seen = Set<String>()
        return tracks
            .filter { track in
                guard let root else { return true }
                return DatabaseManager.canonicalPath(track.path).hasPrefix(root + "/")
            }
            .sorted { ($0.fileSize ?? .max) < ($1.fileSize ?? .max) }
            .filter { track in
                let url = DatabaseManager.localFileURL(forStoredPath: track.path)
                guard FileManager.default.fileExists(atPath: url.path) else { return false }
                // A dataless iCloud file exists at its path too.
                let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
                guard status == nil || status == .current else { return false }
                return seen.insert(fileName(track).lowercased()).inserted
            }
    }

    /// Copies a song, with today's date, so its size-and-date fingerprint is
    /// not the original's (the indexer must see a new file, not a move).
    static func copySong(_ track: Track, to destination: URL, coordinated: Bool) throws {
        let source = DatabaseManager.localFileURL(forStoredPath: track.path)
        let fileManager = FileManager.default
        func copy(_ target: URL) throws {
            try fileManager.copyItem(at: source, to: target)
            try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
        }
        guard coordinated else { return try copy(destination) }
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { target in
            do { try copy(target) } catch { copyError = error }
        }
        if let error = coordinationError ?? copyError { throw error }
    }

    static func coordinatedMove(_ source: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var moveError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: source, options: .forMoving,
                               writingItemAt: destination, options: .forReplacing,
                               error: &coordinationError) { from, to in
            do {
                try FileManager.default.moveItem(at: from, to: to)
                coordinator.item(at: from, didMoveTo: to)
            } catch {
                moveError = error
            }
        }
        if let error = coordinationError ?? moveError { throw error }
    }

    static func coordinatedDelete(_ url: URL) throws {
        var coordinationError: NSError?
        var deleteError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { target in
            do { try FileManager.default.removeItem(at: target) } catch { deleteError = error }
        }
        if let error = coordinationError ?? deleteError { throw error }
    }

    static func token() -> String {
        String(UUID().uuidString.prefix(6))
    }

    // MARK: - M3U

    static func m3uSuite() async {
        let tracks = await allTracks()
        let roots = libraryRootPaths()
        let database = DatabaseManager.shared
        var fallbackArtistIds: [String: Int64] = [:]
        for track in tracks {
            if let artistId = track.artistId { fallbackArtistIds[track.stableId] = artistId }
        }
        let artistNames = (try? database.getArtistDisplayNames(
            forTrackStableIds: tracks.map(\.stableId),
            fallbackArtistIdsByStableId: fallbackArtistIds
        )) ?? [:]

        // One right answer for every rule below: file names that occur once,
        // and for the #EXTINF-only entry an artist + title that occur once.
        var nameCounts: [String: Int] = [:]
        var pairCounts: [String: Int] = [:]
        func pairKey(_ track: Track) -> String {
            "\(M3UText.key(artistNames[track.stableId] ?? ""))|\(M3UText.key(track.title))"
        }
        for track in tracks {
            nameCounts[fileName(track).lowercased(), default: 0] += 1
            pairCounts[pairKey(track), default: 0] += 1
        }
        let generic = Set((M3ULibraryIndex.defaultGenericArtists + [Localized.unknownArtist, Localized.variousArtists]).map(M3UText.key))
        let candidates = tracks.filter { nameCounts[fileName($0).lowercased()] == 1 && !$0.title.isEmpty }.shuffled()
        guard let infoOnly = candidates.first(where: { track in
                  guard let artist = artistNames[track.stableId], !artist.isEmpty else { return false }
                  return pairCounts[pairKey(track)] == 1 && !generic.contains(M3UText.key(artist))
              }) else {
            skip("m3u", "no song with a unique artist + title")
            return
        }
        // Prefer a song with an accented file name for the Windows-1252 file.
        let others = candidates.filter { $0.stableId != infoOnly.stableId }
        let accented = others.first { name in
            let file = fileName(name)
            return file.unicodeScalars.contains { !$0.isASCII } && file.data(using: .windowsCP1252) != nil
        }
        var picks = Array(others.filter { $0.stableId != accented?.stableId }.prefix(5))
        guard picks.count == 5 else {
            skip("m3u", "fewer than 6 songs with distinct file names (library \(tracks.count))")
            return
        }
        picks.insert(accented ?? picks.removeLast(), at: 2)
        let relative = picks.map { relativeLibraryPath($0.path, roots: roots) }
        func lengthSeconds(_ track: Track) -> Int { ((track.durationMs ?? 0) + 500) / 1000 }
        func extinf(_ track: Track) -> String {
            "#EXTINF:\(lengthSeconds(track)),\(artistNames[track.stableId] ?? "") - \(track.title)"
        }
        func windows(_ path: String) -> String { path.replacingOccurrences(of: "/", with: "\\") }
        let urlPath = relative[1].split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")

        let tag = token()
        let cases: [(label: String, lines: [String], expected: String?)] = [
            ("windows-absolute", [extinf(picks[0]), "C:\\Users\\Raph\\Music\\" + windows(relative[0])], picks[0].stableId),
            ("file-url", ["file:///D:/Musique/" + urlPath], picks[1].stableId),
            ("other-folder-same-file-name", ["E:\\Téléchargements\\Vrac\\" + fileName(picks[2])], picks[2].stableId),
            ("extinf-only", [extinf(infoOnly), "F:\\Old Library\\gone-\(tag).mp3"], infoOnly.stableId),
            ("mac-path", ["/Users/raph/Music/Music/Media.localized/Music/" + relative[3]], picks[3].stableId),
            ("relative-backslash", ["..\\Musique\\" + windows(relative[4])], picks[4].stableId),
            ("unknown-song", ["#EXTINF:201,Nobody Zzq\(tag) - No Such Song \(tag)", "C:\\Music\\Zzq\\nothing-\(tag).flac"], nil),
            ("same-song-again", ["C:\\Users\\Raph\\Music\\" + windows(relative[0])], picks[0].stableId)
        ]
        let uniqueExpected: [String] = cases.compactMap(\.expected).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }

        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory.appendingPathComponent("selftest-m3u-\(tag)", isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "Cosmos Self-Test M3U \(tag)"
        let m3u8URL = folder.appendingPathComponent("\(name).m3u8")
        var lines = ["#EXTM3U", "#PLAYLIST:\(name)"]
        for entry in cases { lines += entry.lines }
        // As Windows tools write it: a BOM and CRLF line ends.
        let text = lines.joined(separator: "\r\n") + "\r\n"
        try? (Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)).write(to: m3u8URL)
        info("m3u.file", lines.joined(separator: " | "))

        var createdPlaylistIds: [Int64] = []
        defer {
            for id in createdPlaylistIds { try? database.deletePlaylist(playlistId: id) }
            try? fileManager.removeItem(at: folder)
        }
        let playlistsBefore = (try? database.getAllPlaylists().count) ?? -1

        // 1. Parse and match each line on its own.
        let parsed = M3UParser.parse(data: (try? Data(contentsOf: m3u8URL)) ?? Data())
        report("m3u.parse", parsed.entries.count == cases.count && parsed.name == name,
               "entries=\(parsed.entries.count)/\(cases.count) name=\(parsed.name ?? "nil")")
        let libraryTracks = (try? database.m3uLibraryTracks()) ?? []
        let index = M3ULibraryIndex(
            tracks: libraryTracks,
            genericArtistNames: M3ULibraryIndex.defaultGenericArtists + [Localized.unknownArtist, Localized.variousArtists]
        )
        for (entry, expected) in zip(parsed.entries, cases) {
            let match = index.match(entry, playlistDirectory: folder.path)
            let got = match.map { index.tracks[$0.trackIndex].stableId }
            report("m3u.match.\(expected.label)", got == expected.expected,
                   "expected=\(short(expected.expected)) got=\(short(got)) by=\(match?.method.rawValue ?? "none") line=\(entry.location)")
        }

        // 2. A legacy .m3u in Windows-1252, as Winamp and older tools save it.
        if let accented {
            let legacyLines = ["#EXTM3U", "E:\\Téléchargements\\Vrac\\" + fileName(accented)]
            let legacyURL = folder.appendingPathComponent("legacy-\(tag).m3u")
            if let data = (legacyLines.joined(separator: "\r\n") + "\r\n").data(using: .windowsCP1252) {
                try? data.write(to: legacyURL)
                let legacy = M3UParser.parse(data: data)
                let match = legacy.entries.first.flatMap { index.match($0, playlistDirectory: folder.path) }
                let got = match.map { index.tracks[$0.trackIndex].stableId }
                report("m3u.windows-1252", got == accented.stableId,
                       "decoded=\(legacy.entries.first?.location ?? "nil") got=\(short(got)) by=\(match?.method.rawValue ?? "none")")
            }
        } else {
            info("m3u.windows-1252", "no accented file name in the library - skipped")
        }

        // 3. The import itself (everything but its iCloud push).
        do {
            let result = try PlaylistImporter.prepareAndSave(m3u8URL)
            if let id = result.playlistId { createdPlaylistIds.append(id) }
            let items = result.playlistId.flatMap { try? database.getPlaylistItems(playlistId: $0) }?.map(\.trackStableId) ?? []
            report("m3u.import", result.playlistId != nil
                   && result.matchedEntries == cases.count - 1
                   && result.unmatched.count == 1
                   && result.repeatedSongs == 1
                   && items == uniqueExpected,
                   "title=\(result.playlistTitle) matched=\(result.matchedEntries)/\(result.totalEntries) repeated=\(result.repeatedSongs) unmatched=\(result.unmatched) orderOK=\(items == uniqueExpected) songs=\(items.count)")

            // Same file again: a second playlist "<name> 2", not a merge.
            let again = try PlaylistImporter.prepareAndSave(m3u8URL)
            if let id = again.playlistId { createdPlaylistIds.append(id) }
            report("m3u.import-twice", again.playlistTitle == "\(name) 2", "second title=\(again.playlistTitle)")

            // 4. Export, then read the export back against the library.
            if let id = result.playlistId {
                let exported = try PlaylistExporter.writeFile(playlistId: id, title: result.playlistTitle)
                let exportData = (try? Data(contentsOf: exported)) ?? Data()
                let exportText = String(decoding: exportData, as: UTF8.self)
                let reread = M3UParser.parse(data: exportData)
                let rematched = reread.entries.compactMap { entry in
                    index.match(entry, playlistDirectory: exported.deletingLastPathComponent().path).map { index.tracks[$0.trackIndex].stableId }
                }
                info("m3u.export.file", exportText.split(separator: "\n").prefix(4).joined(separator: " | "))
                report("m3u.export-roundtrip", rematched == items && reread.name == result.playlistTitle,
                       "\(exported.lastPathComponent): \(reread.entries.count) lines, \(rematched.count) matched back, same order=\(rematched == items) name=\(reread.name ?? "nil")")
                try? fileManager.removeItem(at: exported.deletingLastPathComponent())
            }
        } catch {
            report("m3u.import", false, "threw \(error)")
        }

        // 5. Clean up and make sure nothing is left - here or in iCloud.
        let slugs = createdPlaylistIds.compactMap { id in try? database.getAllPlaylists().first { $0.id == id }?.slug }
        for id in createdPlaylistIds { try? database.deletePlaylist(playlistId: id) }
        createdPlaylistIds.removeAll()
        var leftInState: [String] = []
        for slug in slugs where (try? StateManager.shared.loadPlaylist(slug: slug)) != nil {
            leftInState.append(slug)
            try? StateManager.shared.deletePlaylist(slug: slug)
        }
        let playlistsAfter = (try? database.getAllPlaylists().count) ?? -1
        let leftovers = (try? database.getAllPlaylists().filter { $0.title.hasPrefix(name) }.map(\.title)) ?? []
        report("m3u.cleanup", playlistsAfter == playlistsBefore && leftovers.isEmpty,
               "playlists before=\(playlistsBefore) after=\(playlistsAfter) leftovers=\(leftovers) syncedCopiesRemoved=\(leftInState)")
    }

    // MARK: - iCloud, live

    static func iCloudLiveSuite() async {
        guard let urls = await iCloudLiveSteps() else { return }
        // Whatever happened: our files gone, our rows gone.
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            try? coordinatedDelete(url)
        }
        for url in urls {
            for row in await rows(named: url.lastPathComponent) {
                try? await DatabaseManager.shared.deleteTrack(byStableId: row.stableId)
                info("icloud.cleanup", "removed a leftover row for \(url.lastPathComponent)")
            }
        }
        NotificationCenter.default.post(name: NSNotification.Name("LibraryNeedsRefresh"), object: nil)
    }

    /// Returns the test's file URLs for cleanup, or nil when it never made any.
    private static func iCloudLiveSteps() async -> [URL]? {
        guard AppCoordinator.shared.iCloudStatus != .offline,
              let music = StateManager.shared.getMusicFolderURL() else {
            skip("icloud", "iCloud is not available (status \(AppCoordinator.shared.iCloudStatus))")
            return nil
        }
        let musicRoot = DatabaseManager.canonicalPath(music.path)
        let tracks = await allTracks()
        guard let source = smallestLocalSongs(tracks, under: musicRoot).first else {
            skip("icloud", "no downloaded song in the iCloud music folder")
            return nil
        }
        let countBefore = tracks.count
        let tag = token()
        let ext = URL(fileURLWithPath: source.path).pathExtension
        // At the folder's top level: a subfolder would get a folder playlist.
        let firstName = "zz Cosmos Self-Test \(tag).\(ext)"
        let renamedName = "zz Cosmos Self-Test \(tag) renamed.\(ext)"
        let firstURL = music.appendingPathComponent(firstName)
        let renamedURL = music.appendingPathComponent(renamedName)
        let made = [firstURL, renamedURL]
        info("icloud.source", "copying '\(source.title)' (\(fileName(source)), \(source.fileSize ?? 0) bytes) as \(firstName)")

        // 1. A new file appears while the app is open.
        do {
            try copySong(source, to: firstURL, coordinated: true)
        } catch {
            report("icloud.copy", false, "could not copy into the iCloud folder: \(error)")
            return made
        }
        var added = await waitFor(120) { await !rows(named: firstName).isEmpty }
        report("icloud.new-file-appears-live", added.ok,
               added.ok ? "in the library after \(Int(added.after))s without a refresh"
                        : "not in the library after \(Int(added.after))s without a refresh")
        if !added.ok {
            let scan = await scanAndWait()
            added = await waitFor(30) { await !rows(named: firstName).isEmpty }
            report("icloud.new-file-after-refresh", added.ok, "after a refresh (\(Int(scan))s): \(added.ok ? "found" : "still missing")")
            guard added.ok else { return made }
        }
        let originalAfterAdd = await allTracks().first { $0.stableId == source.stableId }
        report("icloud.original-untouched", originalAfterAdd?.path == source.path,
               "the copied song's own row \(originalAfterAdd == nil ? "is gone" : originalAfterAdd?.path == source.path ? "kept its path" : "moved to \(originalAfterAdd?.path ?? "")")")

        // 2. Renamed (as in Files) - the row should follow.
        do {
            try coordinatedMove(firstURL, to: renamedURL)
        } catch {
            report("icloud.rename", false, "could not rename: \(error)")
            return made
        }
        var renamed = await waitFor(180) {
            let new = await rows(named: renamedName)
            let old = await rows(named: firstName)
            return !new.isEmpty && old.isEmpty
        }
        let afterRename = (await rows(named: renamedName), await rows(named: firstName))
        report("icloud.rename-followed-live", renamed.ok,
               "after \(Int(renamed.after))s: new name rows=\(afterRename.0.count) old name rows=\(afterRename.1.count)")
        if !renamed.ok {
            let scan = await scanAndWait()
            renamed = await waitFor(90) {
                let new = await rows(named: renamedName)
                let old = await rows(named: firstName)
                return !new.isEmpty && old.isEmpty
            }
            report("icloud.rename-after-refresh", renamed.ok,
                   "after a refresh (\(Int(scan))s) + \(Int(renamed.after))s: new=\(await rows(named: renamedName).count) old=\(await rows(named: firstName).count)")
        }

        // 3. Deleted - the row should go once iCloud confirms it (~1 min).
        do {
            try coordinatedDelete(renamedURL)
        } catch {
            report("icloud.delete", false, "could not delete: \(error)")
            return made
        }
        let deleted = await waitFor(240) {
            let new = await rows(named: renamedName)
            let old = await rows(named: firstName)
            return new.isEmpty && old.isEmpty
        }
        report("icloud.delete-removed-live", deleted.ok,
               deleted.ok ? "row removed \(Int(deleted.after))s after the delete, without a refresh"
                          : "row still there \(Int(deleted.after))s after the delete")

        let after = await allTracks()
        let original = after.first { $0.stableId == source.stableId }
        report("icloud.library-unchanged", original?.path == source.path && after.count == countBefore,
               "songs before=\(countBefore) after=\(after.count); the original song \(original == nil ? "is missing" : "is still there")")
            return made
    }

    // MARK: - Linked folder

    /// What the first half of the linked-folder test leaves for the second.
    struct LinkedFolderRun {
        var folder: LinkedFolder?
        var folderURL: URL
        var backupURL: URL
        var deletedName: String?
        var deletedAt: Date?
        var otherNames: [String]
    }

    static func linkedFolderSuite() async {
        guard let run = await linkedFolderSetup() else { return }
        await linkedFolderFinish(run)
    }

    /// Runs the three file suites with the linked folder's 15-minute wait
    /// spent on the other two.
    static func filesSuite() async {
        let run = await linkedFolderSetup()
        emit("m3u", "BEGIN", "")
        await m3uSuite()
        emit("m3u", "END", "")
        emit("icloud-live", "BEGIN", "")
        await iCloudLiveSuite()
        emit("icloud-live", "END", "")
        if let run { await linkedFolderFinish(run) }
    }

    static func linkedFolderSetup() async -> LinkedFolderRun? {
        let fileManager = FileManager.default
        let tracks = await allTracks()
        let sources = Array(smallestLocalSongs(tracks).prefix(3))
        guard sources.count == 3 else {
            skip("linked", "fewer than 3 songs on the device")
            return nil
        }
        let tag = token()
        let base = fileManager.temporaryDirectory.appendingPathComponent("selftest-linked-\(tag)", isDirectory: true)
        let folderURL = base.appendingPathComponent("Cosmos Self-Test Linked \(tag)", isDirectory: true)
        let backupURL = base.appendingPathComponent("unplugged", isDirectory: true)
        var run = LinkedFolderRun(folder: nil, folderURL: folderURL, backupURL: backupURL, deletedName: nil, deletedAt: nil, otherNames: [])
        do {
            try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
            for (index, source) in sources.enumerated() {
                let name = "zz Cosmos Self-Test \(tag) \(index + 1).\(URL(fileURLWithPath: source.path).pathExtension)"
                try copySong(source, to: folderURL.appendingPathComponent(name), coordinated: false)
                run.otherNames.append(name)
            }
        } catch {
            report("linked.copy", false, "\(error)")
            try? fileManager.removeItem(at: base)
            return nil
        }

        // 1. Link it, as if picked in Files. link() starts a scan itself.
        let before = Set(LinkedFolderStore.shared.folders.map(\.id))
        let outcome = await LinkedFolderImporter.link(folderURL)
        run.folder = LinkedFolderStore.shared.folders.first { !before.contains($0.id) }
        report("linked.link", run.folder != nil, "outcome=\(outcome.id) folder=\(run.folder?.name ?? "nil")")
        guard let folder = run.folder else {
            try? fileManager.removeItem(at: base)
            return nil
        }
        var added = await waitFor(120) { await rows(under: folder.path).count == 3 }
        if !added.ok {
            await scanAndWait()
            added = await waitFor(30) { await rows(under: folder.path).count == 3 }
        }
        let addedRows = await rows(under: folder.path)
        report("linked.songs-added", added.ok, "\(addedRows.count)/3 songs in the library after \(Int(added.after))s")
        let readable = addedRows.allSatisfy {
            FileManager.default.isReadableFile(atPath: DatabaseManager.localFileURL(forStoredPath: $0.path).path)
        }
        report("linked.songs-readable", readable && !addedRows.isEmpty, "every song opens from its stored path: \(readable)")
        let addedIds = Set(addedRows.map(\.stableId))

        // 2. The folder vanishes, like an unplugged drive: nothing may go.
        do {
            try fileManager.copyItem(at: folderURL, to: backupURL)
            try fileManager.removeItem(at: folderURL)
        } catch {
            report("linked.unplug", false, "\(error)")
        }
        await scanAndWait()
        let whileGone = await rows(under: folder.path)
        report("linked.unplugged-keeps-songs", Set(whileGone.map(\.stableId)) == addedIds,
               "\(whileGone.count)/\(addedIds.count) songs kept while the folder is missing; needsReconnect=\(LinkedFolderStore.shared.needsReconnect(folder.id))")

        // 3. It comes back: same songs, no duplicates.
        do {
            try fileManager.moveItem(at: backupURL, to: folderURL)
        } catch {
            report("linked.replug", false, "\(error)")
        }
        await scanAndWait()
        let current = LinkedFolderStore.shared.folders.first { $0.id == folder.id }
        let back = await rows(under: current?.path ?? folder.path)
        report("linked.replugged-same-songs", Set(back.map(\.stableId)) == addedIds && back.count == addedIds.count,
               "\(back.count) songs, same IDs=\(Set(back.map(\.stableId)) == addedIds); needsReconnect=\(LinkedFolderStore.shared.needsReconnect(folder.id)) path=\(current?.path == folder.path ? "same" : current?.path ?? "nil")")

        // 4. One song deleted. The scan keeps it for the 15-minute second
        // look (a single walk cannot tell a deletion from a hiccup); a
        // recheck 16 minutes later removes it.
        let deletedName = run.otherNames.removeLast()
        do {
            try fileManager.removeItem(at: folderURL.appendingPathComponent(deletedName))
        } catch {
            report("linked.delete", false, "\(error)")
        }
        run.deletedName = deletedName
        run.deletedAt = Date()
        await scanAndWait()
        let afterFirstLook = await rows(named: deletedName)
        info("linked.deleted-song-first-look",
             afterFirstLook.isEmpty ? "removed at once" : "kept after the first scan, as designed - rechecked in 16 min")
        return run
    }

    static func linkedFolderFinish(_ run: LinkedFolderRun) async {
        guard let folder = run.folder else { return }
        defer {
            try? FileManager.default.removeItem(at: run.folderURL.deletingLastPathComponent())
        }

        if UserDefaults.standard.bool(forKey: "cosmosSelfTestQuick") {
            // `-cosmosSelfTestQuick YES`: skip the 16-minute wait.
            info("linked.deleted-song-removed", "not waited for (quick run)")
        } else if let deletedName = run.deletedName, let deletedAt = run.deletedAt {
            // The recheck runs 16 min after the first look; allow 3 more.
            let deadline = deletedAt.addingTimeInterval(19 * 60)
            info("linked.waiting", "for the 15-minute second look, until about \(deadline.formatted(date: .omitted, time: .shortened))")
            let removed = await waitFor(max(1, deadline.timeIntervalSinceNow)) { await rows(named: deletedName).isEmpty }
            let elapsed = Date().timeIntervalSince(deletedAt)
            report("linked.deleted-song-removed", removed.ok,
                   removed.ok ? "removed \(Int(elapsed / 60)) min \(Int(elapsed) % 60) s after the delete"
                              : "still in the library \(Int(elapsed / 60)) min after the delete")
            var others = true
            for name in run.otherNames where await rows(named: name).isEmpty { others = false }
            report("linked.other-songs-kept", others, "the folder's other \(run.otherNames.count) songs are still there: \(others)")
        }

        // 5. Unlink: its songs leave the library, the files stay.
        let current = LinkedFolderStore.shared.folders.first { $0.id == folder.id } ?? folder
        await LinkedFolderImporter.remove(current)
        let left = await rows(under: current.path)
        let filesStay = run.otherNames.allSatisfy {
            FileManager.default.fileExists(atPath: run.folderURL.appendingPathComponent($0).path)
        }
        report("linked.unlink", left.isEmpty && !LinkedFolderStore.shared.folders.contains { $0.id == folder.id } && filesStay,
               "songs left=\(left.count) stillLinked=\(LinkedFolderStore.shared.folders.contains { $0.id == folder.id }) filesStay=\(filesStay)")

        // A folder playlist made for it would outlive the unlink.
        let database = DatabaseManager.shared
        let folderPlaylists = ((try? database.getAllPlaylists()) ?? []).filter { playlist in
            guard let path = playlist.folderPath else { return false }
            let canonical = DatabaseManager.canonicalPath(path)
            let root = DatabaseManager.canonicalPath(run.folderURL.deletingLastPathComponent().path)
            return canonical == root || canonical.hasPrefix(root + "/")
        }
        report("linked.no-folder-playlist-left", folderPlaylists.isEmpty,
               folderPlaylists.isEmpty ? "none" : "left behind: \(folderPlaylists.map(\.title)) - removing")
        for playlist in folderPlaylists {
            if let id = playlist.id { try? database.deletePlaylist(playlistId: id) }
            if (try? StateManager.shared.loadPlaylist(slug: playlist.slug)) != nil {
                try? StateManager.shared.deletePlaylist(slug: playlist.slug)
            }
        }
        NotificationCenter.default.post(name: NSNotification.Name("LibraryNeedsRefresh"), object: nil)
    }
}
#endif
