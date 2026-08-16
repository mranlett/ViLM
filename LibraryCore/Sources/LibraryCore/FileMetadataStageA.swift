// FileMetadataStageA.swift
// F5 — persisting what a stat call already knows (#9).
//
// 🚨 THE DEFECT IS MISSING PERSISTENCE, NOT THREADING. The audit reported that
// sorting by size re-stats every file on the main thread. Half of that was
// wrong: the read already runs in `Task.detached(priority: .utility)`, off-main
// and downgraded. What is actually wrong is that the answer is thrown away and
// re-derived on the next sort, for every file, forever.
//
// ⭐ Resumable BY CONSTRUCTION rather than by a checkpoint. The work list is
// "rows with no size, plus rows the disk disagrees with", so a run killed
// halfway simply has less to do next time. There is no progress cursor to keep
// consistent, which is the kind of state that goes wrong exactly when the
// process died — the case it exists for.

import Foundation

/// What the filesystem says about a file.
public struct FileFacts: Equatable, Sendable {
    public let size: Int64
    public let modified: Date

    public init(size: Int64, modified: Date) {
        self.size = size
        self.modified = modified
    }
}

/// What a Stage A pass did. ⚠️ The buckets sum to the input.
public struct StageASummary: Equatable, Sendable {
    /// Had nothing recorded; now measured.
    public var measured = 0
    /// Had values, and the file has changed on disk since.
    public var refreshed = 0
    /// Already correct — deliberately NOT rewritten.
    public var unchanged = 0
    /// No file to measure. The row is untouched, not blanked.
    public var missing = 0
    /// Not reached because the pass was cancelled.
    public var remaining = 0

    public var considered: Int { measured + refreshed + unchanged + missing + remaining }
}

public enum FileMetadataStageA {

    /// 🚨 A STORED date and a live one are not comparable exactly.
    ///
    /// SQLite rounds a stored `Date` to the millisecond, so a value written
    /// from `FileManager` reads back microseconds away from what went in.
    /// Comparing them with `==` would mark every single row stale on every
    /// pass — rewriting the whole table forever while reporting it as
    /// "refreshed", which looks like the feature working.
    ///
    /// ⚠️ This is the same precision boundary that broke `shouldPropagate`, and
    /// it is written down here rather than rediscovered.
    static let storageGranularity: TimeInterval = 0.001

    /// Whether the recorded facts still describe the file on disk.
    static func isCurrent(_ asset: Asset, _ facts: FileFacts) -> Bool {
        guard let size = asset.fileSize, let modified = asset.modifiedAt else { return false }
        guard size == facts.size else { return false }
        return abs(modified.timeIntervalSince(facts.modified)) <= storageGranularity
    }

    /// Populates size and modified date for everything that needs it.
    ///
    /// - Parameters:
    ///   - facts: the filesystem, as a seam. Returns nil when there is no file.
    ///   - isCancelled: checked before each item. Whatever has been written
    ///     stays written — a cancelled pass leaves a partly-populated library,
    ///     which is a supported state because null means "not measured yet"
    ///     and every reader falls back to the file.
    ///   - write: persists one updated asset.
    @discardableResult
    public static func backfill(_ assets: [Asset],
                                facts: (Asset) -> FileFacts?,
                                isCancelled: () -> Bool = { false },
                                onProgress: (StageASummary) -> Void = { _ in },
                                write: (Asset) throws -> Void) rethrows -> StageASummary {
        var summary = StageASummary()

        for (index, asset) in assets.enumerated() {
            if isCancelled() {
                summary.remaining = assets.count - index
                break
            }

            guard let measured = facts(asset) else {
                // ⚠️ A missing file leaves the recorded values ALONE. Blanking
                // them would destroy a good measurement because a drive
                // happened to be unplugged, and the row would then re-measure
                // from nothing the next time it is seen.
                summary.missing += 1
                continue
            }

            guard !isCurrent(asset, measured) else {
                // ⭐ Not rewritten. An unchanged row must not be touched, or a
                // backfill over an unchanged library is a full table write
                // every time it runs.
                summary.unchanged += 1
                continue
            }

            var updated = asset
            let hadValues = asset.fileSize != nil
            updated.fileSize = measured.size
            updated.modifiedAt = measured.modified
            try write(updated)

            if hadValues { summary.refreshed += 1 } else { summary.measured += 1 }
            onProgress(summary)
        }

        return summary
    }

    /// Sizes for sorting: from the catalogue where measured, from disk only
    /// for what has not been.
    ///
    /// 🚨 This is the acceptance criterion in testable form. "Sorting issues no
    /// stat calls" is a claim about a view, and a view is where this project
    /// has repeatedly been unable to assert anything — so the DECISION lives
    /// here, where a test can count how many times the fallback was reached.
    ///
    /// ⚠️ The fallback is kept rather than removed. A library that has never
    /// been backfilled, or one cancelled halfway, must still sort correctly —
    /// degrading to the old behaviour for the rows that lack a value is the
    /// whole reason the columns are nullable.
    public static func sizes(for assets: [Asset],
                             measuring: (Asset) -> Int64?) -> (sizes: [UUID: Int64], read: Int) {
        var sizes: [UUID: Int64] = [:]
        var read = 0
        for asset in assets {
            if let stored = asset.fileSize {
                sizes[asset.id] = stored
            } else if let measured = measuring(asset) {
                sizes[asset.id] = measured
                read += 1
            }
        }
        return (sizes, read)
    }
}
