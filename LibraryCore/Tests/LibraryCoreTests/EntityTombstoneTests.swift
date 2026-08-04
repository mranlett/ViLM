import XCTest
@testable import LibraryCore

/// Deletions must survive a sync.
///
/// Sync unions what each library holds, so without a record of removal an
/// absence is indistinguishable from a deliberate deletion — and the union
/// always resurrects. Deleting in both places by hand does not work either:
/// whichever library you delete from second gets the record copied back.
final class EntityTombstoneTests: XCTestCase {

    private var root: URL!
    private var libA: URL!
    private var libB: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tombstone-\(UUID().uuidString)")
        libA = root.appendingPathComponent("A")
        libB = root.appendingPathComponent("B")
        for url in [libA!, libB!] {
            try FileManager.default.createDirectory(
                at: url.appendingPathComponent(".catalog/profiles"),
                withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - The rule

    func testDeletionPropagatesToAnOlderCopy() {
        let stone = EntityTombstone(entityId: "actor:helen",
                                    deletedAt: Date(timeIntervalSince1970: 2000))
        var older = EntityProfile(id: "actor:helen")
        older.createdAt = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(TombstoneRules.shouldPropagate(tombstone: stone, to: older))
    }

    /// Re-creating an actor you once removed must stick. Undoing that on the
    /// next sync would be worse than the resurrection tombstones prevent.
    func testDeliberateRecreationOutranksTheTombstone() {
        let stone = EntityTombstone(entityId: "actor:helen",
                                    deletedAt: Date(timeIntervalSince1970: 1000))
        var newer = EntityProfile(id: "actor:helen")
        newer.createdAt = Date(timeIntervalSince1970: 2000)
        XCTAssertFalse(TombstoneRules.shouldPropagate(tombstone: stone, to: newer))
    }

    func testNothingToDeleteIsNotAPropagation() {
        let stone = EntityTombstone(entityId: "actor:helen")
        XCTAssertFalse(TombstoneRules.shouldPropagate(tombstone: stone, to: nil))
    }

    // MARK: - End to end

    /// The Helen B case: deleted in one library, still present in the other.
    func testDeletingInOneLibraryRemovesTheActorFromBoth() throws {
        let actorId = "actor:helen"
        var profile = EntityProfile(id: actorId)
        profile.createdAt = Date(timeIntervalSince1970: 1000)
        profile.bio = "stale record"

        let storeA = try LibraryStore(at: libA)
        let storeB = try LibraryStore(at: libB)
        try storeA.saveEntityProfile(profile)
        try storeB.saveEntityProfile(profile)

        // Removed in A only.
        try storeA.deleteEntityProfile(for: actorId)
        XCTAssertNil(try storeA.fetchEntityProfile(for: actorId))
        XCTAssertNotNil(try storeB.fetchEntityProfile(for: actorId), "B still holds it")

        let snaps = [try ActorSync.snapshot(of: libA), try ActorSync.snapshot(of: libB)]
        let plans = ActorSync.plan(for: snaps)

        let plan = try XCTUnwrap(plans.first { $0.actorId == actorId })
        XCTAssertEqual(plan.deletionFrom, [libB], "the plan proposes removing it from B")
        XCTAssertTrue(plan.diagnosis().contains("DELETED"))

        let export = ActorSync.convergedExport(actorIds: [actorId], resolutions: [:], snapshots: snaps)
        try ActorSync.apply(export, to: libA)
        try ActorSync.apply(export, to: libB)

        XCTAssertNil(try storeB.fetchEntityProfile(for: actorId), "deletion reached B")
        XCTAssertTrue(ActorSync.plan(for: [try ActorSync.snapshot(of: libA),
                                           try ActorSync.snapshot(of: libB)]).isEmpty,
                      "and the libraries have converged")
    }

    /// Without a tombstone this is exactly the resurrection being fixed, so it
    /// is worth pinning that a plain absence still copies.
    func testAbsenceWithoutATombstoneStillCopies() throws {
        let actorId = "actor:new"
        let storeA = try LibraryStore(at: libA)
        try storeA.saveEntityProfile(EntityProfile(id: actorId, bio: "real"))

        let snaps = [try ActorSync.snapshot(of: libA), try ActorSync.snapshot(of: libB)]
        let plan = try XCTUnwrap(ActorSync.plan(for: snaps).first { $0.actorId == actorId })
        XCTAssertEqual(plan.missingFrom, [libB])
        XCTAssertTrue(plan.deletionFrom.isEmpty)
    }

    /// A rename is a removal of the old id. Without recording it, accepting a
    /// canonical name leaves the previous name alive in every other library and
    /// the next sync brings it back — the actor then exists under both names.
    func testRenameRecordsATombstoneForTheOldId() throws {
        let store = try LibraryStore(at: libA)
        try store.saveEntityProfile(EntityProfile(id: "actor:Helen B", bio: "before"))

        try store.renameTagGlobally(oldTag: "actor:Helen B", newTag: "actor:Helen Bright")

        let stones = try store.fetchTombstones()
        let stone = try XCTUnwrap(stones.first { $0.entityId == "actor:Helen B" })
        XCTAssertEqual(stone.replacedBy, "actor:Helen Bright")
        XCTAssertNil(try store.fetchEntityProfile(for: "actor:Helen B"))
        XCTAssertNotNil(try store.fetchEntityProfile(for: "actor:Helen Bright"))
    }

    /// An export written before v20 has no tombstone field. It must decode as
    /// "no deletions known" — never as "everything was deleted".
    func testOlderExportsDecodeWithNoDeletions() throws {
        let json = """
        {"formatVersion":1,"exportedAt":0,"profiles":[],"photos":[]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ActorLibraryExport.self, from: json)
        XCTAssertTrue(decoded.tombstones.isEmpty)
    }
}
