//
//  String+CacheFilename.swift
//  Cosmos Music Player
//
//  Filesystem-safe filenames for cache entries keyed by metadata.
//

import Foundation

/// Filesystem-safe cache filename for a metadata-derived key.
///
/// Artist names come from file tags and third-party APIs, so they can carry
/// "/" (AC/DC), "..", or characters that are illegal in filenames. Building
/// the name by replacing only spaces produced cache files that could never be
/// written (a "/" silently nests a directory that does not exist) or that two
/// different artists would share ("AC/DC" and "AC_DC" both became "ac_dc").
/// Encoding every character outside a small safe set keeps the mapping
/// deterministic and collision-free, so a cache write can never land outside
/// its directory and a cache hit always belongs to the artist it was cached
/// for.
extension String {
    /// Percent-encoded form, safe as a single filename component.
    /// "AC/DC" -> "ac%2Fdc", "AC_DC" -> "ac_dc", "Sigur Rós" -> "sigur_rós".
    ///
    /// Names without special characters encode to exactly the strings the
    /// previous scheme produced, so existing cache entries stay valid.
    var cacheFilename: String {
        let lowered = lowercased().replacingOccurrences(of: " ", with: "_")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
        return lowered.addingPercentEncoding(withAllowedCharacters: allowed) ?? lowered
    }
}
