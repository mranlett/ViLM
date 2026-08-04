import XCTest
@testable import LibraryCore

/// Finding tags whose capitalization needs repairing.
///
/// Nothing here knows any real tag. The vocabulary belongs to the library and
/// to whatever source is installed — a table of acronyms compiled into the app
/// would be both wrong to carry and impossible to keep current.
final class TagCaseAuditTests: XCTestCase {

    // MARK: - Collisions

    func testSpellingsDifferingOnlyByCaseCollide() {
        let found = TagCaseAudit.collisions(in: ["Pov": 12, "POV": 3, "Outdoors": 5])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.key, "pov")
        XCTAssertEqual(found.first?.totalUses, 15)
    }

    func testDifferentWordsAreNotACollision() {
        XCTAssertTrue(TagCaseAudit.collisions(in: ["Climbing": 4, "Climbdown": 2]).isEmpty)
    }

    func testTheMostUsedSpellingIsKept() {
        let found = TagCaseAudit.collisions(in: ["Pov": 12, "POV": 3])
        XCTAssertEqual(found.first?.suggestedKeeper, "Pov")
        XCTAssertEqual(found.first?.losers, ["POV"])
    }

    /// A tie goes to the spelling with more capitals: where both are used
    /// equally, the one that KEPT its capitals survived a rule that used to
    /// strip them, so it is the deliberate one.
    func testATieGoesToTheSpellingWithMoreCapitals() {
        let found = TagCaseAudit.collisions(in: ["Scuba": 4, "SCUBA": 4])
        XCTAssertEqual(found.first?.suggestedKeeper, "SCUBA")
    }

    func testBiggestCollisionsComeFirst() {
        let found = TagCaseAudit.collisions(in: ["a": 1, "A": 1, "Big": 50, "BIG": 40])
        XCTAssertEqual(found.first?.key, "big")
    }

    // MARK: - Respellings

    func testASourceSpellingIsSuggested() {
        let found = TagCaseAudit.respellings(current: ["Scuba": 9],
                                             canonical: ["scuba": "SCUBA"])
        XCTAssertEqual(found, [TagRespelling(current: "Scuba", suggested: "SCUBA", uses: 9)])
    }

    func testAnAlreadyMatchingSpellingIsNotSuggested() {
        XCTAssertTrue(TagCaseAudit.respellings(current: ["SCUBA": 9],
                                               canonical: ["scuba": "SCUBA"]).isEmpty)
    }

    /// The guard that keeps this a CAPITALIZATION repair. A source proposing a
    /// different word is proposing a different tag, and adopting it silently
    /// would rewrite the library's vocabulary rather than fix its case.
    func testADifferentWordIsNeverTreatedAsARespelling() {
        let found = TagCaseAudit.respellings(current: ["Climbing": 3],
                                             canonical: ["climbing": "Climbing Her"])
        XCTAssertTrue(found.isEmpty)
    }

    func testTagsTheSourceDoesNotKnowAreLeftAlone() {
        XCTAssertTrue(TagCaseAudit.respellings(current: ["My Own Tag": 2],
                                               canonical: [:]).isEmpty)
    }

    // MARK: - Counting

    func testCountsOnlyPlainTags() {
        let assets = [
            Asset(relativePath: "a.mp4", fileName: "a.mp4",
                  tags: ["tag:Outdoors", "actor:Someone", "studio:Somewhere"]),
            Asset(relativePath: "b.mp4", fileName: "b.mp4", tags: ["tag:Outdoors"]),
        ]
        XCTAssertEqual(TagCaseAudit.tagCounts(in: assets), ["Outdoors": 2])
    }
}
