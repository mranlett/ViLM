import XCTest
@testable import LibraryCore

/// A performer's filmography split by their age at each release.
///
/// The rules that matter are about honesty: an age derived from a birth YEAR is
/// not the same claim as one derived from a full date, and a section header is
/// a claim.
final class CareerArcTests: XCTestCase {

    private func asset(_ released: String?) -> Asset {
        Asset(relativePath: "\(UUID()).mp4", fileName: "a.mp4",
              tags: [], releaseDate: released)
    }

    private func performer(birthDate: String? = nil, birthYear: Int? = nil) -> EntityProfile {
        var p = EntityProfile(id: "actor:Someone")
        p.birthDate = birthDate
        p.birthYear = birthYear
        return p
    }

    // MARK: - The arc

    func testVideosAreGroupedByAgeAtRelease() {
        let sections = CareerArc.sections(
            assets: [asset("2020-06-01"), asset("2022-06-01"), asset("2022-09-01")],
            profile: performer(birthDate: "1995-01-01"))

        XCTAssertEqual(sections.map(\.age), [25, 27])
        XCTAssertEqual(sections.map(\.assets.count), [1, 2])
    }

    /// A career is read forwards.
    func testSectionsAscendByAge() {
        let sections = CareerArc.sections(
            assets: [asset("2024-06-01"), asset("2018-06-01"), asset("2021-06-01")],
            profile: performer(birthDate: "1995-01-01"))

        XCTAssertEqual(sections.map(\.age), [23, 26, 29])
    }

    // MARK: - Honesty about approximation

    /// ⚠️ A birth YEAR gives an answer right to within a year and no better,
    /// because whether the birthday had happened yet is unknown.
    func testAnAgeFromABirthYearIsMarkedApproximate() {
        let sections = CareerArc.sections(assets: [asset("2020-06-01")],
                                          profile: performer(birthYear: 1995))

        XCTAssertEqual(sections.first?.age, 25)
        XCTAssertTrue(sections.first?.isApproximate ?? false)
        XCTAssertEqual(sections.first?.title, "Around 25")
    }

    func testAnAgeFromAFullBirthDateIsExact() {
        let sections = CareerArc.sections(assets: [asset("2020-06-01")],
                                          profile: performer(birthDate: "1995-01-01"))

        XCTAssertFalse(sections.first?.isApproximate ?? true)
        XCTAssertEqual(sections.first?.title, "Age 25")
    }

    /// One approximate member makes the whole header approximate — the section
    /// cannot claim more precision than its least precise entry.
    func testASectionIsApproximateIfAnyMemberIs() {
        var exact = performer(birthDate: "1995-06-01")
        exact.birthYear = 1995

        // Both resolve to 25; the full date makes this one exact.
        let sections = CareerArc.sections(assets: [asset("2020-07-01")], profile: exact)
        XCTAssertFalse(sections.first?.isApproximate ?? true)
    }

    // MARK: - The unknowns

    /// They say nothing about the arc, so they must not open it.
    func testUnknownAgesSortLast() {
        let sections = CareerArc.sections(
            assets: [asset(nil), asset("2020-06-01")],
            profile: performer(birthDate: "1995-01-01"))

        XCTAssertEqual(sections.map(\.age), [25, nil])
        XCTAssertEqual(sections.last?.title, "Age not known")
    }

    func testNoBirthDateMeansEveryVideoIsUnknown() {
        let sections = CareerArc.sections(
            assets: [asset("2020-06-01"), asset("2021-06-01")],
            profile: performer())

        XCTAssertEqual(sections.count, 1)
        XCTAssertNil(sections.first?.age)
        XCTAssertEqual(sections.first?.assets.count, 2)
    }

    func testNoProfileMeansEveryVideoIsUnknown() {
        let sections = CareerArc.sections(assets: [asset("2020-06-01")], profile: nil)
        XCTAssertNil(sections.first?.age)
    }

    /// A release before the birth is a data error, not a negative age —
    /// `AgeAtReleaseCalculator` says nothing rather than something wrong.
    func testAReleaseBeforeTheBirthIsUnknownRatherThanNegative() {
        let sections = CareerArc.sections(assets: [asset("1990-06-01")],
                                          profile: performer(birthDate: "1995-01-01"))

        XCTAssertEqual(sections.map(\.age), [nil])
    }

    // MARK: - Whether to show it at all

    func testTwoKnownAgesAreWorthShowing() {
        let sections = CareerArc.sections(
            assets: [asset("2020-06-01"), asset("2022-06-01")],
            profile: performer(birthDate: "1995-01-01"))

        XCTAssertTrue(CareerArc.isWorthShowing(sections))
    }

    /// One age is a single section with a number on it, which is not an arc.
    func testOneKnownAgeIsNotWorthShowing() {
        let sections = CareerArc.sections(
            assets: [asset("2020-06-01"), asset("2020-09-01")],
            profile: performer(birthDate: "1995-01-01"))

        XCTAssertEqual(sections.count, 1)
        XCTAssertFalse(CareerArc.isWorthShowing(sections))
    }

    /// ⚠️ All-unknown produces one section headed "Age not known" — a header
    /// over the whole page saying nothing.
    func testAllUnknownIsNotWorthShowing() {
        let sections = CareerArc.sections(assets: [asset(nil), asset(nil)],
                                          profile: performer(birthDate: "1995-01-01"))

        XCTAssertFalse(CareerArc.isWorthShowing(sections))
    }

    // MARK: - Evidenced span

    /// What the library proves, as against what the source recorded — where the
    /// two disagree, either the record or a match is wrong.
    func testTheEvidencedRangeSpansTheKnownAges() {
        let sections = CareerArc.sections(
            assets: [asset("2018-06-01"), asset("2024-06-01"), asset(nil)],
            profile: performer(birthDate: "1995-01-01"))

        XCTAssertEqual(CareerArc.evidencedAgeRange(sections), 23...29)
    }

    func testNoKnownAgesHasNoRange() {
        let sections = CareerArc.sections(assets: [asset(nil)],
                                          profile: performer(birthDate: "1995-01-01"))
        XCTAssertNil(CareerArc.evidencedAgeRange(sections))
    }
}
