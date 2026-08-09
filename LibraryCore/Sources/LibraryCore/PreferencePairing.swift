// PreferencePairing.swift
// Head to Head — choosing which two contenders to put in front of the operator.
//
// ⭐ D4 says this decides whether the feature works, and that is not rhetoric.
// Random pairs waste taps on obvious mismatches: comparing a clear favourite
// against a clear also-ran teaches almost nothing, because the answer was
// already known. Pairing close scores extracts the most information per tap —
// the difference between ranking 1,100 contenders in fifty sessions and in five
// hundred.
//
// ⚠️ With the caveat D4 attaches: pure score-matching never re-tests across
// tiers, so an early mistake strands someone forever. Roughly one pair in five
// is deliberately distant, to keep the ladder connected.
//
// ⚠️ Randomness is INJECTED, never taken from the global source. A pairing rule
// that cannot be replayed cannot be tested, and "occasionally distant" is
// exactly the kind of property that would otherwise be asserted by running it
// a hundred times and hoping.

import Foundation

/// A contender as the game sees it. Deliberately not an `EntityProfile` or an
/// `Asset` — D1 runs the same mechanic over both, and the pairing rule has no
/// business knowing which.
public struct PreferenceContender: Equatable, Sendable {
    public let id: String
    public var score: PreferenceScore
    /// ⚠️ D9: a contender with no image cannot play and is excluded rather than
    /// shown blank. Carried here so the rule can enforce it, rather than
    /// trusting every caller to filter first.
    public let hasImage: Bool
    /// D6's "neither" — retired from the game without being rated.
    public let isRetired: Bool

    public init(id: String, score: PreferenceScore = PreferenceScore(),
                hasImage: Bool = true, isRetired: Bool = false) {
        self.id = id
        self.score = score
        self.hasImage = hasImage
        self.isRetired = isRetired
    }

    /// Everything that disqualifies a contender from being offered.
    public var isEligible: Bool { hasImage && !isRetired }
}

public enum PreferencePairingError: Error, Equatable {
    /// ⚠️ T12 — a pool that cannot produce a pair is refused WITH A REASON
    /// rather than entered and then stuck on an empty screen.
    case notEnoughContenders(eligible: Int)
}

public enum PreferencePairing {

    /// How often to reach outside the neighbourhood, per D4.
    static let distantPairingRate = 5

    /// How many near-neighbours to choose among.
    ///
    /// ⚠️ Not 1. Always taking the single closest score would show the same two
    /// contenders repeatedly until one of them moved, which reads as the game
    /// being stuck. A small window keeps it informative and varied.
    static let neighbourhood = 6

    /// The next pair to show, or a refusal that says why.
    ///
    /// ⭐ Prefers contenders with FEW comparisons, per D8 — coverage grows
    /// instead of the same familiar faces recurring, which is also what makes
    /// the derived stars arrive at all.
    public static func nextPair<G: RandomNumberGenerator>(
        from contenders: [PreferenceContender],
        using generator: inout G
    ) throws -> (left: PreferenceContender, right: PreferenceContender) {

        let eligible = contenders.filter(\.isEligible)
        guard eligible.count >= 2 else {
            throw PreferencePairingError.notEnoughContenders(eligible: eligible.count)
        }

        // The least-compared contender anchors the pair. Ties broken by id so a
        // fresh pool does not depend on the order it was loaded in.
        let anchor = eligible.min {
            $0.score.comparisons == $1.score.comparisons
                ? $0.id < $1.id
                : $0.score.comparisons < $1.score.comparisons
        }!

        let others = eligible.filter { $0.id != anchor.id }
        let wantsDistant = Int.random(in: 0..<distantPairingRate, using: &generator) == 0

        let opponent: PreferenceContender
        if wantsDistant {
            // ⭐ Furthest in score, which is the pairing that re-tests across
            // tiers and rescues anyone stranded by an early mistake.
            opponent = others.max {
                abs($0.score.value - anchor.score.value) < abs($1.score.value - anchor.score.value)
            }!
        } else {
            let nearest = others
                .sorted { abs($0.score.value - anchor.score.value)
                        < abs($1.score.value - anchor.score.value) }
                .prefix(neighbourhood)
            opponent = nearest.randomElement(using: &generator)!
        }

        // ⚠️ Side is randomised. A rule that always put the anchor on the left
        // would train a positional habit, and a habit is indistinguishable from
        // a preference in the data it produces.
        return Bool.random(using: &generator)
            ? (left: anchor, right: opponent)
            : (left: opponent, right: anchor)
    }

    /// Convenience for callers with no opinion about the random source.
    public static func nextPair(from contenders: [PreferenceContender])
    throws -> (left: PreferenceContender, right: PreferenceContender) {
        var generator = SystemRandomNumberGenerator()
        return try nextPair(from: contenders, using: &generator)
    }
}
