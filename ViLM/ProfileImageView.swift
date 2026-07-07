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
    nonisolated(unsafe) static let shared = NSCache<NSString, PlatformImage>()
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
        .task(id: photoUrl ?? "") {
            await resolveLocalImage()
        }
    }

    // Prefer already-loaded state, then a synchronous cache hit so a page that
    // was decoded elsewhere (e.g. the gallery strip) renders immediately
    // instead of flashing the placeholder before `.task` runs.
    private var displayImage: Image? {
        if let localImage { return localImage }
        if let url = resolvedFileURL,
           let cached = ProfileImageCache.shared.object(forKey: url.path as NSString) {
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
        guard let libraryURL = libraryURL else { return }

        let safeId = ProfileImageNaming.safeId(for: entityId)
        let profilesDir = libraryURL.appendingPathComponent(".catalog/profiles")

        let fileName = ProfileImageNaming.fileName(for: entityId, token: photoUrl, isGallery: isGallery)

        let fileURL = profilesDir.appendingPathComponent(fileName)
        
        // 1. Check if the primary image file exists
        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let image = await loadImageAsync(from: fileURL) {
                setLocalImage(image)
                return
            } else {
                // File exists but failed to decode (e.g. corrupted/0 bytes). Delete it to allow redownload.
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
        
        // 2. Check for legacy images to migrate (previously hashed by URL) - only for primary
        if !isGallery, let fallbackFile = findAnyExistingImage(in: profilesDir, for: safeId) {
            do {
                try FileManager.default.moveItem(at: fallbackFile, to: fileURL)
                cleanupOldImages(in: profilesDir, for: safeId, keeping: fileName)
                if let image = await loadImageAsync(from: fileURL) {
                    setLocalImage(image)
                    return
                } else {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            } catch {
                if let image = await loadImageAsync(from: fallbackFile) {
                    setLocalImage(image)
                    return
                }
            }
        }
        
        // 3. If no local image exists, and a URL was provided, attempt to download it
        guard let photoUrlString = photoUrl, let url = URL(string: photoUrlString) else { return }
        
        do {
            try FileManager.default.createDirectory(at: profilesDir, withIntermediateDirectories: true, attributes: nil)
            
            var request = URLRequest(url: url)
            // Add a standard User-Agent to prevent 403 Forbidden on some CDNs (like sk-static)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
                print("Failed to download profile image for \(entityId): HTTP \(httpResponse.statusCode)")
                return
            }
            
            try data.write(to: fileURL)

            if let image = await decodeAndCache(from: data, cacheKey: fileURL.path as NSString) {
                setLocalImage(image)
            }
        } catch {
            print("Failed to download profile image for \(entityId): \(error)")
        }
    }
    
    @MainActor
    private func setLocalImage(_ image: Image) {
        self.localImage = image
    }
    
    private func loadImageAsync(from url: URL) async -> Image? {
        let key = url.path as NSString
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
            ProfileImageCache.shared.setObject(platformImage, forKey: cacheKey)
        }
        return Image(platformImage: platformImage)
    }
    
    private func findAnyExistingImage(in directory: URL, for safeId: String) -> URL? {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            return files.first { $0.lastPathComponent.hasPrefix("\(safeId)_") && $0.lastPathComponent.hasSuffix(".jpg") }
        } catch {
            return nil
        }
    }
    
    private func cleanupOldImages(in directory: URL, for safeId: String, keeping currentFileName: String) {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            for file in files {
                let name = file.lastPathComponent
                if name.hasPrefix("\(safeId)_") && name.hasSuffix(".jpg") && name != currentFileName {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        } catch {
            // Ignore cleanup errors
        }
    }
}
