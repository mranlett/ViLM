// FileRenamerService.swift
// Renames a video file on disk and updates its asset record to match. The two
// steps stay consistent: a DB failure rolls the file move back (so disk and
// catalog never disagree), and the video's duplicate-scan fingerprint is
// re-keyed to the new path (a rename must never cost a re-fingerprint).

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

        let oldFileName = asset.fileName
        let oldRelativePath = asset.relativePath

        try FileManager.default.moveItem(at: oldURL, to: newURL)

        let pathInLibrary = newURL.path.replacingOccurrences(of: libraryURL.path + "/", with: "")

        asset.fileName = newFileName
        asset.relativePath = pathInLibrary

        do {
            try store.updateAsset(asset)
        } catch {
            // Roll the file move back so the catalog row still points at a
            // real file — the old order left the file renamed with the row on
            // the stale path (asset flagged missing, metadata orphaned).
            try? FileManager.default.moveItem(at: newURL, to: oldURL)
            asset.fileName = oldFileName
            asset.relativePath = oldRelativePath
            throw error
        }

        // Re-key the duplicate-scan fingerprint to the new path: the bytes
        // didn't change, so the fingerprint is still valid. Best-effort —
        // the cache is regenerable.
        var prints = FrameFingerprintStore(libraryURL: libraryURL)
        if let entry = prints.entries[oldRelativePath] {
            prints.setHashes(entry.hashes, relativePath: pathInLibrary,
                             sizeBytes: entry.sizeBytes, modified: entry.modified)
            prints.removeEntry(relativePath: oldRelativePath)
            prints.save()
        }
    }
}
