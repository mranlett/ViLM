import SwiftUI

struct ProfileImageView<Content: View, Placeholder: View>: View {
    let libraryURL: URL?
    let entityId: String
    let photoUrl: String
    let content: (Image) -> Content
    let placeholder: () -> Placeholder
    
    @State private var localURL: URL?
    
    init(libraryURL: URL?, entityId: String, photoUrl: String, @ViewBuilder content: @escaping (Image) -> Content, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.libraryURL = libraryURL
        self.entityId = entityId
        self.photoUrl = photoUrl
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
        .task(id: photoUrl) {
            await resolveLocalImage()
        }
    }
    
    private func resolveLocalImage() async {
        guard let libraryURL = libraryURL, let url = URL(string: photoUrl) else { return }
        
        let safeId = entityId.replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_")
        let profilesDir = libraryURL.appendingPathComponent(".catalog/profiles")
        
        // Use a hash of the URL to ensure if the user changes the photo URL for the same entity, it downloads the new one
        let fileName = "\(safeId)_\(abs(photoUrl.hashValue)).jpg"
        let fileURL = profilesDir.appendingPathComponent(fileName)
        
        if FileManager.default.fileExists(atPath: fileURL.path) {
            localURL = fileURL
            return
        }
        
        // Download and save
        do {
            try FileManager.default.createDirectory(at: profilesDir, withIntermediateDirectories: true, attributes: nil)
            let (data, _) = try await URLSession.shared.data(from: url)
            try data.write(to: fileURL)
            localURL = fileURL
        } catch {
            print("Failed to download profile image for \(entityId): \(error)")
        }
    }
}
