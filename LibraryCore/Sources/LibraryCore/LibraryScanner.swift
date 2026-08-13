// LibraryScanner.swift
// Walks a library folder for video files and registers unseen ones as assets
// (INSERT OR IGNORE, so re-scans are cheap and non-destructive).

import Foundation

public class LibraryScanner {

    /// Containers the scanner will catalogue.
    ///
    /// 🚨 `.mkv` was missing until 2026-08-12 (#63), and the way it was missing
    /// is the point: an unrecognised file is not skipped VISIBLY. There is no
    /// count, no report, no "skipped" state — the file simply never enters the
    /// library, which is indistinguishable from it not being there.
    ///
    /// ⭐ So this list is deliberately GENEROUS. Some of these containers
    /// AVFoundation cannot decode, so a thumbnail or a fingerprint may fail —
    /// that path already degrades to a placeholder rather than an error. A
    /// catalogued file the app cannot preview is visible and fixable; an
    /// unindexed one is neither.
    static let indexableExtensions: Set<String> = [
        // AVFoundation-native
        "mp4", "mov", "m4v",
        // Common containers. Indexed even where playback may not work.
        "mkv", "avi", "wmv", "webm", "ts", "m2ts", "mpg", "mpeg",
    ]
    private let store: LibraryStore
    
    public init(store: LibraryStore) {
        self.store = store
    }
    
    public func scan(at rootURL: URL) async throws {
        let fileManager = FileManager.default
        var failedPaths: [String] = []

        // Only look for videos, skip the hidden .catalog folder
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        
        let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: options
        )
        
        while let fileURL = enumerator?.nextObject() as? URL {
            let ext = fileURL.pathExtension.lowercased()
            
            if LibraryScanner.indexableExtensions.contains(ext) {
                // Create a path relative to the drive root for portability
                let rootPath = rootURL.standardizedFileURL.path
                let filePath = fileURL.standardizedFileURL.path

                let relativePath: String
                if filePath.hasPrefix(rootPath) {
                    var rel = String(filePath.dropFirst(rootPath.count))
                    if rel.hasPrefix("/") { rel.removeFirst() } // store paths relative to the library root
                    relativePath = rel
                } else {
                    // Fallback: just use lastPathComponent
                    relativePath = fileURL.lastPathComponent
                }

                
                let asset = Asset(
                    relativePath: relativePath,
                    fileName: fileURL.lastPathComponent
                )

                // saveAsset is INSERT OR IGNORE, so re-scanning known files
                // is a no-op. One bad row must not abandon the rest of the
                // walk (DEFECT_INVENTORY L2) — collect failures, keep
                // scanning, and report the aggregate at the end.
                do {
                    try store.saveAsset(asset)
                } catch {
                    failedPaths.append(relativePath)
                }
            }
        }

        if !failedPaths.isEmpty {
            throw ScanError(failedPaths: failedPaths)
        }
    }
}

/// Files that couldn't be indexed during a scan (the rest of the scan
/// completed normally).
public struct ScanError: Error, LocalizedError {
    public let failedPaths: [String]
    public var errorDescription: String? {
        "\(failedPaths.count) file\(failedPaths.count == 1 ? "" : "s") couldn't be added to the library."
    }
}
