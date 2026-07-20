// LibraryBackupService.swift
// Manual backup/restore of a library's `.catalog` (SQLite + thumbnails +
// profile/marker images) as a single compressed `.vilmbackup` archive. Video
// files are deliberately excluded — this is catalog durability, not media
// backup. Uses AppleArchive (dependency-free, and symmetric: it both
// compresses and extracts, unlike NSFileCoordinator `.forUploading`, which can
// only zip). v1 scope: export + verify + restore into an empty library; restore
// *over* an existing library (field merge) is a separate, later milestone.

import Foundation
import AppleArchive
import System

public enum LibraryBackupError: Error, Equatable {
    case catalogMissing
    case archiveFailed
    case extractFailed
    case verificationFailed
    case targetNotEmpty
}

public struct LibraryBackupResult: Sendable {
    public let archiveURL: URL
    /// Asset count read back from the *verified* archive.
    public let assetCount: Int
}

public struct LibraryBackupService {
    public init() {}

    private static let catalogDirName = ".catalog"

    // MARK: - Export

    /// Compresses `libraryURL`'s `.catalog` into a `.vilmbackup` archive in the
    /// temp directory, verifies it re-opens cleanly, and returns the archive URL
    /// (ready to hand to a save sheet). Throws if the archive can't be produced
    /// or fails verification.
    public func exportBackup(of libraryURL: URL) throws -> LibraryBackupResult {
        let catalogURL = libraryURL.appendingPathComponent(Self.catalogDirName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: catalogURL.path) else {
            throw LibraryBackupError.catalogMissing
        }

        // Merge the WAL into the main DB so the archived catalog.sqlite is
        // complete and consistent on its own.
        try? LibraryStore(at: libraryURL).checkpointWAL()

        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vilmbackup-\(UUID().uuidString).vilmbackup")
        try? FileManager.default.removeItem(at: archiveURL)
        try Self.compress(directoryContentsOf: catalogURL, to: archiveURL)

        // Post-write verification: a silently-corrupt backup would defeat the
        // whole purpose, so extract to scratch and re-open the database.
        let count = try Self.verify(archiveURL: archiveURL)
        return LibraryBackupResult(archiveURL: archiveURL, assetCount: count)
    }

    // MARK: - Restore (into a brand-new / empty library)

    /// Restores `archiveURL` into `targetLibraryURL`, which must not already
    /// contain a `.catalog`. After this returns, the caller should open the
    /// library and run "Check for Changes" so records whose video files aren't
    /// present get flagged missing (normal reconciliation).
    public func restoreIntoEmpty(archiveURL: URL, targetLibraryURL: URL) throws {
        let targetCatalog = targetLibraryURL.appendingPathComponent(Self.catalogDirName, isDirectory: true)
        if FileManager.default.fileExists(atPath: targetCatalog.path) {
            throw LibraryBackupError.targetNotEmpty
        }
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try FileManager.default.createDirectory(at: targetCatalog, withIntermediateDirectories: true)
        try Self.extract(archiveURL: archiveURL, into: targetCatalog)
        // It must open (and migrate) cleanly.
        _ = try LibraryStore(at: targetLibraryURL).fetchAllAssets()
    }

    // MARK: - Restore over an existing library (merge)

    public struct LibraryRestorePlan: Sendable {
        public let newAssetCount: Int          // in the archive, not yet in the library → inserted
        public let updatedAssetCount: Int      // in both → field-merged
        public let destinationOnlyAssets: [Asset]  // Case A: in the library, not in the archive
        public let newActorCount: Int
        public let updatedActorCount: Int
    }

    public struct LibraryRestoreResult: Sendable {
        public let insertedAssets: Int
        public let mergedAssets: Int
        public let discardedAssets: Int
        public let newActors: Int
        public let updatedActors: Int
    }

    /// Previews a restore into a *non-empty* library without writing anything:
    /// how many videos would be inserted vs. field-merged, and which
    /// destination-only videos (added since the backup) need a keep/discard
    /// decision.
    public func planRestore(archiveURL: URL, destinationLibraryURL: URL) throws -> LibraryRestorePlan {
        try withExtractedArchive(archiveURL) { archiveStore in
            LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
            let destStore = try LibraryStore(at: destinationLibraryURL)
            let archiveAssets = try archiveStore.fetchAllAssets()
            let destAssets = try destStore.fetchAllAssets()
            let archiveIDs = Set(archiveAssets.map(\.id))
            let destIDs = Set(destAssets.map(\.id))

            let actorPlan = try destStore.planActorMerge(try archiveStore.exportActorLibrary())

            return LibraryRestorePlan(
                newAssetCount: archiveAssets.filter { !destIDs.contains($0.id) }.count,
                updatedAssetCount: archiveAssets.filter { destIDs.contains($0.id) }.count,
                destinationOnlyAssets: destAssets.filter { !archiveIDs.contains($0.id) }
                    .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending },
                newActorCount: actorPlan.newActorCount,
                updatedActorCount: actorPlan.updatedActorCount)
        }
    }

    /// Merges an archive into an existing library: archive-only videos are
    /// inserted; videos in both are field-merged non-destructively (a real
    /// archive value wins a conflict, progress fields never regress, tags are
    /// unioned); actor profiles/photos reuse the Actor Merge engine; scene
    /// markers and smart collections are unioned; cached images are copied
    /// additively (never overwriting the library's current ones). Case A
    /// (destination-only) videos are kept unless their id is in `discardAssetIDs`.
    @discardableResult
    public func applyRestoreOverExisting(
        archiveURL: URL, destinationLibraryURL: URL, discardAssetIDs: Set<UUID> = []
    ) throws -> LibraryRestoreResult {
        try withExtractedArchive(archiveURL) { archiveStore in
            LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
            let destStore = try LibraryStore(at: destinationLibraryURL)
            let archiveAssets = try archiveStore.fetchAllAssets()
            let destByID = Dictionary(uniqueKeysWithValues: try destStore.fetchAllAssets().map { ($0.id, $0) })

            var inserted = 0, merged = 0, discarded = 0

            // Assets: insert new, field-merge shared.
            for asset in archiveAssets {
                if let existing = destByID[asset.id] {
                    try destStore.updateAsset(MergeSemantics.mergeAsset(source: asset, into: existing))
                    merged += 1
                } else {
                    try destStore.insertAsset(asset)
                    inserted += 1
                }
                // Scene markers for this asset: union by id (archive adds only).
                let existingMarkerIDs = Set(((try? destStore.fetchSceneMarkers(for: asset.id)) ?? []).map(\.id))
                for marker in (try? archiveStore.fetchSceneMarkers(for: asset.id)) ?? []
                where !existingMarkerIDs.contains(marker.id) {
                    try? destStore.saveSceneMarker(marker)
                }
            }

            // Smart collections: union by id.
            let existingCollectionIDs = Set(((try? destStore.fetchAllSmartCollections()) ?? []).map(\.id))
            for collection in (try? archiveStore.fetchAllSmartCollections()) ?? []
            where !existingCollectionIDs.contains(collection.id) {
                try? destStore.saveSmartCollection(collection)
            }

            // Actor profiles + photos: the full Actor Merge engine.
            let actorResult = try destStore.applyActorMerge(try archiveStore.exportActorLibrary())

            // Cached visuals: copy archive files that the library doesn't have
            // (new assets' thumbnails), never overwriting current ones.
            let archiveCatalog = archiveStore.libraryURL.appendingPathComponent(Self.catalogDirName)
            let destCatalog = destinationLibraryURL.appendingPathComponent(Self.catalogDirName)
            for subdir in ["thumbnails", "contactSheets", "markers"] {
                Self.copyMissingFiles(from: archiveCatalog.appendingPathComponent(subdir),
                                      to: destCatalog.appendingPathComponent(subdir))
            }

            // Case A discards (destination-only videos the user chose to drop).
            for id in discardAssetIDs {
                if let asset = destByID[id] {
                    try? destStore.deleteAsset(asset) // cascade-deletes its markers
                    discarded += 1
                }
            }

            return LibraryRestoreResult(
                insertedAssets: inserted, mergedAssets: merged, discardedAssets: discarded,
                newActors: actorResult.newActorCount, updatedActors: actorResult.updatedActorCount)
        }
    }

    /// Extracts `archiveURL` to a scratch library, runs `body` with a store
    /// opened on it, and cleans up.
    private func withExtractedArchive<T>(_ archiveURL: URL, _ body: (LibraryStore) throws -> T) throws -> T {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("vilmbackup-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let scratchCatalog = scratch.appendingPathComponent(Self.catalogDirName, isDirectory: true)
        try FileManager.default.createDirectory(at: scratchCatalog, withIntermediateDirectories: true)
        try Self.extract(archiveURL: archiveURL, into: scratchCatalog)
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        let result = try body(try LibraryStore(at: scratch))
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        return result
    }

    private static func copyMissingFiles(from sourceDir: URL, to destDir: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: sourceDir.path) else { return }
        try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        for name in names {
            let dest = destDir.appendingPathComponent(name)
            guard !fm.fileExists(atPath: dest.path) else { continue }
            try? fm.copyItem(at: sourceDir.appendingPathComponent(name), to: dest)
        }
    }

    // MARK: - Verify

    private static func verify(archiveURL: URL) throws -> Int {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("vilmbackup-verify-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let scratchCatalog = scratch.appendingPathComponent(catalogDirName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: scratchCatalog, withIntermediateDirectories: true)
            try extract(archiveURL: archiveURL, into: scratchCatalog)
            LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
            let count = try LibraryStore(at: scratch).fetchAllAssets().count
            LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
            return count
        } catch {
            throw LibraryBackupError.verificationFailed
        }
    }

    // MARK: - AppleArchive compress / extract

    private static func compress(directoryContentsOf directory: URL, to dest: URL) throws {
        let keySet = ArchiveHeader.FieldKeySet("TYP,PAT,LNK,DEV,DAT,UID,GID,MOD,FLG,MTM,CTM,BTM,SIZ")!
        guard let writeStream = ArchiveByteStream.fileStream(
                path: FilePath(dest.path), mode: .writeOnly, options: [.create, .truncate],
                permissions: FilePermissions(rawValue: 0o644)),
              let compressStream = ArchiveByteStream.compressionStream(using: .lzfse, writingTo: writeStream),
              let encodeStream = ArchiveStream.encodeStream(writingTo: compressStream)
        else { throw LibraryBackupError.archiveFailed }
        // Close inner-to-outer so each stream flushes into the next.
        defer {
            try? encodeStream.close()
            try? compressStream.close()
            try? writeStream.close()
        }
        do {
            try encodeStream.writeDirectoryContents(archiveFrom: FilePath(directory.path), keySet: keySet)
        } catch {
            throw LibraryBackupError.archiveFailed
        }
    }

    private static func extract(archiveURL: URL, into destinationDir: URL) throws {
        guard let readStream = ArchiveByteStream.fileStream(
                path: FilePath(archiveURL.path), mode: .readOnly, options: [],
                permissions: FilePermissions(rawValue: 0o644)),
              let decompressStream = ArchiveByteStream.decompressionStream(readingFrom: readStream),
              let decodeStream = ArchiveStream.decodeStream(readingFrom: decompressStream),
              let extractStream = ArchiveStream.extractStream(
                extractingTo: FilePath(destinationDir.path), flags: [.ignoreOperationNotPermitted])
        else { throw LibraryBackupError.extractFailed }
        defer {
            try? extractStream.close()
            try? decodeStream.close()
            try? decompressStream.close()
            try? readStream.close()
        }
        do {
            _ = try ArchiveStream.process(readingFrom: decodeStream, writingTo: extractStream)
        } catch {
            throw LibraryBackupError.extractFailed
        }
    }
}
