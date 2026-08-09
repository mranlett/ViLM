import XCTest
@testable import LibraryCore

/// Phase D, steps 2 and 3 — studios (with the conflict gate) and tags (with the
/// taxonomy deciding where each association goes).
final class ConnectStudioAndTagEdgesTests: XCTestCase {

    private var libraryURL: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        libraryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConnectST-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        store = try LibraryStore(at: libraryURL)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: libraryURL)
    }

    @discardableResult
    private func video(_ tags: [String]) throws -> UUID {
        let asset = Asset(relativePath: "\(UUID()).mp4", fileName: "a.mp4", tags: tags)
        try store.insertAsset(asset)
        return asset.id
    }

    private func profile(_ id: String, tags: [String] = []) throws {
        var p = EntityProfile(id: id)
        p.tags = tags
        try store.saveEntityProfile(p)
    }

    private func tag(_ name: String, _ kind: TagKind?) throws {
        try store.saveTagRecord(TagRecord(displayName: name, kind: kind))
    }

    // MARK: - Studios

    func testASingleStudioBecomesAnEdge() throws {
        try profile("studio:Example Studio")
        let v = try video(["studio:Example Studio", "actor:Alice Example"])

        try store.connectStudioEdges()

        XCTAssertEqual(try store.studioId(forVideo: v), "studio:Example Studio")
    }

    /// ⚠️ The gate. A scene has one releasing studio and the primary key says
    /// so, so a video the strings gave two cannot be represented at all.
    func testAVideoWithTwoStudiosIsSkippedAndReported() throws {
        try profile("studio:Example Studio"); try profile("studio:Other Studio")
        let conflicted = try video(["studio:Example Studio", "studio:Other Studio"])
        let fine = try video(["studio:Example Studio"])

        let plan = try store.connectStudioEdges()

        XCTAssertEqual(plan.conflicted, [conflicted])
        XCTAssertTrue(plan.isBlocked)
        XCTAssertNil(try store.studioId(forVideo: conflicted),
                     "picking one for the operator would discard a fact nobody checked")
        XCTAssertEqual(try store.studioId(forVideo: fine), "studio:Example Studio",
                       "and it does not block the videos that are fine")
    }

    func testAnUnknownStudioIsReportedNotInvented() throws {
        let v = try video(["studio:Never Seen"])

        let plan = try store.connectStudioEdges()

        XCTAssertEqual(plan.missingProfiles, ["Never Seen"])
        XCTAssertNil(try store.studioId(forVideo: v))
        XCTAssertNil(try store.fetchEntityProfile(for: "studio:Never Seen"))
    }

    func testStudioConnectIsIdempotentAndLeavesStringsAlone() throws {
        try profile("studio:Example Studio")
        let v = try video(["studio:Example Studio"])

        try store.connectStudioEdges()
        try store.connectStudioEdges()

        XCTAssertEqual(try store.edgeCount(.videoStudio), 1)
        let asset = try XCTUnwrap(try store.fetchAllAssets().first { $0.id == v })
        XCTAssertEqual(asset.studios, ["Example Studio"])
    }

    func testStudioVerificationIgnoresConflictedVideos() throws {
        try profile("studio:Example Studio"); try profile("studio:Other Studio")
        try video(["studio:Example Studio", "studio:Other Studio"])
        try video(["studio:Example Studio"])

        try store.connectStudioEdges()

        XCTAssertEqual(try store.studioEdgeDisagreements(), [],
                       "a known blocker is not a disagreement")
    }

    // MARK: - Tags

    func testActionAndVideoAttributeTagsBecomeVideoEdges() throws {
        try tag("Climbing", .action)
        try tag("Anthology", .videoAttribute)
        let v = try video(["tag:Climbing", "tag:Anthology"])

        let plan = try store.connectTagEdges()

        XCTAssertEqual(plan.videoEdges, 2)
        XCTAssertEqual(Set(try store.tagIds(forVideo: v)),
                       [TagNormalizer.identityKey("Climbing"),
                        TagNormalizer.identityKey("Anthology")])
    }

    /// ⚠️ Decision 2, enforced by the migration: an attribute tag sitting on a
    /// video becomes NOTHING — not an edge, and not staged either. Enrichment
    /// corrects it per performer, because which of the cast it describes is a
    /// guess the migration must not make.
    func testAPerformerAttributeOnAVideoBecomesNothing() throws {
        try tag("Tall", .performerAttribute)
        let v = try video(["tag:Tall"])

        let plan = try store.connectTagEdges()

        // ⚠️ THE VIDEOS since 2026-08-08, not a count and not a per-tag total.
        //
        // First it was an `Int`, then `[String: Int]` — and that second fix
        // stopped one level short: the screen could name the tag but could only
        // link to the TAG PAGE, which also lists every video whose cast carries
        // the trait. Eleven videos opened onto several hundred.
        XCTAssertEqual(plan.attributeTagAssociations, 1)
        XCTAssertEqual(plan.attributeTagsOnVideos, ["Tall": [v]],
                       "the actual video, so the report leads to it and not to a superset")
        XCTAssertEqual(try store.tagIds(forVideo: v), [], "no edge")
        XCTAssertEqual(try store.edgeCount(.pendingTagAssociation), 0, "and nothing staged")
    }

    func testAPerformersAttributeTagBecomesAPerformerEdge() throws {
        try tag("Tall", .performerAttribute)
        try profile("actor:Alice Example", tags: ["Tall"])

        let plan = try store.connectTagEdges()

        XCTAssertEqual(plan.performerEdges, 1)
        XCTAssertEqual(try store.edgeCount(.performerTag), 1)
    }

    /// The parser's finding is held rather than lost.
    func testAnUnclassifiedTagIsStagedNotDropped() throws {
        try tag("Unsorted", nil)
        let v = try video(["tag:Unsorted"])

        let plan = try store.connectTagEdges()

        XCTAssertEqual(plan.pending, 1)
        XCTAssertEqual(try store.tagIds(forVideo: v), [], "not an edge")
        XCTAssertEqual(try store.edgeCount(.pendingTagAssociation), 1, "but not lost")
    }

    func testATagMissingFromTheVocabularyIsReported() throws {
        try video(["tag:Never Promoted"])

        let plan = try store.connectTagEdges()

        XCTAssertEqual(plan.unknownTags, ["Never Promoted"])
    }

    func testTagConnectIsIdempotent() throws {
        try tag("Climbing", .action)
        try video(["tag:Climbing"])

        try store.connectTagEdges()
        try store.connectTagEdges()

        XCTAssertEqual(try store.edgeCount(.videoTag), 1)
    }

    // MARK: - Redeeming what was staged

    /// The payoff for staging: classify the tag later and the link is still
    /// there to become an edge.
    func testClassifyingAStagedTagMaterialisesItsEdges() throws {
        try tag("Unsorted", nil)
        let v = try video(["tag:Unsorted"])
        try store.connectTagEdges()

        try tag("Unsorted", .action)
        let result = try store.resolvePendingAssociations(
            forTag: TagNormalizer.identityKey("Unsorted"))

        XCTAssertEqual(result.materialised, 1)
        XCTAssertEqual(try store.tagIds(forVideo: v), [TagNormalizer.identityKey("Unsorted")])
        XCTAssertEqual(try store.edgeCount(.pendingTagAssociation), 0, "the staging is consumed")
    }

    /// ⚠️ Classified as describing a PERSON, so the staged video links are
    /// discarded and counted — inventing an edge for them is exactly what the
    /// taxonomy exists to stop.
    func testAStagedTagClassifiedAsAPerformerAttributeIsDiscarded() throws {
        try tag("Unsorted", nil)
        let v = try video(["tag:Unsorted"])
        try store.connectTagEdges()

        try tag("Unsorted", .performerAttribute)
        let result = try store.resolvePendingAssociations(
            forTag: TagNormalizer.identityKey("Unsorted"))

        XCTAssertEqual(result.discarded, 1)
        XCTAssertEqual(result.materialised, 0)
        XCTAssertEqual(try store.tagIds(forVideo: v), [])
        XCTAssertEqual(try store.edgeCount(.pendingTagAssociation), 0)
    }

    func testResolvingAnUnclassifiedTagDoesNothing() throws {
        try tag("Unsorted", nil)
        try video(["tag:Unsorted"])
        try store.connectTagEdges()

        let result = try store.resolvePendingAssociations(
            forTag: TagNormalizer.identityKey("Unsorted"))

        XCTAssertEqual(result.materialised, 0)
        XCTAssertEqual(result.discarded, 0)
        XCTAssertEqual(try store.edgeCount(.pendingTagAssociation), 1, "still waiting")
    }
}
