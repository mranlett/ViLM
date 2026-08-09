// EntityDisplayNameTests.swift
// Step 1 of retiring the id: the name becomes a field rather than a key.
//
// ⭐ CHARACTERIZATION FIRST. Every assertion below describes behaviour that is
// already true today, before the stored properties exist — so the seam can be
// added underneath and proven to change nothing. That is what makes it safe to
// touch `EntityProfile`, whose eight reconstruction sites have already cost
// this project one whole-graph data loss.
//
// 🚨 The ones that matter after the re-key are N5 and N6. Once `id` is an
// opaque uid it carries no name at all, and a name is not recoverable from a
// uid — so anything that drops it drops it permanently.

import XCTest
import GRDB
@testable import LibraryCore

final class EntityDisplayNameTests: XCTestCase {

    private var url: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DisplayName-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store = try LibraryStore(at: url)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Characterization: what is true today

    // N1 — a fresh profile knows its own name and type from its id.
    func testAFreshProfileReportsItsNameAndType() {
        let profile = EntityProfile(id: "actor:Marta Venlowe")
        XCTAssertEqual(profile.name, "Marta Venlowe")
        XCTAssertEqual(profile.type, "actor")
    }

    // N2 — a name containing a colon is not truncated.
    func testANameContainingAColonSurvives() {
        XCTAssertEqual(EntityProfile(id: "studio:Vol 2: The Return").name,
                       "Vol 2: The Return")
    }

    // N3 — an id this scheme cannot read falls back to the id itself rather
    // than to an empty label. A blank row is unfindable and unfixable.
    func testAnUnreadableIdFallsBackToTheIdItself() {
        let profile = EntityProfile(id: "no-colon")
        XCTAssertEqual(profile.name, "no-colon")
        XCTAssertNil(profile.type)
    }

    // N4 — the name survives a database round trip.
    func testTheNameSurvivesARoundTrip() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Marta Venlowe", bio: "kept"))
        let loaded = try XCTUnwrap(try store.fetchEntityProfile(for: "actor:Marta Venlowe"))
        XCTAssertEqual(loaded.name, "Marta Venlowe")
        XCTAssertEqual(loaded.bio, "kept")
    }

    // MARK: - 🚨 What must be true AFTER the re-key

    // N5 — a profile whose id is an opaque uid still knows its name, because
    // the name is now stored rather than derived.
    func testAProfileKeyedByAUidStillKnowsItsName() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Marta Venlowe"))
        let plan = try store.rekeyPlan()
        try store.rekeyMintUids(plan)
        _ = try store.rekeyCommit(plan)
        let uid = try XCTUnwrap(plan.uidByOldId["actor:Marta Venlowe"])

        let loaded = try XCTUnwrap(try store.fetchEntityProfile(for: uid))
        XCTAssertEqual(loaded.name, "Marta Venlowe",
                       "the name is not recoverable from a uid — it must be stored")
        XCTAssertEqual(loaded.type, "actor")
    }

    // N6 — 🚨 and re-keying a profile in memory carries the name across.
    // `reidentified(as:)` is what the federation boundary uses; if it dropped
    // the name, every arriving profile would land nameless.
    func testReidentifyingCarriesTheNameToTheNewKey() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Jane"))
        let loaded = try XCTUnwrap(try store.fetchEntityProfile(for: "actor:Jane"))

        let moved = loaded.reidentified(as: "some-opaque-uid")
        XCTAssertEqual(moved.id, "some-opaque-uid")
        XCTAssertEqual(moved.name, "Jane", "the name must not be left behind with the key")
        XCTAssertEqual(moved.type, "actor")
    }

    // N7 — an edit after the re-key does not blank the name, and the edit lands.
    func testAnEditAfterTheRekeyKeepsBothTheNameAndTheEdit() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Jane"))
        let plan = try store.rekeyPlan()
        try store.rekeyMintUids(plan)
        _ = try store.rekeyCommit(plan)
        let uid = try XCTUnwrap(plan.uidByOldId["actor:Jane"])

        var profile = try XCTUnwrap(try store.fetchEntityProfile(for: uid))
        profile.bio = "edited"
        try store.saveEntityProfile(profile)

        let after = try XCTUnwrap(try store.fetchEntityProfile(for: uid))
        XCTAssertEqual(after.name, "Jane")
        XCTAssertEqual(after.bio, "edited")
    }

    // MARK: - The seam holds its shape

    // N8 — ⚠️ a stored name WINS over one derived from the id. That is the
    // whole point: after the re-key there is nothing to derive from, and
    // before it the two agree, so preferring the stored value is safe now and
    // required later.
    func testAStoredNameWinsOverADerivedOne() {
        let profile = EntityProfile(id: "actor:Old Spelling",
                                    entityType: "actor", displayName: "New Spelling")
        XCTAssertEqual(profile.name, "New Spelling")
    }

    // N9 — a profile built the ordinary way still works, so no existing call
    // site had to change. The eight reconstruction sites are why.
    func testTheOrdinaryInitialiserIsUnchanged() {
        let profile = EntityProfile(id: "actor:Jane", bio: "b", birthYear: 1990)
        XCTAssertEqual(profile.name, "Jane")
        XCTAssertEqual(profile.bio, "b")
        XCTAssertEqual(profile.birthYear, 1990)
    }

    // N10 — JSON round trip, which is how a profile travels between libraries.
    func testTheNameSurvivesAFileRoundTrip() throws {
        let original = EntityProfile(id: "actor:Jane",
                                     entityType: "actor", displayName: "Jane")
        let decoded = try JSONDecoder().decode(
            EntityProfile.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.name, "Jane")
        XCTAssertEqual(decoded.id, "actor:Jane")
    }

    // N11 — ⚠️ an export written BEFORE these fields existed still decodes,
    // and derives the name from the id exactly as it always did.
    func testAnOlderExportWithoutTheFieldsStillDecodes() throws {
        let json = #"{"id":"actor:Jane","bio":"old file"}"#
        let decoded = try JSONDecoder().decode(
            EntityProfile.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.name, "Jane", "derived, because the file predates the field")
        XCTAssertEqual(decoded.bio, "old file")
    }
}

// MARK: - 🚨 Step 1b — every rebuild carries the name once ids stop encoding it

/// The sites the tripwire names, each exercised with a UID-shaped key.
///
/// ⚠️ These would ALL have passed before step 1b, because the id still encoded
/// the name and the initialiser derived it. Passing a uid is the only way to
/// tell a site that carries the name from one that merely re-derives it — and
/// after the re-key, re-deriving yields nothing.
extension EntityDisplayNameTests {

    private var uid: String { "8B0C5E62-0000-4000-8000-000000000001" }

    private func named(_ name: String, id: String) -> EntityProfile {
        EntityProfile(id: id, entityType: "actor", displayName: name)
    }

    // 1b-1 — `renamed(to:)` onto a uid keeps the name it cannot read.
    func testRenamingOntoAUidKeepsTheName() {
        let moved = named("Jane", id: "actor:Jane").renamed(to: uid)
        XCTAssertEqual(moved.id, uid)
        XCTAssertEqual(moved.name, "Jane")
        XCTAssertEqual(moved.type, "actor")
    }

    // 1b-2 — ...and a rename that DOES encode a name still adopts the new one.
    func testRenamingOntoANameStillAdoptsIt() {
        let moved = named("Jane", id: "actor:Jane").renamed(to: "actor:Jane Doe")
        XCTAssertEqual(moved.name, "Jane Doe")
    }

    // 1b-3 — the two-library overlay keeps the name.
    func testTheOverlayKeepsTheName() {
        let merged = MergeSemantics.mergedProfileView(
            ordered: [[uid: named("Jane", id: uid)],
                      [uid: EntityProfile(id: uid, bio: "from the other library")]])
        XCTAssertEqual(merged[uid]?.name, "Jane")
    }

    // 1b-4 — accepting a lookup does not rename the node.
    func testAcceptingALookupKeepsTheStoredName() {
        let applied = ActorEnrichment.apply(
            ActorMetadataProposal(), to: named("Jane", id: uid),
            entityId: uid, accepting: [])
        XCTAssertEqual(applied.name, "Jane",
                       "a lookup fills fields in; it must not rename anyone")
    }

    // 1b-5 — 🚨 the CSV round trip. Its Name column is the authority, so a
    // uid-keyed row still comes back named.
    func testTheCSVCarriesTheNameEvenForAUidKeyedRecord() {
        let line = ActorCSV.row(name: "Jane", profile: named("Jane", id: uid),
                                stripCountry: { $0 })
        guard let columns = ActorCSV.parse(line).first,
              let back = ActorCSV.merge(columns: columns, existing: nil,
                                        decorateCountry: { $0 }) else {
            return XCTFail("row did not round-trip")
        }
        XCTAssertEqual(back.name, "Jane")
    }
}
