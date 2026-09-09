//
//  PlaybackRouter.swift
//  Cosmos Music Player
//
//  Container inspection for formats whose extension does not name the codec.
//

import Foundation

/// NOTE: this class no longer routes anything.
///
/// It used to expose `determineStrategy(for:)`, a switch over the file
/// extension returning either an `AVAudioFile` or an `AudioDecoder`, plus a
/// `getFormatInfo(for:)` used for UI badges. Neither had a caller: `PlayerEngine`
/// dispatches on `SFBAudioEngineManager.canHandle(url:)` and opens the decoder
/// itself, and the views derive their own badges. Keeping a second, parallel
/// description of how playback routes was worse than useless - edits landed
/// there believing they changed playback, and it disagreed with the real
/// dispatch (it sent `.aac` to AVAudioFile, which `canHandle` also does, but
/// listed no fallbacks and knew nothing about CarPlay or DoP refusals).
///
/// What remains is the one thing that genuinely is shared: deciding whether an
/// `.m4a` holds Opus rather than AAC. That answer is used by the indexer, and
/// through `AudioParseError.unplayableFormat` it decides whether a row is
/// deleted - so it lives in exactly one place.
class PlaybackRouter {

    /// Whether an MP4/M4A file's sample description declares the Opus codec.
    ///
    /// This walks the ISO-BMFF box tree - moov → trak → mdia → minf → stbl →
    /// stsd - and reads the four-character format code of each sample entry.
    /// It is deliberately not a byte search. Scanning the file's first megabyte
    /// for "Opus" (or for the "dOps" configuration box) matches roughly one
    /// ordinary AAC file in a few thousand purely by chance - artwork and
    /// padding are effectively random bytes - and a false positive here is
    /// destructive rather than cosmetic: the indexer refuses the file as
    /// unplayable and `deleteTrack` removes its row along with its favourites
    /// and playlist entries, on every scan, with no way for the user to get it
    /// back. Anything this function cannot parse with certainty answers false,
    /// which is the safe direction: the file is simply indexed as AAC.
    static func isOpusInM4A(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        guard let fileLength = try? handle.seekToEnd(), fileLength > 8 else { return false }
        return sampleEntryFormats(in: handle, fileLength: fileLength).contains("Opus")
    }

    // MARK: - ISO base media file format

    /// One box's type and the extent of its payload.
    private struct BoxHeader {
        let type: String
        let payloadOffset: UInt64
        let payloadEnd: UInt64
    }

    /// Bounds the walk so a corrupt or hostile file cannot spin here. Real
    /// files have a handful of boxes per level.
    private static let maxBoxesPerLevel = 1024

    private static func readBoxHeader(
        _ handle: FileHandle,
        at offset: UInt64,
        limit: UInt64
    ) -> BoxHeader? {
        guard offset + 8 <= limit,
              (try? handle.seek(toOffset: offset)) != nil,
              let header = try? handle.read(upToCount: 8),
              header.count == 8 else {
            return nil
        }

        let base = header.startIndex
        var size = UInt64(bigEndian32(header, at: base))
        let type = String(decoding: header[(base + 4)..<(base + 8)], as: UTF8.self)
        var payloadOffset = offset + 8

        switch size {
        case 1:
            // 64-bit largesize follows the header; the read above left the
            // file position exactly there.
            guard payloadOffset + 8 <= limit,
                  let extended = try? handle.read(upToCount: 8),
                  extended.count == 8 else {
                return nil
            }
            size = bigEndian64(extended, at: extended.startIndex)
            payloadOffset += 8
            guard size >= 16 else { return nil }
        case 0:
            // Extends to the end of its container.
            size = limit - offset
        default:
            guard size >= 8 else { return nil }
        }

        // `largesize` is controlled by the file. Check it with subtraction
        // before adding: `offset + UInt64.max` traps in Swift instead of
        // reaching the bounds check below. The entry guard proves
        // `offset <= limit`, so this subtraction is itself safe.
        guard size <= limit - offset else { return nil }
        let end = offset + size
        guard end <= limit, payloadOffset <= end else { return nil }
        return BoxHeader(type: type, payloadOffset: payloadOffset, payloadEnd: end)
    }

    /// Visits each child box between `start` and `end`.
    private static func forEachBox(
        in handle: FileHandle,
        from start: UInt64,
        to end: UInt64,
        visit: (BoxHeader) -> Void
    ) {
        var offset = start
        var visited = 0

        while offset + 8 <= end, visited < maxBoxesPerLevel {
            guard let box = readBoxHeader(handle, at: offset, limit: end) else { return }
            visit(box)
            guard box.payloadEnd > offset else { return }
            offset = box.payloadEnd
            visited += 1
        }
    }

    private static func findBox(
        _ type: String,
        in handle: FileHandle,
        from start: UInt64,
        to end: UInt64
    ) -> BoxHeader? {
        var found: BoxHeader?
        forEachBox(in: handle, from: start, to: end) { box in
            if found == nil, box.type == type { found = box }
        }
        return found
    }

    /// Follows a chain of single-child container boxes.
    private static func descend(
        _ path: [String],
        in handle: FileHandle,
        from parent: BoxHeader
    ) -> BoxHeader? {
        var current = parent
        for type in path {
            guard let next = findBox(
                type,
                in: handle,
                from: current.payloadOffset,
                to: current.payloadEnd
            ) else {
                return nil
            }
            current = next
        }
        return current
    }

    /// The four-character format codes of every track's sample entries.
    private static func sampleEntryFormats(
        in handle: FileHandle,
        fileLength: UInt64
    ) -> Set<String> {
        var formats: Set<String> = []
        guard let moov = findBox("moov", in: handle, from: 0, to: fileLength) else {
            return formats
        }

        forEachBox(in: handle, from: moov.payloadOffset, to: moov.payloadEnd) { trak in
            guard trak.type == "trak",
                  let stsd = descend(["mdia", "minf", "stbl", "stsd"], in: handle, from: trak) else {
                return
            }

            // stsd is a FullBox: one version byte, three flag bytes, then a
            // four-byte entry count, then the sample entries themselves.
            let entriesStart = stsd.payloadOffset + 8
            guard entriesStart <= stsd.payloadEnd else { return }

            forEachBox(in: handle, from: entriesStart, to: stsd.payloadEnd) { entry in
                formats.insert(entry.type)
            }
        }

        return formats
    }

    private static func bigEndian32(_ data: Data, at index: Data.Index) -> UInt32 {
        (UInt32(data[index]) << 24)
            | (UInt32(data[index + 1]) << 16)
            | (UInt32(data[index + 2]) << 8)
            | UInt32(data[index + 3])
    }

    private static func bigEndian64(_ data: Data, at index: Data.Index) -> UInt64 {
        (UInt64(bigEndian32(data, at: index)) << 32)
            | UInt64(bigEndian32(data, at: index + 4))
    }
}
