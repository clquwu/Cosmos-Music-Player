//
//  TrackBulkSelection.swift
//  Cosmos Music Player
//
//  Shared multi-select behaviour for track lists.
//
//  All Songs and Liked Songs grew this inline inside TrackListView. Album and
//  artist detail pages embed their song lists as sections of a larger
//  ScrollView (with disc grouping, track numbers and artwork rows), so they
//  cannot simply reuse TrackListView - but they should still offer the same
//  actions. The toolbar, action sheets and bulk operations live here so all
//  three lists stay in step.
//

import SwiftUI

/// Supplies the selection toolbar, the "add to playlist" sheet and the delete
/// confirmation for a list that supports multi-select.
struct TrackBulkActionsModifier: ViewModifier {
    /// Candidates for "Select All" - the tracks currently shown by the list.
    let tracks: [Track]
    /// Every track the list can select, ignoring any active search. Selections
    /// survive a change of query, so the actions resolve ids against this;
    /// resolving them against `tracks` silently dropped every selected song the
    /// current query happened to hide.
    let selectionPool: [Track]
    @Binding var isBulkMode: Bool
    @Binding var selectedTracks: Set<String>
    /// Liked Songs phrases the favourite action as "remove" rather than "add".
    let isLikedContext: Bool

    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var showPlaylistDialog = false
    @State private var showDeleteConfirmation = false
    @State private var settings = DeleteSettings.load()

    func body(content: Content) -> some View {
        content
            .toolbar {
                if isBulkMode {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(Localized.cancel) { exitBulkMode() }
                            .foregroundColor(settings.backgroundColorChoice.color)
                    }

                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            Button(action: { selectAll() }) {
                                Label(Localized.selectAll, systemImage: "checkmark.circle")
                            }
                            Divider()
                            Button(action: { bulkToggleLiked() }) {
                                Label(
                                    isLikedContext ? Localized.removeFromLiked : Localized.addToLiked,
                                    systemImage: "heart.fill"
                                )
                            }
                            .disabled(selectedTracks.isEmpty)

                            Button(action: { showPlaylistDialog = true }) {
                                Label(Localized.addToPlaylist, systemImage: "music.note.list")
                            }
                            .disabled(selectedTracks.isEmpty)
                            Divider()
                            Button(role: .destructive, action: { showDeleteConfirmation = true }) {
                                Label(Localized.deleteFiles, systemImage: "trash")
                            }
                            .disabled(selectedTracks.isEmpty)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.title3)
                                .foregroundColor(settings.backgroundColorChoice.color)
                                .padding(4)
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                    }
                }
            }
            .sheet(isPresented: $showPlaylistDialog) {
                BulkPlaylistSelectionView(
                    trackIds: Array(selectedTracks),
                    onComplete: { exitBulkMode() }
                )
                .accentColor(settings.backgroundColorChoice.color)
            }
            .alert(Localized.deleteFilesConfirmation, isPresented: $showDeleteConfirmation) {
                Button(Localized.delete, role: .destructive) { bulkDelete() }
                Button(Localized.cancel, role: .cancel) { }
            } message: {
                Text(Localized.deleteFilesConfirmationMessage(selectedTracks.count))
            }
            .onReceive(NotificationCenter.default.publisher(for: .cosmosSettingsDidChange)) { _ in
                settings = DeleteSettings.load()
            }
    }

    private func exitBulkMode() {
        isBulkMode = false
        selectedTracks.removeAll()
    }

    private func selectAll() {
        selectedTracks = Set(tracks.map { $0.stableId })
    }

    private func bulkToggleLiked() {
        for trackId in selectedTracks {
            if let track = selectionPool.first(where: { $0.stableId == trackId }) {
                try? appCoordinator.toggleFavorite(trackStableId: track.stableId)
            }
        }
        exitBulkMode()
    }

    private func bulkDelete() {
        Task {
            let deleteSettings = DeleteSettings.load()
            for trackId in selectedTracks {
                if let track = selectionPool.first(where: { $0.stableId == trackId }) {
                    if deleteSettings.deleteFromLibraryOnly {
                        DeleteSettings.addExcludedTrack(track.stableId, path: track.path, modificationDate: track.modificationDate)
                    } else {
                        try? FileManager.default.removeItem(at: URL(fileURLWithPath: track.path))
                    }
                    try? await DatabaseManager.shared.deleteTrack(byStableId: track.stableId)
                }
            }
            NotificationCenter.default.post(
                name: NSNotification.Name("LibraryNeedsRefresh"),
                object: nil
            )
            exitBulkMode()
        }
    }
}

extension View {
    /// Adds the shared selection toolbar and bulk actions to a track list.
    func trackBulkActions(
        tracks: [Track],
        selectionPool: [Track]? = nil,
        isBulkMode: Binding<Bool>,
        selectedTracks: Binding<Set<String>>,
        isLikedContext: Bool = false
    ) -> some View {
        modifier(
            TrackBulkActionsModifier(
                tracks: tracks,
                selectionPool: selectionPool ?? tracks,
                isBulkMode: isBulkMode,
                selectedTracks: selectedTracks,
                isLikedContext: isLikedContext
            )
        )
    }
}

/// The leading checkmark shown on a track row while selecting. Kept here so the
/// album and artist rows present selection identically to the library list,
/// including a full-size tap target on the checkmark itself.
struct TrackSelectionIndicator: View {
    let isSelected: Bool
    let accentColor: Color
    var onTap: (() -> Void)? = nil

    var body: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title2)
            .foregroundColor(isSelected ? accentColor : .secondary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .onTapGesture { onTap?() }
    }
}
