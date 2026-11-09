//
//  FolderViews.swift
//  Cosmos Music Player
//
//  Linking music folders from Files, the Music Folders settings page, and
//  the Folders browser that shows the library the way it sits on disk.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Linking

/// Links, reconnects and removes music folders on behalf of the UI.
@MainActor
enum LinkedFolderImporter {
    enum Outcome: Identifiable, Equatable {
        case added(String)
        case reconnected
        case alreadyInLibrary
        case alreadyLinked
        case unsupported
        case failed

        var id: String {
            switch self {
            case .added(let name): return "added-\(name)"
            case .reconnected: return "reconnected"
            case .alreadyInLibrary: return "alreadyInLibrary"
            case .alreadyLinked: return "alreadyLinked"
            case .unsupported: return "unsupported"
            case .failed: return "failed"
            }
        }

        var title: String {
            switch self {
            case .unsupported: return Localized.folderUnsupportedTitle
            case .added, .reconnected: return Localized.musicFolders
            case .alreadyInLibrary, .alreadyLinked, .failed: return Localized.addFolder
            }
        }

        var message: String {
            switch self {
            case .added(let name): return String(format: Localized.folderAddedFormat, name)
            case .reconnected: return Localized.folderReconnected
            case .alreadyInLibrary: return Localized.folderAlreadyInLibrary
            case .alreadyLinked: return Localized.folderAlreadyLinked
            case .unsupported: return Localized.folderUnsupportedMessage
            case .failed: return Localized.folderAddFailed
            }
        }
    }

    /// Links the folder the user picked, unless it is somewhere that cannot
    /// be scanned reliably or is already part of the library.
    static func link(_ url: URL) async -> Outcome {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        switch await verdict(for: url) {
        case .alreadyInLibrary:
            return .alreadyInLibrary
        case .unsupportedLocation:
            print("🔗 Refused to link a folder from an unsupported location: \(url.path)")
            return .unsupported
        case .allowed:
            break
        }

        do {
            let folder = try LinkedFolderStore.shared.add(url)
            print("🔗 Linked music folder: \(folder.name)")
            scanSoon()
            return .added(folder.name)
        } catch LinkedFolderStore.AddError.alreadyLinked {
            return .alreadyLinked
        } catch {
            print("⚠️ Could not link folder \(url.lastPathComponent): \(error)")
            return .failed
        }
    }

    /// Points a folder that needs reconnecting at the folder picked again.
    static func reconnect(_ folder: LinkedFolder, to url: URL) async -> Outcome {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard await verdict(for: url) == .allowed else { return .unsupported }
        do {
            try LinkedFolderStore.shared.reconnect(folder.id, to: url)
            scanSoon()
            return .reconnected
        } catch {
            print("⚠️ Could not reconnect folder \(folder.name): \(error)")
            return .failed
        }
    }

    /// Unlinks a folder and takes its songs out of the library. The files
    /// stay where they are.
    static func remove(_ folder: LinkedFolder) async {
        LinkedFolderStore.shared.remove(folder.id)
        let paths = [folder.path] + folder.formerPaths
        let (removedCount, playlistSlugs) = await Task.detached(priority: .userInitiated) {
            var count = 0
            var slugs: [String] = []
            for path in paths {
                count += (try? DatabaseManager.shared.deleteTracks(underPath: path))?.count ?? 0
                // Its folder playlists go with it.
                slugs += (try? DatabaseManager.shared.deleteFolderPlaylists(underPath: path)) ?? []
            }
            // And their copies saved for iCloud, which would otherwise
            // restore them on another device or a reinstall.
            for slug in slugs {
                try? StateManager.shared.deletePlaylist(slug: slug)
            }
            return (count, slugs)
        }.value
        print("🔗 Removed music folder \(folder.name), its \(removedCount) song(s) and \(playlistSlugs.count) folder playlist(s)")

        NotificationCenter.default.post(name: NSNotification.Name("LibraryNeedsRefresh"), object: nil)
        #if canImport(MediaIntents)
        if #available(iOS 27.0, *) {
            SpotlightLibraryIndexer.shared.scheduleReindex()
        }
        #endif
    }

    /// The classification needs the app's iCloud folder, whose first lookup
    /// must not run on the main thread, and resource values a provider may be
    /// slow to answer.
    private static func verdict(for url: URL) async -> LinkedFolderPolicy.Verdict {
        await Task.detached(priority: .userInitiated) {
            var appRoots = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            if let iCloudFolder = StateManager.shared.getMusicFolderURL() {
                appRoots.append(iCloudFolder)
            }
            return LinkedFolderPolicy.classify(url, appRoots: appRoots)
        }.value
    }

    /// Scans as soon as any scan already running has finished, so a new
    /// folder's songs show up without a manual refresh.
    private static func scanSoon() {
        Task { @MainActor in
            while LibraryIndexer.shared.isIndexing {
                try? await Task.sleep(for: .milliseconds(300))
            }
            await AppCoordinator.shared.manualSync()
        }
    }
}

/// The Files picker in folder mode.
struct MusicFolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.modalPresentationStyle = .formSheet
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: UIDocumentPickerViewController, coordinator: Coordinator) {
        // Same DocumentManager workaround as MusicFilePicker.
        uiViewController.delegate = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            controller.delegate = nil
            if let url = urls.first {
                onPick(url)
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            controller.delegate = nil
        }
    }
}

extension View {
    /// The alert for a linking outcome that needs one - a refusal, a no-op.
    /// A successful add is quiet here; the caller shows it its own way.
    func linkedFolderAlert(_ outcome: Binding<LinkedFolderImporter.Outcome?>) -> some View {
        alert(
            outcome.wrappedValue?.title ?? "",
            isPresented: Binding(
                get: { outcome.wrappedValue != nil },
                set: { if !$0 { outcome.wrappedValue = nil } }
            ),
            presenting: outcome.wrappedValue
        ) { _ in
            Button(Localized.ok, role: .cancel) {}
        } message: { outcome in
            Text(outcome.message)
        }
    }
}

// MARK: - Settings › Music Folders

struct MusicFoldersView: View {
    private enum PickerMode: Identifiable {
        case add
        case reconnect(LinkedFolder)

        var id: String {
            switch self {
            case .add: return "add"
            case .reconnect(let folder): return folder.id.uuidString
            }
        }
    }

    @State private var folders: [LinkedFolder] = []
    @State private var needsReconnect: Set<UUID> = []
    @State private var songCounts: [UUID: Int] = [:]
    @State private var pickerMode: PickerMode?
    @State private var pendingRemoval: LinkedFolder?
    @State private var outcome: LinkedFolderImporter.Outcome?
    @ObservedObject private var theme = ThemeStore.shared

    var body: some View {
        Form {
            Section {
                if folders.isEmpty {
                    Text(Localized.noMusicFolders)
                        .foregroundStyle(.secondary)
                }
                ForEach(folders) { folder in
                    row(folder)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                pendingRemoval = folder
                            } label: {
                                Label(Localized.removeFolder, systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button {
                                pickerMode = .reconnect(folder)
                            } label: {
                                Label(Localized.reconnect, systemImage: "arrow.triangle.2.circlepath")
                            }
                            Button(role: .destructive) {
                                pendingRemoval = folder
                            } label: {
                                Label(Localized.removeFolder, systemImage: "trash")
                            }
                        }
                }

                Button {
                    pickerMode = .add
                } label: {
                    Label(Localized.addFolder, systemImage: "folder.badge.plus")
                }
            } footer: {
                Text(Localized.musicFoldersFooter)
            }
        }
        .navigationTitle(Localized.musicFolders)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $pickerMode) { mode in
            MusicFolderPicker { url in
                Task {
                    switch mode {
                    case .add:
                        let result = await LinkedFolderImporter.link(url)
                        if case .added = result { reload() } else { outcome = result }
                    case .reconnect(let folder):
                        let result = await LinkedFolderImporter.reconnect(folder, to: url)
                        outcome = result
                        reload()
                    }
                }
            }
        }
        .confirmationDialog(
            Localized.removeFolderTitle,
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { folder in
            Button(Localized.removeFolder, role: .destructive) {
                Task {
                    await LinkedFolderImporter.remove(folder)
                    reload()
                }
            }
            Button(Localized.cancel, role: .cancel) {}
        } message: { _ in
            Text(Localized.removeFolderMessage)
        }
        .linkedFolderAlert($outcome)
        .task {
            reload()
            // Checks each folder is still there, so one that was unplugged
            // or whose bookmark broke offers Reconnect straight away.
            await Task.detached(priority: .userInitiated) {
                _ = LinkedFolderStore.shared.activateAll()
            }.value
            reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: LinkedFolderStore.didChangeNotification)) { _ in
            reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LibraryNeedsRefresh"))) { _ in
            reload()
        }
    }

    private func row(_ folder: LinkedFolder) -> some View {
        let isUnreachable = needsReconnect.contains(folder.id)
        return HStack(spacing: Design.Spacing.m) {
            Image(systemName: isUnreachable ? "exclamationmark.triangle.fill" : "folder.fill")
                .font(.title3)
                .foregroundStyle(isUnreachable ? Color.orange : theme.accent)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .lineLimit(1)
                Text(isUnreachable ? Localized.folderNeedsReconnect : Localized.songsCountOnly(songCounts[folder.id] ?? 0))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: Design.Spacing.s)

            if isUnreachable {
                Button(Localized.reconnect) {
                    pickerMode = .reconnect(folder)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func reload() {
        let store = LinkedFolderStore.shared
        folders = store.folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        needsReconnect = Set(folders.filter { store.needsReconnect($0.id) }.map(\.id))
        var counts: [UUID: Int] = [:]
        for folder in folders {
            counts[folder.id] = ([folder.path] + folder.formerPaths).reduce(0) {
                $0 + ((try? DatabaseManager.shared.countTracks(underPath: $1)) ?? 0)
            }
        }
        songCounts = counts
    }
}

// MARK: - Folders browser

/// The library as folders on disk: the app's own folder on the device, its
/// iCloud folder and every linked folder, each browsable down to its songs.
///
/// Built from the songs' stored paths rather than by walking the disk, so it
/// shows exactly the folders that hold music, opens instantly however large
/// the library is, and works for an offline iCloud folder.
enum FolderBrowser {
    struct Source: Identifiable, Hashable {
        let path: String
        let name: String
        let systemImage: String
        var id: String { path }
    }

    struct Subfolder: Identifiable {
        let path: String
        let name: String
        let songCount: Int
        /// The song the folder's cover is read from.
        let artworkTrack: Track?
        var id: String { path }
    }

    struct Contents {
        var subfolders: [Subfolder] = []
        /// In file-name order, the order a file browser shows them in.
        var songs: [Track] = []
        /// Every song at any depth, in browsing order: this folder's own
        /// songs, then each subfolder's in turn - so CD1 plays before CD2.
        var allSongs: [Track] = []
    }

    @MainActor
    static func sources(iCloudFolder: URL?) -> [Source] {
        var sources = [Source(
            path: DatabaseManager.canonicalPath(LibraryIndexer.localDocumentsURL.path),
            name: Localized.onThisDevice,
            systemImage: UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        )]
        if let iCloudFolder {
            sources.append(Source(
                path: DatabaseManager.canonicalPath(iCloudFolder.path),
                name: Localized.iCloudDrive,
                systemImage: "icloud"
            ))
        }
        for folder in LinkedFolderStore.shared.folders.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            sources.append(Source(path: folder.path, name: folder.name, systemImage: "folder"))
        }
        return sources
    }

    static func displayName(ofPath path: String, sources: [Source]) -> String {
        sources.first { $0.path == path }?.name ?? (path as NSString).lastPathComponent
    }

    /// Where a song sits now. After a restore or reinstall iOS moves the
    /// app's container, and rows keep the old container's path until the
    /// cleanup pass rewrites them; playback already follows them into the new
    /// one (`DatabaseManager.localFileURL`), and so must the browser, or the
    /// device's own folder would look empty meanwhile.
    static func browsingPath(of path: String, documentsPath: String) -> String {
        guard !path.hasPrefix(documentsPath + "/"),
              path.contains("/Containers/Data/Application/"),
              let relative = DatabaseManager.applicationContainerDocumentsRelativePath(forPath: path) else {
            return path
        }
        return documentsPath + "/" + relative
    }

    static func contents(of folderPath: String, in tracks: [Track]) -> Contents {
        let prefix = folderPath + "/"
        let documentsPath = DatabaseManager.canonicalPath(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        )
        var direct: [(name: String, track: Track)] = []
        var nested: [String: [(relative: String, track: Track)]] = [:]

        for track in tracks {
            let path = browsingPath(of: track.path, documentsPath: documentsPath)
            guard path.hasPrefix(prefix) else { continue }
            let relative = path.dropFirst(prefix.count)
            if let slash = relative.firstIndex(of: "/") {
                nested[String(relative[..<slash]), default: []].append((String(relative), track))
            } else {
                direct.append((String(relative), track))
            }
        }

        var contents = Contents()
        contents.songs = direct
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map(\.track)
        contents.allSongs = contents.songs

        for name in nested.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            let members = nested[name] ?? []
            let ordered = members
                .sorted { browsingOrder($0.relative, $1.relative) }
                .map(\.track)
            contents.subfolders.append(Subfolder(
                path: prefix + name,
                name: name,
                songCount: members.count,
                artworkTrack: ordered.first(where: \.hasArtwork) ?? ordered.first
            ))
            contents.allSongs.append(contentsOf: ordered)
        }
        return contents
    }

    /// Depth-first, file-name order: a folder's own files before its
    /// subfolders, as `contents` lists them.
    private static func browsingOrder(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.split(separator: "/").map(String.init)
        let right = rhs.split(separator: "/").map(String.init)
        for index in 0..<min(left.count, right.count) {
            let leftIsFile = index == left.count - 1
            let rightIsFile = index == right.count - 1
            if left[index] == right[index] { continue }
            if leftIsFile != rightIsFile { return leftIsFile }
            return left[index].localizedStandardCompare(right[index]) == .orderedAscending
        }
        return left.count < right.count
    }

    @MainActor
    static func play(_ tracks: [Track], startingAt index: Int = 0, shuffled: Bool = false) {
        guard !tracks.isEmpty else { return }
        let queue = shuffled ? tracks.shuffled() : tracks
        let start = shuffled ? 0 : min(max(index, 0), queue.count - 1)
        ListeningLog.shared.tagQueue("folder", tracks: queue)
        Task { await AppCoordinator.shared.playTrack(queue[start], queue: queue) }
    }
}

/// A folder's cover for a list row: its first song's artwork.
private struct FolderThumb: View {
    let track: Track?
    @State private var image: UIImage?

    var body: some View {
        ArtworkView(image: image, cornerRadius: 6, placeholderSymbol: "folder.fill")
            .task(id: track?.stableId) {
                guard let track else { return }
                image = await ArtworkManager.shared.getThumbnail(for: track)
            }
            .reloadsArtwork(for: track?.stableId) {
                guard let track else { return }
                Task { image = await ArtworkManager.shared.getThumbnail(for: track) }
            }
    }
}

/// The top of the Folders browser: one row per place songs come from.
struct FoldersScreen: View {
    let tracks: [Track]
    @ObservedObject private var theme = ThemeStore.shared
    @State private var sources: [FolderBrowser.Source] = []
    @State private var counts: [String: Int] = [:]

    var body: some View {
        List {
            ForEach(sources.filter { (counts[$0.path] ?? 0) > 0 }) { source in
                NavigationLink(value: LibraryRoute.folder(path: source.path)) {
                    CollectionRow(title: source.name, subtitle: Localized.songsCountOnly(counts[source.path] ?? 0)) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(theme.accent.opacity(0.15))
                            .overlay {
                                Image(systemName: source.systemImage)
                                    .font(.title2)
                                    .foregroundStyle(theme.accent)
                            }
                    }
                }
                .listRowBackground(Color.clear)
                .contextMenu {
                    playMenu(for: source.path)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay {
            if !sources.isEmpty, !sources.contains(where: { (counts[$0.path] ?? 0) > 0 }) {
                CosmosEmptyState(systemImage: "folder", title: Localized.folderNoSongs)
            }
        }
        .background(ScreenSpecificBackgroundView(screen: .albums))
        .navigationTitle(Localized.folders)
        .navigationBarTitleDisplayMode(.large)
        .task(id: TrackSearchIndex.identity(for: tracks)) {
            await load()
        }
        .onReceive(NotificationCenter.default.publisher(for: LinkedFolderStore.didChangeNotification)) { _ in
            Task { await load() }
        }
    }

    @ViewBuilder
    private func playMenu(for path: String) -> some View {
        Button {
            FolderBrowser.play(FolderBrowser.contents(of: path, in: tracks).allSongs)
        } label: {
            Label(Localized.play, systemImage: "play.fill")
        }
        Button {
            FolderBrowser.play(FolderBrowser.contents(of: path, in: tracks).allSongs, shuffled: true)
        } label: {
            Label(Localized.shuffle, systemImage: "shuffle")
        }
    }

    private func load() async {
        // The app's iCloud folder lookup must stay off the main thread.
        let iCloudFolder = await Task.detached(priority: .userInitiated) {
            StateManager.shared.getMusicFolderURL()
        }.value
        let sources = FolderBrowser.sources(iCloudFolder: iCloudFolder)
        let documentsPath = DatabaseManager.canonicalPath(LibraryIndexer.localDocumentsURL.path)
        let paths = tracks.map { FolderBrowser.browsingPath(of: $0.path, documentsPath: documentsPath) }
        var counts: [String: Int] = [:]
        for source in sources {
            let prefix = source.path + "/"
            counts[source.path] = paths.reduce(0) { $0 + ($1.hasPrefix(prefix) ? 1 : 0) }
        }
        self.sources = sources
        self.counts = counts
    }
}

/// One folder: its subfolders, then its songs. Tapping a song plays the
/// folder from there, in file order; Play and Shuffle take everything under it.
struct FolderDetailScreen: View {
    let path: String
    let allTracks: [Track]

    @State private var contents = FolderBrowser.Contents()
    @State private var title = ""
    @State private var artistNames: [String: String] = [:]
    @State private var artworkImage: UIImage?
    @State private var didLoad = false

    /// See `TrackRowView.contextIdentity`: the tap handler captures the song list.
    private var rowContextIdentity: String {
        "\(path)|\(contents.songs.count)-\(contents.songs.first?.stableId ?? "")"
    }

    private var detailLine: String {
        var parts = [Localized.songsCountOnly(contents.allSongs.count)]
        if let length = DurationFormatter.totalLength(of: contents.allSongs) {
            parts.append(length)
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        DetailPage {
            DetailHeader(
                title: title,
                detail: detailLine,
                isPlayDisabled: contents.allSongs.isEmpty,
                onPlay: { FolderBrowser.play(contents.allSongs) },
                onShuffle: { FolderBrowser.play(contents.allSongs, shuffled: true) }
            ) {
                ArtworkView(image: artworkImage, cornerRadius: Design.Radius.artwork, placeholderSymbol: "folder.fill")
            }
        } rows: {
            if !contents.subfolders.isEmpty {
                Section {
                    ForEach(contents.subfolders) { subfolder in
                        NavigationLink(value: LibraryRoute.folder(path: subfolder.path)) {
                            CollectionRow(title: subfolder.name, subtitle: Localized.songsCountOnly(subfolder.songCount)) {
                                FolderThumb(track: subfolder.artworkTrack)
                            }
                        }
                        .listRowBackground(Color.clear)
                        .contextMenu {
                            Button {
                                FolderBrowser.play(FolderBrowser.contents(of: subfolder.path, in: allTracks).allSongs)
                            } label: {
                                Label(Localized.play, systemImage: "play.fill")
                            }
                            Button {
                                FolderBrowser.play(FolderBrowser.contents(of: subfolder.path, in: allTracks).allSongs, shuffled: true)
                            } label: {
                                Label(Localized.shuffle, systemImage: "shuffle")
                            }
                        }
                    }
                } header: {
                    Text(Localized.folders)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }

            if !contents.songs.isEmpty {
                Section {
                    ForEach(Array(contents.songs.enumerated()), id: \.element.stableId) { index, track in
                        LiveTrackRow(
                            track: track,
                            artistName: artistNames[track.stableId],
                            showsDuration: true,
                            contextIdentity: rowContextIdentity
                        ) {
                            FolderBrowser.play(contents.songs, startingAt: index)
                        }
                        .songListRow(track)
                    }
                } header: {
                    if !contents.subfolders.isEmpty {
                        Text(Localized.songs)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                    }
                }
            } else if didLoad && contents.subfolders.isEmpty {
                Text(Localized.folderNoSongs)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
        }
        .background(ArtworkBackground(image: artworkImage, line: HaloLine(for: .albumDetail)))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(path)|\(TrackSearchIndex.identity(for: allTracks))") {
            await load()
        }
    }

    private func load() async {
        let iCloudFolder = await Task.detached(priority: .userInitiated) {
            StateManager.shared.getMusicFolderURL()
        }.value
        title = FolderBrowser.displayName(ofPath: path, sources: FolderBrowser.sources(iCloudFolder: iCloudFolder))

        let path = self.path
        let tracks = allTracks
        contents = await Task.detached(priority: .userInitiated) {
            FolderBrowser.contents(of: path, in: tracks)
        }.value
        didLoad = true

        let fallbackArtistIds = contents.songs.reduce(into: [String: Int64]()) { result, track in
            if let artistId = track.artistId { result[track.stableId] = artistId }
        }
        artistNames = (try? DatabaseManager.shared.getArtistDisplayNames(
            forTrackStableIds: contents.songs.map(\.stableId),
            fallbackArtistIdsByStableId: fallbackArtistIds
        )) ?? [:]

        if let coverTrack = contents.allSongs.first(where: \.hasArtwork) {
            artworkImage = await ArtworkManager.shared.getArtwork(for: coverTrack)
        }
    }
}
