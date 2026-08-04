// ActorVideoCountsTests.swift
//
// The equivalence test (T1) is the one that matters. The fast path replaced a
// computation whose results are shown on every card and drive both a filter and
// a sort — a subtle disagreement would be visible everywhere and obvious
// nowhere. So rather than asserting hand-written expectations, the important
// tests assert that the fast path agrees with the slow one it replaced.

import XCTest
@testable import LibraryCore

final class ActorVideoCountsTests: XCTestCase {

    /// `Asset.actors` is DERIVED from tags prefixed `actor:` — there is no
    /// `actors` initialiser parameter. Building assets the real way also means
    /// these tests run through TagNormalizer exactly as production does.
    private func asset(_ actors: [String], _ name: String = "v") -> Asset {
        Asset(relativePath: "\(name).mp4", fileName: "\(name).mp4",
              tags: actors.map { "actor:\($0)" })
    }

    private func profile(_ name: String, akas: [String]) -> (String, EntityProfile) {
        ("actor:\(name)", EntityProfile(id: "actor:\(name)", akas: akas))
    }

    // MARK: - T1, equivalence with the computation it replaced

    func testAgreesWithTheReferenceComputationOnAKAOverlap() {
        let assets = [asset(["Jane Doe"], "a"),
                      asset(["Janie D"], "b"),
                      asset(["Someone Else"], "c")]
        let profiles = Dictionary(uniqueKeysWithValues: [profile("Jane Doe", akas: ["Janie D"])])

        let fast = ActorVideoCounts.build(assets: assets, profiles: profiles)
        for actor in ["Jane Doe", "Janie D", "Someone Else"] {
            XCTAssertEqual(
                fast[actor] ?? 0,
                ActorVideoCounts.referenceCount(for: actor, assets: assets, profiles: profiles),
                "disagreement for \(actor)")
        }
    }

    func testAgreesWithTheReferenceAcrossAGeneratedLibrary() {
        // Deterministic pseudo-random shapes: overlapping aliases, shared names,
        // actors with no profile, assets with no actors.
        var assets: [Asset] = []
        var profiles: [String: EntityProfile] = [:]
        let names = (0..<40).map { "Actor \($0)" }

        for (i, name) in names.enumerated() where i % 3 == 0 {
            // Every third actor lists the NEXT actor's name as an alias, which
            // is the case most likely to be miscounted.
            let (k, v) = profile(name, akas: [names[(i + 1) % names.count]])
            profiles[k] = v
        }
        for i in 0..<120 {
            let cast = (0..<(i % 4)).map { names[(i * 7 + $0 * 11) % names.count] }
            assets.append(asset(cast, "v\(i)"))
        }

        let fast = ActorVideoCounts.build(assets: assets, profiles: profiles)
        for name in names {
            XCTAssertEqual(
                fast[name] ?? 0,
                ActorVideoCounts.referenceCount(for: name, assets: assets, profiles: profiles),
                "disagreement for \(name)")
        }
    }

    // MARK: - The specific behaviours that equivalence depends on

    func testAnAssetCreditingBothANameAndItsAliasCountsOnce() {
        // This counts ASSETS, not name matches. Counting twice here would
        // inflate exactly the actors with the richest alias data.
        let assets = [asset(["Jane Doe", "Janie D"])]
        let profiles = Dictionary(uniqueKeysWithValues: [profile("Jane Doe", akas: ["Janie D"])])
        XCTAssertEqual(ActorVideoCounts.build(assets: assets, profiles: profiles)["Jane Doe"], 1)
    }

    func testAnActorWithNoProfileStillCountsByName() {
        // Most actors have a profile, but not all — and the old code matched
        // them by name regardless.
        let assets = [asset(["Unknown Person"]), asset(["Unknown Person"])]
        XCTAssertEqual(ActorVideoCounts.build(assets: assets, profiles: [:])["Unknown Person"], 2)
    }

    func testSeveralActorsMayShareAnAlias() {
        // Both should be credited; taking a single owner would lose one.
        let assets = [asset(["Shared Alias"])]
        let profiles = Dictionary(uniqueKeysWithValues: [
            profile("First Actor", akas: ["Shared Alias"]),
            profile("Second Actor", akas: ["Shared Alias"]),
        ])
        let counts = ActorVideoCounts.build(assets: assets, profiles: profiles)
        XCTAssertEqual(counts["First Actor"], 1)
        XCTAssertEqual(counts["Second Actor"], 1)
    }

    func testEmptyAliasesAreIgnored() {
        // A blank AKA would otherwise credit every asset with a blank actor name.
        let assets = [asset([""]), asset(["Jane Doe"])]
        let profiles = Dictionary(uniqueKeysWithValues: [profile("Jane Doe", akas: [""])])
        XCTAssertEqual(ActorVideoCounts.build(assets: assets, profiles: profiles)["Jane Doe"], 1)
    }

    func testNonActorProfilesAreIgnored() {
        // entityProfiles holds studios and tags too; their AKAs must not credit
        // an actor.
        let assets = [asset(["Some Studio"])]
        let profiles = ["studio:Some Studio": EntityProfile(id: "studio:Some Studio",
                                                            akas: ["Jane Doe"])]
        XCTAssertNil(ActorVideoCounts.build(assets: assets, profiles: profiles)["Jane Doe"])
    }

    func testAnActorWithNoVideosIsAbsentRatherThanZero() {
        // Callers read `counts[actor] ?? 0`, so absent and zero are equivalent —
        // this pins that no phantom entries are produced.
        let profiles = Dictionary(uniqueKeysWithValues: [profile("Ghost", akas: [])])
        XCTAssertTrue(ActorVideoCounts.build(assets: [], profiles: profiles).isEmpty)
    }

    // MARK: - T2, the cost that motivated this

    func testBuildingCountsForALibrarySizedSetIsFast() {
        // 1,335 actors and 1,346 assets — the measured library. The old path
        // performed ~37 million asset inspections to sort this; one pass must
        // be trivial by comparison.
        let names = (0..<1335).map { "Actor \($0)" }
        var profiles: [String: EntityProfile] = [:]
        for (i, n) in names.enumerated() where i % 5 == 0 {
            let (k, v) = profile(n, akas: ["Alias \(i)"])
            profiles[k] = v
        }
        let assets = (0..<1346).map { i in
            asset([names[i % names.count], names[(i * 3) % names.count]], "v\(i)")
        }

        let started = Date()
        let counts = ActorVideoCounts.build(assets: assets, profiles: profiles)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertFalse(counts.isEmpty)
        XCTAssertLessThan(elapsed, 0.5, "one pass over the library should be well under half a second")
    }
}
