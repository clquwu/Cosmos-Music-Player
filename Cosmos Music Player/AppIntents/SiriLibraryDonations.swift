//
//  SiriLibraryDonations.swift
//  Cosmos Music Player
//
//  Keeps what Siri knows about the library current:
//  - SiriKit vocabulary (playlist + mix titles, artist names) so the speech
//    recognizer hears "Shiro Sagisu" and "Redécouvrir 2019";
//  - the mix index the Siri extension reads (it cannot see MixStore, which
//    lives in the app's own container) for "joue <mix> dans Cosmos";
//  - App Shortcut parameter values (mixes, playlists, artists) via
//    updateAppShortcutParameters().
//
//  Refreshes on launch, after a library scan, when the mixes change and when
//  the app goes to the background (playlist edits). All database reads run
//  off the main thread and refreshes are debounced.
//

import AppIntents
import Combine
import Foundation
import Intents
import UIKit

@MainActor
final class SiriLibraryDonations {
    static let shared = SiriLibraryDonations()

    private var cancellables: Set<AnyCancellable> = []
    private var pending: Task<Void, Never>?

    private init() {}

    nonisolated static var mixIndexURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.dev.clq.Cosmos-Music-Player")?
            .appendingPathComponent("Library/siri-mixes.json")
    }

    /// Idempotent; call at launch (including background Siri launches).
    func activate() {
        guard cancellables.isEmpty else { return }

        MixStore.shared.$madeForYou
            .combineLatest(MixStore.shared.$moments)
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] madeForYou, moments in
                guard !madeForYou.isEmpty || !moments.isEmpty else { return }
                self?.writeMixIndex(madeForYou: madeForYou, moments: moments)
                self?.scheduleRefresh(after: 0.5)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.scheduleRefresh(after: 0.2) }
            .store(in: &cancellables)

        scheduleRefresh(after: 1)
    }

    /// Debounced vocabulary + App Shortcut parameter refresh.
    func scheduleRefresh(after delay: TimeInterval = 1) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    private struct VocabularySource: Sendable {
        var playlists: [String] = []
        var artists: [String] = []
        var trackCount = 0
    }

    private var indexingObserver: AnyCancellable?

    private func refresh() async {
        // Subscribed here rather than in activate(), so a launch never
        // creates LibraryIndexer earlier than the app itself would.
        if indexingObserver == nil {
            indexingObserver = LibraryIndexer.shared.$isIndexing
                .removeDuplicates()
                .dropFirst()
                .filter { !$0 }
                .sink { [weak self] _ in self?.scheduleRefresh(after: 3) }
        }
        let mixTitles = (MixStore.shared.madeForYou + MixStore.shared.moments).map(\.title)
        let source: VocabularySource = await Task.detached(priority: .utility) {
            var source = VocabularySource()
            let database = DatabaseManager.shared
            source.playlists = ((try? database.getAllPlaylists()) ?? []).map(\.title)
            // Artist names ranked by song count: the vocabulary is ordered
            // by importance and Siri keeps only the top of it.
            // Counted in SQL: this runs every time the app goes to the
            // background, and loading every song for it was a full decode
            // of the library each time.
            let counts = (try? database.artistSongCounts()) ?? (byArtist: [:], total: 0)
            source.trackCount = counts.total
            let songCount = counts.byArtist
            let names = (try? database.getAllArtistNamesById()) ?? [:]
            source.artists = songCount.sorted { $0.value > $1.value }.compactMap { names[$0.key] }
            return source
        }.value

        var playlistTerms = source.playlists + mixTitles
        playlistTerms += [
            "Liked Songs", "Favorites", "Favourites", "Made for You", "Rediscover",
            "Titres likés", "Favoris", "Coups de cœur", "Pour vous", "Redécouvrir",
            "ma playlist", "ma liste de lecture", "mes playlists", "liste de lecture"
        ]
        let vocabulary = INVocabulary.shared()
        vocabulary.setVocabularyStrings(NSOrderedSet(array: playlistTerms), of: .mediaPlaylistTitle)
        vocabulary.setVocabularyStrings(NSOrderedSet(array: Array(source.artists.prefix(500))), of: .mediaMusicArtistName)

        let context = INMediaUserContext()
        context.numberOfLibraryItems = source.trackCount
        context.subscriptionStatus = .notSubscribed
        context.becomeCurrent()

        if #available(iOS 26.0, *) {
            CosmosAppShortcuts.updateAppShortcutParameters()
        }
        SiriDiag.log("APP Siri donations refreshed playlists=\(source.playlists.count) mixes=\(mixTitles.count) artists=\(source.artists.count)")
    }

    private struct MixRecord: Codable {
        let id: String
        let title: String
        let kind: String
    }

    private func writeMixIndex(madeForYou: [Mix], moments: [Mix]) {
        let records = madeForYou.map { MixRecord(id: $0.id, title: $0.title, kind: "madeForYou") }
            + moments.map { MixRecord(id: $0.id, title: $0.title, kind: "rediscover") }
        guard let url = Self.mixIndexURL, let data = try? JSONEncoder().encode(records) else { return }
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}
