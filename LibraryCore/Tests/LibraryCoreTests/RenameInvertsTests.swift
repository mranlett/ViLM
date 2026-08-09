// RenameInvertsTests.swift
// What a rename does BEFORE and AFTER the re-key — they are opposites.
//
// 🚨 Today a rename changes the id, so the profile row moves to a new key,
// every edge is re-pointed, the photo files are renamed and a tombstone
// records that the old id is gone. All of that is bookkeeping for a key that
// happens to contain a name.
//
// ⭐ Once the id is an opaque uid the node does not move. A pure rename is one
// column — `display_name` — plus the tag strings on the videos. Re-pointing
// edges would be pointless; renaming photos would be actively wrong.

import XCTest
import GRDB
@testable import LibraryCore

final class RenameInvertsTests: XCTestCase {

    private var url: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenameInverts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store = try LibraryStore(at: url)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: url)
    }

    /// Puts the library in the state `rekeyCommit` leaves: uid minted AND
    /// adopted as the key.
    private func markRekeyed() throws {
        let uid = UUID().uuidString
        try store.saveEntityProfile(EntityProfile(id: uid, entityType: "actor",
                                                  displayName: "Sentinel"))
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE entity_profiles SET uid = id WHERE id = ?",
                           arguments: [uid])
        }
    }

    @discardableResult
    private func video(_ tags: [String]) throws -> UUID {
        let asset = Asset(relativePath: "v-\(UUID().uuidString).mp4",
                          fileName: "v.mp4", tags: tags)
        try store.insertAsset(asset)
        return asset.id
    }

    // MARK: - After the re-key: the node stays put

    // R1 — ⭐ the inversion itself. The id is untouched and only the name moves.
    func testARenameAfterTheRekeyKeepsTheIdAndMovesOnlyTheName() throws {
        try markRekeyed()
        let uid = UUID().uuidString
        try store.saveEntityProfile(EntityProfile(id: uid, entityType: "actor",
                                                  displayName: "Old Name", bio: "kept"))

        _ = try store.renameTagGlobally(oldTag: "actor:Old Name", newTag: "actor:New Name")

        let moved = try XCTUnwrap(try store.fetchEntityProfile(for: uid))
        XCTAssertEqual(moved.name, "New Name")
        XCTAssertEqual(moved.bio, "kept")
        XCTAssertNil(try store.fetchEntityProfile(named: "Old Name", type: "actor"))
    }

    // R2 — 🚨 the edges are NOT touched, and survive. Under the old behaviour
    // the re-point would match no rows (the endpoints are uids, the search
    // string is a name) and the DELETE that follows would then destroy them.
    func testARenameAfterTheRekeyLeavesEveryEdgeIntact() throws {
        try markRekeyed()
        let uid = UUID().uuidString
        try store.saveEntityProfile(EntityProfile(id: uid, entityType: "actor",
                                                  displayName: "Old Name"))
        let videoId = try video(["actor:Old Name"])
        try store.linkPerformer(uid, toVideo: videoId)

        _ = try store.renameTagGlobally(oldTag: "actor:Old Name", newTag: "actor:New Name")

        XCTAssertEqual(try store.performerIds(forVideo: videoId), [uid],
                       "the cast edge must still point at the same node")
    }

    // R3 — and no tombstone, because nothing was removed. A tombstone here
    // would tell every other library the node is gone and have the next sync
    // delete it.
    func testARenameAfterTheRekeyRecordsNoTombstone() throws {
        try markRekeyed()
        try store.saveEntityProfile(EntityProfile(id: UUID().uuidString, entityType: "actor",
                                                  displayName: "Old Name"))

        _ = try store.renameTagGlobally(oldTag: "actor:Old Name", newTag: "actor:New Name")

        XCTAssertTrue(try store.fetchTombstones().isEmpty)
    }

    // R4 — the tag strings on videos DO still change. That namespace is not
    // re-keyed, and it is what the grid reads.
    func testTheTagStringsStillFollowTheRename() throws {
        try markRekeyed()
        try store.saveEntityProfile(EntityProfile(id: UUID().uuidString, entityType: "actor",
                                                  displayName: "Old Name"))
        let videoId = try video(["actor:Old Name"])

        _ = try store.renameTagGlobally(oldTag: "actor:Old Name", newTag: "actor:New Name")

        let asset = try XCTUnwrap(try store.fetchAllAssets().first { $0.id == videoId })
        XCTAssertEqual(asset.actors, ["New Name"])
    }

    // MARK: - A MERGE still moves everything, in both eras

    // R5 — two distinct nodes becoming one genuinely does re-point edges and
    // delete the loser, uid-keyed or not.
    func testAMergeAfterTheRekeyStillMovesTheEdgesAndDeletesTheLoser() throws {
        try markRekeyed()
        let loser = UUID().uuidString, keeper = UUID().uuidString
        try store.saveEntityProfile(EntityProfile(id: loser, entityType: "actor",
                                                  displayName: "Alias Spelling"))
        try store.saveEntityProfile(EntityProfile(id: keeper, entityType: "actor",
                                                  displayName: "Canonical Name"))
        let videoId = try video(["actor:Alias Spelling"])
        try store.linkPerformer(loser, toVideo: videoId)

        _ = try store.renameTagGlobally(oldTag: "actor:Alias Spelling",
                                        newTag: "actor:Canonical Name")

        XCTAssertEqual(try store.performerIds(forVideo: videoId), [keeper],
                       "the edge must move to the surviving node")
        XCTAssertNil(try store.fetchEntityProfile(for: loser))
        XCTAssertNotNil(try store.fetchEntityProfile(for: keeper))
    }

    // R7 — ⚠️ a CASE-ONLY repair after the re-key resolves both ends to the
    // same node. That must be a rename, not a merge — treating it as a merge
    // would delete the node into itself.
    func testACaseOnlyRepairAfterTheRekeyIsARenameNotAMerge() throws {
        try markRekeyed()
        let uid = UUID().uuidString
        try store.saveEntityProfile(EntityProfile(id: uid, entityType: "tag",
                                                  displayName: "scuba"))
        let videoId = try video(["tag:scuba"])

        _ = try store.renameTagGlobally(oldTag: "tag:scuba", newTag: "tag:SCUBA")

        XCTAssertNotNil(try store.fetchEntityProfile(for: uid),
                        "the node must survive being renamed to itself")
        XCTAssertEqual(try store.fetchEntityProfile(for: uid)?.name, "SCUBA")
        let asset = try XCTUnwrap(try store.fetchAllAssets().first { $0.id == videoId })
        XCTAssertEqual(asset.actions, ["SCUBA"])
    }

    // R8 — ⚠️ an unparseable new name leaves the profile alone, and says so.
    // Claiming `profileMoved` would report a success that did not happen.
    func testAnUnparseableNewNameDoesNotClaimTheProfileMoved() throws {
        try markRekeyed()
        try store.saveEntityProfile(EntityProfile(id: UUID().uuidString, entityType: "actor",
                                                  displayName: "Old Name"))

        let outcome = try store.renameTagGlobally(oldTag: "actor:Old Name",
                                                  newTag: "no colon at all")

        XCTAssertFalse(outcome.profileMoved)
        XCTAssertNotNil(try store.fetchEntityProfile(named: "Old Name", type: "actor"))
    }

    // MARK: - The defensive branches

    // ⚠️ An empty name is refused. After the re-key the name is the only
    // record of what a node is called, so blanking it is unrecoverable.
    func testRenamingInPlaceToAnEmptyNameIsRefused() {
        let profile = EntityProfile(id: UUID().uuidString, entityType: "actor",
                                    displayName: "Marta Venlowe")

        XCTAssertEqual(profile.renamedInPlace(to: "").name, "Marta Venlowe")
        XCTAssertEqual(profile.renamedInPlace(to: "Other").name, "Other")
    }

    // ⚠️ A tag with no profile row still renames its strings. Most tags have
    // no `entity_profiles` row at all, so this is the ordinary case.
    func testATagWithNoProfileRowStillRenamesItsStrings() throws {
        try markRekeyed()
        let videoId = try video(["tag:Outdoors"])

        let outcome = try store.renameTagGlobally(oldTag: "tag:Outdoors",
                                                  newTag: "tag:Outdoor")

        XCTAssertEqual(outcome.videosChanged, 1)
        XCTAssertFalse(outcome.profileMoved, "there was no profile to move")
        let asset = try XCTUnwrap(try store.fetchAllAssets().first { $0.id == videoId })
        XCTAssertEqual(asset.actions, ["Outdoor"])
    }

    // ⚠️ The second lookup in the chain: the caller's spelling misses, and the
    // NORMALIZED one finds the row. Without it a repair whose stored spelling
    // is already canonical would silently skip the profile.
    func testTheNormalizedSpellingIsTriedWhenTheCallersMisses() throws {
        try markRekeyed()
        let uid = UUID().uuidString
        // Stored canonically; the caller asks with a lower-case spelling.
        try store.saveEntityProfile(EntityProfile(id: uid, entityType: "actor",
                                                  displayName: "Marta Venlowe"))

        _ = try store.renameTagGlobally(oldTag: "actor:marta venlowe",
                                        newTag: "actor:Marta V")

        XCTAssertEqual(try store.fetchEntityProfile(for: uid)?.name, "Marta V",
                       "the normalized spelling is what matched the stored row")
    }

    // MARK: - 🚨 The no-op assertion

    // R6 — before the re-key, everything behaves exactly as it always did:
    // the key moves, and the edges move with it.
    func testBeforeTheRekeyTheIdStillMoves() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Old Name"))
        let videoId = try video(["actor:Old Name"])
        try store.linkPerformer("actor:Old Name", toVideo: videoId)

        _ = try store.renameTagGlobally(oldTag: "actor:Old Name", newTag: "actor:New Name")

        XCTAssertNil(try store.fetchEntityProfile(for: "actor:Old Name"))
        XCTAssertNotNil(try store.fetchEntityProfile(for: "actor:New Name"))
        XCTAssertEqual(try store.performerIds(forVideo: videoId), ["actor:New Name"])
        XCTAssertFalse(try store.fetchTombstones().isEmpty,
                       "the old id really is gone, so other libraries must be told")
    }
}
