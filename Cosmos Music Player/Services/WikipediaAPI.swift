//
//  WikipediaAPI.swift
//  Cosmos Music Player
//
//  Wikipedia summaries and Wikimedia Commons photos for artist pages,
//  reached through the Wikidata item MusicBrainz links to. Following that
//  link rather than searching Wikipedia by name is what keeps "Nirvana" the
//  band from becoming the Buddhist concept.
//

import Foundation

/// The lead of a Wikipedia article. Text is CC BY-SA, so `pageURL` must be
/// shown with it.
struct WikipediaSummary: Codable, Sendable {
    let title: String
    let extract: String
    let language: String
    let pageURL: String
    let imageURL: String?
    /// The Commons file page for the photo, for crediting it.
    let imagePageURL: String?
}

enum WikipediaAPI {
    /// Wikimedia asks API clients to identify themselves the same way
    /// MusicBrainz does.
    static var userAgent: String { MusicBrainzAPIService.userAgent }

    /// Wikipedia editions to try, most wanted first: the device language,
    /// then English, which has an article for almost every artist.
    static var preferredLanguages: [String] {
        var languages: [String] = []
        for identifier in Locale.preferredLanguages.prefix(2) {
            guard let code = Locale(identifier: identifier).language.languageCode?.identifier else { continue }
            let edition = wikipediaCode(for: code)
            if !languages.contains(edition) { languages.append(edition) }
        }
        if !languages.contains("en") { languages.append("en") }
        return languages
    }

    /// Norwegian Bokmål's edition is "no", not "nb".
    private static func wikipediaCode(for languageCode: String) -> String {
        languageCode == "nb" ? "no" : languageCode
    }

    // MARK: Wikidata

    /// Article titles for each requested language, from a Wikidata item's
    /// site links.
    static func articleTitles(wikidataID: String, languages: [String]) async throws -> [String: String] {
        let sites = languages.map { "\($0)wiki" }.joined(separator: "|")
        let data = try await get("https://www.wikidata.org/w/api.php", query: [
            "action": "wbgetentities", "ids": wikidataID, "props": "sitelinks",
            "sitefilter": sites, "format": "json"
        ])
        struct Response: Decodable {
            struct Entity: Decodable {
                struct SiteLink: Decodable { let title: String }
                let sitelinks: [String: SiteLink]?
            }
            let entities: [String: Entity]
        }
        let links = try JSONDecoder().decode(Response.self, from: data).entities[wikidataID]?.sitelinks ?? [:]
        var titles: [String: String] = [:]
        for language in languages {
            if let title = links["\(language)wiki"]?.title { titles[language] = title }
        }
        return titles
    }

    /// The item's image (P18) as a Commons file name, for artists whose
    /// article lead has no picture.
    static func commonsImageFile(wikidataID: String) async throws -> String? {
        let data = try await get("https://www.wikidata.org/w/api.php", query: [
            "action": "wbgetclaims", "entity": wikidataID, "property": "P18", "format": "json"
        ])
        struct Response: Decodable {
            struct Claim: Decodable {
                struct Snak: Decodable {
                    struct Value: Decodable { let value: String }
                    let datavalue: Value?
                }
                let mainsnak: Snak
            }
            let claims: [String: [Claim]]?
        }
        return try JSONDecoder().decode(Response.self, from: data).claims?["P18"]?.first?.mainsnak.datavalue?.value
    }

    // MARK: Commons

    /// A scaled rendering of a Commons file. Originals are often several
    /// thousand pixels and megabytes, far more than a 340 pt header needs.
    static func commonsImageURL(file: String, width: Int = 960) -> String? {
        let name = file.replacingOccurrences(of: " ", with: "_")
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return "https://commons.wikimedia.org/wiki/Special:FilePath/\(encoded)?width=\(width)"
    }

    static func commonsFilePage(file: String) -> String? {
        let name = file.replacingOccurrences(of: " ", with: "_")
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return "https://commons.wikimedia.org/wiki/File:\(encoded)"
    }

    // MARK: Summaries

    /// The lead section of an article. Nil for disambiguation pages, which
    /// describe a name rather than an artist.
    static func summary(title: String, language: String) async throws -> WikipediaSummary? {
        let path = title.replacingOccurrences(of: " ", with: "_")
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) else { return nil }
        let data: Data
        do {
            data = try await get("https://\(language).wikipedia.org/api/rest_v1/page/summary/\(encoded)", query: [:])
        } catch WikipediaAPIError.httpError(404) {
            return nil
        }

        struct Response: Decodable {
            struct Image: Decodable { let source: String; let width: Int?; let height: Int? }
            struct URLs: Decodable { struct Page: Decodable { let page: String }; let desktop: Page? }
            let type: String?
            let title: String
            let extract: String?
            let lang: String?
            let thumbnail: Image?
            let originalimage: Image?
            let content_urls: URLs?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.type != "disambiguation",
              let extract = response.extract?.trimmingCharacters(in: .whitespacesAndNewlines), !extract.isEmpty else { return nil }

        // The file name is the original's last path component; going through
        // Special:FilePath gets a sensibly sized rendering of it.
        let file = response.originalimage
            .flatMap { URL(string: $0.source)?.lastPathComponent.removingPercentEncoding }
        let imageURL: String?
        if let original = response.originalimage, (original.width ?? .max) <= 1280 {
            imageURL = original.source
        } else {
            imageURL = file.flatMap { commonsImageURL(file: $0) } ?? response.thumbnail?.source
        }

        return WikipediaSummary(
            title: response.title,
            extract: extract,
            language: response.lang ?? language,
            pageURL: response.content_urls?.desktop?.page ?? "https://\(language).wikipedia.org/wiki/\(encoded)",
            imageURL: imageURL,
            imagePageURL: file.flatMap { commonsFilePage(file: $0) }
        )
    }

    /// For MusicBrainz "wikipedia" links (older entries link an article
    /// rather than a Wikidata item): "https://en.wikipedia.org/wiki/Title".
    static func summary(articleURL: String) async throws -> WikipediaSummary? {
        guard let url = URL(string: articleURL), let host = url.host,
              host.hasSuffix("wikipedia.org"),
              let language = host.split(separator: ".").first,
              url.path.hasPrefix("/wiki/") else { return nil }
        // Taken from the whole path, not one component: "AC/DC" has a slash.
        return try await summary(title: String(url.path.dropFirst("/wiki/".count)), language: String(language))
    }

    /// The best summary for a MusicBrainz artist: the device language when
    /// that edition has an article, English otherwise.
    static func bestSummary(wikidataID: String?, articleURL: String?) async throws -> WikipediaSummary? {
        if let wikidataID {
            let languages = preferredLanguages
            let titles = try await articleTitles(wikidataID: wikidataID, languages: languages)
            for language in languages {
                guard let title = titles[language] else { continue }
                if let summary = try await summary(title: title, language: language) { return summary }
            }
        }
        if let articleURL { return try await summary(articleURL: articleURL) }
        return nil
    }

    // MARK: Requests

    private static func get(_ base: String, query: [String: String]) async throws -> Data {
        guard var components = URLComponents(string: base) else { throw WikipediaAPIError.invalidURL }
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = components.url else { throw WikipediaAPIError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard status == 200 else { throw WikipediaAPIError.httpError(status) }
        return data
    }
}

enum WikipediaAPIError: Error, LocalizedError {
    case invalidURL
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .httpError(let code): return "HTTP Error: \(code)"
        }
    }
}
