// PerformIdentityRekeyTests.swift
// The public driver: the four phases, in the one order that is safe.

import XCTest
import GRDB
@testable import LibraryCore

final class PerformIdentityRekeyTests: XCTestCase {

    private var url: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Rekey-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store = try LibraryStore(at: url)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    private func video(_ tags: [String]) throws -> UUID {
        let asset = Asset(relativePath: "v-\(UUID().uuidString).mp4",
                          fileName: "v.mp4", tags: tags)
        try store.insertAsset(asset)
        return asset.id
    }

    /// A small but complete library: a cast edge, a studio edge, a hierarchy
    /// row and a match edge — one of each thing the commit must re-point.
    private func seed() throws -> (video: UUID, actor: String, studio: String) {
        try store.saveEntityProfile(EntityProfile(id: "actor:Marta Venlowe"))
        try store.saveEntityProfile(EntityProfile(id: "studio:Silver River"))
        try store.saveEntityProfile(EntityProfile(id: "studio:Silver Network"))
        let videoId = try video(["actor:Marta Venlowe", "studio:Silver River"])
        try store.linkPerformer("actor:Marta Venlowe", toVideo: videoId)
        try store.setStudio("studio:Silver River", forVideo: videoId)
        try store.setStudioParent("studio:Silver Network", forStudio: "studio:Silver River")
        try store.recordMatch(NodeMatch(nodeId: "actor:Marta Venlowe", source: "A Source",
                                        sourceId: "s-1", method: .operator),
                              isVideo: false)
        return (videoId, "actor:Marta Venlowe", "studio:Silver River")
    }

    // MARK: - The happy path

    // P1 — every node is re-keyed and NOTHING is lost.
    func testTheLibraryComesOutReKeyedWithEveryEdgeIntact() throws {
        let seeded = try seed()

        let result = try store.performIdentityRekey()

        XCTAssertEqual(result.nodesRekeyed, 3)
        XCTAssertTrue(try store.isRekeyed())

        // Names still resolve, and now to uids.
        let actor = try XCTUnwrap(try store.fetchEntityProfile(named: "Marta Venlowe",
                                                               type: "actor"))
        XCTAssertNil(NodeIdentity.parse(actor.id), "the key is opaque now")
        XCTAssertEqual(actor.name, "Marta Venlowe")

        // Every edge followed.
        XCTAssertEqual(try store.performerIds(forVideo: seeded.video), [actor.id])
        let studio = try XCTUnwrap(try store.fetchEntityProfile(named: "Silver River",
                                                                type: "studio"))
        XCTAssertEqual(try store.studioId(forVideo: seeded.video), studio.id)
        XCTAssertEqual(try store.parentStudioId(of: studio.id),
                       try store.entityId(named: "Silver Network", type: "studio"))
        XCTAssertEqual(try store.matches(forEntity: actor.id).first?.sourceId, "s-1")
    }

    // P2 — ⚠️ the tag STRINGS on the video are untouched. They are a different
    // namespace, and the read path unions them with the edges.
    func testTheTagStringsOnVideosAreNotRewritten() throws {
        let seeded = try seed()

        _ = try store.performIdentityRekey()

        let asset = try XCTUnwrap(try store.fetchAllAssets().first { $0.id == seeded.video })
        XCTAssertEqual(asset.actors, ["Marta Venlowe"])
        XCTAssertEqual(asset.studios, ["Silver River"])
    }

    // P3 — running it twice is not an error. An operator making sure is not a
    // failure state.
    func testRunningItTwiceIsAZeroResultRatherThanAnError() throws {
        try seed()

        let first = try store.performIdentityRekey()
        let second = try store.performIdentityRekey()

        XCTAssertEqual(first.nodesRekeyed, 3)
        XCTAssertEqual(second.nodesRekeyed, 0)
        XCTAssertTrue(try store.isRekeyed())
    }

    // MARK: - 🚨 The gate is the last thing that happens

    // P4 — the pre-flight is re-run inside the operation, so a blocker that
    // appeared AFTER the operator read the verdict still stops it. A duplicate
    // (type, name) is the one the screen most plausibly misses: a match run
    // can create one while the sheet is open.
    func testABlockerAppearingAfterTheVerdictStillStopsIt() throws {
        try seed()
        // Two studios sharing a display name — created after the screen's read.
        try store.saveEntityProfile(EntityProfile(id: UUID().uuidString,
                                                  entityType: "studio",
                                                  displayName: "Silver River"))

        XCTAssertThrowsError(try store.performIdentityRekey()) { error in
            guard case RekeyError.preflightFailed(let blockers) = error else {
                return XCTFail("expected the gate to refuse, got \(error)")
            }
            // ⚠️ Asserts WHICH blocker. A non-empty list would also be
            // satisfied by the gate refusing for an unrelated reason, which
            // would leave the duplicate check itself untested.
            XCTAssertEqual(blockers.count, 1, "only the duplicate name blocks it")
            XCTAssertTrue(
                blockers[0].contains("claimed by more than one record"),
                "expected the duplicate-identity blocker, got \(blockers)")
        }
        XCTAssertFalse(try store.isRekeyed(), "nothing may have happened")
    }

    // P5 — and a refusal leaves the library EXACTLY as it was. Not partly
    // minted, not partly copied.
    func testARefusalLeavesTheLibraryUntouched() throws {
        let seeded = try seed()
        try store.saveEntityProfile(EntityProfile(id: UUID().uuidString,
                                                  entityType: "studio",
                                                  displayName: "Silver River"))

        _ = try? store.performIdentityRekey()

        XCTAssertNotNil(try store.fetchEntityProfile(for: "actor:Marta Venlowe"),
                        "the legacy key must still be the key")
        XCTAssertEqual(try store.performerIds(forVideo: seeded.video),
                       ["actor:Marta Venlowe"])
        let uidsMinted = try store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entity_profiles WHERE uid IS NOT NULL")
        }
        XCTAssertEqual(uidsMinted, 0, "not even the additive mint may have run")

        // 🚨 The EDGE tables too. Checking `entity_profiles` alone would miss a
        // half-applied re-point — the commit touches six join tables, and a
        // rollback that covered only the profile row would leave the graph
        // pointing at uids that no profile carries.
        XCTAssertEqual(try store.studioId(forVideo: seeded.video), seeded.studio)
        XCTAssertEqual(try store.parentStudioId(of: "studio:Silver River"),
                       "studio:Silver Network")
        XCTAssertEqual(try store.matches(forEntity: "actor:Marta Venlowe").first?.sourceId,
                       "s-1")
        let strayEndpoints = try store.dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM video_performer
                 WHERE performer_id NOT IN (SELECT id FROM entity_profiles)
                """)
        }
        XCTAssertEqual(strayEndpoints, 0, "no edge may point at a node that is not there")
    }

    // MARK: - Photos

    // P6 — photos follow their node, and the old names are cleaned up.
    func testPhotosAreMovedToTheUidNameAndTheOldOnesRemoved() throws {
        try seed()
        let dir = url.appendingPathComponent(".catalog/profiles")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = dir.appendingPathComponent("actor_Marta Venlowe.jpg")
        try Data("photo".utf8).write(to: old)

        let result = try store.performIdentityRekey()

        XCTAssertEqual(result.photosCopied, 1)
        XCTAssertEqual(result.photosDeleted, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))

        let actor = try XCTUnwrap(try store.fetchEntityProfile(named: "Marta Venlowe",
                                                               type: "actor"))
        let expected = dir.appendingPathComponent(ProfileImageNaming.primaryFileName(for: actor.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path),
                      "the photo must be reachable under the new key")
    }

    // MARK: - After it, the app still works

    // P7 — ⭐ the whole point. Every lookup the app makes by NAME keeps working.
    func testTheAppsNameLookupsAllStillResolve() throws {
        try seed()

        _ = try store.performIdentityRekey()

        XCTAssertNotNil(try store.fetchEntityProfile(named: "Marta Venlowe", type: "actor"))
        XCTAssertNotNil(try store.entityId(named: "Silver River", type: "studio"))
        let index = EntityProfileIndex(try store.fetchAllEntityProfiles())
        XCTAssertNotNil(index[actor: "Marta Venlowe"])
        XCTAssertNotNil(index[studio: "Silver River"])
        XCTAssertEqual(index.actors.count, 1)
        // And the federation boundary resolves a LEGACY id to the new local one.
        let resolver = NodeResolver(profiles: try store.fetchAllEntityProfiles())
        XCTAssertEqual(resolver.localId(for: "actor:Marta Venlowe"),
                       index[actor: "Marta Venlowe"]?.id)
    }
}
