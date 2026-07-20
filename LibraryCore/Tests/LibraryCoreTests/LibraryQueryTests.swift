import XCTest
@testable import LibraryCore

/// Characterizes the shared `LibraryQuery` pools that back Smart Shelves and the
/// Quick Actions picker. Deterministic: fixed `now`, explicit dates, and a
/// UUID tiebreak in the source so ordering is stable.
final class LibraryQueryTests: XCTestCase {

    // Fixed reference point + dates around the 90-day Rediscover cutoff.
    private let now = Date(timeIntervalSince1970: 1_000_000_000)
    private var old: Date { now.addingTimeInterval(-100 * 24 * 60 * 60) }   // 100d ago (older than cutoff)
    private var recent: Date { now.addingTimeInterval(-10 * 24 * 60 * 60) } // 10d ago (newer than cutoff)
    private var cutoff: Date { now.addingTimeInterval(-LibraryQuery.rediscoverRecency) } // exactly 90d ago

    private func asset(
        _ tag: String,
        created: Date,
        rating: Int? = nil,
        playCount: Int = 0,
        lastPlayed: Date? = nil
    ) -> Asset {
        // `notes` carries a stable label so assertions can name assets.
        Asset(relativePath: "\(tag).mp4", fileName: "\(tag).mp4",
              createdAt: created, notes: tag, rating: rating,
              playCount: playCount, lastPlayedAt: lastPlayed)
    }

    private func labels(_ assets: [Asset]) -> [String] { assets.map { $0.notes ?? "" } }

    // MARK: - Recently Added

    func testRecentlyAddedSortsNewestFirst() {
        let a = asset("old", created: old)
        let b = asset("recent", created: recent)
        let c = asset("now", created: now)
        XCTAssertEqual(labels(LibraryQuery.recentlyAdded.run(assets: [a, b, c], now: now)),
                       ["now", "recent", "old"])
    }

    // MARK: - Top Rated

    func testTopRatedIncludesFourAndFiveExcludesLowerAndUnrated() {
        let five = asset("five", created: recent, rating: 5)
        let four = asset("four", created: recent, rating: 4)
        let three = asset("three", created: recent, rating: 3)
        let none = asset("none", created: recent, rating: nil)
        let result = LibraryQuery.topRated.run(assets: [three, none, four, five], now: now)
        XCTAssertEqual(labels(result), ["five", "four"], "only rating >= 4, sorted by rating desc")
    }

    // MARK: - Never Watched

    func testNeverWatchedIsExactlyPlayCountZero() {
        let unplayed = asset("unplayed", created: recent, playCount: 0)
        let played = asset("played", created: recent, playCount: 1, lastPlayed: recent)
        XCTAssertEqual(labels(LibraryQuery.neverWatched.run(assets: [unplayed, played], now: now)),
                       ["unplayed"])
    }

    // MARK: - Most Watched

    func testMostWatchedExcludesUnplayedAndSortsByCountDesc() {
        let a = asset("a", created: recent, playCount: 5, lastPlayed: recent)
        let b = asset("b", created: recent, playCount: 2, lastPlayed: recent)
        let unplayed = asset("unplayed", created: recent, playCount: 0)
        XCTAssertEqual(labels(LibraryQuery.mostWatched.run(assets: [b, unplayed, a], now: now)),
                       ["a", "b"])
    }

    // MARK: - Rediscover

    func testRediscoverMembership() {
        let playedLongAgo = asset("playedLongAgo", created: old, rating: 5, playCount: 3, lastPlayed: old)      // in
        let playedRecently = asset("playedRecently", created: old, rating: 5, playCount: 3, lastPlayed: recent) // out (too recent)
        let neverPlayedOld = asset("neverPlayedOld", created: old, rating: 5)                                   // in
        let neverPlayedNew = asset("neverPlayedNew", created: recent, rating: 5)                                // out (added recently)
        let lowRated = asset("lowRated", created: old, rating: 3, lastPlayed: old)                              // out (rating < 4)

        let result = LibraryQuery.rediscover.run(
            assets: [playedLongAgo, playedRecently, neverPlayedOld, neverPlayedNew, lowRated], now: now)
        // Most-forgotten first: never-played (nil last-played) ahead of played-long-ago.
        XCTAssertEqual(labels(result), ["neverPlayedOld", "playedLongAgo"])
    }

    func testRediscoverRecencyBoundaryIsInclusive() {
        // Played exactly at the cutoff (90d ago) counts as eligible (<=).
        let atCutoff = asset("atCutoff", created: old, rating: 4, playCount: 1, lastPlayed: cutoff)
        XCTAssertEqual(labels(LibraryQuery.rediscover.run(assets: [atCutoff], now: now)), ["atCutoff"])
    }

    func testRediscoverRatingBoundaryExcludesThree() {
        let three = asset("three", created: old, rating: 3, lastPlayed: old)
        XCTAssertTrue(LibraryQuery.rediscover.run(assets: [three], now: now).isEmpty)
    }

    // MARK: - Empty library

    func testAllQueriesEmptyOnEmptyLibrary() {
        for query in LibraryQuery.allCases {
            XCTAssertTrue(query.run(assets: [], now: now).isEmpty, "\(query) should be empty for an empty library")
        }
    }

    func testTitlesAreStable() {
        XCTAssertEqual(LibraryQuery.rediscover.title, "Rediscover")
        XCTAssertEqual(LibraryQuery.neverWatched.title, "Never Watched")
    }
}
