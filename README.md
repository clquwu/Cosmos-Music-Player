# Cosmos Music Player 🎵

Cosmos Music Player is a high-quality music player that supports both iCloud Drive synchronization and local storage, giving users flexibility in how they manage their music. The app is built and designed for the iOS and Apple ecosystem.

A premium FLAC, MP3, and WAV music player for iOS with advanced features including dual storage options (iCloud/local), playlist management, artist information integration, and multi-language support.

## Features ✨

### 🎧 Audio Playback
- **High-Quality Lossless Support**: Native support for lossless FLAC and WAV audio files, plus MP3
- **Background Playback**: Continue listening while using other apps
- **Siri Integration**: Voice control for music playback in English and French
- **ReplayGain Support**: Automatic volume normalization for consistent listening experience
- **Embedded Artwork**: Displays album art from FLAC, MP3, and WAV metadata
- **Advanced Audio Engine**: Built with AVFoundation for optimal audio quality

### 📚 Music Library Management
- **Dual Storage Support**: Choose between iCloud Drive (syncs across devices) or local storage (device only)
- **iCloud Drive Integration**: Automatic sync of music files across devices when using iCloud storage
- **Local File Support**: Full support for music files stored locally in app's Documents folder
- **Smart Library Indexing**: Automatic detection and indexing of music files from both storage locations
- **Metadata Extraction**: Reads artist, album, title, and other metadata from FLAC, MP3, and WAV files
- **Offline First**: Works completely offline with local files, no internet required
- **File Organization**: Intelligent organization by artist and album regardless of storage location

### 🎵 Playlists
- **Custom Playlists**: Create and manage custom playlists
- **Smart Sorting**: Playlists sorted by most recent activity
- **Priority Display**: Shows playlists where songs are NOT present at the top when adding tracks
- **Cross-Device Sync**: Playlists synchronized via iCloud
- **Playlist Management**: Add, remove, and reorder tracks easily

### 👤 Artist Information
- **Dual API Integration**: Combines Discogs and Spotify APIs for comprehensive artist data
- **Artist Profiles**: Rich artist biographies and information
- **High-Quality Images**: Artist photos and album artwork
- **Alternative Sources**: "Wrong artist?" feature to switch between data sources
- **Smart Caching**: Efficient caching system for offline access

### 🎤 Siri Voice Control
- **Full Voice Integration**: Control music playback with Siri voice commands
- **Multi-Language Support**: Works in both English and French
- **Smart Recognition**: Fuzzy matching for playlist and song names with pronunciation variations
- **Complete Control**: Play favorites, playlists, specific songs, or all music via voice
- **Seamless Experience**: Proper queue management and playback state synchronization

#### Supported Siri Commands

**English Commands:**
- "Hey Siri, play my music on Cosmos"
- "Hey Siri, play my favorites on Cosmos"
- "Hey Siri, play [playlist name] on Cosmos"
- "Hey Siri, play [song name] on Cosmos"

**French Commands:**
- "Dis Siri, joue ma musique sur Cosmos"
- "Dis Siri, joue mes favoris sur Cosmos"
- "Dis Siri, joue la playlist [nom] sur Cosmos"
- "Dis Siri, joue [nom de chanson] sur Cosmos"

### 🌍 Internationalization
- **Multi-Language Support**: English and French translations
- **Localized Interface**: Complete UI translation system
- **Cultural Adaptation**: Proper pluralization and date formatting
- **Easy Extension**: Modular system for adding new languages

### ☁️ Storage Options
- **iCloud Drive**: Automatic synchronization of music, favorites, and playlists across devices
- **Local Storage**: Store music directly on device with no iCloud required
- **Flexible Choice**: Mix and match - use both storage types simultaneously
- **Offline Mode**: Full functionality without internet connection (especially with local files)
- **Smart Fallbacks**: Graceful handling of connectivity issues
- **Authentication Management**: Robust iCloud authentication when using cloud features

## Technical Architecture 🏗️

### Core Components

#### Services Layer
- **AppCoordinator**: Main app coordinator managing all services and initialization
- **PlayerEngine**: Advanced audio playback engine with background support
- **DatabaseManager**: SQLite/GRDB-based local database with migrations
- **StateManager**: iCloud state synchronization and local persistence
- **LibraryIndexer**: Automatic music file discovery and indexing

#### API Integration
- **DiscogsAPI**: Rich artist information from Discogs database
- **SpotifyAPI**: Alternative artist data with OAuth2 authentication
- **HybridMusicAPI**: Intelligent fallback system between services

#### Data Management
- **CloudDownloadManager**: Handles iCloud Drive file operations
- **FileCleanupManager**: Manages cleanup of iCloud files deleted from iCloud Drive
- **ArtworkManager**: Extracts and caches album artwork from both storage types

### Database Schema

```sql
-- Artists table
CREATE TABLE artist (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL COLLATE NOCASE
);

-- Albums table  
CREATE TABLE album (
    id INTEGER PRIMARY KEY,
    artist_id INTEGER REFERENCES artist(id) ON DELETE CASCADE,
    title TEXT NOT NULL COLLATE NOCASE,
    year INTEGER,
    album_artist TEXT COLLATE NOCASE
);

-- Tracks table
CREATE TABLE track (
    id INTEGER PRIMARY KEY,
    stable_id TEXT NOT NULL UNIQUE,
    album_id INTEGER REFERENCES album(id) ON DELETE SET NULL,
    artist_id INTEGER REFERENCES artist(id) ON DELETE SET NULL,
    title TEXT NOT NULL COLLATE NOCASE,
    track_no INTEGER,
    disc_no INTEGER,
    duration_ms INTEGER,
    sample_rate INTEGER,
    bit_depth INTEGER,
    channels INTEGER,
    path TEXT NOT NULL,
    file_size INTEGER,
    replaygain_track_gain REAL,
    replaygain_album_gain REAL,
    replaygain_track_peak REAL,
    replaygain_album_peak REAL,
    has_embedded_art INTEGER DEFAULT 0
);

-- Favorites table
CREATE TABLE favorite (
    track_stable_id TEXT PRIMARY KEY
);

-- Playlists table
CREATE TABLE playlist (
    id INTEGER PRIMARY KEY,
    slug TEXT NOT NULL UNIQUE,
    title TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    last_played_at INTEGER DEFAULT 0
);

-- Playlist items table
CREATE TABLE playlist_item (
    playlist_id INTEGER REFERENCES playlist(id) ON DELETE CASCADE,
    position INTEGER NOT NULL,
    track_stable_id TEXT NOT NULL,
    PRIMARY KEY (playlist_id, position)
);
```

## Setup Instructions 🚀

### Prerequisites
- **Xcode**: Latest stable version (Xcode 15+ recommended)
- **Swift**: 6+
- **iOS Deployment Target**: iOS 18.5+
- **Git**: For version control
- **Valid Apple Developer Account**: Required for iCloud capabilities
- **Device**: Physical iOS device (required for iCloud functionality testing)

### Installation Steps

1. **Clone the Repository**
   ```bash
   git clone <repository-url>
   cd Cosmos\ Music\ Player
   ```

2. **Configure Environment Variables**
   - Copy `.env.template` to `.env`
   - Add your API credentials:
   ```bash
   SPOTIFY_CLIENT_ID=your_spotify_client_id
   SPOTIFY_CLIENT_SECRET=your_spotify_client_secret
   DISCOGS_CONSUMER_KEY=your_discogs_consumer_key  
   DISCOGS_CONSUMER_SECRET=your_discogs_consumer_secret
   ```

3. **API Key Setup**
   
   **Spotify API Keys:**
   - Visit [Spotify Developer Dashboard](https://developer.spotify.com/dashboard/applications)
   - Create a new app
   - Copy Client ID and Client Secret to your `.env` file
   
   **Discogs API Keys:**
   - Visit [Discogs Developer Settings](https://www.discogs.com/settings/developers)
   - Create a new application
   - Copy Consumer Key and Consumer Secret to your `.env` file

4. **Configure iCloud**
   - Ensure your Apple Developer Account has iCloud capabilities
   - The app uses container: `iCloud.dev.clq.Cosmos-Music-Player`
   - Update the bundle identifier in project settings if needed

5. **Build and Run**
   - Open `Cosmos Music Player.xcodeproj` in Xcode
   - Select your development team
   - Build and run on device (required for iCloud functionality)

### First Launch Setup

1. **iCloud Sign-in** (Optional): Sign into iCloud only if you want cross-device sync
2. **Add Music**: Choose your preferred storage method:
   - **iCloud Drive**: Place music files in "iCloud Drive → Cosmos Music Player" folder
   - **Local Storage**: Place music files in "On My iPhone → Cosmos Music Player" folder
3. **Library Sync**: The app will automatically detect and index your music from both locations
4. **Enjoy**: Start creating playlists and exploring your music!

## Usage Guide 📱

### Adding Music

You have two storage options:

#### Option 1: iCloud Drive (Syncs Across Devices)
1. Open Files app on your iOS device
2. Navigate to "iCloud Drive" → "Cosmos Music Player"
3. Add your FLAC, MP3, or WAV music files to this folder
4. Files will sync to all your devices signed into the same iCloud account

#### Option 2: Local Storage (This Device Only)
1. Open Files app on your iOS device
2. Navigate to "On My iPhone" → "Cosmos Music Player"
3. Add your FLAC, MP3, or WAV music files to this folder
4. Files remain on this device only (no iCloud required)

**Mixed Storage**: You can use both methods simultaneously - the app will find and index music from both locations!

### Creating Playlists
1. Tap the "+" button in the Playlists section
2. Enter a playlist name
3. Add songs from your library
4. Playlists sync automatically across devices

### Using Artist Information
1. Navigate to any artist in your library
2. View rich artist information from Discogs/Spotify
3. Tap "Wrong artist?" to switch data sources
4. Artist data is cached for offline viewing

### Using Siri Voice Control
1. **Enable Siri**: Ensure Siri is enabled in your device settings
2. **Grant Permissions**: Allow Siri access to Cosmos Music Player when prompted
3. **Voice Commands**: Use any of the supported commands listed above
4. **Language Support**: Works with both English and French Siri
5. **Smart Matching**: Don't worry about exact pronunciation - the app uses fuzzy matching for names

### Language Settings
The app automatically uses your device's language setting. Currently supported:
- English (en)
- French (fr)

## Dependencies 📦

### Swift Packages
- **GRDB**: SQLite database management
- **Foundation**: Core system framework
- **AVFoundation**: Audio playback engine
- **SwiftUI**: Modern UI framework
- **Combine**: Reactive programming

### API Services
- **Spotify Web API**: Artist information and metadata
- **Discogs API**: Comprehensive music database
- **iCloud Drive API**: Cross-device synchronization

## File Structure 📂

```
Cosmos Music Player/
├── Services/           # Core business logic services
│   ├── AppCoordinator.swift
│   ├── PlayerEngine.swift
│   ├── DatabaseManager.swift
│   ├── StateManager.swift
│   ├── LibraryIndexer.swift
│   ├── SpotifyAPI.swift
│   ├── DiscogsAPI.swift
│   └── HybridMusicAPI.swift
├── Views/              # SwiftUI views
│   ├── Library/
│   ├── Artists/
│   ├── Albums/
│   ├── Playlists/
│   ├── Player/
│   └── Utility/
├── Models/             # Data models
│   ├── DatabaseModels.swift
│   ├── StateModels.swift
│   └── SettingsModels.swift
├── Helpers/            # Utility classes
│   ├── LocalizationHelper.swift
│   └── EnvironmentLoader.swift
└── Resources/          # Localization files
    ├── en.lproj/
    └── fr.lproj/
```

# Contributing 🤝

We welcome contributions to this project! Please follow these guidelines to help us maintain a high-quality codebase.

## Prerequisites

- **Xcode**: Latest stable version (Xcode 15+ recommended)
- **Swift**: 6+
- **iOS Deployment Target**: iOS 18.5+
- **Git**: For version control
- **Device**: Physical iOS device (required for iCloud functionality testing)

## Development Workflow

1. **Create a feature branch** from `main`:
   ```bash
   git checkout -b feature/your-feature-name
   ```

2. **Make your changes** following our coding standards

3. **Commit your changes**:
   ```bash
   git add .
   git commit -m "feat: add new feature description"
   ```

4. **Push to your fork** and create a Pull Request

## Coding Standards

### Swift Style Guide
- Follow [Swift API Design Guidelines](https://swift.org/documentation/api-design-guidelines/)
- Use SwiftLint for consistent formatting (run `swiftlint` before committing)
- Prefer `let` over `var` when possible
- Use meaningful variable and function names
- Add documentation comments for public APIs

### Code Organization
- Group related functionality using `// MARK: -` comments
- Keep files under 300 lines when possible
- Use extensions to organize code by functionality
- Follow MVC/MVVM architecture patterns

### Example:
```swift
// MARK: - View Lifecycle
override func viewDidLoad() {
    super.viewDidLoad()
    setupUI()
    configureBindings()
}

// MARK: - Private Methods
private func setupUI() {
    // Implementation
}
```

## Pull Request Guidelines

### Before Submitting
- [ ] Code is properly documented
- [ ] Screenshots/GIFs included for UI changes
- [ ] Tested on physical device with iCloud functionality
- [ ] Environment variables properly configured

### PR Description Template
```markdown
## Description
Brief description of changes

## Type of Change
- [ ] Bug fix
- [ ] New feature
- [ ] Breaking change
- [ ] Documentation update

## Testing
- [ ] Tested on iOS device
- [ ] iCloud sync functionality verified
- [ ] API integrations working

## Screenshots
(If applicable)
```

## Commit Message Format

Use conventional commits format:
```
type(scope): description

feat(auth): add biometric login support
fix(network): resolve timeout issues
docs(readme): update installation instructions
```

Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`

## Issue Reporting

When reporting issues, please include:
- iOS version and device model
- Xcode version
- Swift version
- Steps to reproduce
- Expected vs actual behavior
- Crash logs or error messages
- Screenshots if applicable
- iCloud account status

## Code Review Process

1. All PRs require at least one review
2. Address review feedback promptly
3. Keep PRs focused and reasonably sized
4. Respond to comments and update code as needed
5. Ensure all tests pass and functionality works on device

## Special Contributing Areas

### Internationalization
To add a new language:

1. Create a new `.lproj` folder in `Resources/`
2. Copy `en.lproj/Localizable.strings` as a template
3. Translate all strings to your target language
4. Update `LocalizationHelper.swift` if needed for locale-specific formatting
5. Test the UI with your new language

### API Integration
To add new music APIs:

1. Create a new service file in `Services/`
2. Implement the required protocols
3. Update `HybridMusicAPI.swift` to include the new service
4. Add appropriate error handling and caching
5. Update environment variable documentation

Thank you for contributing! 🚀

## Security & Privacy 🔒

- **Flexible Storage**: Music files stored either locally on device or in user's personal iCloud Drive
- **User Choice**: Complete control over where music files are stored (local vs cloud)
- **API Keys**: Securely loaded from environment variables
- **No Tracking**: No user data collection or tracking
- **Offline First**: Full functionality works without internet (especially with local storage)
- **Encrypted Sync**: iCloud synchronization uses Apple's end-to-end encryption
- **No External Servers**: Music files never leave your device/iCloud account

## Troubleshooting 🔧

### Common Issues

**Music not appearing:**
- For iCloud files: Check iCloud Drive is enabled and signed in
- For local files: Ensure files are in the local "Cosmos Music Player" folder
- Verify files are FLAC, MP3, or WAV format
- Try manual sync from the app
- Check both iCloud Drive and "On My iPhone" locations

**Artist information missing:**
- Check internet connection
- Verify API keys are correctly configured
- Try the "Wrong artist?" feature for alternative sources

**Playlist sync issues:**
- Ensure iCloud Drive has sufficient storage
- Check device is connected to internet
- Try signing out and back into iCloud

**Siri not working:**
- Ensure Siri is enabled in Settings → Siri & Search
- Grant Siri access to Cosmos Music Player when prompted
- Try saying "Cosmos" or "Cosmos Musique" (French) to help Siri recognize the app
- Restart the app to refresh Siri vocabulary
- Make sure you're connected to the internet for initial Siri setup

## License 📄

This project is licensed under [Your License] - see the LICENSE file for details.

## Environment Variables 🔧

To run this project, you will need to add the following environment variables to your `.env` file:

```bash
# Spotify API Keys (Required)
SPOTIFY_CLIENT_ID=your_spotify_client_id
SPOTIFY_CLIENT_SECRET=your_spotify_client_secret

# Discogs API Keys (Required)
DISCOGS_CONSUMER_KEY=your_discogs_consumer_key
DISCOGS_CONSUMER_SECRET=your_discogs_consumer_secret
```

### Getting API Keys

**Spotify API Keys:**
- Visit [Spotify Developer Dashboard](https://developer.spotify.com/dashboard/applications)
- Create a new app
- Copy Client ID and Client Secret to your `.env` file

**Discogs API Keys:**
- Visit [Discogs Developer Settings](https://www.discogs.com/settings/developers)
- Create a new application
- Copy Consumer Key and Consumer Secret to your `.env` file

## Appendix 📋

We use Spotify and Discogs to fetch artist details. We are not related to either of their services in any financial way - we just want to offer you the best experience possible.

The logo was created by **Zerrotic** (zerrotic on Discord).

## Authors 👥

- [@clquwu](https://github.com/clquwu) - Main Developer

## Contact 📧

To contact me:
- **Email**: raphaelboullaylefur@proton.me
- **Discord**: clarityhs

## Support 💬

For issues, questions, or feature requests:
- Create an issue in the repository
- Check the troubleshooting section above
- Ensure you have the latest version installed
- Contact via email or Discord for direct support

## License 📄

This project is licensed under GNU - see the LICENSE file for details.

---

**Enjoy your high-quality music experience with Cosmos Music Player!** 🎵✨
