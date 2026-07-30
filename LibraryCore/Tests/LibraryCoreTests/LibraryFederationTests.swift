import XCTest
@testable import LibraryCore

/// The pure union-admission logic for the multi-library session: an attaching
/// library's rows either join the union or are hidden because an open library
/// already has the identical row id (backup-cloned libraries).
final class LibraryFederationTests: XCTestCase {

    private func asset(_ name: String, id: UUID = UUID()) -> Asset {
        Asset(id: id, relativePath: name, fileName: name)
    }

    func testDisjointLibrariesAllJoinTheUnion() {
        let incoming = [asset("a.mp4"), asset("b.mp4")]
        let result = LibraryFederation.partitionForUnion(
            incoming: incoming, existingIDs: [UUID(), UUID()])
        XCTAssertEqual(result.included.map(\.relativePath), ["a.mp4", "b.mp4"], "order preserved")
        XCTAssertTrue(result.excludedIDs.isEmpty)
    }

    func testClonedRowsAreExcludedAndCounted() {
        // A backup-restored copy shares row ids with the original.
        let sharedID = UUID()
        let incoming = [asset("clone.mp4", id: sharedID), asset("unique.mp4")]
        let result = LibraryFederation.partitionForUnion(
            incoming: incoming, existingIDs: [sharedID])
        XCTAssertEqual(result.included.map(\.relativePath), ["unique.mp4"],
                       "the higher-precedence copy wins; the clone is hidden")
        XCTAssertEqual(result.excludedIDs, [sharedID])
    }

    func testEmptyIncomingIsANoOp() {
        let result = LibraryFederation.partitionForUnion(incoming: [], existingIDs: [UUID()])
        XCTAssertTrue(result.included.isEmpty)
        XCTAssertTrue(result.excludedIDs.isEmpty)
    }

    func testSetEvictionKeepsEveryOpenLibrary() throws {
        // Three libraries open (primary + two attachments): a keep-set evict
        // must drop none of them and remain non-destructive for a fourth.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("FederationEvict-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var urls: [URL] = []
        for i in 0..<4 {
            let url = tmp.appendingPathComponent("lib\(i)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let store = try LibraryStore(at: url)
            try store.saveAsset(Asset(relativePath: "v\(i).mp4", fileName: "v\(i).mp4"))
            urls.append(url)
        }

        LibraryStore.evictCachedConnections(keeping: Set(urls.prefix(3)))

        for (i, url) in urls.enumerated() {
            XCTAssertEqual(try LibraryStore(at: url).fetchAllAssets().map(\.relativePath), ["v\(i).mp4"],
                           "eviction is non-destructive for kept and dropped libraries alike")
        }
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
    }
}
