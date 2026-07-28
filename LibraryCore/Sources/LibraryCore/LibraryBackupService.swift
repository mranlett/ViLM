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

    /// Test seam (default-preserving, like `fileRemover`): called after each
    /// asset's rows are written inside the restore-merge transaction. Tests
    /// inject a throw partway through to prove a mid-merge failure rolls the
    /// entire merge back instead of committing a half-merged library.
    var postAssetWriteHook: ((Asset) throws -> Void)? = nil

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

        // Stage the catalog for archiving. The DATABASE goes through SQLite's
        // online backup API (a consistent committed state even while
        // background writes — thumbnail generation, imports — are in flight);
        // it used to be file-copied raw alongside its WAL, a torn-copy risk,
        // "mitigated" by a checkpoint whose failure was swallowed
        // (DEFECT_INVENTORY H2). Errors here now propagate — no silent
        // fallback to an unsafe copy. Image files are copied as files:
        // they're written whole then never mutated, so a plain copy is safe.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("vilmbackup-staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        try LibraryStore(at: libraryURL)
            .snapshotDatabase(to: staging.appendingPathComponent("catalog.sqlite"))

        // Live DB sidecars are superseded by the snapshot; `editing/` holds
        // transient in-progress edit copies that don't belong in a backup.
        let excluded: Set<String> = ["catalog.sqlite", "catalog.sqlite-wal", "catalog.sqlite-shm", "editing"]
        for name in try FileManager.default.contentsOfDirectory(atPath: catalogURL.path)
        where !excluded.contains(name) {
            try FileManager.default.copyItem(
                at: catalogURL.appendingPathComponent(name),
                to: staging.appendingPathComponent(name))
        }

        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vilmbackup-\(UUID().uuidString).vilmbackup")
        try? FileManager.default.removeItem(at: archiveURL)
        try Self.compress(directoryContentsOf: staging, to: archiveURL)

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
        // Extract to scratch and move into place only on success: a failed
        // extraction (corrupt archive, disk full) must not leave a partial
        // `.catalog` in the target, which would make every retry fail with a
        // misleading `.targetNotEmpty` (DEFECT_INVENTORY M2).
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("vilmbackup-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let scratchCatalog = scratch.appendingPathComponent(Self.catalogDirName, isDirectory: true)
        try FileManager.default.createDirectory(at: scratchCatalog, withIntermediateDirectories: true)
        try Self.extract(archiveURL: archiveURL, into: scratchCatalog)

        // It must open (and migrate) cleanly — validated on the scratch copy,
        // before anything touches the target. Checkpoint the WAL the
        // validation opened (merging any migration writes into the main
        // file), evict the scratch connection, and drop the now-redundant
        // sidecars so they don't travel with the move — SQLite's close
        // doesn't reliably unlink them. Targeted evictions only: sweeping
        // the whole cache would disconnect the active library out from
        // under in-flight work (H6). The target path is evicted too, in
        // case an earlier library lived at the same folder.
        let validationStore = try LibraryStore(at: scratch)
        _ = try validationStore.fetchAllAssets()
        try validationStore.checkpointWAL()
        LibraryStore.evictCachedConnection(forLibraryAt: scratch)
        LibraryStore.evictCachedConnection(forLibraryAt: targetLibraryURL)
        for sidecar in ["catalog.sqlite-wal", "catalog.sqlite-shm"] {
            try? FileManager.default.removeItem(at: scratchCatalog.appendingPathComponent(sidecar))
        }

        do {
            try FileManager.default.moveItem(at: scratchCatalog, to: targetCatalog)
        } catch {
            // A cross-volume move is copy-then-delete; clean up any partial
            // copy so the target folder stays retryable.
            try? FileManager.default.removeItem(at: targetCatalog)
            throw error
        }
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
            let destStore = try LibraryStore(at: destinationLibraryURL)

            // Gather everything from the archive up front (reads on a separate
            // scratch database) so the destination's write phase below stays
            // short and purely local.
            let archiveAssets = try archiveStore.fetchAllAssets()
            var archiveMarkers: [Asset.ID: [SceneMarker]] = [:]
            for asset in archiveAssets {
                archiveMarkers[asset.id] = try archiveStore.fetchSceneMarkers(for: asset.id)
            }
            let archiveCollections = try archiveStore.fetchAllSmartCollections()
            let actorExport = try archiveStore.exportActorLibrary()

            let destAssets = try destStore.fetchAllAssets()
            let destByID = Dictionary(uniqueKeysWithValues: destAssets.map { ($0.id, $0) })
            // relative_path is UNIQUE — an archived asset whose path is now
            // occupied by a *different* asset (file re-added/renamed since the
            // backup) must not abort the merge with a constraint violation
            // (DEFECT_INVENTORY H4); it gets a "-restored" suffixed path and
            // its file reconnects via Check for Changes like any restored row.
            var takenPaths = Set(destAssets.map(\.relativePath))

            var inserted = 0, merged = 0, discarded = 0

            // The entire destination write phase is ONE transaction
            // (DEFECT_INVENTORY H3): any mid-merge error — disk full, scope
            // revocation, a bad record — rolls everything back instead of
            // committing a half-merged library, and the former `try?` unions
            // now propagate instead of failing silently. Actor photo writes
            // inside the actor merge are additive/content-addressed, so
            // orphaned files from a rollback are harmless.
            let actorResult = try destStore.performInTransaction { db in
                // Assets: insert new, field-merge shared.
                for asset in archiveAssets {
                    if let existing = destByID[asset.id] {
                        try destStore.updateAsset(MergeSemantics.mergeAsset(source: asset, into: existing), in: db)
                        merged += 1
                    } else {
                        var adjusted = asset
                        if takenPaths.contains(adjusted.relativePath) {
                            let ext = (adjusted.relativePath as NSString).pathExtension
                            let base = (adjusted.relativePath as NSString).deletingPathExtension
                            var candidate = ext.isEmpty ? "\(base)-restored" : "\(base)-restored.\(ext)"
                            var n = 1
                            while takenPaths.contains(candidate) {
                                n += 1
                                candidate = ext.isEmpty ? "\(base)-restored-\(n)" : "\(base)-restored-\(n).\(ext)"
                            }
                            adjusted.relativePath = candidate
                        }
                        try destStore.insertAsset(adjusted, in: db)
                        takenPaths.insert(adjusted.relativePath)
                        inserted += 1
                    }
                    // Scene markers for this asset: union by id (archive adds only).
                    let existingMarkerIDs = Set(try destStore.fetchSceneMarkers(for: asset.id, in: db).map(\.id))
                    for marker in archiveMarkers[asset.id] ?? []
                    where !existingMarkerIDs.contains(marker.id) {
                        try destStore.saveSceneMarker(marker, in: db)
                    }
                    try postAssetWriteHook?(asset)
                }

                // Smart collections: union by id.
                let existingCollectionIDs = Set(try destStore.fetchAllSmartCollections(in: db).map(\.id))
                for collection in archiveCollections
                where !existingCollectionIDs.contains(collection.id) {
                    try destStore.saveSmartCollection(collection, in: db)
                }

                // Actor profiles + photos: the full Actor Merge engine.
                let actorResult = try destStore.applyActorMerge(actorExport, in: db)

                // Case A discards (destination-only videos the user chose to drop).
                for id in discardAssetIDs {
                    if let asset = destByID[id] {
                        try destStore.deleteAsset(asset, in: db) // cascade-deletes its markers
                        discarded += 1
                    }
                }

                return actorResult
            }

            // Cached visuals: copy archive files that the library doesn't have
            // (new assets' thumbnails), never overwriting current ones.
            // Additive file copies stay outside the transaction by design.
            let archiveCatalog = archiveStore.libraryURL.appendingPathComponent(Self.catalogDirName)
            let destCatalog = destinationLibraryURL.appendingPathComponent(Self.catalogDirName)
            for subdir in ["thumbnails", "contactSheets", "markers"] {
                Self.copyMissingFiles(from: archiveCatalog.appendingPathComponent(subdir),
                                      to: destCatalog.appendingPathComponent(subdir))
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
        // Evict only the scratch connection when done — declared after the
        // removeItem defer above so it runs first (defers unwind LIFO), i.e.
        // WAL handles close before the directory is deleted. Never sweep the
        // whole cache here: the destination library keeps using its shared
        // connection (DEFECT_INVENTORY H6).
        defer { LibraryStore.evictCachedConnection(forLibraryAt: scratch) }
        return try body(try LibraryStore(at: scratch))
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
            defer { LibraryStore.evictCachedConnection(forLibraryAt: scratch) }
            let store = try LibraryStore(at: scratch)
            // Structural corruption check, not just "the rows parse" — a
            // backup must never verify green while carrying a damaged B-tree.
            try store.runIntegrityCheck()
            return try store.fetchAllAssets().count
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
