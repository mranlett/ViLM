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

    private func input(_ missing: [String],
                       videos: [String: Int] = [:],
                       matched: [String: Int] = [:]) -> IdentityGapAudit.Input {
        .init(missing: missing, videosByNode: videos, matchedVideosByNode: matched)
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
}
