import XCTest
@testable import LibraryCore

final class SceneMarkerTests: XCTestCase {

    private var libraryURL: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        libraryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SceneMarkerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        store = try LibraryStore(at: libraryURL)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: libraryURL)
    }

    // MARK: - Formatting

    func testFormattedTimestampUnderAnHour() {
        let marker = SceneMarker(assetId: UUID(), timestampSeconds: 325) // 5:25
        XCTAssertEqual(marker.formattedTimestamp, "5:25")
    }

    func testFormattedTimestampOverAnHour() {
        let marker = SceneMarker(assetId: UUID(), timestampSeconds: 3725) // 1:02:05
        XCTAssertEqual(marker.formattedTimestamp, "1:02:05")
    }

    func testDisplayTitleFallsBackToTimestampWhenNoLabel() {
        let marker = SceneMarker(assetId: UUID(), timestampSeconds: 65)
        XCTAssertEqual(marker.displayTitle, "1:05")
    }

    func testDisplayTitleUsesLabelWhenPresent() {
        let marker = SceneMarker(assetId: UUID(), timestampSeconds: 325, label: "Lightsaber Fight")
        XCTAssertEqual(marker.displayTitle, "Lightsaber Fight")
    }

    // MARK: - CRUD

    func testSaveAndFetchMarkersOrderedByTimestamp() throws {
        try store.saveAsset(Asset(relativePath: "a.mp4", fileName: "a.mp4"))
        let asset = try XCTUnwrap(store.fetchAllAssets().first)

        try store.saveSceneMarker(SceneMarker(assetId: asset.id, timestampSeconds: 572, label: "Trench Run"))
        try store.saveSceneMarker(SceneMarker(assetId: asset.id, timestampSeconds: 325, label: "Lightsaber Fight"))

        let markers = try store.fetchSceneMarkers(for: asset.id)
        XCTAssertEqual(markers.map(\.label), ["Lightsaber Fight", "Trench Run"], "markers should be chronological, not insertion order")
    }

    func testFetchSceneMarkersOnlyReturnsMarkersForThatAsset() throws {
        try store.saveAsset(Asset(relativePath: "a.mp4", fileName: "a.mp4"))
        try store.saveAsset(Asset(relativePath: "b.mp4", fileName: "b.mp4"))
        let assets = try store.fetchAllAssets()
        let a = try XCTUnwrap(assets.first { $0.relativePath == "a.mp4" })
        let b = try XCTUnwrap(assets.first { $0.relativePath == "b.mp4" })

        try store.saveSceneMarker(SceneMarker(assetId: a.id, timestampSeconds: 10, label: "A's marker"))
        try store.saveSceneMarker(SceneMarker(assetId: b.id, timestampSeconds: 20, label: "B's marker"))

        let aMarkers = try store.fetchSceneMarkers(for: a.id)
        XCTAssertEqual(aMarkers.map(\.label), ["A's marker"])
    }

    func testDeleteSceneMarker() throws {
        try store.saveAsset(Asset(relativePath: "a.mp4", fileName: "a.mp4"))
        let asset = try XCTUnwrap(store.fetchAllAssets().first)
        let marker = SceneMarker(assetId: asset.id, timestampSeconds: 10)
        try store.saveSceneMarker(marker)

        try store.deleteSceneMarker(id: marker.id)

        XCTAssertTrue(try store.fetchSceneMarkers(for: asset.id).isEmpty)
    }

    func testEditingMarkerLabelPersists() throws {
        try store.saveAsset(Asset(relativePath: "a.mp4", fileName: "a.mp4"))
        let asset = try XCTUnwrap(store.fetchAllAssets().first)
        var marker = SceneMarker(assetId: asset.id, timestampSeconds: 10, label: "Original")
        try store.saveSceneMarker(marker)

        marker.label = "Renamed"
        try store.saveSceneMarker(marker)

        let fetched = try XCTUnwrap(store.fetchSceneMarkers(for: asset.id).first)
        XCTAssertEqual(fetched.label, "Renamed")
    }

    // MARK: - Cascade delete (the important one)

    func testDeletingAssetCascadesToItsSceneMarkers() throws {
        try store.saveAsset(Asset(relativePath: "a.mp4", fileName: "a.mp4"))
        let asset = try XCTUnwrap(store.fetchAllAssets().first)
        try store.saveSceneMarker(SceneMarker(assetId: asset.id, timestampSeconds: 10, label: "Marker 1"))
        try store.saveSceneMarker(SceneMarker(assetId: asset.id, timestampSeconds: 20, label: "Marker 2"))
        XCTAssertEqual(try store.fetchSceneMarkers(for: asset.id).count, 2)

        try store.deleteAsset(asset)

        XCTAssertTrue(try store.fetchSceneMarkers(for: asset.id).isEmpty, "markers must be cascade-deleted with their video")
    }

    func testDeletingOneAssetDoesNotAffectAnotherAssetsMarkers() throws {
        try store.saveAsset(Asset(relativePath: "a.mp4", fileName: "a.mp4"))
        try store.saveAsset(Asset(relativePath: "b.mp4", fileName: "b.mp4"))
        let assets = try store.fetchAllAssets()
        let a = try XCTUnwrap(assets.first { $0.relativePath == "a.mp4" })
        let b = try XCTUnwrap(assets.first { $0.relativePath == "b.mp4" })

        try store.saveSceneMarker(SceneMarker(assetId: a.id, timestampSeconds: 10))
        try store.saveSceneMarker(SceneMarker(assetId: b.id, timestampSeconds: 20))

        try store.deleteAsset(a)

        XCTAssertTrue(try store.fetchSceneMarkers(for: a.id).isEmpty)
        XCTAssertEqual(try store.fetchSceneMarkers(for: b.id).count, 1, "unrelated asset's markers must survive")
    }
}
