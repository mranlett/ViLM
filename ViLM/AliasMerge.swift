// AliasMerge.swift
// Merging two performer profiles, decided apart from the screen that shows it.
//
// 🚨 Extracted because both halves of this shipped broken inside a view, where
// nothing could test them:
//
//   • it passed profile IDS to `renameTagGlobally`, which matches `actor:Name`
//     strings in `Asset.tags`. Before the re-key an id WAS that string, so it
//     worked by coincidence; afterwards it matched nothing.
//
//   • it discarded the result with `_ =`, so a rename that changed nothing
//     counted as a merge. The row vanished from the list, both profiles
//     survived, and the screen reported success.
//
// ⚠️ A view cannot be unit tested, so logic that decides anything does not
// belong in one. What is left in `AliasSplitMergeView` is presentation.

import Foundation
import LibraryCore

enum AliasMerge {

    /// What a merge attempt did, in terms the screen can render.
    enum Outcome: Equatable {
        case merged
        /// 🚨 Nothing matched. Reported rather than swallowed — this is the
        /// state that used to be indistinguishable from success.
        case nothingChanged(losing: String)
        case failed(String)

        /// Whether the operator should be shown a problem.
        var message: String? {
            switch self {
            case .merged: return nil
            case let .nothingChanged(losing):
                return "Nothing changed — no video, profile or tag was found under “\(losing)”. The two profiles are unchanged."
            case let .failed(reason):
                return "Couldn't merge those: \(reason)"
            }
        }
    }

    /// Folds `losing` into `surviving`, both given as NAMES.
    ///
    /// ⭐ Names, not ids. The global rename is the merge — the destination
    /// keeps its own values, the source fills gaps, photos, AKAs and links are
    /// unioned, edges move, and a tombstone stops the losing name returning on
    /// the next sync. All of that already exists; the only thing this adds is
    /// handing it the form it actually matches on, and believing its answer.
    static func perform(losing: String, surviving: String,
                        in libraryURL: URL) -> Outcome {
        // ⚠️ Refused rather than attempted. Renaming a name to itself is a
        // no-op the store early-returns on, which would then be reported as
        // "nothing changed" — a confusing way to say "that made no sense".
        guard losing.caseInsensitiveCompare(surviving) != .orderedSame else {
            return .nothingChanged(losing: losing)
        }
        do {
            let outcome = try LibraryStore(at: libraryURL).renameTagGlobally(
                oldTag: EntityProfile.actorTag(losing),
                newTag: EntityProfile.actorTag(surviving))
            return outcome.changedAnything ? .merged : .nothingChanged(losing: losing)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
