//
//  FileCleanupManager.swift
//  Cosmos Music Player
//
//  Manages cleanup of iCloud files that were deleted from iCloud Drive
//

import Foundation
import SwiftUI

/// Withholds every reconciliation pass that would delete library rows until a
/// later, separate pass agrees with it.
///
/// `reconcileMissingFiles` infers deletion from a file simply not being on
/// disk, and `deleteTrack` takes the row's favourite flag and every playlist
/// entry pointing at it with no undo. That inference is sound for a file the
/// user removed, and unsound for a whole root that has not finished
/// materialising - most plausibly right after a restore from backup, where the
/// app-group database comes back at once while iCloud is still publishing
/// placeholders. `NSMetadataQueryDidFinishGathering` cannot tell those apart:
/// it reports that the query collected the results that exist *now*.
///
/// So a track is removed only once it has been absent for at least
/// `confirmationGrace`, AND no previously-absent track has come back within
/// that window. The second condition is what tells a converging container
/// (files keep reappearing) from a settled one.
///
/// This used to key the whole absent set by one signature, which was stricter
/// than either condition needs and in practice never confirmed: the scan
/// reconciliation and the orphan check look at different scopes, so each kept
/// overwriting the other's observation and resetting the clock, and deleting
/// one more file between scans did the same. Deleted songs stayed in the
/// library indefinitely. Tracking each row separately removes that coupling.
///
/// Not main-actor bound: ICloudDeletionMonitor records thousands of absences
/// at once (a stat per pending entry plus a JSON round trip), which blocked
/// the UI for seconds, so it calls in from a background task. The lock keeps
/// that and the scan path's main-actor calls from losing each other's
/// load-modify-save.
private enum RemovalConfirmationGuard {
    private static let lock = NSLock()
    private static let legacyDefaultsKey = "LibraryPendingMassRemoval"
    private static let defaultsKey = "LibraryPendingTrackRemovals"
    private static let lastReappearanceKey = "LibraryPendingRemovalLastReappearance"

    static let confirmationGrace: TimeInterval = 15 * 60
    /// How long an absence stays "pending" without being observed again.
    /// Entries used to keep their first observation for 90 days, so a file
    /// that went missing once and was then briefly absent again weeks later
    /// was deleted on that single new observation - the 15-minute second
    /// look was already "satisfied". Past this window the next absence
    /// starts a fresh observation instead. Not shorter: passes run with
    /// scans, which are normally a day apart, and two consecutive daily
    /// scans must still be able to confirm a real deletion.
    private static let observationWindow: TimeInterval = 36 * 60 * 60

    private struct Pending: Codable {
        var path: String
        var firstObservedAt: Date
        /// Most recent pass that found it absent. Optional: entries saved
        /// before this field existed decode with nil and fall back to
        /// `firstObservedAt`.
        var lastObservedAt: Date?

        var lastSeenAbsent: Date { lastObservedAt ?? firstObservedAt }
    }

    /// Records this pass's absent tracks and returns those that may be
    /// deleted now.
    static func confirmedRemovals(among absentTracks: [Track]) -> Set<String> {
        let absentIds = Set(absentTracks.map(\.stableId))
        // The stat per pending entry happens outside the lock: thousands of
        // them (or one slow provider) kept the scan path's main-actor calls
        // waiting behind the monitor's background pass. An entry added
        // meanwhile is simply not checked for reappearance until next time.
        let toStat: [(stableId: String, path: String)] = lock.withLock {
            load().compactMap { absentIds.contains($0.key) ? nil : ($0.key, $0.value.path) }
        }
        let reappearedIds = Set(toStat.filter { FileManager.default.fileExists(atPath: $0.path) }.map(\.stableId))

        lock.lock()
        defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)

        let now = Date()
        var pending = load()

        var sawReappearance = false
        for (stableId, entry) in pending where !absentIds.contains(stableId) {
            if reappearedIds.contains(stableId) {
                pending[stableId] = nil
                sawReappearance = true
            } else if now.timeIntervalSince(entry.lastSeenAbsent) > observationWindow {
                // Also covers rows deleted by some other route.
                pending[stableId] = nil
            }
        }
        if sawReappearance {
            UserDefaults.standard.set(now, forKey: lastReappearanceKey)
        }

        for track in absentTracks {
            if var entry = pending[track.stableId],
               now.timeIntervalSince(entry.lastSeenAbsent) <= observationWindow {
                entry.lastObservedAt = now
                pending[track.stableId] = entry
            } else {
                pending[track.stableId] = Pending(path: track.path, firstObservedAt: now, lastObservedAt: now)
            }
        }
        save(pending)

        guard !absentTracks.isEmpty else { return [] }

        if let lastReappearance = UserDefaults.standard.object(forKey: lastReappearanceKey) as? Date {
            let quietFor = now.timeIntervalSince(lastReappearance)
            guard quietFor >= confirmationGrace else {
                print("""
                    🛡️ Withholding removal of \(absentTracks.count) track(s) - \
                    missing files were still reappearing \(Int(quietFor))s ago
                    """)
                return []
            }
        }

        let confirmed = Set(absentTracks.compactMap { track -> String? in
            guard let entry = pending[track.stableId],
                  now.timeIntervalSince(entry.firstObservedAt) >= confirmationGrace else {
                return nil
            }
            return track.stableId
        })

        let withheld = absentTracks.count - confirmed.count
        if withheld > 0 {
            print("""
                🛡️ Withholding removal of \(withheld) track(s) - \
                a later scan must still find them missing after \(Int(confirmationGrace))s
                """)
        }
        if !confirmed.isEmpty {
            print("🧹 Removal of \(confirmed.count) track(s) confirmed by an earlier scan - proceeding")
        }
        return confirmed
    }

    /// When a previously-absent file was last seen coming back, if ever.
    static var lastReappearance: Date? {
        UserDefaults.standard.object(forKey: lastReappearanceKey) as? Date
    }

    /// Lets the fast path (ICloudDeletionMonitor) report a reappearance, so
    /// the scan path backs off too.
    static func noteReappearance() {
        lock.lock()
        defer { lock.unlock() }
        UserDefaults.standard.set(Date(), forKey: lastReappearanceKey)
    }

    /// Drops entries for rows that no longer exist, or whose absence was seen
    /// while that absence proved nothing (see ICloudDeletionMonitor's
    /// untrusted listings).
    static func forget(_ stableIds: [String]) {
        guard !stableIds.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var pending = load()
        let before = pending.count
        for stableId in stableIds { pending[stableId] = nil }
        guard pending.count != before else { return }
        save(pending)
    }

    private static func load() -> [String: Pending] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: Pending].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func save(_ pending: [String: Pending]) {
        if pending.isEmpty {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(pending) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

@MainActor
class FileCleanupManager: ObservableObject {
    static let shared = FileCleanupManager()

    private enum ExternalFileAccessibility {
        case accessible
        case confirmedMissing
        case temporarilyUnavailable
    }
    
    
    private let databaseManager = DatabaseManager.shared
    private let stateManager = StateManager.shared
    /// Second looks at linked folders' former locations, by former path.
    private var formerPathRechecks: [String: Task<Void, Never>] = [:]
    /// Former-location looks that fell due in the background, with their
    /// folder and attempt number; run on the next foreground.
    private var parkedFormerPathRechecks: [String: (folderId: UUID, attempt: Int)] = [:]
    /// Second looks at linked folders' missing songs, by folder, and the
    /// rows each is for.
    private var linkedFolderRechecks: [UUID: Task<Void, Never>] = [:]
    private var linkedFolderRecheckIds: [UUID: Set<String>] = [:]
    /// Linked-folder looks that fell due in the background, with their
    /// attempt number; run on the next foreground.
    private var parkedLinkedFolderRechecks: [UUID: Int] = [:]
    private var foregroundObserver: NSObjectProtocol?
    private static let maxLinkedFolderRechecks = 3
    
    private init() {}

    /// Reconciles only roots that the indexer successfully enumerated during
    /// this scan. This avoids treating an iCloud/authentication failure as an
    /// empty library while still removing files that were genuinely deleted.
    func reconcileMissingFiles(in successfullyScannedRoots: [URL]) async {
        let roots = successfullyScannedRoots.map(\.standardizedFileURL)
        guard !roots.isEmpty else { return }

        do {
            let tracks = try databaseManager.getAllTracks()
            let tracksUnderScannedRoots = tracks.filter { track in
                let trackURL = URL(fileURLWithPath: track.path).standardizedFileURL
                return roots.contains { isURL(trackURL, inside: $0) }
            }
            let absentTracks = tracksUnderScannedRoots.filter { track in
                let trackURL = URL(fileURLWithPath: track.path).standardizedFileURL
                return !FileManager.default.fileExists(atPath: trackURL.path)
            }

            guard !absentTracks.isEmpty else {
                // Still recorded: this is how the guard sees earlier absences
                // reappear, i.e. that the container is converging.
                _ = RemovalConfirmationGuard.confirmedRemovals(among: [])
                print("🧹 Scan reconciliation found no deleted files")
                return
            }

            // A clean walk of the root does not prove every nested provider
            // directory was materialised. A deletion leaves the nearest
            // surviving folder inside the root readable - the immediate
            // parent for a single file, a higher one for a deleted album
            // folder; an unavailable/unmounted subtree does not. Preserve the
            // latter until accessibility is authoritative.
            let missingTracks = absentTracks.filter {
                databaseManager.isPathConfirmedMissing($0.path, within: roots)
            }
            let temporarilyUnavailableCount = absentTracks.count - missingTracks.count
            if temporarilyUnavailableCount > 0 {
                print("🧹 🛡️ Preserving \(temporarilyUnavailableCount) track(s) whose parent directory is unavailable")
            }
            guard !missingTracks.isEmpty else { return }

            // Every absence set has to be confirmed by a later pass before any
            // relationship data is destroyed. Count/fraction thresholds cannot
            // distinguish a real deletion from partially published iCloud data.
            // Linked folders get their own version of the mass rule (and an
            // iCloud placeholder check): the app container's does not see them.
            let (settledTracks, heldLinkedIds) = await withholdingUnsettledLinkedFolderAbsence(
                missingTracks,
                absentTracks: absentTracks
            )
            let judgedTracks = withholdingMassICloudAbsence(settledTracks)
            let confirmedIds = RemovalConfirmationGuard.confirmedRemovals(among: judgedTracks)
            let confirmedTracks = judgedTracks.filter { confirmedIds.contains($0.stableId) }
            // Withheld rows used to wait for another scan 15 min - 36 h later,
            // which daily/weekly/manual scan settings rarely produce: the
            // entry expired and the ghost stayed for ever. The monitor takes
            // that second look itself - it puts plain absences through this
            // same guard (see confirmedAbsences), so this is not a way
            // around it. It only judges Documents and iCloud, though: songs
            // in a linked folder get their second look here - except those
            // held as unsettled, which only a later scan's walk can clear.
            let withheldTracks = missingTracks.filter {
                !confirmedIds.contains($0.stableId) && !heldLinkedIds.contains($0.stableId)
            }
            var monitorPaths: [String] = []
            var linkedWithheld: [UUID: [String]] = [:]
            for track in withheldTracks {
                if let folder = LinkedFolderStore.shared.folder(containing: track.path) {
                    linkedWithheld[folder.id, default: []].append(track.stableId)
                } else {
                    monitorPaths.append(track.path)
                }
            }
            ICloudDeletionMonitor.shared.consider(paths: monitorPaths)
            for (folderId, stableIds) in linkedWithheld {
                scheduleLinkedFolderRecheck(folderId: folderId, stableIds: stableIds)
            }
            guard !confirmedTracks.isEmpty else { return }

            print("🧹 Scan reconciliation removing \(confirmedTracks.count) deleted track(s)")
            var removedIds: [String] = []
            for track in confirmedTracks {
                // The guard and the hand-offs above awaited: a file that came
                // back meanwhile (or its iCloud placeholder) keeps its row.
                guard Self.isAbsentWithoutPlaceholder(track.path) else { continue }
                do {
                    // Parent readability above established that this absence is
                    // authoritative. Give a newly-indexed row one conservative
                    // chance to inherit this row's favourites and playlist
                    // entries before deleteTrack removes them. This is what
                    // makes whole-folder renames as safe as single-file renames.
                    let relocationResult = try databaseManager.preserveReferencesForAuthoritativelyMissingTrack(
                        track,
                        within: roots
                    )
                    if case .ambiguous = relocationResult {
                        // The file is gone, but choosing the wrong surviving
                        // duplicate would be as destructive as dropping the
                        // references. Preserve the row until a later scan has
                        // an unambiguous answer.
                        print("🧹 🛡️ Preserving ambiguously relocated track: \(track.title)")
                        continue
                    }
                    try await databaseManager.deleteTrack(byStableId: track.stableId)
                    removedIds.append(track.stableId)
                    await deleteArtworkCache(for: track.stableId)
                    print("🧹 Removed missing track: \(track.title)")
                } catch {
                    print("🧹 Failed to remove missing track \(track.title): \(error)")
                }
            }
            RemovalConfirmationGuard.forget(removedIds)

            if removedIds.isEmpty {
                NotificationCenter.default.post(
                    name: NSNotification.Name("LibraryNeedsRefresh"),
                    object: nil
                )
            } else {
                notifyTracksRemoved()
            }
        } catch {
            print("🧹 Scan reconciliation failed: \(error)")
        }
    }
    
    /// Hands files the live iCloud query reported as removed to
    /// ICloudDeletionMonitor.
    ///
    /// Before the live query existed, deletions made in iCloud Drive while
    /// the app was open were only noticed by two full scans at least
    /// `confirmationGrace` apart. This used to delete on the single removal
    /// event, with none of the monitor's checks (query fully gathered,
    /// iCloud metadata no longer listing the file, no missing file coming
    /// back, not most of the library, renamed copy indexed first). Routing
    /// it through the monitor keeps deletions to about a minute while
    /// requiring all of them.
    func removeTracksDeletedFromICloud(at removedURLs: [URL]) async {
        guard !removedURLs.isEmpty,
              let iCloudFolderURL = stateManager.getMusicFolderURL() else {
            return
        }
        let paths = removedURLs
            .filter { isURL($0, inside: iCloudFolderURL) }
            .map(\.path)
        guard !paths.isEmpty else { return }
        print("🧹 iCloud reported \(paths.count) removed file(s) - handing to the deletion monitor")
        ICloudDeletionMonitor.shared.consider(paths: paths, isRemovalEvent: true)
    }

    /// - Parameter incompleteRoots: roots the last scan could only partly
    ///   enumerate. A root that fails the same way on every scan no longer
    ///   blocks this whole pass (which left every deletion in the library for
    ///   good); the tracks under it are simply not judged.
    func checkForOrphanedFiles(skippingIncompleteRoots incompleteRoots: [URL] = []) async {
        print("🧹 Checking for library files that no longer exist...")

        let iCloudFolderURL = stateManager.getMusicFolderURL()
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        if let iCloudFolderURL {
            print("🧹 iCloud folder URL: \(iCloudFolderURL.path)")
        } else {
            print("🧹 No iCloud folder available; reconciling local and external files")
        }
        
        do {
            // Get all tracks from database
            let allTracks = try databaseManager.getAllTracks()
            print("🧹 Found \(allTracks.count) tracks in database")
            
            var nonExistentTracks: [Track] = []
            
            for track in allTracks {
                let trackURL = URL(fileURLWithPath: track.path)
                print("🧹 Checking track: \(trackURL.lastPathComponent)")
                print("🧹   Path: \(trackURL.path)")

                if incompleteRoots.contains(where: { isURL(trackURL, inside: $0) }) {
                    print("🧹 🛡️ Skipping track under a partially enumerated root: \(trackURL.lastPathComponent)")
                    continue
                }

                // Songs in a linked music folder are reconciled only by a scan
                // that walked the whole folder. Judged here they would look
                // like external files without a bookmark of their own - and a
                // folder that is unplugged, offline or waiting to be
                // reconnected would lose every one of its songs.
                if LinkedFolderStore.shared.folder(containing: track.path) != nil {
                    continue
                }

                // A restore or device migration changes the UUID in this
                // app's data-container path. Repair that identity before
                // external-file classification so legacy Opus/OGG/DSD rows
                // do not depend on metadata-based duplicate matching to keep
                // their favourites and playlist entries.
                if await rescueRelocatedApplicationFile(
                    track,
                    currentDocumentsURL: documentsURL
                ) {
                    continue
                }

                // Check if this is an internal file (iCloud/Documents) or external file
                let isInCurrentiCloudFolder = iCloudFolderURL.map {
                    isURL(trackURL, inside: $0)
                } ?? false
                let isICloudFile = isInCurrentiCloudFolder

                // iCloud paths can temporarily disappear while signed out or
                // offline. Absence is only authoritative while the container
                // is available; otherwise preserve the user's database row.
                //
                // The path check is deliberately kept for THIS guard even
                // though it is not trusted for the internal/external
                // classification below. getMusicFolderURL() returns nil in
                // exactly the situation the guard exists for - signed out, or
                // the container unavailable - so gating on
                // isInCurrentiCloudFolder alone disarmed it precisely when it
                // was needed: every ubiquitous track was then classified
                // external, failed bookmark resolution, and was pruned.
                let looksUbiquitous = isInCurrentiCloudFolder
                    || trackURL.pathComponents.contains("Mobile Documents")

                // Two independent reasons to leave a ubiquitous row alone, and
                // both are needed because the destructive path below has no
                // second chance: absence of a bookmark becomes .confirmedMissing
                // and deleteTrack takes the row's favourites and playlist
                // entries with it.
                //
                // iCloudStatus alone is not enough. It is resolved separately
                // from getMusicFolderURL(), whose first failed container lookup
                // is cached permanently by StateManager - so the status can
                // read .available while this pass still has no container URL
                // to measure the path against. That combination classifies
                // every ubiquitous track as external, and prunes it.
                //
                // Not having the container URL is exactly as good a reason to
                // do nothing as knowing iCloud is unavailable: without it,
                // nothing here can tell a deleted track from one whose
                // container simply has not resolved.
                if looksUbiquitous
                    && (iCloudFolderURL == nil || AppCoordinator.shared.iCloudStatus != .available) {
                    print("🧹 Skipping unverifiable iCloud path: \(trackURL.lastPathComponent)")
                    continue
                }

                // Only roots owned by this app are internal. A substring such
                // as "/Documents/" also appears in other app containers and
                // Files providers; classifying those as local bypasses their
                // security-scoped bookmark and can delete a valid track.
                let isInternalFile = isICloudFile || isURL(trackURL, inside: documentsURL)
                print("🧹   Is internal file: \(isInternalFile)")

                if isInternalFile {
                    // For internal files, absence is authoritative only while
                    // the nearest surviving folder inside the app's root is
                    // still readable (so a deleted album folder counts too).
                    let fileExists = FileManager.default.fileExists(atPath: trackURL.path)
                    print("🧹   Internal file exists: \(fileExists)")
                    let owningRoots = isICloudFile ? [iCloudFolderURL].compactMap { $0 } : [documentsURL]

                    if fileExists {
                        print("🧹 ✅ Internal file exists (keeping): \(trackURL.lastPathComponent)")
                    } else if databaseManager.isPathConfirmedMissing(trackURL.path, within: owningRoots) {
                        print("🧹   Internal file doesn't exist - will auto-clean from database")
                        nonExistentTracks.append(track)
                    } else {
                        print("🧹 🛡️ Internal file's parent directory is unavailable - preserving: \(trackURL.lastPathComponent)")
                    }
                } else {
                    // For external files (from share/document picker), check if still accessible
                    let accessibility = await checkExternalFileAccessibility(trackURL, stableId: track.stableId)

                    switch accessibility {
                    case .accessible:
                        print("🧹 ✅ External file still accessible (keeping): \(trackURL.lastPathComponent)")
                    case .confirmedMissing:
                        print("🧹   External file has no path or bookmark - will auto-clean from database")
                        nonExistentTracks.append(track)
                    case .temporarilyUnavailable:
                        // A document-provider bookmark can resolve while the
                        // provider is offline, yet startAccessing... returns
                        // false (or fileExists/read fails). None of those prove
                        // deletion. Preserve both the row and bookmark so the
                        // track recovers when Dropbox/SMB/etc. comes back.
                        print("🧹 🛡️ External provider unavailable - preserving track and bookmark: \(trackURL.lastPathComponent)")
                    }
                }
            }
            
            // This is a second deletion path after scan reconciliation. It
            // must honour the same removal decision: after a restore,
            // an available-but-not-yet-materialised iCloud container looks
            // exactly like deleted files here. Without this
            // gate, reconcileMissingFiles() withheld those rows and this
            // pass deleted them (plus favourites and playlist entries) 15
            // seconds later. Called even with nothing missing so the guard
            // can see earlier absences reappear.
            nonExistentTracks = withholdingMassICloudAbsence(nonExistentTracks)
            let confirmedIds = RemovalConfirmationGuard.confirmedRemovals(among: nonExistentTracks)
            // See reconcileMissingFiles: withheld rows get a prompt re-check.
            // The monitor ignores external/bookmarked rows.
            ICloudDeletionMonitor.shared.consider(
                paths: nonExistentTracks.filter { !confirmedIds.contains($0.stableId) }.map(\.path)
            )
            nonExistentTracks = nonExistentTracks.filter { confirmedIds.contains($0.stableId) }

            // Auto-clean files that don't exist anywhere
            if !nonExistentTracks.isEmpty {
                print("🧹 Auto-cleaning \(nonExistentTracks.count) files that don't exist anywhere")
                
                for track in nonExistentTracks {
                    do {
                        print("🧹 Auto-cleaning database entry for non-existent file: \(URL(fileURLWithPath: track.path).lastPathComponent)")
                        print("🧹 Auto-removing track from database: \(track.title)")
                        // Use the ID stored with the row. Re-hashing the
                        // filename was incompatible with path-based IDs and
                        // silently left deleted tracks in previous builds.
                        try await databaseManager.deleteTrack(byStableId: track.stableId)
                        RemovalConfirmationGuard.forget([track.stableId])

                        // Delete cached artwork for this track
                        await deleteArtworkCache(for: track.stableId)
                    } catch {
                        print("🧹 Error auto-cleaning file \(track.path): \(error)")
                    }
                }
                
                // Notify UI (and Spotlight/Siri) since we made database changes
                notifyTracksRemoved()
            }
            
            print("🧹 No additional cleanup needed")
            
        } catch {
            print("🧹 Error checking for orphaned files: \(error)")
        }
    }

    // MARK: - Fast-path removal (ICloudDeletionMonitor)

    var secondsSinceMissingFileReappeared: TimeInterval? {
        RemovalConfirmationGuard.lastReappearance.map { Date().timeIntervalSince($0) }
    }

    func noteMissingFileReappeared() {
        RemovalConfirmationGuard.noteReappearance()
    }

    static var removalConfirmationGrace: TimeInterval {
        RemovalConfirmationGuard.confirmationGrace
    }

    /// Records these absences with RemovalConfirmationGuard and returns the
    /// stable IDs it confirms (first seen at least `confirmationGrace` ago,
    /// nothing reappearing since). The monitor uses this for every absence
    /// iCloud did not itself report as a removal, so its fast path follows
    /// the same rule as the scan path. Callable off the main actor.
    nonisolated static func confirmedAbsences(among tracks: [Track]) -> Set<String> {
        RemovalConfirmationGuard.confirmedRemovals(among: tracks)
    }

    /// Drops the guard's observations of these rows. For absences seen while
    /// iCloud's listing proved nothing: kept, they would let the first pass
    /// after the listing recovers confirm on an hours-old "first look"
    /// instead of taking a second look of its own. Callable off the main actor.
    nonisolated static func forgetAbsences(_ stableIds: [String]) {
        RemovalConfirmationGuard.forget(stableIds)
    }

    /// Takes iCloud rows out of a scan-path removal batch when most of the
    /// iCloud library is missing at once, and forgets the guard's
    /// observations of them.
    ///
    /// After a restore with iCloud offline or sync paused, the container is
    /// readable but empty: every scan walks it "completely", finds every
    /// iCloud song absent, and a second scan 15 min later sees exactly the
    /// same thing - which the guard took as confirmation, deleting the whole
    /// iCloud library with its favourites and playlists. Nothing on disk can
    /// tell that apart from the user deleting most of their songs elsewhere,
    /// and losing the library is far worse than keeping ghosts, so such a
    /// batch is never removed here. ICloudDeletionMonitor applies the same
    /// rule; there only iCloud's own removal events can get rows of such a
    /// batch removed. Someone who really deleted more than half their iCloud
    /// songs while the app was closed keeps those rows until they remove
    /// them by hand, or until the remaining library is the larger part again.
    ///
    /// Rows iCloud reported removed this session, while its query had been
    /// listing files (see `ICloudDeletionMonitor.trustedRemovalEventPaths`),
    /// are not held: someone who moved or deleted their whole music folder
    /// while the app was open otherwise kept every song as a ghost - or as a
    /// duplicate of the moved copy - for good. They still go through the
    /// guard like any other row.
    private func withholdingMassICloudAbsence(_ tracks: [Track]) -> [Track] {
        guard let iCloudRoot = stateManager.getMusicFolderURL() else { return tracks }
        let iCloudAbsent = tracks.filter { isURL(URL(fileURLWithPath: $0.path), inside: iCloudRoot) }
        guard iCloudAbsent.count > 1,
              let total = try? databaseManager.countTracks(underPath: iCloudRoot.path),
              iCloudAbsent.count * 2 > total else {
            return tracks
        }
        let removalEvents = ICloudDeletionMonitor.shared.trustedRemovalEventPaths()
        let heldTracks = iCloudAbsent.filter { !removalEvents.contains(DatabaseManager.canonicalPath($0.path)) }
        print("""
            🧹 🛡️ \(iCloudAbsent.count)/\(total) iCloud tracks missing at once - keeping \(heldTracks.count) \
            not reported removed by iCloud
            """)
        let held = Set(heldTracks.map(\.stableId))
        RemovalConfirmationGuard.forget(Array(held))
        return tracks.filter { !held.contains($0.stableId) }
    }

    /// Takes linked-folder rows out of a scan-path removal batch when their
    /// absence proves nothing, and forgets the guard's observations of them:
    /// a song iCloud may still be bringing down (`LinkedFolderAbsence
    /// .mayStillBeSyncing`), and every missing song of a folder where too
    /// much is missing at once (`LinkedFolderAbsence.isUnsettled`). Without
    /// this a partially synced linked iCloud Drive folder - which has no
    /// iCloud listing to compare against - lost its songs after two scans.
    ///
    /// - Parameter absentTracks: every absent row the scan saw, including
    ///   those already preserved for an unreadable parent - they count
    ///   towards "too much missing".
    /// - Returns: the rows still to judge, and the stable IDs held.
    private func withholdingUnsettledLinkedFolderAbsence(
        _ tracks: [Track],
        absentTracks: [Track]
    ) async -> (kept: [Track], held: Set<String>) {
        guard !LinkedFolderStore.shared.folders.isEmpty else { return (tracks, []) }
        // A row count per folder and a stat plus resource-value reads per
        // ancestor of every missing song.
        return await Task.detached(priority: .utility) {
            Self.unsettledLinkedFolderAbsence(tracks, absentTracks: absentTracks)
        }.value
    }

    nonisolated private static func unsettledLinkedFolderAbsence(
        _ tracks: [Track],
        absentTracks: [Track]
    ) -> (kept: [Track], held: Set<String>) {
        let store = LinkedFolderStore.shared
        var absentByFolder: [UUID: (folder: LinkedFolder, ids: [String])] = [:]
        for track in absentTracks {
            guard let folder = store.folder(containing: track.path) else { continue }
            absentByFolder[folder.id, default: (folder, [])].ids.append(track.stableId)
        }
        guard !absentByFolder.isEmpty else { return (tracks, []) }

        var held: Set<String> = []
        var unsettledFolders: Set<UUID> = []
        for (id, entry) in absentByFolder {
            // Unknown counts as "all of it": nothing here can be judged then.
            guard let total = try? DatabaseManager.shared.countTracks(underPath: entry.folder.path) else {
                print("🔗 🛡️ Could not count linked folder \(entry.folder.name) - keeping its missing songs")
                unsettledFolders.insert(id)
                held.formUnion(entry.ids)
                continue
            }
            if LinkedFolderAbsence.isUnsettled(missing: entry.ids.count, total: total, folderPath: entry.folder.path) {
                print("🔗 🛡️ \(entry.ids.count)/\(total) songs of linked folder \(entry.folder.name) missing at once - keeping them all")
                unsettledFolders.insert(id)
                held.formUnion(entry.ids)
            }
        }

        let kept = tracks.filter { track in
            guard let folder = store.folder(containing: track.path) else { return true }
            if unsettledFolders.contains(folder.id) { return false }
            if LinkedFolderAbsence.mayStillBeSyncing(track.path, within: folder.path) {
                print("🔗 🛡️ Linked song may still be syncing from iCloud - keeping: \(URL(fileURLWithPath: track.path).lastPathComponent)")
                held.insert(track.stableId)
                return false
            }
            return true
        }
        // Kept, these observations would let the first pass after the folder
        // settles confirm on a stale first look instead of taking its own.
        RemovalConfirmationGuard.forget(Array(held))
        return (kept, held)
    }

    /// Removes rows ICloudDeletionMonitor has verified as deleted (see its
    /// doc comment for the evidence required). Same relocation handling as
    /// the scan path, so a renamed/moved file keeps favourites and playlists.
    @discardableResult
    func removeVerifiedMissingTracks(_ tracks: [Track], within roots: [URL]) async -> Int {
        var removedIds: [String] = []
        for track in tracks {
            do {
                // Re-check at the last moment: the verification awaited.
                guard databaseManager.isPathConfirmedMissing(track.path, within: roots) else { continue }
                let relocationResult = try databaseManager.preserveReferencesForAuthoritativelyMissingTrack(
                    track,
                    within: roots
                )
                if case .ambiguous = relocationResult {
                    print("🧹 🛡️ Preserving ambiguously relocated track: \(track.title)")
                    continue
                }
                try await databaseManager.deleteTrack(byStableId: track.stableId)
                removedIds.append(track.stableId)
                await deleteArtworkCache(for: track.stableId)
                print("🧹 Removed track whose file was deleted: \(track.title)")
            } catch {
                print("🧹 Failed to remove deleted track \(track.title): \(error)")
            }
        }
        RemovalConfirmationGuard.forget(removedIds)
        if !removedIds.isEmpty {
            notifyTracksRemoved()
        }
        return removedIds.count
    }

    // MARK: - Linked folders' former locations

    /// Removes the rows a renamed/moved linked folder left under its former
    /// location whose file is at neither place.
    ///
    /// `relocateTracks` only moves rows whose file is at the new place. The
    /// rest stayed for ever: the former path is only forgotten once no row
    /// is left under it, the orphan check skips anything a linked folder
    /// contains (former paths included), scan reconciliation only covers the
    /// folder's new location, and the deletion monitor ignores paths outside
    /// Documents/iCloud.
    ///
    /// A row goes only when its file is not at the old path (nor an iCloud
    /// placeholder for it), is confirmed missing inside the new folder - which
    /// the caller has just walked completely - and RemovalConfirmationGuard
    /// agrees, as on every other removal path. Same relocation handling as
    /// scan reconciliation, so a song also renamed inside the folder keeps
    /// its favourites and playlists. Rows whose file is still at the old path
    /// are left alone. The former path is forgotten once nothing is under it.
    ///
    /// - Parameter attempt: which look this is; a scan starts the count
    ///   afresh (the default), the follow-up looks it schedules count up to
    ///   `maxLinkedFolderRechecks`.
    func reconcileFormerLinkedFolderPath(
        _ formerPath: String,
        folderId: UUID,
        newRoot: URL,
        attempt: Int = 1
    ) async {
        formerPathRechecks.removeValue(forKey: formerPath)?.cancel()
        parkedFormerPathRechecks.removeValue(forKey: formerPath)

        let oldRootPath = DatabaseManager.canonicalPath(formerPath)
        let newRootPath = DatabaseManager.canonicalPath(newRoot.path)
        guard oldRootPath != newRootPath else { return }

        // A stat, an ancestor walk with resource-value reads and a
        // confirmed-missing check per row, plus the counts: off the main
        // actor, like recheckLinkedFolder (the scan calls this from its own
        // main-actor sweep).
        let outcome = await Task.detached(priority: .utility) { () -> FormerPathOutcome in
            let databaseManager = DatabaseManager.shared
            guard let tracks = try? databaseManager.tracks(underPath: oldRootPath) else { return .unreadable }

            let missing = tracks.filter { track in
                let oldPath = DatabaseManager.canonicalPath(track.path)
                guard oldPath.hasPrefix(oldRootPath + "/") else { return false }
                let newPath = newRootPath + "/" + String(oldPath.dropFirst(oldRootPath.count + 1))
                return Self.isAbsentWithoutPlaceholder(oldPath)
                    && !LinkedFolderAbsence.mayStillBeSyncing(newPath, within: newRootPath)
                    && databaseManager.isPathConfirmedMissing(newPath, within: [newRoot])
            }

            // A folder moved to a place iCloud is still filling: most rows are
            // at neither location. Same mass rule as scan reconciliation, over
            // the folder's rows at both places.
            if !missing.isEmpty {
                // A count that fails is unknown, which counts as "all of it".
                guard let oldCount = try? databaseManager.countTracks(underPath: oldRootPath),
                      let newCount = try? databaseManager.countTracks(underPath: newRootPath) else {
                    RemovalConfirmationGuard.forget(missing.map(\.stableId))
                    return .unsettled
                }
                let total = oldCount + newCount
                if LinkedFolderAbsence.isUnsettled(missing: missing.count, total: total, folderPath: newRootPath)
                    || (total == 1 && LinkedFolderAbsence.isInICloudDrive(oldRootPath)) {
                    print("🔗 🛡️ \(missing.count)/\(total) songs of a moved linked folder at neither place - keeping them all")
                    RemovalConfirmationGuard.forget(missing.map(\.stableId))
                    return .unsettled
                }
            }
            return .missing(missing)
        }.value

        let missing: [Track]
        switch outcome {
        case .unreadable, .unsettled:
            return
        case .missing(let tracks):
            missing = tracks
        }

        if !missing.isEmpty {
            let confirmedIds = RemovalConfirmationGuard.confirmedRemovals(among: missing)
            // Scans are normally a day or a week apart, past the guard's
            // observation window; take the second look this session. Capped:
            // a song whose file keeps flapping in and out (iCloud evicting
            // and restoring it) otherwise kept this going for ever; the next
            // scan starts the count again.
            if confirmedIds.count < missing.count, attempt < Self.maxLinkedFolderRechecks {
                scheduleFormerPathRecheck(formerPath, folderId: folderId, attempt: attempt + 1)
            }

            let roots = [URL(fileURLWithPath: oldRootPath), newRoot]
            var removedIds: [String] = []
            for track in missing where confirmedIds.contains(track.stableId) {
                // Re-check at the last moment: the look above ran off the main
                // actor and each removal awaits.
                let oldPath = DatabaseManager.canonicalPath(track.path)
                let newPath = newRootPath + "/" + String(oldPath.dropFirst(oldRootPath.count + 1))
                guard Self.isAbsentWithoutPlaceholder(oldPath),
                      Self.isAbsentWithoutPlaceholder(newPath) else { continue }
                do {
                    let relocationResult = try databaseManager.preserveReferencesForAuthoritativelyMissingTrack(
                        track,
                        within: roots
                    )
                    if case .ambiguous = relocationResult {
                        print("🧹 🛡️ Preserving ambiguously relocated track: \(track.title)")
                        continue
                    }
                    try await databaseManager.deleteTrack(byStableId: track.stableId)
                    removedIds.append(track.stableId)
                    await deleteArtworkCache(for: track.stableId)
                    print("🔗 Removed song whose file left the linked folder: \(track.title)")
                } catch {
                    print("🧹 Failed to remove missing track \(track.title): \(error)")
                }
            }
            RemovalConfirmationGuard.forget(removedIds)
            if !removedIds.isEmpty {
                notifyTracksRemoved()
            }
        }

        if (try? databaseManager.countTracks(underPath: oldRootPath)) == 0 {
            LinkedFolderStore.shared.clearFormerPath(formerPath, of: folderId)
            print("🔗 Former location of a linked folder is empty - forgetting it")
        }
    }

    private func scheduleFormerPathRecheck(
        _ formerPath: String,
        folderId: UUID,
        attempt: Int,
        after delay: TimeInterval = RemovalConfirmationGuard.confirmationGrace + 60
    ) {
        guard formerPathRechecks[formerPath] == nil else { return }
        formerPathRechecks[formerPath] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.formerPathRechecks[formerPath] = nil
            // A scan does this itself, with a fresh walk of the folder.
            guard !LibraryIndexer.shared.isIndexing else { return }
            guard UIApplication.shared.applicationState != .background else {
                // The database may be suspended. Rescheduling from here woke
                // the app every 16 minutes for as long as audio kept it alive
                // in the background; park the look until the next foreground,
                // as scheduleLinkedFolderRecheck does.
                self.parkedFormerPathRechecks[formerPath] = (folderId, attempt)
                self.observeForegroundForParkedRechecks()
                return
            }
            let store = LinkedFolderStore.shared
            guard let folder = store.folders.first(where: { $0.id == folderId }),
                  folder.formerPaths.contains(formerPath),
                  !store.needsReconnect(folderId) else { return }
            let newRoot = URL(fileURLWithPath: folder.path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: newRoot.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  FileManager.default.isReadableFile(atPath: newRoot.path) else { return }
            await self.reconcileFormerLinkedFolderPath(formerPath, folderId: folderId, newRoot: newRoot, attempt: attempt)
        }
    }

    /// What `reconcileFormerLinkedFolderPath` found off the main actor.
    private enum FormerPathOutcome: @unchecked Sendable {
        /// The rows under the former path could not be read.
        case unreadable
        /// Too much of the moved folder at neither place: nothing judged.
        case unsettled
        case missing([Track])
    }

    /// No file at `path` and no `.name.icloud` placeholder for it either.
    /// Cheap enough for the main actor: two stats.
    nonisolated private static func isAbsentWithoutPlaceholder(_ path: String) -> Bool {
        let fileManager = FileManager.default
        let url = URL(fileURLWithPath: path)
        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
        return !fileManager.fileExists(atPath: path) && !fileManager.fileExists(atPath: placeholder.path)
    }

    // MARK: - Linked folders' missing songs

    /// The second look scan reconciliation's withheld linked-folder rows
    /// need. They used to go to ICloudDeletionMonitor, which ignores
    /// everything outside Documents/iCloud, and the orphan check skips
    /// linked folders: under weekly or manual scans no second scan came
    /// within the guard's window, so a song deleted from a linked folder
    /// stayed in the library for ever.
    private func scheduleLinkedFolderRecheck(
        folderId: UUID,
        stableIds: [String],
        attempt: Int = 1,
        after delay: TimeInterval = RemovalConfirmationGuard.confirmationGrace + 60
    ) {
        linkedFolderRecheckIds[folderId, default: []].formUnion(stableIds)
        guard linkedFolderRechecks[folderId] == nil else { return }
        linkedFolderRechecks[folderId] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.linkedFolderRechecks[folderId] = nil
            guard UIApplication.shared.applicationState != .background else {
                // The database may be suspended. Rescheduling from here woke
                // the app every 16 minutes for as long as audio kept it alive
                // in the background; park the look until the next foreground
                // instead (the rows stay queued in linkedFolderRecheckIds).
                self.parkedLinkedFolderRechecks[folderId] = attempt
                self.observeForegroundForParkedRechecks()
                return
            }
            let stableIds = self.linkedFolderRecheckIds.removeValue(forKey: folderId) ?? []
            // A scan walks the folder afresh and hands back whatever it
            // still withholds.
            guard !LibraryIndexer.shared.isIndexing, !stableIds.isEmpty else { return }
            await self.recheckLinkedFolder(folderId, stableIds: stableIds, attempt: attempt)
        }
    }

    /// Runs the linked-folder looks (missing songs and former locations)
    /// parked while the app was in the
    /// background, shortly after it returns. Their grace period has already
    /// passed, so there is no need to wait it out again.
    private func observeForegroundForParkedRechecks() {
        guard foregroundObserver == nil else { return }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { @Sendable _ in
            Task { @MainActor in
                let manager = FileCleanupManager.shared
                let parked = manager.parkedLinkedFolderRechecks
                manager.parkedLinkedFolderRechecks.removeAll()
                for (folderId, attempt) in parked {
                    manager.scheduleLinkedFolderRecheck(folderId: folderId, stableIds: [], attempt: attempt, after: 10)
                }
                let parkedFormer = manager.parkedFormerPathRechecks
                manager.parkedFormerPathRechecks.removeAll()
                for (formerPath, entry) in parkedFormer {
                    manager.scheduleFormerPathRecheck(
                        formerPath,
                        folderId: entry.folderId,
                        attempt: entry.attempt,
                        after: 10
                    )
                }
            }
        }
    }

    /// What `recheckLinkedFolder` found off the main actor.
    private enum LinkedFolderRecheckOutcome: @unchecked Sendable {
        case unreachable
        /// Too much of the folder missing, or still syncing: nothing judged.
        case unsettled
        case missing([Track], root: URL)
    }

    /// Removes the given rows of a linked folder whose files are still gone,
    /// once RemovalConfirmationGuard agrees. Nothing is judged unless the
    /// folder itself resolves and is readable right now: an unplugged drive
    /// or a broken bookmark makes every song look deleted. Nor while the
    /// folder looks unsettled (see `withholdingUnsettledLinkedFolderAbsence`):
    /// a linked iCloud Drive folder still syncing is readable too.
    private func recheckLinkedFolder(_ folderId: UUID, stableIds: Set<String>, attempt: Int) async {
        // Resolving the bookmark can touch the file provider, and the checks
        // below stat every song of the folder: off the main actor, like the
        // scan's sweepLinkedFolders.
        let outcome = await Task.detached(priority: .utility) { () -> LinkedFolderRecheckOutcome in
            guard let root = LinkedFolderStore.shared.reopen(folderId) else { return .unreachable }
            let databaseManager = DatabaseManager.shared
            let rootPath = DatabaseManager.canonicalPath(root.path)
            let fileManager = FileManager.default

            // The whole folder, not only the rows withheld last time: a
            // folder that has since lost most of its songs is the same
            // partially-synced shape the scan path refuses to judge.
            // A failed read is not "no rows": as 0/0 it slipped past the mass
            // rule and every withheld row was judged on its own.
            guard let folderTracks = try? databaseManager.tracks(underPath: rootPath) else {
                print("🔗 🛡️ Could not read a linked folder's songs - keeping its missing songs")
                return .unsettled
            }
            let absentIds = folderTracks.filter { !fileManager.fileExists(atPath: $0.path) }.map(\.stableId)
            if LinkedFolderAbsence.isUnsettled(missing: absentIds.count, total: folderTracks.count, folderPath: rootPath) {
                print("🔗 🛡️ \(absentIds.count)/\(folderTracks.count) songs of a linked folder missing at once - keeping them all")
                RemovalConfirmationGuard.forget(absentIds)
                return .unsettled
            }

            var syncing: [String] = []
            let missing = stableIds.compactMap { stableId -> Track? in
                guard let track = try? databaseManager.getTrack(byStableId: stableId) else { return nil }
                let path = DatabaseManager.canonicalPath(track.path)
                // Under a former location now (the folder moved): that is
                // reconcileFormerLinkedFolderPath's to judge.
                guard path.hasPrefix(rootPath + "/") else { return nil }
                guard !fileManager.fileExists(atPath: path) else { return nil }
                if LinkedFolderAbsence.mayStillBeSyncing(path, within: rootPath) {
                    syncing.append(stableId)
                    return nil
                }
                guard databaseManager.isPathConfirmedMissing(path, within: [root]) else { return nil }
                return track
            }
            if !syncing.isEmpty {
                print("🔗 🛡️ \(syncing.count) linked song(s) may still be syncing from iCloud - keeping them")
                RemovalConfirmationGuard.forget(syncing)
            }
            return .missing(missing, root: root)
        }.value

        let missing: [Track]
        let root: URL
        switch outcome {
        case .unreachable:
            print("🔗 🛡️ Linked folder unreachable - keeping its missing songs")
            return
        case .unsettled:
            // The next scan's walk judges them afresh.
            return
        case .missing(let tracks, let folderRoot):
            missing = tracks
            root = folderRoot
        }
        guard !missing.isEmpty else { return }

        let confirmedIds = RemovalConfirmationGuard.confirmedRemovals(among: missing)
        let stillWithheld = missing.filter { !confirmedIds.contains($0.stableId) }.map(\.stableId)
        // Withheld again only while missing files keep coming back; a few
        // more looks, then the next scan's turn.
        if !stillWithheld.isEmpty, attempt < Self.maxLinkedFolderRechecks {
            scheduleLinkedFolderRecheck(folderId: folderId, stableIds: stillWithheld, attempt: attempt + 1)
        }

        var removedIds: [String] = []
        for track in missing where confirmedIds.contains(track.stableId) {
            // Re-check at the last moment, as removeVerifiedMissingTracks
            // does: the look above ran off the main actor and each removal
            // awaits.
            guard Self.isAbsentWithoutPlaceholder(track.path) else { continue }
            do {
                // Same relocation handling as scan reconciliation, so a song
                // renamed inside the folder keeps favourites and playlists.
                let relocationResult = try databaseManager.preserveReferencesForAuthoritativelyMissingTrack(
                    track,
                    within: [root]
                )
                if case .ambiguous = relocationResult {
                    print("🧹 🛡️ Preserving ambiguously relocated track: \(track.title)")
                    continue
                }
                try await databaseManager.deleteTrack(byStableId: track.stableId)
                removedIds.append(track.stableId)
                await deleteArtworkCache(for: track.stableId)
                print("🔗 Removed song whose file was deleted from a linked folder: \(track.title)")
            } catch {
                print("🧹 Failed to remove missing track \(track.title): \(error)")
            }
        }
        RemovalConfirmationGuard.forget(removedIds)
        if !removedIds.isEmpty {
            notifyTracksRemoved()
        }
    }

    /// Library UI refresh plus the Spotlight/Siri index, which otherwise
    /// only reindexes when a scan finishes and would keep offering the
    /// deleted song.
    private func notifyTracksRemoved() {
        NotificationCenter.default.post(
            name: NSNotification.Name("LibraryNeedsRefresh"),
            object: nil
        )
        #if canImport(MediaIntents)
        if #available(iOS 27.0, *) {
            SpotlightLibraryIndexer.shared.scheduleReindex()
        }
        #endif
    }

    private func isURL(_ url: URL, inside rootURL: URL) -> Bool {
        // Canonical spelling: NSMetadataQuery and the container lookup do not
        // agree on whether paths start with /private.
        let path = DatabaseManager.canonicalPath(url.path)
        let rootPath = DatabaseManager.canonicalPath(rootURL.path)
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private func rescueRelocatedApplicationFile(
        _ track: Track,
        currentDocumentsURL: URL
    ) async -> Bool {
        guard !FileManager.default.fileExists(atPath: track.path),
              let relocatedURL = DatabaseManager.relocatedApplicationDocumentsURL(
                forStoredPath: track.path,
                currentDocumentsURL: currentDocumentsURL
              ),
              FileManager.default.fileExists(atPath: relocatedURL.path) else {
            return false
        }

        // A provider-owned file may also live in another app container. A
        // bookmark proves it is external, so never rewrite those paths.
        do {
            await databaseManager.waitForExternalBookmarkMigration()
            guard try await ExternalBookmarkStore.shared.bookmarkData(for: track.stableId) == nil else {
                return false
            }
        } catch {
            print("🧹 Could not verify bookmark before relocation rescue: \(error)")
            return false
        }

        do {
            let relocatedStableId = DatabaseManager.generatePathStableId(forPath: relocatedURL.path)
            try databaseManager.migrateTrackStableIdAndPath(
                oldStableId: track.stableId,
                newStableId: relocatedStableId,
                newPath: relocatedURL.path
            )
            print("🧹 🔁 Repaired restored local track path: \(relocatedURL.lastPathComponent)")
            return true
        } catch {
            // Preserve the row on migration failure. Returning true keeps the
            // destructive cleanup pass from converting a repair error into
            // loss of favourites and playlist membership.
            print("🧹 Failed to repair restored local track path; preserving row: \(error)")
            return true
        }
    }
    

    private func checkExternalFileAccessibility(
        _ fileURL: URL,
        stableId: String
    ) async -> ExternalFileAccessibility {
        // First check if file exists at the path
        if FileManager.default.fileExists(atPath: fileURL.path) {
            // File exists at original path, try to access it
            do {
                _ = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                print("🧹     External file accessible at original path")
                return .accessible
            } catch {
                print("🧹     External file exists but not accessible: \(error)")
                // A security-scoped file can exist while direct attribute
                // access is denied. Fall through and resolve its bookmark
                // before declaring it orphaned.
            }
        }

        // The direct path is absent or inaccessible; try the security-scoped
        // bookmark before treating the database row as orphaned.
        print("🧹     Checking bookmark data for external file")
        return await checkBookmarkAccessibility(for: fileURL, stableId: stableId)
    }

    private func checkBookmarkAccessibility(
        for fileURL: URL,
        stableId: String
    ) async -> ExternalFileAccessibility {
        do {
            await databaseManager.waitForExternalBookmarkMigration()
            guard let bookmarkData = try await ExternalBookmarkStore.shared.bookmarkData(for: stableId) else {
                print("🧹     No bookmark found for stableId: \(stableId)")
                return .confirmedMissing
            }

            var isStale = false
            let resolvedURL = try URL(resolvingBookmarkData: bookmarkData, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale)

            if isStale {
                print("🧹     Document picker bookmark is STALE for stableId: \(stableId)")
                print("🧹     Resolved path: \(resolvedURL.path)")
                return .temporarilyUnavailable
            }

            print("🧹     Document picker bookmark resolved successfully for stableId: \(stableId)")
            print("🧹     Resolved path: \(resolvedURL.path)")
            if resolvedURL.path != fileURL.path {
                print("🧹     File has moved from \(fileURL.path) to \(resolvedURL.path) - bookmark is tracking it")
            }

            if await testFileAccessibility(resolvedURL) {
                print("🧹     External file is accessible via bookmark ✅")
                return .accessible
            }

            return .temporarilyUnavailable
        } catch {
            print("🧹     Failed to resolve document picker bookmark: \(error)")
            // Resolution and bookmark-store failures are also not proof that
            // the user deleted the provider-backed file.
            return .temporarilyUnavailable
        }
    }

    private func testFileAccessibility(_ fileURL: URL) async -> Bool {
        print("🧹     Testing accessibility for resolved URL: \(fileURL.path)")

        guard fileURL.startAccessingSecurityScopedResource() else {
            print("🧹     ❌ Failed to start accessing security-scoped resource")
            return false
        }

        defer {
            fileURL.stopAccessingSecurityScopedResource()
            print("🧹     ⏹️ Stopped accessing security-scoped resource")
        }

        // Check if file exists at the resolved path
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("🧹     ❌ File doesn't exist at resolved bookmark path: \(fileURL.path)")
            return false
        }

        print("🧹     ✅ File exists at resolved path")

        do {
            // Try to get file attributes - this tests basic access permissions
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let fileSize = attributes[.size] as? Int64 ?? 0
            print("🧹     ✅ Got file attributes - size: \(fileSize) bytes")

            // For additional verification, try to actually read the file
            // This will catch cases where the file exists but is corrupted or inaccessible
            let fileHandle = try FileHandle(forReadingFrom: fileURL)
            defer {
                do {
                    try fileHandle.close()
                    print("🧹     ✅ Successfully closed file handle")
                } catch {
                    print("🧹     ⚠️ Error closing file handle: \(error)")
                }
            }

            let data = try fileHandle.read(upToCount: 1024)

            if let data = data, data.count > 0 {
                print("🧹     ✅ External file accessible and readable via bookmark (\(data.count) bytes read)")
                return true
            } else {
                print("🧹     ❌ External file exists but appears to be empty or unreadable")
                return false
            }
        } catch {
            print("🧹     ❌ External file not accessible or readable via bookmark")
            print("🧹     ❌ Error details: \(error)")
            print("🧹     ❌ Error type: \(type(of: error))")
            return false
        }
    }

    // MARK: - Artwork Cache Cleanup

    private func deleteArtworkCache(for stableId: String) async {
        // Note: We don't delete the actual artwork file as other tracks might use it
        // The artwork manager will clean up unused files during cleanupOrphanedArtwork
        // Just notify that we're removing this track's artwork reference
        print("🧹 Removed artwork reference for: \(stableId)")
    }
}
