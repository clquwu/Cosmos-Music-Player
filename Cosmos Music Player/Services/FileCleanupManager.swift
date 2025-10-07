//
//  FileCleanupManager.swift
//  Cosmos Music Player
//
//  Manages cleanup of iCloud files that were deleted from iCloud Drive
//

import Foundation
import SwiftUI
import CryptoKit

@MainActor
class FileCleanupManager: ObservableObject {
    static let shared = FileCleanupManager()
    
    
    private let databaseManager = DatabaseManager.shared
    private let stateManager = StateManager.shared
    
    private init() {}
    
    func checkForOrphanedFiles() async {
        print("🧹 Checking for iCloud files that were deleted from iCloud Drive...")
        
        guard let iCloudFolderURL = stateManager.getMusicFolderURL() else {
            print("🧹 No iCloud folder available, skipping cleanup check")
            return
        }
        
        print("🧹 iCloud folder URL: \(iCloudFolderURL.path)")
        
        do {
            // Get all tracks from database
            let allTracks = try databaseManager.getAllTracks()
            print("🧹 Found \(allTracks.count) tracks in database")
            
            var nonExistentFiles: [URL] = []
            
            for track in allTracks {
                let trackURL = URL(fileURLWithPath: track.path)
                print("🧹 Checking track: \(trackURL.lastPathComponent)")
                print("🧹   Path: \(trackURL.path)")

                // Check if this is an internal file (iCloud/Documents) or external file
                let isInternalFile = trackURL.path.contains(iCloudFolderURL.path) ||
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
                        if trackURL.path.contains("/Documents/") && !trackURL.path.contains(iCloudFolderURL.path) {
                            // Try to find the file in the current Documents directory
                            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                            let filename = trackURL.lastPathComponent
                            let newURL = documentsURL.appendingPathComponent(filename)

                            if FileManager.default.fileExists(atPath: newURL.path) {
                                print("🧹   Found file in current Documents folder, updating path...")
                                print("🧹   Old path: \(trackURL.path)")
                                print("🧹   New path: \(newURL.path)")

                                // Update the track's path in the database
                                do {
                                    try databaseManager.write { db in
                                        var updatedTrack = track
                                        updatedTrack.path = newURL.path
                                        try updatedTrack.update(db)
                                    }
                                    print("🧹 ✅ Updated path for: \(filename)")
                                } catch {
                                    print("🧹 ❌ Failed to update path: \(error)")
                                    nonExistentFiles.append(trackURL)
                                }
                            } else {
                                print("🧹   Internal file doesn't exist - will auto-clean from database")
                                nonExistentFiles.append(trackURL)
                            }
                        } else {
                            print("🧹   Internal file doesn't exist - will auto-clean from database")
                            nonExistentFiles.append(trackURL)
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
                        nonExistentFiles.append(trackURL)
                    }
                }
            }
            
            // Auto-clean files that don't exist anywhere
            if !nonExistentFiles.isEmpty {
                print("🧹 Auto-cleaning \(nonExistentFiles.count) files that don't exist anywhere")
                
                for fileURL in nonExistentFiles {
                    do {
                        let stableId = generateStableId(for: fileURL)
                        print("🧹 Auto-cleaning database entry for non-existent file: \(fileURL.lastPathComponent)")

                        if let track = try databaseManager.getTrack(byStableId: stableId) {
                            print("🧹 Auto-removing track from database: \(track.title)")
                            try databaseManager.deleteTrack(byStableId: stableId)

                            // Delete cached artwork for this track
                            await deleteArtworkCache(for: stableId)
                        }
                    } catch {
                        print("🧹 Error auto-cleaning file \(fileURL.lastPathComponent): \(error)")
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

    private func generateStableId(for url: URL) -> String {
        // Simple stable ID based only on filename - matches LibraryIndexer
        let filename = url.lastPathComponent
        let digest = SHA256.hash(data: filename.data(using: .utf8) ?? Data())
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Artwork Cache Cleanup

    private func deleteArtworkCache(for stableId: String) async {
        // Note: We don't delete the actual artwork file as other tracks might use it
        // The artwork manager will clean up unused files during cleanupOrphanedArtwork
        // Just notify that we're removing this track's artwork reference
        print("🧹 Removed artwork reference for: \(stableId)")
    }
}

