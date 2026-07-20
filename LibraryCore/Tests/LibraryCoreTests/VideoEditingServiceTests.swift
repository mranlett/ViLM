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
}
