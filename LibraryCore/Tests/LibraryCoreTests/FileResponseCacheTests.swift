import XCTest
@testable import LibraryCore

/// Tests for the on-disk response cache (Plugin Architecture, D6 / T8).
final class FileResponseCacheTests: XCTestCase {

    private var libraryURL: URL!
    private var cache: FileResponseCache!

    override func setUpWithError() throws {
        libraryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileResponseCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        cache = FileResponseCache(libraryURL: libraryURL)
    }

    override func tearDownWithError() throws {
        cache = nil
        try? FileManager.default.removeItem(at: libraryURL)
    }

    // MARK: - Round trip

    func testAStoredResponseIsReplayedExactly() {
        let payload = Data("recorded response".utf8)
        cache.store(payload, pluginId: "p", requestKey: "search:jane")
        XCTAssertEqual(cache.data(pluginId: "p", requestKey: "search:jane"), payload)
    }

    func testAMissingEntryReturnsNilRatherThanEmptyData() {
        XCTAssertNil(cache.data(pluginId: "p", requestKey: "never-stored"))
    }

    func testStoringTwiceForTheSameKeyOverwrites() {
        cache.store(Data("first".utf8), pluginId: "p", requestKey: "k")
        cache.store(Data("second".utf8), pluginId: "p", requestKey: "k")
        XCTAssertEqual(cache.data(pluginId: "p", requestKey: "k"), Data("second".utf8))
    }

    // MARK: - Isolation

    func testTheSameRequestKeyUnderDifferentPluginsIsADifferentEntry() {
        cache.store(Data("a".utf8), pluginId: "p1", requestKey: "k")
        cache.store(Data("b".utf8), pluginId: "p2", requestKey: "k")
        XCTAssertEqual(cache.data(pluginId: "p1", requestKey: "k"), Data("a".utf8))
        XCTAssertEqual(cache.data(pluginId: "p2", requestKey: "k"), Data("b".utf8))
    }

    func testPurgingOnePluginLeavesAnotherIntact() {
        cache.store(Data(repeating: 0, count: 100), pluginId: "p1", requestKey: "k")
        cache.store(Data(repeating: 0, count: 200), pluginId: "p2", requestKey: "k")
        cache.purge(pluginId: "p1")
        XCTAssertNil(cache.data(pluginId: "p1", requestKey: "k"))
        XCTAssertEqual(cache.data(pluginId: "p2", requestKey: "k")?.count, 200)
    }

    /// The promise uninstall makes: nothing of that plugin survives.
    func testPurgeRemovesThePluginDirectoryEntirely() {
        cache.store(Data("x".utf8), pluginId: "p", requestKey: "a")
        cache.store(Data("y".utf8), pluginId: "p", requestKey: "b")
        XCTAssertGreaterThan(cache.size(pluginId: "p"), 0)
        cache.purge(pluginId: "p")
        XCTAssertEqual(cache.size(pluginId: "p"), 0)
        XCTAssertNil(cache.data(pluginId: "p", requestKey: "a"))
        XCTAssertNil(cache.data(pluginId: "p", requestKey: "b"))
    }

    func testPurgeAllClearsEveryPlugin() {
        cache.store(Data("a".utf8), pluginId: "p1", requestKey: "k")
        cache.store(Data("b".utf8), pluginId: "p2", requestKey: "k")
        cache.purgeAll()
        XCTAssertEqual(cache.size(pluginId: "p1"), 0)
        XCTAssertEqual(cache.size(pluginId: "p2"), 0)
    }

    // MARK: - Size reporting (the plugin detail screen)

    func testSizeSumsOnlyTheRequestedPlugin() {
        cache.store(Data(repeating: 0, count: 10), pluginId: "p1", requestKey: "a")
        cache.store(Data(repeating: 0, count: 25), pluginId: "p1", requestKey: "b")
        cache.store(Data(repeating: 0, count: 99), pluginId: "p2", requestKey: "a")
        XCTAssertEqual(cache.size(pluginId: "p1"), 35)
        XCTAssertEqual(cache.size(pluginId: "p2"), 99)
    }

    func testSizeIsZeroForAPluginThatHasCachedNothing() {
        XCTAssertEqual(cache.size(pluginId: "never-used"), 0)
    }

    // MARK: - Path safety

    /// Ids and keys are hashed, so neither can escape the cache root or collide
    /// with an unrelated file.
    func testAnIdContainingPathSeparatorsCannotEscapeTheCacheRoot() {
        let hostile = "../../../etc/passwd"
        cache.store(Data("x".utf8), pluginId: hostile, requestKey: "k")
        XCTAssertEqual(cache.data(pluginId: hostile, requestKey: "k"), Data("x".utf8),
                       "it still round-trips")

        let escaped = libraryURL.deletingLastPathComponent()
            .appendingPathComponent("etc/passwd", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: escaped.path),
                       "but nothing was written outside the cache root")
    }

    func testARequestKeyContainingPathSeparatorsIsSafe() {
        cache.store(Data("x".utf8), pluginId: "p", requestKey: "../../escape")
        XCTAssertEqual(cache.data(pluginId: "p", requestKey: "../../escape"), Data("x".utf8))
    }

    func testTheDigestIsStableAndDistinguishesDifferentInputs() {
        XCTAssertEqual(FileResponseCache.digest("same"), FileResponseCache.digest("same"))
        XCTAssertNotEqual(FileResponseCache.digest("a"), FileResponseCache.digest("b"))
        XCTAssertEqual(FileResponseCache.digest("x").count, 64, "SHA-256 hex")
    }

    // MARK: - Location

    func testTheCacheLivesInsideTheLibraryCatalogue() {
        cache.store(Data("x".utf8), pluginId: "p", requestKey: "k")
        let expected = libraryURL.appendingPathComponent(".catalog/pluginCache", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path),
                      "cached responses travel with the library they enriched")
    }

    func testAFailedWriteDoesNotThrow() {
        // A cache is an optimisation; a write failure must never surface as an
        // error to the operation that produced the data.
        let unwritable = FileResponseCache(libraryURL: URL(fileURLWithPath: "/dev/null/nope"))
        unwritable.store(Data("x".utf8), pluginId: "p", requestKey: "k")
        XCTAssertNil(unwritable.data(pluginId: "p", requestKey: "k"))
    }
}
