// FetchProfileByNameTests.swift
// The store lookup that survives the re-key.

import XCTest
@testable import LibraryCore

final class FetchProfileByNameTests: XCTestCase {

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

    // ⭐ The no-op assertion: on today's rows it answers exactly what the
    // id-keyed read answers.
    func testAgreesWithTheIdLookupOnTodaysSchema() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Marta Venlowe", bio: "held"))

        let byId = try store.fetchEntityProfile(for: "actor:Marta Venlowe")
        let byName = try store.fetchEntityProfile(named: "Marta Venlowe", type: "actor")

        XCTAssertEqual(byName?.id, byId?.id)
        XCTAssertEqual(byName?.bio, "held")
    }

    // 🚨 And it keeps working when the id no longer carries the name.
    func testFindsARekeyedProfileTheIdLookupCouldNotReach() throws {
        let uid = UUID().uuidString
        try store.saveEntityProfile(EntityProfile(id: uid, entityType: "actor",
                                                  displayName: "Marta Venlowe"))

        XCTAssertNil(try store.fetchEntityProfile(for: "actor:Marta Venlowe"),
                     "the legacy id is exactly what stops resolving")
        XCTAssertEqual(try store.fetchEntityProfile(named: "Marta Venlowe", type: "actor")?.id, uid)
    }

    // ⚠️ Type-qualified: one name held by two kinds is two nodes.
    func testTheTypeAxisSeparatesTwoNodesOfOneName() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Pink"))
        try store.saveEntityProfile(EntityProfile(id: "studio:Pink"))

        XCTAssertEqual(try store.fetchEntityProfile(named: "Pink", type: "actor")?.id, "actor:Pink")
        XCTAssertEqual(try store.fetchEntityProfile(named: "Pink", type: "studio")?.id, "studio:Pink")
    }

    // A studio whose NAME contains a colon still resolves — the case that
    // breaks any implementation that splits an id on the last colon.
    func testAColonInTheNameIsNotAProblem() throws {
        try store.saveEntityProfile(EntityProfile(id: "studio:Vol 2: The Return"))

        XCTAssertEqual(try store.fetchEntityProfile(named: "Vol 2: The Return", type: "studio")?.id,
                       "studio:Vol 2: The Return")
    }

    // MARK: - resolveActorAKA

    func testAnAliasResolvesToItsOwnersName() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Marta Venlowe",
                                                  akas: ["Marti V"]))

        XCTAssertEqual(try store.resolveActorAKA(for: "Marti V"), "Marta Venlowe")
    }

    // 🚨 And after the re-key, when the id carries no name at all.
    func testAnAliasStillResolvesWhenTheIdIsAUid() throws {
        let uid = UUID().uuidString
        try store.saveEntityProfile(EntityProfile(id: uid, entityType: "actor",
                                                  displayName: "Marta Venlowe",
                                                  akas: ["Marti V"]))

        XCTAssertEqual(try store.resolveActorAKA(for: "Marti V"), "Marta Venlowe")
    }

    // ⚠️ Only ACTORS own aliases. A studio listing the same string must not
    // capture it — the old prefix test is what kept them apart.
    func testAStudioAliasDoesNotClaimAnActorName() throws {
        try store.saveEntityProfile(EntityProfile(id: UUID().uuidString,
                                                  entityType: "studio",
                                                  displayName: "Some Studio",
                                                  akas: ["Marti V"]))

        XCTAssertEqual(try store.resolveActorAKA(for: "Marti V"), "Marti V",
                       "unresolved names come back unchanged")
    }

    // MARK: - entityId(named:type:)

    // The id-only form, which is what the edge writers take.
    func testEntityIdAnswersTheLocalIdForAName() throws {
        try store.saveEntityProfile(EntityProfile(id: "studio:Silver River"))

        XCTAssertEqual(try store.entityId(named: "Silver River", type: "studio"),
                       "studio:Silver River")
        XCTAssertNil(try store.entityId(named: "Silver River", type: "actor"),
                     "type-qualified")
        XCTAssertNil(try store.entityId(named: "Nobody", type: "studio"))
    }

    // ⭐ And it keeps answering once the key is a uid — this is the whole
    // reason the hierarchy writers go through it.
    func testEntityIdResolvesARekeyedNodeToItsUid() throws {
        let uid = UUID().uuidString
        try store.saveEntityProfile(EntityProfile(id: uid, entityType: "studio",
                                                  displayName: "Silver River"))

        XCTAssertEqual(try store.entityId(named: "Silver River", type: "studio"), uid)
    }

    // ⚠️ Never mints. A caller wanting a row to exist says so explicitly.
    func testEntityIdDoesNotCreateAnything() throws {
        XCTAssertNil(try store.entityId(named: "Nobody", type: "studio"))
        XCTAssertTrue(try store.fetchAllEntityProfiles().isEmpty)
    }

    func testAnEmptyNameOrTypeFindsNothingRatherThanTheFirstRow() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Someone"))

        XCTAssertNil(try store.fetchEntityProfile(named: "", type: "actor"))
        XCTAssertNil(try store.fetchEntityProfile(named: "Someone", type: ""))
    }
}
