//
//  Cosmos_Music_PlayerApp.swift
//  Cosmos Music Player
//
//  Created by CLQ on 28/08/2025.
//

import SwiftUI
import AVFoundation
import Intents

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handle intent: INIntent, completionHandler: @escaping (INIntentResponse) -> Void) {
        SiriDiag.log("APP AppDelegate.handle intent=\(type(of: intent))")
        if let playMediaIntent = intent as? INPlayMediaIntent {
            Task { @MainActor in
                await AppCoordinator.shared.handleSiriPlaybackIntent(playMediaIntent, completion: completionHandler)
            }
        } else if let addMediaIntent = intent as? INAddMediaIntent {
            Task { @MainActor in
                await AppCoordinator.shared.handleSiriAddMediaIntent(addMediaIntent, completion: completionHandler)
            }
        } else {
            completionHandler(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
        }
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        SiriDiag.log("APP didFinishLaunching")
        // Set up Siri vocabulary and media context
        setupSiriIntegration()
        return true
    }

    private func setupSiriIntegration() {
        // Donate vocabulary on every OS version: Siri keeps routing by-name
        // media requests through the legacy SiriKit extension even on iOS 27
        // with assistant schemas registered, so the old recognizer still
        // needs playlist/artist names.
        DispatchQueue.global(qos: .userInitiated).async {
            // Set up vocabulary for playlists, artists, and albums
            Task { @MainActor in
                do {
                    // Playlist vocabulary
                    let playlists = try AppCoordinator.shared.databaseManager.getAllPlaylists()
                    var playlistVocabulary = playlists.map { $0.title }

                    // Add French playlist generic terms to help recognition
                    playlistVocabulary.append(contentsOf: [
                        "ma playlist", "ma liste de lecture", "mes playlists",
                        "liste de lecture", "playlist", "playlists",
                        "Liked Songs", "Favorites", "Favourites", "Favoris"
                    ])

                    let playlistNames = NSOrderedSet(array: playlistVocabulary)
                    INVocabulary.shared().setVocabularyStrings(playlistNames, of: .mediaPlaylistTitle)
                    print("✅ Set up vocabulary for \(playlistNames.count) playlist terms")

                } catch {
                    print("❌ Failed to set up vocabulary: \\(error)")
                }
            }

            // Create media user context
            let context = INMediaUserContext()
            Task { @MainActor in
                do {
                    let trackCount = try AppCoordinator.shared.databaseManager.getAllTracks().count
                    context.numberOfLibraryItems = trackCount
                    context.subscriptionStatus = .notSubscribed // Since this is a local music app
                    context.becomeCurrent()
                } catch {
                    print("❌ Failed to set up media context: \\(error)")
                }
            }
        }
    }
}

@main
struct Cosmos_Music_PlayerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appCoordinator = AppCoordinator.shared

    init() {
        if #available(iOS 26.0, *) {
            AppIntentsDependencies.register()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appCoordinator)
                .task {
                    DatabaseSuspensionCoordinator.shared.start()
                    await appCoordinator.initialize()
                    #if canImport(MediaIntents)
                    if #available(iOS 27.0, *) {
                        SpotlightLibraryIndexer.shared.activate()
                    }
                    #endif
                    await createiCloudContainerPlaceholder()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIScene.didEnterBackgroundNotification)) { _ in
                    handleDidEnterBackground()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIScene.willEnterForegroundNotification)) { _ in
                    handleWillEnterForeground()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIScene.willDeactivateNotification)) { _ in
                    handleWillResignActive()
                }
                .onOpenURL { url in
                    handleOpenURL(url)
                }
                .onContinueUserActivity("com.cosmos.music.play") { userActivity in
                    handleSiriIntent(userActivity)
                }
        }
    }
    
    private func handleDidEnterBackground() {
        print("🔍 DIAGNOSTIC - backgroundTimeRemaining:", UIApplication.shared.backgroundTimeRemaining)

        // Suspend view-update work after the app has actually entered background.
        Task { @MainActor in
            if PlayerEngine.shared.isAudioSessionInterrupted {
                print("🎧 Audio session interrupted - suspending UI timers only")
            }

            // Stop ALL high-frequency UI timers when backgrounded to prevent
            // SwiftUI redraws from spiking CPU and triggering the iOS watchdog
            // kill.
            //
            // Deliberately NOT behind an interruption guard - this touches no
            // audio state. It used to be, and that skipped it whenever a call
            // or alarm started before the user switched away: isInBackground
            // stayed false, so the auto-resume at the end of the interruption
            // started the 0.25s SwiftUI timer with the app still in the
            // background, and it stayed that way for the rest of the session
            // (only willEnterForeground clears the flag).
            PlayerEngine.shared.suspendUITimersForBackground()
        }
    }
    
    private func handleWillEnterForeground() {
        // Restart timers when foregrounding
        Task { @MainActor in
            // Restore all UI timers. Do not change the preferred I/O buffer on
            // a live session merely because the screen locked or unlocked:
            // that forces a route reconfiguration and can interrupt SFB audio.
            PlayerEngine.shared.resumeUITimersForForeground()

            // Check for new shared files and refresh library
            await LibraryIndexer.shared.copyFilesFromSharedContainer()

            // Only auto-scan if it's been a long time since last scan
            if !LibraryIndexer.shared.isIndexing {
                let settings = DeleteSettings.load()
                if shouldPerformAutoScan(
                    lastScanDate: settings.lastLibraryScanDate,
                    interval: settings.libraryScanInterval
                ) {
                    print("🔄 Foreground: Starting library scan (been a while since last scan)")
                    LibraryIndexer.shared.start()
                } else {
                    print("⏭️ Foreground: Skipping auto-scan (use manual sync button)")
                }
            }
        }
    }

    private func shouldPerformAutoScan(
        lastScanDate: Date?,
        interval: LibraryScanInterval
    ) -> Bool {
        // If never scanned before, definitely scan
        guard let lastScanDate = lastScanDate else {
            print("🆕 Never scanned before - will perform scan")
            return true
        }

        guard let cooldownHours = interval.cooldownHours else {
            print("⏭️ Foreground: automatic scanning is disabled")
            return false
        }

        let hoursSinceLastScan = Date().timeIntervalSince(lastScanDate) / 3600
        let shouldScan = hoursSinceLastScan >= cooldownHours

        if shouldScan {
            print("⏰ Last scan was \(String(format: "%.1f", hoursSinceLastScan))h ago (limit \(cooldownHours)h) - will scan")
        } else {
            print("⏰ Last scan was \(String(format: "%.1f", hoursSinceLastScan))h ago (limit \(cooldownHours)h) - skipping")
        }

        return shouldScan
    }
    
    private func handleWillResignActive() {
        guard PlayerEngine.shared.isPlaying else {
            // willDeactivate fires for every transient overlay - Control
            // Centre, Notification Centre, a banner, the app switcher, Face ID
            // - and isPlaying is also false for the whole of a track load. This
            // used to deactivate unconditionally with
            // .notifyOthersOnDeactivation, which told other audio apps to take
            // over: pausing and then pulling down Control Centre to press play
            // could hand the lock screen to another app, and a banner arriving
            // mid-load tore the session down underneath the load. Only release
            // when there is genuinely nothing loaded.
            if PlayerEngine.shared.canReleaseAudioSession {
                releaseAudioSessionIfIdle()
                print("🎧 Cosmos has nothing loaded - leaving audio focus with the current app")
            }
            return
        }

        // Don't re-grab the audio session if we're being interrupted by an alarm or call
        guard !PlayerEngine.shared.isAudioSessionInterrupted else {
            print("🎧 Audio session interrupted (alarm/call) - skipping session keepalive")
            return
        }

        // Re-assert the session as we background. Do NOT call setCategory here:
        // changing category/options on a live session forces an audio hardware
        // reconfiguration that stops AVAudioEngine mid-playback (CarPlay pauses
        // every time the phone locks).
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: [])
            print("🎧 Session keepalive on resign active - success")
        } catch {
            print("❌ Session keepalive fail:", error)
        }
    }

    private func releaseAudioSessionIfIdle() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("ℹ️ Audio session was already inactive or could not be released: \(error)")
        }
    }
    
    private func handleOpenURL(_ url: URL) {
        print("🔗 Received URL: \(url.absoluteString)")

        if url.isFileURL {
            Task { @MainActor in
                await importOpenedAudioDocument(url)
            }
            return
        }

        guard url.scheme == "cosmos-music" else {
            print("❌ Unknown URL scheme: \(url.scheme ?? "nil")")
            return
        }

        Task { @MainActor in
            switch url.host {
            case "refresh":
                print("📁 URL triggered library refresh - this is a manual refresh so always scan")
                await LibraryIndexer.shared.copyFilesFromSharedContainer()
                if !LibraryIndexer.shared.isIndexing {
                    LibraryIndexer.shared.start()
                }

            case "playlist":
                // Extract playlist ID from path
                let playlistId = url.pathComponents.dropFirst().joined(separator: "/")
                print("📋 Widget: Opening playlist - \(playlistId)")

                // Navigate to playlist
                if let playlistIdInt = Int64(playlistId) {
                    do {
                        let playlists = try appCoordinator.databaseManager.getAllPlaylists()
                        if let playlist = playlists.first(where: { $0.id == playlistIdInt }) {
                            // Post notification to navigate to playlist
                            NotificationCenter.default.post(
                                name: NSNotification.Name("NavigateToPlaylist"),
                                object: nil,
                                userInfo: ["playlistId": playlistIdInt]
                            )
                            print("✅ Widget: Navigating to playlist \(playlist.title)")
                        }
                    } catch {
                        print("❌ Widget: Failed to find playlist: \(error)")
                    }
                }

            default:
                print("⚠️ Unknown URL host: \(url.host ?? "nil")")
            }
        }
    }

    @MainActor
    private func importOpenedAudioDocument(_ url: URL) async {
        // A `false` answer is NOT a failure to open. The call returns false
        // both when access is denied and when the URL is simply not
        // security-scoped, which is exactly the case for a file that already
        // lives in Cosmos's own container - so treating it as fatal refused
        // every "Open in Cosmos" on a file the app could already read. Only a
        // successful start has to be balanced with a stop.
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        // Opening in place grants temporary access. Save the bookmark before
        // indexing so the row remains playable after this callback returns.
        do {
            await appCoordinator.databaseManager.waitForExternalBookmarkMigration()
            let bookmarkData = try url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let stableId = try LibraryIndexer.shared.generateStableId(for: url)
            try await ExternalBookmarkStore.shared.store(bookmarkData, for: stableId)
        } catch {
            // The immediate import can still succeed under the active scope;
            // keep the same graceful fallback as the document picker.
            print("⚠️ Could not persist bookmark for opened document: \(error)")
        }

        let imported = await LibraryIndexer.shared.processExternalFile(
            url,
            allowExcludedReimport: true
        )
        if imported {
            print("✅ Imported opened document: \(url.lastPathComponent)")
        } else {
            print("ℹ️ Opened document was already present or could not be imported: \(url.lastPathComponent)")
        }
    }

    private func handleSiriIntent(_ userActivity: NSUserActivity) {
        print("🎤 Received Siri intent: \(userActivity.activityType)")
        Task { @MainActor in
            await appCoordinator.handleSiriPlayIntent(userActivity: userActivity)
        }
    }

    private func createiCloudContainerPlaceholder() async {
        guard let iCloudURL = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            print("❌ iCloud Drive not available")
            return
        }
        
        let documentsURL = iCloudURL.appendingPathComponent("Documents")
        let placeholderURL = documentsURL.appendingPathComponent(".cosmos_placeholder")
        
        do {
            // Create Documents directory if it doesn't exist
            try FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true, attributes: nil)
            
            // Create placeholder file if it doesn't exist
            if !FileManager.default.fileExists(atPath: placeholderURL.path) {
                let placeholderText = "This folder contains music files for Cosmos Music Player.\nPlace your FLAC files here to add them to your library."
                try placeholderText.write(to: placeholderURL, atomically: true, encoding: .utf8)
                print("✅ Created iCloud Drive placeholder file to ensure folder visibility")
            }
        } catch {
            print("❌ Failed to create iCloud Drive placeholder: \(error)")
        }
    }

}
