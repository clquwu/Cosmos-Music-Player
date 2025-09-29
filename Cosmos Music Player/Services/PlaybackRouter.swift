//
//  PlaybackRouter.swift
//  Cosmos Music Player
//
//  Smart audio playback routing for different formats
//

import Foundation
import AVFoundation
import SFBAudioEngine

enum PlaybackError: Error {
    case unsupportedFormat
    case fileNotFound
    case decodingFailed
    case dacNotConnected
}

/// Playback strategy pattern for different audio formats
class PlaybackRouter {

    enum PlaybackStrategy {
        case native(AVAudioFile)
        case sfbAudio(AudioDecoder)  // SFBAudioEngine for Opus, Vorbis, DSD
    }

    /// Determine the optimal playback strategy for a given audio file
    static func determineStrategy(for url: URL) async throws -> PlaybackStrategy {
        let ext = url.pathExtension.lowercased()

        switch ext {
        case "flac", "mp3", "wav", "aac":
            // Native AVAudioFile formats
            let file = try AVAudioFile(forReading: url)
            return .native(file)

        case "m4a":
            if isOpusInM4A(url) {
                // Opus in M4A → SFBAudioEngine
                let decoder = try AudioDecoder(url: url)
                return .sfbAudio(decoder)
            } else {
                // AAC in M4A → Native
                let file = try AVAudioFile(forReading: url)
                return .native(file)
            }

        case "opus", "ogg":
            // All Opus/Vorbis containers → SFBAudioEngine
            let decoder = try AudioDecoder(url: url)
            return .sfbAudio(decoder)

        case "dsf", "dff":
            // DSD formats → SFBAudioEngine with DSD to PCM conversion
            let decoder = try AudioDecoder(url: url)
            return .sfbAudio(decoder)

        default:
            throw PlaybackError.unsupportedFormat
        }
    }


    /// Check if M4A file contains Opus codec
    static func isOpusInM4A(_ url: URL) -> Bool {
        // Check MP4 atoms for Opus codec
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return false
        }

        // Look for 'Opus' atom in MP4 structure
        // MP4 structure: ftyp → moov → trak → mdia → minf → stbl → stsd → Opus
        let opusSignature = "Opus".data(using: .ascii)!
        return data.range(of: opusSignature, in: 0..<min(data.count, 10000)) != nil
    }

    /// Get format information for UI display
    static func getFormatInfo(for url: URL) -> (format: String, badge: String?) {
        let ext = url.pathExtension.lowercased()

        switch ext {
        case "flac":
            return ("FLAC", nil)
        case "mp3":
            return ("MP3", nil)
        case "wav":
            return ("WAV", nil)
        case "aac":
            return ("AAC", nil)
        case "m4a":
            if isOpusInM4A(url) {
                return ("Opus", "OPUS")
            } else {
                return ("AAC", nil)
            }
        case "opus":
            return ("Opus", "OPUS")
        case "ogg":
            // Could be Opus or Vorbis - would need deeper inspection
            return ("OGG", "OGG")
        case "dsf":
            return ("DSD", "DSD")
        case "dff":
            return ("DSDIFF", "DSD")
        default:
            return ("Unknown", nil)
        }
    }
}

