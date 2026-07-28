import XCTest
@testable import LibraryCore

/// Rename consistency: file+DB never disagree (rollback on DB failure), and
/// the duplicate-scan fingerprint follows the file to its new path.
final class FileRenamerServiceTests: XCTestCase {

    private var lib: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        lib = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileRenamerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        store = try LibraryStore(at: lib)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: lib)
    }

    func testRenameCarriesTheFingerprintToTheNewPath() throws {
        try Data([1, 2, 3]).write(to: lib.appendingPathComponent("old.mp4"))
        var asset = Asset(relativePath: "old.mp4", fileName: "old.mp4")
        try store.insertAsset(asset)

        var prints = FrameFingerprintStore(libraryURL: lib)
        prints.setHashes([7, 8, 9], relativePath: "old.mp4", sizeBytes: 3, modified: 100)
        prints.save()

        try FileRenamerService(store: store).rename(asset: &asset, newFileName: "new.mp4", libraryURL: lib)

        let reloaded = FrameFingerprintStore(libraryURL: lib)
        XCTAssertEqual(reloaded.validHashes(relativePath: "new.mp4", sizeBytes: 3, modified: 100), [7, 8, 9],
                       "a rename must not cost a re-fingerprint")
        XCTAssertNil(reloaded.entries["old.mp4"], "the old-path entry doesn't linger")
        XCTAssertEqual(asset.relativePath, "new.mp4")
    }

    func testFailedDBUpdateRollsTheFileMoveBack() throws {
        // The asset was never inserted, so updateAsset throws (no row to
        // update) — the file must be moved back so disk and catalog agree.
        try Data([1]).write(to: lib.appendingPathComponent("a.mp4"))
        var asset = Asset(relativePath: "a.mp4", fileName: "a.mp4")

        XCTAssertThrowsError(
            try FileRenamerService(store: store).rename(asset: &asset, newFileName: "b.mp4", libraryURL: lib))

        XCTAssertTrue(FileManager.default.fileExists(atPath: lib.appendingPathComponent("a.mp4").path),
                      "the file returns to its original path on rollback")
        XCTAssertFalse(FileManager.default.fileExists(atPath: lib.appendingPathComponent("b.mp4").path))
        XCTAssertEqual(asset.relativePath, "a.mp4", "the in-memory asset reverts too")
    }

    func testEditRefreshClearsAStaleFingerprintForUnreadableOutput() async throws {
        // A stale entry exists for a path whose (junk) file can't be
        // fingerprinted — the refresh must clear it so the next scan retries
        // instead of matching against pre-edit hashes.
        try Data([0, 1]).write(to: lib.appendingPathComponent("clip.mp4"))
        var prints = FrameFingerprintStore(libraryURL: lib)
        prints.setHashes([1, 2, 3], relativePath: "clip.mp4", sizeBytes: 999, modified: 1)
        prints.save()

        await VideoEditingService.refreshFingerprint(relativePath: "clip.mp4", in: lib)

        XCTAssertNil(FrameFingerprintStore(libraryURL: lib).entries["clip.mp4"],
                     "an unreadable post-edit file clears the stale entry")
    }
}
