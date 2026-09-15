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
    static func perform(losingId: String, survivingId: String,
                        in libraryURL: URL) -> Outcome {
        guard losingId != survivingId else { return .failed("Cannot merge a profile into itself") }
        
        do {
            let store = try LibraryStore(at: libraryURL)
            // If the names are identical, renameTagGlobally won't do anything, 
            // so we merge directly by ID.
            if let losingProfile = try store.fetchEntityProfile(for: losingId),
               let survivingProfile = try store.fetchEntityProfile(for: survivingId) {
                
                let losingName = losingProfile.displayName ?? ""
                let survivingName = survivingProfile.displayName ?? ""
                
                if losingName.caseInsensitiveCompare(survivingName) == .orderedSame {
                    let changed = try store.mergeProfiles(losingId: losingId, survivingId: survivingId)
                    return changed ? .merged : .nothingChanged(losing: losingName)
                } else {
                    let outcome = try store.renameTagGlobally(
                        oldTag: EntityProfile.actorTag(losingName),
                        newTag: EntityProfile.actorTag(survivingName))
                    return outcome.changedAnything ? .merged : .nothingChanged(losing: losingName)
                }
            } else {
                return .failed("Could not find profiles")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
