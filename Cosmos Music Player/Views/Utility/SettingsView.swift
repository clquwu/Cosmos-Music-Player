import SwiftUI
import Intents

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var deleteSettings = DeleteSettings.load()
    @State private var showDeleteFolderPlaylistsPrompt = false
    @AppStorage(HaloStyle.storageKey) private var haloStyle: HaloStyle = .silk
    @AppStorage(HaloStyle.motionKey) private var haloMotion = true
    @AppStorage(HaloStyle.miniKey) private var haloMini = false
    @AppStorage(HaloStyle.formKey) private var haloForm = 0
    @AppStorage(PlayerBackgroundStyle.storageKey) private var playerBackground: PlayerBackgroundStyle = .deviceDefault
    @AppStorage(PlayerEngine.resumeOnCarPlayConnectKey) private var resumeOnCarPlayConnect = false
    @AppStorage(VolumeLevellingMode.storageKey) private var volumeLevelling: VolumeLevellingMode = .off
    @State private var showClearHistoryPrompt = false
    @State private var siriStatus = INPreferences.siriAuthorizationStatus()
    @AppStorage(SupportCosmos.reminderEnabledKey) private var supportReminder = true
    @AppStorage(SupportCosmos.supporterKey) private var isSupporter = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where "I've Donated" sits on screen, and where its hearts rise from.
    @State private var donatedButtonFrame: CGRect = .zero
    @State private var heartBurstOrigin: CGPoint?
    @Environment(\.openURL) private var openURL
    #if DEBUG
    @State private var debugPage: String?
    #endif

    private func deleteExistingFolderPlaylists() {
        do {
            let folderPlaylists = try DatabaseManager.shared.getAllFolderPlaylists()
            for playlist in folderPlaylists {
                if let id = playlist.id {
                    try DatabaseManager.shared.deletePlaylist(playlistId: id)
                }
            }
            print("🗑️ Deleted \(folderPlaylists.count) folder playlist(s) after disabling auto-creation")
        } catch {
            print("❌ Failed to delete folder playlists: \(error)")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                // One row per area, as in the system Settings: the single
                // long page had grown to sixteen sections.
                Section {
                    pageLink(Localized.appearance, detail: Localized.settingsAppearanceDetail, systemImage: "paintbrush.fill", color: .indigo) {
                        appearancePage
                    }
                    pageLink(Localized.settingsPlayback, detail: Localized.settingsPlaybackDetail, systemImage: "play.fill", color: .pink) {
                        playbackPage
                    }
                    pageLink(Localized.librarySection, detail: Localized.settingsLibraryDetail, systemImage: "music.note.list", color: .orange) {
                        libraryPage
                    }
                    pageLink(Localized.settingsSiriHistory, detail: Localized.settingsSiriHistoryDetail, systemImage: "waveform", color: .purple) {
                        siriHistoryPage
                    }
                }

                Section {
                    if let paypal = SupportCosmos.paypalURL {
                        donateRow(Localized.supportPayPal, systemImage: "heart.fill", iconColor: .pink, url: paypal)
                    }
                    donateRow(
                        Localized.supportGitHub,
                        systemImage: SupportCosmos.paypalURL == nil ? "heart.fill" : "chevron.left.forwardslash.chevron.right",
                        iconColor: SupportCosmos.paypalURL == nil ? .pink : .secondary,
                        url: SupportCosmos.githubSponsorsURL
                    )
                    if isSupporter {
                        // On trust, and only a thank-you: nothing is unlocked.
                        Label {
                            Text(Localized.supportThankYouBadge)
                        } icon: {
                            Image(systemName: "heart.fill")
                                .foregroundStyle(.pink)
                                .symbolEffect(.bounce, value: isSupporter)
                        }
                    } else {
                        Button(Localized.supportIDonated) {
                            if !reduceMotion {
                                heartBurstOrigin = CGPoint(x: donatedButtonFrame.minX + 60, y: donatedButtonFrame.midY)
                            }
                            withAnimation(.snappy) { isSupporter = true }
                        }
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { donatedButtonFrame = $0 }
                        Toggle(Localized.supportMonthlyReminder, isOn: $supportReminder)
                    }
                } header: {
                    Text(Localized.supportCosmos)
                } footer: {
                    Text(Localized.supportFooter)
                }

                Section(Localized.information) {
                    LabeledContent(Localized.version, value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? Localized.unknown)

                    if let url = URL(string: "https://github.com/clquwu/Cosmos-Music-Player") {
                        Link(destination: url) {
                            HStack {
                                Text(Localized.githubRepository)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                }

                #if DEBUG
                Section("Developer") {
                    NavigationLink("Mix Diagnostics") { MixDebugView() }
                }
                #endif
            }
            .navigationTitle(Localized.settings)
            .navigationBarTitleDisplayMode(.inline)
            #if DEBUG
            // -cosmosDebugSettingsPage appearance|playback|library|siri|eq|
            // folders|mix opens that page, for screenshots.
            .navigationDestination(item: $debugPage) { page in
                switch page {
                case "appearance": appearancePage
                case "playback": playbackPage
                case "library": libraryPage
                case "siri": siriHistoryPage
                case "eq": EQSettingsView()
                case "folders": MusicFoldersView()
                default: MixDebugView()
                }
            }
            .task {
                try? await Task.sleep(for: .milliseconds(500))
                debugPage = UserDefaults.standard.string(forKey: "cosmosDebugSettingsPage")
            }
            #endif
            .sensoryFeedback(.success, trigger: isSupporter) { _, new in new }
            .overlay {
                if let origin = heartBurstOrigin {
                    GeometryReader { proxy in
                        let frame = proxy.frame(in: .global)
                        HeartBurstView()
                            .position(x: origin.x - frame.minX, y: origin.y - frame.minY)
                    }
                    .ignoresSafeArea()
                    .task {
                        try? await Task.sleep(for: .seconds(2.6))
                        heartBurstOrigin = nil
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Localized.done) {
                        dismiss()
                    }
                }
            }
        }
    }

    /// Light or dark, the theme colour, the halo behind the pages and the player's background.
    private var appearancePage: some View {
        Form {
            Section {
                Picker(Localized.appAppearance, selection: $deleteSettings.appearance) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: deleteSettings.appearance) { _, _ in
                    deleteSettings.save()
                }
            } header: {
                Text(Localized.appAppearance)
            }

            Section {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 52), spacing: Design.Spacing.m)],
                    spacing: Design.Spacing.l
                ) {
                    ForEach(BackgroundColor.allCases, id: \.self) { color in
                        colorSwatch(color)
                    }
                }
                .padding(.vertical, Design.Spacing.xs)
            } header: {
                Text(Localized.themeColor)
            }

            Section {
                // Live previews of each style, in the chosen colour.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Design.Spacing.m) {
                        ForEach(HaloStyle.allCases) { style in
                            haloTile(style)
                        }
                    }
                    .padding(.vertical, Design.Spacing.xs)
                }
                .listRowInsets(EdgeInsets(top: Design.Spacing.s, leading: Design.Spacing.l, bottom: Design.Spacing.s, trailing: Design.Spacing.l))

                // The full-size shapes of the chosen style, side by side.
                if !haloMini, [.silk, .lines, .aurora, .classic].contains(haloStyle) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Design.Spacing.m) {
                            ForEach(0...HaloStyle.formCount, id: \.self) { form in
                                shapeTile(form)
                            }
                        }
                        .padding(.vertical, Design.Spacing.xs)
                    }
                    .listRowInsets(EdgeInsets(top: Design.Spacing.s, leading: Design.Spacing.l, bottom: Design.Spacing.s, trailing: Design.Spacing.l))
                }

                Picker(Localized.haloSize, selection: $haloMini) {
                    Text(Localized.haloSizeFull).tag(false)
                    Text(Localized.haloSizeMini).tag(true)
                }
                .disabled(haloStyle == .none || haloStyle == .glow)

                Toggle(Localized.haloMotion, isOn: $haloMotion)
                    .disabled(haloStyle == .none)
            } header: {
                Text(Localized.haloStyle)
            }

            Section {
                Picker(Localized.playerBackground, selection: $playerBackground) {
                    ForEach(PlayerBackgroundStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
            }
        }
        .navigationTitle(Localized.appearance)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// What you hear and the player's buttons.
    private var playbackPage: some View {
        Form {
            Section {
                NavigationLink(destination: EQSettingsView()) {
                    Label(Localized.graphicEqualizer, systemImage: "slider.horizontal.3")
                }

                Picker(selection: $volumeLevelling) {
                    ForEach(VolumeLevellingMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                } label: {
                    Label(Localized.volumeLevelling, systemImage: "speaker.wave.2")
                }
                .onChange(of: volumeLevelling) { _, _ in
                    // Applied to the song that is playing straight away,
                    // not from the next one.
                    PlayerEngine.shared.volumeLevellingModeDidChange()
                }
            } header: {
                Text(Localized.audioSettings)
            } footer: {
                Text(Localized.volumeLevellingFooter)
            }

            Section {
                VStack(alignment: .leading, spacing: Design.Spacing.s) {
                    Text(Localized.dsdPlaybackMode)

                    Picker(Localized.dsdPlaybackMode, selection: $deleteSettings.dsdPlaybackMode) {
                        ForEach(DSDPlaybackMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: deleteSettings.dsdPlaybackMode) { _, _ in
                        deleteSettings.save()
                    }
                }
                .padding(.vertical, Design.Spacing.xs)
            } footer: {
                Text(Localized.dsdPlaybackModeDescription + "\n\n" + deleteSettings.dsdPlaybackMode.description)
            }

            Section {
                Toggle(Localized.showLyricsButton, isOn: $deleteSettings.showLyricsButton)
                    .onChange(of: deleteSettings.showLyricsButton) { _, _ in
                        deleteSettings.save()
                    }

                Toggle(Localized.showSleepTimerButton, isOn: $deleteSettings.showSleepTimerButton)
                    .onChange(of: deleteSettings.showSleepTimerButton) { _, _ in
                        deleteSettings.save()
                    }

                Toggle(Localized.queueFullListFromSearch, isOn: $deleteSettings.queueFullListFromSearch)
                    .onChange(of: deleteSettings.queueFullListFromSearch) { _, _ in
                        deleteSettings.save()
                    }

                Toggle(Localized.resumeOnCarPlayConnect, isOn: $resumeOnCarPlayConnect)
            } header: {
                Text(Localized.playerControls)
            }
        }
        .navigationTitle(Localized.settingsPlayback)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Where the music comes from, what the Library lists and how songs are filed.
    private var libraryPage: some View {
        Form {
            Section {
                Picker(Localized.libraryScanFrequency, selection: $deleteSettings.libraryScanInterval) {
                    ForEach(LibraryScanInterval.allCases, id: \.self) { interval in
                        Text(interval.displayName).tag(interval)
                    }
                }
                .onChange(of: deleteSettings.libraryScanInterval) { _, _ in
                    deleteSettings.save()
                }

                NavigationLink(destination: MusicFoldersView()) {
                    Label(Localized.musicFolders, systemImage: "folder")
                }
            } header: {
                Text(Localized.librarySection)
            }

            // These once ordered the old home screen; now they choose what
            // the Library tab lists. Its order is fixed and Add Songs is
            // a toolbar button, so neither is offered here any more.
            Section {
                ForEach($deleteSettings.homeSections) { $section in
                    if section.id != .addSongs {
                        Toggle(isOn: $section.isVisible) {
                            Label(section.id.displayName, systemImage: section.id.icon)
                        }
                        .onChange(of: section.isVisible) { _, _ in
                            deleteSettings.save()
                        }
                    }
                }
            } header: {
                Text(Localized.libraryItems)
            }

            Section {
                Toggle(Localized.splitArtistsOnComma, isOn: $deleteSettings.splitArtistsOnComma)
                    .onChange(of: deleteSettings.splitArtistsOnComma) { _, _ in
                        deleteSettings.save()
                    }
            } footer: {
                Text(Localized.splitArtistsOnCommaDescription)
            }

            Section {
                Toggle(Localized.removeFromLibraryOnly, isOn: $deleteSettings.deleteFromLibraryOnly)
                    .onChange(of: deleteSettings.deleteFromLibraryOnly) { _, _ in
                        deleteSettings.save()
                    }
            } footer: {
                Text(Localized.removeFromLibraryOnlyDescription)
            }

            Section {
                Toggle(Localized.autoFolderPlaylists, isOn: $deleteSettings.autoCreateFolderPlaylists)
                    .onChange(of: deleteSettings.autoCreateFolderPlaylists) { _, newValue in
                        deleteSettings.save()
                        if newValue {
                            // Re-enabled: clear tombstones so folder playlists
                            // can be recreated on the next scan
                            try? DatabaseManager.shared.clearDeletedFolderPlaylistTombstones()
                        } else {
                            showDeleteFolderPlaylistsPrompt = true
                        }
                    }
            } footer: {
                Text(Localized.autoFolderPlaylistsDescription)
            }
            .alert(Localized.deleteFolderPlaylistsTitle, isPresented: $showDeleteFolderPlaylistsPrompt) {
                Button(Localized.deleteFolderPlaylistsConfirm, role: .destructive) {
                    deleteExistingFolderPlaylists()
                }
                Button(Localized.keepFolderPlaylists, role: .cancel) {}
            } message: {
                Text(Localized.deleteFolderPlaylistsMessage)
            }
        }
        .navigationTitle(Localized.librarySection)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Siri's permission and the listening history the mixes learn from.
    private var siriHistoryPage: some View {
        Form {
            Section {
                LabeledContent(Localized.siri, value: siriStatus == .authorized ? Localized.siriAllowed : Localized.siriNotAllowed)
                if siriStatus == .notDetermined {
                    Button(Localized.siriAllow) {
                        INPreferences.requestSiriAuthorization { status in
                            Task { @MainActor in siriStatus = status }
                        }
                    }
                } else if siriStatus != .authorized, let url = URL(string: UIApplication.openSettingsURLString) {
                    Link(Localized.siriOpenSettings, destination: url)
                }
            }

            Section {
                Button(Localized.clearListeningHistory, role: .destructive) {
                    showClearHistoryPrompt = true
                }
            } header: {
                Text(Localized.listeningHistory)
            } footer: {
                Text(Localized.listeningHistoryDescription)
            }
            .confirmationDialog(Localized.clearListeningHistory, isPresented: $showClearHistoryPrompt, titleVisibility: .visible) {
                Button(Localized.clearListeningHistory, role: .destructive) {
                    ListeningLog.shared.clear()
                    NotificationCenter.default.post(name: NSNotification.Name("LibraryNeedsRefresh"), object: nil)
                }
            } message: {
                Text(Localized.clearListeningHistoryMessage)
            }
        }
        .navigationTitle(Localized.settingsSiriHistory)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A row opening one of the pages: a coloured icon, the page's name and
    /// what is on it.
    private func pageLink<Destination: View>(
        _ title: String,
        detail: String,
        systemImage: String,
        color: Color,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: Design.Spacing.m) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 2)
        }
    }


    private func donateRow(_ title: String, systemImage: String, iconColor: Color, url: URL) -> some View {
        Button {
            SupportCosmos.markPrompted()
            openURL(url)
        } label: {
            HStack {
                Label {
                    Text(title)
                        .foregroundStyle(.primary)
                } icon: {
                    Image(systemName: systemImage)
                        .foregroundStyle(iconColor)
                }
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }

    /// A shape of the chosen style at full size; 0 is Random.
    private func shapeTile(_ form: Int) -> some View {
        let isSelected = haloForm == form
        return Button {
            haloForm = form
        } label: {
            VStack(spacing: Design.Spacing.xs + 2) {
                Group {
                    if form == 0 {
                        ZStack {
                            Color(.secondarySystemBackground)
                            Image(systemName: "shuffle")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(ThemeStore.shared.accent)
                        }
                    } else {
                        HaloBackground(line: HaloLine(for: .library), styleOverride: haloStyle, formOverride: form, miniOverride: false, animates: isSelected)
                    }
                }
                .frame(width: 76, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(isSelected ? ThemeStore.shared.accent : Color(.separator), lineWidth: isSelected ? 2.5 : 0.5)
                )
                Text(form == 0 ? Localized.haloShapeRandom : "\(Localized.haloShape) \(form)")
                    .font(.footnote.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(form == 0 ? Localized.haloShapeRandom : "\(Localized.haloShape) \(form)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func haloTile(_ style: HaloStyle) -> some View {
        let isSelected = haloStyle == style
        return Button {
            haloStyle = style
        } label: {
            VStack(spacing: Design.Spacing.xs + 2) {
                // Only the chosen style moves: six full halos animating at
                // once behind a settings list was the most expensive screen
                // in the app, for previews nobody watches side by side.
                HaloBackground(line: HaloLine(for: .library), styleOverride: style, animates: isSelected)
                    .frame(width: 76, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(isSelected ? ThemeStore.shared.accent : Color(.separator), lineWidth: isSelected ? 2.5 : 0.5)
                    )
                Text(style.title)
                    .font(.footnote.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(style.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func colorSwatch(_ color: BackgroundColor) -> some View {
        let isSelected = deleteSettings.backgroundColorChoice == color
        return Button {
            deleteSettings.backgroundColorChoice = color
            deleteSettings.save()
            NotificationCenter.default.post(name: NSNotification.Name("BackgroundColorChanged"), object: nil)
        } label: {
            Circle()
                .fill(color.color)
                .frame(width: 44, height: 44)
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .padding(3)
                .overlay(
                    Circle()
                        .strokeBorder(isSelected ? Color.primary : Color.clear, lineWidth: 2)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(color.name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview {
    SettingsView()
}
