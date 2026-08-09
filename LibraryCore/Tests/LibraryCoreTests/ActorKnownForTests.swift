// ActorKnownForTests.swift
// What the library knows a performer for, shown beside them in Head to Head.
//
// ⚠️ K1 is the one that stops a contradiction reaching the screen: this count
// and `ActorVideoCounts.build` are displayed together, and the crediting rule
// is subtle enough that two expressions of it would drift.

import XCTest
@testable import LibraryCore

final class ActorKnownForTests: XCTestCase {

    private func asset(_ actors: [String], series: String? = nil,
                       file: String = "clip.mp4", release: String? = nil) -> Asset {
        var a = Asset(relativePath: "\(UUID()).mp4", fileName: file,
                      tags: actors.map { "actor:\($0)" })
        a.videoName = series
        a.releaseDate = release
        return a
    }

    private func index(_ profiles: [EntityProfile] = []) -> EntityProfileIndex {
        EntityProfileIndex(profiles)
    }

    // MARK: - 🚨 K1 — the count agrees with the one shown everywhere else

    func testK1TheCountAgreesWithActorVideoCounts() {
        var profile = EntityProfile(id: UUID().uuidString, entityType: "actor",
                                    displayName: "Vera Example")
        profile.akas = ["V. Example"]
        let assets = [
            asset(["Vera Example"], series: "Harbour Nights"),
            asset(["V. Example"], series: "The Long Way"),
            // ⚠️ Credits BOTH the canonical name and an alias — the rule says
            // this counts once, and it is the case a second implementation
            // gets wrong.
            asset(["Vera Example", "V. Example"], series: "Coast Road"),
            asset(["Someone Else"], series: "Not Hers"),
        ]
        let profiles = index([profile])

        let known = ActorKnownFor.build(assets: assets, profiles: profiles)
        let counts = ActorVideoCounts.build(assets: assets, profiles: profiles)

        XCTAssertEqual(known["Vera Example"]?.videoCount, counts["Vera Example"])
        XCTAssertEqual(known["Vera Example"]?.videoCount, 3, "the double credit counts once")
    }

    // MARK: - What gets shown

    func testTitlesComeBackNewestFirst() {
        let assets = [
            asset(["Vera Example"], series: "Older", release: "2019-01-01"),
            asset(["Vera Example"], series: "Newest", release: "2024-06-01"),
            asset(["Vera Example"], series: "Middle", release: "2021-03-01"),
        ]
        XCTAssertEqual(ActorKnownFor.build(assets: assets, profiles: index())["Vera Example"]?.titles,
                       ["Newest", "Middle", "Older"])
    }

    /// ⚠️ "No date" is not "oldest". An undated video sorts after the dated
    /// ones rather than being treated as ancient.
    func testUndatedVideosSortAfterDatedOnes() {
        let assets = [
            asset(["Vera Example"], series: "Undated"),
            asset(["Vera Example"], series: "Dated", release: "2015-01-01"),
        ]
        XCTAssertEqual(ActorKnownFor.build(assets: assets, profiles: index())["Vera Example"]?.titles,
                       ["Dated", "Undated"])
    }

    /// ⚠️ Deterministic across appearances. A performer shows up in many pairs
    /// in one session, and a list that reordered itself would read as different
    /// information about the same person.
    func testTheOrderDoesNotDependOnHowAssetsWereLoaded() {
        let assets = [
            asset(["Vera Example"], series: "Bravo"),
            asset(["Vera Example"], series: "Alpha"),
            asset(["Vera Example"], series: "Charlie"),
        ]
        let forward = ActorKnownFor.build(assets: assets, profiles: index())["Vera Example"]?.titles
        let backward = ActorKnownFor.build(assets: assets.reversed(), profiles: index())["Vera Example"]?.titles

        XCTAssertEqual(forward, ["Alpha", "Bravo", "Charlie"])
        XCTAssertEqual(forward, backward)
    }

    func testOnlyAFewTitlesAreReturnedButTheCountIsTotal() {
        let assets = (0..<9).map { asset(["Vera Example"], series: "Film \($0)") }
        let summary = ActorKnownFor.build(assets: assets, profiles: index(), limit: 3)["Vera Example"]

        XCTAssertEqual(summary?.titles.count, 3)
        XCTAssertEqual(summary?.videoCount, 9, "the count is every video, not the listed ones")
    }

    /// ⚠️ Two files of one scene are one thing to be reminded of, and the game
    /// cannot spare the line.
    func testARepeatedTitleIsListedOnce() {
        let assets = [
            asset(["Vera Example"], series: "Same Scene", file: "a.mp4"),
            asset(["Vera Example"], series: "Same Scene", file: "b.mp4"),
            asset(["Vera Example"], series: "Other"),
        ]
        XCTAssertEqual(ActorKnownFor.build(assets: assets, profiles: index())["Vera Example"]?.titles,
                       ["Other", "Same Scene"])
    }

    // MARK: - Falling back

    /// ⭐ A file name is a poor title and a perfectly good reminder. Dropping
    /// these would leave the least-catalogued performers with nothing shown,
    /// which is the opposite of helpful.
    func testAVideoWithNoSeriesBlockFallsBackToItsFileName() {
        let assets = [asset(["Vera Example"], file: "Harbour Nights - Silver River.mp4")]
        XCTAssertEqual(ActorKnownFor.build(assets: assets, profiles: index())["Vera Example"]?.titles,
                       ["Harbour Nights - Silver River"], "extension dropped")
    }

    func testAPerformerWithNoVideosIsAbsentRatherThanEmpty() {
        let assets = [asset(["Someone Else"], series: "Theirs")]
        XCTAssertNil(ActorKnownFor.build(assets: assets, profiles: index())["Vera Example"])
    }
}
