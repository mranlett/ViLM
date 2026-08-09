// PreferenceScoring.swift
// Head to Head — the score a comparison produces.
//
// ⭐ Why a score rather than a rating per run. The spec's D2: awarding a star
// to the winner of a run of ten throws away everything the run learned, and the
// winner of a weak pool is not the equal of the winner of a strong one. Every
// comparison instead nudges BOTH contenders by an amount that depends on how
// surprising the result was, so no run boundary is needed for a number to mean
// something and two sessions weeks apart compose correctly.
//
// 🚨 This type never touches `rating`. `rating` is where the operator STATES an
// opinion; a score inferred from a game is EVIDENCE about one. The project
// keeps those apart everywhere else — a source's description never lands in
// `Asset.notes` — and the same rule applies here. Deriving stars into `rating`
// is a separate, reviewable action, never a side effect of playing. The
// conflict is theoretical today at ten hand-set ratings across both subjects;
// it costs nothing to get right now and cannot be retrofitted once the field
// is polluted.
//
// ⚠️ Deliberately pure and free of storage. The pairing rule, the star
// derivation and the update are the parts worth testing hard, and they test
// without a database, a clock or a random source.

import Foundation

/// Where a contender currently sits, and how much that is worth believing.
public struct PreferenceScore: Equatable, Sendable {
    /// ⭐ The scale is arbitrary and never shown. What matters is the ORDER and
    /// the gaps; 1500 as the middle is the familiar Elo convention, which makes
    /// the numbers legible to anyone who has seen a chess rating.
    public static let start: Double = 1500

    /// Comparisons below which a score is provisional and yields no star.
    ///
    /// ⚠️ D8. A score from three comparisons is not a score from thirty, and
    /// presenting them identically is the fastest way to make the whole ranking
    /// untrustworthy.
    public static let confidenceThreshold = 10

    public var value: Double
    public var comparisons: Int

    public init(value: Double = PreferenceScore.start, comparisons: Int = 0) {
        self.value = value
        self.comparisons = comparisons
    }

    /// Whether this score has earned the right to be presented as settled.
    public var isProvisional: Bool { comparisons < Self.confidenceThreshold }

    /// D9 — a hand-set rating seeds the starting score.
    ///
    /// ⚠️ Ignoring an explicit statement in favour of a default would be
    /// perverse. This READS `rating`; nothing here ever writes it.
    ///
    /// A rating of 3 is the middle and seeds exactly the default, so a
    /// mid-rated contender is indistinguishable from an unrated one — which is
    /// correct, because that is what a 3 says.
    public static func seeded(byRating rating: Int?) -> PreferenceScore {
        guard let rating, (1...5).contains(rating) else { return PreferenceScore() }
        return PreferenceScore(value: start + Double(rating - 3) * 100, comparisons: 0)
    }
}

/// What the operator said about one pair.
///
/// ⚠️ `retire` is NOT here. Answering "neither of these belongs in the ranking"
/// removes a contender from the game; it is not a result between two of them,
/// and modelling it as an outcome would mean inventing a score change for it.
public enum PreferenceOutcome: Equatable, Sendable {
    case left
    case right
    /// D6 — "too close to call" is an answer. Forcing a choice between two
    /// contenders the operator genuinely rates equally injects noise into every
    /// score they touch; a draw says they belong at the same level, which is
    /// real information.
    case draw
}

/// One comparison, kept so it can be undone.
///
/// ⚠️ D7 stores the scores as they were BEFORE, not a description of the
/// change. Recomputing an inverse update would have to reproduce the exact
/// arithmetic, and any drift between the two would leave undo subtly wrong —
/// which is worse than no undo, because it looks like it worked.
public struct PreferenceComparison: Equatable, Sendable {
    public let leftId: String
    public let rightId: String
    public let outcome: PreferenceOutcome
    public let leftBefore: PreferenceScore
    public let rightBefore: PreferenceScore

    public init(leftId: String, rightId: String, outcome: PreferenceOutcome,
                leftBefore: PreferenceScore, rightBefore: PreferenceScore) {
        self.leftId = leftId
        self.rightId = rightId
        self.outcome = outcome
        self.leftBefore = leftBefore
        self.rightBefore = rightBefore
    }
}

public enum PreferenceScoring {

    /// How far a single comparison can move a score, given how settled the two
    /// contenders are.
    ///
    /// ⭐ Decays with experience, at the operator's direction: the point of the
    /// feature is a trustworthy top tier, and a top tier that reshuffles on
    /// every comparison is not one. Two contenders with thirty comparisons each
    /// have already told us where they belong.
    ///
    /// 🚨 SHARED by the pair — the average of what each side would use alone —
    /// rather than each side moving by its own. This is the part that is easy
    /// to get wrong. Per-side factors are what chess federations do, but they
    /// make the two adjustments unequal, so the pool's total score is no longer
    /// conserved: a newcomer beating a veteran gains more than the veteran
    /// loses, and the whole pool inflates over time. D9 seeds every new
    /// contender at a FIXED middle, so an inflating pool would quietly push
    /// each newcomer further below the pack than the last — a bias that grows
    /// with use and would be very hard to see.
    ///
    /// Averaging keeps the two moves equal and opposite while still giving the
    /// behaviour asked for: two newcomers move fast, two veterans barely move,
    /// and a mixed pair lands in between.
    ///
    /// ⚠️ The tiers are anchored on `confidenceThreshold`, so "provisional" and
    /// "moves fast" are the same idea rather than two numbers to keep in step.
    static func updateFactor(_ a: PreferenceScore, _ b: PreferenceScore) -> Double {
        (soloFactor(a.comparisons) + soloFactor(b.comparisons)) / 2
    }

    static func soloFactor(_ comparisons: Int) -> Double {
        switch comparisons {
        case ..<PreferenceScore.confidenceThreshold: return 32   // still finding its level
        case ..<(PreferenceScore.confidenceThreshold * 3): return 20
        default: return 12                                       // settled
        }
    }

    /// The classic logistic curve: a 400-point gap means the favourite is
    /// expected to win about ten times in eleven.
    static func expectedScore(_ a: Double, versus b: Double) -> Double {
        1 / (1 + pow(10, (b - a) / 400))
    }

    /// Applies one comparison, returning both new scores.
    ///
    /// ⭐ BOTH move, always, and by how surprising the result was — beating a
    /// high scorer moves you a lot, beating a low one barely at all. That is
    /// the whole of D2, and it is why a loser keeps its information instead of
    /// being discarded.
    public static func apply(_ outcome: PreferenceOutcome,
                             left: PreferenceScore,
                             right: PreferenceScore) -> (left: PreferenceScore, right: PreferenceScore) {
        let expectedLeft = expectedScore(left.value, versus: right.value)
        let actualLeft: Double
        switch outcome {
        case .left:  actualLeft = 1
        case .right: actualLeft = 0
        case .draw:  actualLeft = 0.5
        }

        // The right-hand side is the mirror: expectations sum to 1, as do
        // outcomes, so the two adjustments are equal and opposite. Computing
        // them independently would let rounding pull the pair apart.
        let delta = updateFactor(left, right) * (actualLeft - expectedLeft)
        return (PreferenceScore(value: left.value + delta, comparisons: left.comparisons + 1),
                PreferenceScore(value: right.value - delta, comparisons: right.comparisons + 1))
    }

    /// Reverses a comparison exactly.
    ///
    /// ⭐ Returns what was stored, so undo cannot drift from the update it
    /// reverses — including the comparison counts, which a naive "subtract the
    /// delta" would leave one too high.
    public static func undo(_ comparison: PreferenceComparison)
    -> (left: PreferenceScore, right: PreferenceScore) {
        (comparison.leftBefore, comparison.rightBefore)
    }

    // MARK: - Derived stars

    /// Stars derived from where a contender sits in the DISTRIBUTION.
    ///
    /// 🔴 Derived, never awarded, and recomputed as the picture changes rather
    /// than frozen at the moment a run happened to end.
    ///
    /// ⚠️ Provisional contenders are excluded from the distribution as well as
    /// from the result. Letting a three-comparison score help decide where the
    /// deciles fall would let noise move everyone else's star.
    ///
    /// Returns nothing for a contender below the threshold — deliberately no
    /// star rather than a low one, because "not yet known" and "known to be
    /// poor" are different claims.
    public static func derivedStars(_ scores: [String: PreferenceScore]) -> [String: Int] {
        let settled = scores.filter { !$0.value.isProvisional }
        guard !settled.isEmpty else { return [:] }

        // Ascending, so a higher score sits later and earns more stars.
        // ⚠️ Ties broken by id so the mapping is stable between runs; without
        // it two equal scores could swap stars on every recomputation.
        let ranked = settled.sorted {
            $0.value.value == $1.value.value ? $0.key < $1.key : $0.value.value < $1.value.value
        }

        var out: [String: Int] = [:]
        let n = Double(ranked.count)
        for (index, entry) in ranked.enumerated() {
            // Percentile of the midpoint of this contender's slot, so a single
            // settled contender lands mid-scale rather than at either extreme.
            let percentile = (Double(index) + 0.5) / n
            out[entry.key] = star(forPercentile: percentile)
        }
        return out
    }

    /// ⭐ Top decile is five stars, per D2. The rest of the scale is spread so
    /// the bands are recognisable rather than uniform: most things are ordinary
    /// and a five means something.
    static func star(forPercentile p: Double) -> Int {
        switch p {
        case ..<0.20: return 1
        case ..<0.50: return 2
        case ..<0.75: return 3
        case ..<0.90: return 4
        default:      return 5
        }
    }
}
