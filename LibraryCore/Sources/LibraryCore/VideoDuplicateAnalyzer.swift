// VideoDuplicateAnalyzer.swift
// Content-aware duplicate detection for videos in one library. Exact-byte-size
// matching only finds bit-identical copies; the common real-world duplicates
// are (a) the *same content in a different encode* (another resolution,
// bitrate, or container) and (b) the *same content trimmed* (e.g. the first
// 30s cut off one copy). Both are found the same way: frames are sampled on a
// fixed time grid (every 5s), each reduced to a 64-bit perceptual
// difference-hash, and two videos match when their hash sequences align at
// some offset with enough close frames. A same-length re-encode aligns at
// offset 0; a front-trimmed copy aligns at the trim offset. Pure math +
// CoreGraphics + AVFoundation; no ML, no bundled model.

import Foundation
import CoreGraphics
import AVFoundation

public enum VideoDuplicateAnalyzer {

    // MARK: - Tunables (v1 constants)

    /// Frames are sampled on this fixed grid (seconds), starting at
    /// `firstSampleSecond` — time-anchored (not percentage-based) so a
    /// trimmed copy's samples still line up with the original's at a shifted
    /// index. Sub-grid trim offsets leave at most interval/2 of phase error,
    /// which the per-frame Hamming tolerance absorbs in continuous scenes.
    public static let intervalSeconds: Double = 5.0
    /// Skip the very start (fades/logos) for the first sample.
    public static let firstSampleSecond: Double = 2.0
    /// Cap on samples per video (48 ⇒ the first ~4 minutes are fingerprinted;
    /// content trimmed by more than that window can't be aligned).
    public static let maxIntervalSamples = 48
    /// Two frames "match" when their 64-bit hashes differ by at most this many bits.
    public static let maxBitsPerFrame = 10
    /// An alignment needs at least this many overlapping samples to be judged.
    public static let minOverlapFrames = 4
    /// Videos whose durations differ by more than this are never compared
    /// (bounds the "reasonable trim" we look for).
    public static let maxTrimSeconds: Double = 600

    // MARK: - Perceptual hash (pure)

    /// 64-bit difference-hash: the image is downscaled to a 9×8 grayscale
    /// grid and each bit records whether a pixel is brighter than its right
    /// neighbor. Robust to re-encoding, scaling, and mild color shifts —
    /// which is exactly what distinguishes "same content, different encode"
    /// from "different content."
    public static func dHash(of image: CGImage) -> UInt64 {
        let width = 9, height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 0 }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var hash: UInt64 = 0
        var bit = 0
        for row in 0..<height {
            for col in 0..<(width - 1) {
                let left = pixels[row * width + col]
                let right = pixels[row * width + col + 1]
                if left > right { hash |= (1 << UInt64(bit)) }
                bit += 1
            }
        }
        return hash
    }

    public static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    // MARK: - Interval sampling (pure)

    /// The time-grid sample points for a video of the given duration:
    /// `firstSampleSecond`, then every `intervalSeconds`, capped at
    /// `maxIntervalSamples`, staying half a second clear of the end.
    public static func intervalSampleTimes(durationSeconds: Double) -> [Double] {
        guard durationSeconds.isFinite, durationSeconds > firstSampleSecond + 0.5 else { return [] }
        var times: [Double] = []
        var t = firstSampleSecond
        while t <= durationSeconds - 0.5, times.count < maxIntervalSamples {
            times.append(t)
            t += intervalSeconds
        }
        return times
    }

    // MARK: - Offset alignment (pure)

    /// The result of aligning a shorter fingerprint sequence within a longer
    /// one: at which sample offset the shorter sequence starts, and how many
    /// of the overlapping frames matched.
    public struct AlignmentMatch: Equatable, Sendable {
        public let offsetSamples: Int      // shorter sequence's start index within the longer
        public let matchingFrames: Int
        public let overlap: Int
        /// The content offset in seconds implied by the alignment (e.g. 30
        /// for a copy with its first 30 seconds trimmed off).
        public var offsetSeconds: Double { Double(offsetSamples) * VideoDuplicateAnalyzer.intervalSeconds }
    }

    /// Slides the shorter sequence across the longer one (argument order
    /// doesn't matter) and returns the best alignment — the shift with the
    /// most fuzzy-matching frames — provided it clears the match rule:
    /// at least `minOverlapFrames` overlapping samples, of which at least
    /// half (and never fewer than `minOverlapFrames`) match within
    /// `maxBitsPerFrame`. A same-length re-encode aligns at offset 0; a
    /// front-trimmed copy aligns at its trim offset. Returns nil when no
    /// shift qualifies (different content).
    public static func bestAlignment(
        _ first: [UInt64], _ second: [UInt64],
        maxBitsPerFrame: Int = maxBitsPerFrame,
        minOverlap: Int = minOverlapFrames
    ) -> AlignmentMatch? {
        let longer = first.count >= second.count ? first : second
        let shorter = first.count >= second.count ? second : first
        guard shorter.count >= minOverlap else { return nil }

        var best: AlignmentMatch?
        for offset in 0...(longer.count - shorter.count) {
            let overlap = shorter.count
            var matching = 0
            for i in 0..<overlap where hammingDistance(longer[offset + i], shorter[i]) <= maxBitsPerFrame {
                matching += 1
            }
            let required = max(minOverlap, (overlap + 1) / 2)
            guard matching >= required else { continue }
            if best == nil || matching > best!.matchingFrames {
                best = AlignmentMatch(offsetSamples: offset, matchingFrames: matching, overlap: overlap)
            }
        }
        return best
    }

    // MARK: - Duration windows (pure)

    /// Clusters ids whose durations sit within `tolerance` seconds of a
    /// neighbor (sorted sliding window, so chains group together). Only
    /// clusters with 2+ members are returned — these are the candidate sets
    /// worth fingerprinting.
    public static func durationWindows(
        _ items: [(id: UUID, seconds: Double)],
        tolerance: Double = maxTrimSeconds
    ) -> [[UUID]] {
        guard items.count > 1 else { return [] }
        let sorted = items.sorted { $0.seconds < $1.seconds }
        var windows: [[UUID]] = []
        var current: [UUID] = [sorted[0].id]
        var lastSeconds = sorted[0].seconds
        for item in sorted.dropFirst() {
            if item.seconds - lastSeconds <= tolerance {
                current.append(item.id)
            } else {
                if current.count > 1 { windows.append(current) }
                current = [item.id]
            }
            lastSeconds = item.seconds
        }
        if current.count > 1 { windows.append(current) }
        return windows
    }

    // MARK: - Pair grouping (pure)

    /// Connected components over matched pairs: if A~B and B~C, all three form
    /// one duplicate group.
    public static func groupMatchedPairs(_ pairs: [(UUID, UUID)]) -> [[UUID]] {
        var parent: [UUID: UUID] = [:]
        func find(_ x: UUID) -> UUID {
            var root = x
            while let p = parent[root], p != root { root = p }
            parent[x] = root
            return root
        }
        func union(_ a: UUID, _ b: UUID) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
        for (a, b) in pairs {
            if parent[a] == nil { parent[a] = a }
            if parent[b] == nil { parent[b] = b }
            union(a, b)
        }
        var components: [UUID: [UUID]] = [:]
        for key in parent.keys {
            components[find(key), default: []].append(key)
        }
        return components.values.filter { $0.count > 1 }.map { $0.sorted { $0.uuidString < $1.uuidString } }
    }

    // MARK: - Frame fingerprinting (AVFoundation — verified on-device)

    /// Samples frames on the fixed time grid and returns their perceptual
    /// hashes. Frames that can't be generated are skipped. Returns [] when
    /// nothing is readable — such a video simply never matches. Frames are
    /// decoded transiently and discarded; only the 8-byte hashes survive.
    public static func intervalFingerprint(videoURL: URL) async -> [UInt64] {
        let avAsset = AVURLAsset(url: videoURL)
        guard let seconds = try? await avAsset.load(.duration).seconds,
              seconds.isFinite, seconds > 0 else { return [] }

        let generator = AVAssetImageGenerator(asset: avAsset)
        generator.appliesPreferredTrackTransform = true
        // Small decode target: the hash only needs a 9×8 grid anyway.
        generator.maximumSize = CGSize(width: 160, height: 90)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        var hashes: [UInt64] = []
        for t in intervalSampleTimes(durationSeconds: seconds) {
            let time = CMTime(seconds: t, preferredTimescale: 600)
            if let image = try? await generator.image(at: time).image {
                hashes.append(dHash(of: image))
            }
        }
        return hashes
    }
}

// MARK: - Persisted fingerprint cache

/// Tiny on-disk cache of interval fingerprints under
/// `.catalog/framePrints/fingerprints.json`, keyed by relative path and
/// validated against file size + modification date — so an edited (trimmed/
/// flipped/replaced) file automatically re-fingerprints, while unchanged
/// files skip the expensive frame decoding on every later scan. ~400 bytes
/// per video; entries for paths no longer passed to `save` are pruned.
/// Purely a performance cache: safe to delete, silently rebuilt.
public struct FrameFingerprintStore {

    public struct Entry: Codable, Sendable, Equatable {
        public let sizeBytes: Int64
        public let modified: TimeInterval
        public let hashes: [UInt64]
        public init(sizeBytes: Int64, modified: TimeInterval, hashes: [UInt64]) {
            self.sizeBytes = sizeBytes
            self.modified = modified
            self.hashes = hashes
        }
    }

    public private(set) var entries: [String: Entry]
    private let fileURL: URL

    public init(libraryURL: URL) {
        fileURL = libraryURL.appendingPathComponent(".catalog/framePrints/fingerprints.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    /// Cached hashes for a file, or nil when absent or stale (size/mtime moved).
    public func validHashes(relativePath: String, sizeBytes: Int64, modified: TimeInterval) -> [UInt64]? {
        guard let entry = entries[relativePath],
              entry.sizeBytes == sizeBytes,
              abs(entry.modified - modified) < 1.0 else { return nil }
        return entry.hashes
    }

    public mutating func setHashes(_ hashes: [UInt64], relativePath: String, sizeBytes: Int64, modified: TimeInterval) {
        entries[relativePath] = Entry(sizeBytes: sizeBytes, modified: modified, hashes: hashes)
    }

    /// Drops one entry (used when a video is deleted or moved out of this
    /// library, so its fingerprint leaves with it).
    public mutating func removeEntry(relativePath: String) {
        entries.removeValue(forKey: relativePath)
    }

    /// Writes the cache without pruning — for targeted updates (a moved-in
    /// video's carried fingerprint, a removed entry) where the caller doesn't
    /// have the full library path list. Best-effort, like `save(keepingPaths:)`.
    public mutating func save() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Writes the cache, dropping entries for paths not in `keepingPaths`
    /// (deleted/renamed videos don't accumulate dead entries). Best-effort by
    /// design — this is a regenerable cache, so a failed save only costs a
    /// future re-fingerprint, never correctness.
    public mutating func save(keepingPaths: Set<String>) {
        entries = entries.filter { keepingPaths.contains($0.key) }
        save()
    }
}
