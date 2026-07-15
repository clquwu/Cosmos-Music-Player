//
//  DebugIntents.swift
//  Cosmos Music Player
//
//  DEBUG-only intents the AppIntentsTesting bundle drives to put the
//  Spotlight index into a known state. Excluded from release builds by the
//  DEBUG gate; isDiscoverable keeps them out of Shortcuts either way.
//

#if DEBUG && canImport(MediaIntents)
import AppIntents
import CoreSpotlight

@available(iOS 27.0, *)
struct ClearSpotlightIntent: AppIntent {
    static let title: LocalizedStringResource = "Clear Spotlight Index"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        try await CSSearchableIndex(name: SpotlightLibraryIndexer.indexName).deleteAllSearchableItems()
        return .result()
    }
}

@available(iOS 27.0, *)
struct ReindexSpotlightIntent: AppIntent {
    static let title: LocalizedStringResource = "Reindex Spotlight"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await SpotlightLibraryIndexer.shared.reindexAll()
        return .result()
    }
}

#endif // DEBUG && canImport(MediaIntents)
