import SwiftUI
import CryptoKit

struct ProfileImageView<Content: View, Placeholder: View>: View {
    let libraryURL: URL?
    let entityId: String
    let photoUrl: String?
    let isGallery: Bool
    let content: (Image) -> Content
    let placeholder: () -> Placeholder
    
    @State private var localURL: URL?
    
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
            if let localURL = localURL {
                AsyncImage(url: localURL, content: content, placeholder: placeholder)
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
        if isGallery, let urlString = photoUrl {
            let hashData = SHA256.hash(data: Data(urlString.utf8))
            let hashString = hashData.compactMap { String(format: "%02x", $0) }.joined()
            fileName = "\(safeId)_\(hashString).jpg"
        } else {
            fileName = "\(safeId).jpg"
        }
        
        let fileURL = profilesDir.appendingPathComponent(fileName)
        
        // 1. Check if the primary image file exists
        if FileManager.default.fileExists(atPath: fileURL.path) {
            localURL = fileURL
            return
        }
        
        // 2. Check for legacy images to migrate (previously hashed by URL) - only for primary
        if !isGallery, let fallbackFile = findAnyExistingImage(in: profilesDir, for: safeId) {
            do {
                try FileManager.default.moveItem(at: fallbackFile, to: fileURL)
                localURL = fileURL
                cleanupOldImages(in: profilesDir, for: safeId, keeping: fileName)
                return
            } catch {
                localURL = fallbackFile
                return
            }
        }
        
        // 3. If no local image exists, and a URL was provided, attempt to download it
        guard let photoUrlString = photoUrl, let url = URL(string: photoUrlString) else { return }
        
        do {
            try FileManager.default.createDirectory(at: profilesDir, withIntermediateDirectories: true, attributes: nil)
            let (data, _) = try await URLSession.shared.data(from: url)
            try data.write(to: fileURL)
            localURL = fileURL
        } catch {
            print("Failed to download profile image for \(entityId): \(error)")
        }
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
