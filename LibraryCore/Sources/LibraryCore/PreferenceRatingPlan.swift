// PreferenceRatingPlan.swift
// Head to Head — the one sanctioned path from a score to a rating (#37, D3).
//
// 🚨 This is the only place in the feature that may write `rating`, and it is
// the only irreversible interaction with operator-authored data anywhere in it.
// Everything else reads a rating to seed a first score (D9) and never writes
// back.
//
// 🔴 An EXPLICIT, REVIEWABLE action — never a side effect of playing. The plan
// is computed first, shown in full, and applied only if the operator says so.
// "Apply these as ratings" that quietly changed forty rows would be exactly the
// pollution D3 exists to prevent, and it cannot be undone by playing more.
//
// ⚠️ Pure. Deciding what WOULD change is separable from changing it, and only
// the deciding needs to be tested hard.

import Foundation

/// One rating this plan would set, and what it would replace.
public struct PreferenceRatingChange: Equatable, Sendable, Identifiable {
    public let contenderId: String
    public let displayName: String
    /// Nil when the operator has never rated this contender by hand.
    public let currentRating: Int?
    public let proposedRating: Int

    public var id: String { contenderId }

    /// ⚠️ The dangerous ones. Overwriting a hand-set rating discards a
    /// statement the operator made; filling a blank one does not.
    public var overwritesAHandSetRating: Bool { currentRating != nil }
}

public enum PreferenceRatingPlan {

    /// What applying the derived stars would do.
    ///
    /// ⭐ Only contenders whose score has earned a star appear — D8's threshold
    /// is enforced here as well as in the leaderboard, because this is the
    /// version that writes to disk. A provisional contender contributes no
    /// star, so there is nothing to apply.
    ///
    /// ⚠️ Retired contenders are excluded. "Neither" said they do not belong in
    /// the ranking; deriving a rating for them from a ranking they were removed
    /// from would be incoherent.
    ///
    /// ⚠️ A change is only listed when it would actually CHANGE something. A
    /// preview listing forty rows of which thirty are already correct teaches
    /// the operator to skim it, and the whole value of the preview is that it
    /// is read.
    public static func plan(scores: [String: PreferenceScore],
                            retired: Set<String>,
                            currentRatings: [String: Int?],
                            displayNames: [String: String]) -> [PreferenceRatingChange] {
        let eligible = scores.filter { !retired.contains($0.key) }
        let stars = PreferenceScoring.derivedStars(eligible)

        return stars.compactMap { id, star -> PreferenceRatingChange? in
            let current = currentRatings[id] ?? nil
            guard current != star else { return nil }
            return PreferenceRatingChange(contenderId: id,
                                          displayName: displayNames[id] ?? id,
                                          currentRating: current,
                                          proposedRating: star)
        }
        // Overwrites first, then by name — the rows that need the most thought
        // are the ones the operator should meet before they stop reading.
        .sorted {
            $0.overwritesAHandSetRating == $1.overwritesAHandSetRating
                ? $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                : $0.overwritesAHandSetRating
        }
    }

    /// How the preview should describe itself.
    public static func summary(_ changes: [PreferenceRatingChange]) -> String {
        guard !changes.isEmpty else { return "Nothing would change." }
        let overwrites = changes.filter(\.overwritesAHandSetRating).count
        let fills = changes.count - overwrites
        var parts: [String] = []
        if fills > 0 { parts.append("\(fills) performer\(fills == 1 ? "" : "s") would get a rating") }
        if overwrites > 0 {
            parts.append("\(overwrites) hand-set rating\(overwrites == 1 ? "" : "s") would be REPLACED")
        }
        return parts.joined(separator: ", ") + "."
    }
}
