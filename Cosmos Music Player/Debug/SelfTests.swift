//
//  SelfTests.swift
//  Cosmos Music Player
//
//  DEBUG-only on-device scenario checks for the riskiest recent changes.
//  Launch with `-cosmosDebugSelfTest <suite[,suite...]|all>`:
//    restore          cold launch restores the saved session, no autoplay
//    deletion-safety  deletion guards fed synthetic inputs only (two phases:
//                     the guard's 15-minute second look is checked on a
//                     launch at least 15 minutes after the first)
//    compilation      split albums / #118 regroup migration, read-only
//    song-mix         Song Mix + Siri song/artist radio + listener choice
//                     cancelling a mix (plays a few seconds each)
//    dsd-eq           DSD/FLAC/MP3 playback with EQ off/on (plays briefly)
//    stop-timing      how long pause()/stop() hold the main thread, and that
//                     Play right after stop() still plays (plays briefly)
//    monitor          waits up to 2 min for ICloudDeletionMonitor's query to
//                     gather (FAIL if it never does), then logs its state
//    query-probe      which NSMetadataQuery scope spellings finish gathering;
//                     for the ubiquitous scope the app now uses, whether its
//                     paths match the music folder and the library's rows,
//                     and whether the indexer's fingerprints agree
//    m3u              imports PC-style M3U/M3U8 files built from the
//                     library (Windows, file://, Mac and relative paths,
//                     #EXTINF only, an unknown song), exports the playlist
//                     and re-matches the export; the test playlists are
//                     deleted again (SelfTestsFiles.swift)
//    icloud-live      copies one small song into the iCloud music folder as
//                     a new file, then renames and deletes it, checking the
//                     library follows each step while the app stays open
//    linked-folder    links a folder of copied songs in the app's tmp
//                     folder, then makes it vanish (like an unplugged
//                     drive), brings it back, deletes one song and unlinks
//    files            linked-folder, m3u and icloud-live in one run, the
//                     linked folder's 16-minute wait spent on the other two
//    energy           the app's own CPU and wake-ups: idle on Home (halo
//                     moving / still), playing, playing with the player
//                     open (plays ~50 s; SelfTestsEnergy.swift)
//    state-check      prints the player/listening/EQ state and compares it
//                     with the snapshot the last playback run restored
//  `all` runs the first five. Every result is one console line:
//  `SELFTEST <name> PASS|FAIL|INFO|SKIP <details>`.
//
//  This runs against a real library. Apart from m3u, icloud-live and
//  linked-folder - which add their own test songs or playlists and remove
//  them again - nothing here writes library rows, favourites or playlists;
//  deletion logic only ever sees synthetic rows
//  (fake stable IDs, paths in the app's tmp directory). The playback suites
//  necessarily touch the saved session, the listening log, recents and EQ:
//  those are snapshotted first (also to tmp, in case the run crashes - the
//  next self-test launch puts it back), restored afterwards, and the process
//  then exits so nothing still held in memory saves the test's state again.
//

#if DEBUG
import Foundation
import GRDB
import UIKit

@MainActor
enum SelfTests {
    private static var started = false
    private static var passed = 0
    private static var failed = 0

    /// Called once the app has initialised. Does nothing without the
    /// launch argument.
    static func runIfRequested() {
        guard !started,
              let request = UserDefaults.standard.string(forKey: "cosmosDebugSelfTest")?.lowercased(),
              !request.isEmpty else { return }
        started = true
        Task { @MainActor in
            await run(request)
        }
    }

    // MARK: - Reporting

    static func report(_ name: String, _ ok: Bool, _ details: String) {
        if ok { passed += 1 } else { failed += 1 }
        emit(name, ok ? "PASS" : "FAIL", details)
    }

    static func info(_ name: String, _ details: String) { emit(name, "INFO", details) }
    static func skip(_ name: String, _ details: String) { emit(name, "SKIP", details) }

    static func emit(_ name: String, _ status: String, _ details: String) {
        print("SELFTEST \(name) \(status) \(details)")
        fflush(nil)
    }

    static func short(_ id: String?) -> String {
        id.map { String($0.prefix(10)) } ?? "nil"
    }

    static func seconds(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    // MARK: - Runner

    private static func run(_ request: String) async {
        let all = ["restore", "deletion-safety", "compilation", "song-mix", "dsd-eq"]
        let suites = request == "all"
            ? all
            : request.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        info("run", "suites=\(suites.joined(separator: ",")) app=\(version)(\(build)) processAge=\(processAge().map(seconds) ?? "?")s")

        let watchdog = MainThreadWatchdog()
        watchdog.start()
        // Some suites wait out the app's own timers (up to ~20 min): an
        // auto-lock would suspend the app under them.
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }

        if UserStateSnapshot.restoreLeftoverBackupIfAny() {
            info("run", "a previous self-test run did not finish - its snapshot of the listening log, session and recents was put back")
        }

        let playsAudio = suites.contains("song-mix") || suites.contains("dsd-eq") || suites.contains("stop-timing") || suites.contains("energy")
        var snapshot: UserStateSnapshot?
        if playsAudio {
            let taken = UserStateSnapshot.take()
            snapshot = taken
            info("snapshot", taken.summary)
        }

        for suite in suites {
            emit(suite, "BEGIN", "")
            switch suite {
            case "restore": await restoreSuite()
            case "deletion-safety": await deletionSafetySuite()
            case "compilation": compilationSuite()
            case "song-mix": await songMixSuite()
            case "dsd-eq": await dsdEQSuite()
            case "state-check": await stateCheckSuite()
            case "stop-timing": await stopTimingSuite()
            case "monitor": await monitorSuite()
            case "query-probe": await queryProbeSuite()
            case "m3u": await m3uSuite()
            case "icloud-live": await iCloudLiveSuite()
            case "linked-folder": await linkedFolderSuite()
            case "files": await filesSuite()
            case "energy": await energySuite()
            default: info("run", "unknown suite '\(suite)'")
            }
            emit(suite, "END", "")
        }

        if let snapshot {
            timedStop("cleanup")
            // ListeningLog saves 2 s after its last change; EQ saves in a task.
            try? await Task.sleep(for: .seconds(4))
            let restored = snapshot.restore()
            let other = snapshot.otherChanges()
            info("cleanup", "restored \(restored.joined(separator: ",")); other defaults keys changed: [\(other.defaults.joined(separator: ","))]; other Application Support entries changed: [\(other.files.joined(separator: ","))]")
            UserDefaults.standard.set(snapshot.fingerprint, forKey: UserStateSnapshot.fingerprintKey)
        }

        if !stopDurations.isEmpty {
            let sorted = stopDurations.sorted()
            info("perf.stop-summary", "PlayerEngine.stop() main-thread time over \(sorted.count) calls: median=\(seconds(sorted[sorted.count / 2]))s max=\(seconds(sorted.last ?? 0))s")
        }
        emit("SUMMARY", failed == 0 ? "PASS" : "FAIL", "passed=\(passed) failed=\(failed) mainThreadHangs=\(watchdog.hangCount) longestHang=\(seconds(watchdog.longestHang))s")

        if playsAudio {
            info("run", "exiting so the player's in-memory test state cannot be saved over the restored state")
            try? await Task.sleep(for: .milliseconds(500))
            exit(0)
        }
    }

    // MARK: - Helpers

    private static var stopDurations: [Double] = []

    /// PlayerEngine.stop() runs on the main thread; records how long it
    /// holds it (it used to release the audio session synchronously, 0.55 s;
    /// the release now runs on a background queue).
    static func timedStop(_ label: String) {
        let start = Date()
        PlayerEngine.shared.stop()
        let elapsed = Date().timeIntervalSince(start)
        stopDurations.append(elapsed)
        if elapsed > 0.25 {
            info("perf.stop", "\(label): stop() held the main thread for \(seconds(elapsed))s")
        }
    }

    @MainActor private final class Flag {
        var value = false
    }

    static func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    /// Seconds since this process started.
    private static func processAge() -> TimeInterval? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_starttime
        let started = TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000
        return Date().timeIntervalSince1970 - started
    }

    nonisolated static func allTracks() async -> [Track] {
        await Task.detached(priority: .userInitiated) {
            (try? DatabaseManager.shared.getAllTracks()) ?? []
        }.value
    }

    static func isLocal(_ track: Track) -> Bool {
        FileManager.default.fileExists(atPath: DatabaseManager.localFileURL(forStoredPath: track.path).path)
    }

    static func fileExtension(_ track: Track) -> String {
        URL(fileURLWithPath: track.path).pathExtension.lowercased()
    }

    // MARK: - 1. Restore

    private static func restoreSuite() async {
        let player = PlayerEngine.shared
        let saved = UserDefaults.standard.dictionary(forKey: "CosmosPlayerState")
        let savedId = saved?["currentTrackStableId"] as? String
        let savedPosition = saved?["playbackTime"] as? Double ?? 0

        let start = Date()
        let finished = Flag()
        Task { @MainActor in
            await player.ensureSavedStateRestored()
            finished.value = true
        }
        _ = await waitUntil(10) { finished.value }
        let elapsed = Date().timeIntervalSince(start)
        report("restore.ensureSavedStateRestored-bounded", finished.value && elapsed < 6,
               "returned=\(finished.value) after \(seconds(elapsed))s (bound 6s) processAge=\(processAge().map(seconds) ?? "?")s")

        let again = Date()
        await player.ensureSavedStateRestored()
        let againElapsed = Date().timeIntervalSince(again)
        report("restore.second-call-cached", againElapsed < 0.2, "second call took \(seconds(againElapsed))s")

        if let savedId {
            let inLibrary = (try? DatabaseManager.shared.read { db in
                try Track.filter(Column("stable_id") == savedId).fetchCount(db)
            }) ?? 0
            let current = player.currentTrack?.stableId
            let expected = inLibrary > 0 ? savedId : nil
            report("restore.session-restored", current == expected,
                   "saved=\(short(savedId)) inLibrary=\(inLibrary > 0) current=\(short(current)) title='\(player.currentTrack?.title ?? "-")' queue=\(player.playbackQueue.count) index=\(player.currentIndex) pos=\(Int(player.playbackTime))s savedPos=\(Int(savedPosition))s")
        } else {
            report("restore.session-restored", player.currentTrack == nil,
                   "no saved session; currentTrack=\(player.currentTrack?.title ?? "nil")")
        }
        report("restore.pending-flag-cleared", !player.savedSessionIsPendingRestore,
               "savedSessionIsPendingRestore=\(player.savedSessionIsPendingRestore)")
        report("restore.no-autoplay-immediately", !player.isPlaying && player.playbackState != .playing,
               "isPlaying=\(player.isPlaying) state=\(player.playbackState)")
        try? await Task.sleep(for: .seconds(2.5))
        report("restore.no-autoplay-after-2.5s", !player.isPlaying && player.playbackState != .playing,
               "isPlaying=\(player.isPlaying) state=\(player.playbackState) error=\(player.playbackErrorMessage ?? "nil")")
    }

    // MARK: - 2. Deletion safety (synthetic inputs only)

    private static func deletionSafetySuite() async {
        isUnsettledCases()
        syncingAndConfirmedMissingCases()

        let bogus = UUID()
        report("deletion.linkedFolderStore.reopen-bogus-id", LinkedFolderStore.shared.reopen(bogus) == nil,
               "reopen(\(bogus.uuidString.prefix(8))) returned nil")
        let folders = LinkedFolderStore.shared.folders
        info("deletion.linked-folders",
             "count=\(folders.count) needingReconnect=\(folders.filter { LinkedFolderStore.shared.needsReconnect($0.id) }.count) inICloudDrive=\(folders.filter { LinkedFolderAbsence.isInICloudDrive($0.path) }.count)")

        await removalGuardCases()
        logMonitorState()
    }

    private static func isUnsettledCases() {
        let local = "/var/mobile/Containers/Shared/AppGroup/0000/File Provider Storage/Music"
        let usb = "/var/mobile/Library/LiveFiles/com.apple.filesystems.userfsd/USB/Music"
        let drive = "/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Music"
        let cases: [(name: String, missing: Int, total: Int, path: String, want: Bool)] = [
            ("none-missing", 0, 10, local, false),
            ("all-missing", 10, 10, local, true),
            ("all-missing-icloud-drive", 10, 10, drive, true),
            ("two-of-two", 2, 2, local, true),
            ("more-than-half", 6, 10, local, true),
            ("exactly-half", 5, 10, local, false),
            ("two-of-three", 2, 3, local, true),
            ("one-of-two", 1, 2, local, false),
            ("one-of-ten", 1, 10, local, false),
            ("one-song-folder-local", 1, 1, local, false),
            ("one-song-folder-usb", 1, 1, usb, false),
            ("one-song-folder-icloud-drive", 1, 1, drive, true),
            ("one-of-two-icloud-drive", 1, 2, drive, false)
        ]
        for c in cases {
            let got = LinkedFolderAbsence.isUnsettled(missing: c.missing, total: c.total, folderPath: c.path)
            report("deletion.isUnsettled.\(c.name)", got == c.want,
                   "missing=\(c.missing) total=\(c.total) got=\(got) want=\(c.want)")
        }
        // A count that fails is held by every caller (`try?` → unsettled);
        // not reachable without a database failure. What the rule itself
        // makes of an inconsistent count (fewer rows than missing songs):
        let inconsistentLocal = LinkedFolderAbsence.isUnsettled(missing: 3, total: 0, folderPath: local)
        let inconsistentDrive = LinkedFolderAbsence.isUnsettled(missing: 3, total: 0, folderPath: drive)
        info("deletion.isUnsettled.count-below-missing",
             "missing=3 total=0 local=\(inconsistentLocal) icloudDrive=\(inconsistentDrive) (failed counts are held by the callers themselves)")
    }

    private static func syncingAndConfirmedMissingCases() {
        let fileManager = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cosmos-selftest-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: base) }
        let root = base.appendingPathComponent("Linked")
        let album = root.appendingPathComponent("Album")
        do {
            try fileManager.createDirectory(at: album, withIntermediateDirectories: true)
        } catch {
            report("deletion.tmp-setup", false, "could not create \(album.path): \(error)")
            return
        }
        func touch(_ url: URL) { fileManager.createFile(atPath: url.path, contents: Data("x".utf8)) }

        // LinkedFolderAbsence.mayStillBeSyncing
        let song = album.appendingPathComponent("song.flac").path
        report("deletion.mayStillBeSyncing.plain-missing", !LinkedFolderAbsence.mayStillBeSyncing(song, within: root.path),
               "missing file, no placeholder, local folder -> false")

        let songPlaceholder = album.appendingPathComponent(".song.flac.icloud")
        touch(songPlaceholder)
        report("deletion.mayStillBeSyncing.file-placeholder", LinkedFolderAbsence.mayStillBeSyncing(song, within: root.path),
               ".song.flac.icloud next to it -> true")

        // The same placeholder, the root spelled with /private and the song without.
        let rootPath = root.path
        let privateRoot = rootPath.hasPrefix("/private/") ? rootPath : "/private" + rootPath
        let plainSong = song.hasPrefix("/private/") ? String(song.dropFirst("/private".count)) : song
        report("deletion.mayStillBeSyncing.private-var-spelling",
               LinkedFolderAbsence.mayStillBeSyncing(plainSong, within: privateRoot),
               "root=/private/... song=/var/... -> true")
        try? fileManager.removeItem(at: songPlaceholder)

        let ghostSong = root.appendingPathComponent("Ghost/track.flac").path
        touch(root.appendingPathComponent(".Ghost.icloud"))
        report("deletion.mayStillBeSyncing.folder-placeholder", LinkedFolderAbsence.mayStillBeSyncing(ghostSong, within: root.path),
               "album folder only a .Ghost.icloud placeholder -> true")

        let goneSong = root.appendingPathComponent("Gone/track.flac").path
        report("deletion.mayStillBeSyncing.folder-gone", !LinkedFolderAbsence.mayStillBeSyncing(goneSong, within: root.path),
               "album folder gone, no placeholder -> false")

        let outside = base.appendingPathComponent("Other/x.flac").path
        touch(base.appendingPathComponent(".Other.icloud"))
        report("deletion.mayStillBeSyncing.placeholder-outside-root",
               !LinkedFolderAbsence.mayStillBeSyncing(outside, within: album.path),
               "placeholder above the linked root is not looked at -> false")

        // DatabaseManager.isPathConfirmedMissing(_:within:) - file system only.
        let database = DatabaseManager.shared
        let deleted = album.appendingPathComponent("deleted.flac").path
        report("deletion.confirmedMissing.file-in-readable-folder", database.isPathConfirmedMissing(deleted, within: [root]),
               "-> true")
        let deletedAlbumSong = root.appendingPathComponent("DeletedAlbum/x.flac").path
        report("deletion.confirmedMissing.whole-album-deleted", database.isPathConfirmedMissing(deletedAlbumSong, within: [root]),
               "nearest surviving ancestor is the readable root -> true")
        touch(album.appendingPathComponent(".evicted.flac.icloud"))
        report("deletion.confirmedMissing.evicted-placeholder",
               !database.isPathConfirmedMissing(album.appendingPathComponent("evicted.flac").path, within: [root]),
               ".evicted.flac.icloud -> false")
        let present = album.appendingPathComponent("present.flac")
        touch(present)
        report("deletion.confirmedMissing.file-present", !database.isPathConfirmedMissing(present.path, within: [root]),
               "-> false")
        report("deletion.confirmedMissing.outside-roots",
               !database.isPathConfirmedMissing(base.appendingPathComponent("Elsewhere/x.flac").path, within: [root]),
               "-> false")
        let missingRoot = base.appendingPathComponent("UnpluggedDrive")
        report("deletion.confirmedMissing.root-missing",
               !database.isPathConfirmedMissing(missingRoot.appendingPathComponent("A/x.flac").path, within: [missingRoot]),
               "root itself absent (unplugged drive) -> false")
    }

    // MARK: RemovalConfirmationGuard (synthetic rows, two phases)

    private static let guardPhaseKey = "cosmosSelfTest.guardPhase1"
    /// RemovalConfirmationGuard's private key, read only to put back the
    /// reappearance time the reappearance case itself records.
    private static let lastReappearanceKey = "LibraryPendingRemovalLastReappearance"
    private static let pendingRemovalsKey = "LibraryPendingTrackRemovals"

    private static func removalGuardCases() async {
        guard let template = try? DatabaseManager.shared.read({ db in try Track.fetchOne(db) }) else {
            skip("deletion.guard", "library is empty - no row to copy the shape of")
            return
        }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cosmos-selftest-guard")
        func synthetic(_ tag: String, run: String, path: String? = nil) -> Track {
            var track = template
            track.id = nil
            track.stableId = "selftest-guard-\(run)-\(tag)"
            track.path = path ?? directory.appendingPathComponent("\(run)-\(tag).flac").path
            return track
        }
        let grace = FileCleanupManager.removalConfirmationGrace

        if let marker = UserDefaults.standard.dictionary(forKey: guardPhaseKey),
           let run = marker["run"] as? String,
           let firstAt = marker["at"] as? Date,
           let paths = marker["paths"] as? [String: String] {
            let age = Date().timeIntervalSince(firstAt)
            if age < grace {
                skip("deletion.guard.second-look-after-15min",
                     "phase 1 was \(Int(age))s ago; relaunch with -cosmosDebugSelfTest deletion-safety in \(Int(grace - age) + 5)s")
                return
            }
            let a = synthetic("A", run: run, path: paths["A"])
            let b = synthetic("B", run: run, path: paths["B"])
            let c = synthetic("C", run: run, path: paths["C"])
            if age > 36 * 3600 {
                FileCleanupManager.forgetAbsences([a.stableId, b.stableId, c.stableId])
                UserDefaults.standard.removeObject(forKey: guardPhaseKey)
                skip("deletion.guard.second-look-after-15min", "phase 1 was \(Int(age))s ago, past the 36 h window - starting over")
                await removalGuardCases()
                return
            }

            let previousReappearance = UserDefaults.standard.object(forKey: lastReappearanceKey) as? Date
            let realQuiet = FileCleanupManager.shared.secondsSinceMissingFileReappeared
            let confirmed = FileCleanupManager.confirmedAbsences(among: [a, b])
            if let realQuiet, realQuiet < grace {
                report("deletion.guard.real-reappearance-withholds", confirmed.isEmpty,
                       "a real missing file came back \(Int(realQuiet))s ago; confirmed=\(confirmed.count) (want 0)")
            } else {
                report("deletion.guard.second-look-after-15min-confirms", confirmed == [a.stableId, b.stableId],
                       "first look \(Int(age))s ago; confirmed \(confirmed.count)/2")
            }

            // A pending row whose file comes back means the container is
            // still converging: nothing may be confirmed for 15 min.
            var setReappearance: Date?
            let cURL = URL(fileURLWithPath: c.path)
            try? FileManager.default.createDirectory(at: cURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.createFile(atPath: c.path, contents: Data("x".utf8)) {
                let afterReappearance = FileCleanupManager.confirmedAbsences(among: [a])
                setReappearance = UserDefaults.standard.object(forKey: lastReappearanceKey) as? Date
                report("deletion.guard.reappearance-withholds", afterReappearance.isEmpty && setReappearance != nil,
                       "C's file came back; confirmed=\(afterReappearance.count) (want 0) reappearanceRecorded=\(setReappearance != nil)")
                try? FileManager.default.removeItem(atPath: c.path)
            } else {
                skip("deletion.guard.reappearance-withholds", "could not create the synthetic file at \(c.path) (container moved since phase 1?)")
            }

            // Clean up: synthetic observations, and the reappearance time
            // this case recorded (only if nothing else changed it since).
            FileCleanupManager.forgetAbsences([a.stableId, b.stableId, c.stableId])
            if let setReappearance,
               (UserDefaults.standard.object(forKey: lastReappearanceKey) as? Date) == setReappearance {
                if let previousReappearance {
                    UserDefaults.standard.set(previousReappearance, forKey: lastReappearanceKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: lastReappearanceKey)
                }
            }
            UserDefaults.standard.removeObject(forKey: guardPhaseKey)
            try? FileManager.default.removeItem(at: directory)
            let leftovers = pendingSyntheticIds()
            report("deletion.guard.cleanup", leftovers.isEmpty,
                   "synthetic pending entries left=\(leftovers.count); lastReappearance restored to \(previousReappearance.map { "\($0)" } ?? "none")")
            return
        }

        // Phase 1: first observations.
        let run = String(UUID().uuidString.prefix(8))
        let a = synthetic("A", run: run), b = synthetic("B", run: run), c = synthetic("C", run: run)
        let first = FileCleanupManager.confirmedAbsences(among: [a, b, c])
        report("deletion.guard.first-look-withheld", first.isEmpty, "confirmed=\(first.count) (want 0)")
        try? await Task.sleep(for: .seconds(1))
        let second = FileCleanupManager.confirmedAbsences(among: [a, b, c])
        report("deletion.guard.second-look-within-15min-withheld", second.isEmpty, "1 s later: confirmed=\(second.count) (want 0)")
        UserDefaults.standard.set([
            "run": run,
            "at": Date().addingTimeInterval(-1),
            "paths": ["A": a.path, "B": b.path, "C": c.path]
        ] as [String: Any], forKey: guardPhaseKey)
        skip("deletion.guard.second-look-after-15min-confirms",
             "phase 2 needs a launch >= \(Int(grace))s from now with -cosmosDebugSelfTest deletion-safety (synthetic ids selftest-guard-\(run)-*)")
    }

    private static func pendingSyntheticIds() -> [String] {
        guard let data = UserDefaults.standard.data(forKey: pendingRemovalsKey),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return object.keys.filter { $0.hasPrefix("selftest-") }
    }

    /// ICloudDeletionMonitor's live state, read by reflection - its empty /
    /// too-small listing rules are inline in verify() and cannot be called.
    private static func logMonitorState() {
        let monitor = ICloudDeletionMonitor.shared
        var parts: [String] = []
        for child in Mirror(reflecting: monitor).children {
            switch child.label {
            case "hasGathered":
                parts.append("gathered=\(child.value)")
            case "query":
                if let query = child.value as? NSMetadataQuery {
                    parts.append("queryResults=\(query.resultCount) gathering=\(query.isGathering)")
                } else {
                    parts.append("query=nil")
                }
            case "candidates":
                if let candidates = child.value as? [String: Any] {
                    func flag(_ value: Any, _ label: String) -> Bool {
                        Mirror(reflecting: value).children.contains { $0.label == label && ($0.value as? Bool) == true }
                    }
                    let held = candidates.values.filter { flag($0, "isHeld") }.count
                    let events = candidates.values.filter { flag($0, "isRemovalEvent") }.count
                    parts.append("candidates=\(candidates.count) held=\(held) removalEvents=\(events)")
                }
            case "listedFilesIn":
                parts.append("listedFilesThisSession=\(String(describing: child.value) != "nil")")
            default:
                break
            }
        }
        let reappeared = FileCleanupManager.shared.secondsSinceMissingFileReappeared.map { "\(Int($0))s ago" } ?? "never"
        info("deletion.monitor-state",
             "\(parts.joined(separator: " ")) iCloud=\(AppCoordinator.shared.iCloudStatus) trustedRemovalEvents=\(monitor.trustedRemovalEventPaths().count) lastReappearance=\(reappeared) realPendingRemovals=\(realPendingRemovalCount())")
    }

    /// The monitor's state once its query has gathered and the launch
    /// sweep has had time to run - read only.
    private static func monitorSuite() async {
        func gathered() -> Bool {
            Mirror(reflecting: ICloudDeletionMonitor.shared).children.first { $0.label == "hasGathered" }?.value as? Bool == true
        }
        func queryState() -> String {
            let value = Mirror(reflecting: ICloudDeletionMonitor.shared).children.first { $0.label == "query" }?.value
            guard let query = value as? NSMetadataQuery else { return "query=nil" }
            let scopes = query.searchScopes.map { scope -> String in
                (scope as? URL)?.path ?? "\(scope)"
            }
            return "started=\(query.isStarted) gathering=\(query.isGathering) stopped=\(query.isStopped) results=\(query.resultCount) scopes=\(scopes)"
        }
        let start = Date()
        var didGather = false
        for _ in 0..<8 where !didGather {
            didGather = await waitUntil(15) { gathered() }
            info("deletion.monitor-query", "t=\(Int(Date().timeIntervalSince(start)))s gathered=\(didGather) \(queryState())")
        }
        report("deletion.monitor-query-gathers", didGather,
               "ICloudDeletionMonitor's NSMetadataQuery \(didGather ? "finished" : "had not finished") gathering after \(seconds(Date().timeIntervalSince(start)))s; iCloud=\(AppCoordinator.shared.iCloudStatus) musicFolder=\(StateManager.shared.getMusicFolderURL()?.path ?? "nil")")
        // The sweep runs a second after gathering, verification a second
        // after the sweep.
        try? await Task.sleep(for: .seconds(5))
        logMonitorState()
    }

    /// Runs the monitor's query over the music folder with different scope
    /// spellings side by side, to see which ones ever finish gathering.
    /// Queries only read iCloud's metadata.
    private static func queryProbeSuite() async {
        guard let root = StateManager.shared.getMusicFolderURL() else {
            skip("probe", "no iCloud music folder")
            return
        }
        let rootPath = root.path
        let varPath = rootPath.hasPrefix("/private/") ? String(rootPath.dropFirst("/private".count)) : rootPath
        let privatePath = rootPath.hasPrefix("/private/") ? rootPath : "/private" + rootPath
        let variants: [(name: String, scope: Any)] = [
            ("url-as-resolved", root),
            ("url-private-var", URL(fileURLWithPath: privatePath, isDirectory: true)),
            ("url-var", URL(fileURLWithPath: varPath, isDirectory: true)),
            ("path-string-var", varPath),
            ("ubiquitous-documents-scope", NSMetadataQueryUbiquitousDocumentsScope)
        ]
        let patterns = ["*.flac", "*.mp3", "*.wav", "*.m4a", "*.aac", "*.opus", "*.ogg", "*.oga", "*.dsf", "*.dff"]
        var queries: [(name: String, query: NSMetadataQuery, started: Bool)] = []
        for variant in variants {
            let query = NSMetadataQuery()
            query.searchScopes = [variant.scope]
            query.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: patterns.map {
                NSPredicate(format: "%K LIKE[c] %@", NSMetadataItemFSNameKey, $0)
            })
            queries.append((variant.name, query, query.start()))
        }
        let start = Date()
        _ = await waitUntil(30) { queries.allSatisfy { !$0.query.isGathering } }
        let elapsed = Date().timeIntervalSince(start)
        for entry in queries {
            info("probe.\(entry.name)",
                 "started=\(entry.started) finishedGathering=\(!entry.query.isGathering) results=\(entry.query.resultCount) (after \(seconds(elapsed))s)")
            if entry.name == "ubiquitous-documents-scope" {
                await probeListing(entry.query, rootPath: rootPath)
            }
            entry.query.stop()
        }
        info("probe.root", "getMusicFolderURL=\(rootPath)")
    }

    /// What ICloudDeletionMonitor and LibraryIndexer rely on now that both
    /// use the ubiquitous-documents scope, read from that query:
    /// - its paths fall under the music folder once canonicalised (if not,
    ///   the monitor sees an empty listing and holds every removal);
    /// - they name the library's rows (if not, every row missing on disk
    ///   also looks unlisted by iCloud);
    /// - the indexer's metadata fingerprint - content-change date in
    ///   microseconds, and size - equals what a scan stored. If it does not,
    ///   every scan and every live update re-parses, and starts downloading,
    ///   every file: `fingerprintMismatch` must be 0 (or only files really
    ///   changed since the last scan).
    private static func probeListing(_ query: NSMetadataQuery, rootPath: String) async {
        let root = DatabaseManager.canonicalPath(rootPath)
        var items: [(path: String, date: Date?, size: Int64?)] = []
        query.disableUpdates()
        for index in 0..<query.resultCount {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let raw = (item.value(forAttribute: NSMetadataItemPathKey) as? String)
                    ?? (item.value(forAttribute: NSMetadataItemURLKey) as? URL)?.path else { continue }
            items.append((
                raw,
                item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date,
                (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value
            ))
        }
        query.enableUpdates()

        let underRoot = items.filter {
            let path = DatabaseManager.canonicalPath($0.path)
            return path == root || path.hasPrefix(root + "/")
        }
        info("probe.listing",
             "results=\(items.count) underMusicFolder=\(underRoot.count) sample=\(items.first?.path ?? "none")")

        let rows = underRoot
        let result = await Task.detached(priority: .userInitiated) { () -> (rows: Int, missing: Int, mismatched: Int, example: String) in
            var withRow = 0
            var noRow = 0
            var mismatched = 0
            var example = "none"
            for item in rows {
                guard let track = try? DatabaseManager.shared.getTrack(byPath: DatabaseManager.canonicalPath(item.path)) else {
                    noRow += 1
                    continue
                }
                withRow += 1
                // Mirrors LibraryIndexer.fileChangedSinceIndexed: only a value
                // the item reports can disagree.
                let micros = item.date.map { Int64(($0.timeIntervalSince1970 * 1_000_000).rounded()) }
                let dateDiffers = micros.map { $0 != track.modificationDate } ?? false
                let sizeDiffers = item.size.map { $0 != track.fileSize } ?? false
                if dateDiffers || sizeDiffers {
                    mismatched += 1
                    if example == "none" {
                        func text(_ value: Int64?) -> String { value.map { "\($0)" } ?? "nil" }
                        example = "'\(URL(fileURLWithPath: item.path).lastPathComponent)' date \(text(micros)) vs stored \(text(track.modificationDate)), size \(text(item.size)) vs stored \(text(track.fileSize))"
                    }
                }
            }
            return (withRow, noRow, mismatched, example)
        }.value
        info("probe.listing-rows",
             "withLibraryRow=\(result.rows) withoutRow=\(result.missing) fingerprintMismatch=\(result.mismatched) example=\(result.example)")
    }

    private static func realPendingRemovalCount() -> Int {
        guard let data = UserDefaults.standard.data(forKey: pendingRemovalsKey),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
        return object.keys.filter { !$0.hasPrefix("selftest-") }.count
    }

    // MARK: - 3. Compilation / album artist (#118), read-only

    private static func compilationSuite() {
        struct AlbumRow {
            let id: Int64
            let title: String
            let albumArtist: String?
            let artistName: String?
            let trackCount: Int
        }
        do {
            let (albumCount, migrated, pending, rows, folders) = try DatabaseManager.shared.read { db -> (Int, Bool?, Int, [AlbumRow], [Int64: Set<String>]) in
                let albumCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM album") ?? 0
                let migrated = try? Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM one_time_migration WHERE name = 'album-artist-regroup')"
                )
                let pending = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track WHERE tag_refresh_pending = 1") ?? 0
                let shared = "SELECT title FROM album GROUP BY title HAVING COUNT(*) > 1"
                let rows = try Row.fetchAll(db, sql: """
                    SELECT a.id, a.title, a.album_artist, ar.name AS artist_name,
                           (SELECT COUNT(*) FROM track t WHERE t.album_id = a.id) AS track_count
                    FROM album a LEFT JOIN artist ar ON ar.id = a.artist_id
                    WHERE a.title IN (\(shared))
                    ORDER BY a.title
                """).map {
                    AlbumRow(id: $0["id"], title: $0["title"], albumArtist: $0["album_artist"],
                             artistName: $0["artist_name"], trackCount: $0["track_count"])
                }
                var folders: [Int64: Set<String>] = [:]
                for row in try Row.fetchAll(db, sql: """
                    SELECT album_id, path FROM track
                    WHERE album_id IN (SELECT id FROM album WHERE title IN (\(shared)))
                """) {
                    let albumId: Int64 = row["album_id"]
                    let path: String = row["path"]
                    folders[albumId, default: []].insert(URL(fileURLWithPath: path).deletingLastPathComponent().path)
                }
                return (albumCount, migrated ?? nil, pending, rows, folders)
            }

            report("compilation.regroup-migration-ran", migrated == true,
                   "one_time_migration 'album-artist-regroup' present=\(migrated.map { "\($0)" } ?? "table missing")")

            let groups = Dictionary(grouping: rows, by: \.title)
            let placeholderTitles: Set<String> = ["", "unknown album", "album inconnu", "unknown", "<unknown>"]
            var sameFolderSplits: [(title: String, albums: [AlbumRow])] = []
            var placeholderGroups = 0
            for (title, albums) in groups {
                var seen: [String: Int] = [:]
                for album in albums {
                    for folder in folders[album.id] ?? [] { seen[folder, default: 0] += 1 }
                }
                guard seen.values.contains(where: { $0 > 1 }) else { continue }
                if placeholderTitles.contains(title.lowercased().trimmingCharacters(in: .whitespaces)) {
                    placeholderGroups += 1
                } else {
                    sameFolderSplits.append((title, albums))
                }
            }
            let lastScan = DeleteSettings.load().lastLibraryScanDate
            info("compilation.counts",
                 "albums=\(albumCount) titlesSharedByMoreThanOneAlbum=\(groups.count) albumsInThem=\(rows.count) sameFolderSplitTitles=\(sameFolderSplits.count) placeholderTitleSplits=\(placeholderGroups) tagRefreshPending=\(pending) lastScan=\(lastScan.map { "\($0)" } ?? "never")")
            for split in sameFolderSplits.sorted(by: { $0.albums.count > $1.albums.count }).prefix(8) {
                let detail = split.albums.map {
                    "#\($0.id)[albumArtist=\($0.albumArtist ?? "nil") artist=\($0.artistName ?? "nil") tracks=\($0.trackCount)]"
                }.joined(separator: " ")
                info("compilation.split-example", "'\(split.title)' \(detail)")
            }
            if sameFolderSplits.isEmpty {
                report("compilation.no-same-folder-splits", true, "no album title split across albums within one folder")
            } else if pending > 0 {
                skip("compilation.no-same-folder-splits",
                     "\(sameFolderSplits.count) split title(s) remain but \(pending) track(s) still await the one-time tag refresh (next scan)")
            } else {
                report("compilation.no-same-folder-splits", false,
                       "\(sameFolderSplits.count) title(s) still split across albums in the same folder with no tag refresh pending")
            }
        } catch {
            report("compilation.read", false, "database read failed: \(error)")
        }
    }

    // MARK: - 4. Song mix / Siri path (plays a few seconds each)

    private static func songMixSuite() async {
        let player = PlayerEngine.shared
        let tracks = await allTracks()
        guard !tracks.isEmpty else {
            skip("songmix", "library is empty")
            return
        }

        // An artist with plenty of songs on the device, for companions.
        let byArtist = Dictionary(grouping: tracks.filter { $0.artistId != nil }, by: { $0.artistId! })
        let names = Dictionary(uniqueKeysWithValues: ((try? DatabaseManager.shared.getAllArtists()) ?? []).compactMap { artist in
            artist.id.map { ($0, artist.name) }
        })
        var chosenArtist: (id: Int64, name: String, local: [Track])?
        for (artistId, songs) in byArtist.sorted(by: { $0.value.count > $1.value.count }).prefix(15) {
            guard let name = names[artistId], !name.isEmpty else { continue }
            let local = songs.prefix(30).filter(isLocal)
            if local.count >= 3 {
                chosenArtist = (artistId, name, Array(local))
                break
            }
        }
        guard let artist = chosenArtist else {
            skip("songmix", "no artist with 3+ songs stored on the device")
            return
        }
        let seed = artist.local[0]
        let seed2 = artist.local[1]
        guard let other = tracks.shuffled().prefix(80).first(where: { $0.artistId != artist.id && isLocal($0) }) else {
            skip("songmix", "no local song by another artist")
            return
        }
        info("songmix.setup", "artist='\(artist.name)' songs=\(byArtist[artist.id]?.count ?? 0) seed='\(seed.title)' seed2='\(seed2.title)' other='\(other.title)' shuffleBefore=\(player.isShuffled) repeatOneBefore=\(player.isLoopingSong)")

        // A. Song Mix from a song that is not current, with Shuffle and
        // Repeat One switched on: the mix must turn both off.
        timedStop("songmix.before-A")
        player.isShuffled = true
        player.isLoopingSong = true
        let started = Date()
        let outcome = await MixStore.shared.playSongMix(from: seed)
        let buildTime = Date().timeIntervalSince(started)
        var startedId: String?
        if case .started(let current) = outcome { startedId = current }
        report("songmix.playSongMix-started", startedId == seed.stableId,
               "outcome=\(outcome) after \(seconds(buildTime))s")
        report("songmix.queue-grows", player.playbackQueue.count > 1,
               "queue=\(player.playbackQueue.count) index=\(player.currentIndex) current='\(player.currentTrack?.title ?? "nil")'")
        let playing = await waitUntil(5) { player.isPlaying && player.currentTrack?.stableId == seed.stableId }
        report("songmix.playing-within-5s", playing,
               "isPlaying=\(player.isPlaying) error=\(player.playbackErrorMessage ?? "nil")")
        report("songmix.shuffle-and-repeat-one-off", !player.isShuffled && !player.isLoopingSong,
               "isShuffled=\(player.isShuffled) isLoopingSong=\(player.isLoopingSong)")
        try? await Task.sleep(for: .seconds(2))
        timedStop("songmix.after-A")
        try? await Task.sleep(for: .milliseconds(600))

        // B. Siri song radio.
        let radioStart = Date()
        let radioOK = await CosmosSiriActions.playSongRadio(seed: seed2)
        report("songmix.siri-playSongRadio", radioOK && player.isPlaying,
               "returned=\(radioOK) after \(seconds(Date().timeIntervalSince(radioStart)))s isPlaying=\(player.isPlaying) current='\(player.currentTrack?.title ?? "nil")' queue=\(player.playbackQueue.count) error=\(player.playbackErrorMessage ?? "nil")")
        try? await Task.sleep(for: .seconds(2))
        timedStop("songmix.after-B")
        try? await Task.sleep(for: .milliseconds(600))

        // C. Siri artist radio by name.
        let artistStart = Date()
        do {
            let artistOK = try await CosmosSiriActions.playArtistRadio(spoken: artist.name)
            let playingNow = await waitUntil(5) { player.isPlaying }
            let byArtistNow = player.currentTrack?.artistId == artist.id
            report("songmix.siri-playArtistRadio", artistOK && playingNow,
                   "spoken='\(artist.name)' returned=\(artistOK) after \(seconds(Date().timeIntervalSince(artistStart)))s isPlaying=\(player.isPlaying) currentByArtist=\(byArtistNow) current='\(player.currentTrack?.title ?? "nil")' queue=\(player.playbackQueue.count) error=\(player.playbackErrorMessage ?? "nil")")
        } catch {
            report("songmix.siri-playArtistRadio", false, "threw \(error)")
        }
        try? await Task.sleep(for: .seconds(2))
        timedStop("songmix.after-C")
        try? await Task.sleep(for: .milliseconds(600))

        // D. The listener picks a song while a mix is still being built:
        // the mix must give up and leave their choice playing.
        let choiceBefore = player.listenerChoiceGeneration
        let mixTask = Task { @MainActor in await MixStore.shared.playSongMix(from: seed) }
        try? await Task.sleep(for: .milliseconds(30))
        let mixLandedFirst = player.currentTrack?.stableId == seed.stableId && player.listenerChoiceGeneration == choiceBefore
        await player.playTrack(other, queue: [other])
        let mixOutcome = await mixTask.value
        var superseded = false
        if case .superseded = mixOutcome { superseded = true }
        try? await Task.sleep(for: .seconds(2.5))
        let stillOther = player.currentTrack?.stableId == other.stableId
        if mixLandedFirst {
            skip("songmix.listener-choice-cancels-mix", "the mix was already playing before the listener's choice could be made")
        } else {
            report("songmix.listener-choice-cancels-mix", superseded && stillOther && player.playbackQueue.count == 1,
                   "mixOutcome=\(mixOutcome) current='\(player.currentTrack?.title ?? "nil")' (want '\(other.title)') queue=\(player.playbackQueue.count) (want 1) isPlaying=\(player.isPlaying) choiceGen \(choiceBefore)->\(player.listenerChoiceGeneration)")
        }
        timedStop("songmix.after-D")
        try? await Task.sleep(for: .milliseconds(600))
    }

    // MARK: - 5. DSD / EQ (plays briefly)

    private static func dsdEQSuite() async {
        let player = PlayerEngine.shared
        let eq = EQManager.shared

        // EQManager loads its settings in a task at init; compare with the
        // stored row before taking the user's values.
        let stored = try? await DatabaseManager.shared.getEQSettings()
        _ = await waitUntil(3) {
            guard let stored else { return true }
            return eq.isEnabled == stored.isEnabled && (stored.activePresetId == nil || eq.currentPreset?.id == stored.activePresetId)
        }
        let original = (enabled: eq.isEnabled, preset: eq.currentPreset, gain: eq.globalGain)
        info("dsdeq.eq-before", "enabled=\(original.enabled) preset=\(original.preset?.name ?? "none")(\(original.preset?.id.map { "\($0)" } ?? "-")) gain=\(original.gain) stored.enabled=\(stored?.isEnabled.description ?? "nil") stored.preset=\(stored?.activePresetId.map { "\($0)" } ?? "nil") presets=\(eq.availablePresets.count)")

        // EQ on without a preset is a bypass; borrow one for the "on" runs.
        var onPreset = original.preset
        if onPreset == nil, let any = eq.availablePresets.first {
            onPreset = any
            info("dsdeq.eq-preset", "no active preset - using '\(any.name)' for the EQ-on runs, put back to none afterwards")
        } else if onPreset == nil {
            info("dsdeq.eq-preset", "no EQ presets at all - EQ-on runs only exercise the toggle (bands bypassed)")
        }

        let tracks = await allTracks()
        let dsd = tracks.filter { ["dsf", "dff"].contains(fileExtension($0)) }
        let localDSD = dsd.filter(isLocal)
        info("dsdeq.library", "dsdTracks=\(dsd.count) localDSD=\(localDSD.count) dsf=\(dsd.filter { fileExtension($0) == "dsf" }.count) dff=\(dsd.filter { fileExtension($0) == "dff" }.count)")

        var picks: [(label: String, track: Track)] = []
        if let dsf = localDSD.first(where: { fileExtension($0) == "dsf" }) { picks.append(("dsf", dsf)) }
        if let dff = localDSD.first(where: { fileExtension($0) == "dff" }) { picks.append(("dff", dff)) }
        if picks.isEmpty {
            if dsd.isEmpty {
                skip("dsdeq.dsd", "no DSD (.dsf/.dff) files in this library - DSD could not be tested on this device")
            } else {
                skip("dsdeq.dsd", "\(dsd.count) DSD track(s) in the library but none downloaded on the device")
            }
        }
        let flacs = tracks.filter { fileExtension($0) == "flac" }
        if let hiRes = flacs.shuffled().prefix(200).first(where: { ($0.sampleRate ?? 0) >= 88_200 && isLocal($0) }) {
            picks.append(("flac-hires", hiRes))
        }
        if let flac = flacs.shuffled().prefix(200).first(where: { ($0.sampleRate ?? 44_100) <= 48_000 && isLocal($0) }) {
            picks.append(("flac", flac))
        }
        if let mp3 = tracks.filter({ fileExtension($0) == "mp3" }).shuffled().prefix(200).first(where: isLocal) {
            picks.append(("mp3", mp3))
        }

        func setEQ(on: Bool) {
            if on, let onPreset, eq.currentPreset?.id != onPreset.id { eq.currentPreset = onPreset }
            if eq.isEnabled != on { eq.isEnabled = on }
        }

        for pick in picks {
            info("dsdeq.\(pick.label).track",
                 "'\(pick.track.title)' sr=\(pick.track.sampleRate ?? 0) bits=\(pick.track.bitDepth ?? 0) ch=\(pick.track.channels ?? 0)")
            for loadWithEQ in [false, true] {
                setEQ(on: loadWithEQ)
                let phase = "\(pick.label).load-eq-\(loadWithEQ ? "on" : "off")"
                await player.playTrack(pick.track, queue: [pick.track])
                let started = await waitUntil(8) { player.isPlaying || player.playbackErrorMessage != nil }
                let t0 = player.playbackTime
                try? await Task.sleep(for: .seconds(3))
                let t1 = player.playbackTime
                report("dsdeq.\(phase)", started && player.isPlaying && player.playbackErrorMessage == nil && t1 - t0 > 2,
                       "sfb=\(player.isUsingSFBEngine) started=\(started) playing=\(player.isPlaying) progress \(seconds(t0))->\(seconds(t1)) error=\(player.playbackErrorMessage ?? "nil")")

                setEQ(on: !loadWithEQ)
                let t2 = player.playbackTime
                try? await Task.sleep(for: .seconds(2))
                let t3 = player.playbackTime
                report("dsdeq.\(phase).toggle-eq-\(loadWithEQ ? "off" : "on")-live",
                       player.isPlaying && player.playbackErrorMessage == nil && t3 - t2 > 1.2,
                       "playing=\(player.isPlaying) progress \(seconds(t2))->\(seconds(t3)) error=\(player.playbackErrorMessage ?? "nil")")
                timedStop("dsdeq.\(phase)")
                try? await Task.sleep(for: .milliseconds(700))
            }
        }

        // Put the user's EQ back exactly.
        if eq.currentPreset?.id != original.preset?.id { eq.currentPreset = original.preset }
        if eq.isEnabled != original.enabled { eq.isEnabled = original.enabled }
        if abs(eq.globalGain - original.gain) > 0.001 { eq.globalGain = original.gain }
        try? await Task.sleep(for: .seconds(1.5))
        let after = try? await DatabaseManager.shared.getEQSettings()
        let liveMatches = eq.isEnabled == original.enabled && eq.currentPreset?.id == original.preset?.id
        var storedMatches = true
        if let stored {
            let sameEnabled = after?.isEnabled == stored.isEnabled
            let samePreset = after?.activePresetId == stored.activePresetId
            let sameGain = abs((after?.globalGain ?? 0) - stored.globalGain) < 0.001
            storedMatches = sameEnabled && samePreset && sameGain
        }
        let matches = liveMatches && storedMatches
        report("dsdeq.eq-restored", matches,
               "now enabled=\(eq.isEnabled) preset=\(eq.currentPreset?.id.map { "\($0)" } ?? "none") stored.enabled=\(after?.isEnabled.description ?? "nil") stored.preset=\(after?.activePresetId.map { "\($0)" } ?? "nil")")
    }

    // MARK: - Stop timing (plays a few seconds per song)

    /// How long pause() and stop() each hold the main thread on a playing
    /// song.
    private static func stopTimingSuite() async {
        let player = PlayerEngine.shared
        let tracks = await allTracks()
        let picks = Array(tracks.shuffled().prefix(200).filter(isLocal).prefix(3))
        guard !picks.isEmpty else {
            skip("stoptiming", "no song stored on the device")
            return
        }
        for track in picks {
            await player.playTrack(track, queue: [track])
            let started = await waitUntil(8) { player.isPlaying || player.playbackErrorMessage != nil }
            try? await Task.sleep(for: .seconds(2))
            let pauseStart = Date()
            player.pause()
            let pauseTime = Date().timeIntervalSince(pauseStart)
            try? await Task.sleep(for: .milliseconds(500))
            player.play()
            let resumed = await waitUntil(5) { player.isPlaying }
            try? await Task.sleep(for: .seconds(1))
            let wasSFB = player.isUsingSFBEngine
            let stopStart = Date()
            timedStop("stoptiming")
            let stopTime = Date().timeIntervalSince(stopStart)
            info("stoptiming.\(fileExtension(track))",
                 "'\(track.title)' started=\(started) resumed=\(resumed) sfb=\(wasSFB) pause()=\(seconds(pauseTime))s stop()=\(seconds(stopTime))s")

            // Play straight after stop(), while its audio-session release is
            // still queued or running: that release must not land after the
            // new activation and silence the song.
            let playStart = Date()
            player.play()
            let playTime = Date().timeIntervalSince(playStart)
            let replayed = await waitUntil(5) { player.isPlaying }
            let positionBefore = player.playbackTime
            try? await Task.sleep(for: .seconds(2))
            let advanced = player.isPlaying && player.playbackTime > positionBefore + 1
            report("stoptiming.play-after-stop.\(fileExtension(track))", replayed && advanced,
                   "playing=\(replayed) stillPlayingAndAdvancing=\(advanced) position \(seconds(positionBefore))s->\(seconds(player.playbackTime))s play()=\(seconds(playTime))s error=\(player.playbackErrorMessage ?? "none")")
            timedStop("stoptiming")
            try? await Task.sleep(for: .milliseconds(700))
        }
    }

    // MARK: - State check (after a playback run)

    private static func stateCheckSuite() async {
        let player = PlayerEngine.shared
        await player.ensureSavedStateRestored()
        let now = UserStateSnapshot.currentFingerprint()
        info("state.now", now.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))
        if let expected = UserDefaults.standard.dictionary(forKey: UserStateSnapshot.fingerprintKey) as? [String: String] {
            let differing = expected.keys.filter { expected[$0] != now[$0] }.sorted()
            report("state.matches-pre-test-snapshot", differing.isEmpty,
                   differing.isEmpty ? "player session, listening log, recents and EQ as before the test"
                                     : differing.map { "\($0): was \(expected[$0] ?? "nil") now \(now[$0] ?? "nil")" }.joined(separator: "; "))
            UserDefaults.standard.removeObject(forKey: UserStateSnapshot.fingerprintKey)
        } else {
            info("state.matches-pre-test-snapshot", "no snapshot fingerprint saved by an earlier playback run")
        }
        // The widget still shows the last test song otherwise.
        player.updateWidgetData()
    }
}

// MARK: - Snapshot of what playback touches

@MainActor
private struct UserStateSnapshot {
    static let defaultsKeys = [
        "CosmosPlayerState",
        "cosmos.recentlyPlayedTrackIds",
        "cosmos.recentSources",
        "cosmos.mixLessons",
        "cosmos.rediscoverShown",
        "cosmos.tasteCuration",
        "cosmos.lastArtistProfiling"
    ]
    // listening-stats.json too: test plays must not count toward the
    // listener's monthly stats.
    static let fileNames = ["listening-log.json", "listening-lifetime.json", "listening-stats.json"]
    static let fingerprintKey = "cosmosSelfTest.expectedFingerprint"

    let values: [String: Any]
    let files: [String: Data]
    let domain: [String: Any]
    let listing: [String: String]
    let fingerprint: [String: String]

    static var supportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static var backupURL: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cosmos-selftest-backup")
    }

    static func take() -> UserStateSnapshot {
        var values: [String: Any] = [:]
        for key in defaultsKeys {
            if let value = UserDefaults.standard.object(forKey: key) { values[key] = value }
        }
        var files: [String: Data] = [:]
        for name in fileNames {
            if let data = try? Data(contentsOf: supportURL.appendingPathComponent(name)) { files[name] = data }
        }
        let snapshot = UserStateSnapshot(
            values: values,
            files: files,
            domain: persistentDomain(),
            listing: supportListing(),
            fingerprint: currentFingerprint()
        )
        snapshot.writeBackup()
        return snapshot
    }

    var summary: String {
        let saved = values["CosmosPlayerState"] as? [String: Any]
        let queue = (saved?["queueTrackIds"] as? [String])?.count ?? 0
        return "session=\((saved?["currentTrackStableId"] as? String).map { String($0.prefix(10)) } ?? "none") queue=\(queue) keys=\(values.keys.sorted().joined(separator: ",")) files=\(files.map { "\($0.key):\($0.value.count)B" }.sorted().joined(separator: ",")) backup=\(Self.backupURL.lastPathComponent)"
    }

    /// Puts the snapshot back. Returns what it restored.
    func restore() -> [String] {
        Self.apply(values: values, files: files)
        try? FileManager.default.removeItem(at: Self.backupURL)
        return Self.defaultsKeys.map { "defaults:\($0)" } + Self.fileNames.map { "file:\($0)" }
    }

    private static func apply(values: [String: Any], files: [String: Data]) {
        for key in defaultsKeys {
            if let value = values[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        for name in fileNames {
            let url = supportURL.appendingPathComponent(name)
            if let data = files[name] {
                try? data.write(to: url, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        UserDefaults.standard.synchronize()
    }

    /// Keys and Application Support entries that changed during the run
    /// and were not restored - reported, never touched.
    func otherChanges() -> (defaults: [String], files: [String]) {
        let now = Self.persistentDomain()
        let ignored = Set(Self.defaultsKeys + [Self.fingerprintKey])
        let keys = Set(domain.keys).union(now.keys).subtracting(ignored)
        let changedKeys = keys.filter { key in
            switch (domain[key], now[key]) {
            case (nil, nil): return false
            case (let before?, let after?): return !((before as? NSObject)?.isEqual(after) ?? false)
            default: return true
            }
        }.sorted()
        let nowListing = Self.supportListing()
        let names = Set(listing.keys).union(nowListing.keys).subtracting(Self.fileNames)
        let changedFiles = names.filter { listing[$0] != nowListing[$0] }.sorted()
        return (changedKeys, changedFiles)
    }

    private static func persistentDomain() -> [String: Any] {
        guard let id = Bundle.main.bundleIdentifier else { return [:] }
        return UserDefaults.standard.persistentDomain(forName: id) ?? [:]
    }

    private static func supportListing() -> [String: String] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: supportURL, includingPropertiesForKeys: keys)) ?? []
        var listing: [String: String] = [:]
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            listing[url.lastPathComponent] = "\(values?.fileSize ?? -1)@\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }
        return listing
    }

    /// What the state-check suite compares after a playback run.
    static func currentFingerprint() -> [String: String] {
        let saved = UserDefaults.standard.dictionary(forKey: "CosmosPlayerState")
        let recents = UserDefaults.standard.stringArray(forKey: "cosmos.recentlyPlayedTrackIds") ?? []
        let logURL = supportURL.appendingPathComponent("listening-log.json")
        let logData = try? Data(contentsOf: logURL)
        let events = logData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        let eq = EQManager.shared
        return [
            "savedTrack": (saved?["currentTrackStableId"] as? String).map { String($0.prefix(12)) } ?? "none",
            "savedQueue": "\((saved?["queueTrackIds"] as? [String])?.count ?? 0)",
            "savedIndex": "\(saved?["currentIndex"] as? Int ?? -1)",
            "savedModes": "repeat=\(saved?["isRepeating"] as? Bool ?? false),shuffle=\(saved?["isShuffled"] as? Bool ?? false),one=\(saved?["isLoopingSong"] as? Bool ?? false)",
            "logEvents": "\(events.count)",
            "logLast": (events.last?["id"] as? String).map { String($0.prefix(12)) } ?? "none",
            "logBytes": "\(logData?.count ?? -1)",
            "recents": recents.prefix(3).map { String($0.prefix(8)) }.joined(separator: "|"),
            "eq": "enabled=\(eq.isEnabled),preset=\(eq.currentPreset?.id.map { "\($0)" } ?? "none")"
        ]
    }

    // MARK: Crash-safe copy in tmp

    private func writeBackup() {
        let fileManager = FileManager.default
        let backup = Self.backupURL
        try? fileManager.removeItem(at: backup)
        try? fileManager.createDirectory(at: backup, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "values": values,
            "absentKeys": Self.defaultsKeys.filter { values[$0] == nil },
            "files": Array(files.keys)
        ]
        if let data = try? PropertyListSerialization.data(fromPropertyList: manifest, format: .binary, options: 0) {
            try? data.write(to: backup.appendingPathComponent("manifest.plist"), options: .atomic)
        }
        for (name, data) in files {
            try? data.write(to: backup.appendingPathComponent(name), options: .atomic)
        }
    }

    /// A run that crashed or was killed mid-test left its snapshot in tmp:
    /// put it back before anything else.
    static func restoreLeftoverBackupIfAny() -> Bool {
        let manifestURL = backupURL.appendingPathComponent("manifest.plist")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return false
        }
        let values = manifest["values"] as? [String: Any] ?? [:]
        let fileList = manifest["files"] as? [String] ?? []
        var files: [String: Data] = [:]
        for name in fileList {
            if let data = try? Data(contentsOf: backupURL.appendingPathComponent(name)) { files[name] = data }
        }
        guard fileList.count == files.count else {
            // Something is missing from the backup: restoring it would lose
            // the listening log. Leave everything for a human to look at.
            print("SELFTEST run FAIL leftover backup in \(backupURL.path) is incomplete - not restored")
            return false
        }
        apply(values: values, files: files)
        try? FileManager.default.removeItem(at: backupURL)
        return true
    }
}

// MARK: - Main-thread watchdog

/// Pings the main queue from a background thread and logs every time it
/// takes longer than half a second to answer.
private final class MainThreadWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var hangs = 0
    private var longest: TimeInterval = 0

    var hangCount: Int { lock.withLock { hangs } }
    var longestHang: TimeInterval { lock.withLock { longest } }

    func start() {
        let thread = Thread { [self] in
            while true {
                let semaphore = DispatchSemaphore(value: 0)
                let sent = Date()
                DispatchQueue.main.async { semaphore.signal() }
                if semaphore.wait(timeout: .now() + 0.5) == .timedOut {
                    semaphore.wait()
                    let blocked = Date().timeIntervalSince(sent)
                    lock.withLock {
                        hangs += 1
                        longest = max(longest, blocked)
                    }
                    print(String(format: "SELFTEST-HANG main thread unresponsive for %.2fs", blocked))
                    fflush(nil)
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        thread.name = "SelfTestWatchdog"
        thread.start()
    }
}
#endif
