//
//  ArtworkManager.swift
//  Cosmos Music Player
//
//  Manages album artwork extraction and caching
//

import Foundation
import UIKit
import AVFoundation
import CryptoKit

@MainActor
class ArtworkManager: ObservableObject {
    static let shared = ArtworkManager()

    // Memory cache for quick access
    private var memoryCache: [String: UIImage] = [:]

    // Persistent disk cache directory
    private let diskCacheURL: URL

    // Mapping file URL (maps track.stableId -> artwork hash)
    private let mappingFileURL: URL

    // In-memory mapping cache
    private var artworkMapping: [String: String] = [:]

    private init() {
        // Create artwork cache directory
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        diskCacheURL = documentsURL.appendingPathComponent("ArtworkCache", isDirectory: true)
        mappingFileURL = documentsURL.appendingPathComponent("ArtworkMapping.plist")

        // Create directory if needed
        try? FileManager.default.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)

        // Load mapping
        loadMapping()

        print("📁 ArtworkManager initialized - Disk cache: \(diskCacheURL.path)")
    }

    private func loadMapping() {
        guard FileManager.default.fileExists(atPath: mappingFileURL.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: mappingFileURL)
            if let mapping = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: String] {
                artworkMapping = mapping
                print("📊 Loaded artwork mapping: \(artworkMapping.count) entries")
            }
        } catch {
            print("⚠️ Failed to load artwork mapping: \(error)")
        }
    }

    private func saveMapping() {
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: artworkMapping, format: .xml, options: 0)
            try data.write(to: mappingFileURL, options: .atomic)
        } catch {
            print("⚠️ Failed to save artwork mapping: \(error)")
        }
    }

    func clearCache() {
        memoryCache.removeAll()
        print("🗑️ ArtworkManager memory cache cleared")
    }

    func clearDiskCache() {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: diskCacheURL, includingPropertiesForKeys: nil)
            for file in files {
                try FileManager.default.removeItem(at: file)
            }
            memoryCache.removeAll()
            artworkMapping.removeAll()
            saveMapping()
            print("🗑️ Cleared \(files.count) artwork files from disk cache")
        } catch {
            print("❌ Failed to clear disk cache: \(error)")
        }
    }

    func forceRefreshArtwork(for track: Track) async -> UIImage? {
        // Remove from memory cache and mapping to force re-extraction
        memoryCache.removeValue(forKey: track.stableId)

        // Note: We don't delete the actual artwork file as other tracks might use it
        // Just remove the mapping for this track
        artworkMapping.removeValue(forKey: track.stableId)
        saveMapping()

        print("🔄 Force refreshing artwork for: \(track.title)")
        return await getArtwork(for: track)
    }

    /// Pre-process and cache artwork during library indexing (background operation)
    func cacheArtwork(for track: Track) async {
        // Skip if already mapped (already has cached artwork)
        if artworkMapping[track.stableId] != nil {
            return
        }

        print("💾 Pre-caching artwork for: \(track.title)")

        // Extract artwork from audio file
        if let image = await extractArtwork(from: URL(fileURLWithPath: track.path)) {
            // Save to disk cache (will deduplicate automatically)
            await saveToDiskCache(image: image, stableId: track.stableId)
        }
    }

    func getArtwork(for track: Track) async -> UIImage? {
        // 1. Check memory cache first (fastest)
        if let cachedImage = memoryCache[track.stableId] {
            return cachedImage
        }

        // 2. Check disk cache (fast)
        if let diskImage = await loadFromDiskCache(stableId: track.stableId) {
            // Store in memory cache for next time
            memoryCache[track.stableId] = diskImage
            return diskImage
        }

        // 3. Extract from audio file and cache (slow - should be rare after indexing)
        if let image = await extractArtwork(from: URL(fileURLWithPath: track.path)) {
            // Store in both caches
            memoryCache[track.stableId] = image
            await saveToDiskCache(image: image, stableId: track.stableId)
            return image
        }

        return nil
    }

    // MARK: - Disk Cache Management

    private nonisolated func loadFromDiskCache(stableId: String) async -> UIImage? {
        // Get artwork hash from mapping
        guard let artworkHash = await getArtworkHash(for: stableId) else {
            return nil
        }

        let diskFile = diskCacheURL.appendingPathComponent("\(artworkHash).jpg")

        guard FileManager.default.fileExists(atPath: diskFile.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: diskFile)
            if let image = UIImage(data: data) {
                return image
            }
        } catch {
            print("❌ Failed to load artwork from disk: \(error)")
        }

        return nil
    }

    private func getArtworkHash(for stableId: String) async -> String? {
        return artworkMapping[stableId]
    }

    private nonisolated func saveToDiskCache(image: UIImage, stableId: String) async {
        // Compress to JPEG at 85% quality for faster loading and smaller size
        guard let imageData = image.jpegData(compressionQuality: 0.85) else {
            print("❌ Failed to compress artwork to JPEG")
            return
        }

        // Compute hash of artwork data to deduplicate
        let artworkHash = SHA256.hash(data: imageData)
        let hashString = artworkHash.compactMap { String(format: "%02x", $0) }.joined()

        let diskFile = diskCacheURL.appendingPathComponent("\(hashString).jpg")

        // Check if artwork already exists
        if FileManager.default.fileExists(atPath: diskFile.path) {
            // Artwork already cached, just update mapping
            await updateMapping(stableId: stableId, artworkHash: hashString)
            print("♻️ Reused existing artwork: \(hashString).jpg for track \(stableId)")
            return
        }

        // Save new artwork file
        do {
            try imageData.write(to: diskFile, options: .atomic)
            await updateMapping(stableId: stableId, artworkHash: hashString)
            print("💾 Saved artwork to disk cache: \(hashString).jpg (\(imageData.count / 1024) KB)")
        } catch {
            print("❌ Failed to save artwork to disk: \(error)")
        }
    }

    private func updateMapping(stableId: String, artworkHash: String) async {
        artworkMapping[stableId] = artworkHash
        saveMapping()
    }

    /// Clean up artwork files for tracks that no longer exist
    func cleanupOrphanedArtwork(validStableIds: Set<String>) async {
        // First, clean up mapping entries for deleted tracks
        var removedMappings = 0
        for stableId in artworkMapping.keys {
            if !validStableIds.contains(stableId) {
                artworkMapping.removeValue(forKey: stableId)
                removedMappings += 1
            }
        }

        if removedMappings > 0 {
            saveMapping()
            print("🗑️ Removed \(removedMappings) orphaned mapping entries")
        }

        // Build set of artwork hashes still in use
        let usedHashes = Set(artworkMapping.values)

        // Clean up artwork files that are no longer referenced
        do {
            let files = try FileManager.default.contentsOfDirectory(at: diskCacheURL, includingPropertiesForKeys: nil)
            var removedCount = 0

            for fileURL in files {
                let artworkHash = fileURL.deletingPathExtension().lastPathComponent
                if !usedHashes.contains(artworkHash) {
                    try FileManager.default.removeItem(at: fileURL)
                    removedCount += 1
                }
            }

            if removedCount > 0 {
                print("🗑️ Cleaned up \(removedCount) unused artwork files")
            }
        } catch {
            print("❌ Failed to cleanup orphaned artwork: \(error)")
        }
    }
    
    private nonisolated func extractArtwork(from url: URL) async -> UIImage? {
        let ext = url.pathExtension.lowercased()

        if ext == "flac" {
            return await extractFlacArtwork(from: url)
        } else if ext == "mp3" {
            return await extractMp3Artwork(from: url)
        } else if ext == "m4a" || ext == "mp4" || ext == "aac" {
            return await extractM4AArtwork(from: url)
        } else if ext == "dsf" || ext == "dff" {
            return await extractDSDArtwork(from: url)
        } else if ext == "opus" || ext == "ogg" {
            return await extractGenericArtwork(from: url)
        }

        return nil
    }
    
    private nonisolated func extractMp3Artwork(from url: URL) async -> UIImage? {
        return await withCheckedContinuation { continuation in
            Task {
                let asset = AVURLAsset(url: url)
                
                do {
                    let metadata = try await asset.load(.commonMetadata)
                    
                    for item in metadata {
                        if item.commonKey == .commonKeyArtwork {
                            do {
                                if let data = try await item.load(.dataValue),
                                   let image = UIImage(data: data) {
                                    continuation.resume(returning: image)
                                    return
                                }
                            } catch {
                                print("Failed to load artwork data: \(error)")
                            }
                        }
                    }
                    
                    continuation.resume(returning: nil)
                } catch {
                    print("Failed to load MP3 metadata: \(error)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }
    
    private nonisolated func extractFlacArtwork(from url: URL) async -> UIImage? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .background).async {
                do {
                    let data = try Data(contentsOf: url)
                    
                    if data.count < 42 {
                        continuation.resume(returning: nil)
                        return
                    }
                    
                    var offset = 4
                    
                    while offset < data.count {
                        let blockHeader = data[offset]
                        let isLast = (blockHeader & 0x80) != 0
                        let blockType = blockHeader & 0x7F
                        
                        offset += 1
                        
                        guard offset + 3 <= data.count else { break }
                        
                        let blockSize = Int(data[offset]) << 16 | Int(data[offset + 1]) << 8 | Int(data[offset + 2])
                        offset += 3
                        
                        if blockType == 6 { // PICTURE block
                            if let image = Self.parseFlacPictureBlock(data: data, offset: offset, size: blockSize) {
                                continuation.resume(returning: image)
                                return
                            }
                        }
                        
                        offset += blockSize
                        
                        if isLast { break }
                    }
                    
                    continuation.resume(returning: nil)
                    
                } catch {
                    print("Failed to extract FLAC artwork: \(error)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }
    
    private nonisolated static func parseFlacPictureBlock(data: Data, offset: Int, size: Int) -> UIImage? {
        var pos = offset
        
        // Skip picture type (4 bytes)
        pos += 4
        
        guard pos + 4 <= data.count else { return nil }
        
        // Get MIME type length
        let mimeLength = Int(data[pos]) << 24 | Int(data[pos + 1]) << 16 | Int(data[pos + 2]) << 8 | Int(data[pos + 3])
        pos += 4 + mimeLength
        
        guard pos + 4 <= data.count else { return nil }
        
        // Get description length
        let descLength = Int(data[pos]) << 24 | Int(data[pos + 1]) << 16 | Int(data[pos + 2]) << 8 | Int(data[pos + 3])
        pos += 4 + descLength
        
        // Skip width, height, color depth, indexed colors (16 bytes total)
        pos += 16
        
        guard pos + 4 <= data.count else { return nil }
        
        // Get picture data length
        let pictureLength = Int(data[pos]) << 24 | Int(data[pos + 1]) << 16 | Int(data[pos + 2]) << 8 | Int(data[pos + 3])
        pos += 4
        
        guard pos + pictureLength <= data.count else { return nil }
        
        // Extract picture data
        let pictureData = data.subdata(in: pos..<pos + pictureLength)
        return UIImage(data: pictureData)
    }

    // MARK: - M4A/AAC Artwork Extraction

    private nonisolated func extractM4AArtwork(from url: URL) async -> UIImage? {
        return await withCheckedContinuation { continuation in
            Task {
                do {
                    let asset = AVAsset(url: url)
                    let commonMetadata = asset.commonMetadata

                    for item in commonMetadata {
                        if item.commonKey == .commonKeyArtwork,
                           let data = item.dataValue,
                           let image = UIImage(data: data) {
                            print("🎨 Extracted M4A artwork: \(url.lastPathComponent)")
                            continuation.resume(returning: image)
                            return
                        }
                    }

                    print("⚠️ No artwork found in M4A file: \(url.lastPathComponent)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - DSD Artwork Extraction

    private nonisolated func extractDSDArtwork(from url: URL) async -> UIImage? {
        do {
            let data = try Data(contentsOf: url)

            // For DSF files, try ID3v2 APIC frame extraction first
            if url.pathExtension.lowercased() == "dsf" {
                if let artwork = extractDSFArtworkFromID3(data: data, filename: url.lastPathComponent) {
                    return artwork
                }
            }

            // Fallback to binary signature search for both DSF and DFF files
            print("⚠️ No ID3v2 artwork found, searching for binary signatures in: \(url.lastPathComponent)")

            // Image signatures to look for
            let jpegSignature = Data([0xFF, 0xD8, 0xFF])
            let pngSignature = Data([0x89, 0x50, 0x4E, 0x47])

            // Search for embedded images in DSD files
            let searchRange = 0..<min(data.count, 2097152) // Search first 2MB

            // Look for JPEG images
            if let jpegRange = data.range(of: jpegSignature, in: searchRange) {
                let startOffset = jpegRange.lowerBound

                // Look for JPEG end marker (FF D9)
                let jpegEndSignature = Data([0xFF, 0xD9])
                if let endRange = data.range(of: jpegEndSignature, in: startOffset..<min(data.count, startOffset + 1048576)) {
                    let endOffset = endRange.upperBound
                    let imageData = data.subdata(in: startOffset..<endOffset)

                    if let image = UIImage(data: imageData) {
                        print("🎨 Extracted JPEG artwork from DSD file (binary search): \(url.lastPathComponent)")
                        return image
                    }
                }
            }

            // Look for PNG images
            if let pngRange = data.range(of: pngSignature, in: searchRange) {
                let startOffset = pngRange.lowerBound

                // PNG files end with IEND chunk (49 45 4E 44)
                let pngEndSignature = Data([0x49, 0x45, 0x4E, 0x44])
                if let endRange = data.range(of: pngEndSignature, in: startOffset..<min(data.count, startOffset + 1048576)) {
                    let endOffset = endRange.upperBound + 4 // Include CRC after IEND
                    let imageData = data.subdata(in: startOffset..<min(endOffset, data.count))

                    if let image = UIImage(data: imageData) {
                        print("🎨 Extracted PNG artwork from DSD file (binary search): \(url.lastPathComponent)")
                        return image
                    }
                }
            }

            print("⚠️ No artwork found in DSD file: \(url.lastPathComponent)")
            return nil
        } catch {
            print("❌ DSD artwork extraction failed: \(error)")
            return nil
        }
    }

    // Extract artwork from DSF file using ID3v2 APIC frames
    private nonisolated func extractDSFArtworkFromID3(data: Data, filename: String) -> UIImage? {
        // Validate DSF signature: 'D', 'S', 'D', ' ' (includes 1 space)
        guard data.count >= 28,
              data[0] == 0x44, data[1] == 0x53, data[2] == 0x44, data[3] == 0x20 else {
            print("⚠️ Invalid DSF signature in: \(filename)")
            return nil
        }

        // Read metadata pointer from DSF header (little-endian at offset 20)
        let metadataPointer = readLittleEndianUInt64(from: data, offset: 20)

        guard metadataPointer > 0 && metadataPointer < data.count else {
            print("⚠️ No metadata pointer in DSF file: \(filename)")
            return nil
        }

        let metadataOffset = Int(metadataPointer)

        // Check for ID3v2 signature at metadata pointer
        guard data.count >= metadataOffset + 10,
              data[metadataOffset] == 0x49, // 'I'
              data[metadataOffset + 1] == 0x44, // 'D'
              data[metadataOffset + 2] == 0x33 else { // '3'
            print("⚠️ No ID3v2 tag found at metadata pointer in: \(filename)")
            return nil
        }

        print("🏷️ Found ID3v2 tag in DSF file: \(filename)")

        let id3Data = data.subdata(in: metadataOffset..<data.count)
        return extractArtworkFromID3v2(data: id3Data, filename: filename)
    }

    // Extract artwork from ID3v2 APIC frame
    private nonisolated func extractArtworkFromID3v2(data: Data, filename: String) -> UIImage? {
        guard data.count >= 10 else { return nil }

        // Read ID3v2 header
        let majorVersion = data[3]
        let tagSize = Int((UInt32(data[6]) << 21) | (UInt32(data[7]) << 14) | (UInt32(data[8]) << 7) | UInt32(data[9]))

        print("🏷️ Searching for APIC frame in ID3v2.\(majorVersion) tag, size: \(tagSize) bytes")

        // Parse frames to find APIC (attached picture)
        var offset = 10
        let endOffset = min(data.count, 10 + tagSize)

        while offset < endOffset - 10 {
            // Read frame header (10 bytes for v2.3/v2.4)
            let frameId = String(data: data.subdata(in: offset..<offset+4), encoding: .ascii) ?? ""

            let frameSize: Int
            if majorVersion >= 4 {
                // ID3v2.4 uses synchsafe integers for frame size
                frameSize = Int((UInt32(data[offset+4]) << 21) | (UInt32(data[offset+5]) << 14) | (UInt32(data[offset+6]) << 7) | UInt32(data[offset+7]))
            } else {
                // ID3v2.3 uses regular 32-bit big-endian integer
                frameSize = Int((UInt32(data[offset+4]) << 24) | (UInt32(data[offset+5]) << 16) | (UInt32(data[offset+6]) << 8) | UInt32(data[offset+7]))
            }

            // Move to frame data
            offset += 10

            guard frameSize > 0 && offset + frameSize <= endOffset else {
                break
            }

            if frameId == "APIC" {
                print("🎨 Found APIC frame in \(filename), size: \(frameSize) bytes")

                let frameData = data.subdata(in: offset..<offset+frameSize)

                // Parse APIC frame structure:
                // [Encoding] [MIME type] [Picture type] [Description] [Picture data]
                var frameOffset = 1 // Skip encoding byte

                // Skip MIME type (null-terminated string)
                while frameOffset < frameData.count && frameData[frameOffset] != 0 {
                    frameOffset += 1
                }
                frameOffset += 1 // Skip null terminator

                // Skip picture type (1 byte)
                frameOffset += 1

                // Skip description (null-terminated string, encoding-dependent)
                let encoding = frameData[0]
                if encoding == 1 || encoding == 2 { // UTF-16
                    // Look for double null bytes
                    while frameOffset < frameData.count - 1 && !(frameData[frameOffset] == 0 && frameData[frameOffset + 1] == 0) {
                        frameOffset += 1
                    }
                    frameOffset += 2 // Skip double null
                } else {
                    // Single byte encoding
                    while frameOffset < frameData.count && frameData[frameOffset] != 0 {
                        frameOffset += 1
                    }
                    frameOffset += 1 // Skip null terminator
                }

                // Extract image data
                guard frameOffset < frameData.count else {
                    print("⚠️ Invalid APIC frame structure in: \(filename)")
                    break
                }

                let imageData = frameData.subdata(in: frameOffset..<frameData.count)

                if let image = UIImage(data: imageData) {
                    print("✅ Successfully extracted artwork from ID3v2 APIC frame: \(filename)")
                    return image
                } else {
                    print("⚠️ Could not create UIImage from APIC data in: \(filename)")
                }
            }

            offset += frameSize
        }

        print("⚠️ No APIC frame found in ID3v2 tag: \(filename)")
        return nil
    }

    // Safe byte reading helper for DSF format (little-endian)
    private nonisolated func readLittleEndianUInt64(from data: Data, offset: Int) -> UInt64 {
        guard offset >= 0 && offset + 8 <= data.count else {
            print("⚠️ Invalid byte access in artwork: offset=\(offset), dataSize=\(data.count)")
            return 0
        }

        let byte0 = UInt64(data[offset])
        let byte1 = UInt64(data[offset + 1]) << 8
        let byte2 = UInt64(data[offset + 2]) << 16
        let byte3 = UInt64(data[offset + 3]) << 24
        let byte4 = UInt64(data[offset + 4]) << 32
        let byte5 = UInt64(data[offset + 5]) << 40
        let byte6 = UInt64(data[offset + 6]) << 48
        let byte7 = UInt64(data[offset + 7]) << 56

        return byte0 | byte1 | byte2 | byte3 | byte4 | byte5 | byte6 | byte7
    }

    // MARK: - Generic Artwork Extraction (Opus, OGG, etc.)

    private nonisolated func extractGenericArtwork(from url: URL) async -> UIImage? {
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)

            // Look for common image format signatures
            let jpegSignature = Data([0xFF, 0xD8, 0xFF])
            let pngSignature = Data([0x89, 0x50, 0x4E, 0x47])

            // Search in first 64KB of file for image data
            let searchRange = 0..<min(data.count, 65536)

            if data.range(of: jpegSignature, in: searchRange) != nil ||
               data.range(of: pngSignature, in: searchRange) != nil {
                print("🎨 Found potential artwork in generic file: \(url.lastPathComponent)")
                // For complex formats like Opus/OGG, we'd need more sophisticated parsing
                // For now, return nil and let the detection system handle it
            }

            return nil
        } catch {
            print("❌ Generic artwork extraction failed: \(error)")
            return nil
        }
    }
}
