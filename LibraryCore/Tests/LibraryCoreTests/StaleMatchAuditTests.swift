// StaleMatchAuditTests.swift
// Reporting matches the source says are gone or moved (#49 — U1, U2, U5).
//
// 🚨 U2 is asserted against the TYPE, not against behaviour, and that is the
// point of how it was built. "Unreachable" has no representation in
// `SourceRecordState`, so a failed fetch cannot be recorded as a deletion by a
// caller who forgets the rule — there is no value to pass.

import XCTest
@testable import LibraryCore

final class StaleMatchAuditTests: XCTestCase {

    private func match(_ id: String, deleted: Date? = nil, merged: String? = nil,
                       checked: Date? = nil, source: String = "TheSource") -> NodeMatch {
        NodeMatch(nodeId: id, source: source, sourceId: "s-\(id)", method: .title,
                  matchedAt: Date(timeIntervalSince1970: 1_600_000_000),
                  deletedAt: deleted, mergedInto: merged, checkedAt: checked)
    }

    private let names = ["a": "Alpha Example", "b": "Bravo Example", "c": "Charlie Example"]

    // MARK: - U1 — reported, and nothing is repaired

    func testU1ADeletedRecordIsReported() {
        let found = StaleMatchAudit.findings(from: [match("a", deleted: Date())],
                                             displayNames: names)
        XCTAssertEqual(found.map(\.displayName), ["Alpha Example"])
        XCTAssertEqual(found.first?.kind, .deleted)
    }

    /// ⭐ The audit is pure and returns findings. There is nowhere in this API
    /// to clear a match, which is what makes "report, never repair" a property
    /// rather than a promise.
    func testTheAuditKeepsTheSourceIdSoTheFindingIsActionable() {
        let found = StaleMatchAudit.findings(from: [match("a", deleted: Date())],
                                             displayNames: names)
        XCTAssertEqual(found.first?.sourceId, "s-a")
        XCTAssertEqual(found.first?.source, "TheSource")
    }

    // MARK: - 🚨 U2 — a network failure is not a deletion

    /// Asserted structurally. `SourceRecordState` has `.present`, `.deleted`
    /// and `.merged` — and deliberately no case for "I could not reach it".
    /// A caller whose fetch failed has nothing to pass, so the mistake cannot
    /// be made rather than merely being discouraged.
    func testU2ThereIsNoWayToRecordAnUnknownOutcome() {
        let states: [SourceRecordState] = [.present, .deleted, .merged(into: "x")]
        XCTAssertEqual(states.count, 3, "no fourth, unknown state exists")

        // And nothing at all is reported from a library that has never had a
        // definite answer — which is what a run of failed fetches leaves.
        XCTAssertTrue(StaleMatchAudit.findings(from: [match("a")],
                                               displayNames: names).isEmpty)
    }

    // MARK: - U5 — an unmatched or healthy node is not this audit's business

    func testU5AHealthyMatchIsNotReported() {
        let found = StaleMatchAudit.findings(
            from: [match("a", checked: Date()), match("b", deleted: Date())],
            displayNames: names)
        XCTAssertEqual(found.map(\.displayName), ["Bravo Example"])
    }

    // MARK: - 🔴 A merge is not a deletion

    func testAMergedRecordSaysWhereItWent() {
        let found = StaleMatchAudit.findings(from: [match("a", merged: "p-99")],
                                             displayNames: names)
        XCTAssertEqual(found.first?.kind, .merged(into: "p-99"))
        XCTAssertTrue(found.first?.isMerge ?? false)
    }

    /// ⚠️ Some sources tombstone a record AND record where it went. Reporting
    /// that as a plain deletion discards the forwarding address, which is the
    /// more useful half — and would send the operator to re-match by hand
    /// something the source already answered.
    func testARecordCarryingBothMarksIsReportedAsMerged() {
        let found = StaleMatchAudit.findings(
            from: [match("a", deleted: Date(), merged: "p-99")], displayNames: names)

        XCTAssertEqual(found.first?.kind, .merged(into: "p-99"))
    }

    /// Merges sort first: resolvable in one action, where a deletion needs a
    /// decision.
    func testMergesAreListedBeforeDeletions() {
        let found = StaleMatchAudit.findings(
            from: [match("a", deleted: Date()), match("b", merged: "p-1")],
            displayNames: names)
        XCTAssertEqual(found.map(\.displayName), ["Bravo Example", "Alpha Example"])
    }

    /// ⚠️ Stable between runs. The list is read repeatedly while the operator
    /// works through it, and one that reorders looks like the data changed.
    func testTheOrderDoesNotDependOnInputOrder() {
        let ms = [match("c", deleted: Date()), match("a", deleted: Date()),
                  match("b", deleted: Date())]
        XCTAssertEqual(StaleMatchAudit.findings(from: ms, displayNames: names).map(\.displayName),
                       StaleMatchAudit.findings(from: ms.reversed(), displayNames: names)
                           .map(\.displayName))
    }

    // MARK: - Naming

    /// ⚠️ A node with no name is still reported, under its id. An unnameable
    /// stale match is exactly the kind nobody would otherwise look at.
    func testAnUnnamedNodeIsStillReported() {
        let found = StaleMatchAudit.findings(from: [match("ghost", deleted: Date())],
                                             displayNames: names)
        XCTAssertEqual(found.map(\.displayName), ["ghost"])
    }

    // MARK: - The headline

    func testTheHeadlineDistinguishesMovedFromGone() {
        let found = StaleMatchAudit.findings(
            from: [match("a", deleted: Date()), match("b", merged: "p-1")],
            displayNames: names)
        let line = StaleMatchAudit.headline(found)

        XCTAssertTrue(line.contains("1 moved and can be re-pointed"), line)
        XCTAssertTrue(line.contains("1 no longer exists"), line)
    }

    /// ⭐ And says so plainly when there is nothing wrong — a clean result the
    /// operator can believe, rather than an empty list that might mean the
    /// audit did not run.
    func testAnEmptyResultSaysEverythingStillResolves() {
        XCTAssertTrue(StaleMatchAudit.headline([]).contains("still resolves"))
    }
}
