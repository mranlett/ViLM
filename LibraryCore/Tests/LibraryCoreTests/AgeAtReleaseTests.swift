import XCTest
@testable import LibraryCore

/// Age at a video's release.
///
/// The property under test throughout is that an uncertain answer stays visibly
/// uncertain. A birth YEAR cannot say whether the birthday had come round yet,
/// so the derived figure is right to within a year and no better — and a filter
/// must not decide a record's fate on the difference.
final class AgeAtReleaseTests: XCTestCase {

    private func age(_ birthDate: String?, _ birthYear: Int?, _ release: String?) -> AgeAtRelease? {
        AgeAtReleaseCalculator.age(birthDate: birthDate, birthYear: birthYear, releaseDate: release)
    }

    // MARK: - Exact

    func testFullDatesGiveAnExactAge() {
        let result = age("1990-01-15", nil, "2020-06-01")
        XCTAssertEqual(result, AgeAtRelease(years: 30, isExact: true))
    }

    /// The case a naive year subtraction gets wrong: the birthday had not
    /// happened yet when this was released.
    func testBirthdayNotYetReachedCountsTheYearBefore() {
        let result = age("1990-12-31", nil, "2020-06-01")
        XCTAssertEqual(result?.years, 29, "2020 − 1990 = 30, but the birthday was six months away")
        XCTAssertEqual(result?.isExact, true)
    }

    func testBirthdayOnTheReleaseDayCounts() {
        XCTAssertEqual(age("1990-06-01", nil, "2020-06-01")?.years, 30)
    }

    func testDayBeforeTheBirthdayDoesNot() {
        XCTAssertEqual(age("1990-06-02", nil, "2020-06-01")?.years, 29)
    }

    func testLeapDayBirthday() {
        XCTAssertEqual(age("2000-02-29", nil, "2020-02-28")?.years, 19)
        XCTAssertEqual(age("2000-02-29", nil, "2020-03-01")?.years, 20)
    }

    // MARK: - Approximate

    func testABirthYearAloneIsNeverExact() {
        let result = age(nil, 1990, "2020-06-01")
        XCTAssertEqual(result, AgeAtRelease(years: 30, isExact: false))
    }

    func testAnApproximateAgeCoversBothPossibilities() {
        let result = age(nil, 1990, "2020-06-01")
        XCTAssertEqual(result?.possibleAges, 29...30)
        XCTAssertEqual(result?.displayText, "29–30")
    }

    func testAnExactAgeIsASinglePossibility() {
        let result = age("1990-01-15", nil, "2020-06-01")
        XCTAssertEqual(result?.possibleAges, 30...30)
        XCTAssertEqual(result?.displayText, "30")
    }

    /// A full birth date wins over a year — it is strictly better information.
    func testFullDateIsPreferredOverYear() {
        let result = age("1990-12-31", 1990, "2020-06-01")
        XCTAssertEqual(result?.years, 29)
        XCTAssertEqual(result?.isExact, true)
    }

    // MARK: - Refusing to answer

    func testNoReleaseDateMeansNoAnswer() {
        XCTAssertNil(age("1990-01-15", 1990, nil))
    }

    func testNoBirthInformationMeansNoAnswer() {
        XCTAssertNil(age(nil, nil, "2020-06-01"))
    }

    /// A release before the birth is a data error somewhere. Saying nothing
    /// beats reporting a negative age as though it were a fact.
    func testReleaseBeforeBirthIsRefused() {
        XCTAssertNil(age("2020-01-01", nil, "1990-01-01"))
        XCTAssertNil(age(nil, 2020, "1990-01-01"))
    }

    func testMalformedDatesAreRefused() {
        XCTAssertNil(age("not-a-date", nil, "2020-06-01"))
        XCTAssertNil(age("1990-01-15", nil, "nonsense"))
    }

    // MARK: - Across a video's cast

    private func asset(actors: [String], release: String?) -> Asset {
        Asset(relativePath: "a.mp4", fileName: "a.mp4",
              tags: actors.map { "actor:\($0)" }, releaseDate: release)
    }

    private func profiles(_ entries: [(String, String?, Int?)]) -> [String: EntityProfile] {
        var out: [String: EntityProfile] = [:]
        for (name, birthDate, birthYear) in entries {
            var profile = EntityProfile(id: "actor:\(name)")
            profile.birthDate = birthDate
            profile.birthYear = birthYear
            out[profile.id] = profile
        }
        return out
    }

    func testAgesForEveryCreditedActor() {
        let ages = AgeAtReleaseCalculator.ages(
            for: asset(actors: ["Alice Example", "Bob Example"], release: "2020-06-01"),
            profiles: profiles([("Alice Example", "1990-01-15", nil),
                                ("Bob Example", nil, 1985)]))
        XCTAssertEqual(ages["Alice Example"], AgeAtRelease(years: 30, isExact: true))
        XCTAssertEqual(ages["Bob Example"], AgeAtRelease(years: 35, isExact: false))
    }

    /// Absent rather than present-with-nil, so a caller iterating the result
    /// sees only what is actually known.
    func testActorsWithoutBirthInformationAreOmitted() {
        let ages = AgeAtReleaseCalculator.ages(
            for: asset(actors: ["Alice Example", "Bob Example"], release: "2020-06-01"),
            profiles: profiles([("Alice Example", "1990-01-15", nil),
                                ("Bob Example", nil, nil)]))
        XCTAssertEqual(Array(ages.keys), ["Alice Example"])
    }

    func testNoReleaseDateYieldsNoAges() {
        let ages = AgeAtReleaseCalculator.ages(
            for: asset(actors: ["Alice Example"], release: nil),
            profiles: profiles([("Alice Example", "1990-01-15", nil)]))
        XCTAssertTrue(ages.isEmpty)
    }

    // MARK: - Filtering

    func testMatchesWhenAnActorFallsInRange() {
        let subject = asset(actors: ["Alice Example", "Bob Example"], release: "2020-06-01")
        let people = profiles([("Alice Example", "1990-01-15", nil), ("Bob Example", nil, 1970)])
        XCTAssertTrue(AgeAtReleaseCalculator.anyActorAge(for: subject, profiles: people, within: 28...32))
        XCTAssertTrue(AgeAtReleaseCalculator.anyActorAge(for: subject, profiles: people, within: 48...52))
        XCTAssertFalse(AgeAtReleaseCalculator.anyActorAge(for: subject, profiles: people, within: 60...70))
    }

    /// The rule that matters. An approximate 30 might really be 29, so a filter
    /// for 29 must include it — deciding otherwise would exclude a record on a
    /// fact nobody has.
    func testAnApproximateAgeMatchesEitherYearItCouldBe() {
        let subject = asset(actors: ["Bob Example"], release: "2020-06-01")
        let people = profiles([("Bob Example", nil, 1990)])   // 29 or 30
        XCTAssertTrue(AgeAtReleaseCalculator.anyActorAge(for: subject, profiles: people, within: 29...29))
        XCTAssertTrue(AgeAtReleaseCalculator.anyActorAge(for: subject, profiles: people, within: 30...30))
        XCTAssertFalse(AgeAtReleaseCalculator.anyActorAge(for: subject, profiles: people, within: 31...31))
    }

    /// An exact age does NOT get the same latitude — that is the whole value of
    /// recording a full birth date.
    func testAnExactAgeMatchesOnlyItself() {
        let subject = asset(actors: ["Alice Example"], release: "2020-06-01")
        let people = profiles([("Alice Example", "1990-01-15", nil)])   // exactly 30
        XCTAssertFalse(AgeAtReleaseCalculator.anyActorAge(for: subject, profiles: people, within: 29...29))
        XCTAssertTrue(AgeAtReleaseCalculator.anyActorAge(for: subject, profiles: people, within: 30...30))
    }

    /// "Unknown" is not "outside the range" — a caller needs to tell them apart
    /// so a filter can explain why a video is missing.
    func testUnknownIsDistinguishableFromOutOfRange() {
        let known = asset(actors: ["Alice Example"], release: "2020-06-01")
        let unknown = asset(actors: ["Alice Example"], release: nil)
        let people = profiles([("Alice Example", "1990-01-15", nil)])
        XCTAssertTrue(AgeAtReleaseCalculator.isAgeKnown(for: known, profiles: people))
        XCTAssertFalse(AgeAtReleaseCalculator.isAgeKnown(for: unknown, profiles: people))
    }
}
