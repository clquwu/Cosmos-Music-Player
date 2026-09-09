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
            // Only resume monitoring if downloads are actually in flight -
            // restoring auth is not by itself a reason to start watching the
            // whole container again.
            startProgressQueryIfNeeded()
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

        // Support all audio formats for progress monitoring
        let formats = ["*.flac", "*.mp3", "*.wav", "*.m4a", "*.aac", "*.opus", "*.ogg", "*.oga", "*.dsf", "*.dff"]
        // LIKE[c]: without the [c] modifier the match is case-sensitive, so a
        // file named TRACK.FLAC never matched "*.flac" and its download
        // progress was never reported. LibraryIndexer's query was fixed for
        // the same reason; this one was missed.
        let formatPredicates = formats.map { format in
            NSPredicate(format: "%K LIKE[c] %@", NSMetadataItemFSNameKey, format)
        }
        progressQuery?.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: formatPredicates)
        
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
        
        // Deliberately NOT started here. A live NSMetadataQuery continuously
        // monitors the whole ubiquitous Documents scope, and every iCloud
        // change woke us to walk all results even with nothing downloading.
        // It is now started on demand by startProgressQueryIfNeeded() and torn
        // down again as soon as the last download finishes.
    }

    /// Begin monitoring download progress. Safe to call repeatedly; does
    /// nothing unless a download is actually in flight.
    private func startProgressQueryIfNeeded() {
        guard !isQueryRunning, !downloadingFiles.isEmpty, let query = progressQuery else { return }
        guard AppCoordinator.shared.iCloudStatus != .authenticationRequired,
              AppCoordinator.shared.isiCloudAvailable,
              !hasDetectedSystematicFailure else { return }

        query.start()
        isQueryRunning = true
        print("▶️ Started NSMetadataQuery to track \(downloadingFiles.count) download(s)")
    }

    /// Stop monitoring once nothing is being downloaded, so idle iCloud
    /// activity no longer wakes the app.
    private func stopProgressQueryIfIdle() {
        guard isQueryRunning, downloadingFiles.isEmpty, let query = progressQuery else { return }
        query.stop()
        isQueryRunning = false
        print("🛑 Stopped NSMetadataQuery - no downloads in flight")
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

        // Nothing to track: don't walk every file in the container (this loop
        // used to run over the entire library on every iCloud change, logging
        // two lines per file), and shut the query down until a download starts.
        guard !downloadingFiles.isEmpty else {
            stopProgressQueryIfIdle()
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
                        finishTrackingDownload(url)
                        print("✅ Download complete via NSMetadataQuery: \(url.lastPathComponent)")
                        
                    case .downloaded:
                        // Downloaded but may not be current
                        finishTrackingDownload(url)
                        print("✅ Download finished via NSMetadataQuery: \(url.lastPathComponent)")
                        
                    case .notDownloaded:
                        // Get actual download progress
                        if let progress = item.value(forAttribute: NSMetadataUbiquitousItemPercentDownloadedKey) as? NSNumber {
                            let progressValue = progress.doubleValue / 100.0
                            recordRealProgress(progressValue, for: url)
                            print("📈 Real download progress: \(url.lastPathComponent) - \(Int(progressValue * 100))%")
                        } else {
                            // A provider can omit the percentage on a later
                            // metadata update after publishing it earlier. Keep
                            // the numeric high-water mark already recorded; a
                            // missing value is not evidence of progress.
                            print("⚠️ No progress percentage available for: \(url.lastPathComponent)")
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

        // The loop above may have completed the last tracked download.
        stopProgressQueryIfIdle()
    }

    
        
    /// True when the bytes are actually present, not just a placeholder.
    private func isLocallyAvailable(_ url: URL) -> Bool {
        Self.isLocallyResident(url)
    }

    /// The residency test, off the main actor.
    ///
    /// `isLocallyAvailable` is the main-actor entry point; callers that only
    /// need the answer - the gapless preload paths, the stall monitors - must
    /// use this one instead, because every check here is synchronous file I/O.
    nonisolated static func isLocallyResident(_ url: URL) -> Bool {
        guard FileManager.default.isReadableFile(atPath: url.path) else { return false }
        let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ])
        guard values?.isUbiquitousItem == true else { return true }
        guard let status = values?.ubiquitousItemDownloadingStatus else { return false }
        return status == .current || status == .downloaded
    }

    /// A monotonically-increasing witness that a download is genuinely moving.
    ///
    /// `NSMetadataUbiquitousItemPercentDownloadedKey` is the only source of a
    /// percentage, and Apple documents its range but guarantees nothing about
    /// how often a provider publishes it: small files routinely jump straight
    /// from 0 to 100, and a healthy transfer over a slow link can go minutes
    /// between updates. Treating "no new percentage" as "stalled" therefore
    /// rejected downloads that were running perfectly well.
    ///
    /// The bytes already materialised on disk are a second, independent
    /// witness. It is deliberately the *allocated* size and not `fileSize`:
    /// a ubiquitous placeholder reports the final logical size from the moment
    /// it appears, while the allocated size grows with the transfer.
    struct DownloadProgressMarker: Equatable {
        var percent: Double = 0
        var residentBytes: Int64 = 0

        func advanced(over previous: DownloadProgressMarker) -> Bool {
            percent > previous.percent || residentBytes > previous.residentBytes
        }
    }

    nonisolated static func residentByteCount(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey
        ])
        if let total = values?.totalFileAllocatedSize { return Int64(total) }
        if let allocated = values?.fileAllocatedSize { return Int64(allocated) }
        return 0
    }

    /// Builds a marker off the main actor. `percent` is passed in because it
    /// lives in main-actor state; the byte count is the part that touches disk.
    nonisolated static func progressMarker(
        percent: Double,
        for url: URL
    ) -> DownloadProgressMarker {
        DownloadProgressMarker(percent: percent, residentBytes: residentByteCount(of: url))
    }

    private func recordRealProgress(_ progress: Double, for url: URL) {
        let normalized = min(max(progress, 0), 1)
        downloadProgress[url] = max(downloadProgress[url] ?? 0, normalized)
    }

    private func finishTrackingDownload(_ url: URL) {
        if downloadingFiles.contains(url) || downloadProgress[url] != nil {
            downloadProgress[url] = 1.0
        }
        downloadingFiles.remove(url)
        downloadTasks.removeValue(forKey: url)
        stopProgressQueryIfIdle()
    }

    /// Forgets a download that is not going to land.
    ///
    /// Every abandonment has to come through here. A URL left in
    /// `downloadingFiles` keeps `stopProgressQueryIfIdle()` from ever stopping
    /// the container-wide NSMetadataQuery, keeps `waitForDownload` believing a
    /// transfer is still in flight, and - because `startDownload` refuses a URL
    /// it is already tracking - permanently blocks the retry that would fix it.
    private func stopTrackingDownload(_ url: URL, reason: String) {
        let wasTracked = downloadingFiles.contains(url)
            || downloadProgress[url] != nil
            || downloadTasks[url] != nil
        guard wasTracked else { return }

        downloadingFiles.remove(url)
        downloadProgress.removeValue(forKey: url)
        downloadTasks.removeValue(forKey: url)
        stopProgressQueryIfIdle()
        print("⏹️ Stopped tracking download (\(reason)): \(url.lastPathComponent)")
    }

    private func isTrackingDownload(_ url: URL) -> Bool {
        downloadingFiles.contains(url)
    }

    private func recordedProgress(for url: URL) -> Double {
        downloadProgress[url] ?? 0
    }

    /// Reads a ubiquitous item's residency without touching the main actor -
    /// `resourceValues` is synchronous file I/O and the fallback monitor polls
    /// it for the whole life of a download.
    private nonisolated static func downloadingStatus(
        of url: URL
    ) throws -> URLUbiquitousItemDownloadingStatus? {
        try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            .ubiquitousItemDownloadingStatus
    }

    /// Waits, bounded, for an in-flight download to land. ensureLocal used to
    /// fire off startDownload and return immediately, so callers went straight
    /// on to open a file whose bytes had not arrived.
    private func waitForDownload(_ url: URL, timeout: TimeInterval) async throws -> Bool {
        guard timeout > 0 else { return isLocallyAvailable(url) }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if isLocallyAvailable(url) { return true }
            if !downloadingFiles.contains(url) { return isLocallyAvailable(url) }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        return isLocallyAvailable(url)
    }

    private func requestDownloadAndWait(_ url: URL, timeout: TimeInterval) async throws {
        print("🔽 File is not local - requesting download: \(url.lastPathComponent)")
        await startDownload(url)

        if try await waitForDownload(url, timeout: timeout) {
            print("✅ Download completed: \(url.lastPathComponent)")
            finishTrackingDownload(url)
            resetFailureCount()
            return
        }

        print("⏳ File is still downloading: \(url.lastPathComponent)")
        throw CloudDownloadError.downloadPending
    }

    /// - Parameter downloadTimeout: how long to wait for a cloud-only file.
    ///   Pass 0 to request the download without blocking - the library scanner
    ///   does that so a first run over an un-fetched library still starts every
    ///   download without serialising on them.
    func ensureLocal(_ url: URL, downloadTimeout: TimeInterval = 20) async throws {
        print("🔍 ensureLocal called for: \(url.lastPathComponent)")
        
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("❌ File does not exist: \(url.lastPathComponent)")
            throw CloudDownloadError.fileNotFound
        }
        
        print("✅ File exists: \(url.lastPathComponent)")
        let ubiquitous = isUbiquitous(url)
        
        // Early check for iCloud authentication issues or systematic failures - prevent ANY iCloud operations
        if AppCoordinator.shared.iCloudStatus == .authenticationRequired || !AppCoordinator.shared.isiCloudAvailable || hasDetectedSystematicFailure {
            print("🚫 Skipping iCloud operations - authentication required, not available, or systematic failure detected: \(url.lastPathComponent)")
            // A ubiquitous placeholder can appear readable because that API
            // checks permissions, not byte residency. Only the downloading
            // status proves it is safe to open.
            if ubiquitous, !isLocallyAvailable(url) {
                print("⏳ iCloud placeholder is not local while cloud access is unavailable: \(url.lastPathComponent)")
                throw CloudDownloadError.downloadPending
            }
            guard ubiquitous || FileManager.default.isReadableFile(atPath: url.path) else {
                print("❌ File is not readable and iCloud unavailable: \(url.lastPathComponent)")
                throw CloudDownloadError.fileNotFound
            }
            print("✅ File ensured local (offline mode): \(url.lastPathComponent)")
            return
        }
        
        // Check if this is an iCloud file that needs downloading
        if ubiquitous {
            print("☁️ File is ubiquitous: \(url.lastPathComponent)")
            do {
                let resourceValues = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                
                if let downloadStatus = resourceValues.ubiquitousItemDownloadingStatus {
                    print("📊 Download status for \(url.lastPathComponent): \(downloadStatus)")
                    switch downloadStatus {
                    case .notDownloaded:
                        // A cloud-only file that simply has not been fetched
                        // yet is a normal state, NOT evidence of a broken
                        // iCloud account. Counting it as a systematic failure
                        // pushed the whole app into offline mode after three
                        // such files. Genuine auth/timeout errors are still
                        // detected inside startDownload and the progress
                        // monitor, which is where they belong.
                        try await requestDownloadAndWait(url, timeout: downloadTimeout)
                        return
                        
                    case .downloaded:
                        print("✅ File already downloaded: \(url.lastPathComponent)")
                        finishTrackingDownload(url)
                        resetFailureCount() // Success case
                        return
                    case .current:
                        print("✅ File is current: \(url.lastPathComponent)")
                        finishTrackingDownload(url)
                        resetFailureCount() // Success case
                        return
                    default:
                        print("⚠️ Unknown download status for \(url.lastPathComponent): \(downloadStatus)")
                        try await requestDownloadAndWait(url, timeout: downloadTimeout)
                        return
                    }
                } else {
                    print("⚠️ No download status available - requesting iCloud materialization")
                    try await requestDownloadAndWait(url, timeout: downloadTimeout)
                    return
                }
            } catch let cloudError as CloudDownloadError {
                // Errors this method raised itself are already classified, and
                // downloadPending in particular describes a normal state, not a
                // failure. Letting them fall into the generic handler below
                // rewrote every one of them as fileNotFound and counted it
                // towards systematic failure, so three not-yet-fetched
                // placeholders pushed the whole app into offline mode - and the
                // scanner's pending-download handling never ran at all.
                throw cloudError
            } catch is CancellationError {
                // A superseding track selection cancels its bounded wait. Do
                // not rewrite cancellation as an iCloud account failure.
                throw CancellationError()
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
                
                // Read permission still does not prove that a ubiquitous
                // item's bytes exist. Ask iCloud to materialize it and report
                // the normal pending state to the scanner/player.
                try await requestDownloadAndWait(url, timeout: downloadTimeout)
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

    /// Keeps a playback request parked until an already-requested iCloud file
    /// becomes readable. The wait is cancellable, so selecting another track
    /// or pressing Stop cannot start this one later. Short bounded ensureLocal
    /// calls also recover if the progress monitor had to restart the request.
    /// - Parameter stallTimeout: how long the download may make no progress at
    ///   all before the wait gives up. The wait used to be unbounded, which is
    ///   only correct while iCloud is genuinely reachable: ordinary network
    ///   loss after launch is never recorded anywhere, so `iCloudStatus` stays
    ///   `.available`, `ensureLocal` keeps answering `.downloadPending`, and
    ///   the caller parked in `.loading` for ever with nothing on screen.
    ///   Measured against *progress*, not total elapsed time, so a genuinely
    ///   slow download of a large DSD file is never cut off part-way.
    ///
    ///   "Progress" means either a higher published percentage or more bytes
    ///   materialised on disk - see `DownloadProgressMarker`. The percentage
    ///   alone was not enough: nothing guarantees a provider republishes it
    ///   within any particular window, so a healthy transfer could be declared
    ///   stalled purely because iCloud had not spoken for `stallTimeout`.
    ///   `ubiquitousItemIsDownloading` is deliberately still not consulted -
    ///   it is a request-state flag that stays true across a dead connection.
    func waitUntilLocal(_ url: URL, stallTimeout: TimeInterval = 45) async throws {
        // Initialise only after ensureLocal has started/restarted the request.
        // A completed value retained from an earlier download must not become
        // an unreachable high-water mark for a newly-evicted placeholder.
        var lastMarker: DownloadProgressMarker?
        var lastProgressAt = Date()

        while true {
            try Task.checkCancellation()

            do {
                try await ensureLocal(url, downloadTimeout: 5)
                return
            } catch CloudDownloadError.downloadPending {
                let percent = downloadProgress[url] ?? 0
                let marker = await Task.detached(priority: .utility) {
                    CloudDownloadManager.progressMarker(percent: percent, for: url)
                }.value

                if let previous = lastMarker {
                    if marker.advanced(over: previous) {
                        lastMarker = marker
                        lastProgressAt = Date()
                    } else if Date().timeIntervalSince(lastProgressAt) >= stallTimeout {
                        print("⌛️ Giving up on stalled iCloud download: \(url.lastPathComponent)")
                        throw CloudDownloadError.downloadStalled
                    }
                } else {
                    lastMarker = marker
                    lastProgressAt = Date()
                }

                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
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
        
        // An unreadable ubiquitous placeholder is precisely the case that needs
        // downloading, but it used to fall into the "not found or not readable"
        // return below and never reach startDownloadingUbiquitousItem at all.
        let fileExists = FileManager.default.fileExists(atPath: url.path)
        let fileReadable = FileManager.default.isReadableFile(atPath: url.path)

        if !fileExists {
            print("🚫 File not found: \(url.lastPathComponent)")
            return
        }

        if !fileReadable && !isUbiquitous(url) {
            print("🚫 Local file is not readable: \(url.lastPathComponent)")
            return
        }

        // Check if file is already downloaded and readable - don't re-download
        if fileExists && fileReadable {
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
                        print("🔽 No downloading status; requesting materialization: \(url.lastPathComponent)")
                    }
                } catch {
                    print("🔽 Could not verify byte residency; requesting materialization: \(url.lastPathComponent)")
                }
            } else {
                print("✅ Local file already readable - skipping download: \(url.lastPathComponent)")
                return
            }
        }
        
        print("🔽 Starting download for: \(url.lastPathComponent)")
        downloadingFiles.insert(url)
        downloadProgress[url] = 0.0
        // Progress monitoring only runs while something is actually downloading.
        startProgressQueryIfNeeded()
        
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
                stopProgressQueryIfIdle()
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
            
            stopTrackingDownload(url, reason: "could not be started")
        }
    }

    /// How long a monitored download may make no measurable progress before
    /// the monitor gives up and untracks it. Measured against progress rather
    /// than total elapsed time, so a genuinely slow transfer of a large DSD
    /// file is never cut off part-way.
    private static let fallbackStallTimeout: TimeInterval = 180

    private func startFallbackProgressMonitor(_ url: URL) {
        let stallTimeout = Self.fallbackStallTimeout

        // Detached on purpose. A bare `Task` inherits this class's main-actor
        // isolation, so the synchronous `resourceValues` poll below ran on the
        // main thread - once every two seconds, for every file being fetched.
        let task = Task.detached(priority: .utility) { [weak self] in
            // Only ever exits through completion, cancellation, or one of the
            // untracking paths below. An unbounded loop here kept the URL in
            // `downloadingFiles` for the life of the process.
            var lastMarker: DownloadProgressMarker?
            var lastProgressAt = Date()

            while true {
                try Task.checkCancellation()

                guard let self else { return }
                guard await self.isTrackingDownload(url) else { return }

                do {
                    switch try Self.downloadingStatus(of: url) {
                    case .current, .downloaded:
                        await self.finishTrackingDownload(url)
                        print("✅ Download complete via fallback: \(url.lastPathComponent)")
                        return

                    case .notDownloaded:
                        // iOS exposes the real percentage only through the
                        // live NSMetadataQuery above. This fallback checks
                        // completion; it must never invent progress from
                        // elapsed time or overwrite the query's real value.
                        break

                    default:
                        break
                    }
                } catch {
                    print("❌ Fallback progress check failed: \(error)")

                    // Check if this is a timeout or authentication error
                    if let nsError = error as NSError? {
                        if nsError.domain == NSPOSIXErrorDomain && nsError.code == 60 {
                            print("⏰ Timeout detected during progress check - detecting systematic failure")
                            await self.stopTrackingDownload(url, reason: "iCloud timed out")
                            await self.detectSystematicFailure()
                            return
                        } else if nsError.domain == NSPOSIXErrorDomain && nsError.code == 81 {
                            print("🔐 Authentication error detected during progress check - detecting systematic failure")
                            await self.stopTrackingDownload(url, reason: "iCloud authentication failed")
                            await self.detectSystematicFailure()
                            return
                        }
                    }
                }

                // Give up once nothing has arrived for the stall window. The
                // URL is untracked rather than left in flight, so a later
                // ensureLocal starts a fresh request instead of waiting on a
                // transfer that is never going to finish.
                //
                // Same witness as waitUntilLocal: bytes on disk count as
                // progress even while the published percentage sits still.
                let percent = await self.recordedProgress(for: url)
                let marker = Self.progressMarker(percent: percent, for: url)
                if let previous = lastMarker {
                    if marker.advanced(over: previous) {
                        lastMarker = marker
                        lastProgressAt = Date()
                    } else if Date().timeIntervalSince(lastProgressAt) >= stallTimeout {
                        await self.stopTrackingDownload(
                            url,
                            reason: "no progress for \(Int(stallTimeout))s"
                        )
                        return
                    }
                } else {
                    lastMarker = marker
                    lastProgressAt = Date()
                }

                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }

        downloadTasks[url] = task
    }
    
    func cancelDownload(_ url: URL) {
        // Through stopTrackingDownload so this cannot drift from the invariant
        // that method documents - every abandonment untracks the same fields.
        downloadTasks[url]?.cancel()
        stopTrackingDownload(url, reason: "cancelled by request")
        downloadTasks.removeValue(forKey: url)

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
    /// The file is a cloud placeholder whose download has been requested but
    /// has not landed yet. Distinct from fileNotFound so callers can retry
    /// later instead of treating it as a missing or broken file.
    case downloadPending
    /// A wait for a pending download gave up because nothing arrived for the
    /// stall window. Distinct from downloadPending: the caller should stop
    /// waiting and tell the user, not retry silently.
    case downloadStalled
    case downloadFailed
    case hasConflicts
    case iCloudNotAvailable
    case authenticationRequired
    case accessDenied
}
