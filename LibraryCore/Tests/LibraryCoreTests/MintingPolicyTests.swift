// MintingPolicyTests.swift
// Which SHAPE of id a newly created entity gets.
//
// 🚨 The decision this pins: the LIBRARY decides, not the caller and not a
// build flag. A library that has been re-keyed mints uids; one that has not
// mints legacy `type:Name` ids, exactly as it always did.
//
// ⭐ Why not simply "always mint uids once v34 has run": ~140 call sites still
// reach a profile by building `"actor:\(name)"`. Minting a uid ahead of them
// would create an actor that the app which created it cannot then find — the
// row exists, every screen says it does not. Following the library's own shape
// keeps minting a no-op until the re-key actually happens, which is the same
// discipline as the rest of phase 0.

import XCTest
@testable import LibraryCore

final class MintingPolicyTests: XCTestCase {

    private var directory: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try LibraryStore(at: directory)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    /// Puts the library into the state `IdentityRekey.rekeyCommit` leaves:
    /// `uid` minted AND adopted as the primary key.
    private func markRekeyed() throws {
        let uid = UUID().uuidString
        try store.saveEntityProfile(EntityProfile(id: uid, entityType: "actor",
                                                  displayName: "Already Rekeyed"))
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE entity_profiles SET uid = id WHERE id = ?",
                           arguments: [uid])
        }
    }

    // MARK: - Detecting the state

    func testAFreshLibraryIsNotRekeyed() throws {
        XCTAssertFalse(try store.isRekeyed())
    }

    func testALegacyLibraryIsNotRekeyed() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Someone"))
        XCTAssertFalse(try store.isRekeyed())
    }

    // ⚠️ The window after minting into `uid` and before adopting it as the key.
    // The keys are still legacy here, so minting must still be legacy — a uid
    // handed out now would be a mixed row inside a library mid-migration.
    func testUidPopulatedButNotYetAdoptedIsNotRekeyed() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Someone"))
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE entity_profiles SET uid = ?",
                           arguments: [UUID().uuidString])
        }
        XCTAssertFalse(try store.isRekeyed(), "the id column is still the legacy key")
    }

    func testALibraryWhoseKeysAreUidsIsRekeyed() throws {
        try markRekeyed()
        XCTAssertTrue(try store.isRekeyed())
    }

    // MARK: - What gets minted

    // ⭐ The no-op assertion. Before the re-key, minting is byte-for-byte what
    // the old `EntityProfile(id: "studio:\(name)")` produced.
    func testALegacyLibraryStillMintsTheNameFormId() throws {
        let minted = try store.newEntityProfile(named: "Silver River", type: "studio")

        XCTAssertEqual(minted.id, "studio:Silver River")
        XCTAssertEqual(minted.entityType, "studio")
        XCTAssertEqual(minted.displayName, "Silver River")
    }

    func testARekeyedLibraryMintsAUid() throws {
        try markRekeyed()

        let minted = try store.newEntityProfile(named: "Silver River", type: "studio")

        XCTAssertNil(NodeIdentity.parse(minted.id),
                     "a uid must not parse as a name-form id")
        XCTAssertNotEqual(minted.id, "studio:Silver River")
    }

    // 🚨 The columns are carried EXPLICITLY in both branches. After the re-key
    // there is nothing to derive them from, and a uid-keyed row without them is
    // a profile whose name is unrecoverable.
    func testARekeyedMintStillCarriesItsNameAndType() throws {
        try markRekeyed()

        let minted = try store.newEntityProfile(named: "Silver River", type: "studio")
        // ⚠️ SAVED and re-read. Asserting on the freshly built struct alone
        // would only test that an initialiser assigns its arguments — it would
        // pass even if the columns never reached SQLite, which is the failure
        // that actually loses the name.
        try store.saveEntityProfile(minted)

        let stored = try XCTUnwrap(try store.fetchEntityProfile(for: minted.id))
        XCTAssertEqual(stored.displayName, "Silver River")
        XCTAssertEqual(stored.entityType, "studio")
        XCTAssertEqual(stored.name, "Silver River")
    }

    // And the minted row is findable by the lookup the app now uses.
    func testARekeyedMintIsImmediatelyFindableByName() throws {
        try markRekeyed()

        let minted = try store.newEntityProfile(named: "Silver River", type: "studio")
        try store.saveEntityProfile(minted)

        XCTAssertEqual(try store.fetchEntityProfile(named: "Silver River", type: "studio")?.id,
                       minted.id)
    }

    // MARK: - 🚨 Writing under a name that has no row yet

    /// The defect that reached the live library. Four actors were created with
    /// legacy `actor:Name` keys minutes AFTER the drive library was re-keyed:
    /// a screen resolved the name, found no row, fell back to the name form,
    /// and the editor saved under it. One profile at a time, the library
    /// becomes permanently half-migrated.
    func testWritingUnderANewNameMintsTheLibrarysOwnShape() throws {
        try markRekeyed()

        let id = try store.entityIdForWriting(named: "Brand New", type: "actor")

        XCTAssertNil(NodeIdentity.parse(id),
                     "a re-keyed library must not hand back a name-form id to write under")
    }

    /// ⭐ And it returns the EXISTING row when there is one — it resolves
    /// first, mints second. Minting unconditionally would create a duplicate
    /// of every actor anyone edited.
    func testWritingUnderAKnownNameReturnsThatRow() throws {
        try markRekeyed()
        let existing = try store.newEntityProfile(named: "Already Here", type: "actor")
        try store.saveEntityProfile(existing)

        XCTAssertEqual(try store.entityIdForWriting(named: "Already Here", type: "actor"),
                       existing.id)
    }

    /// ⚠️ Before the re-key it still answers the name form, so this changes
    /// nothing on a library that has not been upgraded.
    func testWritingUnderANewNameIsUnchangedBeforeTheRekey() throws {
        XCTAssertEqual(try store.entityIdForWriting(named: "Brand New", type: "actor"),
                       "actor:Brand New")
    }

    /// The round trip: mint an id to write under, save through it, find it by
    /// name. This is what the editor actually does.
    func testAProfileSavedUnderAMintedIdIsFoundByName() throws {
        try markRekeyed()

        let id = try store.entityIdForWriting(named: "Brand New", type: "actor")
        try store.saveEntityProfile(EntityProfile(id: id, entityType: "actor",
                                                  displayName: "Brand New", bio: "written"))

        let found = try XCTUnwrap(try store.fetchEntityProfile(named: "Brand New",
                                                               type: "actor"))
        XCTAssertEqual(found.id, id)
        XCTAssertEqual(found.bio, "written")
        XCTAssertNil(NodeIdentity.parse(found.id))
    }

    // MARK: - The callers that mint

    // ⚠️ `confirmStudio` must find the EXISTING studio after the re-key rather
    // than minting a second one beside it under a legacy key.
    func testConfirmingAStudioTwiceInARekeyedLibraryIsOneRow() throws {
        try markRekeyed()

        try store.confirmStudio("Silver River", source: "A Source", sourceId: "s-1")
        try store.confirmStudio("Silver River", source: "A Source", sourceId: "s-1")

        let studios = try store.fetchAllEntityProfiles().filter { $0.type == "studio" }
        XCTAssertEqual(studios.count, 1)
        XCTAssertNil(NodeIdentity.parse(studios[0].id), "minted as a uid")
        XCTAssertEqual(studios[0].name, "Silver River")
    }

    func testEnsuringAStudioInARekeyedLibraryMintsAUid() throws {
        try markRekeyed()

        XCTAssertTrue(try store.ensureStudioProfile("Silver River"))
        XCTAssertFalse(try store.ensureStudioProfile("Silver River"), "idempotent by name")

        let studio = try XCTUnwrap(try store.fetchEntityProfile(named: "Silver River",
                                                                type: "studio"))
        XCTAssertNil(NodeIdentity.parse(studio.id))
    }
}
