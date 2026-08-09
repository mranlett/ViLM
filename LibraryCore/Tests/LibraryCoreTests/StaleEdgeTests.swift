// StaleEdgeTests.swift
// Edges the tag strings no longer support, and removing them.
//
// 🚨 The condition the verification could DETECT and nothing could REPAIR.
// Connecting is `INSERT OR IGNORE` only, so once a cast changed the old edge
// stayed forever and re-running the tool could never converge. Reported from
// the device 2026-08-08 — where re-fetching the cast took the count from one
// video to two, because that is what an additive-only tool does.

import XCTest
@testable import LibraryCore

final class StaleEdgeTests: XCTestCase {

    private var url: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Stale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store = try LibraryStore(at: url)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    private func video(_ tags: [String]) throws -> UUID {
        let asset = Asset(relativePath: "v-\(UUID().uuidString).mp4",
                          fileName: "v.mp4", tags: tags)
        try store.insertAsset(asset)
        return asset.id
    }

    // MARK: - 🚨 The edge's kind is carried, not inferred

    /// The remover used to decide which table to DELETE from by testing
    /// `nodeId.hasPrefix("studio:")`. That is undecidable once an id is a uid:
    /// every studio edge would be taken for a performer edge, the DELETE would
    /// match nothing, and the screen whose entire purpose is removing these
    /// would silently do nothing while reporting success.
    func testAStaleEdgeRecordsWhichTableItCameFrom() throws {
        let videoId = try video(["actor:Kept", "studio:Kept Studio"])
        try store.saveEntityProfile(EntityProfile(id: "actor:Dropped"))
        try store.saveEntityProfile(EntityProfile(id: "studio:Dropped Studio"))
        try store.linkPerformer("actor:Dropped", toVideo: videoId)
        try store.setStudio("studio:Dropped Studio", forVideo: videoId)

        let stale = try store.staleEdges()

        XCTAssertEqual(stale.first(where: { $0.nodeId == "actor:Dropped" })?.kind, .actor)
        XCTAssertEqual(stale.first(where: { $0.nodeId == "studio:Dropped Studio" })?.kind,
                       .studio)
    }

    /// ⭐ And the removal itself works on a node whose id carries NO type —
    /// the shape every id takes after the re-key. Inferring from the string
    /// would delete from the wrong table and leave the edge in place.
    func testAStaleEdgeOnAUidKeyedNodeIsActuallyRemoved() throws {
        let studioUid = UUID().uuidString
        let videoId = try video(["studio:Kept Studio"])
        try store.saveEntityProfile(EntityProfile(id: studioUid, entityType: "studio",
                                                  displayName: "Dropped Studio"))
        try store.setStudio(studioUid, forVideo: videoId)

        let stale = try store.staleEdges().filter { $0.nodeId == studioUid }
        XCTAssertEqual(stale.count, 1, "the edge disagrees with the video's strings")
        XCTAssertEqual(stale.first?.kind, .studio,
                       "a uid says nothing about its kind — it must be carried")

        _ = try store.pruneStaleEdges(stale)

        XCTAssertNil(try store.studioId(forVideo: videoId),
                     "inferring the table from the id would have deleted nothing")
    }

    // S1 — the reproduction: connect, then the cast changes, and the old edge
    // is left behind with nothing able to remove it.
    func testAnEdgeLeftBehindByACastChangeIsFound() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Kept"))
        try store.saveEntityProfile(EntityProfile(id: "actor:Removed"))
        let v = try video(["actor:Kept", "actor:Removed"])
        _ = try store.connectPerformerEdges()

        // The operator edits the cast — "Removed" is not in this video.
        var asset = try XCTUnwrap(try store.fetchAllAssets().first { $0.id == v })
        asset.tags = ["actor:Kept"]
        try store.updateAsset(asset)

        // ⚠️ Re-running the tool cannot fix it: connecting only inserts.
        _ = try store.connectPerformerEdges()
        XCTAssertEqual(try store.performerEdgeDisagreements(), [v],
                       "still disagreeing after a re-run — that is the defect")

        let stale = try store.staleEdges()
        XCTAssertEqual(stale.map(\.nodeId), ["actor:Removed"])
        XCTAssertTrue(stale[0].videoNamesOthers, "the video still names its remaining cast")
    }

    // S2 — pruning closes the disagreement, which nothing else could do.
    func testPruningClosesTheDisagreement() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Kept"))
        try store.saveEntityProfile(EntityProfile(id: "actor:Removed"))
        let v = try video(["actor:Kept", "actor:Removed"])
        _ = try store.connectPerformerEdges()

        var asset = try XCTUnwrap(try store.fetchAllAssets().first { $0.id == v })
        asset.tags = ["actor:Kept"]
        try store.updateAsset(asset)

        XCTAssertEqual(try store.pruneStaleEdges(try store.staleEdges()), 1)
        XCTAssertEqual(try store.performerEdgeDisagreements(), [])
        XCTAssertEqual(try store.performerIds(forVideo: v), ["actor:Kept"],
                       "and the remaining cast is untouched")
    }

    // S3 — 🚨 an edge on a video naming NOBODY is flagged differently. The
    // strings may be missing rather than the edge wrong, and deleting on that
    // basis would destroy the only record of who is in the video.
    func testAnEdgeOnAVideoWithNoCastStringsIsMarkedAsSuch() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Only"))
        let v = try video(["actor:Only"])
        _ = try store.connectPerformerEdges()

        var asset = try XCTUnwrap(try store.fetchAllAssets().first { $0.id == v })
        asset.tags = []
        try store.updateAsset(asset)

        let stale = try store.staleEdges()
        XCTAssertEqual(stale.count, 1)
        XCTAssertFalse(stale[0].videoNamesOthers,
                       "nothing else names a performer — this needs a person, not a sweep")
    }

    // S4 — a healthy library reports nothing.
    func testAnAgreeingLibraryHasNoStaleEdges() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Fine"))
        try video(["actor:Fine"])
        _ = try store.connectPerformerEdges()

        XCTAssertTrue(try store.staleEdges().isEmpty)
        XCTAssertTrue(try store.performerEdgeDisagreements().isEmpty)
    }

    // S5 — studio edges go stale by the same mechanism and are found too.
    func testAStaleStudioEdgeIsFound() throws {
        try store.saveEntityProfile(EntityProfile(id: "studio:Old"))
        try store.saveEntityProfile(EntityProfile(id: "studio:New"))
        let v = try video(["studio:Old"])
        _ = try store.connectStudioEdges()

        var asset = try XCTUnwrap(try store.fetchAllAssets().first { $0.id == v })
        asset.tags = ["studio:New"]
        try store.updateAsset(asset)

        XCTAssertEqual(try store.staleEdges().map(\.nodeId), ["studio:Old"])
        XCTAssertEqual(try store.pruneStaleEdges(try store.staleEdges()), 1)
        XCTAssertNil(try store.studioId(forVideo: v))
    }

    // S6 — ⭐ pruning removes EXACTLY what it was given, not what a fresh scan
    // would decide. The operator approves a list; something else being deleted
    // is not a defensible outcome for a destructive action.
    func testPruningRemovesOnlyTheEdgesItWasGiven() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:A"))
        try store.saveEntityProfile(EntityProfile(id: "actor:B"))
        let v1 = try video(["actor:A"])
        let v2 = try video(["actor:B"])
        _ = try store.connectPerformerEdges()

        for id in [v1, v2] {
            var asset = try XCTUnwrap(try store.fetchAllAssets().first { $0.id == id })
            asset.tags = []
            try store.updateAsset(asset)
        }

        let all = try store.staleEdges()
        XCTAssertEqual(all.count, 2)
        let one = all.filter { $0.videoId == v1 }
        XCTAssertEqual(try store.pruneStaleEdges(one), 1)
        XCTAssertEqual(try store.performerIds(forVideo: v1), [])
        XCTAssertEqual(try store.performerIds(forVideo: v2), ["actor:B"],
                       "the edge that was not approved is untouched")
    }

    // S7 — pruning nothing is a clean no-op.
    func testPruningAnEmptyListDoesNothing() throws {
        XCTAssertEqual(try store.pruneStaleEdges([]), 0)
    }

    // S8 — running the prune twice is safe; the second finds nothing to do.
    func testPruningIsIdempotent() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Gone"))
        let v = try video(["actor:Gone"])
        _ = try store.connectPerformerEdges()
        var asset = try XCTUnwrap(try store.fetchAllAssets().first { $0.id == v })
        asset.tags = []
        try store.updateAsset(asset)

        let stale = try store.staleEdges()
        XCTAssertEqual(try store.pruneStaleEdges(stale), 1)
        XCTAssertEqual(try store.pruneStaleEdges(stale), 0, "already gone, and not an error")
    }
}
