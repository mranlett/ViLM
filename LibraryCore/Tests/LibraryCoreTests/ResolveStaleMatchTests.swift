// ResolveStaleMatchTests.swift
// Acting on a stale-match finding (#50 — U3, U4, U9–U12).
//
// 🚨 U11 and U12 exist because the spec contradicted itself and the review
// caught it: U4 wanted the edge and the columns removed together, Decision 3
// wanted the old source id kept — and the columns are where the id lives. The
// profile now clears completely and the history lives beside the finding, so
// both hold.

import XCTest
import GRDB
@testable import LibraryCore

final class ResolveStaleMatchTests: XCTestCase {

    private var url: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Resolve-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store = try LibraryStore(at: url)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: url)
    }

    /// A matched actor, exactly as `confirmEntityMatch` leaves one: edge AND
    /// columns.
    @discardableResult
    private func matchedActor(sourceId: String = "p-old") throws -> String {
        var p = EntityProfile(id: UUID().uuidString, entityType: "actor",
                              displayName: "Vera Example")
        p.enrichmentState = .matched
        p.enrichmentSourceId = sourceId
        p.enrichmentSource = "TheSource"
        try store.saveEntityProfile(p)
        try store.recordMatch(NodeMatch(nodeId: p.id, source: "TheSource",
                                        sourceId: sourceId, method: .name), isVideo: false)
        return p.id
    }

    private func edge(_ id: String) throws -> NodeMatch? {
        try store.matches(forEntity: id).first { $0.source == "TheSource" }
    }

    // MARK: - U9 — a merge is re-pointed, in one transaction

    func testU9AcceptingAMergeRePointsTheMatch() throws {
        let id = try matchedActor()
        try store.recordSourceState(.merged(into: "p-new"), nodeId: id,
                                    source: "TheSource", sourceId: "p-old", isVideo: false)

        try store.rePointMatch(nodeId: id, source: "TheSource", isVideo: false, to: "p-new")

        XCTAssertEqual(try edge(id)?.sourceId, "p-new")
        XCTAssertEqual(try store.fetchEntityProfile(for: id)?.enrichmentSourceId, "p-new",
                       "the profile's own column follows the edge")
        XCTAssertTrue(try store.staleMatchFindings().isEmpty, "the finding clears")
    }

    /// ⚠️ Still matched afterwards. Re-pointing is a correction, not a removal
    /// — the whole reason a merge must not be treated as a deletion.
    func testRePointingKeepsTheNodeMatched() throws {
        let id = try matchedActor()
        try store.recordSourceState(.merged(into: "p-new"), nodeId: id,
                                    source: "TheSource", sourceId: "p-old", isVideo: false)
        try store.rePointMatch(nodeId: id, source: "TheSource", isVideo: false, to: "p-new")

        XCTAssertEqual(try store.fetchEntityProfile(for: id)?.enrichmentState, .matched)
        XCTAssertNotNil(try edge(id))
    }

    // MARK: - U10 — refusing changes nothing

    func testU10RefusingLeavesTheFindingAndTheMatchAlone() throws {
        let id = try matchedActor()
        try store.recordSourceState(.merged(into: "p-new"), nodeId: id,
                                    source: "TheSource", sourceId: "p-old", isVideo: false)

        // The operator refuses: nothing is called.
        XCTAssertEqual(try store.staleMatchFindings().count, 1)
        XCTAssertEqual(try edge(id)?.sourceId, "p-old")
    }

    // MARK: - 🚨 U4 / U11 — clearing leaves nothing half-done

    func testU11ClearingRemovesTheEdgeAndTheColumnsTogether() throws {
        let id = try matchedActor()
        try store.recordSourceState(.deleted, nodeId: id, source: "TheSource", sourceId: "p-old", isVideo: false)

        try store.clearStaleMatch(nodeId: id, source: "TheSource", isVideo: false)

        XCTAssertNil(try edge(id), "no edge")
        let profile = try XCTUnwrap(try store.fetchEntityProfile(for: id))
        XCTAssertNil(profile.enrichmentSourceId, "and no columns")
        XCTAssertNil(profile.enrichmentState)
        XCTAssertTrue(try store.staleMatchFindings().isEmpty)
    }

    /// 🚨 The half-cleared state is what `Missing Identities` exists to find,
    /// and a repair tool must not manufacture one. A node claiming `matched`
    /// with no id and no edge is exactly that.
    func testU11bAClearedNodeIsNotLeftClaimingAMatchItCannotProduce() throws {
        let id = try matchedActor()
        try store.recordSourceState(.deleted, nodeId: id, source: "TheSource", sourceId: "p-old", isVideo: false)
        try store.clearStaleMatch(nodeId: id, source: "TheSource", isVideo: false)

        let stillClaiming = try store.fetchAllEntityProfiles().filter {
            $0.enrichmentState == .matched && ($0.enrichmentSourceId ?? "").isEmpty
        }
        XCTAssertTrue(stillClaiming.isEmpty)
    }

    // MARK: - 🚨 U12 — the deletion stays auditable

    /// Decision 3: discarding the old id makes the deletion unauditable —
    /// there would be no way to answer "what was this matched to, and when did
    /// it go", which is exactly the question someone will ask.
    func testU12TheAuditStillKnowsWhatItUsedToBe() throws {
        let id = try matchedActor(sourceId: "p-gone")
        try store.recordSourceState(.deleted, nodeId: id, source: "TheSource", sourceId: "p-gone", isVideo: false)
        try store.clearStaleMatch(nodeId: id, source: "TheSource", isVideo: false)

        let record = try XCTUnwrap(try store.resolvedStaleMatches().first)
        XCTAssertEqual(record.formerSourceId, "p-gone")
        XCTAssertEqual(record.outcome, .cleared)
        XCTAssertEqual(record.nodeId, id)
    }

    func testARePointIsRecordedWithWhatItLeft() throws {
        let id = try matchedActor(sourceId: "p-old")
        try store.recordSourceState(.merged(into: "p-new"), nodeId: id,
                                    source: "TheSource", sourceId: "p-old", isVideo: false)
        try store.rePointMatch(nodeId: id, source: "TheSource", isVideo: false, to: "p-new")

        let record = try XCTUnwrap(try store.resolvedStaleMatches().first)
        XCTAssertEqual(record.formerSourceId, "p-old")
        XCTAssertEqual(record.outcome, .rePointed)
    }

    // MARK: - 🚨 A finding says which table it came from

    /// Both asset ids and profile ids are UUID strings, so a caller that
    /// inferred the kind from the id would route every actor's finding to the
    /// video table — where it matches nothing, changes nothing, and reports
    /// success. The finding has to carry it.
    func testAFindingKnowsWhetherItIsAVideoOrAnEntity() throws {
        let actorId = try matchedActor()
        try store.recordSourceState(.deleted, nodeId: actorId, source: "TheSource",
                                    sourceId: "p-old", isVideo: false)

        let asset = Asset(relativePath: "\(UUID()).mp4", fileName: "v.mp4", tags: [])
        try store.insertAsset(asset)
        try store.recordMatch(NodeMatch(nodeId: asset.id.uuidString, source: "TheSource",
                                        sourceId: "v-1", method: .title), isVideo: true)
        try store.recordSourceState(.deleted, nodeId: asset.id.uuidString,
                                    source: "TheSource", sourceId: "v-1", isVideo: true)

        let found = try store.staleMatchFindings()
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found.first { $0.nodeId == actorId }?.isVideo, false)
        XCTAssertEqual(found.first { $0.nodeId == asset.id.uuidString }?.isVideo, true)
    }

    // MARK: - Scoping and safety

    /// ⚠️ One source only. Clearing a node's match in one provider must not
    /// discard an identity another provider established.
    func testClearingOneSourceLeavesAnotherIntact() throws {
        let id = try matchedActor()
        try store.recordMatch(NodeMatch(nodeId: id, source: "Elsewhere",
                                        sourceId: "x-1", method: .name), isVideo: false)

        try store.clearStaleMatch(nodeId: id, source: "TheSource", isVideo: false)

        XCTAssertEqual(try store.matches(forEntity: id).map(\.source), ["Elsewhere"])
    }

    func testResolvingAMatchThatDoesNotExistDoesNothing() throws {
        try store.clearStaleMatch(nodeId: UUID().uuidString, source: "TheSource",
                                  isVideo: false)
        XCTAssertTrue(try store.resolvedStaleMatches().isEmpty,
                      "no history for something that was never matched")
    }
}
