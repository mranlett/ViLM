// SyncBoundaryTests.swift
// The merge end of phase 0: what `applyGraphMerge` refuses, and what it counts.
//
// 🚨 The invariant under test, stated once:
//
//     NO STRING FROM A PAYLOAD IS EVER WRITTEN TO A KEY COLUMN.
//
// Before this, every incoming reference was gated on `known.contains(id)` and
// then written verbatim — correct only while both libraries derive the same key
// from the same name, which stops being true the moment either is re-keyed.

import XCTest
@testable import LibraryCore

final class SyncBoundaryTests: XCTestCase {

    private var url: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncBoundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store = try LibraryStore(at: url)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: url)
    }

    /// An export carrying only what a given test needs.
    private func export(studios: [EntityProfile] = [],
                        performerTags: [GraphEdgePair] = [],
                        studioParents: [StudioParentEdge] = [],
                        entityMatches: [NodeMatch] = []) -> ActorLibraryExport {
        var e = ActorLibraryExport(formatVersion: 1, exportedAt: Date(),
                                   profiles: [], photos: [])
        e.studios = studios
        e.performerTags = performerTags
        e.studioParents = studioParents
        e.entityMatches = entityMatches
        return e
    }

    // MARK: - Refusals are counted, not silent

    // B1 — an edge naming a performer this library does not hold is skipped
    // AND counted. Silently dropping it is the failure mode phase 0 exists to
    // end: a sync that discards edges looks exactly like one with nothing to do.
    func testAnEdgeNamingAnAbsentNodeIsSkippedAndCounted() throws {
        let result = try store.applyGraphMerge(
            export(performerTags: [GraphEdgePair(from: "actor:Nobody", to: "blonde")]))

        XCTAssertEqual(result.newPerformerTags, 0)
        XCTAssertEqual(result.integrity.absentNodes, 1)
        XCTAssertEqual(result.integrity.skippedEdges, 1)
        XCTAssertFalse(result.integrity.isClean)
        // ⚠️ Ordinary, not a defect — the two libraries simply differ.
        XCTAssertFalse(result.integrity.hasStructuralProblem)
    }

    // B2 — 🚨 a malformed id is counted APART from an absent one, because it
    // means the sender is emitting something this build cannot read.
    func testAMalformedIdIsReportedAsAStructuralProblem() throws {
        let result = try store.applyGraphMerge(
            export(studios: [EntityProfile(id: "no-colon-here")]))

        XCTAssertEqual(result.newStudios, 0)
        XCTAssertEqual(result.integrity.unparseableIds, 1)
        XCTAssertTrue(result.integrity.hasStructuralProblem)
        // And nothing was minted from it.
        XCTAssertTrue(try store.fetchAllEntityProfiles().isEmpty)
    }

    // B3 — 🚨 the headline invariant. A match edge for a node this library
    // does not hold must not be written, because `entity_match.entity_id`
    // would then reference nothing.
    func testAMatchEdgeForAnAbsentNodeIsNeverWritten() throws {
        let result = try store.applyGraphMerge(export(entityMatches: [
            NodeMatch(nodeId: "actor:Nobody", source: "Example Source",
                      sourceId: "abc", method: .operator)
        ]))

        XCTAssertEqual(result.newMatches, 0)
        XCTAssertEqual(result.integrity.skippedEdges, 1)
        XCTAssertTrue(try store.allEntityMatches().isEmpty)
    }

    // B4 — a match edge for a node this library DOES hold lands, keyed to the
    // local node.
    func testAMatchEdgeForAKnownNodeIsWrittenUnderTheLocalId() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Held"))
        let result = try store.applyGraphMerge(export(entityMatches: [
            NodeMatch(nodeId: "actor:Held", source: "Example Source",
                      sourceId: "abc", method: .operator)
        ]))

        XCTAssertEqual(result.newMatches, 1)
        XCTAssertEqual(try store.allEntityMatches().first?.nodeId, "actor:Held")
        XCTAssertTrue(result.integrity.isClean)
    }

    // B5 — a hierarchy naming a network this library does not hold is refused
    // rather than written as a dangling parent, which the Studio Health audit
    // would then report forever.
    func testAHierarchyNamingAnAbsentParentIsRefused() throws {
        try store.saveEntityProfile(EntityProfile(id: "studio:Imprint"))
        let result = try store.applyGraphMerge(export(studioParents: [
            StudioParentEdge(from: "studio:Imprint", to: "studio:Unknown Network")
        ]))

        XCTAssertEqual(result.newStudioParents, 0)
        XCTAssertNil(try store.parentStudioId(of: "studio:Imprint"))
    }

    // B6 — ⚠️ a FORMER parent resolves too. Historical rows are excluded from
    // the current-set audits, so an unresolvable one written here would never
    // be reported by anything.
    func testAFormerParentNamingAnAbsentNetworkIsRefused() throws {
        try store.saveEntityProfile(EntityProfile(id: "studio:Imprint"))
        let result = try store.applyGraphMerge(export(studioParents: [
            StudioParentEdge(from: "studio:Imprint", to: "studio:Gone",
                             validFrom: "2010", validTo: "2015")
        ]))

        XCTAssertEqual(result.newStudioParentPeriods, 0)
        XCTAssertEqual(result.integrity.skippedEdges, 1)
        XCTAssertTrue(try store.studioParentHistory(of: "studio:Imprint").isEmpty)
    }

    // MARK: - Minting

    // B7 — an absent studio IS minted, under an id this library derives.
    // Today the same string; after v28 the line that stops a foreign uid
    // becoming a local primary key.
    func testAnAbsentStudioIsMintedUnderALocallyDerivedId() throws {
        let result = try store.applyGraphMerge(
            export(studios: [EntityProfile(id: "studio:New Studio")]))

        XCTAssertEqual(result.newStudios, 1)
        let saved = try store.fetchEntityProfile(for: "studio:New Studio")
        XCTAssertNotNil(saved)
        XCTAssertEqual(saved?.id, NodeIdentity.parse("studio:New Studio")?.legacyId)
    }

    // B8 — ⚠️ two arrivals naming one studio mint it ONCE. Without re-indexing
    // after a mint, the second resolves as absent and mints a duplicate.
    func testTheSameStudioArrivingTwiceIsMintedOnce() throws {
        let result = try store.applyGraphMerge(export(studios: [
            EntityProfile(id: "studio:Repeated"),
            EntityProfile(id: "studio:Repeated")
        ]))

        XCTAssertEqual(result.newStudios, 1)
        XCTAssertEqual(try store.fetchAllEntityProfiles()
            .filter { $0.id == "studio:Repeated" }.count, 1)
    }

    // B9 — a studio whose NAME contains a colon survives the round trip. The
    // drive library holds one, carrying a real edge.
    func testAStudioNameContainingAColonIsMintedIntact() throws {
        let result = try store.applyGraphMerge(
            export(studios: [EntityProfile(id: "studio:Vol 2: The Return")]))

        XCTAssertEqual(result.newStudios, 1)
        XCTAssertNotNil(try store.fetchEntityProfile(for: "studio:Vol 2: The Return"))
    }

    // MARK: - 🚨 The no-op assertion

    // B10 — a perfectly ordinary sync between two same-shaped libraries is
    // completely clean. If phase 0 ever starts refusing normal traffic, this
    // is what fails.
    func testAnOrdinarySyncRefusesNothing() throws {
        try store.saveEntityProfile(EntityProfile(id: "studio:Network"))
        try store.saveEntityProfile(EntityProfile(id: "studio:Imprint"))

        let result = try store.applyGraphMerge(export(
            studios: [EntityProfile(id: "studio:Network")],
            studioParents: [StudioParentEdge(from: "studio:Imprint", to: "studio:Network")]))

        XCTAssertEqual(result.newStudioParents, 1)
        XCTAssertEqual(try store.parentStudioId(of: "studio:Imprint"), "studio:Network")
        XCTAssertTrue(result.integrity.isClean,
                      "phase 0 must refuse nothing in an ordinary sync")
    }

    // B11 — the merge is idempotent: running it twice changes nothing the
    // second time and still refuses nothing.
    func testASecondIdenticalMergeIsAClearNoOp() throws {
        try store.saveEntityProfile(EntityProfile(id: "studio:Imprint"))
        let payload = export(studios: [EntityProfile(id: "studio:Network")],
                             studioParents: [StudioParentEdge(from: "studio:Imprint",
                                                              to: "studio:Network")])
        _ = try store.applyGraphMerge(payload)
        let second = try store.applyGraphMerge(payload)

        XCTAssertFalse(second.changedAnything)
        XCTAssertTrue(second.integrity.isClean)
    }
}
