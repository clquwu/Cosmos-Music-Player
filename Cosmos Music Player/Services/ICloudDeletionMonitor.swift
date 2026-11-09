//
//  ICloudDeletionMonitor.swift
//  Cosmos Music Player
//
//  Notices songs whose files were deleted from iCloud Drive (or from the
//  app's own Documents folder) without waiting for the next library scan.
//

import Combine
import Foundation
import GRDB
import UIKit

/// Removes library rows whose files were deleted, within about a minute.
///
/// Before this, deletions were only ever noticed by a library scan:
/// - `LibraryIndexer`'s live NSMetadataQuery is started by `start()`, i.e. only
///   when a scan runs. With the default daily scan interval, most launches run
///   no scan at all, so the query - and with it every removal event - simply
///   did not exist for that session.
/// - A query started fresh never reports removals that happened while the app
///   was closed (a file deleted on a Mac, or in Files while Cosmos was not
///   running). Only scan reconciliation could catch those, and it is gated by
///   `RemovalConfirmationGuard`, which needs a *second* scan 15 min - 36 h
///   after the first. Daily scans opened every other day, weekly scans and
///   "manual only" never satisfy that window, so the ghost row was observed,
///   expired, observed again... for ever.
///
/// This monitor runs its own lightweight query over the music folder for the
/// whole session and does a cheap existence sweep at launch and on every
/// return to the foreground. A row is removed only when ALL of these hold:
/// - the file is not on disk and there is no `.name.icloud` placeholder for it
///   (an evicted / cloud-only file is never a candidate);
/// - the nearest surviving folder inside the root is a readable directory
///   (`isPathConfirmedMissing(_:within:)`), and the root itself is reachable;
/// - for iCloud: iCloud is available and signed in, this session's query has
///   finished gathering, and iCloud's own metadata no longer lists the file;
/// - the absence persisted for `confirmationDelay` (a playback failure only
///   waits `playbackConfirmationDelay`), no missing file came back meanwhile,
///   and no library scan is running;
/// - if the batch is "most of the library" or iCloud lists far fewer files
///   than the library has (e.g. a restore still materialising, or one made
///   with iCloud offline), only rows iCloud reported removed may go, and
///   only once `RemovalConfirmationGuard` agrees; the rest are kept however
///   long the absence lasts. If iCloud lists nothing at all, nothing goes -
///   unless this session's query had listed files before (the folder was
///   moved or deleted while the app watched), when removal events count;
/// - unless iCloud itself reported the removal: `RemovalConfirmationGuard`
///   agrees, i.e. the absence was first seen at least 15 min earlier and no
///   missing file has come back since. A file that is merely not on disk
///   (sweep, scan, playback) is exactly what a restore that is still
///   publishing the container looks like, and that guard is what tells the
///   two apart - this path must not be a way around it;
/// - no file that could be the row's renamed/moved copy is still waiting to
///   be indexed (otherwise its favourites and playlists could not follow).
@MainActor
final class ICloudDeletionMonitor: NSObject {
    static let shared = ICloudDeletionMonitor()

    private struct Candidate {
        let path: String
        var noticedAt: Date
        var minimumWait: TimeInterval
        /// iCloud's live query reported this file removed. A container that
        /// is still materialising never reports removals for files it has
        /// not published, so this - unlike plain absence - does not need
        /// RemovalConfirmationGuard's second observation.
        var isRemovalEvent: Bool
        /// Missing while iCloud's listing could not be trusted (see
        /// `untrustedRecheckDelay`). Sweeps and scans find it again on every
        /// foreground; they must not pull its next look forward to a minute.
        var isHeld = false
    }

    static let confirmationDelay: TimeInterval = 60
    private static let playbackConfirmationDelay: TimeInterval = 5
    private static let busyRetryDelay: TimeInterval = 30
    /// Matches RemovalConfirmationGuard: missing files that keep coming back
    /// mean the container is still converging, not that songs were deleted.
    private static let reappearanceQuietPeriod: TimeInterval = 15 * 60
    /// How long rows missing from an untrusted iCloud listing wait before
    /// being looked at again. Nothing about them can change on a 15-minute
    /// timer - only the listing recovering, or a removal event, which
    /// cuts the wait short.
    private static let untrustedRecheckDelay: TimeInterval = 3 * 60 * 60

    nonisolated private static let audioPatterns = [
        "*.flac", "*.mp3", "*.wav", "*.m4a", "*.aac", "*.opus", "*.ogg", "*.oga", "*.dsf", "*.dff"
    ]

    private var query: NSMetadataQuery?
    private var queryRootPath: String?
    private var hasGathered = false
    /// Bumped whenever the iCloud account or status changes. A verification
    /// that awaited across a change must not act on what it saw before.
    private var iCloudGeneration = 0
    /// `presentFiles` of the current query, until its next update. Built
    /// from every result, so not again on each verification of a quiet
    /// query.
    private var presentFilesCache: [String: Int64]?
    /// The `iCloudGeneration` and root in which a gathered query listed at
    /// least one file. An empty listing is what a restore or an offline
    /// container looks like - but only if iCloud never showed this session
    /// any file. Once it has, an empty listing with removal events is the
    /// user moving or deleting their whole music folder, and those events
    /// are real evidence (see verify()).
    private var listedFilesIn: (generation: Int, rootPath: String)?

    /// Keyed by canonical path.
    private var candidates: [String: Candidate] = [:]
    /// Paths iCloud reported as new since the last verification. A rename or
    /// move arrives as removal + addition; the new file has to be indexed
    /// before the old row is removed, or its favourites and playlist entries
    /// cannot be carried over.
    private var addedPaths: Set<String> = []
    /// Unindexed files a scan was already started for, with when. If one is
    /// still unindexed afterwards (cloud-only, unreadable, unplayable),
    /// starting yet another scan would not help - and would loop. Persisted:
    /// kept per session only, the same unindexable file forced a full scan
    /// on every launch.
    private lazy var rescannedForPaths: [String: Date] = Self.loadRescannedPaths()
    private static let rescannedPathsKey = "ICloudDeletionMonitorRescannedPaths"
    /// After this a file gets one more scan, in case it became indexable.
    private static let rescanTTL: TimeInterval = 7 * 24 * 60 * 60
    /// How long a file a scan could not index keeps blocking the removal of
    /// rows it might be the renamed copy of (same size; same name or folder
    /// when its size is unknown). Time for a cloud-only copy to download and
    /// be indexed. Past it, a file that may never be indexable no longer
    /// keeps a deleted song in the library for ever.
    private static let unindexableHold: TimeInterval = 24 * 60 * 60

    private var verificationTask: Task<Void, Never>?
    private var verificationDueAt: Date?
    /// verify() awaits; a verification falling due meanwhile waits for it
    /// rather than running alongside it on the same candidates.
    private var isVerifying = false
    private var verifyAgainWhenDone = false
    private var sweepTask: Task<Void, Never>?
    private var isActivated = false
    private var cancellables = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []

    private override init() {
        super.init()
    }

    // MARK: - Lifecycle

    /// Call once AppCoordinator has resolved the iCloud status.
    func activate() {
        guard !isActivated else { return }
        isActivated = true

        AppCoordinator.shared.$iCloudStatus
            .dropFirst()
            .sink { [weak self] _ in
                // @Published emits from willSet; read the new value after.
                Task { @MainActor in
                    self?.iCloudGeneration += 1
                    self?.refreshQuery()
                }
            }
            .store(in: &cancellables)

        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { @Sendable _ in
            Task { @MainActor in
                let monitor = ICloudDeletionMonitor.shared
                monitor.refreshQuery()
                monitor.scheduleSweep(after: 3)
            }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange,
            object: nil,
            queue: .main
        ) { @Sendable _ in
            Task { @MainActor in
                // A different (or no) account: nothing observed so far is
                // evidence about the new container.
                let monitor = ICloudDeletionMonitor.shared
                monitor.iCloudGeneration += 1
                monitor.stopQuery()
                monitor.candidates.removeAll()
                monitor.addedPaths.removeAll()
                monitor.rescannedForPaths.removeAll()
                monitor.saveRescannedPaths()
                monitor.refreshQuery()
            }
        })

        refreshQuery()
        // Off the launch path; the sweep itself runs off the main actor.
        scheduleSweep(after: 10)
    }

    private var isICloudUsable: Bool {
        AppCoordinator.shared.iCloudStatus == .available
            && FileManager.default.ubiquityIdentityToken != nil
    }

    private func refreshQuery() {
        guard isICloudUsable, let root = StateManager.shared.getMusicFolderURL() else {
            stopQuery()
            return
        }
        let rootPath = DatabaseManager.canonicalPath(root.path)
        if query != nil, queryRootPath == rootPath { return }

        stopQuery()
        let newQuery = NSMetadataQuery()
        // The ubiquitous-documents scope, not `root`. On device a scope naming
        // the container's Documents folder itself - as a URL or a path, with
        // or without /private - never finishes gathering: still 0 results
        // after two minutes, while this scope lists every file within seconds
        // (SelfTests `query-probe`). The query never became ready, so every
        // iCloud row was skipped and no removal event ever arrived - the
        // monitor did nothing at all. This scope is the Documents folder of
        // the app's iCloud container, which is `root` (the app has one
        // container); results are still kept to `root` wherever they are read
        // (`canonicalPath(of:under:)`), so a listing can only ever speak for
        // the music folder.
        newQuery.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        newQuery.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: Self.audioPatterns.map {
            NSPredicate(format: "%K LIKE[c] %@", NSMetadataItemFSNameKey, $0)
        })
        newQuery.notificationBatchingInterval = 1

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidFinishGathering(_:)),
            name: .NSMetadataQueryDidFinishGathering,
            object: newQuery
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidUpdate(_:)),
            name: .NSMetadataQueryDidUpdate,
            object: newQuery
        )

        guard newQuery.start() else {
            NotificationCenter.default.removeObserver(self, name: nil, object: newQuery)
            print("🗑️ iCloud deletion monitor: query refused to start")
            return
        }
        query = newQuery
        queryRootPath = rootPath
        hasGathered = false
        presentFilesCache = nil
        print("🗑️ iCloud deletion monitor started")
    }

    private func stopQuery() {
        guard let query else { return }
        query.stop()
        NotificationCenter.default.removeObserver(self, name: nil, object: query)
        self.query = nil
        queryRootPath = nil
        hasGathered = false
        presentFilesCache = nil
    }

    @objc private func queryDidFinishGathering(_ notification: Notification) {
        guard let query, (notification.object as? NSMetadataQuery) === query else { return }
        hasGathered = true
        presentFilesCache = nil
        noteListing()
        // The line to look for on a device: with the old folder scope no
        // query ever got this far.
        print("🗑️ iCloud deletion monitor ready - \(query.resultCount) audio file(s) listed, listedThisSession=\(hasListedFilesThisSession)")
        // Deletions made while the app was closed only show up as absences.
        scheduleSweep(after: 1)
    }

    @objc private func queryDidUpdate(_ notification: Notification) {
        guard (notification.object as? NSMetadataQuery) === query else { return }
        presentFilesCache = nil
        // A query that gathered empty and then filled up has listed files too.
        noteListing()
        // Only the music folder's files: an event elsewhere in the scope says
        // nothing about this library (and assess() would only drop it).
        let removed = Self.paths(in: notification.userInfo?[NSMetadataQueryUpdateRemovedItemsKey], under: queryRootPath)
        let added = Self.paths(in: notification.userInfo?[NSMetadataQueryUpdateAddedItemsKey], under: queryRootPath)
        addedPaths.formUnion(added)
        guard !removed.isEmpty else { return }
        print("🗑️ iCloud reported \(removed.count) removed file(s) - verifying in \(Int(Self.confirmationDelay))s")
        consider(paths: removed, wait: Self.confirmationDelay, isRemovalEvent: true)
    }

    /// Records that the current, gathered query lists at least one file in
    /// the music folder. `resultCount` alone counted the whole scope; once
    /// recorded this session, nothing is walked again.
    private func noteListing() {
        guard let query, hasGathered, let queryRootPath, query.resultCount > 0,
              !hasListedFilesThisSession,
              Self.listsAnyFile(in: query, under: queryRootPath) else { return }
        listedFilesIn = (iCloudGeneration, queryRootPath)
    }

    /// Whether iCloud listed any file for the current music folder since the
    /// account or status last changed. Compared with the running query's
    /// root: a listing of another folder proves nothing about this one.
    private var hasListedFilesThisSession: Bool {
        guard let listedFilesIn, listedFilesIn.generation == iCloudGeneration,
              let queryRootPath, listedFilesIn.rootPath == queryRootPath else { return false }
        return true
    }

    /// Canonical paths iCloud reported removed while its listing could be
    /// believed (it has listed files this session), for the scan path's mass
    /// rule. Those rows still need RemovalConfirmationGuard; this only stops
    /// them from being held with the rest. Empty when iCloud never listed
    /// anything this session: a removal event then proves no more than an
    /// absence does.
    func trustedRemovalEventPaths() -> Set<String> {
        guard isICloudUsable, hasListedFilesThisSession else { return [] }
        return Set(candidates.values.filter(\.isRemovalEvent).map(\.path))
    }

    private static func paths(in value: Any?, under rootPath: String?) -> [String] {
        guard let rootPath, let items = value as? [NSMetadataItem] else { return [] }
        return items.compactMap { canonicalPath(of: $0, under: rootPath) }
    }

    /// An item's canonical path, or nil when it is not inside `rootPath`.
    /// Canonical: the query and the container lookup do not agree on whether
    /// paths start with /private, and library rows are stored without it.
    private static func canonicalPath(of item: NSMetadataItem, under rootPath: String) -> String? {
        let path: String
        if let itemPath = item.value(forAttribute: NSMetadataItemPathKey) as? String {
            path = DatabaseManager.canonicalPath(itemPath)
        } else if let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL {
            path = DatabaseManager.canonicalPath(url.path)
        } else {
            return nil
        }
        return path == rootPath || path.hasPrefix(rootPath + "/") ? path : nil
    }

    /// Whether any result lies in `rootPath`; normally the first one answers.
    private static func listsAnyFile(in query: NSMetadataQuery, under rootPath: String) -> Bool {
        query.disableUpdates()
        defer { query.enableUpdates() }
        for index in 0..<query.resultCount {
            if let item = query.result(at: index) as? NSMetadataItem,
               canonicalPath(of: item, under: rootPath) != nil {
                return true
            }
        }
        return false
    }

    // MARK: - Inputs

    /// Paths some other pass found missing (scan reconciliation, orphan
    /// check), or that iCloud reported removed (`isRemovalEvent`).
    func consider(
        paths: [String],
        wait: TimeInterval = ICloudDeletionMonitor.confirmationDelay,
        isRemovalEvent: Bool = false
    ) {
        guard !paths.isEmpty else { return }
        let now = Date()
        for raw in paths {
            let path = DatabaseManager.canonicalPath(raw)
            if var existing = candidates[path] {
                if existing.isHeld && !isRemovalEvent {
                    // Held for an untrusted listing: finding it missing
                    // again says nothing new. A removal event does.
                    continue
                }
                // A stronger signal (playback) may shorten the wait.
                existing.minimumWait = min(existing.minimumWait, wait)
                existing.isRemovalEvent = existing.isRemovalEvent || isRemovalEvent
                existing.isHeld = false
                candidates[path] = existing
            } else {
                candidates[path] = Candidate(
                    path: path,
                    noticedAt: now,
                    minimumWait: wait,
                    isRemovalEvent: isRemovalEvent
                )
            }
        }
        scheduleVerification(after: wait)
    }

    /// Playback could not find this track's file. Re-check it right away
    /// instead of leaving a ghost row that fails every time it is tapped.
    func reportMissingFile(path: String) {
        guard !FileManager.default.fileExists(atPath: path) else { return }
        print("🗑️ Playback found no file - verifying: \(URL(fileURLWithPath: path).lastPathComponent)")
        consider(paths: [path], wait: Self.playbackConfirmationDelay)
    }

    // MARK: - Sweep

    func scheduleSweep(after delay: TimeInterval) {
        sweepTask?.cancel()
        sweepTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.sweep()
        }
    }

    /// One existence check per track under the iCloud music folder or the
    /// app's Documents folder, off the main actor. Absences only become
    /// candidates; verification decides.
    private func sweep() async {
        guard UIApplication.shared.applicationState != .background else { return }
        var rootPaths: [String] = []
        if isICloudUsable, let root = StateManager.shared.getMusicFolderURL() {
            rootPaths.append(DatabaseManager.canonicalPath(root.path))
        }
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            rootPaths.append(DatabaseManager.canonicalPath(documents.path))
        }
        guard !rootPaths.isEmpty else { return }

        let roots = rootPaths
        let missing: [String] = await Task.detached(priority: .utility) {
            guard let paths = try? DatabaseManager.shared.read({ db in
                try String.fetchAll(db, sql: "SELECT path FROM track")
            }) else { return [] }
            return paths.filter { path in
                let canonical = DatabaseManager.canonicalPath(path)
                guard roots.contains(where: { canonical == $0 || canonical.hasPrefix($0 + "/") }) else {
                    return false
                }
                return !FileManager.default.fileExists(atPath: path)
            }
        }.value

        if !missing.isEmpty {
            print("🗑️ Sweep found \(missing.count) track(s) without a file - verifying")
        }
        consider(paths: missing)
        if !candidates.isEmpty {
            scheduleVerification(after: 1)
        }
    }

    // MARK: - Verification

    private func scheduleVerification(after delay: TimeInterval) {
        let due = Date().addingTimeInterval(delay)
        if let current = verificationDueAt, verificationTask != nil, current <= due { return }
        verificationTask?.cancel()
        verificationDueAt = due
        verificationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.verificationTask = nil
            self.verificationDueAt = nil
            guard !self.isVerifying else {
                self.verifyAgainWhenDone = true
                return
            }
            self.isVerifying = true
            await self.verify()
            self.isVerifying = false
            if self.verifyAgainWhenDone {
                self.verifyAgainWhenDone = false
                self.scheduleVerification(after: 1)
            }
        }
    }

    /// What the off-main pass made of the due candidates.
    private struct Assessment: @unchecked Sendable {
        var reappeared = false
        /// No longer candidates: back on disk, row already gone, absence not
        /// authoritative, or outside the roots this monitor judges.
        var dropped: [String] = []
        var localMissing: [Track] = []
        /// Confirmed missing on disk; iCloud's listing is checked on main.
        var iCloudMissing: [Track] = []
    }

    private func verify() async {
        guard !candidates.isEmpty else { return }

        // The database can be suspended in the background; the foreground
        // sweep schedules this again.
        guard UIApplication.shared.applicationState != .background else { return }

        // A running scan may be indexing the new half of a rename, and it
        // runs its own reconciliation.
        guard !LibraryIndexer.shared.isIndexing else {
            scheduleVerification(after: Self.busyRetryDelay)
            return
        }

        if let quietFor = FileCleanupManager.shared.secondsSinceMissingFileReappeared,
           quietFor < Self.reappearanceQuietPeriod {
            scheduleVerification(after: Self.reappearanceQuietPeriod - quietFor)
            return
        }

        let now = Date()
        let notDue = candidates.values.filter { now.timeIntervalSince($0.noticedAt) < $0.minimumWait }
        if let next = notDue.map({ $0.minimumWait - now.timeIntervalSince($0.noticedAt) }).min() {
            scheduleVerification(after: next)
        }
        let due = candidates.values.filter { now.timeIntervalSince($0.noticedAt) >= $0.minimumWait }
        guard !due.isEmpty else { return }

        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let iCloudRoot = isICloudUsable ? StateManager.shared.getMusicFolderURL() : nil
        // Signed out, unavailable, query not ready: iCloud candidates are
        // left as they are.
        let iCloudReady = query.map { hasGathered && !$0.isGathering } ?? false
        let duePaths = due.map(\.path)
        // What iCloud looked like when this pass started; checked again just
        // before removing anything (see the end).
        let startQuery = query
        let startGeneration = iCloudGeneration

        // A stat, a row lookup and an ancestor walk per candidate. Thousands
        // of candidates (a deleted album folder, a big cleanup) blocked the
        // UI for seconds when this ran on the main actor.
        var assessment = await Task.detached(priority: .utility) {
            Self.assess(duePaths, documentsURL: documentsURL, iCloudRoot: iCloudRoot, iCloudReady: iCloudReady)
        }.value
        for path in assessment.dropped { candidates[path] = nil }

        if assessment.reappeared {
            FileCleanupManager.shared.noteMissingFileReappeared()
            print("🗑️ 🛡️ A missing file came back - postponing removals")
            scheduleVerification(after: Self.reappearanceQuietPeriod)
            return
        }

        // iCloud's own listing, downloaded or not. Read here, where the query
        // runs (NSMetadataQuery is not safe to read from another thread), and
        // only when some iCloud row is still in question.
        var iCloudPresent: [String: Int64]?
        if !assessment.iCloudMissing.isEmpty {
            if let query, hasGathered, !query.isGathering, let queryRootPath {
                let present = presentFilesCache ?? Self.presentFiles(in: query, under: queryRootPath)
                presentFilesCache = present
                iCloudPresent = present
                assessment.iCloudMissing.removeAll { track in
                    let path = DatabaseManager.canonicalPath(track.path)
                    guard present[path] != nil else { return false }
                    // iCloud still knows this file (evicted, mid-sync).
                    candidates[path] = nil
                    return true
                }
            } else {
                // The query restarted while the pass ran: look again later.
                assessment.iCloudMissing = []
                scheduleVerification(after: Self.busyRetryDelay)
            }
        }

        var localMissing = assessment.localMissing
        var iCloudMissing = assessment.iCloudMissing

        // Plain absence has to satisfy RemovalConfirmationGuard like the scan
        // path does. Scan reconciliation hands its withheld rows here, and
        // the launch/foreground sweep finds the same rows; deleting them a
        // minute later on weaker evidence defeated the guard during a
        // restore. Withheld rows stay candidates and are looked at again
        // once the guard's grace period has passed, which is also the
        // second observation daily/weekly scans rarely provide.
        //
        // Two shapes make iCloud's view untrustworthy: most of the iCloud
        // library missing at once, or iCloud listing far fewer files than
        // the library still has (its view has not converged). After a
        // restore with iCloud offline or sync paused the container is
        // readable but empty, and it stays exactly as empty 15 minutes
        // later - so in those batches time alone confirms nothing, and the
        // guard's "nothing came back" cannot hold while nothing can come
        // back. Only a row iCloud explicitly reported removed may go, and
        // only once the guard also agrees. The rest are held: kept, their
        // guard observations dropped (a recovered listing must take its own
        // second look rather than confirm on an hours-old first one), and
        // looked at again every `untrustedRecheckDelay`. If iCloud lists no
        // file at all, nothing is removed, removal events included - unless
        // this session's query (same account and status) did list files
        // earlier. Then the listing emptied while the app watched, and a
        // removal event is the user moving or deleting their whole music
        // folder: holding it too kept every song as a ghost, or as a
        // duplicate of the moved copy, for good. Those rows still have to
        // satisfy the guard; rows with no event are held as before.
        //
        // The cost, accepted: someone who deletes more than half their iCloud
        // songs elsewhere while no removal events reach the app (app closed,
        // another device) keeps those ghost rows until the listing again
        // holds at least half of the remaining library and the missing
        // share drops below half, or until they remove them by hand.
        // Losing a whole library to an offline restore is far worse.
        let removalEvents = Set(candidates.values.filter(\.isRemovalEvent).map(\.path))
        let localSnapshot = localMissing
        let iCloudSnapshot = iCloudMissing
        let iCloudRootPath = iCloudRoot?.path
        let presentCount = iCloudPresent?.count ?? 0
        let listedFilesBefore = hasListedFilesThisSession
        let (withheld, held): (Set<String>, Set<String>) = await Task.detached(priority: .utility) {
            var untrusted = false
            var listsNothing = false
            if !iCloudSnapshot.isEmpty, let iCloudRootPath {
                let total = (try? DatabaseManager.shared.countTracks(underPath: iCloudRootPath)) ?? 0
                let remaining = total - iCloudSnapshot.count
                if presentCount == 0, listedFilesBefore {
                    print("🗑️ 🛡️ iCloud's listing emptied this session (\(total) iCloud tracks) - removing only those iCloud reported removed")
                    untrusted = true
                } else if presentCount == 0 {
                    print("🗑️ 🛡️ iCloud lists no files for \(total) iCloud tracks - removing nothing")
                    untrusted = true
                    listsNothing = true
                } else if iCloudSnapshot.count > 1, iCloudSnapshot.count * 2 > total {
                    print("🗑️ 🛡️ \(iCloudSnapshot.count)/\(total) iCloud tracks missing - removing only those iCloud reported removed")
                    untrusted = true
                } else if remaining > 0, presentCount * 2 < remaining {
                    print("🗑️ 🛡️ iCloud lists \(presentCount) files for \(remaining) remaining tracks - removing only those iCloud reported removed")
                    untrusted = true
                }
            }
            func isEvent(_ track: Track) -> Bool {
                removalEvents.contains(DatabaseManager.canonicalPath(track.path))
            }
            let heldTracks = untrusted
                ? iCloudSnapshot.filter { listsNothing || !isEvent($0) }
                : []
            let heldIds = Set(heldTracks.map(\.stableId))
            if !heldIds.isEmpty {
                FileCleanupManager.forgetAbsences(Array(heldIds))
            }
            let mustConfirm = localSnapshot.filter { !isEvent($0) }
                + iCloudSnapshot.filter { !heldIds.contains($0.stableId) && (untrusted || !isEvent($0)) }
            guard !mustConfirm.isEmpty else { return ([], heldIds) }
            // Off the main actor too: a stat per pending entry and a JSON
            // round trip of the whole set.
            let confirmed = FileCleanupManager.confirmedAbsences(among: mustConfirm)
            return (Set(mustConfirm.map(\.stableId)).subtracting(confirmed), heldIds)
        }.value

        if !held.isEmpty {
            let noticedAt = Date()
            for track in iCloudMissing where held.contains(track.stableId) {
                let path = DatabaseManager.canonicalPath(track.path)
                candidates[path] = Candidate(
                    path: path,
                    noticedAt: noticedAt,
                    minimumWait: Self.untrustedRecheckDelay,
                    isRemovalEvent: candidates[path]?.isRemovalEvent ?? false,
                    isHeld: true
                )
            }
            iCloudMissing.removeAll { held.contains($0.stableId) }
            scheduleVerification(after: Self.untrustedRecheckDelay)
        }

        if !withheld.isEmpty {
            let grace = FileCleanupManager.removalConfirmationGrace
            let noticedAt = Date()
            for track in localMissing + iCloudMissing where withheld.contains(track.stableId) {
                let path = DatabaseManager.canonicalPath(track.path)
                candidates[path] = Candidate(
                    path: path,
                    noticedAt: noticedAt,
                    minimumWait: grace,
                    isRemovalEvent: candidates[path]?.isRemovalEvent ?? false
                )
            }
            localMissing.removeAll { withheld.contains($0.stableId) }
            iCloudMissing.removeAll { withheld.contains($0.stableId) }
            scheduleVerification(after: grace)
        }

        // Possible rename/move: index the new file first so the old row's
        // favourites and playlist entries can follow it. Live additions only
        // cover renames made while the app was running; one made while it
        // was closed is found by the sweep with no addition event, so also
        // look for any audio file nobody has indexed whose size matches a
        // row about to go (preserveReferencesForAuthoritativelyMissingTrack
        // matches on size too, so nothing else could inherit the references).
        if !iCloudMissing.isEmpty || !localMissing.isEmpty {
            let removing = localMissing + iCloudMissing
            let sizes = Set(removing.compactMap(\.fileSize).filter { $0 > 0 })
            let listed = iCloudMissing.isEmpty
                ? [:]
                : (iCloudPresent ?? [:]).filter { sizes.contains($0.value) || $0.value == Self.unknownSize }
            let added = addedPaths
            addedPaths.removeAll()
            let localRoot = localMissing.isEmpty ? nil : documentsURL
            let unindexed = await Task.detached(priority: .utility) {
                Self.unindexedFiles(added: added, listed: listed, localRoot: localRoot, sizes: sizes)
            }.value

            // A scan may have started while the lookup ran.
            guard !LibraryIndexer.shared.isIndexing else {
                scheduleVerification(after: Self.busyRetryDelay)
                return
            }

            let checkedAt = Date()
            pruneRescannedPaths(now: checkedAt)
            let notYetRescanned = unindexed.keys.filter { rescannedForPaths[$0] == nil }
            if !notYetRescanned.isEmpty {
                notYetRescanned.forEach { rescannedForPaths[$0] = checkedAt }
                saveRescannedPaths()
                print("🗑️ \(notYetRescanned.count) file(s) not indexed yet - scanning before removing")
                LibraryIndexer.shared.start()
                scheduleVerification(after: Self.busyRetryDelay)
                return
            }

            // A scan already ran and still could not index these. Any of
            // them could be the renamed copy, so for `unindexableHold` keep
            // the rows it could be the copy of rather than lose their
            // favourites and playlist entries. Past that the file is taken
            // to be one that will never be indexed (unplayable, failed
            // parse) and no longer keeps deleted songs in the library.
            let held = unindexed.filter { path, _ in
                rescannedForPaths[path].map { checkedAt.timeIntervalSince($0) < Self.unindexableHold } ?? false
            }
            if !held.isEmpty {
                let blockedSizes = Set(held.values.filter { $0 != Self.unknownSize })
                // A file of unknown size used to block every removal. Only
                // rows it plausibly is the renamed or moved copy of - same
                // file name, or same folder - are kept for it now.
                let unknown = held.filter { $0.value == Self.unknownSize }.map { URL(fileURLWithPath: $0.key) }
                let unknownNames = Set(unknown.map(\.lastPathComponent))
                let unknownFolders = Set(unknown.map { $0.deletingLastPathComponent().path })
                let kept = removing.filter { track in
                    if let size = track.fileSize, blockedSizes.contains(size) { return true }
                    let url = URL(fileURLWithPath: DatabaseManager.canonicalPath(track.path))
                    return unknownNames.contains(url.lastPathComponent)
                        || unknownFolders.contains(url.deletingLastPathComponent().path)
                }
                if !kept.isEmpty {
                    print("🗑️ 🛡️ Keeping \(kept.count) track(s) that may have been renamed to a file that cannot be indexed yet")
                    let keptIds = Set(kept.map(\.stableId))
                    kept.forEach { candidates[DatabaseManager.canonicalPath($0.path)] = nil }
                    localMissing.removeAll { keptIds.contains($0.stableId) }
                    iCloudMissing.removeAll { keptIds.contains($0.stableId) }
                }
            }
        }

        for track in localMissing + iCloudMissing {
            candidates[DatabaseManager.canonicalPath(track.path)] = nil
        }
        if !localMissing.isEmpty, let documentsURL {
            await FileCleanupManager.shared.removeVerifiedMissingTracks(localMissing, within: [documentsURL])
        }
        if !iCloudMissing.isEmpty, let iCloudRoot {
            // This pass awaited several times. Signed out, a different
            // account, iCloud turned off or the query restarted meanwhile:
            // what it saw is no evidence about the container now. Look again.
            guard isICloudUsable,
                  iCloudGeneration == startGeneration,
                  let startQuery, query === startQuery, hasGathered, !startQuery.isGathering else {
                // The new query's gathering schedules a sweep, which finds
                // these again if they are still missing.
                print("🗑️ iCloud changed during verification - not removing anything it saw")
                return
            }
            await FileCleanupManager.shared.removeVerifiedMissingTracks(iCloudMissing, within: [iCloudRoot])
        }
    }

    /// The per-candidate checks of `verify`, off the main actor. iCloud rows
    /// that pass still need iCloud's listing, which only main can read.
    nonisolated private static func assess(
        _ paths: [String],
        documentsURL: URL?,
        iCloudRoot: URL?,
        iCloudReady: Bool
    ) -> Assessment {
        let databaseManager = DatabaseManager.shared
        let fileManager = FileManager.default
        let documentsPath = documentsURL.map { DatabaseManager.canonicalPath($0.path) }
        let iCloudRootPath = iCloudRoot.map { DatabaseManager.canonicalPath($0.path) }
        func isInside(_ path: String, _ root: String?) -> Bool {
            guard let root else { return false }
            return path == root || path.hasPrefix(root + "/")
        }

        var result = Assessment()
        var iCloudRootReadable: Bool?
        for path in paths {
            if fileManager.fileExists(atPath: path) {
                result.dropped.append(path)
                result.reappeared = true
                continue
            }
            guard let track = try? databaseManager.getTrack(byPath: path) else {
                result.dropped.append(path) // already gone
                continue
            }

            if isInside(path, documentsPath), let documentsURL {
                if databaseManager.isPathConfirmedMissing(path, within: [documentsURL]) {
                    result.localMissing.append(track)
                } else {
                    result.dropped.append(path)
                }
            } else if path.contains("/Mobile Documents/") || isInside(path, iCloudRootPath) {
                // Not this app's music folder - another app's folder in
                // iCloud Drive, a linked folder (its own recheck in
                // FileCleanupManager judges it) or an old container: not this
                // monitor's to judge. Tested before the readiness guard below:
                // skipped there, these stayed candidates and were looked at
                // again on every pass, for ever. Without the root (signed
                // out) only linked-folder rows can be told apart.
                if let iCloudRootPath, !isInside(path, iCloudRootPath) {
                    result.dropped.append(path)
                    continue
                }
                if iCloudRootPath == nil, LinkedFolderStore.shared.folder(containing: path) != nil {
                    result.dropped.append(path)
                    continue
                }
                // Signed out, unavailable, query not ready: say nothing yet.
                guard let iCloudRoot, iCloudReady else { continue }
                if iCloudRootReadable == nil {
                    iCloudRootReadable = isReadableDirectory(iCloudRoot)
                }
                guard iCloudRootReadable == true else { continue }
                guard databaseManager.isPathConfirmedMissing(path, within: [iCloudRoot]) else {
                    result.dropped.append(path)
                    continue
                }
                result.iCloudMissing.append(track)
            } else {
                // External/bookmarked or old-container rows: handled by the
                // orphan check, which knows about bookmarks and relocation.
                result.dropped.append(path)
            }
        }
        return result
    }

    private static func loadRescannedPaths() -> [String: Date] {
        UserDefaults.standard.dictionary(forKey: rescannedPathsKey) as? [String: Date] ?? [:]
    }

    private func saveRescannedPaths() {
        if rescannedForPaths.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.rescannedPathsKey)
        } else {
            UserDefaults.standard.set(rescannedForPaths, forKey: Self.rescannedPathsKey)
        }
    }

    private func pruneRescannedPaths(now: Date) {
        let before = rescannedForPaths.count
        rescannedForPaths = rescannedForPaths.filter { now.timeIntervalSince($0.value) < Self.rescanTTL }
        if rescannedForPaths.count != before { saveRescannedPaths() }
    }

    nonisolated private static let unknownSize: Int64 = -1

    /// Audio files that have no library row and could be the renamed copy of
    /// a row being removed, keyed by canonical path, valued by size
    /// (`unknownSize` when it could not be read). Sources: iCloud live
    /// additions (any size), files iCloud's metadata lists with a matching
    /// size (downloaded or not), and - for local removals - the Documents
    /// folder walked for a matching size.
    nonisolated private static func unindexedFiles(
        added: Set<String>,
        listed: [String: Int64],
        localRoot: URL?,
        sizes: Set<Int64>
    ) -> [String: Int64] {
        var found: [String: Int64] = [:]
        let fileManager = FileManager.default
        for path in added where fileManager.fileExists(atPath: path) {
            let attributes = try? fileManager.attributesOfItem(atPath: path)
            found[path] = (attributes?[.size] as? NSNumber)?.int64Value ?? unknownSize
        }
        for (path, size) in listed { found[path] = size }

        if let localRoot, !sizes.isEmpty,
           let enumerator = fileManager.enumerator(
               at: localRoot,
               includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
               options: [.skipsHiddenFiles]
           ) {
            let extensions = Set(audioPatterns.map { String($0.dropFirst(2)) })
            for case let url as URL in enumerator {
                guard extensions.contains(url.pathExtension.lowercased()),
                      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true,
                      let size = values.fileSize.map(Int64.init),
                      sizes.contains(size) else { continue }
                found[DatabaseManager.canonicalPath(url.path)] = size
            }
        }
        guard !found.isEmpty else { return found }
        // Indexed files first: one set lookup each. `listed` can be most of
        // iCloud's listing, and the exclusion check below decodes the whole
        // exclusion list on every call (DeleteSettings has no bulk read), so
        // it now only runs for the few files that really have no row.
        if let indexed = try? DatabaseManager.shared.read({ db in
            try String.fetchAll(db, sql: "SELECT path FROM track")
        }) {
            let indexedPaths = Set(indexed.map(DatabaseManager.canonicalPath))
            found = found.filter { !indexedPaths.contains($0.key) }
        }
        // A copy the user removed from the library is skipped by every scan
        // (LibraryIndexer.isStillExcluded): waiting for it to be indexed held
        // the row, and forced a scan, for ever.
        return found.filter {
            !DeleteSettings.isTrackExcluded(DatabaseManager.generatePathStableId(forPath: $0.key))
        }
    }

    nonisolated private static func isReadableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && FileManager.default.isReadableFile(atPath: url.path)
    }

    /// Every file in `rootPath` iCloud's metadata currently lists, downloaded
    /// or not, with its size (`unknownSize` if iCloud does not report one).
    /// Only the music folder's: this count is what the "lists far fewer files
    /// than the library has" rule compares, and anything else in the scope
    /// would pass for files the library still has.
    private static func presentFiles(in query: NSMetadataQuery, under rootPath: String) -> [String: Int64] {
        query.disableUpdates()
        defer { query.enableUpdates() }
        var files = [String: Int64](minimumCapacity: query.resultCount)
        for index in 0..<query.resultCount {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = canonicalPath(of: item, under: rootPath) else { continue }
            files[path] = (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value ?? unknownSize
        }
        return files
    }
}
