//
//  PlaylistImportViews.swift
//  Cosmos Music Player
//
//  The M3U import's picker, progress and summary, and the export menu.
//

import SwiftUI
import UniformTypeIdentifiers

/// Runs playlist imports from wherever they start - the Library and
/// Playlists "+" menus, or a playlist opened in Cosmos from Files - so the
/// picker and the summary are presented once, from the root
/// (`playlistImportHost()`), whichever screen asked.
@MainActor
final class PlaylistImportCenter: ObservableObject {
    static let shared = PlaylistImportCenter()

    @Published var isPickerPresented = false
    @Published private(set) var isImporting = false
    @Published var result: PlaylistImportResult?
    @Published var errorMessage: String?

    private init() {}

    func presentPicker() {
        isPickerPresented = true
    }

    func importFile(at url: URL) {
        guard !isImporting else { return }
        isImporting = true

        // The summary is presented from the root, which cannot present while
        // the full-screen player is up - as it may be when a playlist is
        // opened in Cosmos from Files.
        let closedPlayer = AppRouter.shared.isPlayerPresented
        if closedPlayer {
            AppRouter.shared.isPlayerPresented = false
        }

        Task {
            defer { isImporting = false }
            do {
                let imported = try await PlaylistImporter.importPlaylist(from: url)
                if closedPlayer {
                    // Presenting while the player is still sliding away is
                    // refused without a word.
                    try? await Task.sleep(for: .milliseconds(600))
                }
                result = imported
            } catch {
                print("❌ Playlist import failed: \(error)")
                errorMessage = (error as? LocalizedError)?.errorDescription ?? Localized.playlistImportUnreadable
            }
        }
    }
}

private struct PlaylistImportHost: ViewModifier {
    @ObservedObject private var center = PlaylistImportCenter.shared

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $center.isPickerPresented,
                allowedContentTypes: PlaylistImporter.contentTypes
            ) { result in
                guard case .success(let url) = result else { return }
                center.importFile(at: url)
            }
            .sheet(item: $center.result) { result in
                PlaylistImportResultSheet(result: result)
            }
            .alert(
                Localized.playlistImportFailed,
                isPresented: Binding(
                    get: { center.errorMessage != nil },
                    set: { if !$0 { center.errorMessage = nil } }
                )
            ) {
                Button(Localized.ok, role: .cancel) { }
            } message: {
                Text(center.errorMessage ?? "")
            }
            .overlay(alignment: .top) {
                if center.isImporting {
                    HStack(spacing: Design.Spacing.s) {
                        ProgressView()
                            .controlSize(.small)
                        Text(Localized.playlistImporting)
                            .font(.footnote.weight(.medium))
                    }
                    .padding(.horizontal, Design.Spacing.l)
                    .padding(.vertical, Design.Spacing.s)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, Design.Spacing.s)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.25), value: center.isImporting)
    }
}

extension View {
    /// Attach once, at the root: the M3U picker, progress and summary.
    func playlistImportHost() -> some View {
        modifier(PlaylistImportHost())
    }
}

/// "Import Playlist (M3U)", for the "+" menus.
struct PlaylistImportMenuButton: View {
    var body: some View {
        Button {
            PlaylistImportCenter.shared.presentPicker()
        } label: {
            Label(Localized.importPlaylistM3U, systemImage: "square.and.arrow.down")
        }
    }
}

/// The playlist page's "…" menu: Edit, and Export Playlist (.m3u8).
struct PlaylistMoreMenu: View {
    let playlist: Playlist
    var hasSongs = true
    var onEdit: (() -> Void)?

    var body: some View {
        Menu {
            if let onEdit {
                Button(action: onEdit) {
                    Label(Localized.edit, systemImage: "pencil")
                }
                .disabled(!hasSongs)
            }
            if hasSongs, let playlistId = playlist.id {
                ShareLink(
                    item: PlaylistM3UExport(playlistId: playlistId, title: playlist.title),
                    preview: SharePreview(playlist.title, image: Image(systemName: "music.note.list"))
                ) {
                    Label(Localized.exportPlaylistM3U8, systemImage: "square.and.arrow.up")
                }
            }
        } label: {
            Label(Localized.moreOptions, systemImage: "ellipsis.circle")
        }
    }
}

/// "Imported 48 of 52 songs", and which ones were not found - so the
/// listener knows exactly what to add, rather than discovering gaps later.
struct PlaylistImportResultSheet: View {
    let result: PlaylistImportResult
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: Design.Spacing.xs) {
                        Text(Localized.playlistImportSummary(imported: result.matchedEntries, total: result.totalEntries))
                            .font(.title3.weight(.semibold))
                        if result.playlistId != nil {
                            Text(String(format: Localized.playlistImportSavedAs, result.playlistTitle))
                                .foregroundStyle(.secondary)
                        } else {
                            Text(Localized.playlistImportNoneMatched)
                                .foregroundStyle(.secondary)
                        }
                        if result.repeatedSongs > 0 {
                            Text(Localized.playlistImportRepeats(result.repeatedSongs))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, Design.Spacing.xs)

                    if let playlistId = result.playlistId {
                        Button {
                            dismiss()
                            AppRouter.shared.open(.playlist(id: playlistId))
                        } label: {
                            Label(Localized.playlistImportOpen, systemImage: "music.note.list")
                        }
                    }
                }

                if !result.unmatched.isEmpty {
                    Section(Localized.playlistImportNotFound) {
                        // By position: a playlist can list the same missing song twice.
                        ForEach(Array(result.unmatched.enumerated()), id: \.offset) { _, name in
                            Text(name)
                                .font(.subheadline)
                                .lineLimit(2)
                        }
                    }
                }
            }
            .navigationTitle(Localized.playlistImportTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Localized.done) { dismiss() }
                }
            }
        }
        .presentationDetents(result.unmatched.isEmpty ? [.medium] : [.medium, .large])
    }
}
