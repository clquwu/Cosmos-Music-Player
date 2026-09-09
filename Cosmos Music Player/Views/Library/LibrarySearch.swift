//
//  LibrarySearch.swift
//  Cosmos Music Player
//
//  Shared in-place search for the library's list screens.
//
//  Every list that can grow long - All Songs, Liked Songs, a playlist, an
//  artist's songs, and the artist/album/playlist browsers - filters through
//  the helpers here, so a query behaves the same everywhere: accent- and
//  case-insensitive, and narrowed by each term rather than widened.
//
//  Each screen carries a `LibrarySearchButton` in its navigation bar, grouped
//  with whatever other controls it has there; tapping it opens the field, and
//  the field's own Cancel clears the query and closes it.
//

import SwiftUI
import UIKit

enum LibrarySearch {
    static func normalized(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    /// Splits a query into the terms that must *all* match, so typing
    /// "beatles yesterday" narrows to that song instead of returning
    /// everything matching either word. Empty when the query is blank.
    static func terms(in query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return normalized(trimmed).split(separator: " ").map(String.init)
    }

    /// Matches the name-only lists (artists, albums, playlists), where the
    /// searchable text is cheap enough to build per row.
    static func matches(terms: [String], in fields: String?...) -> Bool {
        guard !terms.isEmpty else { return true }
        let haystack = normalized(fields.compactMap { $0 }.joined(separator: " "))
        return terms.allSatisfy { haystack.contains($0) }
    }
}

extension LibrarySearch {
    /// The queue a tap should start, honouring the "queue the whole list"
    /// preference.
    ///
    /// A search narrows what is *shown*; whether it should also narrow what
    /// plays next is a matter of taste, which is why this is a setting. Off, the
    /// queue is what the list is showing. On, the matches are a way of finding a
    /// song inside its album or playlist without losing everything around it.
    static func queueSource(filtered: [Track], full: [Track], isSearching: Bool) -> [Track] {
        guard isSearching, DeleteSettings.load().queueFullListFromSearch else {
            return filtered
        }
        return full
    }

    /// Maps a position in the filtered list onto the same occurrence in the
    /// unfiltered one.
    ///
    /// Index rather than stable ID, because a playlist may hold the same track
    /// more than once and the tapped copy is the one that has to play. Counting
    /// how many copies precede it in the filtered list finds the same copy in
    /// the full one.
    static func fullListIndex(ofFiltered index: Int, in filtered: [Track], within full: [Track]) -> Int {
        guard filtered.indices.contains(index) else { return 0 }

        let stableId = filtered[index].stableId
        let occurrence = filtered[..<index].reduce(into: 0) { count, track in
            if track.stableId == stableId { count += 1 }
        }

        var seen = 0
        for (position, track) in full.enumerated() where track.stableId == stableId {
            if seen == occurrence { return position }
            seen += 1
        }
        return 0
    }
}

/// Drops the keyboard while leaving the search bar and its query in place.
///
/// Playing a song or opening the player should not throw away what the user
/// typed - only the field's own Cancel closes the search.
@MainActor
func dismissSearchKeyboard() {
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder),
        to: nil,
        from: nil,
        for: nil
    )
}

/// Search state for one list screen: the query, and whether the field is open.
@MainActor
final class LibrarySearchState: ObservableObject {
    @Published var text = ""
    /// Drives `.searchable`'s presentation, so the toolbar button can open the
    /// field and Cancel can close it.
    @Published var isPresented = false

    /// The query is actually narrowing the list. Lists use this to choose
    /// between their two empty states.
    var isSearching: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension View {
    /// The system search field these screens share, opened by
    /// `LibrarySearchButton`.
    ///
    /// Driving `.searchable` from `isPresented` rather than pinning the bar
    /// also removed the UIKit workaround that used to live here: with an inline
    /// navigation title there is no large-title area for a permanent bar to sit
    /// in, so it had to be un-parked by toggling `hidesSearchBarWhenScrolling`
    /// by hand on the right ancestor's navigation item. Nothing to un-park now -
    /// the bar appears because it was asked for, and Cancel clears the query
    /// and puts it away.
    func librarySearchField(_ state: LibrarySearchState, prompt: String) -> some View {
        searchable(
            text: Binding(get: { state.text }, set: { state.text = $0 }),
            isPresented: Binding(get: { state.isPresented }, set: { state.isPresented = $0 }),
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: prompt
        )
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
    }
}

/// The magnifying glass that opens a screen's search field.
///
/// Deliberately a view rather than something `librarySearchField` adds on its
/// own: the navigation bar spreads separate `ToolbarItem`s apart and tints them
/// independently, so a button added that way sat away from each screen's sort,
/// shuffle and overflow controls and did not match them. Placed *inside* a
/// screen's existing trailing item - the same `HStack(spacing: 0)` those
/// controls already share - it reads as one group with them.
///
/// The styling below is the one these bars already use: `.title3`, the chosen
/// accent, and 4pt of padding for the hit area.
struct LibrarySearchButton: View {
    @ObservedObject var state: LibrarySearchState
    @State private var settings = DeleteSettings.load()

    var body: some View {
        Button {
            state.isPresented = true
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundColor(settings.backgroundColorChoice.color)
                .padding(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Localized.search)
        .onReceive(NotificationCenter.default.publisher(for: .cosmosSettingsDidChange)) { _ in
            settings = DeleteSettings.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("BackgroundColorChanged"))) { _ in
            settings = DeleteSettings.load()
        }
    }
}

/// Searchable text for a list of tracks, resolved once for the whole list.
///
/// The fields people actually search by - artist and album - are not stored on
/// `Track`; they need a join. Resolving them inside the filter would re-query
/// the database for every character typed, so the index resolves them once per
/// track set and keeps a flat normalized haystack per track instead.
struct TrackSearchSignature: Equatable {
    let count: Int
    let exclusiveHash: Int
    let additiveHash: Int
}

/// A cheap, constant-time key for `onChange(of:)`.
///
/// SwiftUI evaluates an `onChange` key on **every** body pass, so it must not
/// walk the list. `TrackSearchSignature` hashes seven fields of every track:
/// that is the right test for whether a rebuild is actually needed, but running
/// it per render meant re-hashing the whole library on every keystroke, sort
/// change and selection toggle.
///
/// Detecting that the array was swapped is all this has to do, because the two
/// ways the rows can change without it noticing are both already covered: a
/// metadata change that keeps the same rows arrives with `LibraryNeedsRefresh`,
/// whose handler forces a rebuild, and a track missing from the index still
/// matches on its title (see `TrackSearchIndex.filter`). The worst case of a
/// missed rebuild is that one row is searchable by title alone until the next
/// refresh - never a row that disappears.
struct TrackListIdentity: Equatable {
    let count: Int
    let firstId: String?
    let lastId: String?
}

struct TrackSearchIndex: Sendable {
    private var haystacks: [String: String] = [:]
    private var signature: TrackSearchSignature?

    /// Metadata-aware but order-independent identity. A reparse or an
    /// interior replacement invalidates the haystacks; sorting the same rows
    /// does not. Two commutative accumulators make duplicate hashes much less
    /// likely to mask a change.
    static func signature(for tracks: [Track]) -> TrackSearchSignature {
        var exclusiveHash = 0
        var additiveHash = 0

        for track in tracks {
            var hasher = Hasher()
            hasher.combine(track.stableId)
            hasher.combine(track.title)
            hasher.combine(track.artistId)
            hasher.combine(track.albumId)
            hasher.combine(track.durationMs)
            hasher.combine(track.fileSize)
            hasher.combine(track.modificationDate)
            let trackHash = hasher.finalize()
            exclusiveHash ^= trackHash
            additiveHash &+= trackHash
        }

        return TrackSearchSignature(
            count: tracks.count,
            exclusiveHash: exclusiveHash,
            additiveHash: additiveHash
        )
    }

    /// The constant-time key list views hand to `onChange`. See
    /// `TrackListIdentity` for why this is not the full signature.
    static func identity(for tracks: [Track]) -> TrackListIdentity {
        TrackListIdentity(
            count: tracks.count,
            firstId: tracks.first?.stableId,
            lastId: tracks.last?.stableId
        )
    }

    /// An index describing `tracks`, built entirely off the main thread.
    ///
    /// Everything this does is expensive at library scale - an artist-name
    /// query, a query for every album, a signature hash over every row, and a
    /// normalized string per track - and it used to run synchronously inside
    /// SwiftUI lifecycle callbacks on the main actor, for the whole library on
    /// All Songs, repeated each time a running scan republished the track list.
    ///
    /// - Parameters:
    ///   - current: the index to update. Returned unchanged when it already
    ///     describes `tracks`, so callers can invoke this freely.
    ///   - force: rebuild even when the signature matches, for when joined
    ///     artist or album rows changed without any mutation to the `Track`
    ///     values themselves.
    static func rebuilt(
        from current: TrackSearchIndex,
        for tracks: [Track],
        force: Bool = false
    ) async -> TrackSearchIndex {
        await Task.detached(priority: .userInitiated) {
            let newSignature = signature(for: tracks)
            guard force || newSignature != current.signature else { return current }

            var updated = current
            updated.signature = newSignature
            updated.haystacks = buildHaystacks(for: tracks)
            return updated
        }.value
    }

    func filter(_ tracks: [Track], query: String) -> [Track] {
        let terms = LibrarySearch.terms(in: query)
        guard !terms.isEmpty else { return tracks }

        return tracks.filter { track in
            // A track missing from the index (added since the last rebuild) is
            // still matched on its title rather than silently disappearing.
            let haystack = haystacks[track.stableId] ?? LibrarySearch.normalized(track.title)
            return terms.allSatisfy { haystack.contains($0) }
        }
    }

    private static func buildHaystacks(for tracks: [Track]) -> [String: String] {
        guard !tracks.isEmpty else { return [:] }

        let database = DatabaseManager.shared

        let fallbackArtistIds = tracks.reduce(into: [String: Int64]()) { result, track in
            if let artistId = track.artistId {
                result[track.stableId] = artistId
            }
        }
        let artistNames = (try? database.getArtistDisplayNames(
            forTrackStableIds: tracks.map(\.stableId),
            fallbackArtistIdsByStableId: fallbackArtistIds
        )) ?? [:]

        var albumTitles: [Int64: String] = [:]
        if let albums = try? database.getAllAlbums() {
            for album in albums {
                if let id = album.id {
                    albumTitles[id] = album.title
                }
            }
        }

        var result: [String: String] = [:]
        result.reserveCapacity(tracks.count)
        for track in tracks {
            var fields = [track.title]
            if let artist = artistNames[track.stableId] {
                fields.append(artist)
            }
            if let albumId = track.albumId, let albumTitle = albumTitles[albumId] {
                fields.append(albumTitle)
            }
            result[track.stableId] = LibrarySearch.normalized(fields.joined(separator: " "))
        }
        return result
    }
}
