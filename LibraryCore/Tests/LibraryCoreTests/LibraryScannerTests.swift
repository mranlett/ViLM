import XCTest
@testable import LibraryCore

final class LibraryScannerTests: XCTestCase {

    private var libraryURL: URL!
    private var store: LibraryStore!
    private var scanner: LibraryScanner!

    override func setUpWithError() throws {
        libraryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        store = try LibraryStore(at: libraryURL)
        scanner = LibraryScanner(store: store)
    }

    override func tearDownWithError() throws {
        scanner = nil
        store = nil
        try? FileManager.default.removeItem(at: libraryURL)
    }

    private func createFile(at relativePath: String) throws {
        let url = libraryURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    func testScanIndexesSupportedVideoFormats() async throws {
        try createFile(at: "a.mp4")
        try createFile(at: "b.mov")
        try createFile(at: "c.m4v")
        try createFile(at: "d.MP4") // extension matching is case-insensitive
        try createFile(at: "notes.txt")
        try createFile(at: "image.jpg")

        try await scanner.scan(at: libraryURL)

        let paths = Set(try store.fetchAllAssets().map(\.relativePath))
        XCTAssertEqual(paths, Set(["a.mp4", "b.mov", "c.m4v", "d.MP4"]))
    }

    func testScanRecursesIntoSubfoldersWithRelativePaths() async throws {
        try createFile(at: "season 1/episode1.mp4")
        try createFile(at: "season 1/extras/blooper.mov")

        try await scanner.scan(at: libraryURL)

        let paths = Set(try store.fetchAllAssets().map(\.relativePath))
        XCTAssertEqual(paths, Set(["season 1/episode1.mp4", "season 1/extras/blooper.mov"]))
    }

    func testScanSkipsHiddenFilesAndCatalogFolder() async throws {
        try createFile(at: "visible.mp4")
        try createFile(at: ".hidden.mp4")
        // .catalog is the store's own metadata folder and is hidden
        try createFile(at: ".catalog/stray.mp4")

        try await scanner.scan(at: libraryURL)

        let paths = try store.fetchAllAssets().map(\.relativePath)
        XCTAssertEqual(paths, ["visible.mp4"])
    }

    func testRescanIsIdempotent() async throws {
        try createFile(at: "a.mp4")

        try await scanner.scan(at: libraryURL)
        try await scanner.scan(at: libraryURL)

        XCTAssertEqual(try store.fetchAllAssets().count, 1)
    }

    func testRescanPreservesExistingMetadata() async throws {
        try createFile(at: "a.mp4")
        try await scanner.scan(at: libraryURL)

        var asset = try XCTUnwrap(store.fetchAllAssets().first)
        asset.status = .reviewed
        asset.tags = ["actor:Jane Doe"]
        try store.updateAsset(asset)

        // A new file appears and the library is rescanned
        try createFile(at: "b.mp4")
        try await scanner.scan(at: libraryURL)

        let assets = try store.fetchAllAssets()
        XCTAssertEqual(assets.count, 2)
        let original = try XCTUnwrap(assets.first { $0.relativePath == "a.mp4" })
        XCTAssertEqual(original.status, .reviewed, "rescanning must not clobber review status")
        XCTAssertEqual(original.tags, ["actor:Jane Doe"], "rescanning must not clobber tags")
    }
}
