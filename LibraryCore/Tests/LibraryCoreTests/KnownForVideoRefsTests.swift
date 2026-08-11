// KnownForVideoRefsTests.swift
// The videos behind the count, for showing stills in Head to Head.
//
// 🚨 The property that matters is AGREEMENT. The card shows "9 videos" and the
// strip below it shows the stills; if those two numbers can differ the operator
// has no way to resolve the contradiction. They come from one pass for exactly
// that reason — filtering the assets again in the view would re-express the
// AKA-crediting rule and drift from it, which is the same failure
// `ActorVideoCounts` parity already guards against one layer up.

import XCTest
@testable import LibraryCore

final class KnownForVideoRefsTests: XCTestCase {

    private func asset(_ title: String, actors: [String], date: String? = nil) -> Asset {
        var a = Asset(relativePath: "\(UUID()).mp4", fileName: "\(title).mp4",
                      tags: actors.map { "actor:\($0)" })
        a.videoName = title
        a.releaseDate = date
        return a
    }

    private func index(_ profiles: [EntityProfile] = []) -> EntityProfileIndex {
        EntityProfileIndex(profiles)
    }

    // MARK: - 🚨 The strip cannot disagree with the count

    func testEveryCountedVideoHasARef() {
        let assets = [asset("One", actors: ["Ann"]),
                      asset("Two", actors: ["Ann"]),
                      asset("Three", actors: ["Ann"])]

        let summary = ActorKnownFor.build(assets: assets, profiles: index())["Ann"]

        XCTAssertEqual(summary?.videoCount, 3)
        XCTAssertEqual(summary?.videos.count, 3, "the strip shows what the count counted")
    }

    /// ⚠️ Including through an alias. The count credits AKAs; if the refs did
    /// not, expanding an aliased performer would show fewer stills than the
    /// number directly above them.
    func testARefIsProducedForACreditThroughAnAlias() {
        var profile = EntityProfile(id: "p1", entityType: "actor", displayName: "Ann Example")
        profile.akas = ["A. Example"]
        let assets = [asset("One", actors: ["Ann Example"]),
                      asset("Two", actors: ["A. Example"])]

        let summary = ActorKnownFor.build(assets: assets, profiles: index([profile]))["Ann Example"]

        XCTAssertEqual(summary?.videoCount, 2)
        XCTAssertEqual(summary?.videos.count, 2)
    }

    /// ⭐ Two files of one scene are TWO videos here, unlike `titles`, which
    /// dedupes. The count counts assets, so the refs must too.
    func testDuplicateTitlesAreNotDeduped() {
        let assets = [asset("Same", actors: ["Ann"]), asset("Same", actors: ["Ann"])]

        let summary = ActorKnownFor.build(assets: assets, profiles: index())["Ann"]

        XCTAssertEqual(summary?.titles.count, 1, "one thing to be reminded of")
        XCTAssertEqual(summary?.videos.count, 2, "but two videos, as the count says")
        XCTAssertEqual(summary?.videoCount, 2)
    }

    // MARK: - Order

    /// Newest first, matching the titles above the strip — nils last, because
    /// "no date" is not "oldest".
    func testRefsAreNewestFirstWithUndatedLast() {
        let assets = [asset("Old", actors: ["Ann"], date: "2015-01-01"),
                      asset("Undated", actors: ["Ann"]),
                      asset("New", actors: ["Ann"], date: "2021-01-01")]

        let refs = ActorKnownFor.build(assets: assets, profiles: index())["Ann"]?.videos ?? []

        XCTAssertEqual(refs.map(\.title), ["New", "Old", "Undated"])
    }

    /// ⚠️ Stable between appearances. The same performer comes up in many
    /// pairs in a session, and a strip that reordered itself would read as
    /// different information about the same person.
    func testTheOrderDoesNotDependOnInputOrder() {
        let assets = [asset("B", actors: ["Ann"]), asset("A", actors: ["Ann"]),
                      asset("C", actors: ["Ann"])]

        let forward = ActorKnownFor.build(assets: assets, profiles: index())["Ann"]?.videos
        let reversed = ActorKnownFor.build(assets: assets.reversed(),
                                           profiles: index())["Ann"]?.videos

        XCTAssertEqual(forward?.map(\.title), reversed?.map(\.title))
    }

    /// A video with no name is still listed — it is one of the videos counted,
    /// and dropping it would reopen the gap between the two numbers.
    func testAnUntitledVideoIsStillListed() {
        var bare = Asset(relativePath: "x.mp4", fileName: "x.mp4", tags: ["actor:Ann"])
        bare.videoName = nil

        let summary = ActorKnownFor.build(assets: [bare], profiles: index())["Ann"]

        XCTAssertEqual(summary?.videoCount, 1)
        XCTAssertEqual(summary?.videos.count, 1)
        XCTAssertFalse(summary?.videos.first?.title.isEmpty ?? true,
                       "labelled by the same rule the strip uses")
    }
}
