//
//  AppIntentsDependencies.swift
//  Cosmos Music Player
//
//  Registers the services App Intents resolve via @Dependency. Must run at
//  process launch — intents can execute without the UI ever appearing.
//

import AppIntents

@available(iOS 26.0, *)
enum AppIntentsDependencies {
    @MainActor
    static func register() {
        AppDependencyManager.shared.add(dependency: IntentPlaybackService())
        #if canImport(MediaIntents)
        if #available(iOS 27.0, *) {
            AppDependencyManager.shared.add(dependency: IntentEntityStore())
        }
        #endif
    }
}
