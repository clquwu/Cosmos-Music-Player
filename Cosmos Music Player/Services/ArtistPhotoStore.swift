import UIKit

/// Artists' photos from their online profile - the picture at the top of an
/// artist's page - kept on disk so lists can show it without going online.
/// Before this the photo was downloaded each time the page opened and shown
/// nowhere else: every artist circle in Search and the lists was a song cover
/// or an initial.
actor ArtistPhotoStore {
    static let shared = ArtistPhotoStore()

    private let directory: URL
    private let memory = NSCache<NSString, UIImage>()
    /// Lookups already in progress, so a row that appears twice asks once.
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    /// Names looked up this session that have no photo online.
    private var missing: Set<String> = []

    /// Lists show the photo in a circle of at most ~200pt.
    private static let thumbnailSide: CGFloat = 400

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("ArtistPhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func key(for name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func fileURL(for name: String) -> URL {
        directory.appendingPathComponent(key(for: name).cacheFilename + ".jpg")
    }

    /// The photo saved for this artist, if any. Disk only, never the network.
    func cachedPhoto(for name: String) -> UIImage? {
        let key = key(for: name) as NSString
        if let image = memory.object(forKey: key) { return image }
        guard let data = try? Data(contentsOf: fileURL(for: name)),
              let image = Self.thumbnail(from: data) else { return nil }
        memory.setObject(image, forKey: key)
        return image
    }

    /// Saves the photo the artist page downloaded, replacing any older one
    /// (a "Wrong artist?" correction changes it).
    func store(_ data: Data, for name: String) {
        guard let image = Self.thumbnail(from: data),
              let jpeg = image.jpegData(compressionQuality: 0.85) else { return }
        try? jpeg.write(to: fileURL(for: name), options: .atomic)
        memory.setObject(image, forKey: key(for: name) as NSString)
        missing.remove(key(for: name))
    }

    /// The saved photo, or - when there is none yet - the one the artist page
    /// would show, looked up online (the same cached lookup) and saved.
    /// `artistId` gives the lookup the artist's album titles, as the page
    /// does: they tell namesakes apart, and the lookup it caches is the one
    /// the page will show later.
    func photo(for name: String, artistId: Int64?) async -> UIImage? {
        if let cached = cachedPhoto(for: name) { return cached }
        let key = key(for: name)
        guard !missing.contains(key) else { return nil }
        if let running = inFlight[key] { return await running.value }

        let albumHints = artistId.flatMap { try? DatabaseManager.shared.getAlbumsByArtistId($0) }?.map(\.title) ?? []
        let task = Task<UIImage?, Never> {
            guard let artist = try? await HybridMusicAPIService.shared.searchArtist(name: name, albumHints: albumHints),
                  let best = artist.images.max(by: { ($0.width ?? 0) * ($0.height ?? 0) < ($1.width ?? 0) * ($1.height ?? 0) }),
                  let url = URL(string: best.url),
                  let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            // Saved below, back on the actor.
            return Self.thumbnail(from: data)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image, let jpeg = image.jpegData(compressionQuality: 0.85) {
            try? jpeg.write(to: fileURL(for: name), options: .atomic)
            memory.setObject(image, forKey: key as NSString)
        } else {
            missing.insert(key)
        }
        return image
    }

    private static func thumbnail(from data: Data) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        let side = max(image.size.width, image.size.height)
        guard side > thumbnailSide else { return image }
        let scale = thumbnailSide / side
        return image.preparingThumbnail(of: CGSize(width: image.size.width * scale, height: image.size.height * scale)) ?? image
    }
}
