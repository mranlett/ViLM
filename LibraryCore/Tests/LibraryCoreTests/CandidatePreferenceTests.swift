import XCTest
@testable import LibraryCore

/// Original production ahead of redistribution — decided by release date,
/// applied only between listings of the same work.
final class CandidatePreferenceTests: XCTestCase {

    private func candidate(_ id: String, _ title: String,
                           date: String? = nil, duration: Int? = 1800) -> PluginCandidate {
        PluginCandidate(id: id, title: title, durationSeconds: duration, releaseDate: date)
    }

    private func ids(_ list: [PluginCandidate]) -> [String] { list.map(\.id) }

    // MARK: - The rule

    func testTheEarlierReleaseOfTheSameWorkComesFirst() {
        let result = CandidatePreference.preferOriginalProduction([
            candidate("redistributed", "The Same Scene", date: "2021-06-01"),
            candidate("original", "The Same Scene", date: "2016-02-11"),
        ])

        XCTAssertEqual(ids(result), ["original", "redistributed"])
    }

    /// ⚠️ Reordering happens INSIDE a work. The search ranked these by how well
    /// they match the file, and an older unrelated scene must not climb over a
    /// better match just for being old.
    func testDifferentWorksKeepTheirSearchRanking() {
        let result = CandidatePreference.preferOriginalProduction([
            candidate("best-match", "Some Scene", date: "2022-01-01", duration: 1800),
            candidate("older-other", "A Different Scene", date: "2010-01-01", duration: 900),
        ])

        XCTAssertEqual(ids(result), ["best-match", "older-other"])
    }

    func testAWorkIsToldApartByTitleAndRunningTime() {
        let result = CandidatePreference.preferOriginalProduction([
            candidate("short-2022", "Same Title", date: "2022-01-01", duration: 600),
            candidate("long-2010", "Same Title", date: "2010-01-01", duration: 3600),
        ])

        XCTAssertEqual(ids(result), ["short-2022", "long-2010"],
                       "same name, very different length — not the same scene")
    }

    /// Two listings of one scene routinely differ by a few seconds.
    func testASmallDurationDifferenceIsStillTheSameWork() {
        let result = CandidatePreference.preferOriginalProduction([
            candidate("later", "The Same Scene", date: "2021-06-01", duration: 1803),
            candidate("earlier", "The Same Scene", date: "2016-02-11", duration: 1800),
        ])

        XCTAssertEqual(ids(result), ["earlier", "later"])
    }

    // MARK: - ⚠️ Where it refuses to decide

    /// Missing data must not outrank a stated fact.
    func testAnUndatedCandidateDoesNotBecomeTheOriginal() {
        let result = CandidatePreference.preferOriginalProduction([
            candidate("dated", "The Same Scene", date: "2016-02-11"),
            candidate("undated", "The Same Scene", date: nil),
        ])

        XCTAssertEqual(ids(result), ["dated", "undated"])
    }

    func testNeitherDatedKeepsTheSourceOrder() {
        let result = CandidatePreference.preferOriginalProduction([
            candidate("first", "The Same Scene", date: nil),
            candidate("second", "The Same Scene", date: nil),
        ])

        XCTAssertEqual(ids(result), ["first", "second"])
    }

    func testTheSameDateKeepsTheSourceOrder() {
        let result = CandidatePreference.preferOriginalProduction([
            candidate("first", "The Same Scene", date: "2016-02-11"),
            candidate("second", "The Same Scene", date: "2016-02-11"),
        ])

        XCTAssertEqual(ids(result), ["first", "second"])
    }

    // MARK: - Leaves ordinary lists alone

    func testAListWithNoDuplicatesIsUnchanged() {
        let input = [
            candidate("a", "One", date: "2020-01-01", duration: 100),
            candidate("b", "Two", date: "2019-01-01", duration: 200),
            candidate("c", "Three", date: "2021-01-01", duration: 300),
        ]

        XCTAssertEqual(ids(CandidatePreference.preferOriginalProduction(input)),
                       ["a", "b", "c"])
    }

    func testAnEmptyListIsFine() {
        XCTAssertTrue(CandidatePreference.preferOriginalProduction([]).isEmpty)
    }

    /// Three listings of one scene: earliest first, the rest in date order.
    func testThreeListingsSortByDate() {
        let result = CandidatePreference.preferOriginalProduction([
            candidate("newest", "The Same Scene", date: "2023-01-01"),
            candidate("oldest", "The Same Scene", date: "2011-01-01"),
            candidate("middle", "The Same Scene", date: "2017-01-01"),
        ])

        XCTAssertEqual(ids(result), ["oldest", "middle", "newest"])
    }
}
