// FrameCache.swift
// Bounded cache and concurrency gate for extracted video frames (issue #4, F1).
//
// The 4x4 detail grid decoded every frame on every appearance, so re-opening a
// video paid the full cost again. Measured baseline: 3.80 s wall clock per grid
// load, 192.5 MiB allocated — 6.6x the raw pixel cost — with 4 of 10 measured
// loads being repeat views that were not cheaper.
//
// Lives in LibraryCore, and takes the decode as a closure, so the caching and
// concurrency behaviour can be unit-tested by COUNTING invocations. No
// AVFoundation here: this file knows nothing about how a frame is produced.

import Foundation
import CoreGraphics

/// Bounds how many decodes may run at once.
///
/// Sixteen simultaneous hardware decoders is the shape the audit objected to.
/// Note the measured caveat: decode is at most ~19.6% of CPU, so throttling too
/// hard risks *increasing* wall clock — now F1's primary metric. The limit is a
/// named constant precisely so it can be tuned against measurement rather than
/// guessed at once and forgotten.
public actor DecodeGate {
    private let limit: Int
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    public func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    public func release() {
        if waiting.isEmpty {
            active = max(0, active - 1)
        } else {
            // Hand the slot straight to the next waiter; `active` is unchanged
            // because ownership transfers rather than being released.
            waiting.removeFirst().resume()
        }
    }

    /// Test seam: how many decodes are running and queued right now.
    public var stats: (active: Int, waiting: Int) { (active, waiting.count) }
}

/// LRU cache of decoded frames, keyed by asset and timestamp.
public actor FrameCache {

    /// Frames retained across grid loads. Sixteen per grid, so this holds two
    /// recently-viewed videos.
    ///
    /// Measured trade: an 800x600 frame is ~1.83 MiB, so capacity 64 retained
    /// ~117 MiB and pushed persistent memory from 48.4 to 112.7 MiB. Capacity 32
    /// keeps the common back-and-forth case free (~59 MiB) while halving that
    /// cost — the 10-load / 6-video measurement never exercised 64 usefully.
    public static let defaultCapacity = 32

    /// Simultaneous decodes permitted. See `DecodeGate` for why this is a
    /// constant rather than an inline literal.
    public static let maxConcurrentDecodes = 6

    public static let shared = FrameCache()

    private var entries: [String: CGImage] = [:]
    private var recency: [String] = []          // oldest first
    private let capacity: Int
    private let gate: DecodeGate

    public init(capacity: Int = FrameCache.defaultCapacity,
                concurrentDecodes: Int = FrameCache.maxConcurrentDecodes) {
        self.capacity = max(1, capacity)
        self.gate = DecodeGate(limit: concurrentDecodes)
    }

    /// Cache key. The timestamp is rounded to milliseconds so floating-point
    /// noise in a recomputed time cannot produce a spurious miss.
    public nonisolated static func key(assetKey: String, timeSeconds: Double) -> String {
        let ms = (timeSeconds * 1000).rounded()
        return "\(assetKey)@\(Int(ms))"
    }

    public func cached(_ key: String) -> CGImage? {
        guard let image = entries[key] else { return nil }
        touch(key)
        return image
    }

    public func store(_ image: CGImage, for key: String) {
        if entries[key] == nil, entries.count >= capacity, let oldest = recency.first {
            entries.removeValue(forKey: oldest)
            recency.removeFirst()
        }
        entries[key] = image
        touch(key)
    }

    /// Returns a cached frame, or produces one via `decode` while holding a
    /// concurrency slot. The decode runs OUTSIDE this actor's isolation, so
    /// several may proceed at once up to the gate's limit.
    ///
    /// A cache hit never touches the gate — that is what makes re-opening a
    /// previously viewed video free rather than merely faster.
    public func image(for key: String, decode: @Sendable @escaping () async -> CGImage?) async -> CGImage? {
        if let hit = cached(key) { return hit }

        await gate.acquire()
        let produced = await decode()
        await gate.release()

        if let produced { store(produced, for: key) }
        return produced
    }

    // MARK: - Test seams

    public var count: Int { entries.count }
    public func contains(_ key: String) -> Bool { entries[key] != nil }
    public func removeAll() { entries.removeAll(); recency.removeAll() }

    private func touch(_ key: String) {
        if let i = recency.firstIndex(of: key) { recency.remove(at: i) }
        recency.append(key)
    }
}
