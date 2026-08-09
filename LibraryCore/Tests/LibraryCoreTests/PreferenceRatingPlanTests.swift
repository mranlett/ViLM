// PreferenceRatingPlanTests.swift
// Head to Head — applying derived stars as ratings (#37, D3).
//
// 🚨 The whole point of these is that the preview cannot lie. This is the one
// path in the feature that overwrites what the operator wrote by hand, and a
// preview that under-reports what it would do is worse than no preview.

import XCTest
@testable import LibraryCore

final class PreferenceRatingPlanTests: XCTestCase {

    /// Ten settled contenders spread across the scale, so the star bands are
    /// populated and the plan has something to say.
    private func spread(_ n: Int = 20) -> [String: PreferenceScore] {
        var out: [String: PreferenceScore] = [:]
        for i in 0..<n {
            out["c\(i)"] = PreferenceScore(value: 1200 + Double(i) * 40, comparisons: 25)
        }
        return out
    }

    private func names(_ scores: [String: PreferenceScore]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: scores.keys.map { ($0, "Performer \($0)") })
    }

    // MARK: - What the plan contains

    func testEverySettledContenderWithAChangeIsListed() {
        let scores = spread()
        let plan = PreferenceRatingPlan.plan(scores: scores, retired: [],
                                             currentRatings: [:], displayNames: names(scores))

        XCTAssertEqual(plan.count, scores.count, "all unrated, all would change")
        XCTAssertTrue(plan.allSatisfy { (1...5).contains($0.proposedRating) })
    }

    /// ⚠️ A row that would change nothing is not shown. A preview of forty rows
    /// where thirty are already correct teaches the operator to skim it, and
    /// the value of the preview is entirely that it gets read.
    func testAContenderAlreadyAtItsDerivedStarIsNotListed() {
        let scores = spread()
        let stars = PreferenceScoring.derivedStars(scores)
        let already = stars.mapValues { Optional($0) }

        let plan = PreferenceRatingPlan.plan(scores: scores, retired: [],
                                             currentRatings: already,
                                             displayNames: names(scores))

        XCTAssertTrue(plan.isEmpty, "nothing to do")
        XCTAssertEqual(PreferenceRatingPlan.summary(plan), "Nothing would change.")
    }

    // MARK: - 🚨 D8 — provisional contenders are not rated

    func testAProvisionalContenderIsNeverGivenARating() {
        var scores = spread()
        scores["fresh"] = PreferenceScore(value: 2400, comparisons: 2)

        let plan = PreferenceRatingPlan.plan(scores: scores, retired: [],
                                             currentRatings: [:], displayNames: names(scores))

        XCTAssertFalse(plan.contains { $0.contenderId == "fresh" },
                       "a huge score from two comparisons writes nothing to disk")
    }

    // MARK: - D6 — retired contenders are out

    /// "Neither" said they do not belong in the ranking. Deriving a rating for
    /// them from a ranking they were removed from would be incoherent.
    func testARetiredContenderIsNeverRated() {
        let scores = spread()
        let plan = PreferenceRatingPlan.plan(scores: scores, retired: ["c0", "c19"],
                                             currentRatings: [:], displayNames: names(scores))

        XCTAssertFalse(plan.contains { $0.contenderId == "c0" })
        XCTAssertFalse(plan.contains { $0.contenderId == "c19" })
    }

    /// ⚠️ And removing them re-shapes the distribution for everyone else, which
    /// is correct: the bands describe the contenders still in the ranking.
    func testRetiringAContenderChangesWhereTheBandsFall() {
        let scores = spread()
        let withAll = PreferenceRatingPlan.plan(scores: scores, retired: [],
                                                currentRatings: [:], displayNames: names(scores))
        let withoutTop = PreferenceRatingPlan.plan(scores: scores, retired: ["c19", "c18"],
                                                   currentRatings: [:], displayNames: names(scores))

        let starFor: ([PreferenceRatingChange], String) -> Int? = { plan, id in
            plan.first { $0.contenderId == id }?.proposedRating
        }
        XCTAssertNotNil(starFor(withAll, "c17"))
        XCTAssertGreaterThanOrEqual(starFor(withoutTop, "c17")!, starFor(withAll, "c17")!,
                                    "with the top two gone, those below move up")
    }

    // MARK: - 🚨 Overwrites are surfaced, not buried

    func testOverwritingAHandSetRatingIsFlagged() {
        let scores = spread()
        // A hand-set 1 on the top-scoring contender: a real disagreement.
        let plan = PreferenceRatingPlan.plan(scores: scores, retired: [],
                                             currentRatings: ["c19": 1],
                                             displayNames: names(scores))

        let row = plan.first { $0.contenderId == "c19" }
        XCTAssertEqual(row?.currentRating, 1)
        XCTAssertTrue(row?.overwritesAHandSetRating ?? false)
        XCTAssertGreaterThan(row?.proposedRating ?? 0, 1)
    }

    /// ⚠️ Overwrites sort FIRST. The rows needing most thought must be met
    /// before the operator stops reading.
    func testOverwritesAreListedBeforeFills() {
        let scores = spread()
        let plan = PreferenceRatingPlan.plan(scores: scores, retired: [],
                                             currentRatings: ["c5": 5, "c12": 1],
                                             displayNames: names(scores))

        // ⚠️ Asserts there ARE overwrites first. An earlier version of this
        // fixture happened to hand-set ratings that already matched their
        // derived star, so no overwrite rows existed and the ordering check
        // passed against an empty set.
        XCTAssertEqual(plan.filter(\.overwritesAHandSetRating).count, 2)
        let firstFill = plan.firstIndex { !$0.overwritesAHandSetRating } ?? plan.count
        let lastOverwrite = plan.lastIndex { $0.overwritesAHandSetRating } ?? -1
        XCTAssertLessThan(lastOverwrite, firstFill)
    }

    /// The summary must NAME the overwrites. "42 performers would be rated"
    /// hides the two that matter.
    func testTheSummaryNamesReplacementsSeparately() {
        let scores = spread()
        let summary = PreferenceRatingPlan.summary(
            PreferenceRatingPlan.plan(scores: scores, retired: [],
                                      currentRatings: ["c5": 5],
                                      displayNames: names(scores)))

        XCTAssertTrue(summary.contains("REPLACED"), summary)
        XCTAssertTrue(summary.contains("1 hand-set rating"), summary)
    }

    // MARK: - Nothing to do

    func testAnEmptyRankingPlansNothing() {
        XCTAssertTrue(PreferenceRatingPlan.plan(scores: [:], retired: [],
                                                currentRatings: [:], displayNames: [:]).isEmpty)
    }
}
