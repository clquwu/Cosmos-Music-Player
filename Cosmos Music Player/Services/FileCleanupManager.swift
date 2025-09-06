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
            
            var orphanedFiles: [URL] = []
            var nonExistentFiles: [URL] = []
            
            for track in allTracks {
                let trackURL = URL(fileURLWithPath: track.path)
                print("🧹 Checking track: \(trackURL.lastPathComponent)")
                print("🧹   Path: \(trackURL.path)")
                
                // Check if file exists locally
                let fileExists = FileManager.default.fileExists(atPath: trackURL.path)
                print("🧹   File exists locally: \(fileExists)")
                
                if fileExists {
                    // Check if it's in iCloud Drive folder
                    let isInICloud = trackURL.path.contains(iCloudFolderURL.path)
                    print("🧹   Is in iCloud folder: \(isInICloud)")
                    
                    if isInICloud {
                        // This is an iCloud file, check if it still exists in iCloud
                        let existsInCloud = await fileExistsInCloud(trackURL)
                        print("🧹   Exists in iCloud: \(existsInCloud)")
                        
                        if !existsInCloud {
                            orphanedFiles.append(trackURL)
                            print("🧹 ✅ Found orphaned iCloud file (deleted from iCloud): \(trackURL.lastPathComponent)")
                        }
                    } else {
                        // File exists locally but NOT in iCloud Drive folder - this is a LOCAL file, keep it!
                        print("🧹 ✅ Local file found (keeping): \(trackURL.lastPathComponent)")
                    }
                } else {
                    print("🧹   File doesn't exist anywhere - will auto-clean from database")
                    // File doesn't exist at all, auto-remove from database without asking user
                    nonExistentFiles.append(trackURL)
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
                        }
                    } catch {
                        print("🧹 Error auto-cleaning file \(fileURL.lastPathComponent): \(error)")
                    }
                }
                
                // Notify UI to refresh since we made database changes
                NotificationCenter.default.post(name: NSNotification.Name("LibraryNeedsRefresh"), object: nil)
            }
            
            print("🧹 Total orphaned files found: \(orphanedFiles.count)")
            
            // Auto-remove orphaned iCloud files (deleted from iCloud Drive) without asking user
            if !orphanedFiles.isEmpty {
                print("🧹 Auto-removing \(orphanedFiles.count) files that were deleted from iCloud")
                
                for fileURL in orphanedFiles {
                    do {
                        let stableId = generateStableId(for: fileURL)
                        print("🧹 Auto-removing orphaned file: \(fileURL.lastPathComponent)")
                        
                        // Remove from database
                        if let track = try databaseManager.getTrack(byStableId: stableId) {
                            print("🧹 Removing track from database: \(track.title)")
                            try databaseManager.deleteTrack(byStableId: stableId)
                        }
                        
                        // Remove local file if it exists
                        if FileManager.default.fileExists(atPath: fileURL.path) {
                            try FileManager.default.removeItem(at: fileURL)
                            print("🧹 Deleted local file: \(fileURL.lastPathComponent)")
                        }
                        
                    } catch {
                        print("🧹 Error removing orphaned file \(fileURL.lastPathComponent): \(error)")
                    }
                }
                
                // Notify UI to refresh since we made changes
                NotificationCenter.default.post(name: NSNotification.Name("LibraryNeedsRefresh"), object: nil)
            } else {
                print("🧹 No orphaned files found")
            }
            
        } catch {
            print("🧹 Error checking for orphaned files: \(error)")
        }
    }
    
    private func fileExistsInCloud(_ fileURL: URL) async -> Bool {
        do {
            print("🧹 Checking iCloud status for: \(fileURL.lastPathComponent)")
            let resourceValues = try fileURL.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
            
            let isUbiquitous = resourceValues.isUbiquitousItem ?? false
            print("🧹   Is ubiquitous: \(isUbiquitous)")
            
            guard isUbiquitous else {
                // Not an iCloud file, so it "exists" (locally)
                print("🧹   Not an iCloud file, returning true")
                return true
            }
            
            // Check if the file is available in iCloud (not deleted from iCloud Drive)
            if let downloadStatus = resourceValues.ubiquitousItemDownloadingStatus {
                print("🧹   Download status: \(downloadStatus.rawValue)")
                switch downloadStatus {
                case .current, .downloaded, .notDownloaded:
                    print("🧹   File exists in iCloud (status: \(downloadStatus.rawValue))")
                    return true
                default:
                    print("🧹   File does NOT exist in iCloud (status: \(downloadStatus.rawValue))")
                    return false
                }
            } else {
                print("🧹   No download status available, assuming exists")
                return true
            }
        } catch {
            // If we can't get resource values, the file might be deleted from iCloud
            print("🧹 Cannot check iCloud status for \(fileURL.lastPathComponent): \(error)")
            return false
        }
    }
    
    
    private func generateStableId(for url: URL) -> String {
        // Simple stable ID based only on filename - matches LibraryIndexer
        let filename = url.lastPathComponent
        let digest = SHA256.hash(data: filename.data(using: .utf8) ?? Data())
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
}

