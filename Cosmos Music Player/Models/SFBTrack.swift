//
//  SFBTrack.swift
//  Cosmos Music Player
//
//  Audio track model for SFBAudioEngine integration
//

import Foundation
import SFBAudioEngine
import UIKit

/// A simplified audio track for SFBAudioEngine
struct SFBTrack: Identifiable {
    /// The unique identifier of this track
    let id = UUID()
    /// The URL holding the audio data
    let url: URL

    /// Duration in seconds (calculated from SFBAudioEngine)
    let duration: TimeInterval
    /// Sample rate from SFBAudioEngine
    let sampleRate: Double
    /// Frame length from SFBAudioEngine
    let frameLength: Int64

    /// Reads audio properties and initializes a track
    init(url: URL) {
        self.url = url

        // Try to get properties from SFBAudioEngine
        if let audioFile = try? SFBAudioEngine.AudioFile(readingPropertiesAndMetadataFrom: url) {
            let frameLength = audioFile.properties.frameLength ?? 0
            let sampleRate = audioFile.properties.sampleRate ?? 0
            let durationProperty = audioFile.properties.duration ?? 0

            self.frameLength = frameLength
            self.sampleRate = sampleRate

            print("🔍 SFBTrack AudioFile properties: frameLength=\(frameLength), sampleRate=\(sampleRate), duration=\(durationProperty)")

            // For duration, prefer the direct duration property if available
            if durationProperty > 0 {
                self.duration = durationProperty
                print("🔍 SFBTrack using direct duration: \(self.duration) seconds")
            } else if frameLength > 0 && sampleRate > 0 {
                self.duration = Double(frameLength) / sampleRate
                print("🔍 SFBTrack calculated duration: \(self.duration) seconds")
            } else {
                self.duration = 0
                print("⚠️ SFBTrack: Invalid frame length or sample rate")
            }
        } else {
            // Fallback values
            print("⚠️ SFBTrack: Could not read AudioFile properties")
            self.frameLength = 0
            self.sampleRate = 0
            self.duration = 0
        }
    }

    /// Returns a decoder for this track or `nil` if the audio type is unknown
    /// Let SFBAudioEngine choose the best decoder automatically
    func decoder(enableDoP: Bool = false) throws -> PCMDecoding? {
        let pathExtension = url.pathExtension.lowercased()
        if AudioDecoder.handlesPaths(withExtension: pathExtension) {
            return try AudioDecoder(url: url)
        } else if DSDDecoder.handlesPaths(withExtension: pathExtension) {
            let dsdDecoder: DSDDecoder
            do {
                dsdDecoder = try DSDDecoder(url: url)
            } catch {
                print("❌ DSDDecoder creation failed for \(url.lastPathComponent): \(error)")
                print("💡 This may be due to unsupported DSD sample rate - returning nil to fallback to native playback")
                return nil // This will cause SFBAudioEngine to return false from canHandle, falling back to native
            }

            if enableDoP {
                // For external DACs, use DoP with proper error handling
                print("🎵 Attempting DoP decoder for external DAC")
                do {
                    let dopDecoder = try DoPDecoder(decoder: dsdDecoder)
                    print("✅ DoP decoder created successfully for DAC")
                    return dopDecoder
                } catch {
                    print("❌ DoP failed for DAC, this may cause noise issues: \(error)")
                    // For DACs that support DoP, failing back to PCM may cause noise
                    // Try to create PCM decoder but warn about potential issues
                    do {
                        let pcmDecoder = try DSDPCMDecoder(decoder: dsdDecoder)
                        print("⚠️ Using PCM fallback - may cause noise on DoP-capable DAC")
                        return pcmDecoder
                    } catch {
                        print("❌ Both DoP and PCM failed: \(error)")
                        throw error
                    }
                }
            } else {
                // For internal audio or non-DoP capable devices, prefer PCM
                do {
                    let pcmDecoder = try DSDPCMDecoder(decoder: dsdDecoder)
                    print("✅ DSD PCM decoder created for internal audio")
                    return pcmDecoder
                } catch {
                    print("⚠️ DSD PCM conversion failed, trying DoP as fallback: \(error)")
                    // Fallback to DoP if PCM fails (e.g., high DSD rates)
                    do {
                        let dopDecoder = try DoPDecoder(decoder: dsdDecoder)
                        print("✅ DoP decoder created as PCM fallback")
                        return dopDecoder
                    } catch {
                        print("❌ Both PCM and DoP failed: \(error)")
                        throw error
                    }
                }
            }
        }
        return nil
    }
}

extension SFBTrack: Equatable {
    /// Returns true if the two tracks have the same `id`
    static func ==(lhs: SFBTrack, rhs: SFBTrack) -> Bool {
        return lhs.id == rhs.id
    }
}