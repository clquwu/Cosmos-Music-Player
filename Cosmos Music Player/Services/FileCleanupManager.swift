//
//  FileCleanupManager.swift
//  Cosmos Music Player
//
//  Manages cleanup of iCloud files that were deleted from iCloud Drive
//

import Foundation
import SwiftUI

@MainActor
class FileCleanupManager: ObservableObject {
    static let shared = FileCleanupManager()
    
    
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
            let missingTracks = tracks.filter { track in
                let trackURL = URL(fileURLWithPath: track.path).standardizedFileURL
                let belongsToScannedRoot = roots.contains { isURL(trackURL, inside: $0) }
                return belongsToScannedRoot && !FileManager.default.fileExists(atPath: trackURL.path)
            }

            guard !missingTracks.isEmpty else {
                print("🧹 Scan reconciliation found no deleted files")
                return
            }

            print("🧹 Scan reconciliation removing \(missingTracks.count) deleted track(s)")
            for track in missingTracks {
                do {
                    try databaseManager.deleteTrack(byStableId: track.stableId)
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

                // Check if this is an internal file (iCloud/Documents) or external file
                let isInCurrentiCloudFolder = iCloudFolderURL.map {
                    isURL(trackURL, inside: $0)
                } ?? false
                let isICloudFile = isInCurrentiCloudFolder || trackURL.path.contains("/Mobile Documents/")

                // iCloud paths can temporarily disappear while signed out or
                // offline. Absence is only authoritative while the container
                // is available; otherwise preserve the user's database row.
                if isICloudFile && AppCoordinator.shared.iCloudStatus != .available {
                    print("🧹 Skipping unavailable iCloud path: \(trackURL.lastPathComponent)")
                    continue
                }

                let isInternalFile = isICloudFile ||
                    isURL(trackURL, inside: documentsURL) ||
                    trackURL.path.contains("/Documents/")
                print("🧹   Is internal file: \(isInternalFile)")

                if isInternalFile {
                    // For internal files, simple existence check
                    let fileExists = FileManager.default.fileExists(atPath: trackURL.path)
                    print("🧹   Internal file exists: \(fileExists)")

                    if fileExists {
                        print("🧹 ✅ Internal file exists (keeping): \(trackURL.lastPathComponent)")
                    } else {
                        // Check if this is a local Documents file with an old container path
                        if trackURL.path.contains("/Documents/") && !isInCurrentiCloudFolder {
                            // Try to find the file in the current Documents directory
                            let filename = trackURL.lastPathComponent
                            let newURL = documentsURL.appendingPathComponent(filename)

                            if FileManager.default.fileExists(atPath: newURL.path) {
                                print("🧹   Found file in current Documents folder, updating path...")
                                print("🧹   Old path: \(trackURL.path)")
                                print("🧹   New path: \(newURL.path)")

                                // Update the track's path in the database
                                do {
                                    let newStableId = DatabaseManager.generatePathStableId(forPath: newURL.path)
                                    try databaseManager.migrateTrackStableIdAndPath(
                                        oldStableId: track.stableId,
                                        newStableId: newStableId,
                                        newPath: newURL.path
                                    )
                                    print("🧹 ✅ Updated path for: \(filename)")
                                } catch {
                                    print("🧹 ❌ Failed to update path: \(error)")
                                    nonExistentTracks.append(track)
                                }
                            } else {
                                print("🧹   Internal file doesn't exist - will auto-clean from database")
                                nonExistentTracks.append(track)
                            }
                        } else {
                            print("🧹   Internal file doesn't exist - will auto-clean from database")
                            nonExistentTracks.append(track)
                        }
                    }
                } else {
                    // For external files (from share/document picker), check if still accessible
                    let isAccessible = await checkExternalFileAccessibility(trackURL, stableId: track.stableId)
                    print("🧹   External file accessible: \(isAccessible)")

                    if isAccessible {
                        print("🧹 ✅ External file still accessible (keeping): \(trackURL.lastPathComponent)")
                    } else {
                        print("🧹   External file no longer accessible - will auto-clean from database")
                        nonExistentTracks.append(track)
                    }
                }
            }
            
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
                        try databaseManager.deleteTrack(byStableId: track.stableId)

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
    

    private func checkExternalFileAccessibility(_ fileURL: URL, stableId: String) async -> Bool {
        // First check if file exists at the path
        if FileManager.default.fileExists(atPath: fileURL.path) {
            // File exists at original path, try to access it
            do {
                _ = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                print("🧹     External file accessible at original path")
                return true
            } catch {
                print("🧹     External file exists but not accessible: \(error)")
                return false
            }
        }

        // File doesn't exist at original path, check if we have bookmark data for it
        print("🧹     External file doesn't exist at original path, checking bookmark data")
        return await checkBookmarkAccessibility(for: fileURL, stableId: stableId)
    }

    private func checkBookmarkAccessibility(for fileURL: URL, stableId: String) async -> Bool {
        // Check document picker bookmarks (now using stableId as key)
        if let resolvedURL = await resolveDocumentPickerBookmark(for: stableId) {
            // Bookmark found! Check if file is still accessible
            if resolvedURL.path != fileURL.path {
                print("🧹     File has been moved from \(fileURL.path) to \(resolvedURL.path) - bookmark is tracking it ✅")
            }

            // Test if the resolved location is accessible
            let isAccessible = await testFileAccessibility(resolvedURL)
            if isAccessible {
                print("🧹     External file is accessible via bookmark ✅")
            }
            return isAccessible
        }

        // Check share extension bookmarks (legacy - should be migrated)
        if let resolvedURL = await resolveShareExtensionBookmark(for: stableId) {
            if resolvedURL.path != fileURL.path {
                print("🧹     File has been moved from \(fileURL.path) to \(resolvedURL.path) - bookmark is tracking it ✅")
            }
            return await testFileAccessibility(resolvedURL)
        }

        print("🧹     No valid bookmark found for external file")
        return false
    }

    private func resolveDocumentPickerBookmark(for stableId: String) async -> URL? {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let bookmarksURL = documentsURL.appendingPathComponent("ExternalFileBookmarks.plist")

        guard FileManager.default.fileExists(atPath: bookmarksURL.path) else {
            print("🧹     No document picker bookmarks file found")
            return nil
        }

        do {
            let data = try Data(contentsOf: bookmarksURL)
            guard let bookmarks = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Data],
                  let bookmarkData = bookmarks[stableId] else {
                print("🧹     No bookmark found for stableId: \(stableId)")
                return nil
            }

            var isStale = false
            let resolvedURL = try URL(resolvingBookmarkData: bookmarkData, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale)

            if isStale {
                print("🧹     Document picker bookmark is STALE for stableId: \(stableId)")
                print("🧹     Resolved path: \(resolvedURL.path)")
                return nil
            }

            print("🧹     Document picker bookmark resolved successfully for stableId: \(stableId)")
            print("🧹     Resolved path: \(resolvedURL.path)")
            return resolvedURL
        } catch {
            print("🧹     Failed to resolve document picker bookmark: \(error)")
            return nil
        }
    }

    private func resolveShareExtensionBookmark(for stableId: String) async -> URL? {
        // Share extension bookmarks are now migrated to the main bookmark storage
        // This function is kept for backward compatibility but should not be needed
        print("🧹     Share extension bookmarks have been migrated to main storage")
        return nil
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
