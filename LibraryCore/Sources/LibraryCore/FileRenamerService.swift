import Foundation

public class FileRenamerService {
    private let store: LibraryStore

    public init(store: LibraryStore) {
        self.store = store
    }

    public func rename(asset: inout Asset, newFileName: String, libraryURL: URL) throws {
        let oldURL = libraryURL.appendingPathComponent(asset.relativePath)
        let directoryURL = oldURL.deletingLastPathComponent()
        let newURL = directoryURL.appendingPathComponent(newFileName)
        
        guard oldURL != newURL else { return }
        
        try FileManager.default.moveItem(at: oldURL, to: newURL)
        
        let pathInLibrary = newURL.path.replacingOccurrences(of: libraryURL.path + "/", with: "")
        
        asset.fileName = newFileName
        asset.relativePath = pathInLibrary
        
        try store.updateAsset(asset)
    }
}
