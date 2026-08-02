// EntityProfileCareerTests.swift
// The derived career values (schema v17).
//
// These are computed on read, never stored, following the `age` precedent —
// storing them would bake in a number that is wrong the following year. These
// tests pin that they are correct AND that they move with time.

import XCTest
@testable import LibraryCore

final class EntityProfileCareerTests: XCTestCase {

    /// Dates are deliberately MID-year. `yearsActive` resolves "this year" in
    /// the device's local calendar (correct — a user in Auckland should not see
    /// last year's figure), so a UTC-midnight 1 January would land in the
    /// previous year anywhere west of UTC and make these tests timezone-
    /// dependent rather than wrong.
    private func date(_ iso: String) -> Date {
        EntityProfile.isoDate(iso)!
    }

    // MARK: - Span shape

    func testOpenSpanRendersAsPresent() {
        // 75% of matched actors: a start and no end.
        let p = EntityProfile(id: "a", birthYear: 1995, careerStartYear: 2014)
        XCTAssertTrue(p.isCareerOngoing)
        XCTAssertEqual(p.careerDisplay(asOf: date("2026-06-15")),
                       "2014-present (started around 19 years old; 12 years active)")
    }

    func testClosedSpanRendersBothYears() {
        let p = EntityProfile(id: "a", birthYear: 1992, careerStartYear: 2010, careerEndYear: 2014)
        XCTAssertFalse(p.isCareerOngoing)
        XCTAssertEqual(p.careerDisplay(asOf: date("2026-06-15")),
                       "2010-2014 (started around 18 years old; 4 years active)")
    }

    func testNoStartYearMeansNothingWorthShowing() {
        XCTAssertNil(EntityProfile(id: "a").careerDisplay)
        XCTAssertNil(EntityProfile(id: "a", careerEndYear: 2014).careerDisplay)
        XCTAssertFalse(EntityProfile(id: "a", careerEndYear: 2014).isCareerOngoing)
    }

    func testSpanWithoutABirthYearOmitsTheAgeClause() {
        let p = EntityProfile(id: "a", careerStartYear: 2016)
        XCTAssertEqual(p.careerDisplay(asOf: date("2026-06-15")),
                       "2016-present (10 years active)")
    }

    // MARK: - Years active moves with time

    func testYearsActiveOnAnOpenSpanGrowsEachYear() {
        // Precisely why this is not stored.
        let p = EntityProfile(id: "a", careerStartYear: 2016)
        XCTAssertEqual(p.yearsActive(asOf: date("2026-06-15")), 10)
        XCTAssertEqual(p.yearsActive(asOf: date("2027-06-15")), 11)
    }

    func testYearsActiveOnAClosedSpanIsFixed() {
        let p = EntityProfile(id: "a", careerStartYear: 2010, careerEndYear: 2014)
        XCTAssertEqual(p.yearsActive(asOf: date("2026-06-15")), 4)
        XCTAssertEqual(p.yearsActive(asOf: date("2040-06-15")), 4)
    }

    // MARK: - Age at career start

    func testStatedAgeWinsOverTheDerivedOne() {
        // A prose source may state it outright; that is provenance, not arithmetic.
        let p = EntityProfile(id: "a", birthYear: 1995, careerStartYear: 2014,
                              ageAtCareerStart: 20)
        XCTAssertEqual(p.careerStartAge, 20)
    }

    func testAgeIsDerivedWhenNoSourceStatedOne() {
        let p = EntityProfile(id: "a", birthYear: 1995, careerStartYear: 2014)
        XCTAssertEqual(p.careerStartAge, 19)
    }

    func testDerivedAgeUsesTheFullBirthDateWhenThereIsOne() {
        let p = EntityProfile(id: "a", birthYear: 1900, birthDate: "1995-11-19",
                              careerStartYear: 2014)
        XCTAssertEqual(p.careerStartAge, 19, "the precise date wins over a stale year")
    }

    func testImpossibleDerivedAgeIsDiscarded() {
        // careerStart before birth is a data error, not a negative age.
        let p = EntityProfile(id: "a", birthYear: 2000, careerStartYear: 1990)
        XCTAssertNil(p.careerStartAge)
    }

    // MARK: - Age prefers the precise date

    func testAgeUsesBirthDateAndDoesNotRoundUpBeforeTheBirthday() {
        // The year-only path would say 38 all year. It is 37 until November.
        let p = EntityProfile(id: "a", birthDate: "1988-11-19")
        XCTAssertEqual(p.age(asOf: date("2026-06-01")), 37)
        XCTAssertEqual(p.age(asOf: date("2026-12-01")), 38)
    }

    func testAgeFallsBackToBirthYearWhenNoDateIsKnown() {
        let p = EntityProfile(id: "a", birthYear: 1988)
        XCTAssertEqual(p.age(asOf: date("2026-06-01")), 38)
    }

    func testResolvedBirthYearPrefersTheDate() {
        XCTAssertEqual(EntityProfile(id: "a", birthYear: 1900, birthDate: "1988-04-12")
                        .resolvedBirthYear, 1988)
        XCTAssertEqual(EntityProfile(id: "a", birthYear: 1988).resolvedBirthYear, 1988)
        XCTAssertNil(EntityProfile(id: "a").resolvedBirthYear)
    }

    func testAMalformedBirthDateDoesNotCrashOrLie() {
        let p = EntityProfile(id: "a", birthYear: 1988, birthDate: "not-a-date")
        XCTAssertEqual(p.age(asOf: date("2026-06-01")), 38, "falls back to the year")
    }
}
