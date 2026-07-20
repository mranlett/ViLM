import XCTest
@testable import LibraryCore

/// Real round-trip integration tests for backup export → verify → restore.
/// Uses AppleArchive against real temp files (like the transfer service's
/// end-to-end move test).
final class LibraryBackupServiceTests: XCTestCase {

    private var tempDir: URL!
    private let service = LibraryBackupService()

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryBackupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeLibrary(_ name: String) throws -> URL {
        let url = tempDir.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testExportThenRestoreIntoEmptyRoundTrips() throws {
        // Source library: two assets + an entity profile + a cached thumbnail.
        let src = try makeLibrary("src")
        let store = try LibraryStore(at: src)
        try store.saveAsset(Asset(relativePath: "a.mp4", fileName: "a.mp4"))
        try store.saveAsset(Asset(relativePath: "b.mp4", fileName: "b.mp4"))
        try store.saveEntityProfile(EntityProfile(id: "actor:Jane Doe", bio: "kept"))
        let thumbs = src.appendingPathComponent(".catalog/thumbnails")
        try FileManager.default.createDirectory(at: thumbs, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: thumbs.appendingPathComponent("poster.jpg"))

        let result = try service.exportBackup(of: src)
        XCTAssertEqual(result.assetCount, 2, "verification reads the archived asset count")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.archiveURL.path))

        // Restore into a brand-new empty folder.
        let dst = try makeLibrary("dst")
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try service.restoreIntoEmpty(archiveURL: result.archiveURL, targetLibraryURL: dst)

        let restored = try LibraryStore(at: dst)
        XCTAssertEqual(Set(try restored.fetchAllAssets().map(\.relativePath)), ["a.mp4", "b.mp4"])
        XCTAssertEqual(try restored.fetchEntityProfile(for: "actor:Jane Doe")?.bio, "kept")
        // The cached thumbnail image survived the round trip byte-for-byte.
        let restoredThumb = dst.appendingPathComponent(".catalog/thumbnails/poster.jpg")
        XCTAssertEqual(try Data(contentsOf: restoredThumb), Data([1, 2, 3]))
    }

    func testRestoreRefusesANonEmptyTarget() throws {
        let src = try makeLibrary("src")
        _ = try LibraryStore(at: src) // gives it a .catalog
        let result = try service.exportBackup(of: src)

        // Target already has a catalog → must refuse (this is the empty-only path).
        let dst = try makeLibrary("dst")
        _ = try LibraryStore(at: dst)
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)

        XCTAssertThrowsError(try service.restoreIntoEmpty(archiveURL: result.archiveURL, targetLibraryURL: dst)) {
            XCTAssertEqual($0 as? LibraryBackupError, .targetNotEmpty)
        }
    }

    func testExportRequiresACatalog() throws {
        let bare = try makeLibrary("bare") // no .catalog created
        XCTAssertThrowsError(try service.exportBackup(of: bare)) {
            XCTAssertEqual($0 as? LibraryBackupError, .catalogMissing)
        }
    }

    func testRestoreOverExistingMergesInsertsAndKeepsCaseA() throws {
        // Library at backup time: A (rating 4, tag:X) and B.
        let lib = try makeLibrary("lib")
        let store = try LibraryStore(at: lib)
        let aID = UUID(), bID = UUID()
        try store.insertAsset(Asset(id: aID, relativePath: "a.mp4", fileName: "a.mp4",
                                    tags: ["tag:X"], rating: 4))
        try store.insertAsset(Asset(id: bID, relativePath: "b.mp4", fileName: "b.mp4"))
        let backup = try service.exportBackup(of: lib)

        // After the backup: B deleted, A re-rated + re-tagged, and a new C added.
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        let store2 = try LibraryStore(at: lib)
        try store2.deleteAsset(Asset(id: bID, relativePath: "b.mp4", fileName: "b.mp4"))
        var a = try XCTUnwrap(store2.fetchAllAssets().first { $0.id == aID })
        a.rating = 2; a.tags = ["tag:X", "tag:Y"]
        try store2.updateAsset(a)
        let cID = UUID()
        try store2.insertAsset(Asset(id: cID, relativePath: "c.mp4", fileName: "c.mp4"))

        // Preview: B is re-insertable (new), A is an update, C is destination-only.
        let plan = try service.planRestore(archiveURL: backup.archiveURL, destinationLibraryURL: lib)
        XCTAssertEqual(plan.newAssetCount, 1)
        XCTAssertEqual(plan.updatedAssetCount, 1)
        XCTAssertEqual(plan.destinationOnlyAssets.map(\.id), [cID])

        // Apply, keeping C.
        let result = try service.applyRestoreOverExisting(
            archiveURL: backup.archiveURL, destinationLibraryURL: lib, discardAssetIDs: [])
        XCTAssertEqual(result.insertedAssets, 1)
        XCTAssertEqual(result.mergedAssets, 1)

        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        let after = Dictionary(uniqueKeysWithValues: try LibraryStore(at: lib).fetchAllAssets().map { ($0.id, $0) })
        XCTAssertNotNil(after[bID], "B was re-inserted from the archive")
        XCTAssertEqual(after[aID]?.rating, 4, "the archive's rating wins the conflict")
        XCTAssertEqual(Set(after[aID]?.tags ?? []), ["tag:X", "tag:Y"], "tags are unioned, not reverted")
        XCTAssertNotNil(after[cID], "the destination-only video is kept by default")
    }

    func testRestoreOverExistingCanDiscardACaseAVideo() throws {
        let lib = try makeLibrary("lib")
        let store = try LibraryStore(at: lib)
        try store.insertAsset(Asset(relativePath: "a.mp4", fileName: "a.mp4"))
        let backup = try service.exportBackup(of: lib)

        // Add a destination-only video after the backup, then discard it on restore.
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        let store2 = try LibraryStore(at: lib)
        let cID = UUID()
        try store2.insertAsset(Asset(id: cID, relativePath: "c.mp4", fileName: "c.mp4"))

        _ = try service.applyRestoreOverExisting(
            archiveURL: backup.archiveURL, destinationLibraryURL: lib, discardAssetIDs: [cID])

        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        XCTAssertFalse(try LibraryStore(at: lib).fetchAllAssets().contains { $0.id == cID },
                       "a discarded Case-A video is removed")
    }

    func testRestoredArchiveIsIndependentOfTheSource() throws {
        // Editing the source after export must not affect the restored copy.
        let src = try makeLibrary("src")
        let store = try LibraryStore(at: src)
        try store.saveAsset(Asset(relativePath: "a.mp4", fileName: "a.mp4"))
        let result = try service.exportBackup(of: src)

        // Mutate the source post-export.
        try store.saveAsset(Asset(relativePath: "added-after.mp4", fileName: "added-after.mp4"))

        let dst = try makeLibrary("dst")
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try service.restoreIntoEmpty(archiveURL: result.archiveURL, targetLibraryURL: dst)

        // Restore reflects the snapshot at export time, not the later edit.
        XCTAssertEqual(Set(try LibraryStore(at: dst).fetchAllAssets().map(\.relativePath)), ["a.mp4"])
    }
}
