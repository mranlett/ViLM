// MatchJourneyTests.swift
// The whole transaction: match a video, and everything it brings with it.
//
// 🚨 This suite exists because 1,790 passing unit tests did not stop six
// defects in one session, all of them in the SEAMS between tested units. The
// difference here is that nothing is asserted about a single function — the
// journey runs the sequence the APP runs, then asserts what must be true of
// the library afterwards (`LibraryInvariants`).
//
// ⚠️ The sequence below is copied from `VideoEnrichmentModel.apply()`. If that
// changes, this must change with it — a journey test that invents its own
// plausible order tests a flow nobody runs, which is worse than no test
// because it reads like coverage.
//
// ⭐ The library is REKEYED in setUp, because that is the state every real
// device is in. Three of this session's defects were invisible on a
// non-rekeyed library, where an id still happens to be `actor:Name` — and one
// of them survived a test I wrote precisely because the fixture was not.

import XCTest
import GRDB
@testable import LibraryCore

final class MatchJourneyTests: XCTestCase {

    private var url: URL!
    private var store: LibraryStore!
    private let source = "TheSource"

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Journey-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store = try LibraryStore(at: url)
        try markRekeyed()
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: url)
    }

    /// The state `rekeyCommit` leaves, which is where every device is.
    private func markRekeyed() throws {
        let uid = UUID().uuidString
        try store.saveEntityProfile(EntityProfile(id: uid, entityType: "actor",
                                                  displayName: "Sentinel Example"))
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE entity_profiles SET uid = id WHERE id = ?",
                           arguments: [uid])
        }
    }

    // MARK: - The proposal a source returns for a scene

    private func sceneProposal(title: String,
                               cast: [(name: String, sourceId: String)],
                               studio: String, studioSourceId: String,
                               parent: String? = nil,
                               parentSourceId: String? = nil) -> VideoMetadataProposal {
        var p = VideoMetadataProposal()
        let note = source
        p.title = .init(title, sourceNote: note)
        p.releaseDate = .init("2021-05-04", sourceNote: note)
        p.studio = .init(studio, sourceNote: note)
        p.studioSourceId = .init(studioSourceId, sourceNote: note)
        if let parent { p.studioParent = .init(parent, sourceNote: note) }
        if let parentSourceId { p.studioParentSourceId = .init(parentSourceId, sourceNote: note) }
        p.actors = .init(cast.map { ProposedCredit(name: $0.name, sourceId: $0.sourceId) },
                         sourceNote: note)
        return p
    }

    /// 🚨 `VideoEnrichmentModel.apply()`, replayed. Same calls, same order.
    @discardableResult
    private func confirmVideoMatch(_ asset: Asset,
                                   proposal: VideoMetadataProposal,
                                   sourceId: String,
                                   accepting: Set<String>? = nil) throws -> Asset {
        let changes = VideoEnrichmentReview.changes(for: asset, proposal: proposal)
        let accepted = accepting ?? Set(changes.map(\.field))

        if let studio = VideoEnrichmentReview.confirmedStudio(proposal: proposal,
                                                              accepting: accepted, asset: asset) {
            try store.confirmStudio(studio, source: source,
                                    sourceId: proposal.studioSourceId.value)
        }
        if let child = proposal.studio.value, let parent = proposal.studioParent.value,
           !StudioResolution.isSameStudio(child, parent) {
            if let pid = proposal.studioParentSourceId.value, !pid.isEmpty {
                try store.confirmStudio(parent, source: source, sourceId: pid)
            } else {
                _ = try store.ensureStudioProfile(parent)
            }
            if let parentId = try store.entityId(named: parent, type: "studio"),
               let childId = try store.entityId(named: child, type: "studio") {
                try store.setStudioParent(parentId, forStudio: childId)
            }
        }

        let merged = VideoEnrichmentReview.merged(asset: asset, proposal: proposal,
                                                  accepting: accepted)
        try store.updateAsset(merged)

        let credits = VideoEnrichmentReview.credits(from: proposal, accepting: accepted)
        if !credits.isEmpty { _ = try store.recordCredits(credits, forVideo: asset.id) }

        try store.confirmVideoMatch(asset.id, source: source,
                                    sourceId: sourceId, method: .operator)
        if let all = proposal.actors.value {
            _ = try store.propagateIdentities(all, source: source, videoMethod: .operator)
        }
        // Nodes for the cast, then the edges — see the same pair in
        // `VideoEnrichmentModel.apply()`.
        for name in merged.actors { _ = try store.ensureActorProfile(name) }
        _ = try store.connectEdges(forVideo: asset.id)
        return merged
    }

    /// Matching one actor, the way `ActorEnrichmentSheet` + the editor do:
    /// the node is minted for writing, then the lookup fills it in.
    private func matchActor(named name: String, sourceId: String) throws {
        let id = try store.entityIdForWriting(named: name, type: "actor")
        let existing = try XCTUnwrap(try store.fetchEntityProfile(for: id))

        var proposal = ActorMetadataProposal()
        proposal.sourceId = .init(sourceId, sourceNote: source)
        proposal.bio = .init("A biography.", sourceNote: source)

        var merged = ActorEnrichment.apply(proposal, to: existing, entityId: id,
                                           accepting: [ActorEnrichment.Field.bio])
        merged.enrichmentState = .matched
        merged.enrichmentSource = source
        merged.enrichmentCheckedAt = Date()
        try store.saveEntityProfile(merged)
        try store.confirmEntityMatch(id, source: source, sourceId: sourceId, method: .name)
    }

    private func video(_ fileName: String) throws -> Asset {
        let asset = Asset(relativePath: "\(UUID()).mp4", fileName: fileName, tags: [])
        try store.insertAsset(asset)
        return asset
    }

    // MARK: - 🚨 The journey

    /// Match one video that brings two new performers and a new studio, then
    /// identify each of them — the sequence a person actually performs.
    func testMatchingAVideoAndThenItsCastLeavesTheGraphWhole() throws {
        let asset = try video("harbour-nights.mp4")
        let proposal = sceneProposal(
            title: "Harbour Nights",
            cast: [("Ann Example", "p-ann"), ("Bea Example", "p-bea")],
            studio: "Coast Line", studioSourceId: "s-coast")

        try confirmVideoMatch(asset, proposal: proposal, sourceId: "v-1")

        // The cast landed on the video.
        let saved = try XCTUnwrap(try store.fetchAllAssets().first { $0.id == asset.id })
        XCTAssertEqual(Set(saved.actors), ["Ann Example", "Bea Example"])

        // Now identify each performer, as the operator would.
        try matchActor(named: "Ann Example", sourceId: "p-ann")
        try matchActor(named: "Bea Example", sourceId: "p-bea")

        try assertLibraryInvariants(store)
    }

    /// ⭐ The state BETWEEN the two steps is the one the operator actually
    /// lives in — a video matched, its cast not yet identified. It must be
    /// coherent, not merely eventually-coherent.
    func testTheLibraryIsCoherentBeforeTheCastIsIdentified() throws {
        let asset = try video("harbour-nights.mp4")
        try confirmVideoMatch(asset,
                              proposal: sceneProposal(
                                title: "Harbour Nights",
                                cast: [("Ann Example", "p-ann")],
                                studio: "Coast Line", studioSourceId: "s-coast"),
                              sourceId: "v-1")

        try assertLibraryInvariants(store)
    }

    /// Two videos sharing a performer must produce ONE profile, not two.
    func testASharedPerformerAcrossTwoVideosIsOneNode() throws {
        for (i, file) in ["one.mp4", "two.mp4"].enumerated() {
            let asset = try video(file)
            try confirmVideoMatch(asset,
                                  proposal: sceneProposal(
                                    title: "Title \(i)",
                                    cast: [("Ann Example", "p-ann")],
                                    studio: "Coast Line", studioSourceId: "s-coast"),
                                  sourceId: "v-\(i)")
        }
        try matchActor(named: "Ann Example", sourceId: "p-ann")

        let actors = try store.fetchAllEntityProfiles()
            .filter { $0.type == "actor" && $0.name != "Sentinel Example" }
        XCTAssertEqual(actors.count, 1, "one person, one node")
        try assertLibraryInvariants(store)
    }

    /// A studio arriving under a network, which is the shape the source
    /// actually returns and the one the hierarchy depends on.
    func testAnImprintAndItsNetworkBothLandAndAreConnected() throws {
        let asset = try video("harbour-nights.mp4")
        try confirmVideoMatch(asset,
                              proposal: sceneProposal(
                                title: "Harbour Nights",
                                cast: [("Ann Example", "p-ann")],
                                studio: "Coast Line", studioSourceId: "s-coast",
                                parent: "Seaboard Group", parentSourceId: "s-sea"),
                              sourceId: "v-1")
        try matchActor(named: "Ann Example", sourceId: "p-ann")

        let studios = try store.fetchAllEntityProfiles().filter { $0.type == "studio" }
        XCTAssertEqual(Set(studios.map(\.name)), ["Coast Line", "Seaboard Group"])
        try assertLibraryInvariants(store)
    }

    /// ⚠️ Re-matching the same video must be idempotent. The operator does this
    /// constantly — Match Again is a refresh — and every one of this session's
    /// duplicate-row defects showed up as "doing it twice makes two".
    func testMatchingTheSameVideoTwiceChangesNothingTheSecondTime() throws {
        let asset = try video("harbour-nights.mp4")
        let proposal = sceneProposal(title: "Harbour Nights",
                                     cast: [("Ann Example", "p-ann")],
                                     studio: "Coast Line", studioSourceId: "s-coast")

        try confirmVideoMatch(asset, proposal: proposal, sourceId: "v-1")
        try matchActor(named: "Ann Example", sourceId: "p-ann")
        let before = try store.fetchAllEntityProfiles().count

        let reloaded = try XCTUnwrap(try store.fetchAllAssets().first { $0.id == asset.id })
        try confirmVideoMatch(reloaded, proposal: proposal, sourceId: "v-1")

        XCTAssertEqual(try store.fetchAllEntityProfiles().count, before,
                       "a re-match must not mint a second anything")
        try assertLibraryInvariants(store)
    }



    // MARK: - 🚨 The hand-added performer

    /// Adding an actor by editing a video's details, then identifying them.
    ///
    /// This is the journey the operator reported twice, and the one the other
    /// tests here do NOT reach: every path above creates the cast as a
    /// side-effect of a match, so `entityIdForWriting` always finds an
    /// existing row and its minting branch never runs. Mutating that branch to
    /// stop saving — the exact defect of 2026-08-10 — left the rest of this
    /// suite green.
    private func addActorByHand(_ name: String, to asset: Asset) throws -> Asset {
        // What the editor does: mint an id to save through, then write the tag.
        _ = try store.entityIdForWriting(named: name, type: "actor")
        var edited = asset
        edited.tags = edited.tags + ["actor:\(name)"]
        try store.updateAsset(edited)
        _ = try store.connectEdges(forVideo: asset.id)
        return edited
    }

    func testAnActorAddedByHandIsAWholeNode() throws {
        let asset = try video("harbour-nights.mp4")

        let edited = try addActorByHand("Cara Example", to: asset)

        XCTAssertEqual(edited.actors, ["Cara Example"])
        let profile = try XCTUnwrap(
            try store.fetchEntityProfile(named: "Cara Example", type: "actor"),
            "the id the editor saves through must name a row")
        XCTAssertEqual(profile.name, "Cara Example", "and never render as its own uid")
        XCTAssertEqual(profile.type, "actor")

        try assertLibraryInvariants(store)
    }

    /// ⭐ And then identifying them completes the picture — the second half of
    /// the report, where the match sheet showed a uid instead of the name.
    func testIdentifyingAHandAddedActorLeavesTheGraphWhole() throws {
        let asset = try video("harbour-nights.mp4")
        _ = try addActorByHand("Cara Example", to: asset)

        try matchActor(named: "Cara Example", sourceId: "p-cara")

        let profile = try XCTUnwrap(
            try store.fetchEntityProfile(named: "Cara Example", type: "actor"))
        XCTAssertEqual(profile.enrichmentSourceId, "p-cara")
        XCTAssertEqual(profile.name, "Cara Example")
        try assertLibraryInvariants(store)
    }

    /// ⚠️ Adding the same name twice must not mint a second node — the shape
    /// of every duplicate defect this session produced.
    func testAddingTheSameActorTwiceIsOneNode() throws {
        let a = try video("one.mp4")
        let b = try video("two.mp4")
        _ = try addActorByHand("Cara Example", to: a)
        _ = try addActorByHand("Cara Example", to: b)

        let matches = try store.fetchAllEntityProfiles()
            .filter { $0.type == "actor" && $0.name == "Cara Example" }
        XCTAssertEqual(matches.count, 1)
        try assertLibraryInvariants(store)
    }
}
