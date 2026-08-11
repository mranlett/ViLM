// VideoEnrichmentModelTests.swift
// What confirming a video match actually WRITES.
//
// 🚨 This is the seam the spanning suite exposed. Every piece of the confirm
// path was individually correct and the graph still came out empty: the studio
// got a node and the cast did not, and nothing joined the video to either.
// `MatchJourneyTests` proves the SEQUENCE is right in core; these prove the app
// performs that sequence, which is a different claim and the one that failed.
//
// ⚠️ Drives the real `apply()` against a real temporary library through
// `LibrarySession`, because the defect was in the wiring — a test that called
// the store directly would have passed throughout.

import XCTest
import LibraryCore
@testable import ViLM

@MainActor
final class VideoEnrichmentModelTests: XCTestCase {

    private var url: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VEM-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store = try LibraryStore(at: url)
        LibrarySession.shared.setPrimary(url)
    }

    override func tearDownWithError() throws {
        LibrarySession.shared.setPrimary(nil)
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: url)
    }

    private func asset(studios: [String] = []) throws -> Asset {
        let a = Asset(relativePath: "\(UUID()).mp4", fileName: "v.mp4",
                      tags: studios.map { "studio:\($0)" })
        try store.insertAsset(a)
        return a
    }

    private func proposal(cast: [String] = ["Ann Example"],
                          studio: String? = "Coast Line",
                          parent: String? = nil) -> VideoMetadataProposal {
        var p = VideoMetadataProposal()
        p.title = .init("Harbour Nights", sourceNote: "TheSource")
        if let studio {
            p.studio = .init(studio, sourceNote: "TheSource")
            p.studioSourceId = .init("s-coast", sourceNote: "TheSource")
        }
        if let parent {
            p.studioParent = .init(parent, sourceNote: "TheSource")
            p.studioParentSourceId = .init("s-parent", sourceNote: "TheSource")
        }
        p.actors = .init(cast.map { ProposedCredit(name: $0) }, sourceNote: "TheSource")
        return p
    }

    private func model(_ a: Asset) -> VideoEnrichmentModel {
        VideoEnrichmentModel(asset: a, libraryURL: url, knownTags: [])
    }

    @discardableResult
    private func confirm(_ m: VideoEnrichmentModel,
                         _ p: VideoMetadataProposal) throws -> Asset {
        let changes = VideoEnrichmentReview.changes(for: m.subjectAssetForTesting, proposal: p)
        m.prepareForTesting(proposal: p, accepting: Set(changes.map(\.field)))
        return try XCTUnwrap(m.apply())
    }

    // MARK: - 🚨 The graph is actually populated

    func testConfirmingCreatesANodeForEveryCastMember() throws {
        let a = try asset()
        let m = model(a)

        try confirm(m, proposal(cast: ["Ann Example", "Bea Example"]))

        let actors = try store.fetchAllEntityProfiles().filter { $0.type == "actor" }
        XCTAssertEqual(Set(actors.map(\.name)), ["Ann Example", "Bea Example"],
                       "the studio got a row and the cast did not, for months")
    }

    /// ⭐ And the video is JOINED to them. The nodes existing is not the same
    /// as the graph being connected, and only the second makes browsing work.
    func testConfirmingJoinsTheVideoToItsCastAndStudio() throws {
        let a = try asset()
        let m = model(a)

        try confirm(m, proposal(cast: ["Ann Example"]))

        XCTAssertEqual(try store.edgeCount(.videoPerformer), 1,
                       "connectEdges ran only on a MOVE before this")
        XCTAssertEqual(try store.edgeCount(.videoStudio), 1)
    }

    func testConfirmingCreatesTheStudioNode() throws {
        let a = try asset()
        let m = model(a)

        try confirm(m, proposal())

        XCTAssertNotNil(try store.fetchEntityProfile(named: "Coast Line", type: "studio"))
    }

    /// ⚠️ Idempotent. Match Again is a refresh and the operator runs it often;
    /// every duplicate defect this session showed up as "twice makes two".
    func testConfirmingTwiceLeavesOneOfEverything() throws {
        let a = try asset()
        try confirm(model(a), proposal())
        let reloaded = try XCTUnwrap(try store.fetchAllAssets().first { $0.id == a.id })
        try confirm(model(reloaded), proposal())

        let actors = try store.fetchAllEntityProfiles().filter { $0.type == "actor" }
        XCTAssertEqual(actors.count, 1)
        XCTAssertEqual(try store.edgeCount(.videoPerformer), 1)
    }

    // MARK: - 🚨 A settled studio decision is not re-opened

    /// The operator already answered imprint-versus-network for this video.
    /// Re-matching is a refresh; it must not put the question back.
    func testAStudioTheVideoAlreadyCarriesIsKept() throws {
        let a = try asset(studios: ["Seaboard Group"])
        let m = model(a)

        let merged = try confirm(m, proposal(studio: "Coast Line", parent: "Seaboard Group"))

        XCTAssertEqual(merged.studios, ["Seaboard Group"],
                       "the answer already on the video wins")
    }

    /// ⭐ With nothing settled, the source's imprint lands as normal — the
    /// rule must not freeze a video that never had a studio.
    func testAVideoWithNoStudioTakesTheSourcesChoice() throws {
        let a = try asset()
        let m = model(a)

        let merged = try confirm(m, proposal(studio: "Coast Line"))

        XCTAssertEqual(merged.studios, ["Coast Line"])
    }

    // MARK: - The library afterwards

    func testTheLibraryIsCoherentAfterAConfirmedMatch() throws {
        let a = try asset()
        try confirm(model(a), proposal(cast: ["Ann Example", "Bea Example"]))

        let nameless = try store.namelessNodes()
        XCTAssertTrue(nameless.isEmpty, "no node left without an identity")
        let known = Set(try store.fetchAllEntityProfiles()
            .filter { $0.type == "actor" }.map(\.name))
        let credited = Set(try store.fetchAllAssets().flatMap(\.actors))
        XCTAssertTrue(credited.subtracting(known).isEmpty,
                      "every credited name resolves to a profile")
    }
}
