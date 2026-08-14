// RelocationPlanTests.swift
// The dry run: what a rename would do, and the fact that it does none of it.
//
// ⚠️ All names invented — this repository is public.

import XCTest
@testable import LibraryCore

final class RelocationPlanTests: XCTestCase {

    private var dir: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Relocation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try LibraryStore(at: dir)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnection(forLibraryAt: dir)
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func add(_ file: String, kind: ContentKind?, tags: [String] = [],
                     series: String? = nil, season: Int? = nil, episodeNumber: Int? = nil,
                     episode: String? = nil, released: String? = nil) throws -> Asset {
        let a = Asset(relativePath: file, fileName: (file as NSString).lastPathComponent,
                      tags: tags, videoName: series, seasonNumber: season,
                      episodeNumber: episodeNumber, episode: episode,
                      contentKind: kind, releaseDate: released)
        try store.insertAsset(a)
        return a
    }

    private func addStudio(_ name: String, state: EnrichmentState) throws {
        var p = try store.newEntityProfile(named: name, type: "studio")
        p.enrichmentState = state
        try store.saveEntityProfile(p)
    }

    private func addActor(_ name: String, gender: String?) throws {
        var p = try store.newEntityProfile(named: name, type: "actor")
        p.gender = gender
        try store.saveEntityProfile(p)
    }

    // MARK: - 🚨 F3 — a dry run writes nothing

    /// The assertion that matters more than the code. A plan that touches the
    /// filesystem or the database is not a plan.
    func testTheDryRunChangesNothingOnDiskOrInTheDatabase() throws {
        try addStudio("Example Pictures", state: .matched)
        let asset = try add("old name.mp4", kind: .scene,
                            tags: ["studio:Example Pictures"], released: "2019-04-12")
        let before = try store.fetchAllAssets()
        let filesBefore = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()

        let plan = try store.relocationPlan()
        XCTAssertFalse(plan.moves.isEmpty, "nothing planned — this test would prove nothing")

        XCTAssertEqual(try store.fetchAllAssets(), before, "the plan wrote to the database")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(),
                       filesBefore, "the plan touched the filesystem")
        XCTAssertEqual(try store.fetchAllAssets().first { $0.id == asset.id }?.relativePath,
                       "old name.mp4", "the path was rewritten by a dry run")
    }

    // MARK: - What it plans

    func testASceneIsPlannedUnderItsMatchedStudio() throws {
        try addStudio("Example Pictures", state: .matched)
        try addActor("Zara Example", gender: "Female")
        try add("clip.mp4", kind: .scene,
                tags: ["studio:Example Pictures", "actor:Zara Example"], released: "2019-04-12")

        let plan = try store.relocationPlan()
        XCTAssertEqual(plan.moves.first?.to,
                       "Example Pictures/Example Pictures - Zara Example - 2019-04-12.mp4")
    }

    /// N1 — a studio earns a folder by being MATCHED. Ruled out goes to the
    /// shared unfiled folder, and anything still in progress stays in the root.
    func testStudioStateDecidesTheFolder() throws {
        try addStudio("Ruled Out Pictures", state: .unmatchable)
        try addStudio("In Progress Pictures", state: .noMatch)
        try add("a.mp4", kind: .scene, tags: ["studio:Ruled Out Pictures"], released: "2019-01-01")
        try add("b.mp4", kind: .scene, tags: ["studio:In Progress Pictures"], released: "2019-01-02")

        let targets = try store.relocationPlan().moves.map(\.to).sorted()
        XCTAssertEqual(targets, ["2019-01-02.mp4", "Unfiled/2019-01-01.mp4"])
    }

    /// Counted, so "nothing to do" is distinguishable from "nothing examined".
    func testAFileAlreadyAtItsTargetIsNotAMove() throws {
        try add("Personal/Beach Trip (2019).mov", kind: .personal,
                episode: "Beach Trip", released: "2019-07-01")
        let plan = try store.relocationPlan()
        XCTAssertTrue(plan.moves.isEmpty)
        XCTAssertEqual(plan.alreadyInPlace, 1)
    }

    // MARK: - 🚨 Collisions, found before the run

    /// Two undated scenes from one studio with the same cast produce one path.
    /// Ordinary, and the answer is to report the pair — never to let one
    /// silently overwrite the other.
    func testTwoVideosWantingOnePathAreReportedAndTheRunIsBlocked() throws {
        try addStudio("Example Pictures", state: .matched)
        try add("first.mp4", kind: .scene, tags: ["studio:Example Pictures"], released: "2019-04-12")
        try add("second.mp4", kind: .scene, tags: ["studio:Example Pictures"], released: "2019-04-12")

        let plan = try store.relocationPlan()
        XCTAssertEqual(plan.collisions.count, 1)
        XCTAssertEqual(plan.collisions.first?.assetIds.count, 2)
        XCTAssertFalse(plan.canRun, "a plan with collisions must not be runnable")
    }

    // MARK: - F7 / F7b — what cannot be filed, and why

    func testUndeclaredAndUnfilableVideosAreReportedWithTheirReason() throws {
        try add("undeclared.mp4", kind: nil)
        try add("no numbers.mp4", kind: .episodic, series: "Harbour Nights")

        let plan = try store.relocationPlan()
        XCTAssertEqual(plan.unfilable.count, 2)
        XCTAssertTrue(plan.unfilable.contains { $0.skip == .undeclared })
        XCTAssertTrue(plan.unfilable.contains { $0.skip == .episodicNeeds("episode number") })
        XCTAssertTrue(plan.moves.isEmpty)
    }

    /// ⭐ The shape the operator actually needs. "90 need an episode number" is
    /// a work list; ninety separate rows is not.
    func testUnfilableVideosAreCountedByReason() throws {
        for n in 1...3 { try add("e\(n).mp4", kind: .episodic, series: "Harbour Nights") }
        try add("u.mp4", kind: nil)

        let byReason = try store.relocationPlan().unfilableByReason
        XCTAssertEqual(byReason.first?.count, 3, "the commonest reason comes first")
        XCTAssertEqual(byReason.map(\.count), [3, 1])
    }

    // MARK: - Cast resolution

    /// ⚠️ Edges AND tag strings. A video the graph has not reached still carries
    /// its cast as `actor:Name`, and filing it from an empty cast would be wrong
    /// rather than merely incomplete.
    func testCastComesFromTagStringsWhenTheGraphHasNotRunYet() throws {
        try addStudio("Example Pictures", state: .matched)
        try addActor("Zara Example", gender: "Female")
        try add("clip.mp4", kind: .scene,
                tags: ["studio:Example Pictures", "actor:Zara Example"], released: "2019-04-12")

        let plan = try store.relocationPlan()
        XCTAssertTrue(plan.moves.first?.to.contains("Zara Example") == true,
                      "a cast held only as tag strings was dropped")
    }

    /// The rank has to survive the round trip through the store, not just the
    /// pure function — gender is read off the profile here, not passed in.
    func testMalePerformersSortLastWhenResolvedFromProfiles() throws {
        try addStudio("Example Pictures", state: .matched)
        try addActor("Adam Example", gender: "Male")
        try addActor("Zara Example", gender: "Female")
        try add("clip.mp4", kind: .scene,
                tags: ["studio:Example Pictures", "actor:Adam Example", "actor:Zara Example"],
                released: "2019-04-12")

        let target = try XCTUnwrap(try store.relocationPlan().moves.first?.to)
        let zara = try XCTUnwrap(target.range(of: "Zara Example"))
        let adam = try XCTUnwrap(target.range(of: "Adam Example"))
        XCTAssertTrue(zara.lowerBound < adam.lowerBound,
                      "male sorted before female: \(target)")
    }

    func testAnEmptyLibraryPlansNothingAndSaysSo() throws {
        let plan = try store.relocationPlan()
        XCTAssertTrue(plan.isEmpty)
        XCTAssertFalse(plan.canRun, "an empty plan is not a runnable one")
    }
}

// MARK: - Readiness — the decision the plan screen shows (#17 step 3)
//
// ⭐ These exist because the first draft of the screen worked this out in the
// view, in a private function no test could reach — the same shape as the
// defect logged on 2026-08-14, where state in a view body was unreachable.
// The wording stays in the view; the reasoning moved here.

extension RelocationPlanTests {

    private func plan(moves: Int = 0, unfilable: [NamingSkip] = [],
                      collisions: Int = 0, inPlace: Int = 0) -> RelocationPlan {
        RelocationPlan(
            moves: (0..<moves).map {
                PlannedMove(assetId: UUID(), from: "a\($0).mp4", to: "b\($0).mp4", title: "T\($0)")
            },
            alreadyInPlace: inPlace,
            unfilable: unfilable.map {
                UnfilableVideo(assetId: UUID(), path: "x.mp4", title: "X", skip: $0)
            },
            collisions: (0..<collisions).map {
                PathCollision(target: "clash\($0).mp4", assetIds: [UUID(), UUID()],
                              titles: ["One", "Two"])
            })
    }

    func testAPlanWithMovesAndNoCollisionsIsReady() {
        XCTAssertEqual(plan(moves: 3).readiness, .ready(moves: 3))
    }

    /// 🚨 A collision blocks even when files could otherwise move. Reporting
    /// the movable count here would read as permission to run.
    func testACollisionBlocksEvenWhenThereAreMovableFiles() {
        XCTAssertEqual(plan(moves: 5, collisions: 1).readiness, .blocked(collisions: 1))
    }

    func testAPlanWithNothingLeftToDoSaysSo() {
        XCTAssertEqual(plan(inPlace: 12).readiness, .nothingToDo)
    }

    /// The state of a library nobody has declared: no collisions, no moves,
    /// and everything waiting. Distinct from "nothing to do", which would
    /// wrongly tell the operator they were finished.
    func testAPlanWhereEverythingIsWaitingIsNotMistakenForNothingToDo() {
        let waiting = plan(unfilable: [.undeclared, .undeclared, .noUsableName])
        XCTAssertEqual(waiting.readiness, .allWaiting(count: 3))
        XCTAssertNotEqual(waiting.readiness, .nothingToDo)
    }

    /// ⭐ The one reason answered in bulk, counted separately so the screen can
    /// name it rather than leaving the operator to read a table.
    func testUndeclaredIsCountedApartFromEveryOtherReason() {
        let mixed = plan(unfilable: [.undeclared, .undeclared,
                                     .episodicNeeds("episode number"), .noUsableName])
        XCTAssertEqual(mixed.undeclaredCount, 2)
        XCTAssertEqual(mixed.unfilable.count, 4)
    }

    func testUndeclaredCountIsZeroWhenNothingIsUndeclared() {
        XCTAssertEqual(plan(unfilable: [.noUsableName]).undeclaredCount, 0)
    }
}
