//
//  FileCleanupManager.swift
//  Cosmos Music Player
//
//  Manages cleanup of iCloud files that were deleted from iCloud Drive
//

import Foundation
import CryptoKit
import SwiftUI

/// Withholds every reconciliation pass that would delete library rows until a
/// second, separate pass agrees with it.
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
/// The same set of absent tracks has to be observed again by a later pass, at
/// least `confirmationGrace` afterwards, before anything is removed. This is
/// deliberately independent of count and library fraction: an iCloud provider
/// can publish one child late, or 199 children in a 1,000-track library, and
/// either case would otherwise permanently discard favourites and playlist
/// positions. A converged library reproduces the set exactly and the deletion
/// goes through; a container that was mid-sync does not.
@MainActor
private enum RemovalConfirmationGuard {
    private static let defaultsKey = "LibraryPendingMassRemoval"
    private static let signatureKey = "signature"
    private static let firstObservedKey = "firstObservedAt"

    private static let confirmationGrace: TimeInterval = 15 * 60

    /// - Returns: whether these tracks may be deleted now.
    static func allowsRemoval(of stableIds: [String]) -> Bool {
        guard !stableIds.isEmpty else { return true }
        let signature = signature(for: stableIds)
        let now = Date()

        guard let pending = UserDefaults.standard.dictionary(forKey: defaultsKey),
              pending[signatureKey] as? String == signature,
              let firstObserved = pending[firstObservedKey] as? Date else {
            UserDefaults.standard.set(
                [signatureKey: signature, firstObservedKey: now],
                forKey: defaultsKey
            )
            print("""
                🛡️ Withholding removal of \(stableIds.count) track(s) - \
                the same absence set must be seen by a later scan before anything is deleted
                """)
            return false
        }

        let waited = now.timeIntervalSince(firstObserved)
        guard waited >= confirmationGrace else {
            print("""
                🛡️ Still withholding removal of \(stableIds.count) track(s) - \
                confirmed after \(Int(waited))s, needs \(Int(confirmationGrace))s
                """)
            return false
        }

        print("🧹 Removal of \(stableIds.count) track(s) confirmed by a second scan - proceeding")
        clear()
        return true
    }

    static func clear() {
        guard UserDefaults.standard.object(forKey: defaultsKey) != nil else { return }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    /// Order-independent, so a differently-ordered query of the same absent
    /// rows still counts as the same observation.
    private static func signature(for stableIds: [String]) -> String {
        let joined = stableIds.sorted().joined(separator: "\n")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
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
                RemovalConfirmationGuard.clear()
                print("🧹 Scan reconciliation found no deleted files")
                return
            }

            // A clean walk of the root does not prove every nested provider
            // directory was materialised. A real single-file deletion leaves
            // its immediate parent readable; an unavailable/unmounted subtree
            // does not. Preserve the latter until accessibility is authoritative.
            let missingTracks = absentTracks.filter {
                databaseManager.isPathConfirmedMissing($0.path)
            }
            let temporarilyUnavailableCount = absentTracks.count - missingTracks.count
            if temporarilyUnavailableCount > 0 {
                print("🧹 🛡️ Preserving \(temporarilyUnavailableCount) track(s) whose parent directory is unavailable")
            }
            guard !missingTracks.isEmpty else { return }

            // Every absence set has to be confirmed by a later pass before any
            // relationship data is destroyed. Count/fraction thresholds cannot
            // distinguish a real deletion from partially published iCloud data.
            guard RemovalConfirmationGuard.allowsRemoval(
                of: missingTracks.map(\.stableId)
            ) else {
                return
            }

            print("🧹 Scan reconciliation removing \(missingTracks.count) deleted track(s)")
            for track in missingTracks {
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
                    await deleteArtworkCache(for: track.stableId)
                    print("🧹 Removed missing track: \(track.title)")
                } catch {
                    print("🧹 Failed to remove missing track \(track.title): \(error)")
                }
            }

            NotificationCenter.default.post(
                name: NSNotification.Name("LibraryNeedsRefresh"),
                object: nil
            )
        } catch {
            print("🧹 Scan reconciliation failed: \(error)")
        }
    }
    
    func checkForOrphanedFiles() async {
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
                    // the immediate containing directory is still readable.
                    let fileExists = FileManager.default.fileExists(atPath: trackURL.path)
                    print("🧹   Internal file exists: \(fileExists)")

                    if fileExists {
                        print("🧹 ✅ Internal file exists (keeping): \(trackURL.lastPathComponent)")
                    } else if databaseManager.isPathConfirmedMissing(trackURL.path) {
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
            
            // Auto-clean files that don't exist anywhere
            if !nonExistentTracks.isEmpty {
                // This is a second deletion path after scan reconciliation. It
                // must honour the same removal decision: after a restore,
                // an available-but-not-yet-materialised iCloud container looks
                // exactly like deleted files here. Without this
                // gate, reconcileMissingFiles() withheld those rows and this
                // pass deleted them (plus favourites and playlist entries) 15
                // seconds later.
                guard RemovalConfirmationGuard.allowsRemoval(
                    of: nonExistentTracks.map(\.stableId)
                ) else {
                    print("🧹 🛡️ Deferring orphan cleanup until the removal is confirmed")
                    return
                }

                print("🧹 Auto-cleaning \(nonExistentTracks.count) files that don't exist anywhere")
                
                for track in nonExistentTracks {
                    do {
                        print("🧹 Auto-cleaning database entry for non-existent file: \(URL(fileURLWithPath: track.path).lastPathComponent)")
                        print("🧹 Auto-removing track from database: \(track.title)")
                        // Use the ID stored with the row. Re-hashing the
                        // filename was incompatible with path-based IDs and
                        // silently left deleted tracks in previous builds.
                        try await databaseManager.deleteTrack(byStableId: track.stableId)

                        // Delete cached artwork for this track
                        await deleteArtworkCache(for: track.stableId)
                    } catch {
                        print("🧹 Error auto-cleaning file \(track.path): \(error)")
                    }
                }
                
                // Notify UI to refresh since we made database changes
                NotificationCenter.default.post(name: NSNotification.Name("LibraryNeedsRefresh"), object: nil)
            }
            
            print("🧹 No additional cleanup needed")
            
        } catch {
            print("🧹 Error checking for orphaned files: \(error)")
        }
    }

    private func isURL(_ url: URL, inside rootURL: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = rootURL.standardizedFileURL.path
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
