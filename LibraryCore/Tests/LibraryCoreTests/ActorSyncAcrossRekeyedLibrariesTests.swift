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
// ⭐ These were written FIRST, pinning the broken behaviour so it could not be
// argued with, then inverted once the fix landed. The root cause turned out to
// be one property: `EntityProfile.nodeIdentity` still parsed the id, with a
// comment saying the columns must take over "after v28's re-keying". The
// re-key shipped; the property never changed.

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

    /// A1 — the defect, now fixed. Two re-keyed libraries each hold Jane under
    /// their own uid, and the planner treats them as one person.
    func testTwoRekeyedLibrariesFoldToOnePerson() {
        let plans = ActorSync.plan(for: [
            snapshot("A", [jane(uid: "uid-in-A", bio: "from A")]),
            snapshot("B", [jane(uid: "uid-in-B")]),
        ])

        XCTAssertEqual(plans.count, 1, "one performer, one plan")
        XCTAssertEqual(plans.first?.displayName, "Jane Example")
        XCTAssertTrue(plans.first?.missingFrom.isEmpty ?? false,
                      "neither library is missing her — both have her under their own uid")
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

    /// A3 — a bio held by one side is now seen as a gap on the other, which is
    /// the entire point of sync.
    func testABlankOnOneSideIsAFillAfterTheRekey() {
        let plans = ActorSync.plan(for: [
            snapshot("A", [jane(uid: "uid-in-A", bio: "written in A")]),
            snapshot("B", [jane(uid: "uid-in-B")]),
        ])

        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans.first?.blankFills.values.reduce(0, +), 1,
                       "B is missing the bio A holds")
    }

    /// A4 — 🚨 and a TRUE disagreement is surfaced rather than silently
    /// resolved. This is the invariant the file header states, and it was not
    /// merely unmet after the re-key — it was unreachable, because the two
    /// records never met to disagree.
    func testATrueConflictIsDetectedAcrossRekeyedLibraries() {
        var a = jane(uid: "uid-in-A"); a.bio = "A's version"
        var b = jane(uid: "uid-in-B"); b.bio = "B's version"

        let plans = ActorSync.plan(for: [snapshot("A", [a]), snapshot("B", [b])])

        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans.first?.conflicts.map(\.field), [.bio],
                       "both sides hold a different real value — the operator must decide")
    }

    // MARK: - Deletions

    /// A5 — a tombstone reaches the other library's copy.
    ///
    /// ⚠️ Recorded in NAME form, which is what `deleteEntityProfile` writes: a
    /// tombstone names an entity that no longer exists, so a uid would point at
    /// nothing. That form now lines up with a profile arriving under a uid,
    /// because both sides resolve to the same identity.
    func testATombstoneReachesTheOtherRekeyedLibrary() {
        // ⚠️ Dated AFTER the profile. `shouldPropagate` compares the
        // tombstone against `createdAt`, which a fresh profile stamps with the
        // current time — a tombstone built first in the same millisecond looks
        // like a deletion that predates the record it refers to.
        let stone = EntityTombstone(entityId: "actor:Jane Example",
                                    deletedAt: Date().addingTimeInterval(60))
        let plans = ActorSync.plan(for: [
            snapshot("A", [], tombstones: [stone]),
            snapshot("B", [jane(uid: "uid-in-B")]),
        ])

        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans.first?.deletionFrom.count, 1,
                       "B's copy is removed by A's deletion")
    }

    // MARK: - The key the whole fix rests on

    /// A6 — identity agrees across libraries where the id cannot, and the read
    /// path was already folding on it. That asymmetry is what made the write
    /// path's breakage findable.
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
