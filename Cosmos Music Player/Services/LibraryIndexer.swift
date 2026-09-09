//
//  LibraryIndexer.swift
//  Cosmos Music Player
//
//  Indexes audio files (FLAC, MP3, WAV, AAC, Opus, Vorbis, DSD) in iCloud Drive using NSMetadataQuery
//

import Foundation
import CryptoKit
import AVFoundation
import GRDB
import SFBAudioEngine

/// Resume gate for a race: whichever racer finishes first wins and the others
/// are dropped, so the winner never waits on the loser.
private final class OneShotResume<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var value: T?

    func attach(_ continuation: CheckedContinuation<T, Never>) {
        lock.lock()
        if let value {
            lock.unlock()
            continuation.resume(returning: value)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ value: T) {
        lock.lock()
        guard self.value == nil else {
            lock.unlock()
            return
        }
        self.value = value
        let waiting = continuation
        self.continuation = nil
        lock.unlock()
        waiting?.resume(returning: value)
    }
}

/// What a `withHardTimeout` race produced. The error travels through the gate
/// inside this box because `any Error` is not Sendable: it is handed from the
/// one racer that produced it to the single waiter and never shared.
private enum HardTimeoutOutcome<T: Sendable>: @unchecked Sendable {
    case success(T)
    case failure(any Error)
}

/// Runs `operation` under a deadline and RETURNS at that deadline even when the
/// operation is wedged. A throwing task group cannot do this: it awaits its
/// children before unwinding, and cancellation is cooperative, while several
/// parsers block inside a non-cancellable NSFileCoordinator read. So one
/// genuinely stuck file used to freeze the whole scan no matter what the
/// timeout said. The loser is cancelled and then abandoned to finish on its own.
private func withHardTimeout<T: Sendable, E: Error & Sendable>(
    nanoseconds: UInt64,
    timeoutError: E,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let gate = OneShotResume<HardTimeoutOutcome<T>>()

    let work = Task.detached(priority: .utility) {
        do {
            let value = try await operation()
            gate.finish(.success(value))
        } catch {
            gate.finish(.failure(error))
        }
    }

    let timer = Task.detached(priority: .utility) {
        try? await Task.sleep(nanoseconds: nanoseconds)
        guard !Task.isCancelled else { return }
        gate.finish(.failure(timeoutError))
        work.cancel()
    }
    defer { timer.cancel() }

    let outcome = await withTaskCancellationHandler {
        await withCheckedContinuation { gate.attach($0) }
    } onCancel: {
        work.cancel()
        timer.cancel()
        gate.finish(.failure(CancellationError()))
    }

    switch outcome {
    case .success(let value):
        return value
    case .failure(let error):
        throw error
    }
}

enum LibraryIndexerError: Error {
    case parseTimeout
    case metadataParsingFailed
    /// FileManager could not enumerate a directory. Distinct from "the
    /// directory is empty": callers must not reconcile deletions against a
    /// root they were never able to read.
    case directoryNotEnumerable(URL)
}

private struct ParsedAudioFile {
    let track: Track
    let trackArtistIds: [Int64]
    let albumArtistIds: [Int64]
}

private struct FileFingerprint {
    let modificationDate: Int64?
    let fileSize: Int64?
}

/// The readable portion of a filesystem walk and whether it is safe to infer
/// deletions from that walk. A partial result is still useful for importing new
/// files, but must never be used for reconciliation or folder-playlist sync.
private struct MusicFileEnumeration {
    let files: [URL]
    let isComplete: Bool
}

/// Files that failed to index, and what they looked like when they failed.
///
/// A per-file failure withholds `lastLibraryScanDate` and marks the scan
/// non-authoritative. That is right for a *transient* failure - an I/O error, a
/// file being written while it was read - but wrong for a file that is simply
/// broken: one permanently unparseable track otherwise meant a full rescan on
/// every launch and every foreground for ever, and deferred post-index
/// maintenance (bookmark orphan checks, relationship verification, cache
/// pruning) that never ran again.
///
/// So a failure only counts against the scan the first time, and again whenever
/// the file changes. A matching path + fingerprint means "the same failure you
/// already knew about", which is not new information about the library.
@MainActor
private enum ScanFailureLog {
    private static let defaultsKey = "LibraryScanFileFailures"

    struct Record: Codable, Equatable {
        var modificationDate: Int64?
        var fileSize: Int64?
    }

    private static func load() -> [String: Record] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: Record].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func save(_ records: [String: Record]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    /// Records a failure.
    /// - Returns: whether this failure is new information about the library,
    ///   i.e. whether the caller should treat the scan as unsuccessful.
    static func noteFailure(at path: String, fingerprint: FileFingerprint) -> Bool {
        let key = DatabaseManager.standardizedPath(path)
        let record = Record(
            modificationDate: fingerprint.modificationDate,
            fileSize: fingerprint.fileSize
        )

        var records = load()
        // An unreadable file gives no fingerprint at all. Two nil-fingerprint
        // failures are not provably the same failure, so those always count.
        if record.modificationDate != nil || record.fileSize != nil,
           records[key] == record {
            return false
        }

        records[key] = record
        save(records)
        return true
    }

    /// Forgets a file that indexed successfully, so a genuinely new failure
    /// later still counts.
    static func clearFailure(at path: String) {
        let key = DatabaseManager.standardizedPath(path)
        var records = load()
        guard records.removeValue(forKey: key) != nil else { return }
        save(records)
    }

    /// Drops records for files that are no longer on disk. Called at the start
    /// of every scan, alongside the exclusion prune.
    static func pruneMissingFiles() {
        let records = load()
        guard !records.isEmpty else { return }

        let surviving = records.filter { path, _ in
            FileManager.default.fileExists(atPath: path)
        }
        guard surviving.count != records.count else { return }
        save(surviving)
        print("🧹 Cleared \(records.count - surviving.count) stale scan-failure record(s)")
    }
}

/// `ScanFailureLog`, for whole roots rather than individual files.
///
/// A root that cannot be enumerated has to withhold `lastLibraryScanDate`
/// once, so the scan is retried instead of the cooldown suppressing it with
/// part of the library missing. But it must not withhold it *for ever*: a
/// permanently unreadable root then means the date is never written at all,
/// and `shouldPerformAutoScan` treats a nil date as "never scanned" and runs
/// a full scan on every launch and every foreground - overriding even the
/// user's "manual only" setting, which is the one case where that is most
/// obviously wrong.
///
/// So the first failure counts and a repeat of the same failure does not,
/// exactly as `ScanFailureLog` does for a file that is simply broken. There
/// is no fingerprint to compare here - a directory's modification date
/// changes whenever its contents do, which says nothing about whether it can
/// be read - so "did this same root fail last time" is the whole test.
private enum ScanRootFailureLog {
    private static let defaultsKey = "LibraryScanRootFailures"

    private static func load() -> Set<String> {
        guard let stored = UserDefaults.standard.array(forKey: defaultsKey) as? [String] else {
            return []
        }
        return Set(stored)
    }

    private static func save(_ roots: Set<String>) {
        if roots.isEmpty {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else {
            UserDefaults.standard.set(Array(roots), forKey: defaultsKey)
        }
    }

    /// Records that a root could not be enumerated.
    /// - Returns: whether this is new information about the library, i.e.
    ///   whether the caller should treat the scan as unsuccessful.
    static func noteFailure(at path: String) -> Bool {
        let key = DatabaseManager.standardizedPath(path)
        var roots = load()
        guard roots.insert(key).inserted else { return false }
        save(roots)
        return true
    }

    /// Forgets a root that enumerated cleanly, so a genuinely new failure
    /// later still counts.
    static func clearFailure(at path: String) {
        let key = DatabaseManager.standardizedPath(path)
        var roots = load()
        guard roots.remove(key) != nil else { return }
        save(roots)
    }
}

private enum ExternalFileProcessingResult {
    case inserted
    case alreadyPresent
    case failed

    var succeeded: Bool {
        switch self {
        case .inserted, .alreadyPresent:
            return true
        case .failed:
            return false
        }
    }
}

/// The external-bookmark plist is shared by scans, playback, and cleanup.
/// Keeping its cached state behind one actor prevents main-thread whole-file
/// reads and turns every mutation into a serialized atomic read-modify-write.
actor ExternalBookmarkStore {
    static let shared = ExternalBookmarkStore()

    struct Resolution: Sendable {
        let url: URL
        /// The newest bookmark data that was successfully persisted. Callers
        /// use this when a moved file also requires its stable-ID key to move.
        let bookmarkData: Data
        let wasStale: Bool
        let wasRefreshed: Bool
    }

    private let fileURL: URL
    private var cachedBookmarks: [String: Data]?

    private init() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        fileURL = documentsURL.appendingPathComponent("ExternalFileBookmarks.plist")
    }

    func allBookmarks() throws -> [String: Data] {
        try loadBookmarksIfNeeded()
    }

    func bookmarkData(for stableID: String) throws -> Data? {
        try loadBookmarksIfNeeded()[stableID]
    }

    /// Resolves a stored bookmark and repairs stale data without throwing away
    /// the usable URL returned by Foundation.
    ///
    /// URL bookmark resolution can succeed while setting `isStale`. The URL is
    /// still the authority needed for this access; stale means only that fresh
    /// bookmark bytes should be persisted for the next launch. Refresh failure
    /// therefore leaves the old bookmark intact and returns the resolved URL so
    /// the current scan/playback attempt can still call
    /// `startAccessingSecurityScopedResource()`.
    func resolveAndRefreshBookmark(for stableID: String) throws -> Resolution? {
        var bookmarks = try loadBookmarksIfNeeded()
        guard let bookmarkData = bookmarks[stableID] else { return nil }

        var isStale = false
        let resolvedURL = try URL(
            resolvingBookmarkData: bookmarkData,
            options: .withoutUI,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        guard isStale else {
            return Resolution(
                url: resolvedURL,
                bookmarkData: bookmarkData,
                wasStale: false,
                wasRefreshed: false
            )
        }

        do {
            let refreshedBookmarkData = try resolvedURL.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            bookmarks[stableID] = refreshedBookmarkData
            try persist(bookmarks)
            return Resolution(
                url: resolvedURL,
                bookmarkData: refreshedBookmarkData,
                wasStale: true,
                wasRefreshed: true
            )
        } catch {
            // Resolution itself succeeded. Do not turn a refresh/persistence
            // problem into a sandbox-denied raw-path fallback for this access.
            print("⚠️ Could not persist refreshed external bookmark for \(resolvedURL.lastPathComponent): \(error)")
            return Resolution(
                url: resolvedURL,
                bookmarkData: bookmarkData,
                wasStale: true,
                wasRefreshed: false
            )
        }
    }

    func store(_ bookmarkData: Data, for stableID: String) throws {
        var bookmarks = try loadBookmarksIfNeeded()
        bookmarks[stableID] = bookmarkData
        try persist(bookmarks)
    }

    func migrate(
        from oldStableID: String,
        to newStableID: String,
        fallbackData: Data
    ) throws {
        guard oldStableID != newStableID else { return }

        var bookmarks = try loadBookmarksIfNeeded()
        let bookmarkData = bookmarks.removeValue(forKey: oldStableID) ?? fallbackData
        bookmarks[newStableID] = bookmarkData
        try persist(bookmarks)
    }

    @discardableResult
    func migrate(_ stableIDRemapping: [String: String]) throws -> Int {
        var bookmarks = try loadBookmarksIfNeeded()
        var updatedCount = 0

        for (oldStableID, newStableID) in stableIDRemapping {
            guard oldStableID != newStableID,
                  let bookmarkData = bookmarks.removeValue(forKey: oldStableID) else {
                continue
            }
            bookmarks[newStableID] = bookmarkData
            updatedCount += 1
        }

        if updatedCount > 0 {
            try persist(bookmarks)
        }
        return updatedCount
    }

    @discardableResult
    func removeBookmark(for stableID: String) throws -> Bool {
        var bookmarks = try loadBookmarksIfNeeded()
        guard bookmarks.removeValue(forKey: stableID) != nil else { return false }
        try persist(bookmarks)
        return true
    }

    private func loadBookmarksIfNeeded() throws -> [String: Data] {
        if let cachedBookmarks {
            return cachedBookmarks
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cachedBookmarks = [:]
            return [:]
        }

        let data = try Data(contentsOf: fileURL)
        guard let bookmarks = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Data] else {
            throw NSError(
                domain: "ExternalBookmarkStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid external bookmarks format"]
            )
        }

        cachedBookmarks = bookmarks
        return bookmarks
    }

    private func persist(_ bookmarks: [String: Data]) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: bookmarks,
            format: .xml,
            options: 0
        )
        try data.write(to: fileURL, options: .atomic)
        cachedBookmarks = bookmarks
    }
}

@MainActor
class LibraryIndexer: NSObject, ObservableObject {
    private enum ScanMode {
        case metadataQuery
        case offline
    }

    static let shared = LibraryIndexer()

    @Published var isIndexing = false
    @Published var indexingProgress: Double = 0.0
    @Published var tracksFound = 0
    @Published var currentlyProcessing: String = ""
    @Published var queuedFiles: [String] = []
    /// Emits only after a real scan has finished all database and folder-
    /// playlist work. `nil` avoids replaying a fake completion on subscription.
    @Published private(set) var completedScanGeneration: Int?
    /// Whether the generation most recently published above reached a clean,
    /// authoritative completion. AppCoordinator still runs state restoration
    /// after a partial/failed scan, but must not infer deletions from it.
    private(set) var lastCompletedScanWasAuthoritative = false
    private var hasPendingLibraryRefresh = false
    /// Serializes processQueryResults; see the comment there.
    private var isProcessingQueryResults = false
    private var hasPendingQueryResults = false
    /// The explicit scan generation whose DidFinishGathering event arrived
    /// while another query snapshot was being processed. Keeping the owner,
    /// rather than a Bool, prevents a live update that predates a manual scan
    /// from swallowing that scan's only completion event.
    private var pendingQueryCompletionGeneration: Int?
    /// What this scan's on-device sweep actually achieved, or nil while it has
    /// not run yet. The sweep runs once per scan, not once per query update -
    /// NSMetadataQuery fires those constantly while files are landing.
    ///
    /// The *outcome* is cached, not merely the fact that an attempt was made.
    /// A plain "has swept" flag was raised before the enumeration and left
    /// raised when it failed, so a repeat call answered "this root was scanned
    /// successfully" for a root that had never been read - which is the answer
    /// that authorises `reconcileMissingFiles` to delete every row under it.
    private var localDocumentsSweepSucceeded: Bool?
    /// Set when any file failed to download or parse during the active scan.
    private var scanHadFileFailures = false
    /// Set when a file was skipped only because its iCloud bytes had not landed
    /// yet. Deliberately NOT a scan failure: on a library that is larger than
    /// the device, or under iCloud's optimised storage, some files are
    /// permanently evicted, so treating this as a failure meant
    /// `lastLibraryScanDate` was never stamped and the app performed a full
    /// rescan on every launch and every foreground - defeating
    /// `libraryScanInterval` entirely. The live metadata query keeps indexing
    /// these as their bytes arrive, so a rescan is not what recovers them.
    private var scanHadPendingDownloads = false
    /// At least one filesystem root could only be enumerated partially. This is
    /// deliberately separate from the deduplicated failure log: a root that is
    /// repeatedly unavailable may eventually stop suppressing the scan date,
    /// but it is never authoritative enough for destructive maintenance.
    private var scanHadIncompleteRoots = false
    /// Set when a database write was cut short because GRDB was suspended
    /// (see `DatabaseSuspensionCoordinator`). Like a file failure it withholds
    /// `lastLibraryScanDate` so the scan is retried, but it is tracked
    /// separately because it says nothing about the file that happened to be
    /// in flight - blaming the file made the logs actively misleading.
    private var scanWasInterrupted = false
    /// Every supported file the active scan saw, so the metadata-query path can
    /// build folder playlists too - previously only the direct and offline
    /// scans did, so users whose query worked never got the feature at all.
    private var scanCollectedFiles: [URL] = []
    /// Identifies the generation currently using the direct scanner. Keeping
    /// the owner, rather than a Bool, prevents an old defer from clearing a new
    /// run's guard.
    private var directScanGeneration: Int?
    /// Prevents the timeout fallback and a non-empty metadata-query pass from
    /// indexing the same iCloud snapshot concurrently.
    private var queryResultScanGeneration: Int?
    /// `NSMetadataQueryDidFinishGathering` is not guaranteed to arrive. The
    /// short zero-result check below detects a query that never got started,
    /// but a healthy large query normally has partial results by then. Give
    /// gathering its own deadline so a positive, perpetually-gathering query
    /// cannot leave the scan generation (and all post-scan work) wedged.
    private var metadataGatheringDeadlineTask: Task<Void, Never>?
    private var metadataGatheringDeadlineGeneration: Int?
    /// Asks a partial `DidUpdate` snapshot to yield before the deadline starts
    /// the direct scan. This keeps both paths from parsing and writing the same
    /// generation concurrently.
    private var metadataGatheringTimedOutGeneration: Int?
    private static let metadataGatheringDeadlineNanoseconds: UInt64 = 30_000_000_000
    private var indexingGeneration = 0
    private var activeScanMode: ScanMode?
    /// The mode of a scan `stop()` abandoned while it was still running.
    /// See `resumeInterruptedScan()`.
    private var interruptedScanMode: ScanMode?
    private var activeScanTask: Task<Void, Never>?
    private var sharedContainerProcessingTask: Task<Void, Never>?
    private var sharedContainerProcessingGeneration: UInt64 = 0

    private let metadataQuery = NSMetadataQuery()
    private let databaseManager = DatabaseManager.shared
    private let stateManager = StateManager.shared
    
    override init() {
        super.init()
        setupMetadataQuery()
    }
    
    private func setupMetadataQuery() {
        metadataQuery.delegate = self

        // The search scope is NOT resolved here. This runs from init(), which
        // happens on the main actor while the app launches, and asking
        // StateManager for the music folder forces the ubiquity container to
        // resolve - a call Apple documents as unsafe for the main thread.
        // start() narrows the scope later, off the main actor.
        metadataQuery.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]

        // Support all audio formats according to plan
        let formats = ["*.flac", "*.mp3", "*.wav", "*.m4a", "*.aac", "*.opus", "*.ogg", "*.oga", "*.dsf", "*.dff"]
        let formatPredicates = formats.map { format in
            // LIKE[c]: without the [c] modifier the match is case-sensitive,
            // so TRACK.FLAC or Song.MP3 were invisible to the query. And
            // because the direct-scan fallback only triggers on a zero-result
            // query, a single lowercase file was enough to hide them for good.
            NSPredicate(format: "%K LIKE[c] %@", NSMetadataItemFSNameKey, format)
        }
        metadataQuery.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: formatPredicates)
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidGatherInitialResults),
            name: NSNotification.Name.NSMetadataQueryDidFinishGathering,
            object: metadataQuery
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidUpdate),
            name: NSNotification.Name.NSMetadataQueryDidUpdate,
            object: metadataQuery
        )
    }
    
    func start() {
        guard !isIndexing else { return }

        // Attempt recovery from offline mode when manually syncing
        CloudDownloadManager.shared.attemptRecovery()

        activeScanTask?.cancel()
        resetMetadataGatheringDeadline()
        indexingGeneration &+= 1
        let generation = indexingGeneration
        activeScanMode = .metadataQuery
        interruptedScanMode = nil
        isIndexing = true
        indexingProgress = 0.0
        tracksFound = 0

        ScanFailureLog.pruneMissingFiles()
        localDocumentsSweepSucceeded = nil
        scanHadFileFailures = false
        scanHadPendingDownloads = false
        scanHadIncompleteRoots = false
        scanWasInterrupted = false
        scanCollectedFiles.removeAll()

        // Copy any new files from share extension first
        Task {
            await copyFilesFromSharedContainer()
        }
        
        activeScanTask = Task { [weak self] in
            guard let self else { return }
            await self.purgeUnplayableOpusInM4AIfNeeded()
            guard self.isActiveScan(generation) else { return }
            // Resolve the container off the main actor, then start the query
            // back on it - NSMetadataQuery needs a run loop. Both the resolve
            // and the diagnostic directory listing used to run inline here, on
            // the main thread, during launch.
            let musicFolderURL = await resolveMusicFolderURL()

            // stop() or switchToOfflineMode() may have run while the container
            // was resolving. Without this the query would be started again just
            // after being stopped, leaving an iCloud query alive in offline
            // mode and racing the local scan.
            guard isActiveScan(generation, mode: .metadataQuery) else {
                print("🛑 Metadata query start cancelled - indexing was stopped")
                return
            }

            // A finished scan deliberately leaves the query running - that is
            // how files added to iCloud between scans still get indexed. But
            // start() is a no-op on an already-running query, so a second
            // manual scan never got its own DidFinishGathering: completeScan
            // was never reached, isIndexing stayed true, and every caller
            // waiting on it (ContentView's manual sync and pull-to-refresh)
            // spun for ever. Restart so this generation is guaranteed a
            // gather, and its completion event, of its own.
            metadataQuery.stop()
            if let musicFolderURL {
                metadataQuery.searchScopes = [musicFolderURL]
            }
            guard metadataQuery.start() else {
                print("❌ NSMetadataQuery refused to start - falling back to direct scan")
                await fallbackToDirectScan(generation: generation)
                return
            }

            armMetadataGatheringDeadline(for: generation)

            // A separate short check handles the clearly broken zero-result
            // case. Do not generalise this to a positive result count: seeing
            // partial results after three seconds is normal for a large
            // container, and only the gathering deadline above should decide
            // that DidFinishGathering has taken too long.
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            } catch {
                return
            }
            print("Timeout check: resultCount=\(metadataQuery.resultCount), isIndexing=\(isIndexing)")
            // The generation check matters as much as isIndexing here: a switch
            // to offline mode sets isIndexing back to true for its own scan, and
            // without this the fallback would run alongside it.
            guard isActiveScan(generation, mode: .metadataQuery) else { return }
            if metadataQuery.resultCount == 0 {
                print("NSMetadataQuery timeout - triggering fallback scan")
                await fallbackToDirectScan(generation: generation)
            }
        }
    }

    /// Reads the music folder URL away from the main actor, since the first
    /// call forces the ubiquity container to resolve.
    nonisolated private func resolveMusicFolderURL() async -> URL? {
        stateManager.getMusicFolderURL()
    }
    
    func startOfflineMode() {
        guard !isIndexing else { return }

        activeScanTask?.cancel()
        resetMetadataGatheringDeadline()
        indexingGeneration &+= 1
        let generation = indexingGeneration
        activeScanMode = .offline
        interruptedScanMode = nil
        isIndexing = true
        indexingProgress = 0.0
        tracksFound = 0

        ScanFailureLog.pruneMissingFiles()
        localDocumentsSweepSucceeded = nil
        scanHadFileFailures = false
        scanHadPendingDownloads = false
        scanHadIncompleteRoots = false
        scanWasInterrupted = false
        scanCollectedFiles.removeAll()

        activeScanTask = Task { [weak self] in
            await self?.purgeUnplayableOpusInM4AIfNeeded()
            await self?.scanLocalDocuments(generation: generation)
        }
    }

    /// Abandons the running scan.
    ///
    /// The abandoned mode is remembered so `resumeInterruptedScan()` can pick
    /// it up again. That matters because a stopped scan reports nothing:
    /// `AppCoordinator` hangs favourites sync and iCloud playlist restoration
    /// off `completedScanGeneration`, which only `completeScan`/`failScan`
    /// publish. Publishing from here instead would be worse - the one caller
    /// is `DatabaseSuspensionCoordinator`, which stops the scan precisely
    /// because it is about to suspend GRDB, so the post-index database work
    /// would run straight into the suspension it is avoiding.
    func stop() {
        if isIndexing {
            interruptedScanMode = activeScanMode
        }

        activeScanTask?.cancel()
        activeScanTask = nil
        resetMetadataGatheringDeadline()
        indexingGeneration &+= 1
        activeScanMode = nil
        directScanGeneration = nil
        queryResultScanGeneration = nil
        metadataQuery.stop()
        isIndexing = false
    }

    /// Starts the scan `stop()` abandoned, once whatever forced the stop has
    /// passed.
    ///
    /// The scan-interval setting is deliberately not consulted: this is not a
    /// scheduled scan, it is the remainder of one that was already running, and
    /// gating it on the cooldown left a manual sync (or any scan at all under
    /// "manual only") permanently unfinished after the user switched apps.
    func resumeInterruptedScan() {
        guard !isIndexing, let mode = interruptedScanMode else { return }
        interruptedScanMode = nil

        print("🔄 Resuming the library scan that was interrupted")
        switch mode {
        case .metadataQuery:
            start()
        case .offline:
            startOfflineMode()
        }
    }
    
    func switchToOfflineMode() {
        print("🔄 Switching LibraryIndexer to offline mode")
        stop()
        startOfflineMode()
    }

    private func isActiveScan(_ generation: Int, mode: ScanMode? = nil) -> Bool {
        guard isIndexing, indexingGeneration == generation else { return false }
        return mode == nil || activeScanMode == mode
    }

    private func armMetadataGatheringDeadline(for generation: Int) {
        resetMetadataGatheringDeadline()
        metadataGatheringDeadlineGeneration = generation
        metadataGatheringDeadlineTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.metadataGatheringDeadlineNanoseconds)
            } catch {
                return
            }

            guard let self,
                  self.metadataGatheringDeadlineGeneration == generation,
                  self.isActiveScan(generation, mode: .metadataQuery) else { return }

            // Clear the handle before entering fallback; fallback also resets
            // watchdog state and must not cancel the task that is running it.
            self.metadataGatheringDeadlineTask = nil
            self.metadataGatheringDeadlineGeneration = nil
            self.metadataGatheringTimedOutGeneration = generation
            print("⏰ NSMetadataQuery gathering deadline expired - falling back to direct scan")

            // A DidUpdate pass can already be walking a stable query snapshot.
            // Marking the generation above makes it yield at its next boundary;
            // wait for the serialized pass to unwind before direct enumeration
            // starts so the two writers never overlap.
            while self.isProcessingQueryResults {
                do {
                    try await Task.sleep(nanoseconds: 50_000_000)
                } catch {
                    return
                }
                guard self.isActiveScan(generation, mode: .metadataQuery) else { return }
            }

            guard self.metadataGatheringTimedOutGeneration == generation,
                  self.isActiveScan(generation, mode: .metadataQuery) else { return }
            await self.fallbackToDirectScan(generation: generation)
        }
    }

    private func cancelMetadataGatheringDeadline(for generation: Int) {
        guard metadataGatheringDeadlineGeneration == generation else { return }
        metadataGatheringDeadlineTask?.cancel()
        metadataGatheringDeadlineTask = nil
        metadataGatheringDeadlineGeneration = nil
    }

    private func resetMetadataGatheringDeadline(for generation: Int? = nil) {
        if let generation {
            cancelMetadataGatheringDeadline(for: generation)
            if metadataGatheringTimedOutGeneration == generation {
                metadataGatheringTimedOutGeneration = nil
            }
            return
        }

        metadataGatheringDeadlineTask?.cancel()
        metadataGatheringDeadlineTask = nil
        metadataGatheringDeadlineGeneration = nil
        metadataGatheringTimedOutGeneration = nil
    }

    /// Records that part of the library could not be read during the active
    /// scan, so the scan is not stamped successful and the automatic retry is
    /// not suppressed for the whole cooldown.
    ///
    /// Prefer `recordScanRootFailure(forRootAt:)` or
    /// `recordScanFileFailure(forFileAt:)`: both deduplicate, so neither a
    /// permanently broken track nor a permanently unreadable root can withhold
    /// the timestamp for ever. This unconditional form is the primitive they
    /// are built on.
    func recordScanFileFailure() {
        scanHadFileFailures = true
    }

    /// Records that a whole root could not be enumerated during this scan.
    ///
    /// Only counts against the scan when it is new information - the first
    /// failure for this root, or the first since it last enumerated cleanly.
    /// See `ScanRootFailureLog` for why a repeat must not count.
    func recordScanRootFailure(forRootAt url: URL) {
        scanHadIncompleteRoots = true
        guard ScanRootFailureLog.noteFailure(at: url.path) else {
            print("↩️ Same root failure as last scan for \(url.lastPathComponent) - not withholding the scan date")
            return
        }
        recordScanFileFailure()
    }

    /// Forgets a previous failure for a root that has now enumerated cleanly.
    func clearScanRootFailure(forRootAt url: URL) {
        ScanRootFailureLog.clearFailure(at: url.path)
    }

    /// Records that one file could not be indexed.
    ///
    /// Only counts against the scan when it is new information - the first
    /// failure for this file, or the first since the file changed. See
    /// `ScanFailureLog`: a file that is simply broken must not keep the library
    /// in permanent doubt.
    func recordScanFileFailure(forFileAt url: URL) async {
        let fingerprint = (try? fileFingerprint(for: url))
            ?? FileFingerprint(modificationDate: nil, fileSize: nil)

        guard ScanFailureLog.noteFailure(at: url.path, fingerprint: fingerprint) else {
            print("↩️ Same failure as last scan for \(url.lastPathComponent) - not withholding the scan date")
            return
        }
        recordScanFileFailure()
    }

    /// Forgets a previous failure for a file that has now indexed cleanly.
    func clearScanFileFailure(forFileAt url: URL) {
        ScanFailureLog.clearFailure(at: url.path)
    }

    /// Drops the database row for a file the parser now refuses.
    ///
    /// Skipping the file is not enough on its own: reconciliation only removes
    /// rows whose file is *gone*, so a track indexed by an older build - an
    /// Opus stream in an MP4 container, which has no decoder on this platform -
    /// stayed in the library for ever, listed as a normal song that silently
    /// did nothing when tapped.
    private func removeUnplayableTrackRow(at fileURL: URL) async {
        guard let stableId = try? generateStableId(for: fileURL),
              let existing = try? databaseManager.getTrack(byStableId: stableId) else {
            return
        }

        do {
            reportDiscardedUserData(for: existing)
            try await databaseManager.deleteTrack(byStableId: existing.stableId)
            print("🧹 Removed unplayable track from the library: \(existing.title)")
        } catch {
            print("⚠️ Could not remove unplayable track \(existing.title): \(error)")
        }
    }

    /// Says out loud what a removal is about to throw away.
    ///
    /// `deleteTrack` also deletes the row's favourite flag and every playlist
    /// entry pointing at it, and there is no undo. That is the right outcome
    /// for a track nothing on this platform can decode, but it must not happen
    /// silently: if the format check ever answers wrongly, this line is the
    /// only trace of what the user lost.
    private func reportDiscardedUserData(for track: Track) {
        let isFavorite = (try? databaseManager.isFavorite(trackStableId: track.stableId)) ?? false
        let playlistCount = (try? databaseManager.read { db in
            try PlaylistItem
                .filter(Column("track_stable_id") == track.stableId)
                .fetchCount(db)
        }) ?? 0

        guard isFavorite || playlistCount > 0 else { return }
        print("""
            ⚠️ Removing "\(track.title)" also discards \
            \(isFavorite ? "its favourite" : "")\
            \(isFavorite && playlistCount > 0 ? " and " : "")\
            \(playlistCount > 0 ? "\(playlistCount) playlist entr\(playlistCount == 1 ? "y" : "ies")" : "") \
            - path: \(track.path)
            """)
    }

    /// One-time sweep for rows that predate the format check above.
    ///
    /// Those files are unchanged on disk, so `needsMetadataRefresh` short
    /// circuits before anything reparses them and the skip path never runs.
    /// Only `.m4a` is examined - it is the one container whose extension does
    /// not determine the codec - and only once, because the check has to read
    /// the file's header to answer.
    private func purgeUnplayableOpusInM4AIfNeeded() async {
        let defaultsKey = "LibraryDidPurgeOpusInM4A"
        guard !UserDefaults.standard.bool(forKey: defaultsKey) else { return }

        guard let tracks = try? databaseManager.getAllTracks() else { return }
        let candidates = tracks.filter {
            URL(fileURLWithPath: $0.path).pathExtension.lowercased() == "m4a"
        }

        guard !candidates.isEmpty else {
            UserDefaults.standard.set(true, forKey: defaultsKey)
            return
        }

        // This runs before any indexing on the first launch after the upgrade,
        // and it opens and parses the header of every downloaded .m4a in the
        // library. Say so: `isIndexing` is already true, but nothing else sets
        // `currentlyProcessing`, so the scan UI sat blank for the whole sweep
        // and read as a hang.
        let previouslyProcessing = currentlyProcessing
        currentlyProcessing = Localized.checkingLibraryFormats
        defer { currentlyProcessing = previouslyProcessing }

        // The header checks are independent and I/O bound, so run a few at a
        // time rather than one detached task after another. Same cap as
        // indexFilesWithBoundedConcurrency, for the same reason.
        let maxConcurrentChecks = 4
        var opusTracks: [Track] = []
        var deferred = 0
        var examined = 0
        var nextIndex = 0

        // A file that is not there is reconciliation's business, not this
        // sweep's - and an iCloud placeholder must not be judged at all.
        // `isLocallyResident` rather than CloudDownloadManager.isDownloaded:
        // that one is @MainActor and logs per call, and this is off-actor work.
        // Returns nil for "could not examine".
        let inspect: @Sendable (Track) -> (Track, Bool?) = { track in
            let url = URL(fileURLWithPath: track.path)
            guard FileManager.default.fileExists(atPath: url.path),
                  CloudDownloadManager.isLocallyResident(url) else {
                return (track, nil)
            }
            return (track, AudioMetadataParser.isOpusInM4A(url))
        }

        await withTaskGroup(of: (Track, Bool?).self) { group in
            while nextIndex < min(maxConcurrentChecks, candidates.count) {
                let track = candidates[nextIndex]
                group.addTask { inspect(track) }
                nextIndex += 1
            }

            while let result = await group.next() {
                let (track, isOpus) = result
                examined += 1
                switch isOpus {
                case nil:
                    // Deliberately counted. These rows have not been examined,
                    // and once they materialise nothing will look at them
                    // again: the file is unchanged, so needsMetadataRefresh
                    // short circuits before any reparse and the ordinary skip
                    // path never runs. Latching the one-shot flag over them
                    // left permanently dead rows no later scan could clear.
                    deferred += 1
                case true?:
                    opusTracks.append(track)
                case false?:
                    break
                }

                if examined % 25 == 0 {
                    indexingProgress = Double(examined) / Double(candidates.count)
                }

                if nextIndex < candidates.count {
                    let next = candidates[nextIndex]
                    group.addTask { inspect(next) }
                    nextIndex += 1
                }
            }
        }

        // Deleting is serialized on purpose - it is a single GRDB writer, and
        // each removal also runs orphan cleanup.
        var removed = 0
        for track in opusTracks {
            do {
                reportDiscardedUserData(for: track)
                try await databaseManager.deleteTrack(byStableId: track.stableId)
                removed += 1
            } catch {
                print("⚠️ Could not remove Opus-in-M4A track \(track.title): \(error)")
                // Same reasoning: an unexamined row must not be written off.
                deferred += 1
            }
        }

        indexingProgress = 0.0

        if deferred == 0 {
            UserDefaults.standard.set(true, forKey: defaultsKey)
        } else {
            print("⏭️ Deferring the Opus-in-M4A sweep - \(deferred) candidate(s) could not be examined yet")
        }
        if removed > 0 {
            print("🧹 Removed \(removed) Opus-in-M4A track(s) that have no decoder on this platform")
        }
    }

    /// Records that a file was skipped only because its iCloud download has not
    /// landed yet. See `scanHadPendingDownloads`: this must not suppress the
    /// scan-success timestamp.
    func recordScanPendingDownload() {
        scanHadPendingDownloads = true
    }

    /// Records that the database was suspended part-way through this scan, so
    /// it is retried rather than stamped successful.
    func recordScanInterrupted() {
        scanWasInterrupted = true
    }

    private func completeScan(generation: Int, message: String) {
        guard isActiveScan(generation) else { return }

        resetMetadataGatheringDeadline(for: generation)

        if scanHadFileFailures {
            // Per-file parse errors are swallowed so one bad file cannot abort
            // a scan. Writing lastLibraryScanDate anyway meant a transient
            // failure left tracks missing AND suppressed the next automatic
            // retry for the full cooldown.
            print("⚠️ Scan finished with file-level failures - not recording a successful scan date")
        } else if scanWasInterrupted {
            // The database went away part-way through, so the library is
            // incomplete for reasons that have nothing to do with any file.
            // Same outcome as a failure - retry - but reported honestly.
            print("⏸️ Scan was interrupted by database suspension - not recording a successful scan date")
        } else {
            // Files still waiting on iCloud are explicitly NOT a reason to
            // withhold the timestamp - the live metadata query indexes them as
            // their bytes land, and withholding it rescanned the whole library
            // on every launch for anyone using optimised storage.
            if scanHadPendingDownloads {
                print("ℹ️ Scan finished with downloads still in flight - they will be indexed as they land")
            }
            var settings = DeleteSettings.load()
            settings.lastLibraryScanDate = Date()
            settings.save()
        }

        activeScanTask?.cancel()
        activeScanTask = nil
        activeScanMode = nil
        isIndexing = false
        // An interrupted scan saw only part of the library, so destructive
        // maintenance must not act on it either.
        lastCompletedScanWasAuthoritative = !scanHadFileFailures
            && !scanHadIncompleteRoots
            && !scanWasInterrupted
        completedScanGeneration = generation
        print(message)
    }

    private func failScan(generation: Int, message: String) {
        guard isActiveScan(generation) else { return }
        resetMetadataGatheringDeadline(for: generation)
        activeScanTask?.cancel()
        activeScanTask = nil
        activeScanMode = nil
        isIndexing = false
        // Still publish the generation. AppCoordinator hangs favourites sync
        // and iCloud playlist restoration off this, and those are about
        // reconciling state that already exists - a scan that failed part-way
        // is exactly when the library most needs them to run. Destructive
        // maintenance is separately gated by this outcome, and the scan-success
        // timestamp is deliberately not written so the scan itself retries.
        lastCompletedScanWasAuthoritative = false
        completedScanGeneration = generation
        print(message)
    }

    nonisolated private static func modificationTimestamp(_ date: Date?) -> Int64? {
        guard let date else { return nil }
        // Microseconds retain sub-second filesystem precision while remaining
        // stable when round-tripped through SQLite INTEGER.
        return Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
    }

    nonisolated private func fileFingerprint(for url: URL) throws -> FileFingerprint {
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return FileFingerprint(
            modificationDate: Self.modificationTimestamp(values.contentModificationDate),
            fileSize: values.fileSize.map(Int64.init)
        )
    }

    private func metadataFingerprint(for item: NSMetadataItem) -> FileFingerprint {
        let modificationDate = item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date
        let fileSize = (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value
        return FileFingerprint(
            modificationDate: Self.modificationTimestamp(modificationDate),
            fileSize: fileSize
        )
    }

    /// Whether a file the user removed from the library should still be
    /// skipped by a folder scan.
    ///
    /// A stable id is a hash of the path, so replacement detection needs a
    /// separate file identity. Absence and modification dates are deliberately
    /// insufficient: cloud paths disappear while providers are offline, and a
    /// tag edit changes the date without changing the user's exclusion intent.
    nonisolated private func isStillExcluded(stableId: String, url: URL) -> Bool {
        guard let details = DeleteSettings.excludedTrackDetails(stableId) else { return false }

        let currentModification = Self.modificationTimestamp(
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        )
        let currentIdentity = DeleteSettings.exclusionFileIdentity(atPath: url.path)

        guard let excludedPath = details.path, !excludedPath.isEmpty else {
            // Written before details were recorded: conservatively keep the
            // exclusion and adopt the identity now visible at the path.
            DeleteSettings.adoptExclusionDetails(stableId, path: url.path, modificationDate: currentModification)
            return true
        }

        if let excludedIdentity = details.fileIdentity,
           let currentIdentity,
           excludedIdentity != currentIdentity {
            // A mismatch on its own is NOT proof of a replacement. Two extra
            // conditions have to hold before the user's removal is undone,
            // because getting this wrong resurrects a track they deleted:
            //
            //  - Both identities must be durable. A `resource:` identity comes
            //    from fileResourceIdentifierKey, which Apple documents as not
            //    persistent across system restarts, so on the launch after a
            //    reboot an untouched file can present a brand-new one.
            //  - The modification date must have moved too. Writing a genuinely
            //    different file to the path changes both; a reissued identifier
            //    changes only the identity.
            let bothDurable = DeleteSettings.exclusionIdentityIsDurable(excludedIdentity)
                && DeleteSettings.exclusionIdentityIsDurable(currentIdentity)
            let modificationMoved = details.modificationDate != currentModification

            if bothDurable && modificationMoved {
                print("🔁 Excluded file was replaced, indexing again: \(url.lastPathComponent)")
                DeleteSettings.removeExcludedTrack(stableId)
                return false
            }

            // Not enough evidence. Adopt what is on disk now so the next scan
            // compares against the current reality rather than re-deciding this
            // every time, and keep the exclusion.
            print("↩️ Excluded file's identity changed without a content change - keeping the exclusion: \(url.lastPathComponent)")
            DeleteSettings.adoptExclusionDetails(
                stableId,
                path: excludedPath,
                modificationDate: currentModification ?? details.modificationDate
            )
            return true
        }

        // Entries created by the first details-based implementation have a
        // path/date but no resource identity. Adopt one without treating the
        // current file as a replacement; guessing here could resurrect a track
        // the user explicitly removed.
        if details.fileIdentity == nil, currentIdentity != nil {
            DeleteSettings.adoptExclusionDetails(
                stableId,
                path: excludedPath,
                modificationDate: currentModification ?? details.modificationDate
            )
        }

        return true
    }

    nonisolated private func needsMetadataRefresh(_ track: Track, fingerprint: FileFingerprint) -> Bool {
        // Rows written by the filename-only parser carry its signature: no
        // duration, no sample rate and no channel count. Every Opus/Vorbis
        // track looked like this until they were routed to a real tag reader,
        // so re-parse them once instead of leaving existing libraries stuck in
        // "Unknown Album" at 0:00. A file the tag reader genuinely cannot read
        // keeps these zeros and is retried on later scans, which costs one
        // parse per scan for that file alone.
        if trackLooksUnparsed(track), Self.filenameParsedExtensions.contains(URL(fileURLWithPath: track.path).pathExtension.lowercased()) {
            return true
        }

        // Existing users have NULL here after the additive migration. Refresh
        // once so their metadata and fingerprint are brought up to date.
        guard let storedModificationDate = track.modificationDate else {
            return true
        }

        if let currentModificationDate = fingerprint.modificationDate,
           currentModificationDate != storedModificationDate {
            return true
        }

        if let currentFileSize = fingerprint.fileSize,
           currentFileSize != track.fileSize {
            return true
        }

        return false
    }

    /// Extensions that were served by the filename-only parser and are now read
    /// with real tags. Restricted so a legitimately zero-valued row of another
    /// format is not re-parsed on every scan.
    ///
    /// dsf/dff are here for the same reason opus/ogg are: their rows were
    /// written with a zero duration, sample rate and channel count, and are
    /// now read with TagLib. Without this an existing library keeps its DSD
    /// tracks in "Unknown Album" at 0:00 for ever, because their files have
    /// not changed and nothing else would re-parse them.
    nonisolated static let filenameParsedExtensions: Set<String> = ["opus", "ogg", "oga", "m4a", "dsf", "dff"]

    nonisolated private func trackLooksUnparsed(_ track: Track) -> Bool {
        (track.durationMs ?? 0) == 0
            && (track.sampleRate ?? 0) == 0
            && (track.channels ?? 0) == 0
    }

    nonisolated private func existingTrack(stableId: String, path: String) throws -> Track? {
        if let existing = try databaseManager.getTrack(byStableId: stableId) {
            return existing
        }

        guard var existing = try databaseManager.getTrack(byPath: path) else {
            return nil
        }

        print("🔁 Track already exists by path with old stable ID: \(existing.stableId)")
        try databaseManager.migrateTrackStableIdAndPath(
            oldStableId: existing.stableId,
            newStableId: stableId,
            newPath: path
        )
        existing.stableId = stableId
        existing.path = path
        return existing
    }

    nonisolated private func saveParsedFile(
        _ parsedFile: ParsedAudioFile,
        replacing existingTrack: Track?,
        sourceDescription: String,
        notifyImmediately: Bool = false
    ) async throws {
        var track = parsedFile.track
        track.id = existingTrack?.id

        try databaseManager.upsertTrackWithArtistRelationships(
            track,
            trackArtistIds: parsedFile.trackArtistIds,
            albumArtistIds: parsedFile.albumArtistIds
        )

        if let existingTrack {
            // Once a row has a fingerprint, a changed timestamp means cached
            // artwork may also be stale. Legacy rows are all refreshed once;
            // avoid synchronously re-extracting artwork for an entire large
            // upgraded library when no prior fingerprint can prove it changed.
            if existingTrack.modificationDate != nil {
                _ = await ArtworkManager.shared.forceRefreshArtwork(for: track)
            }
            print("🔄 Refreshed metadata for \(sourceDescription): \(track.title)")
            if notifyImmediately {
                // A changed album/artist can leave the old relationship empty.
                try databaseManager.cleanupOrphanedLibraryEntries()
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("LibraryNeedsRefresh"),
                        object: nil
                    )
                }
            } else {
                // Large upgraded libraries can refresh thousands of legacy
                // rows. Coalesce those UI reloads into one scan-end event.
                await MainActor.run { self.hasPendingLibraryRefresh = true }
            }
        } else {
            // Artwork is deliberately NOT extracted here. Decoding and
            // re-encoding every embedded cover inline made each file wait on a
            // full-resolution JPEG round trip, which dominated first-run scan
            // time. ArtworkManager.getArtwork/getThumbnail already extract and
            // fill the disk cache lazily the first time a row is displayed.
            print("📢 Posting TrackFound notification for \(sourceDescription): \(track.title)")
            await MainActor.run {
                self.tracksFound += 1
                NotificationCenter.default.post(
                    name: NSNotification.Name("TrackFound"),
                    object: track
                )
            }
        }
    }

    private func postPendingLibraryRefresh() {
        guard hasPendingLibraryRefresh else { return }
        hasPendingLibraryRefresh = false
        do {
            // Run once for the whole scan instead of once per refreshed row.
            try databaseManager.cleanupOrphanedLibraryEntries()
        } catch {
            print("⚠️ Failed to clean orphaned metadata after refresh: \(error)")
        }
        NotificationCenter.default.post(
            name: NSNotification.Name("LibraryNeedsRefresh"),
            object: nil
        )
    }

    @discardableResult
    func processExternalFile(_ fileURL: URL, allowExcludedReimport: Bool = false) async -> Bool {
        let result = await processExternalFileResult(
            fileURL,
            allowExcludedReimport: allowExcludedReimport
        )
        if case .inserted = result { return true }
        return false
    }

    private func processExternalFileResult(
        _ fileURL: URL,
        allowExcludedReimport: Bool = false
    ) async -> ExternalFileProcessingResult {
        // Reject network URLs
        if let scheme = fileURL.scheme?.lowercased(), ["http", "https", "ftp", "sftp"].contains(scheme) {
            print("❌ Rejected network URL: \(fileURL.absoluteString)")
            return .failed
        }

        do {
            print("🎵 Starting to process external file: \(fileURL.lastPathComponent)")
            print("📱 Processing external file from: \(fileURL.path)")

            print("🆔 Generating stable ID for: \(fileURL.lastPathComponent)")
            let stableId = try generateStableId(for: fileURL)
            print("🆔 Generated stable ID: \(stableId)")

            let fingerprint = try fileFingerprint(for: fileURL)
            let existingTrack = try existingTrack(stableId: stableId, path: fileURL.path)

            if let existingTrack, !needsMetadataRefresh(existingTrack, fingerprint: fingerprint) {
                print("⏭️ Track metadata is current: \(fileURL.lastPathComponent)")
                print("📍 Existing DB path: \(existingTrack.path)")
                if allowExcludedReimport && DeleteSettings.isTrackExcluded(stableId) {
                    DeleteSettings.removeExcludedTrack(stableId)
                    print("✅ Cleared exclusion for already-present track: \(fileURL.lastPathComponent)")
                }
                if allowExcludedReimport {
                    NotificationCenter.default.post(name: NSNotification.Name("LibraryNeedsRefresh"), object: nil)
                }
                return .alreadyPresent
            }
            if existingTrack != nil {
                print("🔄 File changed; reparsing external metadata: \(fileURL.lastPathComponent)")
            }

            // Check if track was excluded (removed from library only)
            let isExcluded = DeleteSettings.isTrackExcluded(stableId)
            if isExcluded && !allowExcludedReimport {
                print("⏭️ Track excluded from library: \(fileURL.lastPathComponent)")
                return .alreadyPresent
            }
            if isExcluded && allowExcludedReimport {
                print("🔁 Re-importing excluded track by user request: \(fileURL.lastPathComponent)")
            }

            print("🎶 Parsing external audio file: \(fileURL.lastPathComponent)")
            let parsedFile = try await parseAudioFile(at: fileURL, stableId: stableId)
            print("✅ External audio file parsed successfully: \(parsedFile.track.title)")
            try await saveParsedFile(
                parsedFile,
                replacing: existingTrack,
                sourceDescription: "external file",
                notifyImmediately: true
            )

            // Remove only this track from exclusion after successful explicit re-import.
            if isExcluded && allowExcludedReimport {
                DeleteSettings.removeExcludedTrack(stableId)
                print("✅ Cleared exclusion for re-imported track: \(fileURL.lastPathComponent)")
            }

            return existingTrack == nil ? .inserted : .alreadyPresent

        } catch LibraryIndexerError.parseTimeout {
            print("⏰ Timeout parsing external audio file: \(fileURL.lastPathComponent)")
            print("❌ Skipping external file due to parsing timeout")
            return .failed
        } catch {
            print("❌ Failed to process external track at \(fileURL.lastPathComponent): \(error)")
            print("❌ Error type: \(type(of: error))")
            print("❌ Error details: \(String(describing: error))")
            return .failed
        }
    }
    
    @objc private func queryDidGatherInitialResults() {
        print("🔍 NSMetadataQuery gathered initial results: \(metadataQuery.resultCount) items")
        for i in 0..<metadataQuery.resultCount {
            if let item = metadataQuery.result(at: i) as? NSMetadataItem,
               let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL {
                print("  Found: \(url.lastPathComponent)")
            }
        }
        // Capture ownership synchronously with the notification. The Task may
        // not run until after another scan starts or the current one is
        // cancelled, and a bare Bool cannot distinguish those generations.
        let completionGeneration = activeMetadataQueryGeneration
        if let completionGeneration {
            // If the deadline already won the race, its direct scan owns this
            // generation. A late DidFinishGathering from the stopped/stalled
            // query must not start reconciliation alongside it.
            guard metadataGatheringTimedOutGeneration != completionGeneration else {
                print("⏭️ Ignoring metadata-query completion after direct-scan handoff")
                return
            }
            cancelMetadataGatheringDeadline(for: completionGeneration)
        }
        Task {
            await processQueryResults(completionGeneration: completionGeneration)
        }
    }

    @objc private func queryDidUpdate() {
        Task {
            await processQueryResults(completionGeneration: nil)
        }
    }

    private var activeMetadataQueryGeneration: Int? {
        let generation = indexingGeneration
        return isActiveScan(generation, mode: .metadataQuery) ? generation : nil
    }

    private func processQueryResults(completionGeneration: Int?) async {
        // NSMetadataQuery fires DidUpdate repeatedly while a batch of files
        // lands, and every one of those used to spawn its own run of this.
        // Overlapping runs unbalanced disableUpdates()/enableUpdates() - the
        // first one's defer re-enabled updates while another was still walking
        // result(at:) over a live, mutating result set, so entries shifted and
        // were skipped outright - and whichever finished first declared
        // indexing over. Serialize instead, and remember that a pass is owed.
        guard !isProcessingQueryResults else {
            hasPendingQueryResults = true
            if let completionGeneration {
                pendingQueryCompletionGeneration = max(
                    pendingQueryCompletionGeneration ?? completionGeneration,
                    completionGeneration
                )
            }
            return
        }
        isProcessingQueryResults = true
        defer {
            isProcessingQueryResults = false

            // Updates can also arrive while reconciliation, the local sweep,
            // or folder-playlist work is awaiting below - after the snapshot
            // loop has already decided it is finished. Drain that queued event
            // in a fresh pass so its generation-owned completion is not left
            // parked with nobody to consume it.
            if hasPendingQueryResults {
                Task { @MainActor [weak self] in
                    await self?.processQueryResults(completionGeneration: nil)
                }
            }
        }

        var handedOffToDirectScan = false
        var requestedCompletionGeneration = completionGeneration
        repeat {
            hasPendingQueryResults = false
            if let pendingGeneration = pendingQueryCompletionGeneration {
                requestedCompletionGeneration = max(
                    requestedCompletionGeneration ?? pendingGeneration,
                    pendingGeneration
                )
                pendingQueryCompletionGeneration = nil
            }

            // Re-evaluate ownership for every coalesced snapshot. A manual scan
            // can begin while a long-running live update is awaiting file work;
            // its DidFinishGathering then belongs to the new generation, not to
            // the generation (or lack of one) captured by the older pass.
            handedOffToDirectScan = await scanCurrentQueryResults(
                generation: activeMetadataQueryGeneration
            )
        } while hasPendingQueryResults && !handedOffToDirectScan

        // The direct scan finishes and reports on its own.
        guard !handedOffToDirectScan else { return }

        // DidUpdate may arrive while the query is still gathering. It may
        // index the snapshot it saw, but only DidFinishGathering owns scan
        // reconciliation/completion; otherwise the first partial update can
        // stamp the scan successful and stop accepting generation-owned work.
        guard let generation = requestedCompletionGeneration else {
            postPendingLibraryRefresh()
            return
        }

        guard isActiveScan(generation, mode: .metadataQuery) else {
            print("🛑 Query results pass belongs to a cancelled run - not reporting completion")
            return
        }
        guard metadataGatheringTimedOutGeneration != generation else {
            print("⏭️ Metadata-query completion yielded to the gathering-deadline fallback")
            return
        }

        var scannedRoots: [URL] = []

        // Reconcile only the iCloud root, and only when this scan is
        // authoritative about it. Never infer deletion from a failed or
        // unavailable root.
        //
        // DidFinishGathering says the query collected every currently matching
        // result before switching to live updates - it does not say iCloud's
        // view of the container has converged, which after a restore it has
        // not. So the same evidence the direct scanner demands is required
        // here too: nothing failed to enumerate and nothing failed to index.
        // (`scanHadPendingDownloads` is deliberately excluded - an evicted
        // placeholder still exists on disk, so it is never seen as missing.)
        if AppCoordinator.shared.iCloudStatus == .available,
           !scanHadIncompleteRoots,
           !scanHadFileFailures,
           !scanWasInterrupted,
           let musicFolderURL = stateManager.getMusicFolderURL() {
            scannedRoots.append(musicFolderURL)
        } else if AppCoordinator.shared.iCloudStatus == .available {
            print("🛡️ Not reconciling the iCloud root - this scan could not read all of it")
        }

        // The query's scope is the iCloud folder alone, so on its own this
        // path never looked at on-device storage: with iCloud enabled and one
        // track in it, anything dropped into On My iPhone -> Cosmos was never
        // indexed, no matter how many times the user refreshed.
        if await sweepLocalDocuments(generation: generation) {
            scannedRoots.append(Self.localDocumentsURL)
        }

        guard isActiveScan(generation, mode: .metadataQuery),
              metadataGatheringTimedOutGeneration != generation else { return }

        await FileCleanupManager.shared.reconcileMissingFiles(in: scannedRoots)
        guard isActiveScan(generation, mode: .metadataQuery),
              metadataGatheringTimedOutGeneration != generation else { return }
        postPendingLibraryRefresh()

        // Folder playlists used to be built only by the direct and offline
        // scans, so anyone whose metadata query worked normally never got the
        // feature at all.
        var seen = Set<URL>()
        let uniqueFiles = scanCollectedFiles.filter { seen.insert($0).inserted }
        await processFolderPlaylists(allMusicFiles: uniqueFiles, generation: generation)
        guard isActiveScan(generation, mode: .metadataQuery),
              metadataGatheringTimedOutGeneration != generation else { return }

        completeScan(
            generation: generation,
            message: "Library indexing completed. Found \(tracksFound) tracks."
        )
    }

    /// One pass over the query's current results. Returns true if it handed
    /// off to the direct scan rather than indexing anything itself.
    private func scanCurrentQueryResults(generation: Int?) async -> Bool {
        if let generation, metadataGatheringTimedOutGeneration == generation {
            return true
        }

        metadataQuery.disableUpdates()
        defer { metadataQuery.enableUpdates() }

        let itemCount = metadataQuery.resultCount

        if itemCount == 0 {
            guard let generation else {
                print("⏭️ Ignoring empty metadata-query update outside an explicit scan")
                return false
            }
            print("NSMetadataQuery found 0 results, falling back to direct file system scan")
            await fallbackToDirectScan(generation: generation)
            return true
        }

        if let generation {
            // The timeout may already have handed this generation to the
            // direct scanner. Do not parse the same files again from the query
            // while that owner is running.
            guard directScanGeneration != generation else {
                print("⏭️ Direct scan owns this generation - skipping metadata-query duplicate")
                return true
            }
            queryResultScanGeneration = generation
        }
        defer {
            if let generation, queryResultScanGeneration == generation {
                queryResultScanGeneration = nil
            }
        }

        var processedCount = 0

        for i in 0..<itemCount {
            if let generation {
                guard isActiveScan(generation, mode: .metadataQuery) else { return false }
                if metadataGatheringTimedOutGeneration == generation {
                    print("⏭️ Yielding partial metadata-query snapshot to direct scan")
                    return true
                }
            }
            guard let item = metadataQuery.result(at: i) as? NSMetadataItem else { continue }

            await processMetadataItem(item, generation: generation)

            processedCount += 1
            // Throttle progress updates and yield so the UI stays responsive
            // during large imports
            if processedCount % 10 == 0 || processedCount == itemCount {
                indexingProgress = Double(processedCount) / Double(itemCount)
            }
            await Task.yield()
        }

        if let generation, metadataGatheringTimedOutGeneration == generation {
            return true
        }
        return false
    }

    static let localDocumentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!

    /// Indexes the on-device Documents folder alongside an iCloud scan.
    /// Returns whether the folder was enumerated successfully, so the caller
    /// knows if it may reconcile deletions against that root.
    private func sweepLocalDocuments(generation: Int) async -> Bool {
        guard isActiveScan(generation, mode: .metadataQuery) else { return false }
        if let cached = localDocumentsSweepSucceeded { return cached }

        let succeeded = await performLocalDocumentsSweep(generation: generation)
        localDocumentsSweepSucceeded = succeeded
        return succeeded
    }

    private func performLocalDocumentsSweep(generation: Int) async -> Bool {
        let documentsPath = Self.localDocumentsURL
        let localEnumeration: MusicFileEnumeration
        do {
            localEnumeration = try await findMusicFiles(in: documentsPath)
            if localEnumeration.isComplete {
                clearScanRootFailure(forRootAt: documentsPath)
            } else {
                recordScanRootFailure(forRootAt: documentsPath)
            }
        } catch {
            print("⚠️ Failed to scan local Documents folder: \(error)")
            // The on-device half of a metadata-query scan did not happen, so
            // this scan must not be stamped successful either.
            recordScanRootFailure(forRootAt: documentsPath)
            return false
        }

        guard isActiveScan(generation, mode: .metadataQuery) else { return false }

        let localFiles = localEnumeration.files

        guard !localFiles.isEmpty else { return localEnumeration.isComplete }

        print("📱 Sweeping \(localFiles.count) on-device file(s) alongside iCloud")
        scanCollectedFiles.append(contentsOf: localFiles)
        await indexFilesWithBoundedConcurrency(localFiles, generation: generation)
        return isActiveScan(generation, mode: .metadataQuery)
            && localEnumeration.isComplete
    }
    
    private func fallbackToDirectScan(generation: Int) async {
        guard isActiveScan(generation, mode: .metadataQuery) else { return }
        guard queryResultScanGeneration != generation else {
            print("⏭️ Metadata query is already indexing this generation - skipping timeout fallback")
            return
        }
        // Two entry points reach this: a zero-result gathering notification via
        // processQueryResults, and the 3s timeout in start(), which calls it
        // directly and so bypasses that method's serialization. Both could fire
        // for the same run and enumerate and parse the same files at once,
        // contending on the single database writer.
        guard directScanGeneration == nil else {
            print("⏭️ Direct scan already in progress - skipping duplicate")
            return
        }
        resetMetadataGatheringDeadline(for: generation)
        directScanGeneration = generation
        defer {
            if directScanGeneration == generation {
                directScanGeneration = nil
            }
        }

        print("🔄 Starting fallback direct scan of both iCloud and local folders")
        
        var allMusicFiles: [URL] = []
        var successfullyScannedRoots: [URL] = []
        
        // First, copy any new files from shared container to Documents
        await copyFilesFromSharedContainer()
        guard isActiveScan(generation, mode: .metadataQuery) else { return }
        
        // Scan iCloud folder if available
        if let iCloudMusicFolderURL = stateManager.getMusicFolderURL() {
            print("📁 Scanning iCloud folder: \(iCloudMusicFolderURL.path)")
            do {
                let enumeration = try await findMusicFiles(in: iCloudMusicFolderURL)
                guard isActiveScan(generation, mode: .metadataQuery) else { return }
                let iCloudFiles = enumeration.files
                print("📁 Found \(iCloudFiles.count) files in iCloud folder")
                allMusicFiles.append(contentsOf: iCloudFiles)
                if enumeration.isComplete {
                    if AppCoordinator.shared.iCloudStatus == .available {
                        successfullyScannedRoots.append(iCloudMusicFolderURL)
                    }
                    clearScanRootFailure(forRootAt: iCloudMusicFolderURL)
                } else {
                    recordScanRootFailure(forRootAt: iCloudMusicFolderURL)
                }
            } catch {
                print("⚠️ Failed to scan iCloud folder: \(error)")
                // findMusicFiles throws rather than returning [] precisely so a
                // root that could not be read is never mistaken for an empty
                // one. Logging alone was not enough: completeScan still stamped
                // lastLibraryScanDate, and shouldPerformAutoScan then suppressed
                // every retry for the whole cooldown with the entire iCloud
                // library missing from the app.
                recordScanRootFailure(forRootAt: iCloudMusicFolderURL)
            }
        }
        
        // Scan local Documents folder
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        print("📱 Scanning local Documents folder: \(documentsPath.path)")
        do {
            let enumeration = try await findMusicFiles(in: documentsPath)
            guard isActiveScan(generation, mode: .metadataQuery) else { return }
            let localFiles = enumeration.files
            print("📱 Found \(localFiles.count) files in local Documents folder")
            for file in localFiles {
                print("  📄 Local file: \(file.lastPathComponent)")
            }
            allMusicFiles.append(contentsOf: localFiles)
            if enumeration.isComplete {
                successfullyScannedRoots.append(documentsPath)
                clearScanRootFailure(forRootAt: documentsPath)
            } else {
                recordScanRootFailure(forRootAt: documentsPath)
            }
        } catch {
            print("⚠️ Failed to scan local Documents folder: \(error)")
            // Same reasoning as the iCloud root above.
            recordScanRootFailure(forRootAt: documentsPath)
        }
        
        let totalFiles = allMusicFiles.count
        print("📁 Total music files found (iCloud + local): \(totalFiles)")
        
        guard totalFiles > 0 else {
            // An empty, successfully enumerated root is meaningful: all of
            // its former tracks may have been deleted.
            await FileCleanupManager.shared.reconcileMissingFiles(in: successfullyScannedRoots)
            guard isActiveScan(generation, mode: .metadataQuery) else { return }
            postPendingLibraryRefresh()
            completeScan(generation: generation, message: "No music files found in any location")
            return
        }
        
        // Set initial queue
        await MainActor.run {
            queuedFiles = allMusicFiles.map { $0.lastPathComponent }
            currentlyProcessing = ""
        }
        
        let allFileNames = allMusicFiles.map { $0.lastPathComponent }

        // Parse and persist with bounded concurrency. Each file's work runs off
        // the main actor, so metadata reads and the per-track SQLite writes no
        // longer serialize behind (and block) UI work - previously a 90-file
        // first run spent ~20s with the main thread pinned. The cap keeps
        // memory and the single GRDB writer from being swamped.
        let maxConcurrentFiles = 4
        var completedCount = 0
        var nextIndex = 0

        await withTaskGroup(of: Void.self) { group in
            while nextIndex < min(maxConcurrentFiles, totalFiles) {
                let url = allMusicFiles[nextIndex]
                group.addTask { [weak self] in await self?.indexFile(url, generation: generation) }
                nextIndex += 1
            }

            while await group.next() != nil {
                guard isActiveScan(generation, mode: .metadataQuery) else {
                    group.cancelAll()
                    continue
                }
                completedCount += 1

                // Throttle @Published updates: rebuilding the 2000-element
                // queuedFiles array per file made SwiftUI re-diff the whole list
                // for every import - a major cause of freezes on large libraries
                if completedCount % 20 == 0 || completedCount == totalFiles {
                    currentlyProcessing = allFileNames[min(completedCount, totalFiles - 1)]
                    queuedFiles = Array(allFileNames.suffix(from: min(completedCount, totalFiles)))
                    indexingProgress = Double(completedCount) / Double(totalFiles)
                }

                if isActiveScan(generation, mode: .metadataQuery), nextIndex < totalFiles {
                    let url = allMusicFiles[nextIndex]
                    group.addTask { [weak self] in await self?.indexFile(url, generation: generation) }
                    nextIndex += 1
                }
            }
        }

        guard isActiveScan(generation, mode: .metadataQuery) else { return }
        
        // Clear processing state when done
        await MainActor.run {
            currentlyProcessing = ""
            queuedFiles = []
        }

        await FileCleanupManager.shared.reconcileMissingFiles(in: successfullyScannedRoots)
        guard isActiveScan(generation, mode: .metadataQuery) else { return }
        postPendingLibraryRefresh()

        // Folder playlists are part of the scan transaction. Do not publish
        // completion while they are still mutating the database.
        await processFolderPlaylists(allMusicFiles: allMusicFiles, generation: generation)
        guard isActiveScan(generation, mode: .metadataQuery) else { return }
        completeScan(
            generation: generation,
            message: "✅ Direct scan completed. Found \(tracksFound) tracks from both iCloud and local folders."
        )
    }

    private func processFolderPlaylists(allMusicFiles: [URL], generation: Int) async {
        guard isActiveScan(generation) else { return }
        guard !scanHadIncompleteRoots else {
            print("🛡️ Skipping folder-playlist sync after an incomplete root enumeration")
            return
        }
        guard DeleteSettings.load().autoCreateFolderPlaylists else {
            print("📁 Folder playlist auto-creation disabled in settings - skipping")
            return
        }
        print("📁 Processing folder playlists...")

        // Group music files by their parent directory
        var folderGroups: [String: [URL]] = [:]

        for fileURL in allMusicFiles {
            let parentFolder = fileURL.deletingLastPathComponent()
            let folderPath = parentFolder.path

            // Skip if it's directly in Documents or iCloud root
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.path
            let iCloudMusicPath = stateManager.getMusicFolderURL()?.path

            if folderPath == documentsPath || folderPath == iCloudMusicPath {
                continue
            }

            if folderGroups[folderPath] == nil {
                folderGroups[folderPath] = []
            }
            folderGroups[folderPath]?.append(fileURL)
        }

        print("📁 Found \(folderGroups.count) folders with music files")

        for (folderPath, musicFiles) in folderGroups {
            guard isActiveScan(generation) else { return }
            await processFolderPlaylist(folderPath: folderPath, musicFiles: musicFiles)
        }

        print("✅ Folder playlist processing completed")
    }

    private func processFolderPlaylist(folderPath: String, musicFiles: [URL]) async {
        let folderURL = URL(fileURLWithPath: folderPath)
        let folderName = folderURL.lastPathComponent

        print("📂 Processing folder playlist for: \(folderName)")

        do {
            // Generate stable IDs for all music files in this folder
            var trackStableIds: [String] = []

            for musicFile in musicFiles {
                let stableId = try generateStableId(for: musicFile)
                trackStableIds.append(stableId)
            }

            // A metadata scan can see an iCloud placeholder before its track
            // row exists. Never create a playlist_item for such a placeholder:
            // orphan cleanup would immediately remove it.
            let indexedTrackIds = Set(
                try databaseManager.getTracksByStableIdsPreservingOrder(trackStableIds).map(\.stableId)
            )
            trackStableIds = trackStableIds.filter { indexedTrackIds.contains($0) }

            guard !trackStableIds.isEmpty else {
                print("⏳ No indexed tracks ready yet for folder: \(folderName)")
                return
            }

            print("🎵 Found \(trackStableIds.count) tracks in folder: \(folderName)")

            // Check if a folder playlist already exists for this path
            if let existingPlaylist = try databaseManager.getFolderPlaylist(forPath: folderPath) {
                print("🔄 Syncing existing folder playlist: \(existingPlaylist.title)")

                // Sync the existing playlist with current folder contents
                try databaseManager.syncPlaylistWithFolder(playlistId: existingPlaylist.id!, trackStableIds: trackStableIds)
                print("✅ Synced playlist '\(existingPlaylist.title)' with folder contents")
            } else {
                // Create new folder playlist
                print("➕ Creating new folder playlist: \(folderName)")

                let playlist = try databaseManager.createFolderPlaylist(title: folderName, folderPath: folderPath)
                try databaseManager.syncPlaylistWithFolder(playlistId: playlist.id!, trackStableIds: trackStableIds)
                print("✅ Created folder playlist '\(playlist.title)' with \(trackStableIds.count) tracks")
            }

        } catch {
            print("❌ Failed to process folder playlist for \(folderName): \(error)")
        }
    }

    private func processLiveFolderPlaylist(for fileURL: URL) async {
        guard DeleteSettings.load().autoCreateFolderPlaylists else { return }

        let parentFolder = fileURL.deletingLastPathComponent()
        let folderPath = parentFolder.path
        let documentsPath = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first?.path
        let iCloudMusicPath = stateManager.getMusicFolderURL()?.path

        guard folderPath != documentsPath, folderPath != iCloudMusicPath else { return }
        await processFolderPlaylist(folderPath: folderPath, musicFiles: [fileURL])
    }
    
    private func scanLocalDocuments(generation: Int) async {
        guard isActiveScan(generation, mode: .offline) else { return }
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        
        do {
            let enumeration = try await findMusicFiles(in: documentsPath)
            guard isActiveScan(generation, mode: .offline) else { return }
            let musicFiles = enumeration.files

            if enumeration.isComplete {
                clearScanRootFailure(forRootAt: documentsPath)
            } else {
                recordScanRootFailure(forRootAt: documentsPath)
            }

            await indexFilesWithBoundedConcurrency(musicFiles, generation: generation) { progress in
                self.indexingProgress = progress
            }
            guard isActiveScan(generation, mode: .offline) else { return }

            if enumeration.isComplete {
                await FileCleanupManager.shared.reconcileMissingFiles(in: [documentsPath])
            } else {
                print("🛡️ Skipping deletion reconciliation for partially enumerated Documents")
            }
            guard isActiveScan(generation, mode: .offline) else { return }
            postPendingLibraryRefresh()

            await processFolderPlaylists(allMusicFiles: musicFiles, generation: generation)
            guard isActiveScan(generation, mode: .offline) else { return }
            completeScan(
                generation: generation,
                message: "Offline library scan completed. Found \(tracksFound) tracks."
            )
        } catch {
            failScan(generation: generation, message: "Offline library scan failed: \(error)")
        }
    }
    
    private func findMusicFiles(in directory: URL) async throws -> MusicFileEnumeration {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var musicFiles: [URL] = []
                var unreadableCount = 0
                var traversalErrorCount = 0

                let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .nameKey]
                let directoryEnumerator = FileManager.default.enumerator(
                    at: directory,
                    includingPropertiesForKeys: resourceKeys,
                    options: [.skipsHiddenFiles],
                    errorHandler: { failedURL, error in
                        traversalErrorCount += 1
                        print("⚠️ Could not enumerate \(failedURL.path): \(error)")
                        // Keep collecting readable files, but the result below
                        // is marked partial and can never authorize deletion.
                        return true
                    }
                )

                guard let enumerator = directoryEnumerator else {
                    // This function is declared `throws` but used to resume
                    // with an empty array here, which the direct scanner could
                    // not tell apart from a genuinely empty folder - so it
                    // added the root to successfullyScannedRoots and let
                    // reconciliation delete every track under it.
                    continuation.resume(throwing: LibraryIndexerError.directoryNotEnumerable(directory))
                    return
                }

                for case let fileURL as URL in enumerator {
                    // Read this file's attributes defensively. These used to be
                    // a bare `try` under a `do` that wrapped the whole walk, so
                    // a single file that could not be stat'd - one still being
                    // copied in, an undownloaded iCloud placeholder, a
                    // permissions blip - threw out every file found before it
                    // and every file after it. The library then stopped growing
                    // at the same point on every refresh.
                    guard let resourceValues = try? fileURL.resourceValues(forKeys: Set(resourceKeys)) else {
                        unreadableCount += 1
                        continue
                    }

                    guard let isRegularFile = resourceValues.isRegularFile, isRegularFile else {
                        continue
                    }

                    let pathExtension = fileURL.pathExtension.lowercased()
                    let supportedExtensions = ["flac", "mp3", "wav", "m4a", "aac", "opus", "ogg", "oga", "dsf", "dff"]
                    if supportedExtensions.contains(pathExtension) {
                        musicFiles.append(fileURL)
                    }
                }

                if unreadableCount > 0 {
                    print("⚠️ Skipped \(unreadableCount) unreadable entr\(unreadableCount == 1 ? "y" : "ies") while scanning \(directory.lastPathComponent)")
                }
                if traversalErrorCount > 0 {
                    print("⚠️ Encountered \(traversalErrorCount) traversal error\(traversalErrorCount == 1 ? "" : "s") while scanning \(directory.lastPathComponent)")
                }

                continuation.resume(returning: MusicFileEnumeration(
                    files: musicFiles,
                    isComplete: unreadableCount == 0 && traversalErrorCount == 0
                ))
            }
        }
    }
    
    /// Parses and persists files a few at a time.
    ///
    /// Each file's work runs off the main actor, so metadata reads and the
    /// per-track SQLite writes do not serialize behind (and block) UI work.
    /// The cap keeps memory and the single GRDB writer from being swamped.
    private func indexFilesWithBoundedConcurrency(
        _ files: [URL],
        generation: Int,
        onProgress: ((Double) -> Void)? = nil
    ) async {
        guard isActiveScan(generation) else { return }
        let totalFiles = files.count
        guard totalFiles > 0 else { return }

        let maxConcurrentFiles = 4
        var processedFiles = 0
        var nextIndex = 0

        await withTaskGroup(of: Void.self) { group in
            while nextIndex < min(maxConcurrentFiles, totalFiles) {
                let url = files[nextIndex]
                group.addTask { [weak self] in await self?.indexFile(url, generation: generation) }
                nextIndex += 1
            }

            while await group.next() != nil {
                guard isActiveScan(generation) else {
                    group.cancelAll()
                    continue
                }
                processedFiles += 1
                if processedFiles % 10 == 0 || processedFiles == totalFiles {
                    onProgress?(Double(processedFiles) / Double(totalFiles))
                }

                if nextIndex < totalFiles {
                    let url = files[nextIndex]
                    group.addTask { [weak self] in await self?.indexFile(url, generation: generation) }
                    nextIndex += 1
                }
            }
        }
    }

    /// One unit of scan work, safe to run concurrently off the main actor.
    /// The iCloud status is re-read per file rather than snapshotted so a
    /// mid-scan auth failure still halts further iCloud reads.
    nonisolated private func indexFile(_ fileURL: URL, generation: Int) async {
        guard await isActiveScan(generation) else { return }
        let isLocalFile = !fileURL.path.contains("Mobile Documents")

        if !isLocalFile {
            let status = await AppCoordinator.shared.iCloudStatus
            let isAvailable = await AppCoordinator.shared.isiCloudAvailable
            if status == .authenticationRequired || !isAvailable {
                print("🚫 Skipping iCloud file processing - iCloud authentication required: \(fileURL.lastPathComponent)")
                return
            }
        }

        guard await isActiveScan(generation) else { return }
        await processLocalFile(fileURL, generation: generation)
    }

    nonisolated private func processLocalFile(_ fileURL: URL, generation: Int) async {
        do {
            guard await isActiveScan(generation) else { return }
            print("🎵 Starting to process file: \(fileURL.lastPathComponent)")
            
            let isLocalFile = !fileURL.path.contains("Mobile Documents")
            
            // Only try to download from iCloud if it's actually an iCloud file
            if !isLocalFile {
                do {
                    // downloadTimeout 0: kick the download off but do not block
                    // the scan on it. The file is skipped this pass and indexed
                    // by the live metadata query once its bytes land - which is
                    // why the .downloadPending branch below records it through
                    // recordScanPendingDownload() and deliberately does NOT
                    // withhold the scan-success timestamp. (It used to call
                    // recordScanFileFailure(), which meant a library that is
                    // not fully downloaded rescanned itself on every launch.)
                    try await CloudDownloadManager.shared.ensureLocal(fileURL, downloadTimeout: 0)
                    print("✅ iCloud file ensured local: \(fileURL.lastPathComponent)")
                } catch {
                    print("⚠️ Failed to ensure iCloud file is local: \(fileURL.lastPathComponent) - \(error)")
                    
                    // Check for authentication errors
                    if let cloudError = error as? CloudDownloadError {
                        switch cloudError {
                        case .authenticationRequired, .accessDenied:
                            print("🔐 Authentication error in LibraryIndexer - switching to offline mode")
                            await AppCoordinator.shared.handleiCloudAuthenticationError()
                            return // Skip this file
                        case .downloadPending:
                            // The bytes are on their way. Parsing now would
                            // only fail on an unreadable placeholder and be
                            // recorded as a file failure, which withholds the
                            // scan-success timestamp for ever on a library
                            // that is not fully downloaded.
                            print("⏳ Skipping until its download lands: \(fileURL.lastPathComponent)")
                            await recordScanPendingDownload()
                            return
                        default:
                            break
                        }
                    }

                    // Continue processing even if download fails (for other errors)
                }
            } else {
                print("📱 Processing local file (no iCloud download needed): \(fileURL.lastPathComponent)")
            }

            guard await isActiveScan(generation) else { return }
            
            print("🆔 Generating stable ID for: \(fileURL.lastPathComponent)")
            let stableId = try generateStableId(for: fileURL)
            print("🆔 Generated stable ID: \(stableId)")

            let fingerprint = try fileFingerprint(for: fileURL)
            let existingTrack = try existingTrack(stableId: stableId, path: fileURL.path)

            if let existingTrack, !needsMetadataRefresh(existingTrack, fingerprint: fingerprint) {
                print("⏭️ Track metadata is current: \(fileURL.lastPathComponent)")
                return
            }
            if existingTrack != nil {
                print("🔄 File changed; reparsing metadata: \(fileURL.lastPathComponent)")
            }

            // Check if track was excluded (removed from library only)
            if isStillExcluded(stableId: stableId, url: fileURL) {
                print("⏭️ Track excluded from library: \(fileURL.lastPathComponent)")
                return
            }

            print("🎶 Parsing audio file: \(fileURL.lastPathComponent)")
            let parsedFile = try await parseAudioFile(at: fileURL, stableId: stableId)
            guard await isActiveScan(generation) else { return }
            print("✅ Audio file parsed successfully: \(parsedFile.track.title)")
            try await saveParsedFile(
                parsedFile,
                replacing: existingTrack,
                sourceDescription: "file"
            )
            // Indexed cleanly, so a genuinely new failure later counts again.
            await clearScanFileFailure(forFileAt: fileURL)
            
            // Check if file is downloaded (for iCloud files)
            await checkDownloadStatus(for: fileURL)
            
        } catch AudioParseError.unplayableFormat {
            // Deliberately not a scan failure: the file is intact and the scan
            // did its job, there is simply no decoder for it. Recording a
            // failure here would stop completeScan from ever stamping
            // lastLibraryScanDate, so the library would rescan forever.
            print("⏭️ Not indexing unplayable file: \(fileURL.lastPathComponent)")
            await removeUnplayableTrackRow(at: fileURL)
            await clearScanFileFailure(forFileAt: fileURL)
        } catch LibraryIndexerError.parseTimeout {
            print("⏰ Timeout parsing audio file: \(fileURL.lastPathComponent)")
            print("❌ Skipping file due to parsing timeout")
            await recordScanFileFailure(forFileAt: fileURL)
        } catch let error as DatabaseError where error.isInterruptionError {
            // The database was suspended underneath us - see
            // DatabaseSuspensionCoordinator. That says nothing about this file,
            // so recording it as a file failure was wrong: it withheld
            // lastLibraryScanDate and made the whole library rescan on the next
            // launch because the user happened to background the app mid-scan.
            print("⏸️ Database suspended while indexing \(fileURL.lastPathComponent) - will retry")
            await recordScanInterrupted()
        } catch {
            print("❌ Failed to process local track at \(fileURL.lastPathComponent): \(error)")
            print("❌ Error type: \(type(of: error))")
            print("❌ Error details: \(String(describing: error))")
            await recordScanFileFailure(forFileAt: fileURL)
        }
    }
    
    nonisolated private func checkDownloadStatus(for fileURL: URL) async {
        do {
            let resourceValues = try fileURL.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey, .isUbiquitousItemKey])
            
            if let isUbiquitous = resourceValues.isUbiquitousItem, isUbiquitous {
                if let downloadStatus = resourceValues.ubiquitousItemDownloadingStatus {
                    switch downloadStatus {
                    case .notDownloaded:
                        print("File not downloaded: \(fileURL.lastPathComponent)")
                        // Trigger download
                        try FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
                    case .downloaded:
                        print("File is downloaded: \(fileURL.lastPathComponent)")
                    case .current:
                        print("File is current: \(fileURL.lastPathComponent)")
                    default:
                        print("Unknown download status for: \(fileURL.lastPathComponent)")
                    }
                }
            }
        } catch {
            print("Failed to check download status for \(fileURL.lastPathComponent): \(error)")
        }
    }
    
    private func processMetadataItem(_ item: NSMetadataItem, generation: Int?) async {
        if let generation, !isActiveScan(generation, mode: .metadataQuery) { return }
        guard let fileURL = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { return }
        let ext = fileURL.pathExtension.lowercased()
        let supportedFormats = ["flac", "mp3", "wav", "m4a", "aac", "opus", "ogg", "oga", "dsf", "dff"]
        guard supportedFormats.contains(ext) else { return }

        // Recorded even when the track itself is already current: folder
        // playlists describe what is on disk, not what this pass re-parsed.
        // Only during an owned scan - a live query keeps sending updates
        // between scans and this list would otherwise grow without bound.
        if generation != nil {
            scanCollectedFiles.append(fileURL)
        }

        do {
            let stableId = try generateStableId(for: fileURL)
            let fingerprint = metadataFingerprint(for: item)
            let existingTrack = try existingTrack(stableId: stableId, path: fileURL.path)

            if let existingTrack, !needsMetadataRefresh(existingTrack, fingerprint: fingerprint) {
                return
            }
            if existingTrack != nil {
                print("🔄 iCloud file changed; reparsing metadata: \(fileURL.lastPathComponent)")
            }

            if isStillExcluded(stableId: stableId, url: fileURL) {
                return
            }

            try await CloudDownloadManager.shared.ensureLocal(fileURL, downloadTimeout: 0)
            if let generation, !isActiveScan(generation, mode: .metadataQuery) { return }

            let parsedFile = try await parseAudioFile(at: fileURL, stableId: stableId)
            if let generation, !isActiveScan(generation, mode: .metadataQuery) { return }
            try await saveParsedFile(
                parsedFile,
                replacing: existingTrack,
                sourceDescription: "iCloud file"
            )
            clearScanFileFailure(forFileAt: fileURL)

            // Live metadata updates do not own a scan completion, so they do
            // not run processFolderPlaylists. Add the newly-landed track now.
            if generation == nil {
                await processLiveFolderPlaylist(for: fileURL)
            }
            
            // Check if file is downloaded (for iCloud files)
            await checkDownloadStatus(for: fileURL)

        } catch AudioParseError.unplayableFormat {
            // See the matching case in processLocalFile: a skip, not a failure.
            print("⏭️ Not indexing unplayable file: \(fileURL.lastPathComponent)")
            await removeUnplayableTrackRow(at: fileURL)
            clearScanFileFailure(forFileAt: fileURL)
        } catch CloudDownloadError.downloadPending {
            // Also not a failure - see recordScanPendingDownload().
            print("⏳ Skipping until its download lands: \(fileURL.lastPathComponent)")
            recordScanPendingDownload()
        } catch let error as DatabaseError where error.isInterruptionError {
            // See the matching case in processLocalFile: the database was
            // suspended, which is not this file's fault.
            print("⏸️ Database suspended while indexing \(fileURL.lastPathComponent) - will retry")
            recordScanInterrupted()
        } catch {
            print("Failed to process track at \(fileURL): \(error)")
            await recordScanFileFailure(forFileAt: fileURL)
        }
    }
    
    nonisolated func generateStableId(for url: URL) throws -> String {
        DatabaseManager.generatePathStableId(forPath: url.path)
    }
    
    nonisolated private func parseAudioFile(at url: URL, stableId: String) async throws -> ParsedAudioFile {
        print("🔍 Calling AudioMetadataParser for: \(url.lastPathComponent)")
        
        // Files are parsed several at a time, so a single file's wall-clock
        // time now includes contention with its peers (and, on a fresh
        // install, iCloud still materialising the data). 10s was tight enough
        // that large files were being skipped outright; this only bounds a
        // genuine hang.
        let metadata = try await withHardTimeout(
            nanoseconds: 30_000_000_000, // 30 seconds
            timeoutError: LibraryIndexerError.parseTimeout
        ) {
            try await AudioMetadataParser.parseMetadata(from: url)
        }
        
        print("✅ AudioMetadataParser completed for: \(url.lastPathComponent)")
        
        let artistNames = parseArtistNames(metadata.artist)
        let rawAlbumArtist = metadata.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let albumArtistNames = rawAlbumArtist.isEmpty ? artistNames : parseArtistNames(rawAlbumArtist)
        let displayAlbumArtist = displayArtistName(from: albumArtistNames)
        print("🎤 Creating artist(s): '\(displayArtistName(from: artistNames))'")

        let artists = try artistNames.map { try databaseManager.upsertArtist(name: $0) }
        let albumArtists = try albumArtistNames.map { try databaseManager.upsertArtist(name: $0) }
        let artist: Artist
        if let firstArtist = artists.first {
            artist = firstArtist
        } else {
            artist = try databaseManager.upsertArtist(name: Localized.unknownArtist)
        }
        // Key the album on the ALBUM artist, not the track's artist - keying
        // on the track artist split albums whenever a track featured a guest
        // (issue #81). candidateArtistIds lets upsertAlbum group tracks whose
        // artist order differs (e.g. "Guest; Main") into the existing album.
        let albumPrimaryArtist = albumArtists.first ?? artist
        let album = try databaseManager.upsertAlbum(
            title: metadata.album ?? Localized.unknownAlbum,
            artistId: albumPrimaryArtist.id,
            year: metadata.year,
            albumArtist: displayAlbumArtist,
            candidateArtistIds: (artists + albumArtists).compactMap(\.id)
        )
        
        let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        
        let track = Track(
            stableId: stableId,
            albumId: album.id,
            artistId: artist.id,
            title: metadata.title ?? url.deletingPathExtension().lastPathComponent,
            trackNo: metadata.trackNumber,
            discNo: metadata.discNumber,
            durationMs: metadata.durationMs,
            sampleRate: metadata.sampleRate,
            bitDepth: metadata.bitDepth,
            channels: metadata.channels,
            path: url.path,
            fileSize: Int64(resourceValues.fileSize ?? 0),
            modificationDate: Self.modificationTimestamp(resourceValues.contentModificationDate),
            replaygainTrackGain: metadata.replaygainTrackGain,
            replaygainAlbumGain: metadata.replaygainAlbumGain,
            replaygainTrackPeak: metadata.replaygainTrackPeak,
            replaygainAlbumPeak: metadata.replaygainAlbumPeak,
            hasEmbeddedArt: metadata.hasEmbeddedArt
        )

        return ParsedAudioFile(
            track: track,
            trackArtistIds: artists.compactMap(\.id),
            albumArtistIds: albumArtists.compactMap(\.id)
        )
    }

    nonisolated private func parseArtistNames(_ artistName: String?) -> [String] {
        let rawName = artistName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawName.isEmpty else { return [Localized.unknownArtist] }

        // Treat "feat."-style credits as additional artists so featured
        // tracks group under the same artists and albums (issues #16, #81)
        let featSeparated = rawName.replacingOccurrences(
            of: "(?i)\\s*[\\(\\[]?\\s*\\b(?:featuring|feat\\.?|ft\\.?)\\s+",
            with: ";",
            options: .regularExpression
        )

        // Split on the common multi-artist separators (issue #16):
        // "\\" (ID3 joined-value convention), ";" (most taggers), and
        // NUL (ID3v2.4 multi-value text frames).
        //
        // A comma is only added on request: it is the one separator that also
        // occurs inside real names ("Earth, Wind & Fire", "Tyler, The
        // Creator"), and nothing in the text distinguishes the two uses.
        var delimiters = ["\\\\", ";", "\u{0}"]
        if DeleteSettings.load().splitArtistsOnComma {
            delimiters.append(",")
        }
        var rawComponents = [featSeparated]
        for delimiter in delimiters {
            rawComponents = rawComponents.flatMap { $0.components(separatedBy: delimiter) }
        }

        var seenNames = Set<String>()
        var artists: [String] = []

        for component in rawComponents {
            let cleaned = cleanArtistName(component)
            let normalized = cleaned.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            guard !cleaned.isEmpty, !seenNames.contains(normalized) else { continue }
            seenNames.insert(normalized)
            artists.append(cleaned)
        }

        return artists.isEmpty ? [Localized.unknownArtist] : artists
    }

    nonisolated private func displayArtistName(from artistNames: [String]) -> String {
        artistNames.joined(separator: " / ")
    }

    nonisolated private func cleanArtistName(_ artistName: String) -> String {
        var cleaned = artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove common YouTube/streaming suffixes
        let suffixesToRemove = [
            " - Topic",
            " Topic",
            "- Topic", 
            ", Topic",
            " (Topic)"
        ]
        
        for suffix in suffixesToRemove {
            if cleaned.hasSuffix(suffix) {
                cleaned = String(cleaned.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        // Remove brackets and additional info that might cause duplicates
        if let bracketStart = cleaned.firstIndex(of: "[") {
            cleaned = String(cleaned[..<bracketStart]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Drop unbalanced trailing brackets left over when a "(feat. X)"
        // credit was converted into a separator (keeps names like "(G)I-DLE")
        while let last = cleaned.last,
              (last == ")" && !cleaned.contains("(")) || (last == "]" && !cleaned.contains("[")) {
            cleaned = String(cleaned.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return cleaned.isEmpty ? Localized.unknownArtist : cleaned
    }
    
    func copyFilesFromSharedContainer() async {
        if let sharedContainerProcessingTask {
            await sharedContainerProcessingTask.value
            return
        }

        sharedContainerProcessingGeneration &+= 1
        let generation = sharedContainerProcessingGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performSharedContainerProcessing()
        }
        sharedContainerProcessingTask = task
        await task.value

        if sharedContainerProcessingGeneration == generation {
            sharedContainerProcessingTask = nil
        }
    }

    private func performSharedContainerProcessing() async {
        print("📁 Checking shared container for new music files...")

        guard let sharedContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.dev.clq.Cosmos-Music-Player") else {
            print("❌ Failed to get shared container URL")
            return
        }

        // Process shared URLs from share extension
        await processSharedURLs(from: sharedContainer)

        // Also check for legacy copied files (for backward compatibility)
        await processLegacySharedFiles(from: sharedContainer)

        // Process previously stored external bookmarks (both document picker and share extension files)
        await processStoredExternalBookmarks()
    }

    private func processSharedURLs(from sharedContainer: URL) async {
        let sharedDataURL = sharedContainer.appendingPathComponent("SharedAudioFiles.plist")

        guard FileManager.default.fileExists(atPath: sharedDataURL.path) else {
            print("📁 No shared audio files found")
            return
        }

        do {
            let data = try Data(contentsOf: sharedDataURL)
            guard let sharedFiles = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [[String: Data]] else {
                return
            }

            print("📁 Found \(sharedFiles.count) shared audio file references")

            // Group files by folder for playlist creation
            var folderGroups: [String: [URL]] = [:]
            var pendingFiles: [[String: Data]] = []

            for fileInfo in sharedFiles {
                guard let bookmarkData = fileInfo["bookmark"],
                      let filenameData = fileInfo["filename"],
                      let filename = String(data: filenameData, encoding: .utf8) else {
                    print("❌ Dropping malformed shared import entry")
                    continue
                }

                do {
                    // Resolve bookmark to get access to the original file
                    var isStale = false
                    let url = try URL(resolvingBookmarkData: bookmarkData, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale)
                    var durableBookmarkData = bookmarkData

                    if isStale {
                        print("⚠️ Refreshing stale bookmark for: \(filename)")
                        do {
                            durableBookmarkData = try url.bookmarkData(
                                options: .minimalBookmark,
                                includingResourceValuesForKeys: nil,
                                relativeTo: nil
                            )
                        } catch {
                            print("⚠️ Could not refresh stale bookmark for \(filename): \(error)")
                            pendingFiles.append(fileInfo)
                            continue
                        }
                    }

                    // Reject network URLs
                    if let scheme = url.scheme?.lowercased(), ["http", "https", "ftp", "sftp"].contains(scheme) {
                        print("❌ Rejected network URL: \(url.absoluteString)")
                        continue
                    }

                    // Start accessing security-scoped resource
                    guard url.startAccessingSecurityScopedResource() else {
                        print("❌ Failed to access security-scoped resource for: \(filename)")
                        var pendingFileInfo = fileInfo
                        pendingFileInfo["bookmark"] = durableBookmarkData
                        pendingFiles.append(pendingFileInfo)
                        continue
                    }

                    defer {
                        url.stopAccessingSecurityScopedResource()
                    }

                    // Process the file directly from its original location
                    let processingResult = await processExternalFileResult(
                        url,
                        allowExcludedReimport: true
                    )
                    guard processingResult.succeeded else {
                        print("⏳ Keeping failed shared import for retry: \(filename)")
                        var pendingFileInfo = fileInfo
                        pendingFileInfo["bookmark"] = durableBookmarkData
                        pendingFiles.append(pendingFileInfo)
                        continue
                    }
                    print("✅ Processed shared file from original location: \(filename)")

                    // Store the bookmark permanently for future access after app updates
                    guard await storeBookmarkPermanently(durableBookmarkData, for: url) else {
                        print("⏳ Keeping shared import until its permanent bookmark is stored: \(filename)")
                        var pendingFileInfo = fileInfo
                        pendingFileInfo["bookmark"] = durableBookmarkData
                        pendingFiles.append(pendingFileInfo)
                        continue
                    }

                    // Group by folder path for playlist creation
                    if let folderPathData = fileInfo["folderPath"],
                       let folderPath = String(data: folderPathData, encoding: .utf8) {
                        if folderGroups[folderPath] == nil {
                            folderGroups[folderPath] = []
                        }
                        folderGroups[folderPath]?.append(url)
                    }

                } catch {
                    print("❌ Failed to resolve bookmark for \(filename): \(error)")
                    pendingFiles.append(fileInfo)
                }
            }

            // Create folder playlists for shared files
            await processSharedFolderPlaylists(folderGroups: folderGroups)

            if pendingFiles.isEmpty {
                try FileManager.default.removeItem(at: sharedDataURL)
                print("🗑️ Cleared shared audio files list (bookmarks moved to permanent storage)")
            } else {
                let pendingData = try PropertyListSerialization.data(
                    fromPropertyList: pendingFiles,
                    format: .xml,
                    options: 0
                )
                try pendingData.write(to: sharedDataURL, options: .atomic)
                print("⏳ Preserved \(pendingFiles.count) shared imports for retry")
            }

        } catch {
            print("❌ Failed to process shared audio files: \(error)")
        }
    }

    private func processSharedFolderPlaylists(folderGroups: [String: [URL]]) async {
        guard !folderGroups.isEmpty else { return }
        guard DeleteSettings.load().autoCreateFolderPlaylists else {
            print("📁 Folder playlist auto-creation disabled in settings - skipping shared folders")
            return
        }

        print("📁 Processing \(folderGroups.count) shared folder playlists...")

        for (folderPath, musicFiles) in folderGroups {
            let folderURL = URL(fileURLWithPath: folderPath)
            let folderName = folderURL.lastPathComponent

            print("📂 Processing shared folder playlist for: \(folderName)")

            do {
                // Generate stable IDs for all music files in this folder
                var trackStableIds: [String] = []

                for musicFile in musicFiles {
                    let stableId = try generateStableId(for: musicFile)
                    trackStableIds.append(stableId)
                }

                print("🎵 Found \(trackStableIds.count) tracks in shared folder: \(folderName)")

                // Check if a folder playlist already exists for this path
                if let existingPlaylist = try databaseManager.getFolderPlaylist(forPath: folderPath) {
                    print("🔄 Syncing existing shared folder playlist: \(existingPlaylist.title)")

                    // Sync the existing playlist with current folder contents
                    try databaseManager.syncPlaylistWithFolder(playlistId: existingPlaylist.id!, trackStableIds: trackStableIds)
                    print("✅ Synced shared playlist '\(existingPlaylist.title)' with folder contents")
                } else {
                    // Create new folder playlist for shared folder
                    print("➕ Creating new shared folder playlist: \(folderName)")

                    let playlist = try databaseManager.createFolderPlaylist(title: folderName, folderPath: folderPath)
                    try databaseManager.syncPlaylistWithFolder(playlistId: playlist.id!, trackStableIds: trackStableIds)
                    print("✅ Created shared folder playlist '\(playlist.title)' with \(trackStableIds.count) tracks")
                }

            } catch {
                print("❌ Failed to process shared folder playlist for \(folderName): \(error)")
            }
        }

        print("✅ Shared folder playlist processing completed")
    }

    private func processLegacySharedFiles(from sharedContainer: URL) async {
        let sharedMusicURL = sharedContainer.appendingPathComponent("Documents").appendingPathComponent("Music")
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let localMusicURL = documentsURL.appendingPathComponent("Music")

        // Create local Music directory if it doesn't exist
        do {
            try FileManager.default.createDirectory(at: localMusicURL, withIntermediateDirectories: true, attributes: nil)
        } catch {
            print("❌ Failed to create local Music directory: \(error)")
            return
        }

        // Check if shared Music directory exists
        guard FileManager.default.fileExists(atPath: sharedMusicURL.path) else {
            print("📁 No shared Music directory found")
            return
        }

        do {
            let sharedFiles = try FileManager.default.contentsOfDirectory(at: sharedMusicURL, includingPropertiesForKeys: nil)
            let audioFiles = sharedFiles.filter { url in
                let ext = url.pathExtension.lowercased()
                return ext == "mp3" || ext == "flac" || ext == "wav"
            }

            print("📁 Found \(audioFiles.count) legacy audio files in shared container")

            for audioFile in audioFiles {
                let localDestination = localMusicURL.appendingPathComponent(audioFile.lastPathComponent)

                // Skip if file already exists in local directory
                if FileManager.default.fileExists(atPath: localDestination.path) {
                    print("⏭️ File already exists locally: \(audioFile.lastPathComponent)")
                    continue
                }

                do {
                    try FileManager.default.copyItem(at: audioFile, to: localDestination)
                    print("✅ Copied legacy file to Documents/Music: \(audioFile.lastPathComponent)")

                    // Remove from shared container after successful copy
                    try FileManager.default.removeItem(at: audioFile)
                    print("🗑️ Removed legacy file from shared container: \(audioFile.lastPathComponent)")

                } catch {
                    print("❌ Failed to copy legacy file \(audioFile.lastPathComponent): \(error)")
                }
            }

        } catch {
            print("❌ Failed to read shared container directory: \(error)")
        }
    }

    private func storeBookmarkPermanently(_ bookmarkData: Data, for url: URL) async -> Bool {
        do {
            await databaseManager.waitForExternalBookmarkMigration()
            let stableId = try generateStableId(for: url)
            try await ExternalBookmarkStore.shared.store(bookmarkData, for: stableId)

            print("💾 Stored permanent bookmark for shared file: \(url.lastPathComponent) with stableId: \(stableId)")
            return true
        } catch {
            print("❌ Failed to store permanent bookmark for \(url.lastPathComponent): \(error)")
            return false
        }
    }

    private func processStoredExternalBookmarks() async {
        do {
            await databaseManager.waitForExternalBookmarkMigration()
            let bookmarks = try await ExternalBookmarkStore.shared.allBookmarks()
            guard !bookmarks.isEmpty else {
                print("📁 No stored external bookmarks found")
                return
            }

            print("📁 Found \(bookmarks.count) stored external file bookmarks")

            for stableId in Array(bookmarks.keys) {
                do {
                    guard let resolution = try await ExternalBookmarkStore.shared.resolveAndRefreshBookmark(for: stableId) else {
                        // Another serialized bookmark operation may have migrated
                        // or removed this snapshot key while the scan was running.
                        continue
                    }
                    let resolvedURL = resolution.url
                    let durableBookmarkData = resolution.bookmarkData
                    if resolution.wasRefreshed {
                        print("✅ Refreshed stale bookmark for: \(resolvedURL.lastPathComponent)")
                    } else if resolution.wasStale {
                        print("⚠️ Using resolved URL although bookmark refresh could not be persisted: \(resolvedURL.lastPathComponent)")
                    }

                    // Reject network URLs
                    if let scheme = resolvedURL.scheme?.lowercased(), ["http", "https", "ftp", "sftp"].contains(scheme) {
                        print("❌ Rejected network URL: \(resolvedURL.absoluteString)")
                        continue
                    }

                    let resolvedStableId = try generateStableId(for: resolvedURL)

                    // Check if this file is in the database. Existing files
                    // still flow through processExternalFile below so a
                    // changed modification date can refresh their metadata.
                    var trackAlreadyExists = false
                    if let existingTrack = try databaseManager.getTrack(byStableId: stableId) {
                        trackAlreadyExists = true
                        // Repair either half of the path-derived identity. A
                        // playback-time bookmark resolution may already have
                        // updated the path while an older build left the row
                        // and bookmark under the old path hash.
                        if existingTrack.path != resolvedURL.path || stableId != resolvedStableId {
                            if existingTrack.path != resolvedURL.path {
                                print("📍 File moved detected! Old: \(existingTrack.path)")
                                print("📍 File moved detected! New: \(resolvedURL.path)")
                            } else {
                                print("🔁 Repairing stale path-derived ID for: \(resolvedURL.lastPathComponent)")
                            }

                            try databaseManager.migrateTrackStableIdAndPath(
                                oldStableId: stableId,
                                newStableId: resolvedStableId,
                                newPath: resolvedURL.path
                            )
                            try await ExternalBookmarkStore.shared.migrate(
                                from: stableId,
                                to: resolvedStableId,
                                fallbackData: durableBookmarkData
                            )
                            print("✅ Updated database path for: \(resolvedURL.lastPathComponent)")
                        } else {
                            print("📍 External file path unchanged: \(resolvedURL.lastPathComponent)")
                        }
                    } else if try databaseManager.getTrack(byStableId: resolvedStableId) != nil {
                        trackAlreadyExists = true
                        try await ExternalBookmarkStore.shared.migrate(
                            from: stableId,
                            to: resolvedStableId,
                            fallbackData: durableBookmarkData
                        )
                        print("🔁 Updated stale bookmark key for existing track: \(resolvedURL.lastPathComponent)")
                    }

                    // Check if track was excluded (removed from library only)
                    if !trackAlreadyExists &&
                        (DeleteSettings.isTrackExcluded(stableId) || DeleteSettings.isTrackExcluded(resolvedStableId)) {
                        print("⏭️ Track excluded from library: \(resolvedURL.lastPathComponent)")
                        continue
                    }

                    // File not in database yet - process it
                    // Start accessing security-scoped resource
                    guard resolvedURL.startAccessingSecurityScopedResource() else {
                        print("❌ Failed to access security-scoped resource for: \(resolvedURL.lastPathComponent)")
                        continue
                    }

                    defer {
                        resolvedURL.stopAccessingSecurityScopedResource()
                    }

                    // Import a new file or refresh an existing file whose
                    // fingerprint changed.
                    await processExternalFile(resolvedURL)
                    print("✅ Processed stored external file: \(resolvedURL.lastPathComponent)")

                } catch {
                    print("❌ Failed to resolve bookmark for stableId \(stableId): \(error)")
                }
            }

        } catch {
            print("❌ Failed to process stored external bookmarks: \(error)")
        }
    }

    /// Resolve a bookmark and keep its path-derived database/bookmark identity
    /// consistent before returning it to playback.
    func resolveBookmarkForTrack(_ track: Track) async -> URL? {
        do {
            await databaseManager.waitForExternalBookmarkMigration()
            guard let resolution = try await ExternalBookmarkStore.shared.resolveAndRefreshBookmark(for: track.stableId) else {
                return nil // No bookmark for this track
            }
            let resolvedURL = resolution.url
            let durableBookmarkData = resolution.bookmarkData
            if resolution.wasRefreshed {
                print("✅ Playback refreshed stale bookmark for: \(track.title)")
            } else if resolution.wasStale {
                print("⚠️ Playback is using resolved URL although bookmark refresh could not be persisted: \(track.title)")
            }

            let resolvedStableId = try generateStableId(for: resolvedURL)

            // Update all identity-bearing stores together if the file moved.
            // Updating only Track.path leaves a collision window where a new
            // file imported at the old path reuses this row's stable ID.
            // Compare the canonical spelling, not the raw one. A bookmark
            // resolves to whichever of `/var/...` and `/private/var/...` the
            // system feels like handing back, and the database stores the
            // canonical form - so a raw string comparison reported a move on
            // every single play of an external file, wrote the non-canonical
            // spelling back, and let the next launch's normalisation flip it
            // straight back again.
            let resolvedPath = DatabaseManager.canonicalPath(resolvedURL.path)
            if DatabaseManager.canonicalPath(track.path) != resolvedPath
                || track.stableId != resolvedStableId {
                print("📍 Playback: File moved detected! Old: \(track.path)")
                print("📍 Playback: File moved detected! New: \(resolvedURL.path)")

                try databaseManager.migrateTrackStableIdAndPath(
                    oldStableId: track.stableId,
                    newStableId: resolvedStableId,
                    newPath: resolvedPath
                )
                try await ExternalBookmarkStore.shared.migrate(
                    from: track.stableId,
                    to: resolvedStableId,
                    fallbackData: durableBookmarkData
                )
                NotificationCenter.default.post(
                    name: NSNotification.Name("LibraryNeedsRefresh"),
                    object: nil
                )
                print("✅ Migrated database and bookmark identity for playback: \(resolvedURL.lastPathComponent)")
            }

            return resolvedURL

        } catch {
            print("❌ Failed to resolve bookmark for track \(track.title): \(error)")
            return nil
        }
    }
}

extension LibraryIndexer: NSMetadataQueryDelegate {
    nonisolated func metadataQuery(_ query: NSMetadataQuery, replacementObjectForResultObject result: NSMetadataItem) -> Any {
        return result
    }
}

struct AudioMetadata {
    let title: String?
    let artist: String?
    let album: String?
    let albumArtist: String?
    let trackNumber: Int?
    let discNumber: Int?
    let year: Int?
    let durationMs: Int?
    let sampleRate: Int?
    let bitDepth: Int?
    let channels: Int?
    let replaygainTrackGain: Double?
    let replaygainAlbumGain: Double?
    let replaygainTrackPeak: Double?
    let replaygainAlbumPeak: Double?
    let hasEmbeddedArt: Bool
}

class AudioMetadataParser {
    static func parseMetadata(from url: URL) async throws -> AudioMetadata {
        return try await parseAudioMetadataSync(from: url)
    }
    
    private static func parseAudioMetadataSync(from url: URL) async throws -> AudioMetadata {
        let ext = url.pathExtension.lowercased()

        switch ext {
        // Native formats
        case "flac", "mp3", "wav", "aac":
            return try await parseNativeFormat(url)

        case "m4a":
            // Detect if AAC or Opus
            if isOpusInM4A(url) {
                // Opus inside an ISO-BMFF container has no decoder here.
                // SFBAudioEngineManager.canHandle routes every .m4a to native
                // playback, and AVAudioFile/Core Audio reject Opus-in-MP4;
                // SFBAudioEngine's own Opus decoder only accepts Ogg Opus, so
                // there is no branch to route it to either. Indexing it added
                // a fully-tagged row that every playback path then silently
                // skipped, which reads as "this song does nothing".
                print("⏭️ Opus in an MP4 container has no decoder on this platform: \(url.lastPathComponent)")
                throw AudioParseError.unplayableFormat
            } else {
                return try await parseAacMetadata(url)  // AAC → Native
            }

        case "opus", "ogg", "oga":
            return try await parseOpusOrVorbis(url)

        case "dsf", "dff":
            return try await parseDSDBasicMetadata(url)

        default:
            throw AudioParseError.unsupportedFormat
        }
    }
    
    private static func parseFlacMetadataSync(from url: URL) async throws -> AudioMetadata {
        var title: String?
        var artist: String?
        var album: String?
        var albumArtist: String?
        var trackNumber: Int?
        var discNumber: Int?
        var year: Int?
        var durationMs: Int?
        var sampleRate: Int?
        var bitDepth: Int?
        var channels: Int?
        var replaygainTrackGain: Double?
        var replaygainAlbumGain: Double?
        var replaygainTrackPeak: Double?
        var replaygainAlbumPeak: Double?
        var hasEmbeddedArt = false
        
        // Check if file is actually readable first
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            print("❌ FLAC file is not readable: \(url.lastPathComponent)")
            throw AudioParseError.fileNotReadable
        }
        
        // Get file size to check if reasonable
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSize = fileAttributes[.size] as? Int64 else {
            throw AudioParseError.fileNotReadable
        }
        
        print("📊 FLAC file size: \(fileSize) bytes for \(url.lastPathComponent)")
        
        // or too small (<1KB)
        guard fileSize > 1024 else {
            print("❌ FLAC file size is unreasonable: \(fileSize) bytes")
            throw AudioParseError.fileSizeError
        }
        
        print("📖 Reading FLAC data for: \(url.lastPathComponent)")
        
        // Use NSFileCoordinator to properly read iCloud files
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var error: NSError?
                let coordinator = NSFileCoordinator()
                var coordinatedData: Data?
                var coordinatedError: Error?
                
                coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &error) { (readingURL) in
                    do {
                        // Create fresh URL to avoid stale metadata
                        let freshURL = URL(fileURLWithPath: readingURL.path)
                        print("🔄 Using NSFileCoordinator to read: \(freshURL.lastPathComponent)")
                        
                        // Check if file actually exists at path
                        guard FileManager.default.fileExists(atPath: freshURL.path) else {
                            coordinatedError = AudioParseError.fileNotReadable
                            return
                        }
                        
                        // Map instead of loading the whole file - metadata lives at
                        // the start, and 2000 x full FLAC reads spikes memory
                        coordinatedData = try Data(contentsOf: freshURL, options: .mappedIfSafe)
                        print("✅ FLAC data read successfully via NSFileCoordinator: \(coordinatedData?.count ?? 0) bytes")
                    } catch {
                        print("❌ Failed to read FLAC data via NSFileCoordinator: \(error)")
                        coordinatedError = error
                    }
                }
                
                if let error = error {
                    print("❌ NSFileCoordinator error: \(error)")
                    continuation.resume(throwing: error)
                } else if let coordinatedError = coordinatedError {
                    continuation.resume(throwing: coordinatedError)
                } else if let data = coordinatedData {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: AudioParseError.fileNotReadable)
                }
            }
        }
        
        if data.count < 42 {
            throw AudioParseError.invalidFile
        }
        
        var offset = 4
        
        while offset < data.count {
            let blockHeader = data[offset]
            let isLast = (blockHeader & 0x80) != 0
            let blockType = blockHeader & 0x7F
            
            offset += 1
            
            guard offset + 3 <= data.count else { break }
            
            let blockSize = Int(data[offset]) << 16 | Int(data[offset + 1]) << 8 | Int(data[offset + 2])
            offset += 3
            
            if blockType == 0 {
                if offset + 18 <= data.count {
                    sampleRate = Int(data[offset + 10]) << 12 | Int(data[offset + 11]) << 4 | Int(data[offset + 12]) >> 4
                    channels = Int((data[offset + 12] >> 1) & 0x07) + 1
                    bitDepth = Int(((data[offset + 12] & 0x01) << 4) | (data[offset + 13] >> 4)) + 1
                    
                    let totalSamples = UInt64(data[offset + 13] & 0x0F) << 32 |
                                      UInt64(data[offset + 14]) << 24 |
                                      UInt64(data[offset + 15]) << 16 |
                                      UInt64(data[offset + 16]) << 8 |
                                      UInt64(data[offset + 17])
                    
                    if sampleRate! > 0 {
                        durationMs = Int((totalSamples * 1000) / UInt64(sampleRate!))
                    }
                }
            } else if blockType == 4 {
                let commentData = data.subdata(in: offset..<min(offset + blockSize, data.count))
                let metadata = parseVorbisComments(commentData)
                
                title = metadata["TITLE"]
                artist = metadata["ARTIST"] ?? metadata["ARTISTE"]
                album = metadata["ALBUM"]
                albumArtist = metadata["ALBUMARTIST"]
                
                // "1/12" for TRACKNUMBER/DISCNUMBER and a full "2024-05-01"
                // for DATE are all ordinary in Vorbis comments; handing them
                // straight to Int() returned nil and dropped the value.
                if let trackStr = metadata["TRACKNUMBER"] {
                    trackNumber = parseSlashSeparatedNumber(trackStr)
                }
                if let discStr = metadata["DISCNUMBER"] {
                    discNumber = parseSlashSeparatedNumber(discStr)
                }
                if let dateStr = metadata["DATE"] ?? metadata["YEAR"] {
                    year = parseYear(dateStr)
                }
                
                if let gainStr = metadata["REPLAYGAIN_TRACK_GAIN"] {
                    replaygainTrackGain = parseReplayGain(gainStr)
                }
                if let gainStr = metadata["REPLAYGAIN_ALBUM_GAIN"] {
                    replaygainAlbumGain = parseReplayGain(gainStr)
                }
                if let peakStr = metadata["REPLAYGAIN_TRACK_PEAK"] {
                    replaygainTrackPeak = Double(peakStr)
                }
                if let peakStr = metadata["REPLAYGAIN_ALBUM_PEAK"] {
                    replaygainAlbumPeak = Double(peakStr)
                }
            } else if blockType == 6 {
                // PICTURE block - embedded artwork
                hasEmbeddedArt = true
            }
            
            offset += blockSize
            
            if isLast { break }
        }
        
        return AudioMetadata(
            title: title,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            trackNumber: trackNumber,
            discNumber: discNumber,
            year: year,
            durationMs: durationMs,
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            channels: channels,
            replaygainTrackGain: replaygainTrackGain,
            replaygainAlbumGain: replaygainAlbumGain,
            replaygainTrackPeak: replaygainTrackPeak,
            replaygainAlbumPeak: replaygainAlbumPeak,
            hasEmbeddedArt: hasEmbeddedArt
        )
    }
    
    private static func parseVorbisComments(_ data: Data) -> [String: String] {
        var comments: [String: String] = [:]
        var offset = 0
        
        guard offset + 4 <= data.count else { return comments }
        
        let vendorLength = Int(data[offset]) | (Int(data[offset + 1]) << 8) | (Int(data[offset + 2]) << 16) | (Int(data[offset + 3]) << 24)
        offset += 4 + vendorLength
        
        guard offset + 4 <= data.count else { return comments }
        
        let commentCount = Int(data[offset]) | (Int(data[offset + 1]) << 8) | (Int(data[offset + 2]) << 16) | (Int(data[offset + 3]) << 24)
        offset += 4
        
        for _ in 0..<commentCount {
            guard offset + 4 <= data.count else { break }
            
            let commentLength = Int(data[offset]) | (Int(data[offset + 1]) << 8) | (Int(data[offset + 2]) << 16) | (Int(data[offset + 3]) << 24)
            offset += 4
            
            guard offset + commentLength <= data.count else { break }
            
            if let commentString = String(data: data.subdata(in: offset..<offset + commentLength), encoding: .utf8) {
                let parts = commentString.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    let key = String(parts[0]).uppercased()
                    let value = String(parts[1])
                    // Vorbis allows repeating a field for multiple values -
                    // the standard way to tag multiple artists. Accumulate
                    // them so they aren't silently overwritten (issue #16);
                    // parseArtistNames splits on ";" downstream
                    let multiValueKeys: Set<String> = ["ARTIST", "ARTISTE", "ALBUMARTIST"]
                    if multiValueKeys.contains(key), let existing = comments[key], !existing.isEmpty {
                        comments[key] = existing + "; " + value
                    } else {
                        comments[key] = value
                    }
                }
            }
            
            offset += commentLength
        }
        
        return comments
    }
    
    private static func parseReplayGain(_ gainString: String) -> Double? {
        let cleaned = gainString.replacingOccurrences(of: " dB", with: "")
        return Double(cleaned)
    }

    /// Accepts a bare year, an ISO date ("2024-05-01"), or anything else that
    /// starts with a four-digit year.
    private static func parseYear(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = Int(trimmed) { return exact }

        let digits = trimmed.prefix { $0.isNumber }
        guard digits.count == 4, let year = Int(digits) else { return nil }
        return year
    }

    private static func parseSlashSeparatedNumber(_ value: String) -> Int? {
        let firstPart = value.components(separatedBy: "/").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? value
        return Int(firstPart)
    }

    // MP4 trkn/disk atoms usually store values as big-endian UInt16 pairs.
    private static func parseMP4TrackOrDiscData(_ data: Data) -> Int? {
        let bytes = [UInt8](data)

        if bytes.count >= 4 {
            let valueAtOffset2 = (Int(bytes[2]) << 8) | Int(bytes[3])
            if valueAtOffset2 > 0 {
                return valueAtOffset2
            }
        }

        if bytes.count >= 2 {
            let valueAtOffset0 = (Int(bytes[0]) << 8) | Int(bytes[1])
            if valueAtOffset0 > 0 {
                return valueAtOffset0
            }
        }

        return nil
    }

    private static func extractTrackOrDiscNumber(from metadata: AVMetadataItem) async -> Int? {
        if let stringValue = try? await metadata.load(.stringValue),
           let parsed = parseSlashSeparatedNumber(stringValue) {
            return parsed
        }

        if let numberValue = try? await metadata.load(.numberValue) {
            let value = numberValue.intValue
            if value > 0 {
                return value
            }
        }

        if let dataValue = try? await metadata.load(.dataValue),
           let parsed = parseMP4TrackOrDiscData(dataValue) {
            return parsed
        }

        return nil
    }
    
    /// Carries one coordinated parse's outcome out of the accessor block.
    /// Created, written and read by a single call; the semaphore below orders
    /// the one write against the one read.
    private final class CoordinatedParseOutcome: @unchecked Sendable {
        var result: Result<AudioMetadata, Error>?
    }

    private static func parseMp3MetadataSync(from url: URL) async throws -> AudioMetadata {
        print("📖 Reading MP3 metadata for: \(url.lastPathComponent)")

        // Use NSFileCoordinator for iCloud files (same as FLAC).
        //
        // The whole parse happens INSIDE the accessor. Coordinated access ends
        // the moment that block returns, and this used to return immediately
        // with a lazily-constructed AVURLAsset: every `asset.load(...)` and the
        // AVAudioFile read below then ran with no coordination at all, which is
        // exactly the window this call exists to close (a file still being
        // written, or an iCloud item being replaced under us). The accessor is
        // synchronous and the reads are not, so it is held open on a semaphore.
        // This runs on a global queue, never the cooperative pool, and
        // parseAudioFile's 30s hard timeout still bounds the whole thing.
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var coordinationError: NSError?
                let coordinator = NSFileCoordinator()
                let outcome = CoordinatedParseOutcome()

                coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { (readingURL) in
                    // Create fresh URL to avoid stale metadata
                    let freshURL = URL(fileURLWithPath: readingURL.path)
                    print("🔄 Using NSFileCoordinator for MP3: \(freshURL.lastPathComponent)")

                    // Check if file actually exists at path
                    guard FileManager.default.fileExists(atPath: freshURL.path) else {
                        outcome.result = .failure(AudioParseError.fileNotReadable)
                        return
                    }

                    let finished = DispatchSemaphore(value: 0)
                    Task.detached(priority: .utility) {
                        let metadata = await readTrackMetadata(from: freshURL)
                        outcome.result = .success(metadata)
                        finished.signal()
                    }
                    finished.wait()
                }

                // Exactly one resume on every path: Foundation runs the
                // accessor only when coordination succeeded, and populates the
                // error only when it did not.
                if let coordinationError {
                    print("❌ NSFileCoordinator error for MP3: \(coordinationError)")
                    continuation.resume(throwing: coordinationError)
                } else if let result = outcome.result {
                    continuation.resume(with: result)
                } else {
                    continuation.resume(throwing: AudioParseError.fileNotReadable)
                }
            }
        }
    }

    /// The MP3/AAC parse proper. Called from inside a coordinated read, so
    /// `url` is the reading URL Foundation handed out rather than the caller's.
    private static func readTrackMetadata(from url: URL) async -> AudioMetadata {
        let asset = AVURLAsset(url: url)

        var title: String?
        var artist: String?
        var album: String?
        var albumArtist: String?
        var trackNumber: Int?
        var discNumber: Int?
        var year: Int?
        var hasEmbeddedArt = false
        
        // Parse ID3 metadata using async API
        do {
            let commonMetadata = try await asset.load(.commonMetadata)
            let allMetadata = try await asset.load(.metadata)
            
            // Parse common metadata
            for item in commonMetadata {
                switch item.commonKey {
                case .commonKeyTitle:
                    title = try? await item.load(.stringValue)
                case .commonKeyArtist:
                    artist = try? await item.load(.stringValue)
                    print("🎤 Found artist in common metadata: \(artist ?? "nil")")
                case .commonKeyAlbumName:
                    album = try? await item.load(.stringValue)
                case .commonKeyCreationDate:
                    if let dateString = try? await item.load(.stringValue) {
                        year = Int(String(dateString.prefix(4)))
                    }
                case .commonKeyArtwork:
                    hasEmbeddedArt = true
                default:
                    break
                }

                if trackNumber == nil, item.commonKey?.rawValue == "trackNumber" {
                    trackNumber = await extractTrackOrDiscNumber(from: item)
                }

                if discNumber == nil, item.commonKey?.rawValue == "discNumber" {
                    discNumber = await extractTrackOrDiscNumber(from: item)
                }
            }
            
            // Check for additional ID3 tags
            for metadata in allMetadata {
                if let key = metadata.commonKey?.rawValue {
                    switch key {
                    case "albumArtist":
                        albumArtist = try? await metadata.load(.stringValue)
                    case "artist":
                        // Additional check for artist in common key
                        if artist == nil {
                            artist = try? await metadata.load(.stringValue)
                            print("🎤 Found artist in additional common key: \(artist ?? "nil")")
                        }
                    case "trackNumber":
                        if trackNumber == nil {
                            trackNumber = await extractTrackOrDiscNumber(from: metadata)
                        }
                    case "discNumber":
                        if discNumber == nil {
                            discNumber = await extractTrackOrDiscNumber(from: metadata)
                        }
                    default:
                        break
                    }
                } else if let identifier = metadata.identifier {
                    print("🔍 Checking ID3 tag: \(identifier.rawValue)")
                    switch identifier.rawValue {
                    case "id3/TRCK":
                        if trackNumber == nil {
                            trackNumber = await extractTrackOrDiscNumber(from: metadata)
                        }
                    case "id3/TPOS":
                        if discNumber == nil {
                            discNumber = await extractTrackOrDiscNumber(from: metadata)
                        }
                    case "id3/TPE2":
                        albumArtist = try? await metadata.load(.stringValue)
                        print("🎤 Found album artist in TPE2: \(albumArtist ?? "nil")")
                    case "id3/TPE1":
                        // Fallback for main artist if not found in common metadata
                        if artist == nil {
                            artist = try? await metadata.load(.stringValue)
                            print("🎤 Found artist in TPE1: \(artist ?? "nil")")
                        }
                    // Add more ID3 artist tag variations
                    case "id3/TIT2":
                        // Title fallback
                        if title == nil {
                            title = try? await metadata.load(.stringValue)
                        }
                    case "id3/TALB":
                        // Album fallback
                        if album == nil {
                            album = try? await metadata.load(.stringValue)
                        }
                    default:
                        let identifierValue = identifier.rawValue.lowercased()

                        // Handle MP4/iTunes metadata identifiers (e.g. trkn/disk)
                        if trackNumber == nil &&
                            (identifierValue.contains("trkn") || identifierValue.contains("tracknumber")) {
                            trackNumber = await extractTrackOrDiscNumber(from: metadata)
                        }

                        if discNumber == nil &&
                            (identifierValue.contains("disk") || identifierValue.contains("discnumber")) {
                            discNumber = await extractTrackOrDiscNumber(from: metadata)
                        }

                        // Debug: log unhandled tags that might contain artist info
                        if identifier.rawValue.contains("ART") || identifier.rawValue.contains("TPE") {
                            let value = try? await metadata.load(.stringValue)
                            print("🔍 Unhandled artist-related tag \(identifier.rawValue): \(value ?? "nil")")
                        }
                        break
                    }
                }
            }
        } catch {
            print("Failed to load asset metadata: \(error)")
        }
        
        // Get actual audio format info
        var sampleRate: Int?
        var channels: Int?
        var durationMs: Int?
        
        // Use AVAudioFile to get precise format info
        do {
            let audioFile = try AVAudioFile(forReading: url)
            let format = audioFile.processingFormat
            
            sampleRate = Int(format.sampleRate)
            channels = Int(format.channelCount)
            
            // Calculate precise duration
            let totalFrames = audioFile.length
            durationMs = Int((Double(totalFrames) / format.sampleRate) * 1000)
            
        } catch {
            // Fallback to AVAsset for duration if AVAudioFile fails
            do {
                let duration = try await asset.load(.duration)
                if duration.isValid && !duration.isIndefinite {
                    durationMs = Int(CMTimeGetSeconds(duration) * 1000)
                }
            } catch {
                print("Failed to load duration: \(error)")
            }
            
            // Use reasonable defaults for format if we can't determine
            sampleRate = sampleRate ?? 44100
            channels = channels ?? 2
        }
        
        // Fallback to filename parsing if no metadata found
        if title == nil {
            let fileName = url.deletingPathExtension().lastPathComponent
            let components = fileName.components(separatedBy: " - ")
            
            if components.count >= 2 {
                artist = artist ?? components[0].trimmingCharacters(in: .whitespaces)
                title = components[1].trimmingCharacters(in: .whitespaces)
            } else {
                title = fileName
            }
        }
        
        print("🎵 Final MP3 metadata for \(url.lastPathComponent):")
        print("   Title: \(title ?? "nil")")
        print("   Artist: \(artist ?? "nil")")
        print("   Album: \(album ?? "nil")")
        print("   Album Artist: \(albumArtist ?? "nil")")
        
        return AudioMetadata(
            title: title,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            trackNumber: trackNumber,
            discNumber: discNumber,
            year: year,
            durationMs: durationMs,
            sampleRate: sampleRate,
            bitDepth: nil, // MP3 is lossy, bit depth doesn't apply
            channels: channels,
            replaygainTrackGain: nil,
            replaygainAlbumGain: nil,
            replaygainTrackPeak: nil,
            replaygainAlbumPeak: nil,
            hasEmbeddedArt: hasEmbeddedArt
        )
    }

    private static func parseWavMetadataSync(from url: URL) async throws -> AudioMetadata {
        print("📖 Reading WAV metadata for: \(url.lastPathComponent)")

        // For WAV files, use AVAudioFile to get format info and try AVAsset for metadata
        var sampleRate: Int?
        var channels: Int?
        var bitDepth: Int?
        var durationMs: Int?
        var title: String?
        var artist: String?
        var album: String?
        var albumArtist: String?
        var trackNumber: Int?
        var discNumber: Int?
        var year: Int?
        var hasEmbeddedArt = false

        // Get audio format info
        do {
            let audioFile = try AVAudioFile(forReading: url)
            let format = audioFile.processingFormat

            sampleRate = Int(format.sampleRate)
            channels = Int(format.channelCount)

            // Calculate duration
            let totalFrames = audioFile.length
            durationMs = Int((Double(totalFrames) / format.sampleRate) * 1000)

            // Try to get bit depth from format settings
            if let settings = audioFile.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int {
                bitDepth = settings
            }
        } catch {
            print("⚠️ Failed to read WAV audio format: \(error)")
        }

        // Try to get metadata from AVAsset (some WAV files may have ID3 tags or other metadata)
        do {
            let asset = AVURLAsset(url: url)
            let commonMetadata = try await asset.load(.commonMetadata)

            for item in commonMetadata {
                switch item.commonKey {
                case .commonKeyTitle:
                    title = try? await item.load(.stringValue)
                case .commonKeyArtist:
                    artist = try? await item.load(.stringValue)
                case .commonKeyAlbumName:
                    album = try? await item.load(.stringValue)
                case .commonKeyCreationDate:
                    if let dateString = try? await item.load(.stringValue) {
                        year = Int(String(dateString.prefix(4)))
                    }
                case .commonKeyArtwork:
                    hasEmbeddedArt = true
                default:
                    break
                }
            }
        } catch {
            print("⚠️ Failed to read WAV metadata: \(error)")
        }

        // Fallback to filename parsing if no metadata found
        if title == nil {
            let fileName = url.deletingPathExtension().lastPathComponent
            let components = fileName.components(separatedBy: " - ")

            if components.count >= 2 {
                artist = artist ?? components[0].trimmingCharacters(in: .whitespaces)
                title = components[1].trimmingCharacters(in: .whitespaces)
            } else {
                title = fileName
            }
        }

        // Default values for WAV
        sampleRate = sampleRate ?? 44100
        channels = channels ?? 2
        bitDepth = bitDepth ?? 16

        print("🎵 Final WAV metadata for \(url.lastPathComponent):")
        print("   Title: \(title ?? "nil")")
        print("   Artist: \(artist ?? "nil")")
        print("   Sample Rate: \(sampleRate ?? 0) Hz")
        print("   Channels: \(channels ?? 0)")
        print("   Bit Depth: \(bitDepth ?? 0)")

        return AudioMetadata(
            title: title,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            trackNumber: trackNumber,
            discNumber: discNumber,
            year: year,
            durationMs: durationMs,
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            channels: channels,
            replaygainTrackGain: nil,
            replaygainAlbumGain: nil,
            replaygainTrackPeak: nil,
            replaygainAlbumPeak: nil,
            hasEmbeddedArt: hasEmbeddedArt
        )
    }

    // MARK: - New Format Support Methods

    // Unified parser for native formats (routes to existing parsers)
    private static func parseNativeFormat(_ url: URL) async throws -> AudioMetadata {
        let ext = url.pathExtension.lowercased()

        switch ext {
        case "flac":
            return try await parseFlacMetadataSync(from: url)
        case "mp3":
            return try await parseMp3MetadataSync(from: url)
        case "wav":
            return try await parseWavMetadataSync(from: url)
        case "aac":
            return try await parseAacMetadata(url)
        default:
            throw AudioParseError.unsupportedFormat
        }
    }

    /// Whether an M4A file holds an Opus stream rather than AAC.
    ///
    /// One implementation, in `PlaybackRouter`: this answer decides both how a
    /// file is routed for playback and - through `AudioParseError`
    /// `.unplayableFormat` - whether its row is deleted from the library, so
    /// the two must never be able to disagree.
    static func isOpusInM4A(_ url: URL) -> Bool {
        PlaybackRouter.isOpusInM4A(url)
    }

    // Parse AAC metadata using native AVFoundation
    private static func parseAacMetadata(_ url: URL) async throws -> AudioMetadata {
        print("📖 Reading AAC metadata for: \(url.lastPathComponent)")

        // Use similar logic to MP3 parsing since AAC can have similar metadata
        return try await parseMp3MetadataSync(from: url)
    }

    /// Reads real tags for Opus/Vorbis, falling back to the filename parser
    /// only when metadata extraction fails but the playback decoder still opens.
    ///
    /// These formats used to go straight to parseBasicMetadata, which does
    /// nothing but split the filename on " - ": every Opus/Ogg track in the
    /// library lost its album, track number, disc number, year and ReplayGain,
    /// and was stored with a zero duration, sample rate and channel count - so
    /// they all piled into "Unknown Album" in arbitrary order showing 0:00.
    /// parseSFBAudioFile already extracted all of it correctly and had no
    /// callers anywhere. parseAudioFile still bounds this with its 30s timeout.
    private static func parseOpusOrVorbis(_ url: URL) async throws -> AudioMetadata {
        do {
            return try await parseSFBAudioFile(url)
        } catch {
            let metadataError = error
            print("⚠️ SFBAudioEngine metadata failed for \(url.lastPathComponent) - falling back to filename parsing: \(metadataError)")
            try Task.checkCancellation()

            // Metadata can be unreadable even when the audio stream is fine,
            // which is the case the filename fallback is meant to preserve.
            // Only use that fallback after proving the playback decoder can
            // open the stream. A failed second open is not proof that the file
            // is permanently unplayable: file protection, an in-progress
            // replacement, or a transient provider failure makes both reads
            // fail for the same reason. Preserve any existing library row and
            // its user data by reporting an ordinary scan failure instead of
            // promoting this ambiguous result to `.unplayableFormat`.
            guard canOpenSFBAudioDecoder(for: url) else {
                print("⚠️ Audio stream could not be validated; preserving any existing library row: \(url.lastPathComponent)")
                throw metadataError
            }

            try Task.checkCancellation()
            return try await parseBasicMetadata(url, format: "Opus/Vorbis")
        }
    }

    /// Validates the playback decoder before allowing graceful tag fallback.
    private static func canOpenSFBAudioDecoder(for url: URL) -> Bool {
        do {
            let decoder = try SFBAudioEngine.AudioDecoder(url: url)
            try decoder.open()
            defer { try? decoder.close() }
            return decoder.processingFormat.sampleRate > 0
                && decoder.processingFormat.channelCount > 0
        } catch {
            print("⚠️ Decoder validation failed for \(url.lastPathComponent): \(error)")
            return false
        }
    }

    // Parse using SFBAudioEngine for Opus, Vorbis, etc.
    private static func parseSFBAudioFile(_ url: URL) async throws -> AudioMetadata {
        print("📖 Reading SFBAudioEngine metadata for: \(url.lastPathComponent)")

        do {
            // Create SFBAudioFile for metadata extraction
            let audioFile = try SFBAudioEngine.AudioFile(readingPropertiesAndMetadataFrom: url)

            // Extract basic properties
            let properties = audioFile.properties
            let metadata = audioFile.metadata

            let durationSeconds = properties.duration ?? 0
            let sampleRate = Int(properties.sampleRate ?? 0)
            let channels = Int(properties.channelCount ?? 0)
            let bitDepth = 0  // BitDepth not directly available from AudioProperties

            // Extract metadata
            let title = metadata.title
            let artist = metadata.artist
            let album = metadata.albumTitle
            let albumArtist = metadata.albumArtist
            let trackNumber = metadata.trackNumber
            let discNumber = metadata.discNumber
            let year = metadata.releaseDate?.components(separatedBy: "-").first.flatMap { Int($0) }

            print("🎵 SFBAudioEngine metadata for \(url.lastPathComponent):")
            print("   Title: \(title ?? "nil")")
            print("   Artist: \(artist ?? "nil")")
            print("   Sample Rate: \(sampleRate) Hz")
            print("   Channels: \(channels)")
            print("   Duration: \(durationSeconds) seconds")

            return AudioMetadata(
                title: title,
                artist: artist,
                album: album,
                albumArtist: albumArtist,
                trackNumber: trackNumber,
                discNumber: discNumber,
                year: year,
                durationMs: Int(durationSeconds * 1000),
                sampleRate: sampleRate,
                bitDepth: bitDepth > 0 ? bitDepth : nil,
                channels: channels,
                replaygainTrackGain: metadata.replayGainTrackGain,
                replaygainAlbumGain: metadata.replayGainAlbumGain,
                replaygainTrackPeak: metadata.replayGainTrackPeak,
                replaygainAlbumPeak: metadata.replayGainAlbumPeak,
                hasEmbeddedArt: await checkForEmbeddedArtwork(url: url)  // Check for embedded artwork in SFBAudioEngine files
            )

        } catch {
            print("❌ SFBAudioEngine parsing failed: \(error)")
            throw AudioParseError.invalidFile
        }
    }

    // Simple artwork detection for supported formats
    private static func checkForEmbeddedArtwork(url: URL) async -> Bool {
        do {
            // The Ogg/Vorbis picture field is part of the comment header, and
            // the DSD checks below were already bounded to this same range.
            // Read only that prefix instead of mapping and paging through an
            // entire song for one marker. FileHandle also keeps the operation
            // bounded when a scan timeout cancels its surrounding task.
            let maximumHeaderBytes = 1_048_576
            let fileHandle = try FileHandle(forReadingFrom: url)
            defer { try? fileHandle.close() }
            let data = try fileHandle.read(upToCount: maximumHeaderBytes) ?? Data()
            let ext = url.pathExtension.lowercased()

            // Common image format signatures
            let jpegSignature = Data([0xFF, 0xD8, 0xFF])
            let pngSignature = Data([0x89, 0x50, 0x4E, 0x47])

            if ext == "opus" || ext == "ogg" || ext == "oga" {
                // OGG/Opus files use Vorbis Comments with base64-encoded METADATA_BLOCK_PICTURE
                // Search for "METADATA_BLOCK_PICTURE=" tag
                if let pictureTag = "METADATA_BLOCK_PICTURE=".data(using: .utf8),
                   data.range(of: pictureTag) != nil {
                    return true
                }
                return false
            } else if ext == "dsf" {
                // DSF files: artwork is typically stored after the format chunk
                // DSF signature: "DSD " (44 53 44 20)
                let dsfSignature = Data([0x44, 0x53, 0x44, 0x20])
                if data.starts(with: dsfSignature) {
                    // Search for image signatures in the file (DSF can contain embedded artwork)
                    let searchRange = 0..<data.count
                    return data.range(of: jpegSignature, in: searchRange) != nil ||
                           data.range(of: pngSignature, in: searchRange) != nil
                }
            } else if ext == "dff" {
                // DSDIFF files: look for ID3v2 tags or artwork chunks
                // DSDIFF signature: "FRM8" + "DSD "
                if data.count >= 12 {
                    let frm8Signature = Data([0x46, 0x52, 0x4D, 0x38]) // "FRM8"
                    let dsdSignature = Data([0x44, 0x53, 0x44, 0x20])   // "DSD "

                    if data.starts(with: frm8Signature) &&
                       data.subdata(in: 8..<12) == dsdSignature {
                        // Search for image signatures in DSDIFF file
                        let searchRange = 0..<data.count
                        return data.range(of: jpegSignature, in: searchRange) != nil ||
                               data.range(of: pngSignature, in: searchRange) != nil
                    }
                }
            }

            return false
        } catch {
            print("⚠️ Artwork detection failed for \(url.lastPathComponent): \(error)")
            return false
        }
    }

    // Parse basic metadata from filename (for SFBAudioEngine formats to avoid hangs)
    private static func parseBasicMetadata(_ url: URL, format: String) async throws -> AudioMetadata {
        print("📖 Reading basic metadata for \(format): \(url.lastPathComponent)")

        // Use filename parsing for all SFBAudioEngine formats
        let filename = url.deletingPathExtension().lastPathComponent
        var title = filename
        var artist: String? = nil

        // Try to parse "Artist - Title" format
        let components = filename.components(separatedBy: " - ")
        if components.count >= 2 {
            artist = components[0].trimmingCharacters(in: .whitespaces)
            title = components.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
        }

        // Basic properties - don't assume sample rate as it's crucial for timing
        let ext = url.pathExtension.lowercased()
        let sampleRate = 0      // Unknown - will be determined by audio engine during playback
        let channels = 0        // Unknown - will be determined during playback
        var bitDepth: Int? = nil

        switch ext {
        case "opus", "ogg", "oga", "m4a":
            bitDepth = nil      // Lossy format
        default:
            break
        }

        // Check for embedded artwork in supported formats
        var hasEmbeddedArt = false
        if ext == "opus" || ext == "ogg" || ext == "oga" {
            // These formats can have embedded artwork, check with basic methods
            hasEmbeddedArt = await checkForEmbeddedArtwork(url: url)
        }

        print("🎵 Basic metadata for \(url.lastPathComponent):")
        print("   Title: \(title)")
        print("   Artist: \(artist ?? "Unknown")")
        print("   Format: \(format)")
        print("   Sample Rate: Unknown (will be detected during playback)")
        print("   Has Artwork: \(hasEmbeddedArt)")

        return AudioMetadata(
            title: title,
            artist: artist,
            album: nil,
            albumArtist: artist,
            trackNumber: nil,
            discNumber: nil,
            year: nil,
            durationMs: 0,  // Duration will be calculated during playback
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            channels: channels,
            replaygainTrackGain: nil,
            replaygainAlbumGain: nil,
            replaygainTrackPeak: nil,
            replaygainAlbumPeak: nil,
            hasEmbeddedArt: hasEmbeddedArt
        )
    }

    // Parse DSD metadata with proper ID3v2 tag extraction from DSF files
    private static func parseDSDBasicMetadata(_ url: URL) async throws -> AudioMetadata {
        print("📖 Reading DSD metadata with ID3v2 extraction for: \(url.lastPathComponent)")

        // Try the real tag reader first. TagLib (via SFBAudioEngine) handles
        // both DSF and DSDIFF, including the duration, sample rate and channel
        // count the hand-rolled path below never produced.
        //
        // Without this every DSD row landed in the library with filename-only
        // tags at 0:00: the ID3 extractor was reached only for .dsf, and it
        // bails out above 50MB - which a stereo DSD64 track passes after about
        // 70 seconds, so in practice it never ran on a real song either.
        if let tagged = try? await parseSFBAudioFile(url),
           (tagged.durationMs ?? 0) > 0 || (tagged.sampleRate ?? 0) > 0 || tagged.title != nil {
            print("✅ Read DSD tags with TagLib: \(url.lastPathComponent)")
            return AudioMetadata(
                title: tagged.title,
                artist: tagged.artist,
                album: tagged.album,
                albumArtist: tagged.albumArtist,
                trackNumber: tagged.trackNumber,
                discNumber: tagged.discNumber,
                year: tagged.year,
                durationMs: tagged.durationMs,
                sampleRate: tagged.sampleRate,
                bitDepth: 1,  // DSD is always 1-bit; TagLib does not report it
                channels: tagged.channels,
                replaygainTrackGain: tagged.replaygainTrackGain,
                replaygainAlbumGain: tagged.replaygainAlbumGain,
                replaygainTrackPeak: tagged.replaygainTrackPeak,
                replaygainAlbumPeak: tagged.replaygainAlbumPeak,
                hasEmbeddedArt: tagged.hasEmbeddedArt
            )
        }
        print("⚠️ TagLib could not read DSD tags - falling back to the ID3/filename path: \(url.lastPathComponent)")

        var title: String?
        var artist: String?
        var album: String?
        var albumArtist: String?
        var trackNumber: Int?
        var discNumber: Int?
        var year: Int?
        var hasEmbeddedArt = false
        var sampleRate = 0
        var channels = 0
        let bitDepth = 1  // DSD is always 1-bit

        // Try to extract metadata from DSF file
        if url.pathExtension.lowercased() == "dsf" {
            do {
                let metadata = try await extractDSFMetadata(from: url)
                title = metadata.title
                artist = metadata.artist
                album = metadata.album
                albumArtist = metadata.albumArtist
                trackNumber = metadata.trackNumber
                discNumber = metadata.discNumber
                year = metadata.year
                hasEmbeddedArt = metadata.hasEmbeddedArt
                sampleRate = metadata.sampleRate
                channels = metadata.channels
                print("✅ Successfully extracted DSF metadata for: \(url.lastPathComponent)")
            } catch {
                print("⚠️ Failed to extract DSF metadata, falling back to filename parsing: \(error)")
            }
        }

        // Fallback to filename parsing if metadata extraction failed
        if title == nil {
            let filename = url.deletingPathExtension().lastPathComponent
            title = filename

            // Try to parse "Artist - Title" format
            let components = filename.components(separatedBy: " - ")
            if components.count >= 2 {
                artist = components[0].trimmingCharacters(in: .whitespaces)
                title = components.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
            }
        }

        // Check for embedded artwork if not already determined
        if !hasEmbeddedArt {
            hasEmbeddedArt = await checkForEmbeddedArtwork(url: url)
        }

        print("🎵 DSD metadata for \(url.lastPathComponent):")
        print("   Title: \(title ?? "Unknown")")
        print("   Artist: \(artist ?? "Unknown")")
        print("   Album: \(album ?? "Unknown")")
        print("   Track: \(trackNumber?.description ?? "Unknown")")
        print("   Sample Rate: \(sampleRate > 0 ? "\(sampleRate) Hz" : "Unknown")")
        print("   Channels: \(channels > 0 ? "\(channels)" : "Unknown")")
        print("   Has Artwork: \(hasEmbeddedArt)")

        return AudioMetadata(
            title: title,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            trackNumber: trackNumber,
            discNumber: discNumber,
            year: year,
            durationMs: 0,  // Duration will be calculated during playback
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            channels: channels,
            replaygainTrackGain: nil,
            replaygainAlbumGain: nil,
            replaygainTrackPeak: nil,
            replaygainAlbumPeak: nil,
            hasEmbeddedArt: hasEmbeddedArt
        )
    }

    // Extract metadata from DSF file using DSF format specification and ID3v2 tags
    private static func extractDSFMetadata(from url: URL) async throws -> (title: String?, artist: String?, album: String?, albumArtist: String?, trackNumber: Int?, discNumber: Int?, year: Int?, hasEmbeddedArt: Bool, sampleRate: Int, channels: Int) {

        // Add memory safety check - avoid large file loading during startup if low memory
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if fileSize > 50_000_000 { // Skip files larger than 50MB to prevent memory pressure
            print("⚠️ Skipping large DSF file during startup: \(url.lastPathComponent) (\(fileSize) bytes)")
            return (nil, nil, nil, nil, nil, nil, nil, false, 0, 0)
        }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)

        // Validate DSF signature: 'D', 'S', 'D', ' ' (includes 1 space)
        guard data.count >= 28,
              data[0] == 0x44, data[1] == 0x53, data[2] == 0x44, data[3] == 0x20 else {
            throw AudioParseError.unsupportedFormat
        }

        // Read DSF header (little-endian) with safe byte-by-byte reading
        let chunkSize = readLittleEndianUInt64(from: data, offset: 4)
        let totalFileSize = readLittleEndianUInt64(from: data, offset: 12)
        let metadataPointer = readLittleEndianUInt64(from: data, offset: 20)

        print("📊 DSF Header Analysis for \(url.lastPathComponent):")
        print("   Chunk Size: \(chunkSize)")
        print("   Total File Size: \(totalFileSize)")
        print("   Metadata Pointer: \(metadataPointer)")

        // Parse format chunk to get sample rate and channels
        var sampleRate = 0
        var channels = 0

        // Look for fmt chunk after DSD chunk (at offset 28)
        if data.count >= 52 &&
           data[28] == 0x66 && data[29] == 0x6D && data[30] == 0x74 && data[31] == 0x20 { // "fmt "

            let fmtChunkSize = readLittleEndianUInt64(from: data, offset: 32)

            if fmtChunkSize >= 52 {
                let formatVersion = readLittleEndianUInt32(from: data, offset: 40)
                let formatId = readLittleEndianUInt32(from: data, offset: 44)
                let channelType = readLittleEndianUInt32(from: data, offset: 48)
                let channelNum = readLittleEndianUInt32(from: data, offset: 52)
                let sampleFrequency = readLittleEndianUInt32(from: data, offset: 56)

                sampleRate = Int(sampleFrequency)
                channels = Int(channelNum)

                print("   Format Version: \(formatVersion)")
                print("   Format ID: \(formatId)")
                print("   Channel Type: \(channelType)")
                print("   Channels: \(channels)")
                print("   Sample Rate: \(sampleRate) Hz")
            }
        }

        // Parse ID3v2 metadata if metadata pointer is valid
        var title: String?
        var artist: String?
        var album: String?
        var albumArtist: String?
        var trackNumber: Int?
        var discNumber: Int?
        var year: Int?
        var hasEmbeddedArt = false

        if metadataPointer > 0 && metadataPointer < data.count {
            let metadataOffset = Int(metadataPointer)

            // Check for ID3v2 signature at metadata pointer
            if data.count >= metadataOffset + 10 &&
               data[metadataOffset] == 0x49 && data[metadataOffset + 1] == 0x44 && data[metadataOffset + 2] == 0x33 { // "ID3"

                print("🏷️ Found ID3v2 tag at offset \(metadataOffset)")

                let id3Data = data.subdata(in: metadataOffset..<data.count)
                let parsedTags = parseID3v2Tags(from: id3Data)

                title = parsedTags.title
                artist = parsedTags.artist
                album = parsedTags.album
                albumArtist = parsedTags.albumArtist
                trackNumber = parsedTags.trackNumber
                discNumber = parsedTags.discNumber
                year = parsedTags.year
                hasEmbeddedArt = parsedTags.hasArtwork
            }
        }

        return (
            title: title,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            trackNumber: trackNumber,
            discNumber: discNumber,
            year: year,
            hasEmbeddedArt: hasEmbeddedArt,
            sampleRate: sampleRate,
            channels: channels
        )
    }

    // Parse ID3v2 tags from binary data
    private static func parseID3v2Tags(from data: Data) -> (title: String?, artist: String?, album: String?, albumArtist: String?, trackNumber: Int?, discNumber: Int?, year: Int?, hasArtwork: Bool) {

        guard data.count >= 10 else { return (nil, nil, nil, nil, nil, nil, nil, false) }

        // Read ID3v2 header
        let majorVersion = data[3]
        let revision = data[4]
        let flags = data[5]

        // Read size (synchsafe integer)
        let tagSize = Int((UInt32(data[6]) << 21) | (UInt32(data[7]) << 14) | (UInt32(data[8]) << 7) | UInt32(data[9]))

        print("🏷️ ID3v2.\(majorVersion).\(revision) tag, size: \(tagSize) bytes, flags: 0x\(String(flags, radix: 16))")

        var title: String?
        var artist: String?
        var album: String?
        var albumArtist: String?
        var trackNumber: Int?
        var discNumber: Int?
        var year: Int?
        var hasArtwork = false

        // Parse frames (starting from offset 10)
        var offset = 10
        let endOffset = min(data.count, 10 + tagSize)

        while offset < endOffset - 10 {
            // Read frame header (10 bytes for v2.3/v2.4)
            let frameId = String(data: data.subdata(in: offset..<offset+4), encoding: .ascii) ?? ""

            let frameSize: Int
            if majorVersion >= 4 {
                // ID3v2.4 uses synchsafe integers for frame size
                frameSize = Int((UInt32(data[offset+4]) << 21) | (UInt32(data[offset+5]) << 14) | (UInt32(data[offset+6]) << 7) | UInt32(data[offset+7]))
            } else {
                // ID3v2.3 uses regular 32-bit big-endian integer
                frameSize = Int((UInt32(data[offset+4]) << 24) | (UInt32(data[offset+5]) << 16) | (UInt32(data[offset+6]) << 8) | UInt32(data[offset+7]))
            }

            _ = (UInt16(data[offset+8]) << 8) | UInt16(data[offset+9])

            // Move to frame data
            offset += 10

            guard frameSize > 0 && offset + frameSize <= endOffset else {
                break
            }

            let frameData = data.subdata(in: offset..<offset+frameSize)

            // Parse frame based on ID
            switch frameId {
            case "TIT2": // Title
                title = parseTextFrame(frameData)
            case "TPE1": // Artist
                artist = parseTextFrame(frameData)
            case "TALB": // Album
                album = parseTextFrame(frameData)
            case "TPE2": // Album Artist
                albumArtist = parseTextFrame(frameData)
            case "TRCK": // Track number
                if let trackString = parseTextFrame(frameData) {
                    trackNumber = Int(trackString.components(separatedBy: "/").first ?? "")
                }
            case "TPOS": // Disc number
                if let discString = parseTextFrame(frameData) {
                    discNumber = Int(discString.components(separatedBy: "/").first ?? "")
                }
            case "TYER", "TDRC": // Year (TYER in v2.3, TDRC in v2.4)
                if let yearString = parseTextFrame(frameData) {
                    year = Int(String(yearString.prefix(4)))
                }
            case "APIC": // Attached picture
                hasArtwork = true
                print("🎨 Found embedded artwork in ID3v2 tag")
            default:
                break
            }

            offset += frameSize
        }

        print("🎵 Parsed ID3v2 metadata:")
        print("   Title: \(title ?? "nil")")
        print("   Artist: \(artist ?? "nil")")
        print("   Album: \(album ?? "nil")")
        print("   Album Artist: \(albumArtist ?? "nil")")
        print("   Track: \(trackNumber?.description ?? "nil")")
        print("   Year: \(year?.description ?? "nil")")
        print("   Has Artwork: \(hasArtwork)")

        return (title, artist, album, albumArtist, trackNumber, discNumber, year, hasArtwork)
    }

    // Parse text frame data handling different encodings
    private static func parseTextFrame(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }

        let encoding = data[0]
        let textData = data.subdata(in: 1..<data.count)

        switch encoding {
        case 0: // ISO-8859-1
            return String(data: textData, encoding: .isoLatin1)?.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
        case 1: // UTF-16 with BOM
            return String(data: textData, encoding: .utf16)?.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
        case 2: // UTF-16BE without BOM
            return String(data: textData, encoding: .utf16BigEndian)?.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
        case 3: // UTF-8
            return String(data: textData, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
        default:
            // Fallback to UTF-8
            return String(data: textData, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
        }
    }

    // Safe byte reading helpers for DSF format (little-endian)
    private static func readLittleEndianUInt64(from data: Data, offset: Int) -> UInt64 {
        guard offset >= 0 && offset + 8 <= data.count else {
            print("⚠️ Invalid byte access: offset=\(offset), dataSize=\(data.count)")
            return 0
        }

        let byte0 = UInt64(data[offset])
        let byte1 = UInt64(data[offset + 1]) << 8
        let byte2 = UInt64(data[offset + 2]) << 16
        let byte3 = UInt64(data[offset + 3]) << 24
        let byte4 = UInt64(data[offset + 4]) << 32
        let byte5 = UInt64(data[offset + 5]) << 40
        let byte6 = UInt64(data[offset + 6]) << 48
        let byte7 = UInt64(data[offset + 7]) << 56

        return byte0 | byte1 | byte2 | byte3 | byte4 | byte5 | byte6 | byte7
    }

    private static func readLittleEndianUInt32(from data: Data, offset: Int) -> UInt32 {
        guard offset >= 0 && offset + 4 <= data.count else {
            print("⚠️ Invalid byte access: offset=\(offset), dataSize=\(data.count)")
            return 0
        }

        let byte0 = UInt32(data[offset])
        let byte1 = UInt32(data[offset + 1]) << 8
        let byte2 = UInt32(data[offset + 2]) << 16
        let byte3 = UInt32(data[offset + 3]) << 24

        return byte0 | byte1 | byte2 | byte3
    }

    // Parse DSD metadata with SFBAudioEngine (DEPRECATED - causes hangs)
    private static func parseDSDMetadata(_ url: URL) async throws -> AudioMetadata {
        print("📖 Reading DSD metadata for: \(url.lastPathComponent)")

        do {
            // Create DSD decoder
            let decoder = try SFBAudioEngine.AudioDecoder(url: url)

            // Extract properties
            let sourceFormat = decoder.sourceFormat
            _ = decoder.processingFormat

            let sampleRate = Int(sourceFormat.sampleRate)
            let channels = Int(sourceFormat.channelCount)
            // Duration calculation for DSD - using properties if available
            let durationSeconds = 0.0  // Duration not directly available from AudioDecoder

            // DSD is 1-bit, but we report the effective resolution
            let bitDepth = 1

            print("🎵 DSD metadata for \(url.lastPathComponent):")
            print("   Sample Rate: \(sampleRate) Hz (DSD)")
            print("   Channels: \(channels)")
            print("   Duration: \(durationSeconds) seconds")
            print("   Format: DSD (1-bit)")

            // For DSD files, metadata is limited, so use filename parsing
            let filename = url.deletingPathExtension().lastPathComponent
            let title = filename

            return AudioMetadata(
                title: title,
                artist: nil,
                album: nil,
                albumArtist: nil,
                trackNumber: nil,
                discNumber: nil,
                year: nil,
                durationMs: Int(durationSeconds * 1000),
                sampleRate: sampleRate,
                bitDepth: bitDepth,
                channels: channels,
                replaygainTrackGain: nil,
                replaygainAlbumGain: nil,
                replaygainTrackPeak: nil,
                replaygainAlbumPeak: nil,
                hasEmbeddedArt: false
            )

        } catch {
            print("❌ DSD parsing failed: \(error)")
            throw AudioParseError.invalidFile
        }
    }
}

enum AudioParseError: Error {
    case invalidFile
    case unsupportedFormat
    case fileNotReadable
    case fileSizeError
    /// The file parses fine but nothing on this platform can decode it, so
    /// indexing it would only put a permanently unplayable row in the library.
    /// Distinct from a parse failure: callers skip the file without recording
    /// a scan failure, so the scan still completes successfully.
    case unplayableFormat
}
