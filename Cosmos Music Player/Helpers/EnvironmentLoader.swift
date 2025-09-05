//
//  EnvironmentLoader.swift
//  Cosmos Music Player
//
//  Environment variable loader for API keys and configuration
//

import Foundation

class EnvironmentLoader: @unchecked Sendable {
    static let shared = EnvironmentLoader()
    
    private var environmentVariables: [String: String] = [:]
    
    private init() {
        loadEnvironmentVariables()
    }
    
    private func loadEnvironmentVariables() {
        // First, try to load from .env file in the app bundle
        if let envPath = Bundle.main.path(forResource: ".env", ofType: nil) {
            loadFromFile(path: envPath)
        }
        
        // Also try loading from .env in the project root (for development)
        let projectRoot = Bundle.main.bundlePath
        let rootEnvPath = URL(fileURLWithPath: projectRoot)
            .appendingPathComponent("../../../.env")
            .standardized
            .path
        
        if FileManager.default.fileExists(atPath: rootEnvPath) {
            loadFromFile(path: rootEnvPath)
        }
        
        // Finally, load from actual environment variables (overrides file values)
        loadFromSystemEnvironment()
    }
    
    private func loadFromFile(path: String) {
        guard let content = try? String(contentsOfFile: path) else {
            print("📄 EnvironmentLoader: Could not read .env file at \(path)")
            return
        }
        
        let lines = content.components(separatedBy: .newlines)
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Skip empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            
            // Parse KEY=VALUE format
            let components = trimmed.components(separatedBy: "=")
            if components.count >= 2 {
                let key = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let value = components.dropFirst().joined(separator: "=").trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Remove quotes if present
                let cleanValue = value.hasPrefix("\"") && value.hasSuffix("\"") ? 
                    String(value.dropFirst().dropLast()) : value
                
                environmentVariables[key] = cleanValue
                print("🔑 EnvironmentLoader: Loaded \(key) from .env file")
            }
        }
    }
    
    private func loadFromSystemEnvironment() {
        // Load system environment variables (these override .env file values)
        for (key, value) in ProcessInfo.processInfo.environment {
            if key.hasPrefix("SPOTIFY_") || key.hasPrefix("DISCOGS_") {
                environmentVariables[key] = value
                print("🌍 EnvironmentLoader: Loaded \(key) from system environment")
            }
        }
    }
    
    /// Get an environment variable value
    func getValue(for key: String) -> String? {
        return environmentVariables[key]
    }
    
    /// Get an environment variable value with a fallback
    func getValue(for key: String, fallback: String) -> String {
        return environmentVariables[key] ?? fallback
    }
    
    /// Check if a key exists
    func hasKey(_ key: String) -> Bool {
        return environmentVariables[key] != nil
    }
    
    /// Get all loaded keys (for debugging)
    func getAllKeys() -> [String] {
        return Array(environmentVariables.keys).sorted()
    }
}

// MARK: - API Key Helpers

extension EnvironmentLoader {
    // Spotify API Keys
    var spotifyClientId: String {
        guard let clientId = getValue(for: "SPOTIFY_CLIENT_ID"), !clientId.isEmpty else {
            fatalError("❌ SPOTIFY_CLIENT_ID not found in environment variables. Please add it to your .env file.")
        }
        return clientId
    }
    
    var spotifyClientSecret: String {
        guard let clientSecret = getValue(for: "SPOTIFY_CLIENT_SECRET"), !clientSecret.isEmpty else {
            fatalError("❌ SPOTIFY_CLIENT_SECRET not found in environment variables. Please add it to your .env file.")
        }
        return clientSecret
    }
    
    // Discogs API Keys
    var discogsConsumerKey: String {
        guard let consumerKey = getValue(for: "DISCOGS_CONSUMER_KEY"), !consumerKey.isEmpty else {
            fatalError("❌ DISCOGS_CONSUMER_KEY not found in environment variables. Please add it to your .env file.")
        }
        return consumerKey
    }
    
    var discogsConsumerSecret: String {
        guard let consumerSecret = getValue(for: "DISCOGS_CONSUMER_SECRET"), !consumerSecret.isEmpty else {
            fatalError("❌ DISCOGS_CONSUMER_SECRET not found in environment variables. Please add it to your .env file.")
        }
        return consumerSecret
    }
}