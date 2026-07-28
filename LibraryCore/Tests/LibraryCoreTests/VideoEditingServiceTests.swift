import XCTest
@testable import LibraryCore

/// Covers the pure, deterministic part of video editing: how a trim rebases and
/// drops scene markers. The real AVFoundation re-encode needs a decodable video
/// and is verified manually on-device.
final class VideoEditingServiceTests: XCTestCase {

    private func marker(_ label: String, at t: Double) -> SceneMarker {
        SceneMarker(assetId: UUID(), timestampSeconds: t, label: label)
    }

    private func labels(_ markers: [SceneMarker]) -> [String] { markers.map { $0.label ?? "" } }

    func testMarkersInsideTheKeptRangeAreRebased() {
        // Keep [2, 12]: a marker at 5 becomes 3; at 12 (end) becomes 10.
        let markers = [marker("a", at: 5), marker("edge", at: 12)]
        let result = VideoEditingService.adjustMarkersForTrim(markers, keepStart: 2, keepEnd: 12)
        XCTAssertEqual(labels(result.dropped), [])
        XCTAssertEqual(result.shifted.first(where: { $0.label == "a" })?.timestampSeconds, 3)
        XCTAssertEqual(result.shifted.first(where: { $0.label == "edge" })?.timestampSeconds, 10)
    }

    func testMarkersBeforeAndAfterTheRangeAreDropped() {
        let markers = [
            marker("before", at: 1),   // < keepStart → dropped
            marker("kept", at: 6),     // inside → shifted
            marker("after", at: 20)    // > keepEnd → dropped
        ]
        let result = VideoEditingService.adjustMarkersForTrim(markers, keepStart: 2, keepEnd: 12)
        XCTAssertEqual(Set(labels(result.dropped)), ["before", "after"])
        XCTAssertEqual(labels(result.shifted), ["kept"])
        XCTAssertEqual(result.shifted.first?.timestampSeconds, 4)
    }

    func testKeepStartBoundaryIsInclusiveAndRebasesToZero() {
        // A marker exactly at keepStart survives and lands at 0.
        let result = VideoEditingService.adjustMarkersForTrim([marker("start", at: 2)], keepStart: 2, keepEnd: 12)
        XCTAssertEqual(labels(result.dropped), [])
        XCTAssertEqual(result.shifted.first?.timestampSeconds, 0)
    }

    func testTrimmingOnlyTheFrontShiftsEverythingBack() {
        // Remove the first 2:00 (keepStart 120) — a marker at 12:00 (720) → 10:00 (600).
        let result = VideoEditingService.adjustMarkersForTrim([marker("m", at: 720)], keepStart: 120, keepEnd: 3600)
        XCTAssertEqual(result.shifted.first?.timestampSeconds, 600)
    }

    func testEmptyMarkersProducesEmptyAdjustment() {
        let result = VideoEditingService.adjustMarkersForTrim([], keepStart: 0, keepEnd: 10)
        XCTAssertTrue(result.shifted.isEmpty)
        XCTAssertTrue(result.dropped.isEmpty)
    }

    func testRebaseMarkersWritesRowsAndDeletesThumbnails() throws {
        // The DB half of a trim, against a real store: kept markers' rows are
        // shifted, cut-away markers' rows AND preview thumbnails are gone.
        let lib = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoEditingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        defer {
            LibraryStore.evictCachedConnection(forLibraryAt: lib)
            try? FileManager.default.removeItem(at: lib)
        }
        let store = try LibraryStore(at: lib)
        let asset = Asset(relativePath: "a.mp4", fileName: "a.mp4")
        try store.insertAsset(asset)
        let dropped = SceneMarker(assetId: asset.id, timestampSeconds: 1, label: "cut away")
        let kept = SceneMarker(assetId: asset.id, timestampSeconds: 8, label: "kept")
        try store.saveSceneMarker(dropped)
        try store.saveSceneMarker(kept)
        // A preview thumbnail for the marker that will be dropped.
        let sheets = ContactSheetService(store: store)
        let droppedThumb = sheets.markerThumbnailURL(markerId: dropped.id, libraryURL: lib)
        try FileManager.default.createDirectory(at: droppedThumb.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data([7]).write(to: droppedThumb)

        try VideoEditingService.rebaseMarkers(
            for: asset, keepStart: 5, keepEnd: 20, store: store, libraryURL: lib)

        let after = try store.fetchSceneMarkers(for: asset.id)
        XCTAssertEqual(after.map(\.id), [kept.id], "the cut-away marker's row is gone")
        XCTAssertEqual(after.first?.timestampSeconds, 3, "the kept marker is rebased to the new timeline")
        XCTAssertFalse(FileManager.default.fileExists(atPath: droppedThumb.path),
                       "the dropped marker's preview file is cleaned up")
    }
}
