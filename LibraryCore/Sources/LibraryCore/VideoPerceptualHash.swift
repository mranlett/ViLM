// VideoPerceptualHash.swift
// A 64-bit perceptual fingerprint of a video's visual content.
//
// Unlike a file hash, this survives re-encoding, re-muxing and resizing — two
// copies of the same footage at different bitrates produce the same value, or
// one within a couple of bits of it. That is what makes it useful for
// recognising a video whose bytes have changed.
//
// The construction is fixed by interoperability, not by preference: it matches
// the convention community metadata databases index against, so a hash computed
// here can be looked up directly. Every constant below is load-bearing —
// changing the frame count, the sprite layout, the scaling or the greyscale
// weights produces a valid-looking hash that matches nothing.
//
//   25 frames (5x5), sampled across the middle 90% of the running time
//   each scaled to 160px wide, aspect preserved
//   tiled left-to-right, top-to-bottom into one sprite
//   sprite squashed to 64x64, greyscaled, 2-D DCT-II (unscaled)
//   top-left 8x8 coefficients, bit set where the coefficient exceeds their
//   median, first coefficient in the most significant bit
//
// Measured against a live database: mean 2 bits from the recorded value across
// a ground-truth sample, one exact. The database's own contributors differ from
// each other by 2-4 bits, so that is inside the algorithm's natural spread.

import Foundation
import AVFoundation
import CoreGraphics

public enum VideoPerceptualHash {

    public static let columns = 5
    public static let rows = 5
    public static let frameCount = 25
    public static let frameWidth = 160

    // MARK: - Pure

    /// Timestamps to sample, in seconds.
    ///
    /// The first and last 5% are skipped: titles, studio idents and end cards
    /// are shared across many videos from one source and would pull unrelated
    /// releases toward the same hash.
    public static func sampleTimes(duration: Double) -> [Double] {
        guard duration.isFinite, duration > 0 else { return [] }
        let offset = 0.05 * duration
        let step = (0.9 * duration) / Double(frameCount)
        return (0..<frameCount).map { offset + Double($0) * step }
    }

    /// Greyscale weights applied to 8-bit channel values.
    ///
    /// The blue divisor is 256 where red and green use 257 — an inconsistency
    /// in the reference implementation. For 8-bit channels it makes no
    /// difference at all: integer truncation gives the same result for every
    /// one of the 256 possible values. It is reproduced rather than tidied
    /// because the reference operates on 16-bit channel values, where the two
    /// divisors genuinely diverge, and this needs to stay a faithful port
    /// rather than an improved one.
    static func luminance(r: UInt8, g: UInt8, b: UInt8) -> Double {
        let r32 = UInt32(r) * 257, g32 = UInt32(g) * 257, b32 = UInt32(b) * 257
        return 0.299 * Double(r32 / 257) + 0.587 * Double(g32 / 257) + 0.114 * Double(b32 / 256)
    }

    /// DCT-II, unscaled: `X[k] = Σ x[i]·cos(π/N·(i+½)·k)`.
    static func dct(_ input: [Double]) -> [Double] {
        let n = input.count
        var out = [Double](repeating: 0, count: n)
        for k in 0..<n {
            var sum = 0.0
            for i in 0..<n {
                sum += input[i] * cos(Double.pi / Double(n) * (Double(i) + 0.5) * Double(k))
            }
            out[k] = sum
        }
        return out
    }

    /// The hash of an already-greyscaled 64x64 image, row-major from the top.
    ///
    /// Split out from the frame handling so the arithmetic can be tested
    /// without decoding a video.
    public static func hash(greyscale64: [Double]) -> UInt64? {
        guard greyscale64.count == 64 * 64 else { return nil }

        var matrix = greyscale64
        for row in 0..<64 {
            let transformed = dct(Array(matrix[(row * 64)..<(row * 64 + 64)]))
            for col in 0..<64 { matrix[row * 64 + col] = transformed[col] }
        }

        // Only the first eight columns survive, so only those are transformed.
        var coefficients = [Double](repeating: 0, count: 64)
        for col in 0..<8 {
            var column = [Double](repeating: 0, count: 64)
            for row in 0..<64 { column[row] = matrix[64 * row + col] }
            let transformed = dct(column)
            for row in 0..<8 { coefficients[8 * row + col] = transformed[row] }
        }

        let sorted = coefficients.sorted()
        let median = (sorted[31] + sorted[32]) / 2

        var value: UInt64 = 0
        for (index, coefficient) in coefficients.enumerated() where coefficient > median {
            value |= (1 << UInt64(63 - index))
        }
        return value
    }

    /// Bits that differ. Two videos are the same content at a small distance;
    /// unrelated videos sit near 32, which is what chance looks like on 64 bits.
    public static func distance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    /// Formatted as the 16 lowercase hex digits databases index on.
    public static func hexString(_ value: UInt64) -> String {
        String(format: "%016llx", value)
    }

    // MARK: - From a file

    public enum HashError: Error, Sendable {
        case unreadable
        case tooShort
        /// Fewer frames decoded than the sprite needs. A partial sprite hashes
        /// to something confident and wrong, so it is refused rather than
        /// padded.
        case incompleteFrames(got: Int, want: Int)
    }

    public static func compute(contentsOf url: URL) async throws -> UInt64 {
        let asset = AVURLAsset(url: url)
        let duration: Double
        if #available(macOS 13.0, iOS 16.0, *) {
            duration = try await CMTimeGetSeconds(asset.load(.duration))
        } else {
            duration = CMTimeGetSeconds(asset.duration)
        }
        guard duration.isFinite, duration > 0 else { throw HashError.unreadable }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Exact seeking: snapping to the nearest keyframe would sample
        // different content on every re-encode, which is what this is meant to
        // see through.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        var frames: [CGImage] = []
        for seconds in sampleTimes(duration: duration) {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            guard let image = try? generator.copyCGImage(at: time, actualTime: nil) else { continue }
            guard let scaled = scale(image, toWidth: frameWidth) else { continue }
            frames.append(scaled)
        }
        guard frames.count == frameCount else {
            throw HashError.incompleteFrames(got: frames.count, want: frameCount)
        }
        guard let sprite = tile(frames), let pixels = greyscale64(sprite) else {
            throw HashError.unreadable
        }
        guard let value = hash(greyscale64: pixels) else { throw HashError.unreadable }
        return value
    }

    /// Height is rounded to an even number, matching the scaler the reference
    /// implementation drives.
    static func scale(_ image: CGImage, toWidth width: Int) -> CGImage? {
        guard image.width > 0 else { return nil }
        let exact = Double(width) * Double(image.height) / Double(image.width)
        let rounded = Int(exact.rounded())
        let height = rounded % 2 == 0 ? rounded : rounded + 1
        guard height > 0 else { return nil }
        return draw(width: width, height: height) { context in
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    static func tile(_ frames: [CGImage]) -> CGImage? {
        guard let first = frames.first else { return nil }
        let w = first.width, h = first.height
        return draw(width: w * columns, height: h * rows) { context in
            for (index, frame) in frames.enumerated() {
                // Core Graphics puts the origin bottom-left while the sprite is
                // laid out top-down, so the row index is inverted here. It is
                // NOT inverted again when the pixels are read back — doing both
                // mirrors the sprite and scrambles every high-frequency
                // coefficient, which reads as a hash that matches nothing.
                let x = w * (index % columns)
                let y = h * (rows - 1 - index / columns)
                context.draw(frame, in: CGRect(x: x, y: y, width: w, height: h))
            }
        }
    }

    static func greyscale64(_ image: CGImage) -> [Double]? {
        var buffer = [UInt8](repeating: 0, count: 64 * 64 * 4)
        let ok: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: 64, height: 64,
                                          bitsPerComponent: 8, bytesPerRow: 64 * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
            return true
        }
        guard ok else { return nil }

        var pixels = [Double](repeating: 0, count: 64 * 64)
        for row in 0..<64 {
            for col in 0..<64 {
                let offset = (row * 64 + col) * 4
                pixels[row * 64 + col] = luminance(r: buffer[offset],
                                                   g: buffer[offset + 1],
                                                   b: buffer[offset + 2])
            }
        }
        return pixels
    }

    private static func draw(width: Int, height: Int,
                             _ body: (CGContext) -> Void) -> CGImage? {
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        body(context)
        return context.makeImage()
    }
}
