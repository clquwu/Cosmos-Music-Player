//
//  SecurityScopedFolderBookmark.swift
//  Cosmos Music Player
//
//  Create and resolve security-scoped bookmarks for user-chosen library folders.
//

import Foundation

enum SecurityScopedFolderBookmark {
    /// Creates bookmark data suitable for storing in UserDefaults (includes security scope).
    static func bookmarkData(for folderURL: URL) throws -> Data {
        try folderURL.bookmarkData(
            options: [/*.withSecurityScope*/],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Resolves bookmark data to a file URL. Does not start security-scoped access.
    static func resolveURL(from bookmarkData: Data) -> (url: URL, isStale: Bool)? {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [ .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return (url, isStale)
        } catch {
            print("⚠️ SecurityScopedFolderBookmark: failed to resolve bookmark: \(error)")
            return nil
        }
    }
}
