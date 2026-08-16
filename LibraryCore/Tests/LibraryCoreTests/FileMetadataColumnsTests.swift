// FileMetadataColumnsTests.swift
// F5/F6 — the six file-metadata columns (#8, schema v46).
//
// ⚠️ All names invented. This repository is public.

import XCTest
import GRDB
@testable import LibraryCore

final class FileMetadataColumnsTests: XCTestCase {

    private var libraryURL: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        libraryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileMeta-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        store = try LibraryStore(at: libraryURL)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: libraryURL)
    }

    private func columns() throws -> [String: Bool] {
        try store.dbQueue.read { db in
            var byName: [String: Bool] = [:]
            for row in try Row.fetchAll(db, sql: "PRAGMA table_info(assets)") {
                byName[row["name"] as String] = (row["notnull"] as Int) == 1
            }
            return byName
        }
    }

    // MARK: - The columns exist, and are nullable

    /// 🚨 NULLABLE is the requirement, not an oversight. Null means "not
    /// measured yet" and every reader falls back to the file, which is exactly
    /// what lets the expensive half be deferred, made lazy, or cancelled
    /// halfway with no schema change. A NOT NULL column would have forced the
    /// slow backfill to be part of the migration.
    func testAllSixColumnsExistAndAreNullable() throws {
        let found = try columns()
        for name in ["file_size", "modified_at", "duration", "width", "height", "codec"] {
            let notNull = try XCTUnwrap(found[name], "\(name) is missing")
            XCTAssertFalse(notNull, "\(name) must be nullable")
        }
    }

    /// A fresh row has all six null, and nothing about it is broken by that.
    func testANewAssetHasNoFileMetadataAndStillWorks() throws {
        let asset = Asset(relativePath: "a.mp4", fileName: "a.mp4")
        try store.insertAsset(asset)

        let read = try XCTUnwrap(try store.fetchAllAssets().first)
        XCTAssertNil(read.fileSize)
        XCTAssertNil(read.modifiedAt)
        XCTAssertNil(read.duration)
        XCTAssertNil(read.width)
        XCTAssertNil(read.height)
        XCTAssertNil(read.codec)
        XCTAssertEqual(read.relativePath, "a.mp4", "and the row is otherwise intact")
    }

    // MARK: - Values survive a write and a read

    func testTheSixValuesRoundTripThroughTheDatabase() throws {
        var asset = Asset(relativePath: "a.mp4", fileName: "a.mp4")
        try store.insertAsset(asset)

        asset.fileSize = 987_654_321
        asset.modifiedAt = Date(timeIntervalSince1970: 1_600_000_000)
        asset.duration = 3661.5
        asset.width = 3840
        asset.height = 2160
        asset.codec = "hvc1"
        try store.updateAsset(asset)

        let read = try XCTUnwrap(try store.fetchAllAssets().first)
        XCTAssertEqual(read.fileSize, 987_654_321)
        XCTAssertEqual(read.modifiedAt, Date(timeIntervalSince1970: 1_600_000_000))
        XCTAssertEqual(read.duration, 3661.5)
        XCTAssertEqual(read.width, 3840)
        XCTAssertEqual(read.height, 2160)
        XCTAssertEqual(read.codec, "hvc1")
    }

    /// ⚠️ A large file is bigger than `Int32`. Stored as `Int64` deliberately —
    /// a 4 GB video is ordinary in this library and a 32-bit column would wrap
    /// silently, which reads as a small file rather than as an error.
    func testAFileLargerThanFourGigabytesIsStoredExactly() throws {
        var asset = Asset(relativePath: "big.mp4", fileName: "big.mp4")
        try store.insertAsset(asset)
        asset.fileSize = 8_589_934_592  // 8 GiB
        try store.updateAsset(asset)

        XCTAssertEqual(try store.fetchAllAssets().first?.fileSize, 8_589_934_592)
    }

    // MARK: - Indexed where sorting reads

    /// ⭐ Only the two that sorting reads. An index is a write cost on every
    /// scan and the backfill touches every row, so indexing the four nothing
    /// sorts by would be paid for and never used.
    func testTheSortableColumnsAreIndexedAndTheOthersAreNot() throws {
        let indexed: Set<String> = try store.dbQueue.read { db in
            var columns: Set<String> = []
            for index in try Row.fetchAll(db, sql: "PRAGMA index_list(assets)") {
                let name = index["name"] as String
                for info in try Row.fetchAll(db, sql: "PRAGMA index_info(\(name))") {
                    if let column = info["name"] as String? { columns.insert(column) }
                }
            }
            return columns
        }

        XCTAssertTrue(indexed.contains("file_size"))
        XCTAssertTrue(indexed.contains("duration"))
        for unsorted in ["width", "height", "codec", "modified_at"] {
            XCTAssertFalse(indexed.contains(unsorted),
                           "\(unsorted) is not sorted by and should not carry an index")
        }
    }

    // MARK: - 🚨 An existing library keeps its data

    /// The migration runs against libraries that already hold everything the
    /// operator has done. Adding columns must not disturb a single row.
    func testAnExistingLibraryMigratesWithoutLosingAnything() throws {
        let asset = Asset(relativePath: "kept.mp4", fileName: "kept.mp4",
                          tags: ["actor:Alice Example"], notes: "a private note",
                          rating: 4, episode: "Late Checkout",
                          contentKind: .scene, releaseDate: "2019-04-12")
        try store.insertAsset(asset)

        // Re-opening runs the migrator again against a populated database,
        // which is what an upgrade does.
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        store = try LibraryStore(at: libraryURL)

        let read = try XCTUnwrap(try store.fetchAllAssets().first)
        XCTAssertEqual(read.relativePath, "kept.mp4")
        XCTAssertEqual(read.tags, ["actor:Alice Example"])
        XCTAssertEqual(read.notes, "a private note")
        XCTAssertEqual(read.rating, 4)
        XCTAssertEqual(read.episode, "Late Checkout")
        XCTAssertEqual(read.contentKind, .scene)
        XCTAssertEqual(read.releaseDate, "2019-04-12")
    }

    /// Safely re-runnable: opening the library repeatedly must not fail on an
    /// already-applied migration or a duplicate index.
    func testOpeningTheLibraryRepeatedlyIsSafe() throws {
        for _ in 0..<3 {
            store = nil
            LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
            store = try LibraryStore(at: libraryURL)
        }
        XCTAssertNoThrow(try store.fetchAllAssets())
    }
}
