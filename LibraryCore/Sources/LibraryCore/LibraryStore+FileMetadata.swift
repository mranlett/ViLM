// LibraryStore+FileMetadata.swift
// Running Stage A against a real library (#9).
//
// ⚠️ The RULES live in `FileMetadataStageA`, where they are testable without a
// disk. This file is only the wiring: what the filesystem says, and where the
// answer is written. Keeping the decision out of here is what made the
// staleness comparison, the missing-file case and the cancellation semantics
// assertable at all.

import Foundation

public extension LibraryStore {

    /// Populates size and modified date for everything in this library that
    /// needs it.
    ///
    /// ⭐ No full rescan. It reads the rows it already has and stats each file,
    /// so an existing library is brought up to date without re-walking the
    /// tree or touching anything the operator has recorded.
    ///
    /// - Parameter isCancelled: checked before each file. Whatever has been
    ///   written stays written; the rest keeps falling back to reading the
    ///   file, exactly as before this existed.
    @discardableResult
    func backfillFileMetadata(libraryURL: URL,
                              isCancelled: @escaping () -> Bool = { false },
                              onProgress: (StageASummary) -> Void = { _ in })
        throws -> StageASummary {
        let assets = try fetchAllAssets()
        let manager = FileManager.default

        return try FileMetadataStageA.backfill(
            assets,
            facts: { asset in
                let path = libraryURL.appendingPathComponent(asset.relativePath).path
                guard let attributes = try? manager.attributesOfItem(atPath: path),
                      let size = (attributes[.size] as? NSNumber)?.int64Value,
                      let modified = attributes[.modificationDate] as? Date
                else { return nil }
                return FileFacts(size: size, modified: modified)
            },
            isCancelled: isCancelled,
            onProgress: onProgress,
            write: { try updateAsset($0) })
    }
}
