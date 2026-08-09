// NodeResolverTests.swift
// The federation boundary: no string from a payload reaches a key column.
//
// ⭐ The tests worth reading twice are P1 and P2. Phase 0 is only safe to ship
// ahead of the re-keying because it changes nothing today — so "changes
// nothing" is asserted here rather than argued for in a comment.

import XCTest
@testable import LibraryCore

final class NodeResolverTests: XCTestCase {

    // MARK: - Resolution outcomes

    // R1 — a node this library holds resolves to ITS OWN id.
    func testAKnownNodeResolvesToTheLocalId() {
        let resolver = NodeResolver(localIds: ["actor:Marta Venlowe", "studio:Big"])
        XCTAssertEqual(resolver.resolve("actor:Marta Venlowe"), .resolved("actor:Marta Venlowe"))
        XCTAssertEqual(resolver.localId(for: "studio:Big"), "studio:Big")
    }

    // R2 — absent is not an error, and is distinct from unparseable. The two
    // call for opposite handling: absent may justify minting a node, and
    // unparseable never does.
    func testAbsentAndUnparseableAreDifferentAnswers() {
        let resolver = NodeResolver(localIds: ["actor:Held"])
        XCTAssertEqual(resolver.resolve("actor:Not Held"), .absent)
        XCTAssertEqual(resolver.resolve("no colon at all"), .unparseable)
        XCTAssertEqual(resolver.resolve(""), .unparseable)
        XCTAssertEqual(resolver.resolve("actor:"), .unparseable)
    }

    // R3 — 🚨 two LOCAL nodes claiming one identity resolve to NEITHER.
    //
    // Reachable today: tag identity folds case, so `tag:SCUBA` and `tag:Scuba`
    // are two rows sharing one resolution key. Picking either would attach an
    // arriving edge to whichever row happened to be read last.
    func testTwoLocalNodesSharingAnIdentityRefuseToResolve() {
        let resolver = NodeResolver(localIds: ["tag:SCUBA", "tag:Scuba"])
        XCTAssertEqual(resolver.resolve("tag:scuba"), .ambiguous)
        XCTAssertNil(resolver.localId(for: "tag:Scuba"))
        XCTAssertEqual(resolver.contestedKeyCount, 1)
    }

    // R4 — ⚠️ a contested key must not resolve even when asked with the exact
    // string of one of the two rows. A dictionary build alone would hand back
    // the last writer and look correct in every simple test.
    func testAContestedKeyStaysUnresolvableForBothSpellings() {
        let resolver = NodeResolver(localIds: ["tag:SCUBA", "tag:Scuba"])
        XCTAssertEqual(resolver.resolve("tag:SCUBA"), .ambiguous)
        XCTAssertEqual(resolver.resolve("tag:Scuba"), .ambiguous)
    }

    // R5 — the same id listed twice is one node, not a conflict.
    func testADuplicateIdIsNotAConflict() {
        let resolver = NodeResolver(localIds: ["actor:A", "actor:A"])
        XCTAssertEqual(resolver.resolve("actor:A"), .resolved("actor:A"))
        XCTAssertEqual(resolver.contestedKeyCount, 0)
    }

    // R6 — ⚠️ a local id this build cannot parse is dropped from the index
    // rather than taking the whole resolver down. A library holding a row from
    // a newer build must still resolve everything else.
    func testAnUnparseableLocalIdDoesNotBreakTheIndex() {
        let resolver = NodeResolver(localIds: ["garbage", "actor:Fine"])
        XCTAssertEqual(resolver.resolve("actor:Fine"), .resolved("actor:Fine"))
        XCTAssertEqual(resolver.indexedCount, 1)
    }

    // R7 — an empty library resolves nothing and does not crash.
    func testAnEmptyLibraryResolvesNothing() {
        let resolver = NodeResolver(localIds: [])
        XCTAssertEqual(resolver.resolve("actor:Anyone"), .absent)
        XCTAssertEqual(resolver.indexedCount, 0)
    }

    // R8 — only `.resolved` yields something writable. This is the guard the
    // whole boundary leans on.
    func testOnlyAResolvedOutcomeIsWritable() {
        XCTAssertEqual(NodeResolution.resolved("actor:A").writableLocalId, "actor:A")
        XCTAssertNil(NodeResolution.absent.writableLocalId)
        XCTAssertNil(NodeResolution.unparseable.writableLocalId)
        XCTAssertNil(NodeResolution.ambiguous.writableLocalId)
    }

    // MARK: - The integrity report

    // R9 — every refusal is counted apart, because they mean different things.
    func testTheReportCountsEachRefusalSeparately() {
        var report = SyncIntegrityReport()
        XCTAssertTrue(report.isClean)
        XCTAssertEqual(report.note(.resolved("actor:A")), "actor:A")
        XCTAssertTrue(report.isClean, "a resolution is not a refusal")

        report.note(.absent)
        report.note(.unparseable)
        report.note(.ambiguous)
        XCTAssertEqual(report.absentNodes, 1)
        XCTAssertEqual(report.unparseableIds, 1)
        XCTAssertEqual(report.ambiguousNodes, 1)
        XCTAssertFalse(report.isClean)
    }

    // R10 — ⚠️ an absent node is an ordinary difference between two libraries;
    // an unparseable or ambiguous one is a DEFECT. The report separates them
    // so a normal sync is not reported as broken.
    func testOnlyStructuralProblemsAreFlaggedAsSuch() {
        var ordinary = SyncIntegrityReport()
        ordinary.note(.absent)
        XCTAssertFalse(ordinary.isClean)
        XCTAssertFalse(ordinary.hasStructuralProblem)

        var broken = SyncIntegrityReport()
        broken.note(.unparseable)
        XCTAssertTrue(broken.hasStructuralProblem)
    }

    // MARK: - Re-keying a profile

    // R11 — the profile keeps every field when re-keyed. The assertion that
    // catches a field-by-field reconstruction being added later.
    func testReidentifyingAProfileKeepsEveryOtherField() {
        let original = EntityProfile(id: "actor:Old", bio: "kept", gender: "f",
                                     birthYear: 1990, rating: 4,
                                     galleryUrls: ["a", "b"], akas: ["Other"])
        let moved = original.reidentified(as: "uid-123")
        XCTAssertEqual(moved.id, "uid-123")
        XCTAssertEqual(moved.bio, "kept")
        XCTAssertEqual(moved.gender, "f")
        XCTAssertEqual(moved.birthYear, 1990)
        XCTAssertEqual(moved.rating, 4)
        XCTAssertEqual(moved.galleryUrls, ["a", "b"])
        XCTAssertEqual(moved.akas, ["Other"])
    }

    // R12 — ⚠️ an empty id is refused rather than applied. A profile keyed on
    // "" is unreachable and unremovable.
    func testReidentifyingToAnEmptyIdIsRefused() {
        let original = EntityProfile(id: "actor:Held")
        XCTAssertEqual(original.reidentified(as: "").id, "actor:Held")
        XCTAssertEqual(original.reidentified(as: "actor:Held"), original)
    }

    // MARK: - 🚨 The no-op assertions

    // P1 — on today's schema, resolving a legacy id returns the SAME string.
    // Phase 0 is shipped ahead of the re-keying on exactly this basis.
    func testResolutionIsIdentityOnTodaysSchema() {
        let ids = ["actor:Marta Venlowe", "studio:Big Studio",
                   "studio:Vol 2: The Return", "actor:X"]
        let resolver = NodeResolver(localIds: ids)
        for id in ids {
            XCTAssertEqual(resolver.localId(for: id), id,
                           "phase 0 must not change which node an id names")
        }
    }

    // P2 — parse-then-render round-trips for every id shape in the drive
    // library, including the one studio whose name contains a colon.
    func testEveryLiveIdShapeRoundTripsThroughTheIdentity() {
        for id in ["actor:Marta Venlowe", "studio:Big", "studio:Vol 2: The Return"] {
            XCTAssertEqual(NodeIdentity.parse(id)?.legacyId, id)
        }
    }

    // MARK: - 🚨 Surviving the re-key

    /// A library after v28: ids are uids, and the name lives only in the
    /// columns. Built by hand rather than by running the migration, so the
    /// resolver is tested against the SHAPE the re-key produces without
    /// depending on the re-key working.
    private func rekeyed(_ type: String, _ name: String,
                         uid: String) -> EntityProfile {
        EntityProfile(id: uid, entityType: type, displayName: name)
    }

    // K1 — 🚨 the defect this initialiser exists for. `init(localIds:)`
    // recovers identity by parsing the id, a uid has no colon, and the
    // "drop what cannot be parsed" rule then empties the ENTIRE index —
    // silently. The resolver reports a library with no nodes rather than
    // admitting it cannot see them, which is the failure mode phase 0 is
    // supposed to prevent, sitting inside phase 0's own entry point.
    func testTheIdBackedIndexGoesBlindAfterTheRekey() {
        let uid = UUID().uuidString
        let resolver = NodeResolver(localIds: [uid])

        XCTAssertEqual(resolver.indexedCount, 0)
        XCTAssertEqual(resolver.resolve("actor:Marta Venlowe"), .absent,
                       "every node is dropped, so everything looks merely absent")
    }

    // K2 — the profile-backed index reads the columns instead, so an incoming
    // LEGACY id still finds the re-keyed local node, and what comes back is
    // the LOCAL uid. This is the whole federation invariant across the re-key:
    // a sender's string is evidence, never the value written.
    func testAProfileBackedIndexResolvesALegacyIdToTheLocalUid() {
        let uid = UUID().uuidString
        let resolver = NodeResolver(profiles: [rekeyed("actor", "Marta Venlowe", uid: uid)])

        XCTAssertEqual(resolver.resolve("actor:Marta Venlowe"), .resolved(uid))
        XCTAssertEqual(resolver.indexedCount, 1)
    }

    // K3 — ⭐ the no-op assertion for the new initialiser, and the reason it
    // can ship before anything is re-keyed. On today's rows the two
    // initialisers agree exactly, because `type` and `name` prefer the stored
    // column and fall back to the id.
    func testBothInitialisersAgreeOnTodaysSchema() {
        let ids = ["actor:Marta Venlowe", "studio:Big Studio",
                   "studio:Vol 2: The Return", "actor:X"]
        let byId = NodeResolver(localIds: ids)
        let byProfile = NodeResolver(profiles: ids.map { EntityProfile(id: $0) })

        XCTAssertEqual(byProfile.indexedCount, byId.indexedCount)
        for id in ids {
            XCTAssertEqual(byProfile.localId(for: id), byId.localId(for: id),
                           "the profile-backed index must name the same node today")
        }
    }

    // K4 — ⚠️ the contested-key rule survives the change of initialiser. Two
    // re-keyed rows sharing a display name are two uids claiming one identity,
    // and neither may be handed out — D3's tag split creates exactly this.
    func testTwoRekeyedNodesSharingADisplayNameStayAmbiguous() {
        let resolver = NodeResolver(profiles: [
            rekeyed("tag", "SCUBA", uid: UUID().uuidString),
            rekeyed("tag", "Scuba", uid: UUID().uuidString),
        ])

        XCTAssertEqual(resolver.resolve("tag:scuba"), .ambiguous)
        XCTAssertEqual(resolver.contestedKeyCount, 1)
        XCTAssertEqual(resolver.indexedCount, 0)
    }

    // K5 — a re-keyed studio whose NAME contains a colon still resolves. The
    // id no longer carries the name, so the parse-on-first-colon hazard is
    // gone from the local side entirely — but the incoming legacy id still
    // has it, and that is the side that must keep working.
    func testARekeyedStudioWithAColonInItsNameStillResolves() {
        let uid = UUID().uuidString
        let resolver = NodeResolver(profiles: [rekeyed("studio", "Vol 2: The Return", uid: uid)])

        XCTAssertEqual(resolver.resolve("studio:Vol 2: The Return"), .resolved(uid))
    }

    // K6 — ⚠️ a profile with no discernible type is dropped, on the same
    // reasoning as an unparseable id: its kind cannot be compared without
    // guessing. Reachable only for a row that is both re-keyed and missing
    // `entity_type`, which is damage — but damage must not blind the resolver
    // to every other row, which is precisely K1's failure.
    func testATypelessProfileIsDroppedWithoutTakingTheIndexDown() {
        let uid = UUID().uuidString
        let resolver = NodeResolver(profiles: [
            EntityProfile(id: UUID().uuidString),
            rekeyed("actor", "Fine", uid: uid),
        ])

        XCTAssertEqual(resolver.resolve("actor:Fine"), .resolved(uid))
        XCTAssertEqual(resolver.indexedCount, 1)
    }

    // K7 — 🚨 the one row where reading COLUMNS could disagree with parsing the
    // ID. `"actor:"` has an empty half, so `NodeIdentity.parse` rejects it and
    // `init(localIds:)` drops it — but the v34 backfill (`WHERE instr(id, ':')
    // > 1`) gives it type `actor` and an empty display name, which the column
    // reader would happily index. Both must refuse it, or phase 0 stops being a
    // no-op on exactly the malformed row the resolver exists to exclude.
    func testAProfileWithAnEmptyNameIsRefusedByBothInitialisers() {
        let backfilled = EntityProfile(id: "actor:", entityType: "actor", displayName: "")

        XCTAssertEqual(NodeResolver(localIds: ["actor:"]).indexedCount, 0)
        XCTAssertEqual(NodeResolver(profiles: [backfilled]).indexedCount, 0)
    }

    // K8 — and one nameless row must not swallow the rest of the library, which
    // is how a single malformed profile would otherwise take the whole index
    // with it.
    func testANamelessProfileDoesNotContestARealIdentity() {
        let uid = UUID().uuidString
        let resolver = NodeResolver(profiles: [
            EntityProfile(id: "actor:", entityType: "actor", displayName: ""),
            rekeyed("actor", "Fine", uid: uid),
        ])

        XCTAssertEqual(resolver.resolve("actor:Fine"), .resolved(uid))
        XCTAssertEqual(resolver.contestedKeyCount, 0)
    }
}
