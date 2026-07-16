import XCTest
@testable import LibraryCore

/// Covers the deterministic, Vision-independent logic: contact sheet cell
/// geometry, actor photo file enumeration/hashing, and the similarity-score
/// heuristic. The actual face detection / feature-print pipeline needs real
/// photographs of faces to produce any results, which aren't available as
/// test fixtures — that part is verified manually on-device, not here.
final class ActorFaceSuggestionTests: XCTestCase {

    private var libraryURL: URL!
    private var store: LibraryStore!
    private var profilesDir: URL!

    override func setUpWithError() throws {
        libraryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActorFaceSuggestionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        store = try LibraryStore(at: libraryURL)
        profilesDir = libraryURL.appendingPathComponent(".catalog/profiles")
        try FileManager.default.createDirectory(at: profilesDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: libraryURL)
    }

    private func writeFile(_ name: String, bytes: [UInt8]) throws {
        try Data(bytes).write(to: profilesDir.appendingPathComponent(name))
    }

    // MARK: - ContactSheetLayout geometry

    func testCellRectFirstCellStartsAtMargin() {
        let layout = ContactSheetLayout.default
        let rect = layout.cellRect(row: 0, col: 0)
        XCTAssertEqual(rect.origin.x, layout.margin)
        XCTAssertEqual(rect.origin.y, layout.margin)
        XCTAssertEqual(rect.size, layout.cellSize)
    }

    func testCellRectAdvancesByColumn() {
        let layout = ContactSheetLayout.default
        let cell0 = layout.cellRect(row: 0, col: 0)
        let cell1 = layout.cellRect(row: 0, col: 1)
        XCTAssertEqual(cell1.origin.x, cell0.origin.x + layout.cellSize.width + layout.margin)
        XCTAssertEqual(cell1.origin.y, cell0.origin.y, "same row must share the same y")
    }

    func testCellRectAdvancesByRow() {
        let layout = ContactSheetLayout.default
        let cell0 = layout.cellRect(row: 0, col: 0)
        let cell1 = layout.cellRect(row: 1, col: 0)
        XCTAssertEqual(cell1.origin.y, cell0.origin.y + layout.cellSize.height + layout.margin)
        XCTAssertEqual(cell1.origin.x, cell0.origin.x, "same column must share the same x")
    }

    func testAllCellsFitWithinSheetBounds() {
        let layout = ContactSheetLayout.default
        for row in 0..<layout.rows {
            for col in 0..<layout.columns {
                let rect = layout.cellRect(row: row, col: col)
                XCTAssertLessThanOrEqual(rect.maxX, layout.sheetSize.width)
                XCTAssertLessThanOrEqual(rect.maxY, layout.sheetSize.height)
            }
        }
    }

    func testFrameCountMatchesGridDimensions() {
        let layout = ContactSheetLayout.default
        XCTAssertEqual(layout.frameCount, layout.columns * layout.rows)
    }

    // MARK: - similarityScore heuristic

    func testSimilarityScoreZeroDistanceIsMaximallySimilar() {
        XCTAssertEqual(LibraryStore.similarityScore(forDistance: 0), 1.0)
    }

    func testSimilarityScoreDecreasesWithDistance() {
        let near = LibraryStore.similarityScore(forDistance: 0.2)
        let far = LibraryStore.similarityScore(forDistance: 1.0)
        XCTAssertGreaterThan(near, far)
    }

    func testSimilarityScoreNeverNegative() {
        XCTAssertEqual(LibraryStore.similarityScore(forDistance: 100), 0)
    }

    // MARK: - actorPhotoFiles enumeration

    func testActorPhotoFilesIncludesPrimary() throws {
        try writeFile("actor_Jane Doe.jpg", bytes: [1, 2, 3])
        let profile = EntityProfile(id: "actor:Jane Doe")

        let files = store.actorPhotoFiles(for: profile, libraryURL: libraryURL)

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.contentHash, ProfileImageNaming.sha256Hex(Data([1, 2, 3])))
    }

    func testActorPhotoFilesIncludesGalleryPhotos() throws {
        let token = "https://example.com/1.jpg"
        try writeFile("actor_Jane Doe.jpg", bytes: [1, 2, 3])
        try writeFile(ProfileImageNaming.galleryFileName(for: "actor:Jane Doe", token: token), bytes: [4, 5, 6])
        let profile = EntityProfile(id: "actor:Jane Doe", galleryUrls: [token])

        let files = store.actorPhotoFiles(for: profile, libraryURL: libraryURL)

        XCTAssertEqual(files.count, 2, "primary and gallery photo should both be included")
    }

    func testActorPhotoFilesSkipsMissingFiles() throws {
        let profile = EntityProfile(id: "actor:Jane Doe", galleryUrls: ["https://example.com/missing.jpg"])
        let files = store.actorPhotoFiles(for: profile, libraryURL: libraryURL)
        XCTAssertTrue(files.isEmpty)
    }

    func testActorPhotoFilesContentHashChangesWhenPhotoChanges() throws {
        try writeFile("actor_Jane Doe.jpg", bytes: [1, 2, 3])
        let profile = EntityProfile(id: "actor:Jane Doe")
        let firstHash = store.actorPhotoFiles(for: profile, libraryURL: libraryURL).first?.contentHash

        try writeFile("actor_Jane Doe.jpg", bytes: [9, 9, 9])
        let secondHash = store.actorPhotoFiles(for: profile, libraryURL: libraryURL).first?.contentHash

        XCTAssertNotEqual(firstHash, secondHash, "changing the photo's bytes must change its cache key, so a stale fingerprint is never reused")
    }

    // MARK: - rebuildFaceIndex bookkeeping (no faces expected in synthetic data)

    func testRebuildFaceIndexCountsActorsAndPhotosEvenWithNoDetectableFaces() throws {
        // These bytes aren't a real photo, so face detection will find
        // nothing — this test only verifies the scan's bookkeeping, not
        // detection itself.
        try writeFile("actor_Jane Doe.jpg", bytes: [1, 2, 3])
        try store.saveEntityProfile(EntityProfile(id: "actor:Jane Doe"))

        let result = try store.rebuildFaceIndex(libraryURL: libraryURL)

        XCTAssertEqual(result.actorsScanned, 1)
        XCTAssertEqual(result.photosScanned, 1)
        XCTAssertEqual(result.fingerprintsComputed, 0, "no real image data, so no face should be detected")
    }
}
