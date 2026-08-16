// SidecarBackfill.swift
// Writes the `.nfo` for videos that were relocated before sidecars existed (#75).
//
// 🚨 WHY THIS IS NOT THE THING S6 ARGUES AGAINST. The sidecar spec rejects a
// separate sidecar pass, on the grounds that a pass which writes for files it
// did not move cannot know what they used to be called, and so cannot remove
// the stale document left under the old name.
//
// That objection is about REMOVING, and this backfill removes nothing. It runs
// against a library where 254 files were relocated and zero sidecars exist, so
// there is nothing to strand. ⚠️ That is true today and stops being true the
// moment any sidecar exists under an old name — a backfill written later, over
// a library that has been renamed since, carries a risk this one does not. If
// this is ever reached for again, check that assumption before trusting it.
//
// ⭐ Idempotent and ADDITIVE. A video that already has a sidecar is left
// exactly as it is, never rewritten — so running this twice costs nothing, and
// it can never overwrite a document some other tool wrote.

import Foundation

/// What a backfill did, in terms the operator can check against the library.
///
/// ⚠️ Every video is counted in exactly one bucket, so the four numbers sum to
/// the input. A summary that reports only successes lets a run that did almost
/// nothing read like a run that did everything.
public struct SidecarBackfillSummary: Equatable, Sendable {
    /// A sidecar was written where none existed.
    public var written = 0
    /// A sidecar was already there and was left alone.
    public var alreadyPresent = 0
    /// 🚨 Personal or undeclared, so nothing was written (D4). Reported rather
    /// than folded into a total, because "we wrote 40 of 254" invites the
    /// reading that 214 failed.
    public var refused = 0
    /// The write itself failed.
    public var failed = 0

    /// 🚨 A subset of `refused`: content that must have NO sidecar, which has
    /// one anyway. Not something this pass created and not something it
    /// removes — deleting a file the operator may have made deliberately is a
    /// decision, not a cleanup. It is surfaced because it is the one finding
    /// here that matters more than the backfill itself: a plaintext document
    /// naming people and places, sitting beside personal content on removable
    /// media, is exactly what D4 exists to prevent.
    public var refusedButPresent = 0

    public init() {}

    public var considered: Int { written + alreadyPresent + refused + failed }
}

public enum SidecarBackfill {

    /// Writes a sidecar for every video that may have one and does not.
    ///
    /// ⭐ Pure but for the two seams, so the rules are testable without a disk.
    /// The refusal is `MetadataSidecar.document` returning nil — deliberately
    /// the SAME decision the mover makes rather than a second reading of the
    /// content kind, because two expressions of one privacy rule is how the two
    /// drift apart with only one of them audited.
    ///
    /// - Parameters:
    ///   - assets: every video to consider. Filing state is irrelevant — a
    ///     sidecar beside a file still in the library root is just as portable
    ///     as one beside a filed video, and the point is that a file leaving
    ///     ViLM still means something.
    ///   - fileExists: does a sidecar already sit at this library-relative path
    ///   - write: place this document at this library-relative path
    public static func run(assets: [Asset],
                           profiles: EntityProfileIndex? = nil,
                           fileExists: (String) -> Bool,
                           write: (String, String) throws -> Void) -> SidecarBackfillSummary {
        var summary = SidecarBackfillSummary()

        for asset in assets {
            let path = MetadataSidecar.path(forVideo: asset.relativePath)
            let cast = asset.actors.map { name in
                SidecarPerformer(name: name, thumbURL: profiles?[actor: name]?.photoUrl)
            }
            let stem = (asset.fileName as NSString).deletingPathExtension

            // ⚠️ The refusal is decided BEFORE the existence check, so that a
            // personal video which already carries a sidecar is counted as
            // refused-and-present rather than disappearing into
            // `alreadyPresent`. Checking existence first would report the more
            // comfortable number and hide the one worth knowing.
            guard let document = MetadataSidecar.document(
                for: asset, cast: cast, studio: asset.studios.first, fallbackTitle: stem)
            else {
                summary.refused += 1
                if fileExists(path) { summary.refusedButPresent += 1 }
                continue
            }

            guard !fileExists(path) else {
                summary.alreadyPresent += 1
                continue
            }

            do {
                try write(path, document)
                summary.written += 1
            } catch {
                summary.failed += 1
            }
        }

        return summary
    }

    /// The same pass against a real library.
    ///
    /// ⚠️ Best-effort per video, exactly like the mover's own sidecar write: one
    /// unwritable path must not stop the other two hundred. A failure is
    /// counted, not thrown.
    public static func run(libraryURL: URL, assets: [Asset],
                           profiles: EntityProfileIndex? = nil) -> SidecarBackfillSummary {
        let manager = FileManager.default
        return run(
            assets: assets,
            profiles: profiles,
            fileExists: { manager.fileExists(atPath: libraryURL.appendingPathComponent($0).path) },
            write: { path, document in
                let target = libraryURL.appendingPathComponent(path)
                try manager.createDirectory(at: target.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
                try document.write(to: target, atomically: true, encoding: .utf8)
            })
    }
}
