// ProfileImageView.swift
// Async profile-photo view: resolves an entity's photo from the on-disk
// cache (primary or hashed gallery file), downloading validated bytes from
// the photo URL when missing. Decoded images are shared through a bounded
// NSCache.

import SwiftUI
import LibraryCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// Shared decoded-image cache. Without this, every ProfileImageView instance
// decodes independently — so the full-screen gallery browser (whose
// wrap-around sentinels are separate instances showing the same photo) flashes
// placeholders and snaps abruptly. Lives outside the generic view because
// generic types can't hold static stored properties. Thread-safe NSCache.
private enum ProfileImageCache {
    nonisolated(unsafe) static let shared: NSCache<NSString, PlatformImage> = {
        let c = NSCache<NSString, PlatformImage>()
        // This cache holds full-resolution decoded photos (the full-screen
        // browser reads from it), so bound it by decoded pixel bytes — cost
        // is passed at setObject — rather than waiting for system memory
        // pressure, which on iOS often arrives as a jetsam kill.
        c.totalCostLimit = 192 * 1024 * 1024
        return c
    }()

    /// Cache key for a file on disk.
    ///
    /// Includes the modification date, because the PRIMARY photo's filename is
    /// fixed per entity (`actor_Name.jpg`) — starring a different photo
    /// overwrites the same path. Keying on the path alone meant the old decoded
    /// image was served until the app was relaunched and the cache was empty.
    ///
    /// Same rule ThumbnailLoader already uses, and for the same reason:
    /// "regenerated thumbnails are picked up". Gallery photos are
    /// content-addressed so they never needed it; the primary always did.
    static func key(for url: URL) -> NSString {
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        return "\(url.path)|\(modified)" as NSString
    }

    /// Rough decoded-bitmap size in bytes (RGBA), used as the NSCache cost.
    static func cost(of image: PlatformImage) -> Int {
        #if os(iOS)
        return Int(image.size.width * image.scale) * Int(image.size.height * image.scale) * 4
        #else
        return Int(image.size.width) * Int(image.size.height) * 4
        #endif
    }
}

// URLs that failed to download or decode this session. Without this, a dead
// photo URL is re-requested every single time its view appears — every
// scroll of the actor grid fires HTTP requests for the same 404s. Session-
// scoped on purpose: a URL that's down today may work after a relaunch.
private enum FailedProfileURLs {
    nonisolated(unsafe) private static var urls = Set<String>()
    private static let lock = NSLock()

    static func contains(_ url: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return urls.contains(url)
    }

    static func insert(_ url: String) {
        lock.lock(); defer { lock.unlock() }
        urls.insert(url)
    }
}

// URLs a card is currently downloading. N visible cards for the same actor
// used to fire N parallel downloads of one photo, racing last-write-wins
// writes to the same file (DEFECT_INVENTORY L4). The first card claims the
// URL; the rest skip — the file lands on disk once and later appearances
// load it locally.
private enum InFlightProfileURLs {
    nonisolated(unsafe) private static var urls = Set<String>()
    private static let lock = NSLock()

    /// True if the claim was acquired (nothing else is downloading this URL).
    static func begin(_ url: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return urls.insert(url).inserted
    }

    static func end(_ url: String) {
        lock.lock(); defer { lock.unlock() }
        urls.remove(url)
    }
}

struct ProfileImageView<Content: View, Placeholder: View>: View {
    let libraryURL: URL?
    let entityId: String
    let photoUrl: String?
    let isGallery: Bool
    let content: (Image) -> Content
    let placeholder: () -> Placeholder

    @State private var localImage: Image?
    
    init(libraryURL: URL?, entityId: String, photoUrl: String?, isGallery: Bool = false, @ViewBuilder content: @escaping (Image) -> Content, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.libraryURL = libraryURL
        self.entityId = entityId
        self.photoUrl = photoUrl
        self.isGallery = isGallery
        self.content = content
        self.placeholder = placeholder
    }
    
    var body: some View {
        Group {
            if let image = displayImage {
                content(image)
            } else {
                placeholder()
            }
        }
        // Explicit sentinel: a nil photoUrl and an empty-string photoUrl must
        // not share a task identity (both mean "no remote URL" today, but the
        // collision would silently skip a reload if that ever changes).
        .task(id: photoUrl ?? "«no-url»") {
            await resolveLocalImage()
        }
    }

    // Prefer already-loaded state, then a synchronous cache hit so a page that
    // was decoded elsewhere (e.g. the gallery strip) renders immediately
    // instead of flashing the placeholder before `.task` runs.
    private var displayImage: Image? {
        if let localImage { return localImage }
        if let url = resolvedFileURL,
           let cached = ProfileImageCache.shared.object(forKey: ProfileImageCache.key(for: url)) {
            return Image(platformImage: cached)
        }
        return nil
    }

    // The primary on-disk location for this photo (no I/O), mirroring the
    // filename logic in resolveLocalImage. Used for synchronous cache lookups.
    private var resolvedFileURL: URL? {
        guard let libraryURL else { return nil }
        let profilesDir = libraryURL.appendingPathComponent(".catalog/profiles")
        let fileName = ProfileImageNaming.fileName(for: entityId, token: photoUrl, isGallery: isGallery)
        return profilesDir.appendingPathComponent(fileName)
    }

    private func resolveLocalImage() async {
        guard libraryURL != nil else { return }

        let fileName = ProfileImageNaming.fileName(for: entityId, token: photoUrl, isGallery: isGallery)

        // A download (below) lands in the profile's OWNING library; display
        // lookup checks every open library in precedence order first.
        let profilesDir = LibrarySession.shared.profilesDir(forProfile: entityId)
            ?? libraryURL!.appendingPathComponent(".catalog/profiles")
        let fileURL = profilesDir.appendingPathComponent(fileName)

        // 1. Look for the cached file in ANY open library (the merged actor
        // view can reference photos that live only in an attachment).
        if let existing = LibrarySession.shared.existingProfilePhotoURL(fileName: fileName) {
            if let image = await loadImageAsync(from: existing) {
                setLocalImage(image)
                return
            } else {
                // File exists but failed to decode (e.g. corrupted/0 bytes). Delete it to allow redownload.
                try? FileManager.default.removeItem(at: existing)
            }
        }
        
        // NOTE: a "legacy migration" step used to live here — it moved the
        // first `<safeId>_*.jpg` file to the primary filename and deleted
        // every other match, from an era when that pattern was the *old
        // primary* naming scheme. Today that exact pattern is how GALLERY
        // photos are named, so the "migration" was actively destroying whole
        // galleries: any actor whose primary file was missing had one gallery
        // photo promoted and the rest permanently deleted, triggered by
        // merely scrolling their card into view. Never reintroduce a glob
        // over `<safeId>_` that deletes or moves files.

        // 2. If no local image exists, and a URL was provided, attempt to download it
        guard let photoUrlString = photoUrl, let url = URL(string: photoUrlString),
              url.scheme == "http" || url.scheme == "https" else { return }

        // A URL that already failed this session isn't retried — otherwise a
        // dead link fires a fresh HTTP request every time its card scrolls
        // into view.
        guard !FailedProfileURLs.contains(photoUrlString) else { return }

        // De-duplicate concurrent downloads of the same URL (L4).
        guard InFlightProfileURLs.begin(photoUrlString) else { return }
        defer { InFlightProfileURLs.end(photoUrlString) }

        do {
            try FileManager.default.createDirectory(at: profilesDir, withIntermediateDirectories: true, attributes: nil)

            var request = URLRequest(url: url)
            // Add a standard User-Agent to prevent 403 Forbidden on some CDNs (like sk-static)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
                FailedProfileURLs.insert(photoUrlString)
                print("Failed to download profile image for \(entityId): HTTP \(httpResponse.statusCode)")
                return
            }

            // Decode BEFORE writing. Some hosts return an HTML error page
            // with a 200 status; persisting it produced a churn loop — the
            // undecodable file was deleted on the next appearance and then
            // re-downloaded, forever. Only verified image bytes reach disk.
            guard let image = await decodeAndCache(from: data, cacheKey: fileURL.path as NSString) else {
                FailedProfileURLs.insert(photoUrlString)
                print("Downloaded profile image for \(entityId) is not decodable; not saving")
                return
            }

            try data.write(to: fileURL)
            setLocalImage(image)
        } catch {
            FailedProfileURLs.insert(photoUrlString)
            print("Failed to download profile image for \(entityId): \(error)")
        }
    }
    
    @MainActor
    private func setLocalImage(_ image: Image) {
        self.localImage = image
    }
    
    private func loadImageAsync(from url: URL) async -> Image? {
        let key = ProfileImageCache.key(for: url)
        if let cached = ProfileImageCache.shared.object(forKey: key) {
            return Image(platformImage: cached)
        }
        // For local file URLs, Data(contentsOf:) is reliable and we don't need URLSession complexity
        guard let data = try? Data(contentsOf: url) else { return nil }
        return await decodeAndCache(from: data, cacheKey: key)
    }

    private func decodeAndCache(from data: Data, cacheKey: NSString?) async -> Image? {
        // Decode off the main thread, but build the SwiftUI Image on the main
        // actor (its initializer is main-actor isolated).
        let platformImage: PlatformImage? = await Task.detached {
            #if os(iOS)
            return UIImage(data: data)
            #else
            return NSImage(data: data)
            #endif
        }.value
        guard let platformImage else { return nil }
        if let cacheKey {
            ProfileImageCache.shared.setObject(platformImage, forKey: cacheKey, cost: ProfileImageCache.cost(of: platformImage))
        }
        return Image(platformImage: platformImage)
    }
    
}
