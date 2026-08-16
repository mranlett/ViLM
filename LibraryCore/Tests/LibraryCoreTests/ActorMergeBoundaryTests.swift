// ActorMergeBoundaryTests.swift
// Phase 0 of v28, actor half: profiles, photos and tombstones.
//
// ⚠️ Read A1's note before trusting this file. Some of these are REGRESSION
// GUARDS rather than proofs of the post-re-keying behaviour — today the local
// form and the arriving form are the same string, so the divergence they
// protect against cannot yet be produced end-to-end. They are here so the
// behaviour is pinned before the shapes diverge, which is the only moment it
// can be pinned honestly.

import XCTest
@testable import LibraryCore

final class ActorMergeBoundaryTests: XCTestCase {

    private var url: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActorBoundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store = try LibraryStore(at: url)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: url)
    }

    private func export(profiles: [EntityProfile] = [],
                        photos: [ExportedPhoto] = [],
                        tombstones: [EntityTombstone] = []) -> ActorLibraryExport {
        ActorLibraryExport(formatVersion: 2, exportedAt: Date(),
                           profiles: profiles, photos: photos, tombstones: tombstones)
    }

    private var profilesDir: URL {
        url.appendingPathComponent(".catalog/profiles")
    }

    // MARK: - Refusals

    // A1 — 🚨 a profile whose id is not an id in this scheme is refused and
    // counted. Minting from it would key a row on a malformed string, which is
    // then unreachable and unremovable.
    func testAMalformedProfileIdIsRefusedAndCounted() throws {
        let result = try store.applyActorMerge(
            export(profiles: [EntityProfile(id: "no-colon")]))

        XCTAssertEqual(result.newActorCount, 0)
        XCTAssertEqual(result.integrity.unparseableIds, 1)
        XCTAssertTrue(result.integrity.hasStructuralProblem)
        XCTAssertTrue(try store.fetchAllEntityProfiles().isEmpty)
    }

    // A2 — a well-formed profile lands, keyed by the locally-derived id.
    func testAWellFormedProfileLandsUnderTheLocalId() throws {
        let result = try store.applyActorMerge(
            export(profiles: [EntityProfile(id: "actor:Jane Doe", bio: "kept")]))

        XCTAssertEqual(result.newActorCount, 1)
        let saved = try store.fetchEntityProfile(for: "actor:Jane Doe")
        XCTAssertEqual(saved?.bio, "kept")
        XCTAssertEqual(saved?.id, NodeIdentity.parse("actor:Jane Doe")?.legacyId)
        XCTAssertTrue(result.integrity.isClean)
    }

    // A3 — ⚠️ the same actor arriving twice in one payload is created ONCE.
    // Without re-indexing after a mint, the second arrival resolves as absent
    // and is counted as new again.
    func testTheSameActorArrivingTwiceIsCreatedOnce() throws {
        let result = try store.applyActorMerge(export(profiles: [
            EntityProfile(id: "actor:Repeated", bio: "first"),
            EntityProfile(id: "actor:Repeated", homePage: "https://example.com")
        ]))

        XCTAssertEqual(result.newActorCount, 1, "second arrival is an update, not a new actor")
        XCTAssertEqual(try store.fetchAllEntityProfiles()
            .filter { $0.id == "actor:Repeated" }.count, 1)
    }

    // A4 — an actor name containing a colon survives, like the studio one the
    // drive library actually holds.
    func testAnActorNameContainingAColonIsNotTruncated() throws {
        _ = try store.applyActorMerge(
            export(profiles: [EntityProfile(id: "actor:Smith: The Second")]))
        XCTAssertNotNil(try store.fetchEntityProfile(for: "actor:Smith: The Second"))
    }

    // MARK: - Photos

    // A5 — 🚨 photo files are written under the LOCAL id. `ProfileImageNaming`
    // derives every filename from the entity id, so writing under the sender's
    // would orphan the image from the profile it belongs to — and these are
    // downloaded assets the app cannot rebuild without re-fetching.
    func testPhotoFilesAreWrittenUnderTheLocalId() throws {
        let bytes = Data("image-bytes".utf8)
        let result = try store.applyActorMerge(export(
            profiles: [EntityProfile(id: "actor:Jane Doe")],
            photos: [ExportedPhoto(actorId: "actor:Jane Doe", isPrimary: true,
                                   sourceToken: "https://example.com/p.jpg",
                                   contentHash: ProfileImageNaming.sha256Hex(bytes),
                                   fileExtension: "jpg", data: bytes)]))

        XCTAssertEqual(result.newPhotoCount, 1)
        let expected = profilesDir.appendingPathComponent(
            ProfileImageNaming.primaryFileName(for: "actor:Jane Doe"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path),
                      "the photo must sit under the local id, not the sender's")
    }

    // MARK: - Tombstones

    // A6 — a tombstone still suppresses an incoming profile.
    //
    // ⚠️ REGRESSION GUARD, not a proof. The set that drives this is now keyed
    // by resolution key rather than raw id; today those coincide, so this
    // asserts the behaviour survived the change rather than that the
    // post-re-keying case works. It cannot assert the latter until profiles
    // are actually re-keyed.
    func testATombstoneStillSuppressesAnIncomingProfile() throws {
        // ⚠️ The dates are explicit and ORDERED. `suppressesImport` only refuses
        // a profile that PREDATES the deletion — a newer one legitimately means
        // "re-created since", and must be allowed through. Leaving both to
        // default to `Date()` makes the test a race that reports a real rule as
        // a bug.
        let deletedAt = Date()
        let result = try store.applyActorMerge(export(
            profiles: [EntityProfile(id: "actor:Deleted", bio: "should not land",
                                     createdAt: deletedAt.addingTimeInterval(-3600))],
            tombstones: [EntityTombstone(entityId: "actor:Deleted",
                                         deletedAt: deletedAt, replacedBy: nil)]))

        XCTAssertEqual(result.newActorCount, 0)
        XCTAssertNil(try store.fetchEntityProfile(for: "actor:Deleted"),
                     "a deletion must not be undone by the export carrying it")
    }

    // A7 — a tombstone for an entity this library never held is still recorded,
    // so a third library learns of the deletion from this one.
    func testATombstoneForAnUnknownEntityIsStillCarriedForward() throws {
        _ = try store.applyActorMerge(export(tombstones: [
            EntityTombstone(entityId: "actor:Never Held", deletedAt: Date(), replacedBy: nil)
        ]))

        XCTAssertTrue(try store.fetchTombstones().contains { $0.entityId == "actor:Never Held" },
                      "the deletion must propagate even where there was nothing to delete")
    }

    // A8 — a tombstone deletes the LOCAL profile it names.
    //
    // 🚨 The ordering is STATED, not left to two `Date()` calls microseconds
    // apart. This test failed about one run in eight for weeks and was written
    // off as "the known flake" until it was finally caught: `createdAt` stores
    // rounded to the nearest millisecond, so a profile saved immediately before
    // the tombstone reads back as much as half a millisecond LATER than it —
    // and `shouldPropagate` then correctly declines, because a profile created
    // after a deletion is a deliberate re-creation.
    //
    // ⚠️ The product is right and the fixture was wrong. Measured: 13 of 40
    // saves came back later than a deletion timestamp taken after the save.
    // A6 above already states its ordering explicitly; this one did not.
    func testATombstoneDeletesTheLocalProfile() throws {
        let deletedAt = Date()
        try store.saveEntityProfile(
            EntityProfile(id: "actor:Doomed",
                          createdAt: deletedAt.addingTimeInterval(-3600)))
        _ = try store.applyActorMerge(export(tombstones: [
            EntityTombstone(entityId: "actor:Doomed", deletedAt: deletedAt, replacedBy: nil)
        ]))

        XCTAssertNil(try store.fetchEntityProfile(for: "actor:Doomed"))
    }

    /// ⚠️ The boundary the flake was hiding: a profile created at the SAME
    /// instant as the deletion is still deleted, because the rule is inclusive.
    /// Pinned so the fix above cannot be mistaken for the rule having changed.
    func testAProfileCreatedAtTheDeletionInstantIsStillDeleted() throws {
        let instant = Date()
        try store.saveEntityProfile(EntityProfile(id: "actor:Simultaneous",
                                                  createdAt: instant))
        _ = try store.applyActorMerge(export(tombstones: [
            EntityTombstone(entityId: "actor:Simultaneous", deletedAt: instant,
                            replacedBy: nil)
        ]))

        XCTAssertNil(try store.fetchEntityProfile(for: "actor:Simultaneous"))
    }

    // MARK: - 🚨 The no-op assertion

    // A9 — an ordinary merge between two same-shaped libraries refuses nothing
    // and behaves exactly as before. If phase 0 ever starts rejecting normal
    // traffic, this is what fails.
    func testAnOrdinaryActorMergeRefusesNothing() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Held", bio: "mine"))
        let result = try store.applyActorMerge(export(profiles: [
            EntityProfile(id: "actor:Held", homePage: "https://example.com"),
            EntityProfile(id: "actor:Fresh")
        ]))

        XCTAssertEqual(result.newActorCount, 1)
        XCTAssertEqual(result.updatedActorCount, 1)
        XCTAssertTrue(result.integrity.isClean)
        // The non-destructive field merge is untouched by any of this.
        XCTAssertEqual(try store.fetchEntityProfile(for: "actor:Held")?.bio, "mine")
        XCTAssertEqual(try store.fetchEntityProfile(for: "actor:Held")?.homePage,
                       "https://example.com")
    }

    // A10 — the actor half's refusals reach the graph result, so a caller
    // reporting on a full sync cannot show "clean" while profiles were refused.
    func testActorRefusalsSurfaceInTheGraphMergeResult() throws {
        let result = try store.applyGraphMerge(
            export(profiles: [EntityProfile(id: "malformed")]))

        XCTAssertEqual(result.integrity.unparseableIds, 1)
        XCTAssertFalse(result.integrity.isClean)
    }
}
