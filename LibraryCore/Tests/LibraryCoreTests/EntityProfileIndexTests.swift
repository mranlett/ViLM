// EntityProfileIndexTests.swift
// The read path's half of v28: finding a profile from a NAME.
//
// ⭐ The tests worth reading twice are N1–N3. Like every other piece of phase
// 0, this index is only safe to ship ahead of the re-keying because it changes
// nothing today — so "changes nothing" is asserted rather than argued.

import XCTest
@testable import LibraryCore

final class EntityProfileIndexTests: XCTestCase {

    /// A library BEFORE the re-key: the id encodes the name.
    private func legacy(_ id: String) -> EntityProfile { EntityProfile(id: id) }

    /// A library AFTER it: the id is a uid and the name lives in the columns.
    private func rekeyed(_ type: String, _ name: String,
                         uid: String = UUID().uuidString) -> EntityProfile {
        EntityProfile(id: uid, entityType: type, displayName: name)
    }

    // MARK: - 🚨 The no-op assertions

    // N1 — on today's rows, the index answers exactly what the old id-keyed
    // dictionary answered. This is the basis on which it ships before anything
    // is re-keyed.
    func testLookupMatchesTheOldDictionaryOnTodaysSchema() {
        let ids = ["actor:Marta Venlowe", "studio:Big Studio",
                   "studio:Vol 2: The Return", "tag:Scuba"]
        let old = Dictionary(uniqueKeysWithValues: ids.map { ($0, legacy($0)) })
        let index = EntityProfileIndex(ids.map(legacy))

        XCTAssertEqual(index[actor: "Marta Venlowe"]?.id, old["actor:Marta Venlowe"]?.id)
        XCTAssertEqual(index[studio: "Big Studio"]?.id, old["studio:Big Studio"]?.id)
        XCTAssertEqual(index[studio: "Vol 2: The Return"]?.id,
                       old["studio:Vol 2: The Return"]?.id,
                       "the colon-named studio must survive, as it does everywhere else")
        XCTAssertEqual(index.count, old.count)
    }

    // N2 — ⭐ the point of the whole type: the SAME call works after the
    // re-key, when the id can no longer answer it.
    func testTheSameLookupWorksAfterTheRekey() {
        let uid = UUID().uuidString
        let index = EntityProfileIndex([rekeyed("actor", "Marta Venlowe", uid: uid)])

        XCTAssertEqual(index[actor: "Marta Venlowe"]?.id, uid)
        XCTAssertNil(index[studio: "Marta Venlowe"],
                     "type-qualified: a studio of that name is a different node")
    }

    // N3 — the type axis is load-bearing. A bare display name collides across
    // actor, studio and tag, and the index holds all three at once.
    func testOneNameHeldByThreeTypesStaysThreeNodes() {
        let index = EntityProfileIndex([
            rekeyed("actor", "Pink"), rekeyed("studio", "Pink"), rekeyed("tag", "Pink"),  // hygiene:ok invented
        ])

        XCTAssertEqual(index.count, 3)
        let ids = Set([index[actor: "Pink"]?.id, index[studio: "Pink"]?.id,  // hygiene:ok invented — one word held by three types is the point
                       index[tag: "Pink"]?.id].compactMap { $0 })  // hygiene:ok invented — one word held by three types is the point
        XCTAssertEqual(ids.count, 3, "each type must answer with its own node")
        XCTAssertTrue(index.contestedIdentities.isEmpty, "different types never contest")
    }

    // MARK: - Grouping, which replaces prefix-testing an id

    // N4 — `ofType` is what the screens use instead of
    // `filter { $0.id.hasPrefix("actor:") }`, which returns nothing once the
    // id stops carrying the type.
    func testOfTypeGroupsWithoutInspectingTheId() {
        let index = EntityProfileIndex([
            rekeyed("actor", "One"), rekeyed("actor", "Two"), rekeyed("studio", "Three"),
        ])

        XCTAssertEqual(Set(index.actors.map(\.name)), ["One", "Two"])
        XCTAssertEqual(index.studios.map(\.name), ["Three"])
        XCTAssertTrue(index.tags.isEmpty)
        XCTAssertTrue(index.actors.allSatisfy { !$0.id.hasPrefix("actor:") },
                      "the fixture is re-keyed, so a prefix filter would have found none")
    }

    // MARK: - 🚨 Contested identities

    // N5 — two profiles sharing an identity do NOT blank the lookup. This is
    // where the index deliberately differs from NodeResolver: that guards
    // writes and refuses; this guards reads, and a blank row hides the very
    // duplicate the operator has to see in order to merge it.
    func testAContestedIdentityStillAnswersAndIsRecorded() {
        let index = EntityProfileIndex([
            rekeyed("actor", "Twin", uid: "uid-b"), rekeyed("actor", "Twin", uid: "uid-a"),
        ])

        XCTAssertNotNil(index[actor: "Twin"], "a read must not go blank on a duplicate")
        XCTAssertEqual(index.contestedIdentities.count, 1)
    }

    // N6 — ⚠️ and the winner is deterministic. Input order here is a database
    // read order; last-writer-wins would show a different profile from one
    // launch to the next for the same name.
    func testTheContestedWinnerDoesNotDependOnInputOrder() {
        let a = rekeyed("actor", "Twin", uid: "uid-a")
        let b = rekeyed("actor", "Twin", uid: "uid-b")

        // ⚠️ Asserts a REAL winner first. Comparing two optionals alone would
        // be satisfied by nil == nil — i.e. by an index that resolves nothing.
        let forward = EntityProfileIndex([a, b])[actor: "Twin"]?.id
        let reversed = EntityProfileIndex([b, a])[actor: "Twin"]?.id
        XCTAssertEqual(forward, "uid-a", "the lowest id is the stable winner")
        XCTAssertEqual(reversed, "uid-a")
    }

    // N7 — 🚨 a duplicate must not CRASH. The dictionary this replaces was
    // built with `Dictionary(uniqueKeysWithValues:)`, which traps on a repeated
    // key — safe only because ids are unique. Identity is not unique, so the
    // same construction would turn a data condition into a launch crash.
    func testADuplicateIdentityDoesNotTrap() {
        let index = EntityProfileIndex((0..<3).map { _ in rekeyed("actor", "Twin") })
        XCTAssertEqual(index.count, 3)
        XCTAssertNotNil(index[actor: "Twin"])
    }

    // MARK: - Damaged rows

    // N8 — a profile with no usable identity is still reachable by id rather
    // than dropped. An invisible damaged row cannot be repaired.
    func testATypelessProfileIsStillReachableById() {
        let uid = UUID().uuidString
        let index = EntityProfileIndex([EntityProfile(id: uid), rekeyed("actor", "Fine")])

        XCTAssertNotNil(index.profile(id: uid))
        XCTAssertEqual(index.count, 2)
        XCTAssertEqual(index.actors.count, 1)
    }

    // MARK: - 🚨 The cross-library fold

    // N9 — the multi-library view folds two libraries' copies of one performer
    // into one row, and keeps both halves of the data.
    func testTheMergedViewFoldsTwoLibrariesIntoOneProfile() {
        let primary = EntityProfile(id: "actor:Shared", bio: "from primary")
        let attached = EntityProfile(id: "actor:Shared", homePage: "https://example.com")

        let merged = EntityProfileIndex.merged(ordered: [[primary], [attached]])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[actor: "Shared"]?.bio, "from primary")
        XCTAssertEqual(merged[actor: "Shared"]?.homePage, "https://example.com")
    }

    // N10 — 🚨 the defect this fold exists to fix. After the re-key each
    // library mints its OWN uid for the same performer, so an id-keyed fold —
    // which is what `MergeSemantics.mergedProfileView(ordered:)` does — stops
    // matching them and shows the person TWICE, each copy missing what the
    // other held. Identity is the only key that crosses a library boundary.
    func testTwoLibrariesWithDifferentUidsForOnePersonStillFold() {
        let primary = EntityProfile(id: "uid-in-library-A", entityType: "actor",
                                    displayName: "Shared", bio: "from primary")
        let attached = EntityProfile(id: "uid-in-library-B", entityType: "actor",
                                     displayName: "Shared", homePage: "https://example.com")

        let idKeyed = MergeSemantics.mergedProfileView(ordered: [
            ["uid-in-library-A": primary], ["uid-in-library-B": attached],
        ])
        XCTAssertEqual(idKeyed.count, 2, "the id-keyed fold splits them — the defect")

        let merged = EntityProfileIndex.merged(ordered: [[primary], [attached]])
        XCTAssertEqual(merged.count, 1, "identity folds them back into one person")
        XCTAssertEqual(merged[actor: "Shared"]?.bio, "from primary")
        XCTAssertEqual(merged[actor: "Shared"]?.homePage, "https://example.com")
    }

    // N11 — precedence is preserved: the earlier layer wins a real conflict.
    //
    // 🚨 DIFFERENT uids per layer, deliberately. With one shared id an
    // id-keyed fold groups them too, so the test would pass against exactly
    // the defect N10 exists to catch.
    func testTheEarlierLayerWinsAConflict() {
        let primary = EntityProfile(id: "uid-A", entityType: "actor",
                                    displayName: "Shared", bio: "primary")
        let attached = EntityProfile(id: "uid-B", entityType: "actor",
                                     displayName: "Shared", bio: "attached")

        let merged = EntityProfileIndex.merged(ordered: [[primary], [attached]])

        XCTAssertEqual(merged[actor: "Shared"]?.bio, "primary")
    }
}
