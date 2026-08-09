// IdentityRekeyTests.swift
// The irreversible step, and the properties that make it survivable.
//
// ⭐ These map to the spec's own V-numbers. The ones worth reading first are V6
// (interruption is safe at every phase) and V10 (re-pointing never merges two
// nodes) — the two failures that would be silent and unrecoverable.

import XCTest
import GRDB
@testable import LibraryCore

final class IdentityRekeyTests: XCTestCase {

    private var url: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Rekey-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store = try LibraryStore(at: url)
        try FileManager.default.createDirectory(at: store.profilesDirectory,
                                                withIntermediateDirectories: true)
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

    private func photo(_ name: String, _ contents: String = "bytes") throws {
        try Data(contents.utf8).write(
            to: store.profilesDirectory.appendingPathComponent(name))
    }

    private func fileExists(_ name: String) -> Bool {
        FileManager.default.fileExists(
            atPath: store.profilesDirectory.appendingPathComponent(name).path)
    }

    /// Runs all four phases in order.
    @discardableResult
    private func runFullRekey() throws -> (RekeyPlan, RekeyResult) {
        let plan = try store.rekeyPlan()
        try store.rekeyMintUids(plan)
        _ = try store.rekeyCopyPhotos(plan)
        try store.rekeyVerifyPhotos(plan)
        let result = try store.rekeyCommit(plan)
        _ = try store.rekeyDeleteOldPhotos(plan)
        return (plan, result)
    }

    // MARK: - V1 — nothing is lost

    func testEveryProfileKeepsEveryFieldUnderANewKey() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Jane", bio: "kept",
                                                  birthYear: 1990, akas: ["Other"]))
        let (plan, result) = try runFullRekey()

        XCTAssertEqual(result.nodesRekeyed, 1)
        let uid = try XCTUnwrap(plan.uidByOldId["actor:Jane"])
        let moved = try XCTUnwrap(try store.fetchEntityProfile(for: uid))
        XCTAssertEqual(moved.bio, "kept")
        XCTAssertEqual(moved.birthYear, 1990)
        XCTAssertEqual(moved.akas, ["Other"])
        XCTAssertNil(try store.fetchEntityProfile(for: "actor:Jane"),
                     "the name is no longer a key")
    }

    // MARK: - V3 — every edge follows

    func testEveryEdgeFollowsItsNode() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Jane"))
        try store.saveEntityProfile(EntityProfile(id: "studio:Imprint"))
        try store.saveEntityProfile(EntityProfile(id: "studio:Network"))
        let v = try video(["actor:Jane", "studio:Imprint"])
        _ = try store.connectPerformerEdges()
        _ = try store.connectStudioEdges()
        try store.setStudioParent("studio:Network", forStudio: "studio:Imprint",
                                  since: nil, source: .operator)
        try store.recordMatch(NodeMatch(nodeId: "actor:Jane", source: "Example Source",
                                        sourceId: "abc", method: .operator), isVideo: false)

        let (plan, _) = try runFullRekey()
        let jane = try XCTUnwrap(plan.uidByOldId["actor:Jane"])
        let imprint = try XCTUnwrap(plan.uidByOldId["studio:Imprint"])
        let network = try XCTUnwrap(plan.uidByOldId["studio:Network"])

        XCTAssertEqual(try store.performerIds(forVideo: v), [jane])
        XCTAssertEqual(try store.studioId(forVideo: v), imprint)
        XCTAssertEqual(try store.parentStudioId(of: imprint), network)
        XCTAssertEqual(try store.allEntityMatches().first?.nodeId, jane)
    }

    // MARK: - 🚨 V10 — re-pointing never merges two nodes

    func testTwoNodesWithCollidingNamesKeepTheirOwnEdges() throws {
        // An actor and a studio sharing a display name — the case a
        // re-derive-by-name implementation would merge.
        try store.saveEntityProfile(EntityProfile(id: "actor:Same"))
        try store.saveEntityProfile(EntityProfile(id: "studio:Same"))
        let v = try video(["actor:Same", "studio:Same"])
        _ = try store.connectPerformerEdges()
        _ = try store.connectStudioEdges()

        let (plan, _) = try runFullRekey()
        let actor = try XCTUnwrap(plan.uidByOldId["actor:Same"])
        let studio = try XCTUnwrap(plan.uidByOldId["studio:Same"])
        XCTAssertNotEqual(actor, studio)
        XCTAssertEqual(try store.performerIds(forVideo: v), [actor])
        XCTAssertEqual(try store.studioId(forVideo: v), studio,
                       "each edge landed on the node it started from")
    }

    // MARK: - V5 — every photo resolves

    func testPhotosFollowTheNodeAndOldNamesAreRemoved() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Jane"))
        try photo(ProfileImageNaming.primaryFileName(for: "actor:Jane"), "primary")
        try photo(ProfileImageNaming.galleryFileName(for: "actor:Jane",
                                                     token: "https://example.com/a"), "gallery")

        let (plan, _) = try runFullRekey()
        let uid = try XCTUnwrap(plan.uidByOldId["actor:Jane"])

        XCTAssertTrue(fileExists(ProfileImageNaming.primaryFileName(for: uid)))
        XCTAssertTrue(fileExists(ProfileImageNaming.galleryFileName(
            for: uid, token: "https://example.com/a")))
        XCTAssertFalse(fileExists(ProfileImageNaming.primaryFileName(for: "actor:Jane")))
    }

    // 🚨 The prefix trap. `actor_Jane` is a prefix of `actor_Janet`, so a
    // naive prefix match would carry Janet's photos onto Jane.
    func testAPhotoIsNotStolenByANodeWhoseNameIsAPrefix() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Jane"))
        try store.saveEntityProfile(EntityProfile(id: "actor:Janet"))
        try photo(ProfileImageNaming.primaryFileName(for: "actor:Jane"), "jane")
        try photo(ProfileImageNaming.primaryFileName(for: "actor:Janet"), "janet")

        let (plan, _) = try runFullRekey()
        let jane = try XCTUnwrap(plan.uidByOldId["actor:Jane"])
        let janet = try XCTUnwrap(plan.uidByOldId["actor:Janet"])

        let janeBytes = try Data(contentsOf: store.profilesDirectory
            .appendingPathComponent(ProfileImageNaming.primaryFileName(for: jane)))
        let janetBytes = try Data(contentsOf: store.profilesDirectory
            .appendingPathComponent(ProfileImageNaming.primaryFileName(for: janet)))
        XCTAssertEqual(String(data: janeBytes, encoding: .utf8), "jane")
        XCTAssertEqual(String(data: janetBytes, encoding: .utf8), "janet")
    }

    // MARK: - 🚨 V6 — interruption is safe at every phase

    // Killed after COPY: both names exist, the database is untouched, and
    // re-running from the start still works.
    func testAKillAfterCopyingLeavesTheDatabaseUntouched() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Jane"))
        try photo(ProfileImageNaming.primaryFileName(for: "actor:Jane"))

        let plan = try store.rekeyPlan()
        try store.rekeyMintUids(plan)
        _ = try store.rekeyCopyPhotos(plan)
        // ...crash here.

        XCTAssertNotNil(try store.fetchEntityProfile(for: "actor:Jane"),
                        "the node is still keyed by name — nothing was committed")
        XCTAssertTrue(fileExists(ProfileImageNaming.primaryFileName(for: "actor:Jane")),
                      "and the original is still on disk")

        // The whole thing runs again cleanly.
        try store.rekeyVerifyPhotos(plan)
        _ = try store.rekeyCommit(plan)
        _ = try store.rekeyDeleteOldPhotos(plan)
        let uid = try XCTUnwrap(plan.uidByOldId["actor:Jane"])
        XCTAssertNotNil(try store.fetchEntityProfile(for: uid))
    }

    // Killed after COMMIT but before DELETE: old files linger, and they are
    // harmless — the database already points at the new ones.
    func testAKillAfterCommitLeavesHarmlessOrphansThatPhase4Clears() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Jane"))
        try photo(ProfileImageNaming.primaryFileName(for: "actor:Jane"))

        let plan = try store.rekeyPlan()
        try store.rekeyMintUids(plan)
        _ = try store.rekeyCopyPhotos(plan)
        try store.rekeyVerifyPhotos(plan)
        _ = try store.rekeyCommit(plan)
        // ...crash before phase 4.

        let uid = try XCTUnwrap(plan.uidByOldId["actor:Jane"])
        XCTAssertTrue(fileExists(ProfileImageNaming.primaryFileName(for: uid)),
                      "the referenced photo is present, so the library works")
        XCTAssertTrue(fileExists(ProfileImageNaming.primaryFileName(for: "actor:Jane")),
                      "the orphan lingers and hurts nothing")

        XCTAssertEqual(try store.rekeyDeleteOldPhotos(plan), 1)
        XCTAssertFalse(fileExists(ProfileImageNaming.primaryFileName(for: "actor:Jane")))
    }

    // MARK: - V11 — phase 4 is idempotent

    func testPhase4RunsTwiceWithoutError() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Jane"))
        try photo(ProfileImageNaming.primaryFileName(for: "actor:Jane"))
        let (plan, _) = try runFullRekey()

        XCTAssertEqual(try store.rekeyDeleteOldPhotos(plan), 0,
                       "already done, and not an error")
    }

    // ⚠️ And phase 1 is re-runnable: a file already copied is skipped rather
    // than failing on an existing destination.
    func testPhase1IsResumable() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Jane"))
        try photo(ProfileImageNaming.primaryFileName(for: "actor:Jane"))
        let plan = try store.rekeyPlan()
        try store.rekeyMintUids(plan)

        XCTAssertEqual(try store.rekeyCopyPhotos(plan), 1)
        XCTAssertEqual(try store.rekeyCopyPhotos(plan), 0, "resumed, not re-copied")
    }

    // MARK: - 🚨 V3 as a GATE, not a report

    func testACountMismatchAbortsTheCommit() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Jane"))
        let v = try video(["actor:Jane"])
        _ = try store.connectPerformerEdges()

        var plan = try store.rekeyPlan()
        try store.rekeyMintUids(plan)
        // A baseline that no longer matches reality — as if an edge had been
        // added between planning and committing.
        plan = RekeyPlan(uidByOldId: plan.uidByOldId,
                         fileRenames: plan.fileRenames,
                         edgeCounts: plan.edgeCounts.mapValues { $0 + 1 })

        XCTAssertThrowsError(try store.rekeyCommit(plan)) { error in
            guard case RekeyError.edgeCountChanged = error else {
                return XCTFail("expected an edge-count abort, got \(error)")
            }
        }
        // 🚨 And the transaction rolled back: the node is still name-keyed.
        XCTAssertNotNil(try store.fetchEntityProfile(for: "actor:Jane"))
        XCTAssertEqual(try store.performerIds(forVideo: v), ["actor:Jane"])
    }

    // MARK: - 🚨 The name must survive a later save

    /// Found writing these tests, and it would have been silent.
    ///
    /// `encode` derived `entity_type` and `display_name` from the id. After the
    /// re-key the id is a uid with no colon, so the derivation yields nil — and
    /// assigning nil would blank the name on the NEXT SAVE of every profile.
    /// A name is not recoverable from a uid, so that is permanent loss, and it
    /// would have happened the first time anything edited a profile.
    func testSavingAProfileAfterTheRekeyDoesNotBlankItsName() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Jane"))
        let (plan, _) = try runFullRekey()
        let uid = try XCTUnwrap(plan.uidByOldId["actor:Jane"])

        func name() throws -> String? {
            try store.dbQueue.read { db in
                try String.fetchOne(db,
                    sql: "SELECT display_name FROM entity_profiles WHERE id = ?",
                    arguments: [uid])
            }
        }
        XCTAssertEqual(try name(), "Jane", "carried across by the re-key")

        // An ordinary edit — the sort of thing enrichment does constantly.
        var profile = try XCTUnwrap(try store.fetchEntityProfile(for: uid))
        profile.bio = "edited afterwards"
        try store.saveEntityProfile(profile)

        XCTAssertEqual(try name(), "Jane",
                       "a save must not blank the only record of what this node is called")
        XCTAssertEqual(try store.fetchEntityProfile(for: uid)?.bio, "edited afterwards")
    }

    // MARK: - V8 — renaming becomes free

    func testAfterTheRekeyAnEdgeIsIndependentOfTheName() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Jane"))
        let v = try video(["actor:Jane"])
        _ = try store.connectPerformerEdges()
        let (plan, _) = try runFullRekey()
        let uid = try XCTUnwrap(plan.uidByOldId["actor:Jane"])

        // ⭐ The edge names the uid, so nothing about the display name can move
        // it — which is the property this whole migration exists to buy.
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE entity_profiles SET display_name = ? WHERE id = ?",
                           arguments: ["Jane Doe", uid])
        }

        XCTAssertEqual(try store.performerIds(forVideo: v), [uid],
                       "the edge never moved — one row changed and nothing else")
    }

    // MARK: - Unkeyable rows

    // ⚠️ A row with no derivable identity is left exactly as it was rather
    // than being given a uid it could never be resolved by.
    func testAnUnkeyableRowIsLeftAlone() throws {
        try store.saveEntityProfile(EntityProfile(id: "no-colon"))
        let plan = try store.rekeyPlan()
        XCTAssertTrue(plan.uidByOldId.isEmpty)

        try store.rekeyMintUids(plan)
        _ = try store.rekeyCommit(plan)
        XCTAssertNotNil(try store.fetchEntityProfile(for: "no-colon"))
    }
}
