//
//  ArtworkManager.swift
//  Cosmos Music Player
//
//  Manages album artwork extraction and caching
//

import Foundation
import UIKit
import AVFoundation

@MainActor
class ArtworkManager: ObservableObject {
    static let shared = ArtworkManager()
    
    private var cache: [String: UIImage] = [:]
    
    private init() {}
    
    func getArtwork(for track: Track) async -> UIImage? {
        // Check cache first
        if let cachedImage = cache[track.stableId] {
            return cachedImage
        }
        
        // Try to extract artwork (runs on background thread)
        if let image = await extractArtwork(from: URL(fileURLWithPath: track.path)) {
            // Store in cache (we're on MainActor)
            cache[track.stableId] = image
            return image
        }
        
        return nil
    }
    
    private nonisolated func extractArtwork(from url: URL) async -> UIImage? {
        let ext = url.pathExtension.lowercased()
        
        if ext == "flac" {
            return await extractFlacArtwork(from: url)
        } else if ext == "mp3" {
            return await extractMp3Artwork(from: url)
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
}
