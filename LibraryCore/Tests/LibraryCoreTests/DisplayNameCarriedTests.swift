// DisplayNameCarriedTests.swift
// Names that must be CARRIED rather than sliced out of an id.
//
// 🚨 Every fixture here is uid-keyed on purpose. A legacy `studio:Name` id
// still encodes its name, so it silently exercises the string-slicing fallback
// and proves nothing about the path that has to work after the re-key.

import XCTest
@testable import LibraryCore

final class DisplayNameCarriedTests: XCTestCase {

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
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - entityNamesById

    func testNamesAreReadForOneTypeOnly() throws {
        let studioUid = UUID().uuidString
        try store.saveEntityProfile(EntityProfile(id: studioUid, entityType: "studio",
                                                  displayName: "Silver River"))
        try store.saveEntityProfile(EntityProfile(id: UUID().uuidString, entityType: "actor",
                                                  displayName: "Marta Venlowe"))

        let names = try store.entityNamesById(ofType: "studio")

        XCTAssertEqual(names, [studioUid: "Silver River"])
    }

    /// ⚠️ A row with no name answers with its id rather than vanishing — an
    /// invisible damaged studio cannot be repaired.
    func testANamelessRowStillAnswers() throws {
        let uid = UUID().uuidString
        try store.saveEntityProfile(EntityProfile(id: uid, entityType: "studio",
                                                  displayName: ""))

        XCTAssertEqual(try store.entityNamesById(ofType: "studio")[uid], uid)
    }

    // MARK: - StudioLineage

    // 🚨 The lineage view files studios under these strings and a pivot filters
    // on them, so a uid here shows a UUID on screen and matches no videos.
    func testLineageUsesSuppliedNamesRatherThanTheId() {
        let network = UUID().uuidString
        let imprint = UUID().uuidString
        let sibling = UUID().uuidString

        let lineage = StudioLineage.build(
            for: imprint,
            pairs: [GraphEdgePair(from: imprint, to: network),
                    GraphEdgePair(from: sibling, to: network)],
            videoCounts: [imprint: 3, sibling: 5],
            names: [network: "Silver Network", imprint: "Silver River",
                    sibling: "Silver Creek"])

        XCTAssertEqual(lineage.parent?.name, "Silver Network")
        XCTAssertEqual(lineage.siblings.map(\.name), ["Silver Creek"])
    }

    // ⚠️ And without a name map it falls back to the id — honest, never blank,
    // but this is what the callers must not rely on after the re-key.
    func testLineageFallsBackToTheIdWhenNoNamesAreGiven() {
        let network = UUID().uuidString
        let imprint = UUID().uuidString

        let lineage = StudioLineage.build(
            for: imprint,
            pairs: [GraphEdgePair(from: imprint, to: network)],
            videoCounts: [:])

        XCTAssertEqual(lineage.parent?.name, network)
    }

    // MARK: - ActorSyncPlan

    // 🚨 The sync screen lists each plan under this string and asks the
    // operator to approve them one at a time. Derived from the id, every row
    // would read as a UUID.
    func testASyncPlanCarriesTheActorsName() {
        let uid = UUID().uuidString
        let plan = ActorSyncPlan(actorId: uid, displayName: "Marta Venlowe",
                                 missingFrom: [], deletionFrom: [],
                                 blankFills: [:], photoAdds: [:],
                                 listAdds: [:], conflicts: [])

        XCTAssertEqual(plan.displayName, "Marta Venlowe")
        XCTAssertEqual(plan.id, uid, "the id is still the identity")
    }

    // MARK: - The store supplies them

    func testTheStoreHandsTheLineageRealNames() throws {
        let network = UUID().uuidString
        let imprint = UUID().uuidString
        try store.saveEntityProfile(EntityProfile(id: network, entityType: "studio",
                                                  displayName: "Silver Network"))
        try store.saveEntityProfile(EntityProfile(id: imprint, entityType: "studio",
                                                  displayName: "Silver River"))
        try store.setStudioParent(network, forStudio: imprint)

        let lineage = try store.studioLineage(for: imprint)

        XCTAssertEqual(lineage.parent?.name, "Silver Network",
                       "a uid on screen means the store stopped supplying names")
    }
}
