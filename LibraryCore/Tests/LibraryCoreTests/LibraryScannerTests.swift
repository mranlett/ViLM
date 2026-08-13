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
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
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

    // MARK: - 🚨 T34 / #63 — every container is asserted, one at a time

    /// The Epic's T34, and the reason it says "asserted per extension":
    ///
    /// > an unrecognised file is not skipped visibly — it never enters the
    /// > library at all.
    ///
    /// There is no count, no report, no "skipped" state. A container missing
    /// from the list is indistinguishable from a file that is not on disk, so
    /// the only way to know the list is right is to assert each entry.
    func testEveryIndexableContainerIsActuallyIndexed() async throws {
        let extensions = Array(LibraryScanner.indexableExtensions).sorted()
        XCTAssertTrue(extensions.contains("mkv"), "the container #63 was filed for")

        for ext in extensions {
            try createFile(at: "clip.\(ext)")
        }
        try await scanner.scan(at: libraryURL)

        let indexed = Set(try store.fetchAllAssets().map { ($0.fileName as NSString).pathExtension.lowercased() })
        for ext in extensions {
            XCTAssertTrue(indexed.contains(ext), "\(ext) is in the list but was not indexed")
        }
    }

    /// ⚠️ The other half. A list that indexed everything would also pass the
    /// test above, and would fill the library with subtitles and artwork.
    func testFilesOutsideTheListAreStillIgnored() async throws {
        for name in ["cover.jpg", "subs.srt", "notes.txt", "clip.mp4.part", "archive.zip"] {
            try createFile(at: name)
        }
        try await scanner.scan(at: libraryURL)
        XCTAssertTrue(try store.fetchAllAssets().isEmpty,
                      "something outside the container list was indexed")
    }
}
