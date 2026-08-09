// OpaqueIdentityMigrationTests.swift
// v34 — the additive half of Opaque Node Identity.
//
// ⭐ Everything here asserts that the migration is HARMLESS. That is its whole
// contract: it is a registered migration, so it runs the moment any library is
// opened, and D6 requires it to be safe on a library whose prerequisites are
// unmet. A test suite for it is therefore mostly a suite about what it does NOT
// do.

import XCTest
import GRDB
@testable import LibraryCore

final class OpaqueIdentityMigrationTests: XCTestCase {

    private var url: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("V34-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store = try LibraryStore(at: url)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: url)
    }

    private func column(_ id: String, _ name: String) throws -> String? {
        try store.dbQueue.read { db in
            try String.fetchOne(db,
                sql: "SELECT \(name) FROM entity_profiles WHERE id = ?", arguments: [id])
        }
    }

    // M1 — the type and name are unpacked from the id.
    func testTypeAndDisplayNameAreDerivedFromTheId() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Marta Venlowe"))

        XCTAssertEqual(try column("actor:Marta Venlowe", "entity_type"), "actor")
        XCTAssertEqual(try column("actor:Marta Venlowe", "display_name"), "Marta Venlowe")
    }

    // M2 — 🚨 a name containing a colon is NOT truncated. The drive library
    // holds exactly one of these, carrying a real edge, and a last-colon split
    // would rename it and orphan that edge.
    func testANameContainingAColonKeepsItsWholeName() throws {
        try store.saveEntityProfile(EntityProfile(id: "studio:Vol 2: The Return"))

        XCTAssertEqual(try column("studio:Vol 2: The Return", "entity_type"), "studio")
        XCTAssertEqual(try column("studio:Vol 2: The Return", "display_name"),
                       "Vol 2: The Return")
    }

    // M3 — ⚠️ `uid` stays NULL. Minting is the operator-invoked step, gated on
    // a backup and a free-space pre-flight; a registered migration must not do
    // it behind the operator's back.
    func testUidIsAddedButNotPopulated() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Someone"))

        XCTAssertNil(try column("actor:Someone", "uid"),
                     "minting belongs to the tool, not to a migration that runs on open")
    }

    // M4 — 🚨 THE CONTRACT. Duplicate display names must not stop a library
    // opening. D1 asked for a UNIQUE index; a unique index can fail, and a
    // failed migration on open means the app cannot open that library at all.
    func testTwoNodesSharingADisplayNameDoNotBreakTheLibrary() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Same Name"))
        try store.saveEntityProfile(EntityProfile(id: "studio:Same Name"))

        // Reopening is what would fail if the index were unique and violated.
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        let reopened = try LibraryStore(at: url)
        XCTAssertEqual(try reopened.fetchAllEntityProfiles().count, 2)
    }

    // M5 — nothing is lost. Every profile and every field survives.
    func testNoProfileOrFieldIsLost() throws {
        let profile = EntityProfile(id: "actor:Full", bio: "kept", gender: "f",
                                    birthYear: 1990, rating: 4, akas: ["Other"])
        try store.saveEntityProfile(profile)
        try store.saveEntityProfile(EntityProfile(id: "studio:Also"))

        XCTAssertEqual(try store.fetchAllEntityProfiles().count, 2)
        let after = try store.fetchEntityProfile(for: "actor:Full")
        XCTAssertEqual(after?.bio, "kept")
        XCTAssertEqual(after?.birthYear, 1990)
        XCTAssertEqual(after?.akas, ["Other"])
    }

    // M6 — the graph is untouched. This migration adds columns; it must not
    // move, drop or re-point a single edge.
    func testEveryEdgeSurvivesUnchanged() throws {
        try store.saveEntityProfile(EntityProfile(id: "studio:Imprint"))
        try store.saveEntityProfile(EntityProfile(id: "studio:Network"))
        try store.setStudioParent("studio:Network", forStudio: "studio:Imprint",
                                  since: nil, source: .operator)

        XCTAssertEqual(try store.parentStudioId(of: "studio:Imprint"), "studio:Network")
    }

    // M7 — reopening the library is stable: the migration is already applied
    // and nothing re-derives or duplicates.
    func testReopeningTheLibraryIsStable() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Repeat"))
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        let reopened = try LibraryStore(at: url)

        XCTAssertEqual(try reopened.fetchAllEntityProfiles().count, 1)
        XCTAssertEqual(try column("actor:Repeat", "display_name"), "Repeat")
    }

    // M10 — 🚨 a row saved AFTER the migration ran is populated too.
    //
    // The migration backfills what exists when it runs; `encode` writes the
    // columns on every save. Without the second half these would be correct for
    // old rows and permanently NULL for new ones — right in testing, wrong in
    // use, which is the worst shape a defect can take.
    func testARowCreatedAfterTheMigrationIsAlsoPopulated() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Created Later"))

        XCTAssertEqual(try column("actor:Created Later", "entity_type"), "actor")
        XCTAssertEqual(try column("actor:Created Later", "display_name"), "Created Later")
    }

    // M11 — an UPDATE keeps them correct, not just an insert.
    func testUpdatingAProfileKeepsTheColumnsCorrect() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Edited"))
        try store.saveEntityProfile(EntityProfile(id: "actor:Edited", bio: "now with a bio"))

        XCTAssertEqual(try column("actor:Edited", "display_name"), "Edited")
        XCTAssertEqual(try store.fetchEntityProfile(for: "actor:Edited")?.bio, "now with a bio")
    }

    // M8 — ⚠️ a malformed id is LEFT ALONE, not guessed at. `instr(id,':') > 1`
    // excludes it, so both new columns stay NULL rather than being filled with
    // a truncation of a string that was never an id.
    func testAMalformedIdIsLeftAloneRatherThanGuessedAt() throws {
        try store.saveEntityProfile(EntityProfile(id: "no-colon"))

        XCTAssertNil(try column("no-colon", "entity_type"))
        XCTAssertNil(try column("no-colon", "display_name"))
        XCTAssertNotNil(try store.fetchEntityProfile(for: "no-colon"),
                        "and the row itself is still there")
    }

    // M9 — what is written matches what `NodeIdentity` reads. If these two ever
    // disagree, phase 0's resolver and the migrated columns describe different
    // nodes.
    func testTheColumnsAgreeWithNodeIdentity() throws {
        for id in ["actor:Marta Venlowe", "studio:Vol 2: The Return", "actor:X"] {
            try store.saveEntityProfile(EntityProfile(id: id))
        }

        for id in ["actor:Marta Venlowe", "studio:Vol 2: The Return", "actor:X"] {
            let identity = NodeIdentity.parse(id)
            XCTAssertEqual(try column(id, "entity_type"), identity?.type)
            XCTAssertEqual(try column(id, "display_name"), identity?.displayName)
        }
    }
}
