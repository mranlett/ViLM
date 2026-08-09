// ActorSyncAcrossRekeyedLibrariesTests.swift
// 🚨 Syncing two libraries that have BOTH been re-keyed.
//
// The federation rule (Epic D4) is that a uid is LOCAL: between libraries the
// identity of a node is its name triple, never its primary key. `ActorSync`
// predates the re-key and keys everything on `EntityProfile.id` — the plan, the
// photo index, and the tombstone index — which was correct only while two
// libraries independently derived the SAME id from the same name.
//
// After the re-key each library mints its own uid for the same performer, so
// every one of those lookups misses. This is the exact defect already fixed on
// the READ path: `EntityProfileIndex.merged` folds by identity because an
// id-keyed fold showed one person twice. The WRITE path was never changed.
//
// ⚠️ These tests describe CURRENT behaviour, so they pass. They exist to make
// the behaviour undeniable and to fail loudly the moment sync is corrected —
// at which point their assertions invert and the ⚠️ ones become the spec.

import XCTest
@testable import LibraryCore

final class ActorSyncAcrossRekeyedLibrariesTests: XCTestCase {

    private func snapshot(_ name: String,
                          _ profiles: [EntityProfile],
                          photos: [ExportedPhoto] = [],
                          tombstones: [EntityTombstone] = []) -> ActorSync.LibrarySnapshot {
        ActorSync.LibrarySnapshot(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            export: ActorLibraryExport(formatVersion: 1, exportedAt: Date(),
                                       profiles: profiles, photos: photos,
                                       tombstones: tombstones))
    }

    /// The same performer as each library knows her AFTER its own re-key:
    /// same name, same type, different uid.
    private func jane(uid: String, bio: String? = nil) -> EntityProfile {
        var p = EntityProfile(id: uid, entityType: "actor", displayName: "Jane Example")
        p.bio = bio
        return p
    }

    // MARK: - 🚨 One person becomes two

    /// A1 — the defect. Two re-keyed libraries each hold Jane under their own
    /// uid. Identity says one person; the planner sees two, and each is
    /// reported as MISSING from the library that in fact has her.
    func testTwoRekeyedLibrariesReportOnePersonAsTwoActors() {
        let plans = ActorSync.plan(for: [
            snapshot("A", [jane(uid: "uid-in-A", bio: "from A")]),
            snapshot("B", [jane(uid: "uid-in-B")]),
        ])

        // ⚠️ CURRENT behaviour. Correct would be 1.
        XCTAssertEqual(plans.count, 2,
                       "one performer, two plans — the id is being treated as identity")

        // And each plan proposes copying her into the library that already has
        // her, which is what would create the duplicate rows.
        for plan in plans {
            XCTAssertEqual(plan.missingFrom.count, 1,
                           "each side looks absent from the other")
            XCTAssertEqual(plan.displayName, "Jane Example",
                           "both plans name the SAME person — the tell")
        }
    }

    /// A2 — the control, and the reason this was not caught. Before the re-key
    /// both libraries derive the same `actor:Name` id, so the planner folds
    /// them correctly. Every existing sync test is this shape.
    func testTwoLegacyLibrariesStillFoldToOnePerson() {
        let plans = ActorSync.plan(for: [
            snapshot("A", [EntityProfile(id: "actor:Jane Example", bio: "from A")]),
            snapshot("B", [EntityProfile(id: "actor:Jane Example")]),
        ])

        XCTAssertEqual(plans.count, 1, "the legacy id IS the identity, so this works")
        XCTAssertTrue(plans[0].missingFrom.isEmpty, "neither side is missing her")
    }

    /// A3 — ⚠️ and the two libraries' data never converges. The whole purpose
    /// of sync is that a bio held by one side reaches the other; here each
    /// plan sees only its own holder, so there is nothing to reconcile.
    func testDataDoesNotConvergeAcrossRekeyedLibraries() {
        let plans = ActorSync.plan(for: [
            snapshot("A", [jane(uid: "uid-in-A", bio: "written in A")]),
            snapshot("B", [jane(uid: "uid-in-B")]),
        ])

        let withBio = plans.filter { $0.actorId == "uid-in-A" }
        XCTAssertEqual(withBio.count, 1)
        // Nobody disagrees, because the two records never met.
        XCTAssertTrue(plans.allSatisfy { $0.conflicts.isEmpty },
                      "no conflict is detected between two records of one person")
    }

    // MARK: - 🚨 Deletions stop propagating

    /// A4 — a tombstone is keyed by entity id too. Deleting Jane in A records
    /// A's uid, which matches nothing in B, so the deletion does not reach her
    /// there — and the header of `ActorSync` states that propagating deletions
    /// is exactly what tombstones exist to do.
    func testATombstoneDoesNotReachTheOtherRekeyedLibrary() {
        let stone = EntityTombstone(entityId: "uid-in-A", deletedAt: Date())
        let plans = ActorSync.plan(for: [
            snapshot("A", [], tombstones: [stone]),
            snapshot("B", [jane(uid: "uid-in-B")]),
        ])

        let janeInB = plans.first { $0.actorId == "uid-in-B" }
        XCTAssertNotNil(janeInB)
        // ⚠️ CURRENT behaviour: B's copy is untouched by A's deletion.
        XCTAssertEqual(janeInB?.deletionFrom.count, 0,
                       "the deletion did not reach her under B's uid")
    }

    // MARK: - What a correct implementation would key on

    /// A5 — the key that does work across libraries, for whoever fixes this.
    /// `NodeIdentity.resolutionKey` is what `EntityProfileIndex.merged` folds
    /// on, and it already agrees across the two uids.
    func testIdentityIsTheKeyThatAgreesAcrossLibraries() {
        let a = jane(uid: "uid-in-A")
        let b = jane(uid: "uid-in-B")

        XCTAssertNotEqual(a.id, b.id, "the ids differ, which is the problem")
        XCTAssertEqual(NodeIdentity(type: "actor", displayName: a.name).resolutionKey,
                       NodeIdentity(type: "actor", displayName: b.name).resolutionKey,
                       "identity is the same person in both libraries")

        // And the read path already folds them into one.
        XCTAssertEqual(EntityProfileIndex.merged(ordered: [[a], [b]]).count, 1)
    }
}
