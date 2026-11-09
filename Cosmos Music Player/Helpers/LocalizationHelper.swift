//
//  LocalizationHelper.swift
//  Cosmos Music Player
//
//  Localization helper for easy access to localized strings
//

import Foundation

extension String {
    /// Returns the localized string for this key
    var localized: String {
        return NSLocalizedString(self, comment: "")
    }
    
    /// Returns the localized string with format arguments
    func localized(with arguments: CVarArg...) -> String {
        return String(format: NSLocalizedString(self, comment: ""), arguments: arguments)
    }

    /// A count with its noun in the right form, from Localizable.stringsdict:
    /// "1 song" / "2 songs", "0 musique", and Russian's three forms ("1 песня",
    /// "2 песни", "5 песен") that a singular/plural pair of keys cannot hold.
    /// Formatted in the current locale: without one, Foundation picks the
    /// form by English rules and Russian read "5 песни".
    func pluralized(_ arguments: CVarArg...) -> String {
        String(format: NSLocalizedString(self, comment: ""), locale: Locale.current, arguments: arguments)
    }
}

/// Localization helper with commonly used strings
struct Localized {
    // MARK: - Playback failure strings
    static let playbackTrackUnavailable = "playback_track_unavailable".localized
    static let playbackFormatNeedsPhone = "playback_format_needs_phone".localized
    static let playbackDownloadStalled = "playback_download_stalled".localized
    static let playbackAudioUnavailable = "playback_audio_unavailable".localized
    /// CarPlay refuses SFBAudioEngine outright, so Opus/Vorbis/DSD cannot play
    /// there at all. Saying the file "may have been moved" would send the user
    /// looking for a problem that does not exist.

    // MARK: - Playlist strings
    static let playlists = "playlists".localized
    static let noPlaylistsYet = "no_playlists_yet".localized
    static let createPlaylistsInstruction = "create_playlists_instruction".localized
    static let addToPlaylist = "add_to_playlist".localized
    static let createNewPlaylist = "create_new_playlist".localized
    static let createPlaylist = "create_playlist".localized
    static let playlistNamePlaceholder = "playlist_name_placeholder".localized
    static let aiPlaylistTitle = "ai_playlist_title".localized
    static let aiPlaylistDescription = "ai_playlist_description".localized
    static let aiPlaylistPlaceholder = "ai_playlist_placeholder".localized
    static let aiPlaylistGenerate = "ai_playlist_generate".localized
    static let aiPlaylistGenerating = "ai_playlist_generating".localized
    static let aiPlaylistFailed = "ai_playlist_failed".localized
    static let aiPlaylistButton = "ai_playlist_button".localized
    static let aiPlaylistCreatedTitle = "ai_playlist_created_title".localized
    static func aiPlaylistCreatedMessage(_ title: String, _ count: Int) -> String {
        "ai_playlist_created_message".pluralized(title, count)
    }
    static let enterPlaylistName = "enter_playlist_name".localized
    static let deletePlaylist = "delete_playlist".localized
    static let delete = "delete".localized
    static let cancel = "cancel".localized
    static let create = "create".localized
    static let done = "done".localized
    static let edit = "edit".localized
    static let editPlaylist = "edit_playlist".localized
    static let save = "save".localized
    static let enterNewName = "enter_new_name".localized
    static let managePlaylists = "manage_playlists".localized
    static let playlist = "playlist".localized
    static let createFirstPlaylist = "create_first_playlist".localized
    static let playlistCover = "playlist_cover".localized
    static let changeCoverImage = "change_cover_image".localized
    static let removeCustomCover = "remove_custom_cover".localized
    
    // MARK: - General UI strings
    static let allSongs = "all_songs".localized
    static let likedSongs = "liked_songs".localized
    static let addSongs = "add_songs".localized
    static let importMusicFiles = "import_music_files".localized
    static let noSongsFound = "no_songs_found".localized
    static let yourMusicWillAppearHere = "your_music_will_appear_here".localized
    static let unknown = "unknown".localized
    static let ok = "ok".localized
    static let settings = "settings".localized
    static let retry = "retry".localized
    static let openSettings = "open_settings".localized
    static let `continue` = "continue".localized
    static let back = "back".localized
    static let getStarted = "get_started".localized
    static let imSignedIn = "im_signed_in".localized
    static let itsEnabled = "its_enabled".localized
    
    // MARK: - Library and Navigation
    static let library = "library".localized
    static let artists = "artists".localized
    static let albumArtists = "album_artists".localized
    static let allArtists = "all_artists".localized
    static let libraryScanFrequency = "library_scan_frequency".localized
    static let libraryScanFrequencyDescription = "library_scan_frequency_description".localized
    /// Shown while the one-time Opus-in-M4A sweep reads file headers, which
    /// happens before indexing starts and would otherwise look like a hang.
    static let checkingLibraryFormats = "checking_library_formats".localized
    static let scanEveryLaunch = "scan_every_launch".localized
    static let scanHourly = "scan_hourly".localized
    static let scanDaily = "scan_daily".localized
    static let scanWeekly = "scan_weekly".localized
    static let scanManualOnly = "scan_manual_only".localized
    static let albums = "albums".localized
    static let search = "search".localized
    static let browse = "browse".localized
    static let songs = "songs".localized
    static let processing = "processing".localized
    static let waiting = "waiting".localized
    static let searching = "searching".localized
    
    // MARK: - Artist/Album/Track Info
    static let noArtistsFound = "no_artists_found".localized
    static let artistsWillAppear = "artists_will_appear".localized
    static let noAlbumsFound = "no_albums_found".localized
    static let albumsWillAppear = "albums_will_appear".localized
    static let artist = "artist".localized
    static let album = "album".localized
    static let play = "play".localized
    static let shuffle = "shuffle".localized
    static let wrongArtist = "wrong_artist".localized
    static let openSpotify = "open_spotify".localized
    static let loadingArtist = "loading_artist".localized
    
    // MARK: - Player
    static let playingQueue = "playing_queue".localized
    static let noSongsInQueue = "no_songs_in_queue".localized
    static let noTrackSelected = "no_track_selected".localized
    
    // MARK: - Search
    static let searchYourMusicLibrary = "search_your_music_library".localized
    // Prompts for the in-place search bars on the library's list screens
    static let searchSongs = "search_songs".localized
    static let searchArtists = "search_artists".localized
    static let searchAlbums = "search_albums".localized
    static let searchPlaylists = "search_playlists".localized
    static let findSongsArtistsAlbumsPlaylists = "find_songs_artists_albums_playlists".localized
    static let noResultsFound = "no_results_found".localized
    static let tryDifferentKeywords = "try_different_keywords".localized
    
    // MARK: - Context Menu Actions
    static let showArtistPage = "show_artist_page".localized
    static let addToPlaylistEllipsis = "add_to_playlist_ellipsis".localized
    static let deleteFile = "delete_file".localized
    
    // MARK: - Settings
    static let appearance = "appearance".localized
    static let information = "information".localized
    static let minimalistLibraryIcons = "minimalist_library_icons".localized
    static let appAppearance = "app_appearance".localized
    static let appAppearanceDescription = "app_appearance_description".localized
    static let appearanceSystem = "appearance_system".localized
    static let appearanceLight = "appearance_light".localized
    static let appearanceDark = "appearance_dark".localized
    static let version = "version".localized
    static let appName = "app_name".localized
    static let cosmosMusicPlayer = "cosmos_music_player".localized
    static let githubRepository = "github_repository".localized
    static let useSimpleIcons = "use_simple_icons".localized
    static let overrideSystemAppearance = "override_system_appearance".localized
    static let backgroundColor = "background_color".localized
    static let chooseColorTheme = "choose_color_theme".localized
    static let librarySection = "library_section".localized
    static let homeSections = "home_sections".localized
    static let chooseVisibleSections = "choose_visible_sections".localized
    static let removeFromLibraryOnly = "remove_from_library_only".localized
    static let removeFromLibraryOnlyDescription = "remove_from_library_only_description".localized
    static let autoFolderPlaylists = "auto_folder_playlists".localized
    static let autoFolderPlaylistsDescription = "auto_folder_playlists_description".localized
    static let deleteFolderPlaylistsTitle = "delete_folder_playlists_title".localized
    static let deleteFolderPlaylistsMessage = "delete_folder_playlists_message".localized
    static let deleteFolderPlaylistsConfirm = "delete_folder_playlists_confirm".localized
    static let keepFolderPlaylists = "keep_folder_playlists".localized
    static let playerControls = "player_controls".localized
    static let showLyricsButton = "show_lyrics_button".localized
    static let showSleepTimerButton = "show_sleep_timer_button".localized
    static let queueFullListFromSearch = "queue_full_list_from_search".localized
    static let queueFullListFromSearchDescription = "queue_full_list_from_search_description".localized
    static let splitArtistsOnComma = "split_artists_on_comma".localized
    static let splitArtistsOnCommaDescription = "split_artists_on_comma_description".localized
    
    // MARK: - Liked Songs Actions
    static let addToLikedSongs = "add_to_liked_songs".localized
    static let removeFromLikedSongs = "remove_from_liked_songs".localized
    
    // MARK: - Search Categories
    static let all = "all".localized
    
    // MARK: - Sync and Connection
    static let libraryOutOfSync = "library_out_of_sync".localized
    static let librarySyncMessage = "library_sync_message".localized
    static let offlineMode = "offline_mode".localized
    static let offlineModeMessage = "offline_mode_message".localized
    static let icloudConnectionRequired = "icloud_connection_required".localized
    
    // MARK: - Tutorial/Onboarding
    static let welcomeToCosmos = "welcome_to_cosmos".localized
    static let signInToAppleId = "sign_in_to_apple_id".localized
    static let signInMessage = "sign_in_message".localized
    static let ifSignedInContinue = "if_signed_in_continue".localized
    static let enableIcloudDrive = "enable_icloud_drive".localized
    static let icloudDriveMessage = "icloud_drive_message".localized
    static let ifIcloudEnabledContinue = "if_icloud_enabled_continue".localized
    static let addYourMusic = "add_your_music".localized
    static let howToAddMusic = "how_to_add_music".localized
    static let openFilesApp = "open_files_app".localized
    static let navigateToIcloudDrive = "navigate_to_icloud_drive".localized
    static let findCosmosPlayerFolder = "find_cosmos_player_folder".localized
    static let addYourMusicInstruction = "add_your_music_instruction".localized
    
    // MARK: - Tutorial Status Messages
    static let signedInToAppleId = "signed_in_to_apple_id".localized
    static let notSignedInToAppleId = "not_signed_in_to_apple_id".localized
    static let cannotDetectAppleIdStatus = "cannot_detect_apple_id_status".localized
    static let icloudDriveEnabled = "icloud_drive_enabled".localized
    static let icloudDriveNotEnabled = "icloud_drive_not_enabled".localized
    static let cannotDetectIcloudStatus = "cannot_detect_icloud_status".localized
    
    // MARK: - Tutorial Instructions
    static let findOpenFilesApp = "find_open_files_app".localized
    static let tapIcloudDriveSidebar = "tap_icloud_drive_sidebar".localized
    static let lookForCosmosFolder = "look_for_cosmos_folder".localized
    static let copyMusicFiles = "copy_music_files".localized
    
    // MARK: - Library Processing
    static let processingColon = "processing_colon".localized
    static let waitingColon = "waiting_colon".localized
    static let settingUpICloudLibrary = "setting_up_icloud_library".localized
    static let settingUpOfflineLibrary = "setting_up_offline_library".localized
    static let settingUpLocalLibrary = "setting_up_local_library".localized
    
    // MARK: - Subtitles and descriptions
    static let yourFavorites = "your_favorites".localized
    static let yourPlaylists = "your_playlists".localized
    static let browseByArtist = "browse_by_artist".localized
    static let browseByAlbum = "browse_by_album".localized
    static let unknownAlbum = "unknown_album".localized
    static let unknownArtist = "unknown_artist".localized
    
    // MARK: - Dynamic strings with parameters
    static func songsCount(_ count: Int) -> String {
        songsCountOnly(count)
    }
    
    static func createdDate(_ dateString: String) -> String {
        return "created_date".localized(with: dateString)
    }
    
    static func deletePlaylistConfirmation(_ playlistName: String) -> String {
        return "delete_playlist_confirmation".localized(with: playlistName)
    }
    
    static func deleteFileConfirmation(_ fileName: String) -> String {
        return "delete_file_confirmation".localized(with: fileName)
    }
    
    static func foundTracks(_ count: Int) -> String {
        "found_tracks".pluralized(count)
    }
    
    static func andMore(_ count: Int) -> String {
        return "and_more".localized(with: count)
    }
    
    static func dataProvidedBy(_ source: String) -> String {
        return "data_provided_by".localized(with: source)
    }
    
    static func percentComplete(_ percent: Int) -> String {
        return "percent_complete".localized(with: percent)
    }
    
    static func songsCountOnly(_ count: Int) -> String {
        // One song is "1 song" / "1 musique", not "1 songs".
        "songs_count".pluralized(count)
    }

    static func albumsCount(_ count: Int) -> String {
        "albums_count_plural".pluralized(count)
    }

    static func discNumber(_ number: Int) -> String {
        "disc_number".localized(with: number)
    }

    static func importedSongCount(_ count: Int) -> String {
        "imported_song_count_plural".pluralized(count)
    }

    static func songsAlreadyInLibrary(_ count: Int) -> String {
        "songs_already_in_library".localized(with: count)
    }

    static func importSummary(imported: Int, skipped: Int) -> String {
        "import_summary".localized(with: imported, skipped)
    }

    // MARK: - Equalizer strings
    static let equalizer = "equalizer".localized
    static let graphicEqualizer = "graphic_equalizer".localized
    static let enableEqualizer = "enable_equalizer".localized
    static let enableDisableEqDescription = "enable_disable_eq_description".localized

    // Manual EQ Presets
    static let manualEQPresets = "manual_eq_presets".localized
    static let noManualPresetsCreated = "no_manual_presets_created".localized
    static let createManualEQDescription = "create_manual_eq_description".localized
    static let createManual16BandEQ = "create_manual_16band_eq".localized
    static let manual16BandEQ = "manual_16band_eq".localized
    static let manual16BandDescription = "manual_16band_description".localized
    static let adjustBandsAfterCreation = "adjust_bands_after_creation".localized
    static let frequencyBands = "frequency_bands".localized
    static let editEqualizer = "edit_equalizer".localized
    static let resetToFlat = "reset_to_flat".localized
    static let manualParametricEQ = "manual_parametric_eq".localized
    static let createManualEQ = "create_manual_eq".localized
    static let bands = "bands".localized
    static let createParametricEQDescription = "create_parametric_eq_description".localized
    static let editParametricBandsDescription = "edit_parametric_bands_description".localized
    static let parametricEditor = "parametric_editor".localized
    static let addBand = "add_band".localized
    static let removeBand = "remove_band".localized
    static let selectedBand = "selected_band".localized
    static let frequency = "frequency".localized
    static let gain = "gain".localized

    static func bandCount(used: Int, maximum: Int) -> String {
        "band_count".localized(with: used, maximum)
    }

    static func bandNumber(_ number: Int) -> String {
        "band_number".localized(with: number)
    }

    // Imported GraphicEQ Presets
    static let importedPresets = "imported_presets".localized
    static let noPresetsImported = "no_presets_imported".localized
    static let importGraphicEQDescription = "import_graphiceq_description".localized
    static let importedGraphicEQ = "imported_graphiceq".localized
    static let importGraphicEQFile = "import_graphiceq_file".localized

    // General EQ Settings
    static let globalSettings = "global_settings".localized
    static let globalGain = "global_gain".localized
    static let globalGainDescription = "global_gain_description".localized
    static let aboutGraphicEQFormat = "about_graphiceq_format".localized
    static let importGraphicEQFormatDescription = "import_graphiceq_format_description".localized
    static let frequencyGainPairDescription = "frequency_gain_pair_description".localized
    static let eqExport = "export".localized
    static let eqDelete = "delete".localized
    static let eqEdit = "edit".localized
    static let eqCancel = "cancel".localized
    static let eqDone = "done".localized
    static let eqSave = "save".localized
    static let eqCreate = "create".localized
    static let presetInfo = "preset_info".localized

    // GraphicEQ Import View
    static let importGraphicEQ = "import_graphiceq".localized
    static let presetName = "preset_name".localized
    static let enterPresetName = "enter_preset_name".localized
    static let importMethods = "import_methods".localized
    static let importFromTxtFile = "import_from_txt_file".localized
    static let pasteGraphicEQText = "paste_graphiceq_text".localized
    static let eqError = "error".localized
    static let formatInfo = "format_info".localized
    static let expectedGraphicEQFormat = "expected_graphiceq_format".localized
    static let frequencyGainPair = "frequency_gain_pair".localized

    // Text Import View
    static let pasteGraphicEQ = "paste_graphiceq".localized
    static let pasteGraphicEQTextSection = "paste_graphiceq_text_section".localized
    static let example = "example".localized
    static let eqImport = "import".localized

    // Error Messages
    static func failedToImport(_ error: String) -> String {
        return "failed_to_import".localized(with: error)
    }

    static func fileImportFailed(_ error: String) -> String {
        return "file_import_failed".localized(with: error)
    }

    static func failedToCreate(_ error: String) -> String {
        return "failed_to_create".localized(with: error)
    }

    static let failedToExport = "failed_to_export".localized
    static let failedToDelete = "failed_to_delete".localized

    // EQ Band Information
    static func bandCountInfo(used: Int, original: Int) -> String {
        return "band_count_info".localized(with: used, original)
    }

    static func bandsReducedDescription(original: Int, reduced: Int) -> String {
        return "bands_reduced_description".localized(with: original, reduced)
    }

    static func bandsLimitedWarning(original: Int, limited: Int) -> String {
        return "bands_limited_warning".localized(with: original, limited)
    }

    // MARK: - Audio Settings
    static let audioSettings = "audio_settings".localized
    static let dsdPlaybackMode = "dsd_playback_mode".localized
    static let dsdPlaybackModeDescription = "dsd_playback_mode_description".localized
    static let dsdModeAuto = "dsd_mode_auto".localized
    static let dsdModePCM = "dsd_mode_pcm".localized
    static let dsdModeDoP = "dsd_mode_dop".localized
    static let dsdModeAutoDescription = "dsd_mode_auto_description".localized
    static let dsdModePCMDescription = "dsd_mode_pcm_description".localized
    static let dsdModeDoDescription = "dsd_mode_dop_description".localized

    // MARK: - Sort Options
    static let sortDateNewest = "sort_date_newest".localized
    static let sortDateOldest = "sort_date_oldest".localized
    static let sortNameAZ = "sort_name_az".localized
    static let sortNameZA = "sort_name_za".localized
    static let sortManualOrder = "sort_manual_order".localized
    static let sortArtistAZ = "sort_artist_az".localized
    static let sortArtistZA = "sort_artist_za".localized
    static let sortSizeLargest = "sort_size_largest".localized
    static let sortSizeSmallest = "sort_size_smallest".localized

    // MARK: - Queue Actions
    static let playNext = "play_next".localized
    static let addToQueue = "add_to_queue".localized

    // MARK: - Sleep Timer
    static let sleepTimer = "sleep_timer".localized
    static let sleepTimerOff = "sleep_timer_off".localized
    static let sleepTimer15Minutes = "sleep_timer_15_minutes".localized
    static let sleepTimer30Minutes = "sleep_timer_30_minutes".localized
    static let sleepTimer45Minutes = "sleep_timer_45_minutes".localized
    static let sleepTimer60Minutes = "sleep_timer_60_minutes".localized
    static let cancelSleepTimer = "cancel_sleep_timer".localized

    // MARK: - Lyrics
    static let lyrics = "lyrics".localized
    // MARK: - UI refresh
    static let settingsPlayback = "settings_playback".localized
    static let settingsSiriHistory = "settings_siri_history".localized
    static let settingsAppearanceDetail = "settings_appearance_detail".localized
    static let settingsPlaybackDetail = "settings_playback_detail".localized
    static let settingsLibraryDetail = "settings_library_detail".localized
    static let settingsSiriHistoryDetail = "settings_siri_history_detail".localized
    static let libraryAddRowSubtitle = "library_add_row_subtitle".localized
    static let importPlaylistM3U = "import_playlist_m3u".localized
    static let exportPlaylistM3U8 = "export_playlist_m3u8".localized
    static let playlistImportTitle = "playlist_import_title".localized
    static func playlistImportSummary(imported: Int, total: Int) -> String {
        "playlist_import_summary".pluralized(imported, total)
    }
    static let playlistImportSavedAs = "playlist_import_saved_as".localized
    static let playlistImportNotFound = "playlist_import_not_found".localized
    static let playlistImportNoneMatched = "playlist_import_none_matched".localized
    static func playlistImportRepeats(_ count: Int) -> String {
        "playlist_import_repeats".pluralized(count)
    }
    static let playlistImportOpen = "playlist_import_open".localized
    static let playlistImportFailed = "playlist_import_failed".localized
    static let playlistImportUnreadable = "playlist_import_unreadable".localized
    static let playlistImportEmpty = "playlist_import_empty".localized
    static let playlistImporting = "playlist_importing".localized
    static let volumeLevelling = "volume_levelling".localized
    static let volumeLevellingOff = "volume_levelling_off".localized
    static let volumeLevellingPerSong = "volume_levelling_per_song".localized
    static let volumeLevellingPerAlbum = "volume_levelling_per_album".localized
    static let volumeLevellingFooter = "volume_levelling_footer".localized
    static let sortReleaseOldest = "sort_release_oldest".localized
    static let sortReleaseNewest = "sort_release_newest".localized
    static let supportIDonated = "support_i_donated".localized
    static let supportThankYouBadge = "support_thank_you_badge".localized
    static let supportPayPal = "support_paypal".localized
    static let supportGitHub = "support_github".localized
    static let supportCosmos = "support_cosmos".localized
    static let supportPromptMessage = "support_prompt_message".localized
    static let supportFooter = "support_footer".localized
    static let supportMonthlyReminder = "support_monthly_reminder".localized
    static let supportNotNow = "support_not_now".localized
    static let supportDontAskAgain = "support_dont_ask_again".localized
    static let variousArtists = "various_artists".localized
    static let resumeOnCarPlayConnect = "resume_on_carplay_connect".localized
    static let addMusic = "add_music".localized
    static let addSongsFiles = "add_songs_files".localized
    static let addFolder = "add_folder".localized
    static let musicFolders = "music_folders".localized
    static let musicFoldersFooter = "music_folders_footer".localized
    static let noMusicFolders = "no_music_folders".localized
    static let folderUnsupportedTitle = "folder_unsupported_title".localized
    static let folderUnsupportedMessage = "folder_unsupported_message".localized
    static let folderAlreadyInLibrary = "folder_already_in_library".localized
    static let folderAlreadyLinked = "folder_already_linked".localized
    static let folderAddedFormat = "folder_added_format".localized
    static let folderAddFailed = "folder_add_failed".localized
    static let reconnect = "reconnect".localized
    static let folderNeedsReconnect = "folder_needs_reconnect".localized
    static let removeFolderTitle = "remove_folder_title".localized
    static let removeFolderMessage = "remove_folder_message".localized
    static let removeFolder = "remove_folder".localized
    static let folders = "folders".localized
    static let onThisDevice = "on_this_device".localized
    static let iCloudDrive = "icloud_drive".localized
    static let folderNoSongs = "folder_no_songs".localized
    static let folderReconnected = "folder_reconnected".localized
    static let freshFinds = "fresh_finds".localized
    static let whyFreshModeFormat = "why_fresh_mode_format".localized
    static let whyFreshModeAny = "why_fresh_mode_any".localized
    static let whyFreshTaste = "why_fresh_taste".localized
    static let whyFreshLovedFormat = "why_fresh_loved_format".localized
    static let chooseCoverFromPhotos = "choose_cover_from_photos".localized
    static let chooseCoverFromFiles = "choose_cover_from_files".localized
    static let haloShape = "halo_shape".localized
    static let haloShapeRandom = "halo_shape_random".localized
    static let haloSize = "halo_size".localized
    static let haloSizeFull = "halo_size_full".localized
    static let haloSizeMini = "halo_size_mini".localized
    static let whyPlayFormat = "why_play_format".localized
    static let whyPlayOften = "why_play_often".localized
    static let whyInMorning = "why_in_morning".localized
    static let whyInAfternoon = "why_in_afternoon".localized
    static let whyInEvening = "why_in_evening".localized
    static let whyAtNight = "why_at_night".localized
    static let whyWeekendMorning = "why_weekend_morning".localized
    static let whyWeekendAfternoon = "why_weekend_afternoon".localized
    static let whyWeekendEvening = "why_weekend_evening".localized
    static let whyWeekendNight = "why_weekend_night".localized
    static let whyWeekdayMorning = "why_weekday_morning".localized
    static let whyWeekdayAfternoon = "why_weekday_afternoon".localized
    static let whyWeekdayEvening = "why_weekday_evening".localized
    static let whyWeekdayNight = "why_weekday_night".localized
    static let whyOnWeekends = "why_on_weekends".localized
    static let whyOnWeekdays = "why_on_weekdays".localized
    static let whyRouteCar = "why_route_car".localized
    static let whyRouteHeadphones = "why_route_headphones".localized
    static let whyRouteBluetooth = "why_route_bluetooth".localized
    static let whyRouteSpeaker = "why_route_speaker".localized
    static let whyRouteAirplay = "why_route_airplay".localized
    static let whyMostlyFormat = "why_mostly_format".localized
    static let whyMostlyEraFormat = "why_mostly_era_format".localized
    static let whyEraFormat = "why_era_format".localized
    /// "12 listens" / "1 écoute" - "1 écoutes" before the plural rules.
    static func whyListens(_ count: Int) -> String {
        "why_listens_format".pluralized(count)
    }
    static let whyArtistsFormat = "why_artists_format".localized
    static func whyLibrary(songs: Int) -> String {
        "why_library_format".pluralized(songs)
    }
    static func whyFaded(weeks: Int) -> String {
        "why_faded_format".pluralized(weeks)
    }
    static let whyLapsedTitle = "why_lapsed_title".localized
    static let whyLapsedFormat = "why_lapsed_format".localized
    static let whyLapsedAny = "why_lapsed_any".localized
    static let whyObsessionsTitle = "why_obsessions_title".localized
    static let whyObsessionsDescription = "why_obsessions_desc".localized
    static let playlistMix = "playlist_mix".localized
    static let artistInfoSource = "artist_info_source".localized
    static let artistPhotoSource = "artist_photo_source".localized
    static let artistBioSummarized = "artist_bio_summarized".localized
    static let siriVoicePlayLikedSongs = "Play Liked Songs".localized
    static let siriVoicePlaysTheSongsYouLikedShuffled = "Plays the songs you liked, shuffled.".localized
    static let siriVoiceYouHavenTLikedAnySongs = "You haven't liked any songs in Cosmos yet.".localized
    static let siriVoiceLibrary = "Library".localized
    static let siriVoiceNavigation = "Navigation".localized
    static let siriVoiceMix = "Mix".localized
    static let siriVoiceSiriMixShelfSubtitle = "siri_mix_shelf_subtitle".localized
    static let siriVoicePlayMix = "Play Mix".localized
    static let siriVoicePlaysOneOfYourMadeFor = "Plays one of your Made for You or Rediscover mixes.".localized
    static let siriVoicePlayMix2 = "Play ${mix}".localized
    static let siriVoicePlaying = "Playing %@.".localized
    static let siriVoiceYourMixesArenTReadyYet = "Your mixes aren't ready yet. Open Cosmos once so it can make them.".localized
    static let siriVoicePlaySongMix = "Play Song Mix".localized
    static let siriVoicePlaysAMixOfSongsLike = "Plays a mix of songs like the current song, or like a song you name.".localized
    static let siriVoiceSong = "Song".localized
    static let siriVoiceLeaveEmptyToUseTheSong = "Leave empty to use the song playing now.".localized
    static let siriVoicePlayingAMixBasedOn = "Playing a mix based on %@.".localized
    static let siriVoiceICouldnTFindASong = "I couldn't find a song called %@ in Cosmos.".localized
    static let siriVoiceICouldnTFindInYour = "I couldn't find %@ in your Cosmos library.".localized
    static let siriVoiceControlPlayback = "Control Playback".localized
    static let siriVoicePauseSkipGoBackRestartShuffle = "Pause, skip, go back, restart, shuffle, repeat, unlike the current song, ask what's playing or cancel the sleep timer.".localized
    static let siriVoiceCommand = "Command".localized
    static let siriVoicePlayerCommand = "Player Command".localized
    static let siriVoicePauseTheMusic = "Pause the music".localized
    static let siriVoicePause = "Pause".localized
    static let siriVoiceStopTheMusic = "Stop the music".localized
    static let siriVoicePausePlayback = "Pause playback".localized
    static let siriVoiceNextSong = "Next song".localized
    static let siriVoiceSkipThisSong = "Skip this song".localized
    static let siriVoiceSkip = "Skip".localized
    static let siriVoicePlayTheNextSong = "Play the next song".localized
    static let siriVoicePreviousSong = "Previous song".localized
    static let siriVoiceGoBack = "Go back".localized
    static let siriVoicePlayThePreviousSong = "Play the previous song".localized
    static let siriVoicePrevious = "Previous".localized
    static let siriVoiceRestartThisSong = "Restart this song".localized
    static let siriVoicePlayThisSongAgain = "Play this song again".localized
    static let siriVoiceStartTheSongOver = "Start the song over".localized
    static let siriVoiceTurnOnShuffle = "Turn on shuffle".localized
    static let siriVoiceShuffleOn = "Shuffle on".localized
    static let siriVoiceShuffleTheQueue = "Shuffle the queue".localized
    static let siriVoiceTurnOffShuffle = "Turn off shuffle".localized
    static let siriVoiceShuffleOff = "Shuffle off".localized
    static let siriVoiceStopShuffling = "Stop shuffling".localized
    static let siriVoiceTurnOnRepeat = "Turn on repeat".localized
    static let siriVoiceRepeatOn = "Repeat on".localized
    static let siriVoiceRepeatTheQueue = "Repeat the queue".localized
    static let siriVoiceRepeatAll = "Repeat all".localized
    static let siriVoiceRepeatThisSong = "Repeat this song".localized
    static let siriVoiceLoopThisSong = "Loop this song".localized
    static let siriVoiceRepeatOne = "Repeat one".localized
    static let siriVoiceTurnOffRepeat = "Turn off repeat".localized
    static let siriVoiceRepeatOff = "Repeat off".localized
    static let siriVoiceStopRepeating = "Stop repeating".localized
    static let siriVoiceUnlikeThisSong = "Unlike this song".localized
    static let siriVoiceRemoveThisSongFromFavorites = "Remove this song from favorites".localized
    static let siriVoiceRemoveThisSongFromLikedSongs = "Remove this song from Liked Songs".localized
    static let siriVoiceIDonTLikeThisSong = "I don't like this song".localized
    static let siriVoiceWhatSPlaying = "What's playing".localized
    static let siriVoiceWhatSongIsThis = "What song is this".localized
    static let siriVoiceWhatSThisSong = "What's this song".localized
    static let siriVoiceWhoSingsThis = "Who sings this".localized
    static let siriVoiceCancelTheSleepTimer = "Cancel the sleep timer".localized
    static let siriVoiceTurnOffTheSleepTimer = "Turn off the sleep timer".localized
    static let siriVoiceStopTheSleepTimer = "Stop the sleep timer".localized
    static let siriVoiceSleepTimerCancelled = "Sleep timer cancelled.".localized
    static let siriVoicePaused = "Paused.".localized
    static let siriVoiceSkipped = "Skipped.".localized
    static let siriVoicePlayingThePreviousSong = "Playing the previous song.".localized
    static let siriVoiceRestarting = "Restarting %@.".localized
    static let siriVoiceShuffleIsOn = "Shuffle is on.".localized
    static let siriVoiceShuffleIsOff = "Shuffle is off.".localized
    static let siriVoiceRepeatIsOn = "Repeat is on.".localized
    static let siriVoiceRepeating = "Repeating %@.".localized
    static let siriVoiceRepeatIsOff = "Repeat is off.".localized
    static let siriVoiceIsnTInYourLikedSongs = "%@ isn't in your Liked Songs.".localized
    static let siriVoiceNowPlayingBy = "Now playing %@ by %@.".localized
    static let siriVoiceByIsPaused = "%@ by %@ is paused.".localized
    static let siriVoiceSetSleepTimer = "Set Sleep Timer".localized
    static let siriVoiceStopsTheMusicInCosmosAfter = "Stops the music in Cosmos after the time you choose.".localized
    static let siriVoiceDuration = "Duration".localized
    static let siriVoiceForHowLong = "For how long?".localized
    static let siriVoiceStopTheMusicInDuration = "Stop the music in ${duration}".localized
    static let siriVoiceCosmosWillStopPlayingInLld = "Cosmos will stop playing in %lld minutes.".localized
    static let siriVoiceSleepTimer = "Sleep Timer".localized
    static let siriVoiceSleepTimerDuration = "Sleep Timer Duration".localized
    static let siriVoice5Minutes = "5 minutes".localized
    static let siriVoiceFiveMinutes = "five minutes".localized
    static let siriVoice10Minutes = "10 minutes".localized
    static let siriVoiceTenMinutes = "ten minutes".localized
    static let siriVoice15Minutes = "15 minutes".localized
    static let siriVoiceFifteenMinutes = "fifteen minutes".localized
    static let siriVoiceAQuarterOfAnHour = "a quarter of an hour".localized
    static let siriVoice20Minutes = "20 minutes".localized
    static let siriVoiceTwentyMinutes = "twenty minutes".localized
    static let siriVoice30Minutes = "30 minutes".localized
    static let siriVoiceThirtyMinutes = "thirty minutes".localized
    static let siriVoiceHalfAnHour = "half an hour".localized
    static let siriVoice45Minutes = "45 minutes".localized
    static let siriVoiceFortyFiveMinutes = "forty-five minutes".localized
    static let siriVoiceThreeQuartersOfAnHour = "three quarters of an hour".localized
    static let siriVoice1Hour = "1 hour".localized
    static let siriVoiceAnHour = "an hour".localized
    static let siriVoiceOneHour = "one hour".localized
    static let siriVoice60Minutes = "60 minutes".localized
    static let siriVoice90Minutes = "90 minutes".localized
    static let siriVoiceAnHourAndAHalf = "an hour and a half".localized
    static let siriVoiceOneAndAHalfHours = "one and a half hours".localized
    static let siriVoice2Hours = "2 hours".localized
    static let siriVoiceTwoHours = "two hours".localized
    static let siriVoice120Minutes = "120 minutes".localized
    static let siriVoiceQueueSong = "Queue Song".localized
    static let siriVoicePlaysASongYouNameNext = "Plays a song you name next, or adds it to the end of the queue.".localized
    static let siriVoicePosition = "Position".localized
    static let siriVoiceQueuePosition = "Queue Position".localized
    static let siriVoiceNext = "next".localized
    static let siriVoiceAfterThisSong = "after this song".localized
    static let siriVoiceLater = "later".localized
    static let siriVoiceAtTheEndOfTheQueue = "at the end of the queue".localized
    static let siriVoicePositionSongname = "${position}: ${songName}".localized
    static let siriVoiceWillPlayNext = "%@ will play next.".localized
    static let siriVoiceAddedToTheQueue = "Added %@ to the queue.".localized
    static let siriVoiceCreatePlaylist = "Create Playlist".localized
    static let siriVoiceCreatesAPlaylistInCosmosOptionally = "Creates a playlist in Cosmos, optionally starting with the song playing now.".localized
    static let siriVoiceName = "Name".localized
    static let siriVoiceWhatShouldThePlaylistBeCalled = "What should the playlist be called?".localized
    static let siriVoiceAddTheCurrentSong = "Add the current song".localized
    static let siriVoiceCreateThePlaylistName = "Create the playlist ${name}".localized
    static let siriVoiceCreatedWith = "Created %@ with %@.".localized
    static let siriVoiceCreatedThePlaylist = "Created the playlist %@.".localized
    static let siriVoiceSearchAndPlay = "Search and Play".localized
    static let siriVoicePlaysThePlaylistMixArtistAlbum = "Plays the playlist, mix, artist, album or song that best matches what you say.".localized
    static let siriVoiceWhatDoYouWantToHear = "What do you want to hear?".localized
    static let siriVoicePlayQuery = "Play ${query}".localized
    static let siriVoiceOpenCosmosScreen = "Open Cosmos Screen".localized
    static let siriVoiceOpensCosmosOnHomeLibrarySearch = "Opens Cosmos on Home, Library, Search, Liked Songs, Playlists, Artists, Albums, Songs or the player.".localized
    static let siriVoiceScreen = "Screen".localized
    static let siriVoiceOpenScreen = "Open ${screen}".localized
    static let siriVoiceHome = "Home".localized
    static let siriVoiceMyLibrary = "my library".localized
    static let siriVoiceSearch = "Search".localized
    static let siriVoiceLikedSongs = "Liked Songs".localized
    static let siriVoiceFavorites = "favorites".localized
    static let siriVoicePlaylists = "Playlists".localized
    static let siriVoiceArtists = "Artists".localized
    static let siriVoiceAlbums = "Albums".localized
    static let siriVoiceSongs = "Songs".localized
    static let siriVoiceAllSongs = "all songs".localized
    static let siriVoiceNowPlaying = "Now Playing".localized
    static let siriVoiceThePlayer = "the player".localized
    static let siriVoiceShuffleMusic = "Shuffle Music".localized
    static let siriVoiceShufflesYourWholeCosmosLibraryOr = "Shuffles your whole Cosmos library, or one artist.".localized
    static let siriVoiceArtist = "Artist".localized
    static let siriVoiceShuffleArtist = "Shuffle ${artist}".localized
    static let siriVoiceShuffling = "Shuffling %@.".localized
    static let siriVoiceShufflingYourLibrary = "Shuffling your library.".localized
    static let siriVoiceAddCurrentSongToPlaylist = "Add Current Song to Playlist".localized
    static let siriVoiceAddsTheSongPlayingInCosmos = "Adds the song playing in Cosmos to one of your playlists.".localized
    static let siriVoiceAddTheCurrentSongToPlaylist = "Add the current song to ${playlist}".localized
    static let siriVoiceIsAlreadyIn = "%@ is already in %@.".localized
    static let siriVoiceSongMix = "Song Mix".localized
    static let inTheCar = "mix_in_the_car".localized
    static let onHeadphones = "mix_on_headphones".localized
    static let bluetoothSessions = "mix_bluetooth_sessions".localized
    static let outLoud = "mix_out_loud".localized
    static let onAirPlay = "mix_on_airplay".localized
    static let weekendMornings = "mix_weekend_mornings".localized
    static let weekendAfternoons = "mix_weekend_afternoons".localized
    static let weekendEvenings = "mix_weekend_evenings".localized
    static let weekendNights = "mix_weekend_nights".localized
    static let mixContextDescription = "mix_context_desc".localized
    static let mixWeekendDescription = "mix_weekend_desc".localized
    static let songMix = "song_mix".localized
    static let siri = "siri".localized
    static let siriAllowed = "siri_allowed".localized
    static let siriNotAllowed = "siri_not_allowed".localized
    static let siriAllow = "siri_allow".localized
    static let siriOpenSettings = "siri_open_settings".localized
    static let siriDescription = "siri_desc".localized
    static let playerBackground = "player_background".localized
    static let playerBackgroundArtwork = "player_bg_artwork".localized
    static let playerBackgroundBlend = "player_bg_blend".localized
    static let playerBackgroundTheme = "player_bg_theme".localized
    static let playerBackgroundBlurredCover = "player_bg_blur".localized
    static let playerBackgroundDescription = "player_bg_desc".localized
    static let lyricsAdjustTiming = "lyrics_adjust_timing".localized
    static let lyricsTimingTitle = "lyrics_timing_title".localized
    static let lyricsTimingEarlier = "lyrics_timing_earlier".localized
    static let lyricsTimingLater = "lyrics_timing_later".localized
    static let lyricsTimingEarlierByFormat = "lyrics_timing_earlier_by".localized
    static let lyricsTimingLaterByFormat = "lyrics_timing_later_by".localized
    static let lyricsTimingTapLine = "lyrics_timing_tap_line".localized
    static let lyricsTimingTapLineHint = "lyrics_timing_tap_line_hint".localized
    static let lyricsTimingReset = "lyrics_timing_reset".localized
    static let lyricsTimingInSync = "lyrics_timing_in_sync".localized
    static let lyricsTimingValueEarlierFormat = "lyrics_timing_value_earlier".localized
    static let lyricsTimingValueLaterFormat = "lyrics_timing_value_later".localized
    static let forgottenFavoritesDescription = "forgotten_favorites_desc".localized
    static let longTimeNoHear = "long_time_no_hear".localized
    static let longTimeNoHearDescription = "long_time_no_hear_desc".localized
    static let unfinishedAlbums = "unfinished_albums".localized
    static let unfinishedAlbumsDescription = "unfinished_albums_desc".localized
    static let deepCutsDescription = "deep_cuts_desc".localized
    static let firstLoves = "first_loves".localized
    static let firstLovesDescription = "first_loves_desc".localized
    static let decadeLabelFormat = "decade_label_format".localized
    static let decadeMixDescription = "decade_mix_desc".localized
    static let oldGemsDescription = "old_gems_desc".localized
    static let themeColor = "theme_color".localized
    static let themeColorDescription = "theme_color_desc".localized
    static let libraryItems = "library_items".localized
    static let libraryItemsDescription = "library_items_desc".localized
    static let listeningHistory = "listening_history".localized
    static let clearListeningHistory = "clear_listening_history".localized
    static let listeningHistoryDescription = "listening_history_desc".localized
    static let clearListeningHistoryMessage = "clear_listening_history_msg".localized
    static let haloStyle = "halo_style".localized
    static let haloSilk = "halo_silk".localized
    static let haloAurora = "halo_aurora".localized
    static let haloLines = "halo_lines".localized
    static let haloClassic = "halo_classic".localized
    static let haloGlow = "halo_glow".localized
    static let haloNone = "halo_none".localized
    static let haloMotion = "halo_motion".localized
    static let haloStyleDescription = "halo_style_desc".localized
    static let libraryTab = "library_tab".localized
    static let rediscoverYearFormat = "rediscover_year_format".localized
    static let forgottenFavorites = "forgotten_favorites".localized
    static let oldGems = "old_gems".localized
    static let youRecentlyPlayed = "you_recently_played".localized
    static let mixHabitDescription = "mix_habit_desc".localized
    static let mixTimeDescription = "mix_time_desc".localized
    static let mixPairFormat = "mix_pair_format".localized
    static let yourMornings = "your_mornings".localized
    static let yourAfternoons = "your_afternoons".localized
    static let yourEvenings = "your_evenings".localized
    static let yourNights = "your_nights".localized
    static let madeForYou = "made_for_you".localized
    static let onRepeat = "on_repeat".localized
    static let favoritesMix = "favorites_mix".localized
    static let deepCuts = "deep_cuts".localized
    static let hiResMix = "hires_mix".localized
    static let freshAdditions = "fresh_additions".localized
    static let decadeMixFormat = "decade_mix_format".localized
    static let longListens = "long_listens".localized
    static let yourMonthFormat = "your_month_format".localized
    static let addedInFormat = "added_in_format".localized
    static let thisTimeLastYear = "this_time_last_year".localized
    static let mixOnRepeatDescription = "mix_on_repeat_desc".localized
    static let mixFavoritesDescription = "mix_favorites_desc".localized
    static let mixDeepCutsDescription = "mix_deep_cuts_desc".localized
    static let mixHiResDescription = "mix_hires_desc".localized
    static let mixFreshDescription = "mix_fresh_desc".localized
    static let mixDecadeDescription = "mix_decade_desc".localized
    static let mixLongDescription = "mix_long_desc".localized
    static let mixArtistDescription = "mix_artist_desc".localized
    static let mixMomentDescription = "mix_moment_desc".localized
    static let mixAddedDescription = "mix_added_desc".localized
    static let startListening = "start_listening".localized
    static let yourMixes = "your_mixes".localized
    static let mixFormat = "mix_format".localized
    static let rediscover = "rediscover".localized
    static let yourArtists = "your_artists".localized
    static let recentSearches = "recent_searches".localized
    static let clear = "clear".localized
    static let gridView = "grid_view".localized
    static let listView = "list_view".localized
    static let recents = "recents".localized
    static let playAll = "play_all".localized
    static let continueListening = "continue_listening".localized
    static let home = "home".localized
    static let shuffleAll = "shuffle_all".localized
    static let recentlyPlayed = "recently_played".localized
    static let welcomeTitle = "welcome_title".localized
    static let welcomeMessage = "welcome_message".localized
    static let madeByYou = "made_by_you".localized
    static let fromYourLibrary = "from_your_library".localized
    static let on = "toggle_on".localized
    static let off = "toggle_off".localized
    static let sortBy = "sort_by".localized
    static let recentlyAdded = "recently_added".localized
    static let syncLibrary = "sync_library".localized
    static let nowPlaying = "now_playing".localized
    static let moreOptions = "more_options".localized
    static let removeFromPlaylist = "remove_from_playlist".localized
    static let showAlbum = "show_album".localized
    static let seeAll = "see_all".localized
    static let openNowPlaying = "open_now_playing".localized
    static let previousTrack = "previous_track".localized
    static let nextTrack = "next_track".localized
    static let pause = "pause".localized
    static let upNext = "up_next".localized
    static let playingNext = "playing_next".localized
    static let volume = "volume".localized
    static let audioOutput = "audio_output".localized
    static let repeatMode = "repeat".localized
    static let newPlaylist = "new_playlist".localized
    static let closePlayer = "close_player".localized
    static let artwork = "artwork".localized
    static let close = "close".localized
    static let lyricsCopy = "lyrics_copy".localized
    static let lyricsMoreActions = "lyrics_more_actions".localized
    static let lyricsSeekHint = "lyrics_seek_hint".localized
    static let lyricsBackToCurrent = "lyrics_back_to_current".localized
    static let lyricsInstrumentalBreak = "lyrics_instrumental_break".localized
    static let lyricsInstrumental = "lyrics_instrumental".localized
    static let lyricsInstrumentalMessage = "lyrics_instrumental_message".localized
    static let lyricsUnavailable = "lyrics_unavailable".localized
    static let lyricsUnavailableMessage = "lyrics_unavailable_message".localized
    static let lyricsLoading = "lyrics_loading".localized
    static let lyricsLoadingMessage = "lyrics_loading_message".localized
    static let lyricsSearchAgain = "lyrics_search_again".localized
    static let lyricsChooseVersion = "lyrics_choose_version".localized
    static let lyricsSynced = "lyrics_synced".localized

    // MARK: - Bulk Selection
    static let select = "select".localized
    static let selectAll = "select_all".localized
    static let bulkActions = "bulk_actions".localized
    static let addToLiked = "add_to_liked".localized
    static let removeFromLiked = "remove_from_liked".localized
    static let deleteFiles = "delete_files".localized
    static let deleteFilesConfirmation = "delete_files_confirmation".localized

    static func selectedCount(_ count: Int) -> String {
        "selected_count_plural".pluralized(count)
    }

    static func deleteFilesConfirmationMessage(_ count: Int) -> String {
        "delete_files_confirmation_message".pluralized(count)
    }
}
