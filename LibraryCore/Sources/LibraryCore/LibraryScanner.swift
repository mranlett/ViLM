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
    
    /// Walks the library and indexes what it finds.
    ///
    /// 🚨 S1 — a file arriving with a sidecar and NO catalogue record takes the
    /// sidecar's values (#74). A file that already has a record does not: the
    /// database wins, and the document is not consulted at all. That is the
    /// directional rule, and the `known` set below is what enforces it — it is
    /// read once, before the walk, so "already known" means known *before this
    /// scan started* rather than whatever the walk has inserted so far.
    ///
    /// ⚠️ The reader is a parameter with a real default. It is the only way to
    /// test the rule without a disk, and the default means no caller has to
    /// know the seam exists.
    @discardableResult
    public func scan(at rootURL: URL,
                     readSidecar: (String, URL) -> SidecarContents? = SidecarReader.read(besideVideo:in:))
        async throws -> ScanSummary {
        let fileManager = FileManager.default
        var failedPaths: [String] = []
        var summary = ScanSummary()
        let known = Set((try? store.fetchAllAssets())?.map(\.relativePath) ?? [])

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

                
                var asset = Asset(
                    relativePath: relativePath,
                    fileName: fileURL.lastPathComponent
                )

                // 🚨 Only for a file with no record. A known file keeps what
                // the catalogue says, and its sidecar is not even read —
                // reconciling an existing record is a different job with a
                // different answer, and doing it here would quietly make the
                // document authoritative.
                //
                // ⚠️ `applying` is called directly and `SidecarImport.decide`
                // is bypassed ON PURPOSE (#78). `decide` handles the
                // record-exists case by reporting differences, and there is
                // nowhere to report to — so the branch stays unreachable
                // rather than half-built. See the note on `decide` for what
                // would have to be answered before wiring it.
                var imported = false
                if !known.contains(relativePath),
                   let contents = readSidecar(relativePath, rootURL) {
                    asset = SidecarImport.applying(contents, to: asset)
                    imported = true
                }

                // F5 Stage A (#9) — the size and date, from the stat the
                // enumerator has effectively already paid for. Recording it
                // here is what stops a later sort re-reading every file.
                //
                // ⭐ Only for a new file. A known file's row is not touched by a
                // scan; keeping it current is the backfill's job, and doing it
                // in both places would mean a scan silently rewriting rows.
                var measured = false
                if !known.contains(relativePath),
                   let facts = try? FileManager.default.attributesOfItem(atPath: fileURL.path) {
                    asset.fileSize = (facts[.size] as? NSNumber)?.int64Value
                    asset.modifiedAt = facts[.modificationDate] as? Date
                    measured = asset.fileSize != nil || asset.modifiedAt != nil
                }

                // saveAsset is INSERT OR IGNORE, so re-scanning known files
                // is a no-op. One bad row must not abandon the rest of the
                // walk (DEFECT_INVENTORY L2) — collect failures, keep
                // scanning, and report the aggregate at the end.
                do {
                    try store.saveAsset(asset)
                    if !known.contains(relativePath) { summary.added += 1 }

                    // ⚠️ `saveAsset` is the minimal scan insert — it writes the
                    // path and nothing else, and hard-codes empty tags. So the
                    // imported values need a second write, and it must come
                    // AFTER the insert. Keyed by the id this scan generated: if
                    // the insert was ignored because a row already existed,
                    // that row has a different id and this updates nothing,
                    // which is the correct outcome for a file that turned out
                    // to be known after all.
                    if imported || measured {
                        try store.updateAsset(asset)
                        if imported { summary.importedFromSidecar += 1 }
                        if measured { summary.measured += 1 }
                    }
                } catch {
                    failedPaths.append(relativePath)
                }
            }
        }

        if !failedPaths.isEmpty {
            throw ScanError(failedPaths: failedPaths)
        }
        return summary
    }
}

/// What a scan did.
///
/// ⚠️ `importedFromSidecar` is counted because it is the one thing a scan now
/// does that the operator did not ask for file by file. A scan that silently
/// took values out of documents it found would be indistinguishable from one
/// that read nothing.
public struct ScanSummary: Equatable, Sendable {
    public var added = 0
    public var importedFromSidecar = 0
    /// New files whose size and modified date were recorded during the walk
    /// (F5 Stage A). Existing rows are the backfill's job, not the scan's.
    public var measured = 0
    public init() {}
}

/// Files that couldn't be indexed during a scan (the rest of the scan
/// completed normally).
public struct ScanError: Error, LocalizedError {
    public let failedPaths: [String]
    public var errorDescription: String? {
        "\(failedPaths.count) file\(failedPaths.count == 1 ? "" : "s") couldn't be added to the library."
    }
}
