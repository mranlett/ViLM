import XCTest
import CoreGraphics
@testable import LibraryCore

/// Covers the pure core of content-aware duplicate detection: the perceptual
/// difference-hash, the time-grid sampling, the offset-alignment matcher (the
/// piece that catches trimmed copies), duration-window clustering, pair
/// grouping, and the persisted fingerprint cache. The AVFoundation frame
/// extraction needs real video and is verified on-device.
final class VideoDuplicateAnalyzerTests: XCTestCase {

    // MARK: - Synthetic images

    /// A grayscale gradient image; `reversed` flips the direction so the
    /// brightness *relationships* between neighbors invert (maximally
    /// different dHash), while `size` changes only the resolution (dHash must
    /// be invariant to that).
    private func gradientImage(width: Int, height: Int, reversed: Bool = false) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            for col in 0..<width {
                let value = UInt8((col * 255) / max(1, width - 1))
                pixels[row * width + col] = reversed ? 255 - value : value
            }
        }
        let ctx = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        return ctx.makeImage()!
    }

    /// Distinct, mutually distant 64-bit hashes to stand in for frames of a
    /// video: each differs from every other by far more than the per-frame
    /// match threshold.
    private func frames(_ count: Int, seed: UInt64 = 0) -> [UInt64] {
        (0..<count).map { i in
            var h = UInt64(i) &+ seed &* 0x9E37_79B9_7F4A_7C15
            h = (h ^ (h >> 30)) &* 0xBF58_476D_1CE4_E5B9
            h = (h ^ (h >> 27)) &* 0x94D0_49BB_1331_11EB
            return h ^ (h >> 31)
        }
    }

    // MARK: - dHash

    func testSameImageProducesSameHash() {
        let image = gradientImage(width: 320, height: 180)
        XCTAssertEqual(VideoDuplicateAnalyzer.dHash(of: image), VideoDuplicateAnalyzer.dHash(of: image))
    }

    func testHashIsResolutionInvariant() {
        // The same content at 1080p-ish vs tiny must hash (nearly) identically —
        // this is the property that catches re-encodes at different resolutions.
        let large = gradientImage(width: 1920, height: 1080)
        let small = gradientImage(width: 160, height: 90)
        let distance = VideoDuplicateAnalyzer.hammingDistance(
            VideoDuplicateAnalyzer.dHash(of: large), VideoDuplicateAnalyzer.dHash(of: small))
        XCTAssertLessThanOrEqual(distance, VideoDuplicateAnalyzer.maxBitsPerFrame,
                                 "same content at different resolutions must be within the frame-match threshold")
    }

    func testOppositeContentProducesDistantHash() {
        let normal = gradientImage(width: 320, height: 180)
        let reversed = gradientImage(width: 320, height: 180, reversed: true)
        let distance = VideoDuplicateAnalyzer.hammingDistance(
            VideoDuplicateAnalyzer.dHash(of: normal), VideoDuplicateAnalyzer.dHash(of: reversed))
        XCTAssertGreaterThan(distance, VideoDuplicateAnalyzer.maxBitsPerFrame,
                             "opposite gradients must not read as the same content")
    }

    func testHammingDistance() {
        XCTAssertEqual(VideoDuplicateAnalyzer.hammingDistance(0, 0), 0)
        XCTAssertEqual(VideoDuplicateAnalyzer.hammingDistance(0b1011, 0b0010), 2)
        XCTAssertEqual(VideoDuplicateAnalyzer.hammingDistance(.max, 0), 64)
    }

    // MARK: - Interval sample grid

    func testIntervalSampleTimesFollowTheGrid() {
        XCTAssertEqual(VideoDuplicateAnalyzer.intervalSampleTimes(durationSeconds: 30),
                       [2, 7, 12, 17, 22, 27])
    }

    func testIntervalSampleTimesRespectShortAndTinyDurations() {
        XCTAssertEqual(VideoDuplicateAnalyzer.intervalSampleTimes(durationSeconds: 4), [2])
        XCTAssertTrue(VideoDuplicateAnalyzer.intervalSampleTimes(durationSeconds: 1).isEmpty)
    }

    func testIntervalSampleTimesAreCapped() {
        let times = VideoDuplicateAnalyzer.intervalSampleTimes(durationSeconds: 100_000)
        XCTAssertEqual(times.count, VideoDuplicateAnalyzer.maxIntervalSamples)
    }

    // MARK: - Offset alignment (the trimmed-copy matcher)

    func testThirtySecondFrontTrimAlignsAtTheTrimOffset() {
        // The user's exact scenario: one copy has its first 30 seconds cut
        // off but is otherwise identical. On the 5s grid that's a shift of 6
        // samples — the alignment must find it and report 30s.
        let original = frames(20)
        let trimmed = Array(original[6...])
        let match = VideoDuplicateAnalyzer.bestAlignment(original, trimmed)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.offsetSamples, 6)
        XCTAssertEqual(match?.offsetSeconds, 30)
        XCTAssertEqual(match?.matchingFrames, match?.overlap, "every overlapping frame matches")
    }

    func testEndTrimAlignsAtOffsetZero() {
        // Trimming the END shortens the sequence but the starts align.
        let original = frames(20)
        let trimmed = Array(original[..<12])
        let match = VideoDuplicateAnalyzer.bestAlignment(original, trimmed)
        XCTAssertEqual(match?.offsetSamples, 0)
    }

    func testSameLengthReEncodeAlignsAtZeroWithNoise() {
        // A re-encode: same frames, a couple of bits of hash noise per frame.
        let original = frames(10)
        let reEncoded = original.map { $0 ^ 0b11 } // 2-bit noise ≤ threshold
        let match = VideoDuplicateAnalyzer.bestAlignment(original, reEncoded)
        XCTAssertEqual(match?.offsetSamples, 0)
        XCTAssertEqual(match?.matchingFrames, 10)
    }

    func testOneRuinedFrameStillMatches() {
        // A title card / fade difference in one sample shouldn't break the match.
        let original = frames(12)
        var trimmed = Array(original[4...])
        trimmed[2] = ~trimmed[2]
        let match = VideoDuplicateAnalyzer.bestAlignment(original, trimmed)
        XCTAssertEqual(match?.offsetSamples, 4)
        XCTAssertEqual(match?.matchingFrames, 7)
    }

    func testUnrelatedContentDoesNotAlign() {
        XCTAssertNil(VideoDuplicateAnalyzer.bestAlignment(frames(20, seed: 1), frames(20, seed: 999)))
    }

    func testOverlapBelowMinimumNeverMatches() {
        // A 3-sample sequence can't clear minOverlapFrames even if identical.
        let original = frames(20)
        XCTAssertNil(VideoDuplicateAnalyzer.bestAlignment(original, Array(original[5..<8])))
    }

    func testAlignmentIsArgumentOrderIndependent() {
        let original = frames(20)
        let trimmed = Array(original[6...])
        XCTAssertEqual(VideoDuplicateAnalyzer.bestAlignment(original, trimmed),
                       VideoDuplicateAnalyzer.bestAlignment(trimmed, original))
    }

    // MARK: - Duration windows

    func testDurationWindowsClusterWithinTolerance() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let windows = VideoDuplicateAnalyzer.durationWindows([
            (a, 100.0), (b, 101.5),   // together
            (c, 5000.0),              // alone → dropped
            (d, 103.0)                // chains onto b
        ], tolerance: 2.0)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(Set(windows[0]), Set([a, b, d]), "sliding window chains near-durations together")
    }

    func testDurationWindowsDropSingletons() {
        let windows = VideoDuplicateAnalyzer.durationWindows(
            [(UUID(), 10), (UUID(), 5000), (UUID(), 10_000)], tolerance: 600)
        XCTAssertTrue(windows.isEmpty)
    }

    // MARK: - Pair grouping

    func testGroupMatchedPairsBuildsConnectedComponents() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()
        let groups = VideoDuplicateAnalyzer.groupMatchedPairs([(a, b), (b, c), (d, e)])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(Set(groups.map { Set($0) }), Set([Set([a, b, c]), Set([d, e])]))
    }

    // MARK: - Fingerprint cache

    func testFingerprintStoreRoundTripsAndInvalidates() throws {
        let lib = FileManager.default.temporaryDirectory
            .appendingPathComponent("FingerprintStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: lib) }

        var store = FrameFingerprintStore(libraryURL: lib)
        store.setHashes([1, 2, 3], relativePath: "a.mp4", sizeBytes: 1000, modified: 500)
        store.setHashes([9], relativePath: "gone.mp4", sizeBytes: 1, modified: 1)
        store.save(keepingPaths: ["a.mp4"]) // "gone.mp4" pruned

        let reloaded = FrameFingerprintStore(libraryURL: lib)
        XCTAssertEqual(reloaded.validHashes(relativePath: "a.mp4", sizeBytes: 1000, modified: 500), [1, 2, 3])
        XCTAssertNil(reloaded.validHashes(relativePath: "gone.mp4", sizeBytes: 1, modified: 1), "pruned entries don't survive")
        XCTAssertNil(reloaded.validHashes(relativePath: "a.mp4", sizeBytes: 2000, modified: 500), "size change invalidates")
        XCTAssertNil(reloaded.validHashes(relativePath: "a.mp4", sizeBytes: 1000, modified: 9999), "mtime change invalidates")
    }
}
