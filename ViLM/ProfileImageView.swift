import SwiftUI
import CryptoKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

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
            if let localImage = localImage {
                content(localImage)
            } else {
                placeholder()
            }
        }
        .task(id: photoUrl ?? "") {
            await resolveLocalImage()
        }
    }
    
    private func resolveLocalImage() async {
        guard let libraryURL = libraryURL else { return }
        
        let safeId = entityId.replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_")
        let profilesDir = libraryURL.appendingPathComponent(".catalog/profiles")
        
        let fileName: String
        if isGallery, let urlString = photoUrl, urlString != "local://primary" {
            let hashData = SHA256.hash(data: Data(urlString.utf8))
            let hashString = hashData.compactMap { String(format: "%02x", $0) }.joined()
            fileName = "\(safeId)_\(hashString).jpg"
        } else {
            fileName = "\(safeId).jpg"
        }
        
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
            
            if let image = await createImage(from: data) {
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
        // For local file URLs, Data(contentsOf:) is reliable and we don't need URLSession complexity
        guard let data = try? Data(contentsOf: url) else { return nil }
        return await createImage(from: data)
    }
    
    private func createImage(from data: Data) async -> Image? {
        await Task.detached {
            #if os(iOS)
            if let uiImage = UIImage(data: data) {
                return Image(uiImage: uiImage)
            }
            #else
            if let nsImage = NSImage(data: data) {
                return Image(nsImage: nsImage)
            }
            #endif
            return nil
        }.value
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
