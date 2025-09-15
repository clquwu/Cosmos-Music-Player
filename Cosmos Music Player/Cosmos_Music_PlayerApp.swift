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
        
        // Stop high-frequency timers when backgrounded
        Task { @MainActor in
            PlayerEngine.shared.stopPlaybackTimer()
        }
    }
    
    private func handleWillEnterForeground() {
        // Restart timers when foregrounding
        Task { @MainActor in
            if PlayerEngine.shared.isPlaying {
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
}
