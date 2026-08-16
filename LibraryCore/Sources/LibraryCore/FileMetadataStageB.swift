// FileMetadataStageB.swift
// F6 — duration, dimensions and codec, so a display read stops reopening the
// file (#10).
//
// 🚨 MATERIALLY SLOWER THAN STAGE A, and the whole design follows from that.
// Stage A is a stat call; this opens every file and parses container headers,
// at a cost that depends on the codec. So it must be interruptible, must never
// be blocked by one damaged file, and must be safe to never run at all — the
// columns simply stay null and every reader falls back to AVFoundation exactly
// as before.
//
// ⚠️ DISPLAY reads only. Editing, transcoding and contact-sheet generation keep
// constructing their own assets: they need tracks, transforms and sample
// buffers, not four numbers, and serving them from a cache would be a
// correctness risk for a saving they do not need.

import Foundation

/// What opening a file tells us.
public struct MediaFacts: Equatable, Sendable {
    public let duration: Double
    public let width: Int
    public let height: Int
    public let codec: String?

    public init(duration: Double, width: Int, height: Int, codec: String?) {
        self.duration = duration
        self.width = width
        self.height = height
        self.codec = codec
    }
}

/// What a Stage B pass did. ⚠️ The buckets sum to the input.
public struct StageBSummary: Equatable, Sendable {
    public var measured = 0
    /// Already measured and the file has not changed since.
    public var unchanged = 0
    /// 🚨 Opened and could not be read — damaged, exotic, or not really video.
    /// Counted and named rather than skipped silently, because "we measured
    /// 1,290 of 1,300" with no list is a dead end for the one person who could
    /// do something about the other ten.
    public var unreadable: [String] = []
    public var remaining = 0

    public var considered: Int { measured + unchanged + unreadable.count + remaining }
}

public enum FileMetadataStageB {

    /// Whether the recorded media facts still describe the file.
    ///
    /// ⭐ Present means current UNLESS the file can be shown to have changed.
    /// The alternative — requiring a matching `modifiedAt` — would re-open
    /// every file in a library where Stage A had not run, which is the one
    /// outcome this stage must never produce by accident.
    static func isCurrent(_ asset: Asset, modifiedOnDisk: Date?) -> Bool {
        guard asset.duration != nil, asset.width != nil,
              asset.height != nil else { return false }
        guard let recorded = asset.modifiedAt, let onDisk = modifiedOnDisk else { return true }
        return abs(recorded.timeIntervalSince(onDisk)) <= FileMetadataStageA.storageGranularity
    }

    /// Populates duration, dimensions and codec for everything that needs it.
    ///
    /// - Parameters:
    ///   - measure: opens the file. Returns nil when it cannot be read — which
    ///     is a normal outcome here, not an error.
    ///   - modifiedOnDisk: the cheap check, so a file that has not changed is
    ///     never opened at all.
    @discardableResult
    public static func backfill(_ assets: [Asset],
                                modifiedOnDisk: (Asset) -> Date?,
                                measure: (Asset) -> MediaFacts?,
                                isCancelled: () -> Bool = { false },
                                onProgress: (StageBSummary) -> Void = { _ in },
                                write: (Asset) throws -> Void) rethrows -> StageBSummary {
        var summary = StageBSummary()

        for (index, asset) in assets.enumerated() {
            if isCancelled() {
                summary.remaining = assets.count - index
                break
            }

            guard !isCurrent(asset, modifiedOnDisk: modifiedOnDisk(asset)) else {
                summary.unchanged += 1
                continue
            }

            guard let facts = measure(asset) else {
                // 🚨 Never blocks the run. One damaged file must not cost the
                // other twelve hundred, and the row keeps whatever it had.
                summary.unreadable.append(asset.relativePath)
                continue
            }

            var updated = asset
            updated.duration = facts.duration
            updated.width = facts.width
            updated.height = facts.height
            updated.codec = facts.codec
            try write(updated)
            summary.measured += 1
            onProgress(summary)
        }

        return summary
    }

    /// What the inspector should show, and whether it had to open the file.
    ///
    /// 🚨 The acceptance criterion in testable form: "the inspector constructs
    /// no AVURLAsset" is a claim about a view, and this project has repeatedly
    /// been unable to assert anything about a view. The decision is here, where
    /// a test can count the openings.
    public static func display(for asset: Asset,
                               opening: (Asset) -> MediaFacts?) -> (facts: MediaFacts?, opened: Bool) {
        if let duration = asset.duration, let width = asset.width, let height = asset.height {
            return (MediaFacts(duration: duration, width: width, height: height,
                               codec: asset.codec), false)
        }
        return (opening(asset), true)
    }
}
