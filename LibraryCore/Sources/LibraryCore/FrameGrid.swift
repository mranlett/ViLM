// FrameGrid.swift
// Pure geometry and timing for the 4x4 detail frame grid.
//
// Extracted from DetailGridView so the grid's CONTRACT — which timestamps are
// sampled, in what order, and how the display aspect ratio is derived — can be
// pinned by unit tests. Both are pure functions of their inputs, so they need no
// video fixture and no AVFoundation.
//
// This exists so the F1 optimisation (bounding concurrent decodes and caching
// results) can be shown not to change WHICH frames are produced. Behaviour here
// is identical to the original inline implementation.

import Foundation
import CoreGraphics

public enum FrameGrid {

    /// A 4x4 grid.
    public static let defaultCellCount = 16

    /// The last sampled frame is pulled back from the very end of the video,
    /// because seeking to exactly `duration` commonly yields nothing decodable.
    public static let endGuardSeconds: Double = 0.25

    /// Timestamps sampled for a grid of `count` cells across a video of
    /// `duration` seconds.
    ///
    /// Frames are evenly spaced strictly *between* the endpoints — for 16 cells the
    /// sample points are at 1/17, 2/17 … 16/17 of the duration, so neither the very
    /// first nor the very last frame is used. Each is clamped to
    /// `0 ... duration - endGuardSeconds`.
    ///
    /// - Returns: `count` timestamps in ascending order, or an empty array when the
    ///   duration is not a usable positive finite number.
    public static func frameTimes(count: Int = defaultCellCount, duration: Double) -> [Double] {
        guard count > 0, duration.isFinite, duration > 0 else { return [] }
        return (0..<count).map { i in
            let t = (Double(i) + 1) / Double(count + 1) * duration
            return min(max(0, t), max(0, duration - endGuardSeconds))
        }
    }

    /// Display aspect ratio for a video track, honouring its preferred transform
    /// so rotated footage is described by how it will be SHOWN rather than how it
    /// is stored.
    ///
    /// - Returns: `nil` when the transformed height is zero, so callers can keep
    ///   whatever default they already hold rather than dividing by zero.
    public static func aspectRatio(naturalSize: CGSize, transform: CGAffineTransform) -> CGFloat? {
        let transformed = naturalSize.applying(transform)
        let width = abs(transformed.width)
        let height = abs(transformed.height)
        guard height > 0 else { return nil }
        return width / height
    }
}
