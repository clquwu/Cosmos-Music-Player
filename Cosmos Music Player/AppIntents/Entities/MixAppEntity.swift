//
//  MixAppEntity.swift
//  Cosmos Music Player
//
//  The mixes Cosmos makes (Made for You and Rediscover) as an App Entity,
//  so "Joue <mix> dans Cosmos" works as an App Shortcut phrase. Two shelf
//  entries ("Made for You", "Rediscover") stand for the first mix of each
//  shelf, since those names change daily.
//

import AppIntents
import Foundation

@available(iOS 26.0, *)
struct MixAppEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Mix", comment: "Type name of a Cosmos mix in Shortcuts and Siri.")
    )
    static let defaultQuery = MixAppEntityQuery()

    static let madeForYouId = "shelf:madeForYou"
    static let rediscoverId = "shelf:rediscover"

    let id: String
    let title: String
    let subtitle: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(subtitle)",
            image: DisplayRepresentation.Image(systemName: "sparkles.rectangle.stack")
        )
    }

    @MainActor
    static var shelves: [MixAppEntity] {
        [
            MixAppEntity(id: madeForYouId, title: Localized.madeForYou, subtitle: Localized.siriVoiceSiriMixShelfSubtitle),
            MixAppEntity(id: rediscoverId, title: Localized.rediscover, subtitle: Localized.siriVoiceSiriMixShelfSubtitle)
        ]
    }

    @MainActor
    init(mix: Mix, shelf: CosmosSiriActions.MixShelf) {
        id = mix.id
        title = mix.title
        subtitle = shelf == .madeForYou ? Localized.madeForYou : Localized.rediscover
    }

    init(id: String, title: String, subtitle: String) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
    }
}

@available(iOS 26.0, *)
struct MixAppEntityQuery: EntityStringQuery {
    @MainActor
    private func all() async -> [MixAppEntity] {
        await CosmosSiriActions.ensureMixesLoaded(timeout: 1.5)
        return MixAppEntity.shelves + CosmosSiriActions.allMixes().map { MixAppEntity(mix: $0.mix, shelf: $0.shelf) }
    }

    @MainActor
    func entities(for identifiers: [MixAppEntity.ID]) async throws -> [MixAppEntity] {
        let wanted = Set(identifiers)
        return await all().filter { wanted.contains($0.id) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [MixAppEntity] {
        let query = ArtistMatcher.normalized(string)
        guard !query.isEmpty else { return await all() }
        return await all()
            .map { ($0, ArtistMatcher.similarity(query, ArtistMatcher.normalized($0.title))) }
            .filter { $0.1 >= 0.6 || ArtistMatcher.normalized($0.0.title).contains(query) }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// What's loaded now, without forcing a mix build: this feeds
    /// updateAppShortcutParameters(), which runs at launch and after scans.
    @MainActor
    func suggestedEntities() async throws -> [MixAppEntity] {
        MixAppEntity.shelves + CosmosSiriActions.allMixes().map { MixAppEntity(mix: $0.mix, shelf: $0.shelf) }
    }
}
