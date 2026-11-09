//
//  PlaylistM3U.swift
//  Cosmos Music Player
//
//  Reading and writing M3U/M3U8 playlists, and finding each entry's song in
//  the library. Playlists arrive from other computers - foobar2000, Winamp,
//  VLC, MusicBee, iTunes - whose paths do not exist on this device, so the
//  entries are matched on what survives the trip: trailing folder and file
//  names, then the #EXTINF artist, title and length.
//
//  Foundation only, on purpose: this is the part worth testing against real
//  playlists, and it compiles on its own (`swiftc PlaylistM3U.swift tests.swift`)
//  to do so. The database and UI glue lives in PlaylistImport.swift.
//

import Foundation

// MARK: - Parsed playlist

/// One song line of a playlist, with what the `#EXTINF` before it said.
struct M3UEntry: Sendable, Equatable {
    /// Where the entry points, as written (trimmed).
    let location: String
    /// The folder and file names of the location, outermost first, with both
    /// separators understood and drive letters, ".", ".." and empty parts
    /// dropped. Empty for a remote URL.
    let components: [String]
    /// A path this device could open as is - a POSIX path, or a relative one
    /// to resolve against the playlist's own folder. Nil for Windows and UNC
    /// paths, which can only be matched by their trailing names.
    let localPath: String?
    let isRelative: Bool
    /// http(s) and other network locations: never in the library.
    let isRemote: Bool
    /// Nil when the playlist did not say, or said -1 / 0 (unknown).
    let durationSeconds: Double?
    /// The `#EXTINF` text after the comma - usually "Artist - Title", but
    /// "Title - Artist" from iTunes and just "Title" from some tools.
    let info: String?
    /// `#EXTART:`, which a few writers use instead of putting the artist in
    /// the `#EXTINF` text.
    let infoArtist: String?

    var fileName: String? { components.last }

    /// What the import summary lists when the entry is not found: the
    /// `#EXTINF` text when there is one, else the file name without its
    /// extension, else the location itself (a URL).
    var displayName: String {
        if let info, !info.isEmpty {
            if let infoArtist, !infoArtist.isEmpty, !info.contains(" - ") {
                return "\(infoArtist) - \(info)"
            }
            return info
        }
        if let fileName { return M3UText.stem(of: fileName) }
        return location
    }
}

struct M3UPlaylist: Sendable {
    /// From `#PLAYLIST:`; nil when the file does not name itself.
    var name: String?
    var entries: [M3UEntry]
}

// MARK: - Parsing

enum M3UParser {
    static func parse(data: Data) -> M3UPlaylist {
        parse(text: decode(data))
    }

    /// The playlist's text, whatever its encoding. ".m3u8" promises UTF-8, but
    /// a plain ".m3u" from Windows is usually the ANSI code page - Windows-1252
    /// in western Europe - and the extension is often wrong either way, so the
    /// bytes decide: a BOM first, then strict UTF-8, then Windows-1252, then
    /// Latin-1, which accepts any byte and so always produces something.
    static func decode(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(3))
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            let body = data.dropFirst(3)
            return String(data: body, encoding: .utf8)
                ?? String(decoding: body, as: UTF8.self)
        }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE {
            return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? ""
        }
        if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF {
            return String(data: data.dropFirst(2), encoding: .utf16BigEndian) ?? ""
        }
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let ansi = String(data: data, encoding: .windowsCP1252) {
            return ansi
        }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    static func parse(text: String) -> M3UPlaylist {
        var name: String?
        var entries: [M3UEntry] = []
        // `#EXTINF` and `#EXTART` describe the next location line only.
        var pendingDuration: Double?
        var pendingInfo: String?
        var pendingArtist: String?

        // Character-wise: "\r\n" is a single Character that is a newline, so
        // CRLF, LF and lone CR files all split the same way.
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}\0"))
            if line.isEmpty { continue }

            if line.hasPrefix("#") {
                let upper = line.uppercased()
                if upper.hasPrefix("#EXTINF:") {
                    let parsed = parseInfo(String(line.dropFirst("#EXTINF:".count)))
                    pendingDuration = parsed.duration
                    pendingInfo = parsed.text
                } else if upper.hasPrefix("#PLAYLIST:") {
                    let value = line.dropFirst("#PLAYLIST:".count).trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty { name = value }
                } else if upper.hasPrefix("#EXTART:") {
                    let value = line.dropFirst("#EXTART:".count).trimmingCharacters(in: .whitespaces)
                    pendingArtist = value.isEmpty ? nil : value
                }
                // Everything else - #EXTM3U, #EXTALB, #EXTGRP, plain comments -
                // carries nothing the match uses.
                continue
            }

            let location = parseLocation(line)
            entries.append(M3UEntry(
                location: line,
                components: location.components,
                localPath: location.localPath,
                isRelative: location.isRelative,
                isRemote: location.isRemote,
                durationSeconds: pendingDuration,
                info: pendingInfo,
                infoArtist: pendingArtist
            ))
            pendingDuration = nil
            pendingInfo = nil
            pendingArtist = nil
        }

        return M3UPlaylist(name: name, entries: entries)
    }

    /// The part of an `#EXTINF:` line after the colon: a length in seconds,
    /// optional `key="value"` attributes (IPTV-style lists, some players), and
    /// the display text after the first comma that is not inside quotes.
    static func parseInfo(_ body: String) -> (duration: Double?, text: String?) {
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        let durationToken = trimmed.prefix { $0 != "," && $0 != " " && $0 != "\t" }
        let duration = Double(durationToken).flatMap { $0 > 0 && $0.isFinite ? $0 : nil }

        var insideQuotes = false
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let character = trimmed[index]
            if character == "\"" {
                insideQuotes.toggle()
            } else if character == ",", !insideQuotes {
                let text = trimmed[trimmed.index(after: index)...].trimmingCharacters(in: .whitespaces)
                return (duration, text.isEmpty ? nil : text)
            }
            index = trimmed.index(after: index)
        }
        return (duration, nil)
    }

    struct Location: Equatable {
        var components: [String]
        var localPath: String?
        var isRelative: Bool
        var isRemote: Bool
    }

    /// Understands `C:\Music\a.flac`, `\\server\share\a.flac`, `/Users/me/a.flac`,
    /// `..\Album\a.mp3`, `Album/a.mp3`, `file:///C:/Music/a%20b.flac` and
    /// `http://...` - all of which turn up in real playlists.
    static func parseLocation(_ raw: String) -> Location {
        var path = raw
        if path.count >= 2, path.hasPrefix("\""), path.hasSuffix("\"") {
            path = String(path.dropFirst().dropLast())
        }

        let lowered = path.lowercased()
        if lowered.hasPrefix("file:") {
            // file:///C:/x, file:///Users/x, file://localhost/x, and the
            // file://server/share/x form Windows writes for UNC paths. Always
            // percent-encoded; a malformed escape is kept literally rather
            // than losing the entry.
            var rest = String(path.dropFirst("file:".count))
            if rest.hasPrefix("//") {
                rest = String(rest.dropFirst(2))
                if rest.lowercased().hasPrefix("localhost/") {
                    rest = String(rest.dropFirst("localhost".count))
                } else if !rest.hasPrefix("/") {
                    rest = "//" + rest
                }
            }
            path = rest.removingPercentEncoding ?? rest
        } else if let schemeEnd = path.range(of: "://"),
                  path[..<schemeEnd.lowerBound].count >= 2,
                  path[..<schemeEnd.lowerBound].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }) {
            // A network stream. ("C://" is not one: a scheme is 2+ characters.)
            return Location(components: [], localPath: nil, isRelative: false, isRemote: true)
        }

        let isWindowsDrive: Bool = {
            let characters = Array(path.prefix(3))
            return characters.count >= 2 && characters[0].isLetter && characters[1] == ":"
        }()
        let isUNC = path.hasPrefix("\\\\") || path.hasPrefix("//")
        let isPOSIXAbsolute = path.hasPrefix("/") && !isUNC
        // "/C:/Music" is what a file URL for a Windows path decodes to.
        let isDriveInURL: Bool = {
            let characters = Array(path.prefix(4))
            return characters.count >= 3 && characters[0] == "/" && characters[1].isLetter && characters[2] == ":"
        }()

        var components = path
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .map(String.init)
            .filter { $0 != "." && $0 != ".." }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let first = components.first, first.count == 2, first.hasSuffix(":"), first.first?.isLetter == true {
            components.removeFirst()
        }

        let isRelative = !isWindowsDrive && !isUNC && !isPOSIXAbsolute
        let localPath: String?
        if isRelative {
            localPath = path.replacingOccurrences(of: "\\", with: "/")
        } else if isPOSIXAbsolute && !isDriveInURL {
            localPath = path
        } else {
            localPath = nil
        }
        return Location(components: components, localPath: localPath, isRelative: isRelative, isRemote: false)
    }
}

// MARK: - Text normalisation

/// How names are compared. A playlist made on Windows names "Beyoncé" in
/// NFC, a file copied from a Mac may carry NFD, tags differ in case and
/// punctuation ("Don't" / "Dont", "AC/DC" / "AC-DC"), so every comparison
/// goes through the same folding.
enum M3UText {
    /// Case, diacritics and full/half width ignored; NFC.
    static func fold(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let apostrophes: Set<Unicode.Scalar> = ["'", "\u{2019}", "\u{2018}", "`", "\u{00B4}"]

    /// Folded words joined by single spaces: apostrophes dropped ("don't" ->
    /// "dont"), "&" read as "and", any other punctuation a word break.
    static func key(_ text: String) -> String {
        key(folded: fold(text))
    }

    /// Looked up once: `CharacterSet.alphanumerics` builds a new set on every
    /// access, and `key` asks it for every character of every library title.
    private static let wordCharacters = CharacterSet.alphanumerics

    /// `key` for text already through `fold`, which is the costly part.
    private static func key(folded text: String) -> String {
        var output = String.UnicodeScalarView()
        var pendingSpace = false
        func appendWord(_ word: String) {
            if pendingSpace && !output.isEmpty { output.append(" ") }
            output.append(contentsOf: word.unicodeScalars)
            pendingSpace = true
        }
        for scalar in text.unicodeScalars {
            if apostrophes.contains(scalar) { continue }
            if scalar == "&" {
                pendingSpace = true
                appendWord("and")
            } else if wordCharacters.contains(scalar) {
                if pendingSpace && !output.isEmpty { output.append(" ") }
                pendingSpace = false
                output.append(scalar)
            } else {
                pendingSpace = true
            }
        }
        return String(output)
    }

    /// A title with the parts that differ between releases of the same song
    /// removed: "(Remastered 2011)", "[Live]", "feat. X" and " - Radio Edit"
    /// tails. Only consulted when the full title found nothing.
    static func coreTitleKey(_ title: String) -> String {
        var text = fold(title)
        text = removingBrackets(text)
        if let dash = text.range(of: " - "), !text[..<dash.lowerBound].trimmingCharacters(in: .whitespaces).isEmpty {
            text = String(text[..<dash.lowerBound])
        }
        // Plain searches, not a regular expression: this runs for every song
        // in the library when the index is built.
        let padded = text + " "
        let credit = [" feat. ", " feat ", " ft. ", " ft ", " featuring "]
            .compactMap { padded.range(of: $0)?.lowerBound }
            .min()
        if let credit, credit > padded.startIndex {
            text = String(padded[..<credit])
        }
        let core = key(folded: text)
        return core.isEmpty ? key(title) : core
    }

    private static func removingBrackets(_ text: String) -> String {
        var output = ""
        var depth = 0
        for character in text {
            switch character {
            case "(", "[", "{":
                depth += 1
            case ")", "]", "}":
                depth = max(0, depth - 1)
            default:
                if depth == 0 { output.append(character) }
            }
        }
        return output
    }

    /// What separates several artists in one credit, folded to lower case.
    private static let artistSeparators = [
        " featuring ", " feat. ", " feat ", " ft. ", " ft ", " with ",
        " vs. ", " vs ", " & ", " and ", " x ", " + ", ", ", ";", " / ", "/", "\u{3001}"
    ]

    /// Every way the credit can be named for matching: the whole credit and
    /// each artist in it, without a leading "the". "Daft Punk feat. Pharrell
    /// Williams" -> {"daft punk feat pharrell williams", "daft punk",
    /// "pharrell williams"}. Two credits match when the sets meet, which also
    /// covers the library having split the artists differently.
    static func artistKeys(_ credit: String) -> Set<String> {
        let folded = fold(credit)
        var keys: Set<String> = []
        let whole = artistKey(folded)
        if !whole.isEmpty { keys.insert(whole) }

        var marked = " " + folded.split(whereSeparator: \.isWhitespace).joined(separator: " ") + " "
        for separator in artistSeparators {
            marked = marked.replacingOccurrences(of: separator, with: "\u{1}")
        }
        for part in marked.split(separator: "\u{1}") {
            let partKey = artistKey(String(part))
            if !partKey.isEmpty { keys.insert(partKey) }
        }
        return keys
    }

    private static func artistKey(_ text: String) -> String {
        let base = key(folded: text)
        if base.hasPrefix("the ") {
            return String(base.dropFirst(4))
        }
        return base
    }

    /// A file name without its extension. Only a short alphanumeric suffix
    /// counts as one, so "01. Intro" and "Vol. 2" keep their dots.
    static func stem(of fileName: String) -> String {
        guard let dot = fileName.lastIndex(of: "."), dot > fileName.startIndex else { return fileName }
        let suffix = fileName[fileName.index(after: dot)...]
        guard (1...5).contains(suffix.count), suffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            return fileName
        }
        return String(fileName[..<dot])
    }

    /// A file stem without the leading track number: "01 - Song", "01. Song",
    /// "1-03 Song" -> "Song".
    static func strippingTrackNumber(_ stem: String) -> String {
        guard let range = stem.range(of: #"^\s*\d{1,3}([-.]\d{1,3})?(\s*[-._)]\s*|\s+)"#, options: .regularExpression) else {
            return stem
        }
        let rest = stem[range.upperBound...]
        return rest.trimmingCharacters(in: .whitespaces).isEmpty ? stem : String(rest)
    }

    private static let genericFileWords: Set<String> = [
        "track", "piste", "titre", "pista", "spur", "audio", "audiotrack",
        "song", "untitled", "unknown", "sans", "titel", "cd", "disc", "disk"
    ]

    /// "01.mp3", "Track 01.flac", "Piste 3.wav": names that say nothing about
    /// the song, which a lone file-name match must not trust.
    static func isGenericFileStem(_ stem: String) -> Bool {
        let words = key(stem).split(separator: " ").filter { !$0.allSatisfy(\.isNumber) }
        return words.allSatisfy { genericFileWords.contains(String($0)) }
    }
}

// MARK: - Matching

/// What the matcher needs to know about a library song.
struct M3ULibraryTrack: Sendable {
    let stableId: String
    let path: String
    let title: String
    /// Every artist credited on the song.
    let artists: [String]
    let durationMs: Int?
}

enum M3UMatchMethod: String, Sendable {
    /// The entry's path, as written or relative to the playlist, is the song's.
    case exactPath
    /// The song's path ends with the entry's file and at least its folder.
    case pathSuffix
    /// The only song in the library with that file name.
    case fileName
    /// `#EXTINF` (or file name) artist and title, and the length when known.
    case artistTitle
    /// The only song with that title, with a length that agrees.
    case titleOnly
}

struct M3UMatch: Sendable, Equatable {
    let trackIndex: Int
    let method: M3UMatchMethod
}

/// The library arranged for looking entries up. Built once per import, off
/// the main thread; each lookup is then a few dictionary reads, so a
/// playlist of thousands of lines matches in well under a second.
///
/// Every rule refuses to guess: two equally good candidates leave the entry
/// unmatched. A missing song in an imported playlist is visible and easy to
/// add; a wrong one is not.
struct M3ULibraryIndex: Sendable {
    let tracks: [M3ULibraryTrack]
    /// Folded path components per track, outermost first.
    private let pathComponents: [[String]]
    private let byPath: [String: [Int]]
    private let byFileName: [String: [Int]]
    private let byStem: [String: [Int]]
    private let byTitle: [String: [Int]]
    private let byCoreTitle: [String: [Int]]
    private let artistKeySets: [Set<String>]
    private let genericArtistKeys: Set<String>

    /// Seconds two lengths may differ by and still be the same recording:
    /// players round differently, and a FLAC on the computer and an MP3 of it
    /// here differ by encoder padding.
    static let durationTolerance: Double = 3

    static let defaultGenericArtists = [
        "Unknown Artist", "Unknown", "Various Artists", "Various", "VA",
        "Artiste inconnu", "Artistes divers", "Неизвестный исполнитель", "未知艺术家", "<unknown>"
    ]

    init(tracks: [M3ULibraryTrack], genericArtistNames: [String] = M3ULibraryIndex.defaultGenericArtists) {
        self.tracks = tracks
        let generic = Set(genericArtistNames.flatMap { M3UText.artistKeys($0) })
        genericArtistKeys = generic

        var pathComponents: [[String]] = []
        var byPath: [String: [Int]] = [:]
        var byFileName: [String: [Int]] = [:]
        var byStem: [String: [Int]] = [:]
        var byTitle: [String: [Int]] = [:]
        var byCoreTitle: [String: [Int]] = [:]
        var artistKeySets: [Set<String>] = []
        pathComponents.reserveCapacity(tracks.count)
        artistKeySets.reserveCapacity(tracks.count)

        // Folders and artists repeat across thousands of songs (every path
        // starts with the same container folders), so each distinct name is
        // folded once.
        var foldedNames: [Substring: String] = [:]
        var artistKeysByName: [String: Set<String>] = [:]

        for (index, track) in tracks.enumerated() {
            let components = track.path.split(separator: "/").map { name in
                if let folded = foldedNames[name] { return folded }
                let folded = M3UText.fold(String(name))
                foldedNames[name] = folded
                return folded
            }
            pathComponents.append(components)
            byPath[Self.comparablePath(track.path), default: []].append(index)
            if let fileName = components.last {
                byFileName[fileName, default: []].append(index)
                byStem[M3UText.stem(of: fileName), default: []].append(index)
            }
            let title = M3UText.key(track.title)
            if !title.isEmpty { byTitle[title, default: []].append(index) }
            let core = M3UText.coreTitleKey(track.title)
            if !core.isEmpty { byCoreTitle[core, default: []].append(index) }
            // A song filed under "Unknown Artist" has no artist to agree or
            // disagree with; treating the placeholder as a name would make it
            // match every playlist entry that also lacks one.
            let keys = track.artists.reduce(into: Set<String>()) { keys, name in
                if let known = artistKeysByName[name] {
                    keys.formUnion(known)
                } else {
                    let computed = M3UText.artistKeys(name)
                    artistKeysByName[name] = computed
                    keys.formUnion(computed)
                }
            }
            artistKeySets.append(keys.subtracting(generic))
        }

        self.pathComponents = pathComponents
        self.byPath = byPath
        self.byFileName = byFileName
        self.byStem = byStem
        self.byTitle = byTitle
        self.byCoreTitle = byCoreTitle
        self.artistKeySets = artistKeySets
    }

    /// The one spelling of a path used for the exact comparison: `/private`
    /// dropped from the roots iOS reaches both ways, as
    /// DatabaseManager.canonicalPath does. Plain string work, unlike
    /// `standardizedFileURL`, which asks the filesystem - once per library
    /// song would be tens of thousands of lookups.
    static func comparablePath(_ path: String) -> String {
        var path = path
        for root in ["/private/var", "/private/tmp", "/private/etc"]
        where path == root || path.hasPrefix(root + "/") {
            path.removeFirst("/private".count)
            break
        }
        return path
    }

    /// - Parameter playlistDirectory: the folder the playlist file is in, for
    ///   relative entries that point at songs next to it.
    func match(_ entry: M3UEntry, playlistDirectory: String?) -> M3UMatch? {
        if entry.isRemote { return nil }
        return matchExactPath(entry, playlistDirectory: playlistDirectory)
            ?? matchPathSuffix(entry)
            ?? matchFileName(entry)
            ?? matchArtistTitle(entry)
            ?? matchTitleOnly(entry)
    }

    // (0) The entry already names a file on this device: a playlist exported
    // by Cosmos, or one saved inside a music folder copied to the phone.
    private func matchExactPath(_ entry: M3UEntry, playlistDirectory: String?) -> M3UMatch? {
        guard let localPath = entry.localPath else { return nil }
        let absolute: String
        if entry.isRelative {
            guard let playlistDirectory else { return nil }
            absolute = URL(fileURLWithPath: localPath, relativeTo: URL(fileURLWithPath: playlistDirectory, isDirectory: true))
                .standardized.path
        } else {
            absolute = URL(fileURLWithPath: localPath).standardized.path
        }
        guard let hits = byPath[Self.comparablePath(absolute)], hits.count == 1 else { return nil }
        return M3UMatch(trackIndex: hits[0], method: .exactPath)
    }

    // (1) The deepest run of trailing names - file, album folder, artist
    // folder... - shared with exactly one song. The file may match without
    // its extension: the computer has the FLAC, the phone an MP3 of it.
    private func matchPathSuffix(_ entry: M3UEntry) -> M3UMatch? {
        let entryComponents = entry.components.map(M3UText.fold)
        guard entryComponents.count >= 2, let fileName = entryComponents.last else { return nil }

        // (depth, same extension) per candidate; the best key wins.
        var scored: [(index: Int, depth: Int, sameExtension: Int)] = []
        func score(_ index: Int, sameExtension: Bool) {
            let components = pathComponents[index]
            var depth = 1
            while depth < entryComponents.count, depth < components.count,
                  entryComponents[entryComponents.count - 1 - depth] == components[components.count - 1 - depth] {
                depth += 1
            }
            scored.append((index, depth, sameExtension ? 1 : 0))
        }

        let exact = byFileName[fileName] ?? []
        for index in exact { score(index, sameExtension: true) }
        let exactSet = Set(exact)
        for index in byStem[M3UText.stem(of: fileName)] ?? [] where !exactSet.contains(index) {
            score(index, sameExtension: false)
        }

        guard let top = scored.max(by: { ($0.depth, $0.sameExtension) < ($1.depth, $1.sameExtension) }),
              top.depth >= 2 else { return nil }
        let best = scored
            .filter { $0.depth == top.depth && $0.sameExtension == top.sameExtension }
            .map(\.index)
        guard let index = single(best) else { return nil }
        return M3UMatch(trackIndex: index, method: .pathSuffix)
    }

    // (2) A file name only one song has, with or without the extension.
    // Generic names ("Track 01") are skipped, and a length that disagrees
    // vetoes the match: the folders already failed to corroborate it.
    private func matchFileName(_ entry: M3UEntry) -> M3UMatch? {
        guard let rawName = entry.fileName else { return nil }
        let fileName = M3UText.fold(rawName)
        let stem = M3UText.stem(of: fileName)
        guard !M3UText.isGenericFileStem(stem) else { return nil }

        let candidates: [Int]
        if let exact = byFileName[fileName], !exact.isEmpty {
            candidates = exact
        } else {
            candidates = byStem[stem] ?? []
        }
        guard let index = single(candidates), durationAgrees(entry, index) != false else { return nil }
        return M3UMatch(trackIndex: index, method: .fileName)
    }

    // (3) Artist and title, from `#EXTINF` or failing that the file name.
    private func matchArtistTitle(_ entry: M3UEntry) -> M3UMatch? {
        for guess in Self.artistTitleGuesses(for: entry) {
            guard let artist = guess.artist else { continue }
            let wanted = M3UText.artistKeys(artist).subtracting(genericArtistKeys)
            guard !wanted.isEmpty else { continue }

            let candidates = [byTitle[M3UText.key(guess.title)], byCoreTitle[M3UText.coreTitleKey(guess.title)]]
            for tier in candidates {
                let hits = (tier ?? []).filter { index in
                    !artistKeySets[index].isDisjoint(with: wanted) && durationAgrees(entry, index) != false
                }
                if let index = disambiguate(hits, for: entry) {
                    return M3UMatch(trackIndex: index, method: .artistTitle)
                }
            }
        }
        return nil
    }

    // (4) Only the title is known (or the artist is a placeholder, or the
    // library's song has none): accepted when exactly one song has the title
    // and both lengths are known and agree.
    private func matchTitleOnly(_ entry: M3UEntry) -> M3UMatch? {
        guard entry.durationSeconds != nil else { return nil }
        for guess in Self.artistTitleGuesses(for: entry) {
            guard let hits = byTitle[M3UText.key(guess.title)], hits.count == 1 else { continue }
            let index = hits[0]
            let artistIsUnknown = guess.artist.map { M3UText.artistKeys($0).isSubset(of: genericArtistKeys) } ?? true
            guard artistIsUnknown || artistKeySets[index].isEmpty else { continue }
            guard durationAgrees(entry, index) == true else { continue }
            return M3UMatch(trackIndex: index, method: .titleOnly)
        }
        return nil
    }

    /// One candidate, or the one among several sitting in the entry's own
    /// folder ("Album/03 Song.flac" when the library holds the song on two
    /// albums). Anything else is ambiguous.
    private func disambiguate(_ hits: [Int], for entry: M3UEntry) -> Int? {
        if let index = single(hits) { return index }
        guard hits.count > 1, entry.components.count >= 2 else { return nil }
        let folder = M3UText.fold(entry.components[entry.components.count - 2])
        let inFolder = hits.filter { index in
            let components = pathComponents[index]
            return components.count >= 2 && components[components.count - 2] == folder
        }
        return single(inFolder)
    }

    /// The candidate, when there is exactly one - or when the several are
    /// copies of one recording (the same file in Documents and in iCloud
    /// Drive, a FLAC and an MP3 of it): any of them plays the song the
    /// playlist meant, so that is not an ambiguity worth losing the entry to.
    private func single(_ candidates: [Int]) -> Int? {
        guard let first = candidates.first else { return nil }
        if candidates.count == 1 { return first }
        let title = M3UText.key(tracks[first].title)
        let artists = artistKeySets[first]
        let duration = tracks[first].durationMs
        let allCopies = candidates.dropFirst().allSatisfy { index in
            guard M3UText.key(tracks[index].title) == title, artistKeySets[index] == artists else { return false }
            switch (duration, tracks[index].durationMs) {
            case let (a?, b?): return abs(a - b) <= 1000
            case (nil, nil): return true
            default: return false
            }
        }
        return allCopies ? candidates.min() : nil
    }

    /// True or false when both lengths are known, nil when either is not.
    private func durationAgrees(_ entry: M3UEntry, _ index: Int) -> Bool? {
        guard let seconds = entry.durationSeconds, let ms = tracks[index].durationMs, ms > 0 else { return nil }
        return abs(seconds - Double(ms) / 1000) <= Self.durationTolerance
    }

    /// The readings of an entry's text worth trying, most likely first.
    /// "A - B" is "Artist - Title" for almost every writer but "Title -
    /// Artist" for iTunes, so both are tried; requiring the artist to match
    /// keeps the wrong reading from matching anything.
    static func artistTitleGuesses(for entry: M3UEntry) -> [(artist: String?, title: String)] {
        var guesses: [(artist: String?, title: String)] = []
        func addSplits(of text: String) {
            let normalized = text
                .replacingOccurrences(of: " \u{2013} ", with: " - ")
                .replacingOccurrences(of: " \u{2014} ", with: " - ")
            if let first = normalized.range(of: " - ") {
                let artist = normalized[..<first.lowerBound].trimmingCharacters(in: .whitespaces)
                let title = normalized[first.upperBound...].trimmingCharacters(in: .whitespaces)
                if !artist.isEmpty, !title.isEmpty { guesses.append((artist, title)) }
            }
            if let last = normalized.range(of: " - ", options: .backwards) {
                let title = normalized[..<last.lowerBound].trimmingCharacters(in: .whitespaces)
                let artist = normalized[last.upperBound...].trimmingCharacters(in: .whitespaces)
                if !artist.isEmpty, !title.isEmpty { guesses.append((artist, title)) }
            }
        }

        if let info = entry.info, !info.isEmpty {
            if let artist = entry.infoArtist, !artist.isEmpty {
                guesses.append((artist, info))
            }
            addSplits(of: info)
            guesses.append((nil, info))
        } else if let fileName = entry.fileName {
            let fullStem = M3UText.stem(of: fileName)
            let stem = M3UText.strippingTrackNumber(fullStem)
            if let artist = entry.infoArtist, !artist.isEmpty {
                guesses.append((artist, stem))
            }
            addSplits(of: stem)
            guesses.append((nil, stem))
            // "99 Luftballons" is a title, not track 99.
            if fullStem != stem { guesses.append((nil, fullStem)) }
        }
        return guesses
    }
}

// MARK: - Writing

enum M3UWriter {
    struct Item: Sendable {
        let durationSeconds: Int?
        let artist: String?
        let title: String
        let location: String
    }

    /// An extended M3U in UTF-8 (the ".m3u8" convention), which every player
    /// that reads playlists understands.
    static func m3u8(name: String, items: [Item]) -> String {
        var lines = ["#EXTM3U", "#PLAYLIST:\(singleLine(name))"]
        lines.reserveCapacity(items.count * 2 + 2)
        for item in items {
            let title = singleLine(item.title)
            let text: String
            if let artist = item.artist.map(singleLine), !artist.isEmpty {
                text = "\(artist) - \(title)"
            } else {
                text = title
            }
            lines.append("#EXTINF:\(item.durationSeconds ?? -1),\(text)")
            lines.append(singleLine(item.location))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A line break inside a tag would end the line and turn the rest of the
    /// title into a bogus location.
    private static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}
