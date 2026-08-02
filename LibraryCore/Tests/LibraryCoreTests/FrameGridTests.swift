import XCTest
import CoreGraphics
@testable import LibraryCore

/// Characterization tests for the 4x4 detail grid (issue #3, Phase 0).
///
/// These pin WHICH frames the grid samples and how its aspect ratio is derived,
/// so the F1 optimisation — bounding concurrent decodes and caching the results —
/// can be proven not to change what the user sees. If any of these change, the
/// grid is showing different frames, which is a behaviour change, not a speed-up.
final class FrameGridTests: XCTestCase {

    // MARK: - Frame timestamps

    func testSixteenCellsProduceSixteenTimestamps() {
        XCTAssertEqual(FrameGrid.frameTimes(duration: 100).count, 16)
        XCTAssertEqual(FrameGrid.defaultCellCount, 16, "the grid is 4x4")
    }

    func testFramesAreEvenlySpacedBetweenTheEndpoints() {
        // 16 cells over 170s: sample points at 1/17 … 16/17 of the duration.
        let times = FrameGrid.frameTimes(duration: 170)
        for (i, t) in times.enumerated() {
            XCTAssertEqual(t, Double(i + 1) * 10, accuracy: 0.0001)
        }
    }

    func testNeitherTheFirstNorTheLastFrameIsSampled() {
        let times = FrameGrid.frameTimes(duration: 100)
        XCTAssertGreaterThan(times.first!, 0, "the very first frame is skipped")
        XCTAssertLessThan(times.last!, 100, "the very last frame is skipped")
    }

    func testTimestampsAreAscending() {
        let times = FrameGrid.frameTimes(duration: 613.7)
        XCTAssertEqual(times, times.sorted(), "grid order is chronological, left-to-right then down")
    }

    func testTheFinalTimestampIsPulledBackFromTheEnd() {
        // A very short clip: 16/17 of 1s is 0.941, but the guard clamps to 0.75.
        let times = FrameGrid.frameTimes(duration: 1)
        XCTAssertEqual(times.last!, 1 - FrameGrid.endGuardSeconds, accuracy: 0.0001,
                       "seeking to the exact end usually yields nothing decodable")
        XCTAssertLessThanOrEqual(times.max()!, 1 - FrameGrid.endGuardSeconds)
    }

    func testEveryTimestampStaysInsideTheClip() {
        for duration in [0.1, 0.5, 1, 3.7, 60, 3600, 86_400] as [Double] {
            for t in FrameGrid.frameTimes(duration: duration) {
                XCTAssertGreaterThanOrEqual(t, 0, "duration \(duration)")
                XCTAssertLessThanOrEqual(t, duration, "duration \(duration)")
            }
        }
    }

    func testAVeryShortClipClampsEveryFrameRatherThanGoingNegative() {
        // Shorter than the end guard: everything collapses to 0, but nothing is negative.
        let times = FrameGrid.frameTimes(duration: 0.1)
        XCTAssertEqual(times.count, 16)
        XCTAssertTrue(times.allSatisfy { $0 >= 0 }, "no negative seek times")
    }

    // MARK: - Frame timestamps, failure states

    func testNonPositiveOrNonFiniteDurationsYieldNoFrames() {
        XCTAssertEqual(FrameGrid.frameTimes(duration: 0), [])
        XCTAssertEqual(FrameGrid.frameTimes(duration: -5), [])
        XCTAssertEqual(FrameGrid.frameTimes(duration: .nan), [])
        XCTAssertEqual(FrameGrid.frameTimes(duration: .infinity), [])
    }

    func testZeroOrNegativeCellCountYieldsNoFrames() {
        XCTAssertEqual(FrameGrid.frameTimes(count: 0, duration: 100), [])
        XCTAssertEqual(FrameGrid.frameTimes(count: -1, duration: 100), [])
    }

    func testCellCountIsHonouredWhenItIsNotSixteen() {
        XCTAssertEqual(FrameGrid.frameTimes(count: 4, duration: 50).count, 4)
        XCTAssertEqual(FrameGrid.frameTimes(count: 1, duration: 50), [25], "1 cell samples the midpoint")
    }

    // MARK: - Aspect ratio

    func testUprightVideoKeepsItsStoredRatio() {
        let ratio = FrameGrid.aspectRatio(naturalSize: CGSize(width: 1920, height: 1080),
                                          transform: .identity)
        XCTAssertEqual(ratio!, 16.0 / 9.0, accuracy: 0.0001)
    }

    func testRotatedVideoReportsTheRatioItWillBeDISPLAYEDAt() {
        // Portrait footage stored landscape with a 90-degree preferred transform.
        let ratio = FrameGrid.aspectRatio(naturalSize: CGSize(width: 1920, height: 1080),
                                          transform: CGAffineTransform(rotationAngle: .pi / 2))
        XCTAssertEqual(ratio!, 9.0 / 16.0, accuracy: 0.0001,
                       "the preferred transform must be applied, not ignored")
    }

    func testTransformsProducingNegativeExtentsStillGiveAPositiveRatio() {
        let ratio = FrameGrid.aspectRatio(naturalSize: CGSize(width: 1920, height: 1080),
                                          transform: CGAffineTransform(scaleX: -1, y: -1))
        XCTAssertEqual(ratio!, 16.0 / 9.0, accuracy: 0.0001, "a mirrored video is not negatively shaped")
    }

    func testDegenerateSizeReturnsNilSoTheCallerKeepsItsDefault() {
        XCTAssertNil(FrameGrid.aspectRatio(naturalSize: CGSize(width: 1920, height: 0),
                                           transform: .identity))
        XCTAssertNil(FrameGrid.aspectRatio(naturalSize: .zero, transform: .identity))
    }
}
