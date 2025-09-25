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
}

/// Localization helper with commonly used strings
struct Localized {
    // MARK: - Playlist strings
    static let playlists = "playlists".localized
    static let noPlaylistsYet = "no_playlists_yet".localized
    static let createPlaylistsInstruction = "create_playlists_instruction".localized
    static let addToPlaylist = "add_to_playlist".localized
    static let createNewPlaylist = "create_new_playlist".localized
    static let createPlaylist = "create_playlist".localized
    static let playlistNamePlaceholder = "playlist_name_placeholder".localized
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
    
    // MARK: - General UI strings
    static let allSongs = "all_songs".localized
    static let likedSongs = "liked_songs".localized
    static let addSongs = "add_songs".localized
    static let importMusicFiles = "import_music_files".localized
    static let noSongsFound = "no_songs_found".localized
    static let yourMusicWillAppearHere = "your_music_will_appear_here".localized
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
    static let albums = "albums".localized
    static let search = "search".localized
    static let songs = "songs".localized
    static let processing = "processing".localized
    static let waiting = "waiting".localized
    
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
    static let forceDarkMode = "force_dark_mode".localized
    static let version = "version".localized
    static let appName = "app_name".localized
    static let cosmosMusicPlayer = "cosmos_music_player".localized
    static let githubRepository = "github_repository".localized
    static let useSimpleIcons = "use_simple_icons".localized
    static let overrideSystemAppearance = "override_system_appearance".localized
    static let backgroundColor = "background_color".localized
    static let chooseColorTheme = "choose_color_theme".localized
    
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
    
    // MARK: - Subtitles and descriptions
    static let yourFavorites = "your_favorites".localized
    static let yourPlaylists = "your_playlists".localized
    static let browseByArtist = "browse_by_artist".localized
    static let browseByAlbum = "browse_by_album".localized
    static let unknownAlbum = "unknown_album".localized
    
    // MARK: - Dynamic strings with parameters
    static func songsCount(_ count: Int) -> String {
        if count == 1 {
            return "songs_count_singular".localized(with: count)
        } else {
            return "songs_count_plural".localized(with: count)
        }
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
        return "found_tracks".localized(with: count)
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
        return "songs_count".localized(with: count)
    }

    // MARK: - Equalizer strings
    static let equalizer = "equalizer".localized
    static let graphicEqualizer = "graphic_equalizer".localized
    static let enableEqualizer = "enable_equalizer".localized
    static let enableDisableEqDescription = "enable_disable_eq_description".localized
    static let importedPresets = "imported_presets".localized
    static let noPresetsImported = "no_presets_imported".localized
    static let importGraphicEQDescription = "import_graphiceq_description".localized
    static let importedGraphicEQ = "imported_graphiceq".localized
    static let importGraphicEQFile = "import_graphiceq_file".localized
    static let globalSettings = "global_settings".localized
    static let globalGain = "global_gain".localized
    static let globalGainDescription = "global_gain_description".localized
    static let aboutGraphicEQFormat = "about_graphiceq_format".localized
    static let importGraphicEQFormatDescription = "import_graphiceq_format_description".localized
    static let frequencyGainPairDescription = "frequency_gain_pair_description".localized
    static let eqExport = "export".localized
    static let eqDelete = "delete".localized
    static let eqCancel = "cancel".localized
    static let eqDone = "done".localized

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
}
