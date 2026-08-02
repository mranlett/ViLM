import XCTest
import CoreGraphics
@testable import LibraryCore

/// Tests for the frame cache and decode gate (issue #4, F1).
///
/// The decode is injected as a closure, so these assert the property that
/// matters — HOW MANY DECODES HAPPEN — without needing AVFoundation or a video
/// fixture. F1's headline acceptance criteria are decode counts.
/// A 1x1 image; identity is irrelevant here, only how often one is produced.
/// Free function so the @Sendable decode closures never capture the test case.
private func makeImage() -> CGImage {
    let cs = CGColorSpaceCreateDeviceGray()
    let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                        bytesPerRow: 1, space: cs,
                        bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    return ctx.makeImage()!
}

final class FrameCacheTests: XCTestCase {

    /// Thread-safe invocation counter for the injected decode.
    private actor Counter {
        private(set) var value = 0
        func bump() { value += 1 }
    }

    // MARK: - Keys

    func testKeyCombinesAssetAndTimestamp() async {
        let a = FrameCache.key(assetKey: "video-1", timeSeconds: 10)
        let b = FrameCache.key(assetKey: "video-2", timeSeconds: 10)
        let c = FrameCache.key(assetKey: "video-1", timeSeconds: 20)
        XCTAssertNotEqual(a, b, "different videos are different frames")
        XCTAssertNotEqual(a, c, "different timestamps are different frames")
    }

    func testKeyToleratesFloatingPointNoiseInTheTimestamp() async {
        // computeTimes derives timestamps by division; recomputing can land a
        // hair off. Rounding to milliseconds keeps that a cache HIT.
        let exact = FrameCache.key(assetKey: "v", timeSeconds: 12.3456789)
        let noisy = FrameCache.key(assetKey: "v", timeSeconds: 12.3456791)
        XCTAssertEqual(exact, noisy)
    }

    func testKeySeparatesGenuinelyDifferentTimestamps() async {
        XCTAssertNotEqual(FrameCache.key(assetKey: "v", timeSeconds: 12.340),
                          FrameCache.key(assetKey: "v", timeSeconds: 12.342))
    }

    // MARK: - Decode counting (the acceptance criteria)

    func testASecondRequestForTheSameFrameDoesNotDecodeAgain() async {
        let cache = FrameCache()
        let counter = Counter()
        let key = FrameCache.key(assetKey: "v", timeSeconds: 1)

        for _ in 0..<5 {
            _ = await cache.image(for: key) {
                await counter.bump()
                return makeImage()
            }
        }
        let decodes = await counter.value
        XCTAssertEqual(decodes, 1, "five requests, one decode")
    }

    func testReopeningAGridDecodesNothing() async {
        // The measured scenario: 16 frames, viewed, then viewed again.
        let cache = FrameCache()
        let counter = Counter()
        let times = (0..<16).map { Double($0) * 10 }

        func loadGrid() async {
            for t in times {
                _ = await cache.image(for: FrameCache.key(assetKey: "v", timeSeconds: t)) {
                    await counter.bump()
                    return makeImage()
                }
            }
        }

        await loadGrid()
        let afterFirst = await counter.value
        await loadGrid()
        let afterSecond = await counter.value

        XCTAssertEqual(afterFirst, 16, "first load decodes each frame once")
        XCTAssertEqual(afterSecond, 16, "re-opening performs ZERO additional decodes")
    }

    func testDifferentVideosDoNotShareFrames() async {
        let cache = FrameCache()
        let counter = Counter()
        for asset in ["v1", "v2"] {
            _ = await cache.image(for: FrameCache.key(assetKey: asset, timeSeconds: 5)) {
                await counter.bump()
                return makeImage()
            }
        }
        let decodes = await counter.value
        XCTAssertEqual(decodes, 2)
    }

    func testAFailedDecodeIsNotCached() async {
        let cache = FrameCache()
        let counter = Counter()
        let key = FrameCache.key(assetKey: "v", timeSeconds: 1)

        for _ in 0..<3 {
            _ = await cache.image(for: key) {
                await counter.bump()
                return nil            // e.g. a seek past the end of a damaged file
            }
        }
        let decodes = await counter.value
        XCTAssertEqual(decodes, 3, "a nil result must be retried, not remembered as a hit")
    }

    // MARK: - Eviction

    func testTheCacheIsBoundedAndEvictsLeastRecentlyUsed() async {
        let cache = FrameCache(capacity: 3)
        for i in 0..<3 {
            _ = await cache.image(for: "k\(i)") { makeImage() }
        }
        _ = await cache.cached("k0")          // k0 becomes most recent
        _ = await cache.image(for: "k3") { makeImage() }   // evicts k1

        let count = await cache.count
        let hasK0 = await cache.contains("k0")
        let hasK1 = await cache.contains("k1")
        let hasK3 = await cache.contains("k3")
        XCTAssertEqual(count, 3, "capacity is respected")
        XCTAssertTrue(hasK0, "recently used entries survive")
        XCTAssertFalse(hasK1, "the least recently used entry is evicted")
        XCTAssertTrue(hasK3)
    }

    func testCapacityIsNeverBelowOne() async {
        let cache = FrameCache(capacity: 0)
        _ = await cache.image(for: "k") { makeImage() }
        let count = await cache.count
        XCTAssertEqual(count, 1)
    }

    // MARK: - Concurrency gate

    func testTheGateNeverExceedsItsLimit() async {
        let gate = DecodeGate(limit: 3)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await gate.acquire()
                    let (active, _) = await gate.stats
                    XCTAssertLessThanOrEqual(active, 3, "never more than the limit in flight")
                    await gate.release()
                }
            }
        }
        let (active, waiting) = await gate.stats
        XCTAssertEqual(active, 0, "every slot is returned")
        XCTAssertEqual(waiting, 0, "nothing is left queued")
    }

    func testEveryQueuedDecodeEventuallyRuns() async {
        let gate = DecodeGate(limit: 2)
        let counter = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    await gate.acquire()
                    await counter.bump()
                    await gate.release()
                }
            }
        }
        let completed = await counter.value
        XCTAssertEqual(completed, 50, "no waiter is stranded")
    }

    func testConcurrentRequestsForTheSameFrameAllResolve() async {
        let cache = FrameCache()
        let key = FrameCache.key(assetKey: "v", timeSeconds: 3)
        let results = await withTaskGroup(of: Bool.self) { group -> [Bool] in
            for _ in 0..<16 {
                group.addTask {
                    await cache.image(for: key) { makeImage() } != nil
                }
            }
            var out: [Bool] = []
            for await r in group { out.append(r) }
            return out
        }
        XCTAssertEqual(results.count, 16)
        XCTAssertTrue(results.allSatisfy { $0 }, "every caller gets an image")
    }

    func testNamedConstantsAreExposedForTuning() {
        XCTAssertGreaterThan(FrameCache.maxConcurrentDecodes, 0)
        XCTAssertGreaterThanOrEqual(FrameCache.defaultCapacity, 16, "at least one full grid")
    }
}
