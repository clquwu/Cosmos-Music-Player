//
//  CloudDownloadManager.swift
//  Cosmos Music Player
//
//  Manages downloading and monitoring iCloud Drive files
//

import Foundation
import Combine

@MainActor
class CloudDownloadManager: NSObject, ObservableObject {
    static let shared = CloudDownloadManager()
    
    @Published var downloadProgress: [URL: Double] = [:]
    @Published var downloadingFiles: Set<URL> = []
    
    private var downloadTasks: [URL: Task<Void, Error>] = [:]
    private nonisolated(unsafe) var progressQuery: NSMetadataQuery?
    private var isQueryRunning = false
    
    // Track if we've detected systematic iCloud failures
    private var hasDetectedSystematicFailure = false
    private var consecutiveFailures = 0
    private var lastFailureTime: Date?
    private let maxConsecutiveFailures = 3
    private let failureResetTime: TimeInterval = 300 // 5 minutes
    
    override init() {
        super.init()
        setupProgressQuery()
        
        // Listen for authentication status changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAuthStatusChange),
            name: NSNotification.Name("iCloudAuthStatusChanged"),
            object: nil
        )
    }
    
    @objc private func handleAuthStatusChange() {
        Task { @MainActor in
            await updateQueryForAuthStatus()
        }
    }
    
    @MainActor
    private func updateQueryForAuthStatus() async {
        guard let query = progressQuery else { return }
        
        if AppCoordinator.shared.iCloudStatus == .authenticationRequired || !AppCoordinator.shared.isiCloudAvailable || hasDetectedSystematicFailure {
            // Stop query and clear all downloads when authentication fails
            if isQueryRunning {
                query.stop()
                isQueryRunning = false
                print("🛑 Stopped NSMetadataQuery due to authentication issues or systematic failures")
                
                // Clear all ongoing downloads
                downloadingFiles.removeAll()
                downloadProgress.removeAll()
                downloadTasks.values.forEach { $0.cancel() }
                downloadTasks.removeAll()
            }
        } else if AppCoordinator.shared.iCloudStatus == .available && !hasDetectedSystematicFailure {
            // Restart query when authentication is restored
            if !isQueryRunning {
                query.start()
                isQueryRunning = true
                print("▶️ Restarted NSMetadataQuery after authentication restored")
            }
        }
    }
    
    @MainActor 
    func detectSystematicFailure() {
        // Reset failure count if enough time has passed since last failure
        if let lastFailure = lastFailureTime, Date().timeIntervalSince(lastFailure) > failureResetTime {
            consecutiveFailures = 0
            print("🔄 Resetting failure count after \(Int(failureResetTime/60)) minutes")
        }
        
        consecutiveFailures += 1
        lastFailureTime = Date()
        
        print("⚠️ iCloud failure detected (\(consecutiveFailures)/\(maxConsecutiveFailures))")
        
        if consecutiveFailures >= maxConsecutiveFailures && !hasDetectedSystematicFailure {
            hasDetectedSystematicFailure = true
            print("🚨 Systematic iCloud failure detected after \(maxConsecutiveFailures) consecutive failures - switching to offline mode")
            AppCoordinator.shared.handleiCloudAuthenticationError()
            Task {
                await updateQueryForAuthStatus()
            }
        }
    }
    
    @MainActor
    func resetFailureCount() {
        if consecutiveFailures > 0 {
            consecutiveFailures = 0
            lastFailureTime = nil
            print("✅ Reset iCloud failure count - successful operation detected")
        }
    }
    
    @MainActor
    func attemptRecovery() {
        print("🔄 Attempting recovery from offline mode...")
        hasDetectedSystematicFailure = false
        consecutiveFailures = 0
        lastFailureTime = nil
        
        // Restart the metadata query if needed
        Task {
            await updateQueryForAuthStatus()
        }
    }
    
    // Public method to allow other parts of the app to report iCloud failures
    static func reportiCloudFailure(error: Error) {
        if let nsError = error as NSError? {
            if nsError.domain == NSPOSIXErrorDomain && nsError.code == 60 {
                print("🚨 External timeout error reported - triggering systematic failure detection")
                Task { @MainActor in
                    CloudDownloadManager.shared.detectSystematicFailure()
                }
            } else if nsError.domain == NSPOSIXErrorDomain && nsError.code == 81 {
                print("🚨 External authentication error reported - triggering systematic failure detection") 
                Task { @MainActor in
                    CloudDownloadManager.shared.detectSystematicFailure()
                }
            }
        }
    }
    
    private func setupProgressQuery() {
        progressQuery = NSMetadataQuery()
        progressQuery?.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        progressQuery?.predicate = NSPredicate(format: "%K LIKE '*.flac' OR %K LIKE '*.mp3'", NSMetadataItemFSNameKey, NSMetadataItemFSNameKey)
        
        // Add notification observers for progress updates
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidUpdate),
            name: .NSMetadataQueryDidUpdate,
            object: progressQuery
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidFinishGathering),
            name: .NSMetadataQueryDidFinishGathering,
            object: progressQuery
        )
        
        // Start the query to monitor iCloud downloads
        progressQuery?.start()
        isQueryRunning = true
    }
    
    @objc private func queryDidUpdate(_ notification: Notification) {
        Task { @MainActor in
            await processQueryUpdate()
        }
    }
    
    @objc private func queryDidFinishGathering(_ notification: Notification) {
        Task { @MainActor in
            await processQueryUpdate()
        }
    }
    
    private func processQueryUpdate() async {
        // Skip processing if authentication is required or systematic failure detected
        if AppCoordinator.shared.iCloudStatus == .authenticationRequired || !AppCoordinator.shared.isiCloudAvailable || hasDetectedSystematicFailure {
            print("🚫 Skipping NSMetadataQuery update - authentication required, not available, or systematic failure detected")
            return
        }
        
        guard let query = progressQuery else { 
            print("❌ No progressQuery available")
            return 
        }
        
        print("🔍 NSMetadataQuery update - resultCount: \(query.resultCount)")
        print("📋 Currently tracking downloads for: \(downloadingFiles.map { $0.lastPathComponent })")
        
        query.disableUpdates()
        defer { query.enableUpdates() }
        
        // Process all metadata items to check download progress
        for i in 0..<query.resultCount {
            guard let item = query.result(at: i) as? NSMetadataItem else { 
                print("⚠️ Could not get NSMetadataItem at index \(i)")
                continue 
            }
            
            // Get the file URL
            guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { 
                print("⚠️ Could not get URL for NSMetadataItem at index \(i)")
                continue 
            }
            
            print("📁 NSMetadataQuery found file: \(url.lastPathComponent)")
            
            // Only process files we're tracking for download
            guard downloadingFiles.contains(url) else { 
                print("⏭️ Not tracking download for: \(url.lastPathComponent)")
                continue 
            }
            
            print("🎯 Processing tracked file: \(url.lastPathComponent)")
            
            // Check download status
            if let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? URLUbiquitousItemDownloadingStatus {
                print("📊 NSMetadataQuery status for \(url.lastPathComponent): \(status)")
                
                switch status {
                    case .current:
                        // Download complete
                        downloadProgress[url] = 1.0
                        downloadingFiles.remove(url)
                        downloadTasks.removeValue(forKey: url)
                        print("✅ Download complete via NSMetadataQuery: \(url.lastPathComponent)")
                        
                    case .downloaded:
                        // Downloaded but may not be current
                        downloadProgress[url] = 1.0
                        downloadingFiles.remove(url)
                        downloadTasks.removeValue(forKey: url)
                        print("✅ Download finished via NSMetadataQuery: \(url.lastPathComponent)")
                        
                    case .notDownloaded:
                        // Get actual download progress
                        if let progress = item.value(forAttribute: NSMetadataUbiquitousItemPercentDownloadedKey) as? NSNumber {
                            let progressValue = progress.doubleValue / 100.0
                            downloadProgress[url] = progressValue
                            print("📈 Real download progress: \(url.lastPathComponent) - \(Int(progressValue * 100))%")
                        } else {
                            print("⚠️ No progress percentage available for: \(url.lastPathComponent)")
                            // Set a small progress value to show download is happening
                            downloadProgress[url] = 0.1
                        }
                        
                default:
                    print("⚠️ Unknown download status via NSMetadataQuery: \(url.lastPathComponent)")
                }
            } else {
                print("❌ No download status available for: \(url.lastPathComponent)")
            }
        }
        
        if query.resultCount == 0 {
            print("⚠️ NSMetadataQuery has no results - may need to restart query")
        }
    }

    
        
    func ensureLocal(_ url: URL) async throws {
        print("🔍 ensureLocal called for: \(url.lastPathComponent)")
        
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("❌ File does not exist: \(url.lastPathComponent)")
            throw CloudDownloadError.fileNotFound
        }
        
        print("✅ File exists: \(url.lastPathComponent)")
        
        // Early check for iCloud authentication issues or systematic failures - prevent ANY iCloud operations
        if AppCoordinator.shared.iCloudStatus == .authenticationRequired || !AppCoordinator.shared.isiCloudAvailable || hasDetectedSystematicFailure {
            print("🚫 Skipping iCloud operations - authentication required, not available, or systematic failure detected: \(url.lastPathComponent)")
            // For files that exist locally, just check if they're readable
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                print("❌ File is not readable and iCloud unavailable: \(url.lastPathComponent)")
                throw CloudDownloadError.fileNotFound
            }
            print("✅ File ensured local (offline mode): \(url.lastPathComponent)")
            return
        }
        
        // Check if this is an iCloud file that needs downloading
        if isUbiquitous(url) {
            print("☁️ File is ubiquitous: \(url.lastPathComponent)")
            do {
                let resourceValues = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                
                if let downloadStatus = resourceValues.ubiquitousItemDownloadingStatus {
                    print("📊 Download status for \(url.lastPathComponent): \(downloadStatus)")
                    switch downloadStatus {
                    case .notDownloaded:
                        // Check if file is already readable locally (cached/downloaded but not current)
                        if FileManager.default.isReadableFile(atPath: url.path) {
                            print("✅ File is readable locally despite notDownloaded status: \(url.lastPathComponent)")
                            resetFailureCount() // Success case
                            return
                        }
                        
                        // Only trigger failure detection if we can't read the file at all
                        print("⚠️ File not downloaded and not readable - incrementing failure count")
                        detectSystematicFailure()
                        
                        // If we haven't reached systematic failure threshold yet, try to start download
                        if !hasDetectedSystematicFailure {
                            print("🔽 Attempting to download file: \(url.lastPathComponent)")
                            await startDownload(url)
                            return
                        } else {
                            print("❌ Systematic failure detected - cannot ensure file is local: \(url.lastPathComponent)")
                            throw CloudDownloadError.fileNotFound
                        }
                        
                    case .downloaded:
                        print("✅ File already downloaded: \(url.lastPathComponent)")
                        resetFailureCount() // Success case
                        return
                    case .current:
                        print("✅ File is current: \(url.lastPathComponent)")
                        resetFailureCount() // Success case
                        return
                    default:
                        print("⚠️ Unknown download status for \(url.lastPathComponent): \(downloadStatus)")
                        // Check if file is readable despite unknown status
                        if FileManager.default.isReadableFile(atPath: url.path) {
                            print("✅ File is readable despite unknown status: \(url.lastPathComponent)")
                            resetFailureCount()
                            return
                        }
                        detectSystematicFailure()
                        if hasDetectedSystematicFailure {
                            throw CloudDownloadError.fileNotFound
                        }
                        return
                    }
                } else {
                    print("⚠️ No download status available - checking if file is readable")
                    // Check if file is readable despite missing status
                    if FileManager.default.isReadableFile(atPath: url.path) {
                        print("✅ File is readable despite missing download status: \(url.lastPathComponent)")
                        resetFailureCount()
                        return
                    }
                    
                    // Only detect failure if file is not readable
                    detectSystematicFailure()
                    if hasDetectedSystematicFailure {
                        throw CloudDownloadError.fileNotFound
                    }
                    return
                }
            } catch {
                print("❌ Failed to get download status for \(url.lastPathComponent): \(error)")
                
                // Check if this is an authentication error
                if let nsError = error as NSError? {
                    if nsError.domain == NSPOSIXErrorDomain && nsError.code == 81 {
                        print("🔐 iCloud authentication required - throwing specific error")
                        throw CloudDownloadError.authenticationRequired
                    } else if nsError.domain == NSCocoaErrorDomain && (nsError.code == 256 || nsError.code == 257) {
                        print("🚫 iCloud access denied - throwing specific error")
                        throw CloudDownloadError.accessDenied
                    }
                }
                
                // Check if file is locally readable before detecting failure
                if FileManager.default.isReadableFile(atPath: url.path) {
                    print("✅ File is readable despite iCloud error: \(url.lastPathComponent)")
                    resetFailureCount()
                    return
                }
                
                // Only detect failure if file is not readable
                print("⚠️ iCloud error and file not readable - detecting failure")
                detectSystematicFailure()
                
                if hasDetectedSystematicFailure {
                    print("❌ Systematic failure - file not available: \(url.lastPathComponent)")
                    throw CloudDownloadError.fileNotFound
                }
                
                return
            }
        } else {
            print("📁 File is local (not iCloud): \(url.lastPathComponent)")
        }
        
        // For non-iCloud files, just check if readable
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            print("❌ File is not readable: \(url.lastPathComponent)")
            throw CloudDownloadError.fileNotFound
        }
        
        print("✅ File is readable: \(url.lastPathComponent)")
    }
    
    @MainActor
    private func startDownload(_ url: URL) async {
        guard !downloadingFiles.contains(url) else { 
            print("⏭️ Already downloading: \(url.lastPathComponent)")
            return 
        }
        
        // Check if we're in offline mode due to authentication issues or systematic failures
        if AppCoordinator.shared.iCloudStatus == .authenticationRequired || !AppCoordinator.shared.isiCloudAvailable || hasDetectedSystematicFailure {
            print("🚫 Skipping download - iCloud authentication required, not available, or systematic failure detected: \(url.lastPathComponent)")
            return
        }
        
        // Check if file is already downloaded and readable - don't re-download
        if FileManager.default.fileExists(atPath: url.path) && FileManager.default.isReadableFile(atPath: url.path) {
            // For iCloud files, check actual download status to avoid unnecessary downloads
            if isUbiquitous(url) {
                do {
                    let resourceValues = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                    if let status = resourceValues.ubiquitousItemDownloadingStatus {
                        switch status {
                        case .current, .downloaded:
                            print("✅ File already downloaded and readable - skipping: \(url.lastPathComponent)")
                            resetFailureCount()
                            return
                        case .notDownloaded:
                            print("🔽 File needs downloading despite being readable: \(url.lastPathComponent)")
                            break // Continue with download
                        default:
                            print("🔽 Unknown status - will attempt download: \(url.lastPathComponent)")
                            break // Continue with download
                        }
                    } else {
                        print("✅ File is readable, assuming already available: \(url.lastPathComponent)")
                        resetFailureCount()
                        return
                    }
                } catch {
                    print("✅ File is readable despite status check error - skipping download: \(url.lastPathComponent)")
                    resetFailureCount()
                    return
                }
            } else {
                print("✅ Local file already readable - skipping download: \(url.lastPathComponent)")
                return
            }
        } else {
            print("🚫 File not found or not readable: \(url.lastPathComponent)")
            return
        }
        
        print("🔽 Starting download for: \(url.lastPathComponent)")
        downloadingFiles.insert(url)
        downloadProgress[url] = 0.0
        
        do {
            // Start downloading the iCloud file
            if isUbiquitous(url) {
                try FileManager.default.startDownloadingUbiquitousItem(at: url)
                print("📡 Initiated iCloud download for: \(url.lastPathComponent)")
                print("🎯 NSMetadataQuery will now track real progress...")
                
                // Start a fallback progress monitor in case NSMetadataQuery doesn't work
                startFallbackProgressMonitor(url)
                
            } else {
                print("⚠️ File is not ubiquitous: \(url.lastPathComponent)")
                // For local files, mark as complete immediately
                downloadProgress[url] = 1.0
                downloadingFiles.remove(url)
            }
        } catch {
            print("💥 Failed to start download for \(url.lastPathComponent): \(error)")
            
            // Check if this is a timeout or authentication error
            if let nsError = error as NSError? {
                if nsError.domain == NSPOSIXErrorDomain && nsError.code == 60 {
                    print("⏰ Timeout error at download start - detecting systematic failure")
                    detectSystematicFailure()
                } else if nsError.domain == NSPOSIXErrorDomain && nsError.code == 81 {
                    print("🔐 Authentication error at download start - detecting systematic failure")
                    detectSystematicFailure()
                }
            }
            
            downloadingFiles.remove(url)
            downloadProgress.removeValue(forKey: url)
        }
    }
    
    private func startFallbackProgressMonitor(_ url: URL) {
        let task = Task {
            var attempts = 0
            let maxAttempts = 60 // 30 seconds max
            
            while attempts < maxAttempts && downloadingFiles.contains(url) {
                do {
                    let resourceValues = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                    
                    if let status = resourceValues.ubiquitousItemDownloadingStatus {
                        print("🔄 Fallback check - \(url.lastPathComponent): \(status)")
                        
                        switch status {
                        case .current, .downloaded:
                            await MainActor.run {
                                downloadProgress[url] = 1.0
                                downloadingFiles.remove(url)
                                downloadTasks.removeValue(forKey: url)
                            }
                            print("✅ Download complete via fallback: \(url.lastPathComponent)")
                            return
                            
                        case .notDownloaded:
                            // Show incremental progress
                            let progress = min(0.9, Double(attempts) / Double(maxAttempts))
                            await MainActor.run {
                                downloadProgress[url] = progress
                            }
                            print("⏳ Fallback progress: \(url.lastPathComponent) - \(Int(progress * 100))%")
                            
                        default:
                            break
                        }
                    }
                } catch {
                    print("❌ Fallback progress check failed: \(error)")
                    
                    // Check if this is a timeout or authentication error
                    if let nsError = error as NSError? {
                        if nsError.domain == NSPOSIXErrorDomain && nsError.code == 60 {
                            print("⏰ Timeout detected during progress check - detecting systematic failure")
                            await MainActor.run {
                                CloudDownloadManager.shared.detectSystematicFailure()
                            }
                            return
                        } else if nsError.domain == NSPOSIXErrorDomain && nsError.code == 81 {
                            print("🔐 Authentication error detected during progress check - detecting systematic failure")
                            await MainActor.run {
                                CloudDownloadManager.shared.detectSystematicFailure()
                            }
                            return
                        }
                    }
                }
                
                attempts += 1
                try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            }
            
            // Timeout - assume download failed and check if we should switch to offline mode
            await MainActor.run {
                if downloadingFiles.contains(url) {
                    print("⏰ Download timeout for: \(url.lastPathComponent)")
                    downloadingFiles.remove(url)
                    downloadProgress.removeValue(forKey: url)
                    downloadTasks.removeValue(forKey: url)
                    
                    // If any files are timing out, detect systematic failure
                    print("🚫 Download timeout detected - detecting systematic failure")
                    detectSystematicFailure()
                }
            }
        }
        
        downloadTasks[url] = task
    }
    
    func cancelDownload(_ url: URL) {
        downloadTasks[url]?.cancel()
        downloadTasks.removeValue(forKey: url)
        downloadingFiles.remove(url)
        downloadProgress.removeValue(forKey: url)
        
        // Try to cancel the iCloud download
        if isUbiquitous(url) {
            // Note: There's no direct API to cancel iCloud downloads
            // The system manages this automatically
            print("🚫 Cancelled download for: \(url.lastPathComponent)")
        }
    }
    
    deinit {
        progressQuery?.stop()
        NotificationCenter.default.removeObserver(self)
    }
    
    func isDownloaded(_ url: URL) -> Bool {
        // For iCloud files, check the proper download status
        if isUbiquitous(url) {
            do {
                let resourceValues = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                
                if let status = resourceValues.ubiquitousItemDownloadingStatus {
                    let isDownloaded = status == .downloaded || status == .current
                    print("📋 File \(url.lastPathComponent) download status: \(status), isDownloaded: \(isDownloaded)")
                    return isDownloaded
                }
                
                print("⚠️ No download status available for \(url.lastPathComponent)")
                return false
            } catch {
                print("❌ Failed to check download status for \(url.lastPathComponent): \(error)")
                return FileManager.default.isReadableFile(atPath: url.path)
            }
        }
        
        // For local files, just check if readable
        let isReadable = FileManager.default.isReadableFile(atPath: url.path)
        print("📄 Local file \(url.lastPathComponent) isReadable: \(isReadable)")
        return isReadable
    }
    
    func isUbiquitous(_ url: URL) -> Bool {
        do {
            let resourceValues = try url.resourceValues(forKeys: [.isUbiquitousItemKey])
            let isUbiquitous = resourceValues.isUbiquitousItem ?? false
            print("🔍 File \(url.lastPathComponent) isUbiquitous: \(isUbiquitous)")
            return isUbiquitous
        } catch {
            print("❌ Error checking if file is ubiquitous: \(error)")
            return false
        }
    }
}

enum CloudDownloadError: Error {
    case fileNotFound
    case downloadFailed
    case hasConflicts
    case iCloudNotAvailable
    case authenticationRequired
    case accessDenied
}
