// MigrationPreflightTests.swift
// The gate before the irreversible half of v28.
//
// ⭐ Every assertion here is about REFUSING. The pre-flight's job is to stop a
// run that would corrupt a library, and a gate that passes when it should not
// is worse than no gate — it converts a caught problem into a silent one.

import XCTest
@testable import LibraryCore

final class MigrationPreflightTests: XCTestCase {

    private var url: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Preflight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store = try LibraryStore(at: url)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: url)
    }

    // P1 — a healthy library may proceed.
    func testAHealthyLibraryPasses() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Marta Venlowe"))
        try store.saveEntityProfile(EntityProfile(id: "studio:Big"))

        let check = try store.migrationPreflight()
        XCTAssertTrue(check.schemaReady)
        XCTAssertTrue(check.canProceed, "blockers: \(check.blockers)")
        XCTAssertTrue(check.blockers.isEmpty)
    }

    // P2 — 🚨 two records claiming one identity BLOCK the run.
    //
    // D1 wanted this as a unique index inside the migration, where a violation
    // would have stopped the library opening at all. Here it is reported, the
    // duplicates are named, and the operator decides.
    func testTwoRecordsClaimingOneIdentityBlockTheRun() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Same"))
        // A second row with the same derived identity, inserted directly —
        // `saveEntityProfile` would treat the matching id as an update.
        try store.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO entity_profiles (id, entity_type, display_name)
                VALUES ('actor:Same ', 'actor', 'Same')
                """)
        }

        let check = try store.migrationPreflight()
        XCTAssertEqual(check.duplicates.count, 1)
        XCTAssertEqual(check.duplicates.first?.displayName, "Same")
        XCTAssertEqual(check.duplicates.first?.ids.count, 2)
        XCTAssertFalse(check.canProceed)
    }

    // P3 — a record with no derivable identity blocks the run: there is
    // nothing to mint a uid from and nothing to resolve it by later.
    func testAnUnkeyableRecordBlocksTheRun() throws {
        try store.saveEntityProfile(EntityProfile(id: "no-colon"))

        let check = try store.migrationPreflight()
        XCTAssertEqual(check.unkeyableProfiles, ["no-colon"])
        XCTAssertFalse(check.canProceed)
    }

    // P4 — ⭐ the SCHEMA already refuses a dangling edge, which is a stronger
    // guarantee than the check.
    //
    // Discovered writing this test: inserting an edge for a profile that does
    // not exist fails on the foreign key. So `danglingEdges` cannot fire on any
    // edge the current schema governs, and it stays as defence-in-depth for
    // rows predating a constraint rather than as a live risk.
    //
    // ⚠️ Asserted rather than assumed, because "the FK protects us" is exactly
    // the kind of belief that turns out to be false for one table.
    func testTheSchemaItselfRefusesADanglingEdge() throws {
        XCTAssertThrowsError(
            try store.dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO entity_match (entity_id, source, source_id, method, matched_at)
                    VALUES ('actor:Ghost', 'Example Source', 'x', 'operator', datetime('now'))
                    """)
            },
            "an edge naming a missing profile must not be insertable")

        let check = try store.migrationPreflight()
        XCTAssertEqual(check.danglingEdges, 0)
        XCTAssertTrue(check.canProceed, "blockers: \(check.blockers)")
    }

    // P5 — 🚨 THE TOMBSTONE ASSERTION. A tombstone for a deleted entity is
    // CORRECT, not dangling, and must not block anything.
    //
    // D1 listed `deleted_entities` among the tables to re-point by joining
    // `entity_profiles`. On the drive library 1,102 of 1,202 tombstones name an
    // entity that no longer exists — the entire point of the table — so that
    // join finds nothing and would blank them, resurrecting every deletion on
    // the next sync. They are counted here and never treated as a fault.
    func testATombstoneForADeletedEntityIsNotAFault() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Gone"))
        try store.recordTombstone(EntityTombstone(entityId: "actor:Gone",
                                                  deletedAt: Date(), replacedBy: nil))
        try store.deleteEntityProfile(for: "actor:Gone")

        let check = try store.migrationPreflight()
        XCTAssertEqual(check.tombstoneCount, 1)
        XCTAssertEqual(check.danglingEdges, 0, "a tombstone is not a dangling edge")
        XCTAssertTrue(check.canProceed, "blockers: \(check.blockers)")
    }

    // P6 — the space rule is D3's, and it is required rather than advisory:
    // both copies of every photo exist between phases 1 and 4.
    func testTheSpaceRuleAccountsForBothCopies() {
        let check = MigrationPreflight(
            schemaReady: true, duplicates: [], unkeyableProfiles: [],
            danglingEdges: 0,
            photoBytes: 2_670_000_000,          // the drive library today
            freeBytes: 3_000_000_000,
            edgeCounts: [:], tombstoneCount: 0)

        XCTAssertEqual(check.requiredBytes, 3_037_000_000)
        XCTAssertFalse(check.hasEnoughSpace, "3.0 GB free is NOT enough for 2.67 GB of photos")
        XCTAssertFalse(check.canProceed)
    }

    // P7b — 🚨 unknown free space is refused, and NOT reported as a full disk.
    //
    // `volumeAvailableCapacityForImportantUsage` is an APFS/HFS+ concept and
    // returns nothing on ExFAT, which is what the drive library is formatted
    // as. Coercing that to zero showed "0.00 GB free" on a volume with 239 GB
    // and blocked the upgrade. Reported from the device 2026-08-08.
    func testUnreadableFreeSpaceIsRefusedButNotCalledAFullDisk() {
        let check = MigrationPreflight(
            schemaReady: true, duplicates: [], unkeyableProfiles: [],
            danglingEdges: 0, photoBytes: 3_170_000_000, freeBytes: nil,
            edgeCounts: [:], tombstoneCount: 0)

        XCTAssertFalse(check.canProceed, "it cannot be verified, so it does not pass")
        let reason = try? XCTUnwrap(check.blockers.first)
        XCTAssertTrue(reason?.contains("would not report") == true,
                      "must read as unreadable, not as full: \(check.blockers)")
        XCTAssertFalse(reason?.contains("Not enough") == true)
    }

    // P7c — 🚨 the requirement is ALLOCATED size, not logical size.
    //
    // The drive library is 1.61 GB of image bytes occupying 3.17 GB of disk:
    // ExFAT with a 256 KB allocation block across 9,202 mostly-small files. A
    // gate built on logical size would have passed a run with barely 2 GB free
    // and died halfway through copying — the exact failure it exists to stop.
    func testTheRequirementIsBuiltOnWhatACopyActuallyConsumes() {
        let logical = MigrationPreflight(
            schemaReady: true, duplicates: [], unkeyableProfiles: [],
            danglingEdges: 0, photoBytes: 1_610_000_000, freeBytes: 2_000_000_000,
            edgeCounts: [:], tombstoneCount: 0)
        XCTAssertTrue(logical.hasEnoughSpace, "what the old, wrong measurement believed")

        let allocated = MigrationPreflight(
            schemaReady: true, duplicates: [], unkeyableProfiles: [],
            danglingEdges: 0, photoBytes: 3_170_000_000, freeBytes: 2_000_000_000,
            edgeCounts: [:], tombstoneCount: 0)
        XCTAssertFalse(allocated.hasEnoughSpace,
                       "the same volume, measured honestly, is not big enough")
    }

    // P7 — with real headroom it passes.
    func testAmpleSpacePasses() {
        let check = MigrationPreflight(
            schemaReady: true, duplicates: [], unkeyableProfiles: [],
            danglingEdges: 0,
            photoBytes: 3_170_000_000,          // allocated, the drive today
            freeBytes: 239_000_000_000,
            edgeCounts: [:], tombstoneCount: 0)

        XCTAssertTrue(check.hasEnoughSpace)
        XCTAssertTrue(check.canProceed)
    }

    // P8 — every blocker is reported, not just the first. An operator fixing
    // them one run at a time is an operator making four passes at a gate.
    func testEveryBlockerIsReportedAtOnce() throws {
        try store.saveEntityProfile(EntityProfile(id: "no-colon"))
        try store.saveEntityProfile(EntityProfile(id: "actor:Same"))
        try store.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO entity_profiles (id, entity_type, display_name)
                VALUES ('actor:Same ', 'actor', 'Same')
                """)
        }

        let check = try store.migrationPreflight()
        XCTAssertEqual(check.blockers.count, 2,
                       "both the duplicate and the unkeyable record, in one pass")
        XCTAssertFalse(check.canProceed)
    }

    // P9 — the V3 baseline names every table that gets re-pointed, and
    // `deleted_entities` is NOT among them.
    func testTheBaselineCoversTheRepointedTablesOnly() throws {
        let check = try store.migrationPreflight()
        XCTAssertEqual(Set(check.edgeCounts.keys),
                       ["video_performer", "video_studio", "video_tag",
                        "performer_tag", "studio_parent", "entity_match",
                        "pending_tag_association"])
        XCTAssertFalse(check.edgeCounts.keys.contains("deleted_entities"))
    }

    // P10 — read-only. Running it changes nothing at all.
    func testThePreflightChangesNothing() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Untouched", bio: "kept"))
        _ = try store.migrationPreflight()
        _ = try store.migrationPreflight()

        XCTAssertEqual(try store.fetchAllEntityProfiles().count, 1)
        XCTAssertEqual(try store.fetchEntityProfile(for: "actor:Untouched")?.bio, "kept")
    }
}
