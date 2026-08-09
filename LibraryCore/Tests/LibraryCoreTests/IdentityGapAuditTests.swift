import XCTest
@testable import LibraryCore

/// The missing-identity worklist.
///
/// 🚨 What the match edges exist to make visible: `enrichmentState = matched`
/// beside a null `enrichmentSourceId` is indistinguishable from a record nobody
/// ever looked up. Those records were invisible AND unreachable, because every
/// matching tool skips anything already matched.
///
/// ⭐ What makes it a WORKLIST rather than a list is the second question: for
/// each one, is there a route back? A flat list of 243 names says nothing about
/// which of them one unattended pass would fix.
final class IdentityGapAuditTests: XCTestCase {

    /// ⚠️ LEGACY `type:Name` ids with no columns, so every test using this is
    /// a characterisation of a library that has not been re-keyed. The
    /// re-keyed shape is exercised at the bottom of the file.
    private func input(_ missing: [String],
                       videos: [String: Int] = [:],
                       matched: [String: Int] = [:]) -> IdentityGapAudit.Input {
        .init(missing: missing.map { ProfileRef(id: $0) },
              videosByNode: videos, matchedVideosByNode: matched)
    }

    // MARK: - The route back

    /// ⭐ A performer credited on a MATCHED video is recoverable: that video's
    /// source record links to their confirmed profile.
    func testANodeOnAMatchedVideoIsRecoverable() {
        let r = IdentityGapAudit.report(input(["actor:Alice"],
                                              videos: ["actor:Alice": 4],
                                              matched: ["actor:Alice": 2]))

        XCTAssertEqual(r.recoverable.map(\.displayName), ["Alice"])
        XCTAssertTrue(r.needsAPerson.isEmpty)
    }

    /// ⚠️ Credited only on UNMATCHED videos: nothing to hand an identity down.
    func testANodeOnNoMatchedVideoNeedsAPerson() {
        let r = IdentityGapAudit.report(input(["actor:Bob"],
                                              videos: ["actor:Bob": 3],
                                              matched: [:]))

        XCTAssertEqual(r.needsAPerson.map(\.displayName), ["Bob"])
        XCTAssertTrue(r.recoverable.isEmpty)
    }

    /// A node in no videos at all is the hardest case, and still reported.
    func testANodeInNoVideosIsStillListed() {
        let r = IdentityGapAudit.report(input(["actor:Ghost"]))

        XCTAssertEqual(r.needsAPerson.count, 1)
        XCTAssertEqual(r.gaps.first?.videoCount, 0)
    }

    // MARK: - Ordering

    /// ⚠️ Recoverable FIRST. Someone working down the list should meet the ones
    /// a single pass fixes before the ones costing a lookup each.
    func testRecoverableEntriesComeFirst() {
        let r = IdentityGapAudit.report(input(
            ["actor:Manual", "actor:Auto"],
            videos: ["actor:Manual": 9, "actor:Auto": 1],
            matched: ["actor:Auto": 1]))

        XCTAssertEqual(r.gaps.map(\.displayName), ["Auto", "Manual"],
                       "recoverable outranks a much larger manual case")
    }

    /// Within a pile, the most-credited matter most.
    func testTheMostCreditedComeFirstWithinAPile() {
        let r = IdentityGapAudit.report(input(
            ["actor:Few", "actor:Many"],
            videos: ["actor:Few": 1, "actor:Many": 30]))

        XCTAssertEqual(r.gaps.map(\.displayName), ["Many", "Few"])
    }

    // MARK: - Shape

    func testStudiosAndActorsAreDistinguishable() {
        let r = IdentityGapAudit.report(input(["actor:Alice", "studio:Coast Line"]))

        XCTAssertEqual(r.of(.actor).map(\.displayName), ["Alice"])
        XCTAssertEqual(r.of(.studio).map(\.displayName), ["Coast Line"])
    }

    /// ⚠️ An id shape this build does not recognise is skipped, not guessed at.
    func testAnUnrecognisedIdIsIgnored() {
        XCTAssertTrue(IdentityGapAudit.report(input(["tag:blonde", "whatever"])).isEmpty)
    }

    // MARK: - What it says

    /// The headline distinguishes the two piles, because they mean different
    /// work — not just a different number.
    func testTheHeadlineSaysWhichKindOfWorkIsWaiting() {
        XCTAssertTrue(IdentityGapAudit.report(input([])).headline
            .contains("Every matched record"))

        let auto = IdentityGapAudit.report(input(["actor:A"], videos: ["actor:A": 1],
                                                 matched: ["actor:A": 1]))
        XCTAssertTrue(auto.headline.contains("recovered"), auto.headline)

        let manual = IdentityGapAudit.report(input(["actor:B"]))
        XCTAssertTrue(manual.headline.contains("nothing to look it up by"), manual.headline)

        let both = IdentityGapAudit.report(input(["actor:A", "actor:B"],
                                                 videos: ["actor:A": 1],
                                                 matched: ["actor:A": 1]))
        XCTAssertTrue(both.headline.contains("need you"), both.headline)
    }

    // MARK: - 🚨 The re-keyed library

    /// G1 — the defect. Every node claiming a match it cannot prove was
    /// dropped, and the report's headline read "Every matched record carries
    /// an identity" on a library where 1,236 of them did not.
    func testARekeyedLibrarysGapsAreStillReported() {
        let uid = UUID().uuidString
        let report = IdentityGapAudit.report(.init(
            missing: [ProfileRef(id: uid, entityType: "actor", displayName: "Alice")],
            videosByNode: [uid: 4], matchedVideosByNode: [uid: 2]))

        XCTAssertFalse(report.isEmpty, "the gap must not vanish with the id shape")
        XCTAssertEqual(report.gaps.first?.displayName, "Alice")
        XCTAssertEqual(report.gaps.first?.videoCount, 4)
        XCTAssertEqual(report.gaps.first?.isRecoverableByRefresh, true)
    }

    /// G2 — ⚠️ the worklist SORTS by this name, so a chopped-up uid would not
    /// merely look wrong, it would scatter the list.
    func testTheWorklistSortsByTheRealName() {
        func ref(_ name: String) -> ProfileRef {
            ProfileRef(id: UUID().uuidString, entityType: "actor", displayName: name)
        }
        let report = IdentityGapAudit.report(.init(
            missing: [ref("Zoe"), ref("alice"), ref("Bob")],
            videosByNode: [:], matchedVideosByNode: [:]))

        XCTAssertEqual(report.gaps.map(\.displayName), ["alice", "Bob", "Zoe"])
    }

    /// G3 — a uid-keyed row with no columns still has no knowable kind and is
    /// still skipped, exactly as an unrecognised id always was.
    func testAUidWithNoColumnsIsStillSkipped() {
        let report = IdentityGapAudit.report(.init(
            missing: [ProfileRef(id: UUID().uuidString)],
            videosByNode: [:], matchedVideosByNode: [:]))

        XCTAssertTrue(report.isEmpty)
    }
}
