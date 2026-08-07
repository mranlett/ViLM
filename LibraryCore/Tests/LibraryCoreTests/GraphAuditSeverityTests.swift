import XCTest
@testable import LibraryCore

/// How much of a problem each audit finding is.
///
/// 🚨 Reported by the operator: *"it is possible for an actor to record a film
/// which is released after their retirement. That's less impossible and more
/// just an interesting datapoint."* Correct — and the screen was calling it
/// Impossible Data, which trains someone to distrust the whole list.
final class GraphAuditSeverityTests: XCTestCase {

    private func check(_ kind: GraphFinding.Kind, count: Int = 1) -> GraphCheck {
        GraphCheck(kind: kind, findings: (0..<count).map { i in
            GraphFinding(kind: kind, assetId: UUID(), videoLabel: "v\(i).mp4",
                         performer: "Someone", detail: "detail")
        })
    }

    /// ⭐ The correction. Every explanation for it is ordinary.
    func testWorkingAfterARecordedRetirementIsNotAProblem() {
        XCTAssertEqual(check(.afterCareerEnd).severity, .notable)
        XCTAssertFalse(check(.afterCareerEnd).isCertain)
    }

    /// One check, and only one, can say something is definitely wrong.
    func testOnlyABirthDateContradictionIsCertain() {
        XCTAssertEqual(check(.releasedBeforeBirth).severity, .certain)
        for kind in GraphFinding.Kind.allCases where kind != .releasedBeforeBirth {
            XCTAssertNotEqual(check(kind).severity, .certain, "\(kind) is not certain")
        }
    }

    /// These compare against a recorded span that is often just incomplete.
    func testTheCareerStartAndAgeChecksRemainSuspect() {
        XCTAssertEqual(check(.beforeCareerStart).severity, .suspect)
        XCTAssertEqual(check(.implausibleAge).severity, .suspect)
    }

    /// The wording no longer calls it impossible.
    func testTheTitleReadsAsAnObservation() {
        XCTAssertEqual(check(.afterCareerEnd).title,
                       "Worked after their recorded career ended")
        XCTAssertTrue(check(.afterCareerEnd).detail.contains("Nothing here needs fixing"))
    }

    /// ⚠️ A large pile of interesting-but-fine findings must never push a real
    /// contradiction below the fold.
    func testNotableFindingsSortLastEvenWhenTheyAreTheLargestGroup() throws {
        let ordered = GraphAudit.ordered([
            check(.afterCareerEnd, count: 500),
            check(.releasedBeforeBirth, count: 1),
            check(.beforeCareerStart, count: 50),
        ])

        XCTAssertEqual(ordered.map(\.kind),
                       [.releasedBeforeBirth, .beforeCareerStart, .afterCareerEnd])
    }
}
