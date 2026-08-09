// PreferenceScoringTests.swift
// Head to Head — the spec's test strategy, by number.
//
// ⭐ T1–T12 come straight from the spec so a reader can check coverage against
// it without interpretation. Where a test needed more than the spec's one line
// to be meaningful, the extra assertion says why.
//
// ⚠️ The one that matters most is T5. Every other failure here produces a
// wrong number in a game; that one produces a wrong number in data the operator
// authored by hand, and it is the only irreversible interaction in the feature.

import XCTest
@testable import LibraryCore

/// Deterministic, so "roughly one in five is distant" can be ASSERTED rather
/// than sampled and hoped over.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}

final class PreferenceScoringTests: XCTestCase {

    private func score(_ value: Double, _ comparisons: Int = 0) -> PreferenceScore {
        PreferenceScore(value: value, comparisons: comparisons)
    }

    // MARK: - T1 — a win moves both

    func testT1AWinMovesBothContenders() {
        let (left, right) = PreferenceScoring.apply(.left,
                                                    left: score(1500), right: score(1500))

        XCTAssertGreaterThan(left.value, 1500, "the winner rises")
        XCTAssertLessThan(right.value, 1500, "and the loser falls — it is not discarded")
        XCTAssertEqual(left.comparisons, 1)
        XCTAssertEqual(right.comparisons, 1)
    }

    /// ⭐ Equal and opposite. The two are computed from one delta precisely so
    /// rounding cannot pull the pair apart over thousands of comparisons.
    func testT1bTheTotalScoreIsConserved() {
        let (left, right) = PreferenceScoring.apply(.left,
                                                    left: score(1500), right: score(1320))
        XCTAssertEqual(left.value + right.value, 2820, accuracy: 0.000_001)
    }

    // MARK: - T2 — surprise decides the size of the move

    func testT2BeatingAHigherScorerMovesTheWinnerMore() {
        let beatingStronger = PreferenceScoring.apply(.left,
                                                      left: score(1500), right: score(1900)).left
        let beatingWeaker = PreferenceScoring.apply(.left,
                                                    left: score(1500), right: score(1100)).left

        XCTAssertGreaterThan(beatingStronger.value - 1500, beatingWeaker.value - 1500,
                             "an upset is worth more than confirming what was already known")
        // And the expected result barely moves anyone, which is what makes
        // close pairings the informative ones.
        XCTAssertLessThan(beatingWeaker.value - 1500, 4)
    }

    // MARK: - T3 — a draw converges

    func testT3ADrawConvergesTwoScoresAndNeverDivergesThem() {
        let gapBefore = abs(1700.0 - 1300.0)
        let (left, right) = PreferenceScoring.apply(.draw,
                                                    left: score(1700), right: score(1300))

        XCTAssertLessThan(abs(left.value - right.value), gapBefore, "they move toward each other")
        XCTAssertLessThan(left.value, 1700, "the higher one comes down")
        XCTAssertGreaterThan(right.value, 1300, "the lower one comes up")
    }

    /// ⚠️ And a draw between equals changes nothing but the counts — a drawn
    /// comparison is still evidence that they met.
    func testT3bADrawBetweenEqualsMovesNeitherScore() {
        let (left, right) = PreferenceScoring.apply(.draw,
                                                    left: score(1500, 4), right: score(1500, 9))
        XCTAssertEqual(left.value, 1500, accuracy: 0.000_001)
        XCTAssertEqual(right.value, 1500, accuracy: 0.000_001)
        XCTAssertEqual(left.comparisons, 5)
        XCTAssertEqual(right.comparisons, 10)
    }

    // MARK: - T4 — undo restores exactly

    func testT4UndoRestoresBothScoresIncludingCounts() {
        let before = (left: score(1612.5, 7), right: score(1488.25, 3))
        let after = PreferenceScoring.apply(.right, left: before.left, right: before.right)
        XCTAssertNotEqual(after.left, before.left)

        let restored = PreferenceScoring.undo(
            PreferenceComparison(leftId: "a", rightId: "b", outcome: .right,
                                 leftBefore: before.left, rightBefore: before.right))

        XCTAssertEqual(restored.left, before.left)
        XCTAssertEqual(restored.right, before.right)
        XCTAssertEqual(restored.left.comparisons, 7, "the count goes back too")
        XCTAssertEqual(restored.right.comparisons, 3)
    }

    // MARK: - 🚨 T5 — the game never writes `rating`

    /// The one irreversible interaction with operator-authored data.
    ///
    /// ⚠️ Asserted at the type level rather than by inspecting a call: nothing
    /// in this module can write a rating because nothing in it is handed a
    /// profile to write to. `PreferenceScore` is built FROM a rating (D9) and
    /// never back into one.
    func testT5ScoringCannotReachRatingAtAll() {
        var profile = EntityProfile(id: UUID().uuidString, entityType: "actor",
                                    displayName: "Vera Example")
        profile.rating = 4
        let ratingBefore = profile.rating

        // Everything the engine can do with a rating: read it.
        let seeded = PreferenceScore.seeded(byRating: profile.rating)
        _ = PreferenceScoring.apply(.left, left: seeded, right: PreferenceScore())
        _ = PreferenceScoring.derivedStars(["x": PreferenceScore(value: 1900, comparisons: 40)])

        XCTAssertEqual(profile.rating, ratingBefore, "untouched")
        XCTAssertEqual(profile.rating, 4)
    }

    // MARK: - T6 — no star below the confidence threshold

    func testT6AProvisionalContenderYieldsNoStar() {
        let stars = PreferenceScoring.derivedStars([
            "settled": PreferenceScore(value: 1900, comparisons: 30),
            "provisional": PreferenceScore(value: 2400, comparisons: 3),
        ])

        XCTAssertNotNil(stars["settled"])
        XCTAssertNil(stars["provisional"],
                     "a huge score from three comparisons still earns nothing")
    }

    /// ⚠️ And a provisional score does not shift where the deciles fall for
    /// everyone else. Letting noise decide the bands would move other people's
    /// stars.
    func testT6bProvisionalScoresAreExcludedFromTheDistribution() {
        var settled: [String: PreferenceScore] = [:]
        for i in 0..<10 {
            settled["s\(i)"] = PreferenceScore(value: 1400 + Double(i) * 20, comparisons: 20)
        }
        let withoutNoise = PreferenceScoring.derivedStars(settled)

        var withNoise = settled
        for i in 0..<50 { withNoise["n\(i)"] = PreferenceScore(value: 3000, comparisons: 1) }

        XCTAssertEqual(PreferenceScoring.derivedStars(withNoise).filter { settled.keys.contains($0.key) },
                       withoutNoise)
    }

    func testT6cTheTopBandIsTheTopDecile() {
        var scores: [String: PreferenceScore] = [:]
        for i in 0..<100 {
            scores["c\(i)"] = PreferenceScore(value: 1000 + Double(i), comparisons: 20)
        }
        let stars = PreferenceScoring.derivedStars(scores)

        XCTAssertEqual(stars.values.filter { $0 == 5 }.count, 10, "top decile, per D2")
        XCTAssertEqual(stars["c99"], 5, "the highest score is in it")
        XCTAssertEqual(stars["c0"], 1, "and the lowest is not")
    }

    // MARK: - T9 — a hand-set rating seeds the score

    func testT9AHandSetRatingSeedsTheStartingScore() {
        XCTAssertGreaterThan(PreferenceScore.seeded(byRating: 5).value, PreferenceScore.start)
        XCTAssertLessThan(PreferenceScore.seeded(byRating: 1).value, PreferenceScore.start)
        XCTAssertEqual(PreferenceScore.seeded(byRating: 3).value, PreferenceScore.start,
                       "a 3 says middling, which is exactly the default")
        XCTAssertEqual(PreferenceScore.seeded(byRating: nil).value, PreferenceScore.start)
    }

    /// ⚠️ A seed is a starting point, not evidence. It must not count as a
    /// comparison or a seeded contender would arrive already looking confident.
    func testT9bASeedIsNotAComparison() {
        XCTAssertEqual(PreferenceScore.seeded(byRating: 5).comparisons, 0)
        XCTAssertTrue(PreferenceScore.seeded(byRating: 5).isProvisional)
    }

    func testT9cAnOutOfRangeRatingIsIgnoredRatherThanTrusted() {
        XCTAssertEqual(PreferenceScore.seeded(byRating: 0).value, PreferenceScore.start)
        XCTAssertEqual(PreferenceScore.seeded(byRating: 99).value, PreferenceScore.start)
    }

    // MARK: - T10 — order stability

    /// The same comparisons in a different order reach the same ORDERING.
    ///
    /// ⚠️ Ordering, not identical scores — Elo is path-dependent in the exact
    /// numbers and pretending otherwise would be asserting something false.
    /// What must hold is that the ranking does not depend on the order the
    /// operator happened to play in, which is the property a leaderboard rests
    /// on. This is also why the update factor is constant: a K that shrinks
    /// with a contender's own history would make the result depend on when
    /// each comparison arrived.
    func testT10TheSameComparisonsInADifferentOrderReachTheSameOrdering() {
        let ids = ["a", "b", "c", "d"]
        // A transitive truth for the run to discover: a > b > c > d.
        let rank = ["a": 4, "b": 3, "c": 2, "d": 1]
        var comparisons: [(String, String)] = []
        for i in ids.indices {
            for j in ids.indices where i < j {
                // Several rounds, so scores separate clearly.
                for _ in 0..<6 { comparisons.append((ids[i], ids[j])) }
            }
        }

        func play(_ order: [(String, String)]) -> [String] {
            var scores = Dictionary(uniqueKeysWithValues: ids.map { ($0, PreferenceScore()) })
            for (l, r) in order {
                let outcome: PreferenceOutcome = rank[l]! > rank[r]! ? .left : .right
                let updated = PreferenceScoring.apply(outcome, left: scores[l]!, right: scores[r]!)
                scores[l] = updated.left
                scores[r] = updated.right
            }
            return scores.sorted { $0.value.value > $1.value.value }.map(\.key)
        }

        let forward = play(comparisons)
        let reversed = play(comparisons.reversed())
        let shuffled = play(comparisons.sorted { $0.1 < $1.1 })

        XCTAssertEqual(forward, ["a", "b", "c", "d"], "the run found the true order")
        XCTAssertEqual(reversed, forward)
        XCTAssertEqual(shuffled, forward)
    }

    // MARK: - T11 — one ladder, whatever the filter

    /// ⭐ There is no per-filter score to test, and that is the point. A filter
    /// chooses who the operator SEES; the score it updates is the same one an
    /// unfiltered session updates. This asserts the shape that makes a separate
    /// ladder impossible rather than merely absent.
    func testT11AFilteredSessionUpdatesTheSameScore() {
        let a = PreferenceScore(value: 1500, comparisons: 2)
        let b = PreferenceScore(value: 1500, comparisons: 2)

        // "Filtered" and "unfiltered" are the same call — there is nowhere to
        // put a pool identifier, because a score does not have one.
        let first = PreferenceScoring.apply(.left, left: a, right: b)
        let second = PreferenceScoring.apply(.left, left: first.left, right: first.right)

        XCTAssertEqual(second.left.comparisons, 4, "both sessions accumulated onto one score")
        XCTAssertGreaterThan(second.left.value, first.left.value)
    }
}

// MARK: - Pairing

final class PreferencePairingTests: XCTestCase {

    private func pool(_ values: [Double]) -> [PreferenceContender] {
        values.enumerated().map {
            PreferenceContender(id: "c\($0.offset)",
                                score: PreferenceScore(value: $0.element, comparisons: 20))
        }
    }

    // MARK: - T7 — close pairs, with occasional distant ones

    func testT7PairingPrefersCloseScoresAndStillReachesAcrossTiers() throws {
        // A wide spread so "close" and "distant" are unambiguous.
        let contenders = pool(stride(from: 1000.0, through: 2000.0, by: 50).map { $0 })
        var generator = SeededGenerator(seed: 42)

        var gaps: [Double] = []
        for _ in 0..<400 {
            let pair = try PreferencePairing.nextPair(from: contenders, using: &generator)
            gaps.append(abs(pair.left.score.value - pair.right.score.value))
        }

        let distant = gaps.filter { $0 > 500 }.count
        let close = gaps.filter { $0 <= 300 }.count

        XCTAssertGreaterThan(close, distant * 2, "most pairs are informative neighbours")
        XCTAssertGreaterThan(distant, 0, "but the ladder is not allowed to fragment")
    }

    /// ⚠️ Both sides get used. A rule that always seated the anchor on the left
    /// would train a positional habit, and a habit is indistinguishable from a
    /// preference in the data it produces.
    func testT7bSidesAreRandomised() throws {
        let contenders = pool([1500, 1500, 1500, 1500])
        var generator = SeededGenerator(seed: 7)
        var leftIds = Set<String>()
        for _ in 0..<50 {
            leftIds.insert(try PreferencePairing.nextPair(from: contenders,
                                                          using: &generator).left.id)
        }
        XCTAssertGreaterThan(leftIds.count, 1)
    }

    /// D8 — coverage grows instead of the same faces recurring.
    func testT7cTheLeastComparedContenderIsPreferred() throws {
        var contenders = pool([1500, 1500, 1500])
        contenders[2] = PreferenceContender(id: "fresh",
                                            score: PreferenceScore(value: 1500, comparisons: 0))
        var generator = SeededGenerator(seed: 3)

        for _ in 0..<20 {
            let pair = try PreferencePairing.nextPair(from: contenders, using: &generator)
            XCTAssertTrue(pair.left.id == "fresh" || pair.right.id == "fresh",
                          "the contender nobody has seen is in every pair until it catches up")
        }
    }

    // MARK: - T8 — ineligible contenders are never offered

    func testT8AContenderWithNoImageIsNeverOffered() throws {
        let contenders = [
            PreferenceContender(id: "seen-a"),
            PreferenceContender(id: "seen-b"),
            PreferenceContender(id: "blank", hasImage: false),
        ]
        var generator = SeededGenerator(seed: 11)

        for _ in 0..<50 {
            let pair = try PreferencePairing.nextPair(from: contenders, using: &generator)
            XCTAssertNotEqual(pair.left.id, "blank")
            XCTAssertNotEqual(pair.right.id, "blank")
        }
    }

    /// D6's "neither" — retired without being rated.
    func testT8bARetiredContenderIsNeverOffered() throws {
        let contenders = [
            PreferenceContender(id: "a"),
            PreferenceContender(id: "b"),
            PreferenceContender(id: "gone", isRetired: true),
        ]
        var generator = SeededGenerator(seed: 5)

        for _ in 0..<50 {
            let pair = try PreferencePairing.nextPair(from: contenders, using: &generator)
            XCTAssertFalse([pair.left.id, pair.right.id].contains("gone"))
        }
    }

    // MARK: - T12 — an unplayable pool is refused, with a reason

    func testT12APoolWithFewerThanTwoEligibleContendersIsRefused() {
        let almostEmpty = [PreferenceContender(id: "only")]
        XCTAssertThrowsError(try PreferencePairing.nextPair(from: almostEmpty)) { error in
            XCTAssertEqual(error as? PreferencePairingError, .notEnoughContenders(eligible: 1))
        }

        XCTAssertThrowsError(try PreferencePairing.nextPair(from: [])) { error in
            XCTAssertEqual(error as? PreferencePairingError, .notEnoughContenders(eligible: 0))
        }
    }

    /// ⚠️ The count in the refusal is of ELIGIBLE contenders, not of the pool.
    /// "3 contenders, cannot play" would look like a bug; "1 of your 3 can play"
    /// tells the operator their filter is the problem.
    func testT12bTheRefusalCountsEligibleNotTotal() {
        let contenders = [
            PreferenceContender(id: "a"),
            PreferenceContender(id: "b", hasImage: false),
            PreferenceContender(id: "c", isRetired: true),
        ]
        XCTAssertThrowsError(try PreferencePairing.nextPair(from: contenders)) { error in
            XCTAssertEqual(error as? PreferencePairingError, .notEnoughContenders(eligible: 1))
        }
    }
}
