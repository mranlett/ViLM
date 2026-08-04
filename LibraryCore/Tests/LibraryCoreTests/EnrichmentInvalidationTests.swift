// EnrichmentInvalidationTests.swift
//
// The operator's rule: a manual edit that could change a lookup's outcome
// clears an unresolved verdict, returning the actor to the queue. Chosen over
// time-based expiry because it fires exactly when the data changes.

import XCTest
@testable import LibraryCore

final class EnrichmentInvalidationTests: XCTestCase {

    private func profile(state: EnrichmentState? = nil,
                         akas: [String] = [],
                         birthYear: Int? = nil,
                         birthDate: String? = nil,
                         rating: Int? = nil) -> EntityProfile {
        EntityProfile(id: "actor:A", birthYear: birthYear, rating: rating, akas: akas,
                      birthDate: birthDate,
                      enrichmentState: state,
                      enrichmentSource: state == nil ? nil : "Some Source",
                      enrichmentCheckedAt: state == nil ? nil : Date(timeIntervalSince1970: 1))
    }

    // MARK: - The rule

    func testAddingAnAliasClearsANoMatch() {
        // The headline case: an actor could not be found because the source
        // knows them under another name. Adding it must return them to the queue.
        let before = profile(state: .noMatch)
        let after  = profile(state: .noMatch, akas: ["Another Name"])
        let result = EnrichmentInvalidation.afterManualEdit(previous: before, edited: after)
        XCTAssertNil(result.state)
        XCTAssertNil(result.source)
        XCTAssertNil(result.checkedAt, "back to never-checked, so a re-run picks it up")
    }

    func testCorrectingABirthYearClearsAnAmbiguousVerdict() {
        // Birth year is the disambiguator for same-name performers — supplying
        // it is exactly how an ambiguous case becomes resolvable.
        let before = profile(state: .ambiguous)
        let after  = profile(state: .ambiguous, birthYear: 1988)
        XCTAssertNil(EnrichmentInvalidation.afterManualEdit(previous: before, edited: after).state)
    }

    func testCorrectingABirthDateClearsIt() {
        let before = profile(state: .needsReview, birthDate: "1990-01-01")
        let after  = profile(state: .needsReview, birthDate: "1992-04-18")
        XCTAssertNil(EnrichmentInvalidation.afterManualEdit(previous: before, edited: after).state)
    }

    // MARK: - What must NOT clear it

    func testEditingSomethingIrrelevantLeavesTheVerdictAlone() {
        // A rating change cannot alter a lookup's outcome. Clearing here would
        // churn actors back into the queue for no reason.
        let before = profile(state: .noMatch, rating: 3)
        let after  = profile(state: .noMatch, rating: 5)
        let result = EnrichmentInvalidation.afterManualEdit(previous: before, edited: after)
        XCTAssertEqual(result.state, .noMatch)
        XCTAssertNotNil(result.checkedAt)
    }

    func testAMatchedResultIsNeverCleared() {
        // Editing a matched actor's birth year must not push them back into the
        // backlog — the match already happened.
        let before = profile(state: .matched)
        let after  = profile(state: .matched, birthYear: 1988)
        XCTAssertEqual(EnrichmentInvalidation.afterManualEdit(previous: before, edited: after).state,
                       .matched)
    }

    func testAnUncheckedProfileStaysUnchecked() {
        let before = profile()
        let after  = profile(akas: ["New"])
        XCTAssertNil(EnrichmentInvalidation.afterManualEdit(previous: before, edited: after).state)
    }

    // MARK: - Match-input detection

    func testAliasComparisonIgnoresOrderAndCase() {
        // Reordering the list, or a casing fix, is not new matching information.
        let a = profile(akas: ["One", "Two"])
        let b = profile(akas: ["two", "ONE"])
        XCTAssertFalse(EnrichmentInvalidation.matchInputsChanged(from: a, to: b))
    }

    func testRemovingAnAliasAlsoCounts() {
        // Removal changes what a lookup would find just as much as addition.
        let a = profile(akas: ["One", "Two"])
        let b = profile(akas: ["One"])
        XCTAssertTrue(EnrichmentInvalidation.matchInputsChanged(from: a, to: b))
    }

    func testNonMatchingFieldsAreNotMatchInputs() {
        XCTAssertFalse(EnrichmentInvalidation.matchInputsChanged(
            from: profile(rating: 1), to: profile(rating: 5)))
    }
}
