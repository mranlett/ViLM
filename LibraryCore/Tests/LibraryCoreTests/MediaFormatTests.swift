import XCTest
@testable import LibraryCore

/// Characterization tests for container-metadata display (issue #3, Phase 0).
///
/// F6 stops re-parsing duration and dimensions from the container on every hover
/// and reads them from SQLite instead. These pin the strings the user sees, so
/// that change can be proven to alter WHERE values come from and not WHAT is shown.
///
/// Scope note: this characterizes the MAPPING from loaded values to display text.
/// It does not characterize AVFoundation itself — that would need a real decodable
/// video, and the repository has no such fixture. F6's risk is in the substitution,
/// which is exactly what these cover.
final class MediaFormatTests: XCTestCase {

    // MARK: - Duration

    func testShortDurationsUseMinuteSecondForm() {
        XCTAssertEqual(MediaFormat.duration(seconds: 0), "0:00")
        XCTAssertEqual(MediaFormat.duration(seconds: 5), "0:05")
        XCTAssertEqual(MediaFormat.duration(seconds: 65), "1:05")
        XCTAssertEqual(MediaFormat.duration(seconds: 599), "9:59")
    }

    func testAnHourOrMoreSwitchesToHourForm() {
        XCTAssertEqual(MediaFormat.duration(seconds: 3600), "1:00:00")
        XCTAssertEqual(MediaFormat.duration(seconds: 3661), "1:01:01")
        XCTAssertEqual(MediaFormat.duration(seconds: 7325), "2:02:05")
    }

    func testTheBoundaryAtOneHourIsExact() {
        XCTAssertEqual(MediaFormat.duration(seconds: 3599), "59:59", "still minute form")
        XCTAssertEqual(MediaFormat.duration(seconds: 3600), "1:00:00", "hour form begins here")
    }

    func testSecondsAreRoundedNotTruncated() {
        XCTAssertEqual(MediaFormat.duration(seconds: 59.6), "1:00",
                       "rounding up crosses the minute — truncation would give 0:59")
        XCTAssertEqual(MediaFormat.duration(seconds: 59.4), "0:59")
    }

    func testMinutesAndSecondsAreZeroPaddedButHoursAreNot() {
        XCTAssertEqual(MediaFormat.duration(seconds: 3600 + 5 * 60 + 7), "1:05:07")
        XCTAssertEqual(MediaFormat.duration(seconds: 7), "0:07")
    }

    func testDegenerateDurationsDoNotProduceNonsense() {
        XCTAssertEqual(MediaFormat.duration(seconds: -10), "0:00", "no negative clock")
        XCTAssertEqual(MediaFormat.duration(seconds: .nan), "0:00")
        XCTAssertEqual(MediaFormat.duration(seconds: .infinity), "0:00")
    }

    func testAVeryLongVideoStillFormats() {
        XCTAssertEqual(MediaFormat.duration(seconds: 86_400), "24:00:00")
    }

    // MARK: - Resolution

    func testResolutionUsesTheMultiplicationSignNotTheLetterX() {
        let res = MediaFormat.resolution(width: 1920, height: 1080)
        XCTAssertEqual(res, "1920×1080")
        XCTAssertTrue(res!.contains("\u{00D7}"), "U+00D7 MULTIPLICATION SIGN, not ASCII 'x'")
    }

    func testUnknownDimensionsAreOmittedRatherThanShownAsZero() {
        XCTAssertNil(MediaFormat.resolution(width: 0, height: 1080))
        XCTAssertNil(MediaFormat.resolution(width: 1920, height: 0))
        XCTAssertNil(MediaFormat.resolution(width: 0, height: 0))
        XCTAssertNil(MediaFormat.resolution(width: -1, height: -1))
    }

    // MARK: - Byte count

    func testByteCountDelegatesToTheFileStyleFormatter() {
        // Pinned as delegation rather than a literal: ByteCountFormatter output is
        // locale- and OS-version dependent.
        for bytes in [0, 1, 1_000, 1_048_576, 5_368_709_120] as [Int64] {
            XCTAssertEqual(MediaFormat.byteCount(bytes),
                           ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
    }

    func testByteCountProducesSomethingNonEmptyForARealisticVideo() {
        let s = MediaFormat.byteCount(450 * 1_024 * 1_024)
        XCTAssertFalse(s.isEmpty)
        XCTAssertTrue(s.contains(where: \.isNumber))
    }

    // MARK: - The summary line

    func testFullyPopulatedLineJoinsEveryPartWithAMiddleDot() {
        let line = MediaFormat.metaLine(sizeBytes: 1_048_576, width: 1920, height: 1080,
                                        bitrateMbps: 8.26, durationSeconds: 3661)
        XCTAssertEqual(line.components(separatedBy: " · ").count, 4)
        XCTAssertTrue(line.contains("1920×1080"))
        XCTAssertTrue(line.contains("8.3 Mbps"), "one decimal place")
        XCTAssertTrue(line.hasSuffix("1:01:01"))
    }

    func testSizeIsTheOnlyUnconditionalPart() {
        let line = MediaFormat.metaLine(sizeBytes: 1_048_576, width: 0, height: 0,
                                        bitrateMbps: nil, durationSeconds: nil)
        XCTAssertEqual(line, MediaFormat.byteCount(1_048_576))
        XCTAssertFalse(line.contains("·"), "no dangling separators when everything else is unknown")
    }

    func testEachUnknownPartIsDroppedRatherThanLeavingAGap() {
        let noBitrate = MediaFormat.metaLine(sizeBytes: 100, width: 640, height: 480,
                                             bitrateMbps: nil, durationSeconds: 90)
        XCTAssertEqual(noBitrate.components(separatedBy: " · ").count, 3)
        XCTAssertFalse(noBitrate.contains("Mbps"))

        let noDuration = MediaFormat.metaLine(sizeBytes: 100, width: 640, height: 480,
                                              bitrateMbps: 2.0, durationSeconds: nil)
        XCTAssertEqual(noDuration.components(separatedBy: " · ").count, 3)
        XCTAssertTrue(noDuration.hasSuffix("2.0 Mbps"))
    }

    func testPartOrderIsSizeThenResolutionThenBitrateThenDuration() {
        let line = MediaFormat.metaLine(sizeBytes: 1_048_576, width: 1280, height: 720,
                                        bitrateMbps: 3.0, durationSeconds: 120)
        let parts = line.components(separatedBy: " · ")
        XCTAssertEqual(parts[0], MediaFormat.byteCount(1_048_576))
        XCTAssertEqual(parts[1], "1280×720")
        XCTAssertEqual(parts[2], "3.0 Mbps")
        XCTAssertEqual(parts[3], "2:00")
    }

    /// Note: `%.1f` uses round-half-to-even and operates on the binary value, so
    /// exact halves are not intuitive — 8.25 renders as "8.2", while 8.35 renders as
    /// "8.3" because it is stored slightly below the true half. Values here are
    /// deliberately away from the halfway point.
    func testBitrateAlwaysShowsExactlyOneDecimalPlace() {
        for (value, expected) in [(1.0, "1.0 Mbps"), (0.04, "0.0 Mbps"), (12.349, "12.3 Mbps")] {
            let line = MediaFormat.metaLine(sizeBytes: 1, width: 0, height: 0,
                                            bitrateMbps: value, durationSeconds: nil)
            XCTAssertTrue(line.hasSuffix(expected), "\(value) should render as \(expected), got \(line)")
        }
    }

    /// The formatter is duplicated in the app target (DuplicateDetectionView,
    /// EditVideoView ×2) and in SceneMarker.formattedTimestamp. This asserts they
    /// agree, so consolidating them later is provably safe.
    func testMatchesTheExistingSceneMarkerTimestampFormatter() {
        for seconds in [0, 7, 65, 599, 3599, 3600, 3661, 86_400] as [Double] {
            let marker = SceneMarker(assetId: UUID(), timestampSeconds: seconds)
            XCTAssertEqual(MediaFormat.duration(seconds: seconds), marker.formattedTimestamp,
                           "the four duration formatters in this codebase must agree at \(seconds)s")
        }
    }
}
