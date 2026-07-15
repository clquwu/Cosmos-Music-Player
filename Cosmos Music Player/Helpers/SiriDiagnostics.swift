//
//  SiriDiagnostics.swift
//  Cosmos Music Player
//
//  Temporary file-based diagnostics for the Siri routing investigation:
//  every Siri-facing entry point appends a line to a log in the shared
//  app-group container so it can be pulled off-device with devicectl.
//  Lives under Library/ because devicectl can only copy from Library,
//  Documents or tmp. Remove once the iOS 27 Siri routing work settles.
//

import Foundation

enum SiriDiag {
    static let appGroupId = "group.dev.clq.Cosmos-Music-Player"
    nonisolated(unsafe) private static var migrated = false

    static func log(_ message: String) {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId
        ) else { return }
        let dir = container.appendingPathComponent("Library", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("siri-diagnostics.log")
        migrateRootLogIfNeeded(container: container, to: url)

        let stamp = ISO8601DateFormatter().string(from: Date())
        append("\(stamp) \(message)\n", to: url)
    }

    /// Earlier builds wrote to the group-container root, which devicectl
    /// cannot read — fold that file into the Library one.
    private static func migrateRootLogIfNeeded(container: URL, to url: URL) {
        guard !migrated else { return }
        migrated = true
        let old = container.appendingPathComponent("siri-diagnostics.log")
        guard let data = try? Data(contentsOf: old),
              let text = String(data: data, encoding: .utf8) else { return }
        append(text, to: url)
        try? FileManager.default.removeItem(at: old)
    }

    private static func append(_ text: String, to url: URL) {
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
