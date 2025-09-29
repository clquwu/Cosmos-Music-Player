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
        guard let playMediaIntent = intent as? INPlayMediaIntent else {
            completionHandler(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
            return
        }

        Task { @MainActor in
            await AppCoordinator.shared.handleSiriPlaybackIntent(playMediaIntent, completion: completionHandler)
        }
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Set up Siri vocabulary and media context
        setupSiriIntegration()
        return true
    }

    private func setupSiriIntegration() {
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
                        "liste de lecture", "playlist", "playlists"
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
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appCoordinator)
                .task {
                    await appCoordinator.initialize()
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

        // Configure audio for background playback - critical for SFBAudioEngine stability
        Task { @MainActor in
            // Optimize SFBAudioEngine for lock screen stability
            if PlayerEngine.shared.isPlaying {
                await optimizeSFBAudioForBackground()
            }

            // Stop high-frequency timers when backgrounded
            PlayerEngine.shared.stopPlaybackTimer()
        }
    }
    
    private func handleWillEnterForeground() {
        // Restart timers when foregrounding
        Task { @MainActor in
            // Restore audio configuration when returning to foreground
            if PlayerEngine.shared.isPlaying {
                await optimizeSFBAudioForForeground()
                PlayerEngine.shared.startPlaybackTimer()
            }

            // Check for new shared files and refresh library
            await LibraryIndexer.shared.copyFilesFromSharedContainer()
            if !LibraryIndexer.shared.isIndexing {
                LibraryIndexer.shared.start()
            }
        }
    }
    
    private func handleWillResignActive() {
        // Re-assert the session as we background - no mixWithOthers in background
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playback, mode: .default, options: []) // no mixWithOthers in bg
            try s.setActive(true, options: [])
            print("🎧 Session keepalive on resign active - success")
        } catch { 
            print("❌ Session keepalive fail:", error) 
        }
    }
    
    private func handleOpenURL(_ url: URL) {
        print("🔗 Received URL: \(url.absoluteString)")
        
        guard url.scheme == "cosmos-music" else {
            print("❌ Unknown URL scheme: \(url.scheme ?? "nil")")
            return
        }
        
        if url.host == "refresh" {
            print("📁 URL triggered library refresh")
            Task { @MainActor in
                await LibraryIndexer.shared.copyFilesFromSharedContainer()
                if !LibraryIndexer.shared.isIndexing {
                    LibraryIndexer.shared.start()
                }
            }
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

    // MARK: - SFBAudioEngine Background Optimization

    private func optimizeSFBAudioForBackground() async {
        print("🔒 Optimizing SFBAudioEngine for background/lock screen")

        // Increase buffer size significantly for background stability
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setPreferredIOBufferDuration(0.100) // 100ms buffer for lock screen
            print("✅ Increased buffer to 100ms for lock screen stability")
        } catch {
            print("⚠️ Failed to increase buffer for background: \(error)")
        }

        // Simplified audio session for background
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            print("✅ Audio session optimized for background playback")
        } catch {
            print("⚠️ Failed to optimize audio session for background: \(error)")
        }
    }

    private func optimizeSFBAudioForForeground() async {
        print("🔓 Restoring SFBAudioEngine for foreground")

        // Restore normal buffer size
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setPreferredIOBufferDuration(0.040) // Back to 40ms
            print("✅ Restored buffer to 40ms for foreground")
        } catch {
            print("⚠️ Failed to restore buffer for foreground: \(error)")
        }

        // Restore full audio session options
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.allowBluetooth, .allowBluetoothA2DP])
            print("✅ Audio session restored for foreground playback")
        } catch {
            print("⚠️ Failed to restore audio session for foreground: \(error)")
        }
    }
}
