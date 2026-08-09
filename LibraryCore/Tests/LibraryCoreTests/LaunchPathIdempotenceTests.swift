// LaunchPathIdempotenceTests.swift
// Every operation the app runs repeatedly, run twice on a RE-KEYED library.
//
// 🚨 The gap this closes. All four "Connect the Graph" steps already had a
// runs-twice test, and every one of them ran on a LEGACY library — so did the
// backfill's. `promoteStudioProfiles` had one too, and it passed, and the
// operation still tripled 469 studios on the drive. Idempotence is not a
// property of an operation; it is a property of an operation *against a
// particular shape of data*, and the re-key changed the shape underneath all
// of them at once.
//
// ⭐ Each test asserts EFFECTIVENESS before idempotence, and that ordering is
// the whole design. "Running it twice changes nothing" is satisfied perfectly
// by an operation that does nothing at all — which is exactly how both graph
// audits came to report a clean library while seeing none of it. A test that
// only checks the second run cannot tell the two apart.
//
// ⚠️ These use the REAL `performIdentityRekey()` rather than a hand-set flag.
// The point is to exercise the state the migration actually produces, uids and
// re-pointed edges included, not a fixture's idea of it.

import XCTest
import GRDB
@testable import LibraryCore

final class LaunchPathIdempotenceTests: XCTestCase {

    private var url: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchPath-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store = try LibraryStore(at: url)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Fixtures

    @discardableResult
    private func video(_ tags: [String]) throws -> UUID {
        let asset = Asset(relativePath: "\(UUID()).mp4", fileName: "a.mp4", tags: tags)
        try store.insertAsset(asset)
        return asset.id
    }

    private func profile(_ id: String, tags: [String] = []) throws {
        var p = EntityProfile(id: id)
        p.tags = tags
        try store.saveEntityProfile(p)
    }

    private func tag(_ name: String, _ kind: TagKind?) throws {
        try store.saveTagRecord(TagRecord(displayName: name, kind: kind))
    }

    private var profileCount: Int {
        get throws { try store.fetchAllEntityProfiles().count }
    }

    /// Every edge table at once, so a test can assert that a whole re-run moved
    /// nothing rather than checking the one table it happened to think of.
    private func allEdgeCounts() throws -> [GraphEdgeKind: Int] {
        var counts: [GraphEdgeKind: Int] = [:]
        for kind in GraphEdgeKind.allCases { counts[kind] = try store.edgeCount(kind) }
        return counts
    }

    /// A small library with one of everything, already connected and re-keyed —
    /// the state the drive is in and the phone is about to be.
    private func seedAndRekey() throws {
        try profile("actor:Alice Example")
        try profile("actor:Bob Example")
        try profile("studio:Silver River")
        try tag("Climbing", .action)

        try video(["actor:Alice Example", "studio:Silver River", "tag:Climbing"])
        try video(["actor:Bob Example", "studio:Silver River"])

        try store.connectPerformerEdges()
        try store.connectStudioEdges()
        try store.connectTagEdges()

        _ = try store.performIdentityRekey()
        XCTAssertTrue(try store.isRekeyed(), "the fixture must actually be re-keyed")
    }

    // MARK: - 🚨 The four Connect the Graph steps

    /// L1 — performer edges. The first run must have BUILT the edges before
    /// "the second run adds nothing" means anything.
    func testConnectingPerformerEdgesTwiceOnARekeyedLibraryAddsNothing() throws {
        try profile("actor:Alice Example")
        try video(["actor:Alice Example"])
        _ = try store.performIdentityRekey()

        let first = try store.connectPerformerEdges()
        XCTAssertEqual(try store.edgeCount(.videoPerformer), 1,
                       "effectiveness: a uid-keyed performer must still connect")
        XCTAssertGreaterThan(first.connectable, 0)

        let second = try store.connectPerformerEdges()
        XCTAssertEqual(second.connectable, 0, "nothing left to do")
        XCTAssertEqual(try store.edgeCount(.videoPerformer), 1, "no duplicate edge")
    }

    /// L2 — studio edges.
    func testConnectingStudioEdgesTwiceOnARekeyedLibraryAddsNothing() throws {
        try profile("studio:Silver River")
        try video(["studio:Silver River"])
        _ = try store.performIdentityRekey()

        try store.connectStudioEdges()
        XCTAssertEqual(try store.edgeCount(.videoStudio), 1, "effectiveness")

        try store.connectStudioEdges()
        XCTAssertEqual(try store.edgeCount(.videoStudio), 1)
    }

    /// L3 — tag edges. ⚠️ Tags keep their `tag:Name` strings permanently, so
    /// this one must survive the re-key by NOT changing — the opposite risk
    /// from the others, and just as easy to get wrong.
    func testConnectingTagEdgesTwiceOnARekeyedLibraryAddsNothing() throws {
        try tag("Climbing", .action)
        try video(["tag:Climbing"])
        _ = try store.performIdentityRekey()

        try store.connectTagEdges()
        XCTAssertEqual(try store.edgeCount(.videoTag), 1, "effectiveness")

        try store.connectTagEdges()
        XCTAssertEqual(try store.edgeCount(.videoTag), 1)
    }

    /// L4 — the match backfill, which the Connect screen calls straight after
    /// the three connects and describes in a comment as idempotent.
    func testBackfillingMatchEdgesTwiceOnARekeyedLibraryAddsNothing() throws {
        var p = EntityProfile(id: "actor:Alice Example")
        p.enrichmentSource = "A Source"
        p.enrichmentSourceId = "a-1"
        p.enrichmentState = .matched
        try store.saveEntityProfile(p)
        try video(["actor:Alice Example"])
        _ = try store.performIdentityRekey()

        let first = try store.backfillMatchEdges()
        XCTAssertGreaterThan(first.entities, 0,
                             "effectiveness: a uid-keyed profile's identity must backfill")
        let after = try store.edgeCount(.videoPerformer)

        let second = try store.backfillMatchEdges()
        XCTAssertEqual(second.entities, 0, "the identity is already recorded")
        XCTAssertEqual(second.videos, 0)
        XCTAssertEqual(try store.edgeCount(.videoPerformer), after)
    }

    // MARK: - 🚨 The whole sequence, the way the app runs it

    /// L5 — the launch path end to end, three times over. This is the shape of
    /// the defect that reached the drive: each individual step looked fine and
    /// the library grew on every launch.
    func testThreeFullLaunchesChangeNothingAfterTheFirst() throws {
        try seedAndRekey()

        let profilesAfterSetup = try profileCount
        let edgesAfterSetup = try allEdgeCounts()
        XCTAssertGreaterThan(profilesAfterSetup, 0)
        XCTAssertGreaterThan(edgesAfterSetup[.videoPerformer] ?? 0, 0,
                             "effectiveness: the fixture is genuinely connected")

        for launch in 1...3 {
            _ = try? store.promoteStudioProfiles()
            try store.connectPerformerEdges()
            try store.connectStudioEdges()
            try store.connectTagEdges()
            _ = try store.backfillMatchEdges()

            XCTAssertEqual(try profileCount, profilesAfterSetup,
                           "launch \(launch) minted a profile")
            XCTAssertEqual(try allEdgeCounts(), edgesAfterSetup,
                           "launch \(launch) moved an edge count")
        }
    }

    /// L6 — ⚠️ and the sequence still PICKS UP genuinely new work afterwards.
    /// The cheapest way to pass every test above is to make each operation a
    /// no-op on a re-keyed library, which is precisely the bug that blinded the
    /// orphan audit. This is the test that rejects that fix.
    func testTheLaunchPathStillPicksUpSomethingNewAfterTheRekey() throws {
        try seedAndRekey()
        let before = try profileCount

        try profile("actor:Carol Example")
        try video(["actor:Carol Example", "studio:Brand New Studio", "tag:Climbing"])

        _ = try store.promoteStudioProfiles()
        try store.connectPerformerEdges()
        try store.connectStudioEdges()
        try store.connectTagEdges()

        XCTAssertEqual(try profileCount, before + 2,
                       "the new actor's row plus a promoted studio")
        XCTAssertNotNil(try store.fetchEntityProfile(named: "Brand New Studio", type: "studio"))
        XCTAssertEqual(try store.edgeCount(.videoPerformer), 3)
    }

    // MARK: - 🚨 The audits, which run on the same path and must SEE something

    /// L7 — the orphan audit is repeatable AND non-blind. It reported a clean
    /// library on the drive because every uid failed a `hasPrefix` test, and
    /// "clean twice in a row" was indistinguishable from "clean".
    func testTheOrphanAuditIsRepeatableAndNotBlindAfterTheRekey() throws {
        try seedAndRekey()
        // Someone nothing refers to, added after the graph was connected.
        try store.saveEntityProfile(EntityProfile(id: UUID().uuidString,
                                                  entityType: "actor",
                                                  displayName: "Nobody Refers To Me"))

        let first = try store.auditOrphans()
        XCTAssertEqual(first[.actor]?.map(\.displayName), ["Nobody Refers To Me"],
                       "effectiveness: the audit must see a uid-keyed orphan")

        let second = try store.auditOrphans()
        XCTAssertEqual(first, second, "an audit is a read; twice is the same answer")
    }

    /// L8 — ⚠️ and it does NOT report the connected cast. Reading this audit as
    /// a worklist and acting on it deletes profiles, so a false positive here
    /// costs real data.
    func testTheOrphanAuditDoesNotReportConnectedNodesAfterTheRekey() throws {
        try seedAndRekey()

        let found = try store.auditOrphans()

        XCTAssertTrue(found.values.allSatisfy(\.isEmpty) || found.isEmpty,
                      "everything in this library is referred to by a video")
    }

    /// L8b — 🚨 the case L8 alone does NOT cover, and the one that would have
    /// cost data.
    ///
    /// Every node in `seedAndRekey` has an EDGE, and the edge check rescues it
    /// before the string check is ever consulted — so L8 passes even with the
    /// reference test comparing a uid against `actor:Name`. Found by mutation:
    /// breaking exactly that comparison left all nine tests in this file green.
    ///
    /// A performer named on a video that was never connected has a string and
    /// no edge, which is the ONLY thing standing between them and the delete
    /// button. That is not a rare state — it is every library before Connect
    /// the Graph is run, and every video imported since.
    func testANodeWithAStringAndNoEdgeIsNotAnOrphanAfterTheRekey() throws {
        try profile("actor:Alice Example")
        try video(["actor:Alice Example"])
        _ = try store.performIdentityRekey()
        // ⚠️ Deliberately NOT connected — no `connectPerformerEdges`.
        XCTAssertEqual(try store.edgeCount(.videoPerformer), 0, "no edge to hide behind")

        let found = try store.auditOrphans()

        XCTAssertTrue(found[.actor]?.isEmpty ?? true,
                      "a video names her by string; deleting her would lose the profile")
    }

    /// L9 — the identity-gap worklist, same two properties.
    func testTheIdentityGapReportIsRepeatableAfterTheRekey() throws {
        try seedAndRekey()
        var p = EntityProfile(id: UUID().uuidString, entityType: "actor",
                              displayName: "Claims A Match")
        p.enrichmentState = .matched
        try store.saveEntityProfile(p)

        let first = try store.identityGaps()
        XCTAssertEqual(first.gaps.map(\.displayName), ["Claims A Match"],
                       "effectiveness: a uid-keyed gap must still be reported")

        let second = try store.identityGaps()
        XCTAssertEqual(first.gaps, second.gaps)
    }
}
