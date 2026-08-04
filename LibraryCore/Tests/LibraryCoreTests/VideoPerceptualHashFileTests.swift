import XCTest
import AVFoundation
@testable import LibraryCore

/// End-to-end hashing of a real video file.
///
/// Opt-in: set `VILM_PHASH_FIXTURE` to a video path and, optionally,
/// `VILM_PHASH_EXPECT` to the 16-hex-digit value it should produce. Skipped
/// otherwise, because the fixture is a large file that does not belong in the
/// repository and the value is only meaningful for one specific video.
///
///   VILM_PHASH_FIXTURE=/path/to.mp4 VILM_PHASH_EXPECT=b39180ee9fc3a0f1 swift test
final class VideoPerceptualHashFileTests: XCTestCase {

    func testHashesARealFile() async throws {
        guard let path = ProcessInfo.processInfo.environment["VILM_PHASH_FIXTURE"] else {
            throw XCTSkip("set VILM_PHASH_FIXTURE to run")
        }
        let value = try await VideoPerceptualHash.compute(contentsOf: URL(fileURLWithPath: path))
        let hex = VideoPerceptualHash.hexString(value)
        print("PHASH \(hex)  \(URL(fileURLWithPath: path).lastPathComponent)")

        if let expected = ProcessInfo.processInfo.environment["VILM_PHASH_EXPECT"] {
            XCTAssertEqual(hex, expected)
        }
    }
}
