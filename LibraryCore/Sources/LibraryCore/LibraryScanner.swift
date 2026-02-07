import Foundation

public class LibraryScanner {
    private let store: LibraryStore
    
    public init(store: LibraryStore) {
        self.store = store
    }
    
    public func scan(at rootURL: URL) async throws {
        let fileManager = FileManager.default
        
        // Only look for videos, skip the hidden .catalog folder
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        
        let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: options
        )
        
        while let fileURL = enumerator?.nextObject() as? URL {
            let ext = fileURL.pathExtension.lowercased()
            
            // Supported formats from your spec
            if ["mp4", "mov", "m4v"].contains(ext) {
                // Create a path relative to the drive root for portability
                let rootPath = rootURL.standardizedFileURL.path
                let filePath = fileURL.standardizedFileURL.path

                let relativePath: String
                if filePath.hasPrefix(rootPath) {
                    var rel = String(filePath.dropFirst(rootPath.count))
                    if rel.hasPrefix("/") { rel.removeFirst() } // ✅ remove leading slash
                    relativePath = rel
                } else {
                    // Fallback: just use lastPathComponent
                    relativePath = fileURL.lastPathComponent
                }

                
                let asset = Asset(
                    relativePath: relativePath,
                    fileName: fileURL.lastPathComponent
                )
                
                // Write to the SQLite database
                try store.saveAsset(asset)
                print("Registered: \(asset.fileName)")
            }
        }
    }
}
