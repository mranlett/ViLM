import XCTest
@testable import LibraryCore

/// Edge attributes, phase 1 — facts about a relationship.
///
/// The migration is additive, so the assertions that matter are: nothing
/// existing changed, an un-stamped edge reads as UNKNOWN rather than as any
/// particular origin, and the credited name survives a round trip.
final class EdgeAttributeTests: XCTestCase {

    private var directory: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        store = try LibraryStore(at: directory)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeVideo(actors: [String] = []) throws -> Asset {
        let asset = Asset(relativePath: "\(UUID()).mp4", fileName: "a.mp4",
                          tags: actors.map { "actor:\($0)" })
        try store.saveAsset(asset)
        try store.updateAsset(asset)
        return asset
    }

    private func makePerformer(_ name: String) throws -> String {
        let id = "actor:\(name)"
        try store.saveEntityProfile(EntityProfile(id: id))
        return id
    }

    // MARK: - The migration

    /// Additive: the columns exist and every existing edge keeps its identity.
    func testTheNewColumnsExist() throws {
        let asset = try makeVideo()
        let performer = try makePerformer("Someone")
        try store.linkPerformer(performer, toVideo: asset.id)

        let credits = try store.performerCredits(forVideo: asset.id)
        XCTAssertEqual(credits.map(\.performerId), [performer])
    }

    /// ⚠️ An edge written before provenance existed reads as UNKNOWN, never as
    /// any particular origin. Defaulting it to a source would be inventing the
    /// very fact this migration exists to record.
    func testAnEdgeWithNoRecordedSourceReadsAsUnknown() throws {
        let asset = try makeVideo()
        let performer = try makePerformer("Someone")
        // Written the way the pre-migration code did.
        try store.insertLegacyPerformerEdge(performer, forVideo: asset.id)

        XCTAssertNil(try store.performerCredits(forVideo: asset.id).first?.source)
    }

    // MARK: - Provenance

    func testALinkRecordsWhereItCameFrom() throws {
        let asset = try makeVideo()
        let performer = try makePerformer("Someone")
        try store.linkPerformer(performer, toVideo: asset.id, source: .download)

        XCTAssertEqual(try store.performerCredits(forVideo: asset.id).first?.source, .download)
    }

    /// ⚠️ The bulk connect walks `asset.tags`, whose own origin is not
    /// recorded, so it must claim `inferred` — not `filename`, not `download`.
    func testTheBulkConnectClaimsInferredRatherThanASpecificOrigin() throws {
        _ = try makePerformer("Someone")
        _ = try makeVideo(actors: ["Someone"])
        _ = try store.connectPerformerEdges()

        let assets = try store.fetchAllAssets()
        let credits = try store.performerCredits(forVideo: assets[0].id)
        XCTAssertEqual(credits.first?.source, .inferred)
    }

    func testProvenanceCountsSeparateKnownFromUnknown() throws {
        let known = try makeVideo()
        let unknown = try makeVideo()
        let performer = try makePerformer("Someone")

        try store.linkPerformer(performer, toVideo: known.id, source: .download)
        try store.insertLegacyPerformerEdge(performer, forVideo: unknown.id)

        let counts = try store.edgeProvenanceCounts(.videoPerformer)
        XCTAssertEqual(counts["download"], 1)
        XCTAssertEqual(counts["unknown"], 1)
    }

    // MARK: - ⭐ The credited name

    /// The reason phase 1 exists: this was supplied on every match and
    /// discarded, because it belongs to the appearance rather than to the
    /// person or the video.
    func testACreditedNameRoundTrips() throws {
        let asset = try makeVideo()
        let performer = try makePerformer("Canonical Name")
        try store.recordPerformerCredit(
            PerformerCredit(performerId: performer, creditedAs: "Stage Name",
                            billing: 1, source: .download),
            forVideo: asset.id)

        let credit = try XCTUnwrap(try store.performerCredits(forVideo: asset.id).first)
        XCTAssertEqual(credit.creditedAs, "Stage Name")
        XCTAssertEqual(credit.billing, 1)
        XCTAssertEqual(credit.source, .download)
    }

    /// Recording a credit creates the edge if it is not there yet.
    func testRecordingACreditCreatesTheEdge() throws {
        let asset = try makeVideo()
        let performer = try makePerformer("Someone")
        try store.recordPerformerCredit(
            PerformerCredit(performerId: performer, source: .download),
            forVideo: asset.id)

        XCTAssertEqual(try store.performerIds(forVideo: asset.id), [performer])
    }

    /// ⚠️ Nil leaves the stored value alone rather than clearing it — the same
    /// rule as `ProposedField`, where "the source said nothing" must never
    /// overwrite something already known.
    func testASilentFieldDoesNotClearWhatIsStored() throws {
        let asset = try makeVideo()
        let performer = try makePerformer("Someone")
        try store.recordPerformerCredit(
            PerformerCredit(performerId: performer, creditedAs: "Stage Name",
                            billing: 2, source: .download),
            forVideo: asset.id)
        // A later write that knows only the source.
        try store.recordPerformerCredit(
            PerformerCredit(performerId: performer, source: .operator),
            forVideo: asset.id)

        let credit = try XCTUnwrap(try store.performerCredits(forVideo: asset.id).first)
        XCTAssertEqual(credit.creditedAs, "Stage Name", "not cleared by a silent field")
        XCTAssertEqual(credit.billing, 2)
    }

    /// Billed order first, then stable by id — a list that reorders between
    /// reads looks like data changing.
    func testCreditsAreOrderedByBillingThenStably() throws {
        let asset = try makeVideo()
        let lead = try makePerformer("Lead")
        let second = try makePerformer("Second")
        let unbilled = try makePerformer("Unbilled")

        try store.recordPerformerCredit(PerformerCredit(performerId: second, billing: 2),
                                        forVideo: asset.id)
        try store.recordPerformerCredit(PerformerCredit(performerId: lead, billing: 1),
                                        forVideo: asset.id)
        try store.recordPerformerCredit(PerformerCredit(performerId: unbilled),
                                        forVideo: asset.id)

        XCTAssertEqual(try store.performerCredits(forVideo: asset.id).map(\.performerId),
                       [lead, second, unbilled])
    }

    // MARK: - Display

    func testACreditUnderTheUsualNameShowsJustTheName() {
        XCTAssertEqual(PerformerCredit(performerId: "actor:Someone")
            .displayName(canonical: "Someone"), "Someone")
        XCTAssertEqual(PerformerCredit(performerId: "actor:Someone", creditedAs: "someone")
            .displayName(canonical: "Someone"), "Someone",
                       "a case-variant of the same name is not a different credit")
    }

    func testADifferentCreditedNameIsShown() {
        XCTAssertEqual(PerformerCredit(performerId: "actor:Someone", creditedAs: "Stage Name")
            .displayName(canonical: "Someone"), "Someone (as Stage Name)")
    }

    func testProvenancePrecedenceFollowsD7() {
        XCTAssertGreaterThan(EdgeProvenance.download.precedence,
                             EdgeProvenance.operator.precedence)
        XCTAssertGreaterThan(EdgeProvenance.operator.precedence,
                             EdgeProvenance.filename.precedence)
        XCTAssertGreaterThan(EdgeProvenance.filename.precedence,
                             EdgeProvenance.inferred.precedence)
    }
}
