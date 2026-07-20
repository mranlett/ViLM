import XCTest
@testable import LibraryCore

/// A small seedable RNG (SplitMix64) so the picker's random choices are
/// deterministic under test.
private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

final class QuickActionPickerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000_000)
    private var old: Date { now.addingTimeInterval(-100 * 24 * 60 * 60) }
    private var recent: Date { now.addingTimeInterval(-10 * 24 * 60 * 60) }
    private let picker = QuickActionPicker()

    private func asset(
        _ tag: String,
        created: Date? = nil,
        rating: Int? = nil,
        playCount: Int = 0,
        lastPlayed: Date? = nil,
        tags: [String] = []
    ) -> Asset {
        Asset(relativePath: "\(tag).mp4", fileName: "\(tag).mp4",
              createdAt: created ?? recent, tags: tags, notes: tag,
              rating: rating, playCount: playCount, lastPlayedAt: lastPlayed)
    }

    private func run(_ action: QuickAction, _ assets: [Asset],
                     profiles: [String: EntityProfile] = [:], aka: [String: String] = [:],
                     seed: UInt64 = 42) -> QuickActionResult {
        var rng = SeededRNG(seed: seed)
        return picker.pick(action, assets: assets, entityProfiles: profiles, akaMap: aka, now: now, using: &rng)
    }

    // MARK: - Play Something New

    func testPlaySomethingNewPicksAnUnwatchedVideo() {
        let unplayed = asset("unplayed", playCount: 0)
        let played = asset("played", playCount: 3, lastPlayed: recent)
        guard case let .play(pick) = run(.playSomethingNew, [played, unplayed]) else {
            return XCTFail("expected a play result")
        }
        XCTAssertEqual(pick.playCount, 0, "must pick from the never-watched pool when it's non-empty")
    }

    func testPlaySomethingNewFallsBackToLeastRecentlyPlayed() {
        // Everything's been watched → fall back to the oldest last-played.
        let a = asset("a", playCount: 1, lastPlayed: old)     // least recently played
        let b = asset("b", playCount: 1, lastPlayed: recent)
        guard case let .play(pick) = run(.playSomethingNew, [b, a]) else {
            return XCTFail("expected a play result")
        }
        XCTAssertEqual(pick.notes, "a")
    }

    // MARK: - Rediscover

    func testRediscoverPicksFromCanonicalPoolWhenAvailable() {
        let inPool = asset("inPool", created: old, rating: 5, playCount: 2, lastPlayed: old) // 4-5★ + stale
        let recentlyPlayed = asset("recent", created: old, rating: 5, playCount: 2, lastPlayed: recent)
        guard case let .play(pick) = run(.rediscover, [recentlyPlayed, inPool]) else {
            return XCTFail("expected a play result")
        }
        XCTAssertEqual(pick.notes, "inPool")
    }

    func testRediscoverLoosensRatingWhenPoolEmpty() {
        // No 4-5★ stale videos, but a 3★ stale one exists → rung 2.
        let threeStale = asset("threeStale", created: old, rating: 3, playCount: 1, lastPlayed: old)
        guard case let .play(pick) = run(.rediscover, [threeStale]) else {
            return XCTFail("expected a play result")
        }
        XCTAssertEqual(pick.notes, "threeStale")
    }

    func testRediscoverLoosensRecencyAsLastResort() {
        // Only a 3★ *recently-played* video exists — rungs 1 & 2 are empty, so
        // rung 3 (drop the recency requirement) is the one that catches it.
        let threeRecent = asset("threeRecent", created: recent, rating: 3, playCount: 1, lastPlayed: recent)
        guard case let .play(pick) = run(.rediscover, [threeRecent]) else {
            return XCTFail("expected a play result")
        }
        XCTAssertEqual(pick.notes, "threeRecent")
    }

    // MARK: - Actor Spotlight

    func testActorSpotlightPrefersActorsWithThreePlusVideos() {
        // Jane has 3 videos, John has 1. With the 3+ bar, only Jane qualifies.
        let assets = [
            asset("j1", tags: ["actor:Jane"]),
            asset("j2", tags: ["actor:Jane"]),
            asset("j3", tags: ["actor:Jane"]),
            asset("k1", tags: ["actor:John"])
        ]
        guard case let .play(pick) = run(.actorSpotlight, assets) else {
            return XCTFail("expected a play result")
        }
        XCTAssertTrue(pick.actors.contains("Jane"), "should spotlight the actor meeting the 3+ threshold")
    }

    func testActorSpotlightLoosensWhenNobodyHasThree() {
        let assets = [asset("k1", tags: ["actor:John"])] // John has 1
        guard case let .play(pick) = run(.actorSpotlight, assets) else {
            return XCTFail("expected a play result")
        }
        XCTAssertTrue(pick.actors.contains("John"))
    }

    // MARK: - Discover Mix

    func testDiscoverMixReturnsANonEmptyFilter() {
        let profiles = ["actor:Jane": EntityProfile(id: "actor:Jane", tags: ["tag:Lead"])]
        let a = asset("a", tags: ["tag:Action", "actor:Jane"])
        guard case let .openFilteredList(criteria) = run(.discoverMix, [a], profiles: profiles) else {
            return XCTFail("expected a filtered-list result")
        }
        // Whatever pairing/degrade it chose, the filter must match at least one video.
        let matched = [a].contains { asset in
            criteria.matches(asset,
                             mappedActors: AssetFilterCriteria.mappedActors(for: asset, akaMap: [:]),
                             entityProfiles: profiles)
        }
        XCTAssertTrue(matched, "Discover Mix must never open an empty list")
        XCTAssertFalse(criteria.isEmpty)
    }

    // MARK: - Empty library

    func testEmptyLibraryYieldsNothingAvailable() {
        for action in QuickAction.allCases {
            XCTAssertEqual(run(action, []), .nothingAvailable, "\(action) on empty library")
        }
    }
}
