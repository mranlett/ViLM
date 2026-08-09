// RecordComparisonTests.swift
// Head to Head — recording a comparison and taking it back (#33, D2 + D7).
//
// ⚠️ R5 is the one that would have shipped wrong without thinking about it:
// undoing a contender's FIRST comparison has to remove the row, not write the
// seed back. A restored seed reads as "played, and average" — which is a claim
// the operator never made, and which D8 would then treat as real once ten of
// them accumulated.

import XCTest
@testable import LibraryCore

final class RecordComparisonTests: XCTestCase {

    private var url: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Compare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store = try LibraryStore(at: url)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    private func actor(_ name: String, rating: Int? = nil) throws -> String {
        var p = EntityProfile(id: UUID().uuidString, entityType: "actor", displayName: name)
        p.rating = rating
        try store.saveEntityProfile(p)
        return p.id
    }

    private func standing(_ id: String) throws -> PreferenceRecord? {
        try store.preferenceRecord(subject: .actor, contenderId: id)
    }

    // MARK: - R1 — one comparison moves both, and persists

    func testRecordingAComparisonMovesBothContenders() throws {
        let a = try actor("A Example"), b = try actor("B Example")

        try store.recordComparison(subject: .actor, leftId: a, rightId: b, outcome: .left)

        let left = try XCTUnwrap(try standing(a)), right = try XCTUnwrap(try standing(b))
        XCTAssertGreaterThan(left.score, PreferenceScore.start)
        XCTAssertLessThan(right.score, PreferenceScore.start)
        XCTAssertEqual(left.comparisons, 1)
        XCTAssertEqual(right.comparisons, 1)
    }

    /// ⚠️ Both rows are written by ONE transaction. If they were two, a failure
    /// between them would leave a comparison half-recorded — one contender
    /// credited with a win nobody lost.
    func testTheTotalScoreIsConservedAcrossManyComparisons() throws {
        let ids = try (0..<4).map { try actor("Contender \($0)") }
        for i in 0..<3 {
            try store.recordComparison(subject: .actor, leftId: ids[i], rightId: ids[i + 1],
                                       outcome: .left)
        }
        let total = try store.preferenceRecords(subject: .actor).values.reduce(0.0) { $0 + $1.score }
        // Four contenders, three of which have played, all seeded at the middle.
        let played = try store.preferenceRecords(subject: .actor).count
        XCTAssertEqual(total, PreferenceScore.start * Double(played), accuracy: 0.000_001)
    }

    // MARK: - R2 — D9 seeding happens at first play, not before

    func testAHandSetRatingSeedsTheFirstComparison() throws {
        let loved = try actor("Loved", rating: 5)
        let plain = try actor("Plain")

        try store.recordComparison(subject: .actor, leftId: loved, rightId: plain, outcome: .right)

        // The upset moves things, but the seeded contender started above the
        // middle and an unremarkable loss does not erase that.
        XCTAssertGreaterThan(try XCTUnwrap(try standing(loved)).score,
                             try XCTUnwrap(try standing(plain)).score)
    }

    /// ⭐ Nothing exists until a contender actually plays. A row per actor
    /// would destroy the distinction absence carries (D8/D9).
    func testNoRowsExistBeforeAnyoneHasPlayed() throws {
        _ = try actor("A Example"); _ = try actor("B Example")
        XCTAssertTrue(try store.preferenceRecords(subject: .actor).isEmpty)
    }

    // MARK: - R3 — T4, undo restores exactly

    func testUndoRestoresBothScoresAndCounts() throws {
        let a = try actor("A Example"), b = try actor("B Example")
        // Play a few so there is a real state to return to.
        for _ in 0..<3 {
            try store.recordComparison(subject: .actor, leftId: a, rightId: b, outcome: .left)
        }
        let beforeA = try XCTUnwrap(try standing(a)), beforeB = try XCTUnwrap(try standing(b))

        let recorded = try store.recordComparison(subject: .actor, leftId: a, rightId: b,
                                                  outcome: .right)
        XCTAssertNotEqual(try standing(a)?.score, beforeA.score)

        try store.undoComparison(recorded)

        XCTAssertEqual(try XCTUnwrap(try standing(a)).score, beforeA.score, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(try standing(b)).score, beforeB.score, accuracy: 0.000_001)
        XCTAssertEqual(try standing(a)?.comparisons, 3, "the count goes back too")
        XCTAssertEqual(try standing(b)?.comparisons, 3)
    }

    // MARK: - 🚨 R5 — undoing a FIRST comparison removes the row

    /// The case a "restore the before-scores" undo gets wrong. Before the
    /// comparison neither contender had a standing; writing the seed back
    /// would leave two contenders that read as played-and-average, which is a
    /// claim the operator never made.
    func testUndoingAFirstEverComparisonLeavesNoStanding() throws {
        let a = try actor("A Example"), b = try actor("B Example")

        let recorded = try store.recordComparison(subject: .actor, leftId: a, rightId: b,
                                                  outcome: .left)
        XCTAssertEqual(try store.preferenceRecords(subject: .actor).count, 2)

        try store.undoComparison(recorded)

        XCTAssertTrue(try store.preferenceRecords(subject: .actor).isEmpty,
                      "back to never having played, not to an average score")
    }

    /// ⚠️ And the mixed case: one side had a history, the other did not.
    func testUndoRemovesOnlyTheRowItCreated() throws {
        let veteran = try actor("Veteran"), newcomer = try actor("Newcomer")
        let other = try actor("Other")
        try store.recordComparison(subject: .actor, leftId: veteran, rightId: other,
                                   outcome: .left)
        let veteranBefore = try XCTUnwrap(try standing(veteran))

        let recorded = try store.recordComparison(subject: .actor, leftId: veteran,
                                                  rightId: newcomer, outcome: .right)
        try store.undoComparison(recorded)

        XCTAssertEqual(try XCTUnwrap(try standing(veteran)).score, veteranBefore.score,
                       accuracy: 0.000_001)
        XCTAssertEqual(try standing(veteran)?.comparisons, 1)
        XCTAssertNil(try standing(newcomer), "the row this comparison created is gone")
    }

    // MARK: - R6 — retirement survives play and undo

    /// ⚠️ Undo must not un-retire someone as a side effect. Retirement is a
    /// separate statement from any comparison.
    func testRetirementSurvivesAComparisonAndItsUndo() throws {
        let a = try actor("A Example"), b = try actor("B Example")
        try store.recordComparison(subject: .actor, leftId: a, rightId: b, outcome: .left)
        try store.retirePreferenceContender(subject: .actor, contenderId: a)

        let recorded = try store.recordComparison(subject: .actor, leftId: a, rightId: b,
                                                  outcome: .right)
        XCTAssertEqual(try standing(a)?.retired, true, "still retired after playing")

        try store.undoComparison(recorded)
        XCTAssertEqual(try standing(a)?.retired, true, "and after undoing")
    }

    // MARK: - R7 — refusals

    func testAContenderCannotPlayItself() throws {
        let a = try actor("A Example")
        XCTAssertThrowsError(try store.recordComparison(subject: .actor, leftId: a,
                                                        rightId: a, outcome: .left)) {
            XCTAssertEqual($0 as? PreferenceStoreError, .sameContender(a))
        }
        XCTAssertTrue(try store.preferenceRecords(subject: .actor).isEmpty,
                      "and nothing was written on the way to refusing")
    }

    // MARK: - 🚨 R8 — T5 at the store layer

    func testPlayingAndUndoingNeverTouchARating() throws {
        let a = try actor("A Example", rating: 4)
        let b = try actor("B Example", rating: 2)

        let recorded = try store.recordComparison(subject: .actor, leftId: a, rightId: b,
                                                  outcome: .left)
        try store.undoComparison(recorded)
        try store.recordComparison(subject: .actor, leftId: a, rightId: b, outcome: .draw)

        XCTAssertEqual(try store.fetchEntityProfile(for: a)?.rating, 4)
        XCTAssertEqual(try store.fetchEntityProfile(for: b)?.rating, 2)
    }

    // MARK: - R9 — T11, one ladder

    /// Comparisons drawn from different pools accumulate onto the same score.
    /// There is nowhere to put a pool identifier, which is the point.
    func testComparisonsFromDifferentPoolsAccumulateOnOneScore() throws {
        let a = try actor("A Example"), b = try actor("B Example"), c = try actor("C Example")

        try store.recordComparison(subject: .actor, leftId: a, rightId: b, outcome: .left)
        try store.recordComparison(subject: .actor, leftId: a, rightId: c, outcome: .left)

        XCTAssertEqual(try standing(a)?.comparisons, 2)
    }
}
