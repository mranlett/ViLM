import XCTest
@testable import LibraryCore

/// Carrying a credited name from a proposal onto the edge.
///
/// 🚨 Migration v29 added `credited_as` and `billing` to `video_performer` and
/// nothing ever wrote to them — `VideoMetadataProposal.actors` was `[String]`,
/// so the name a performer appeared under in a scene was read at the plugin
/// boundary and dropped there. The column existed, the data existed, and the
/// two were never connected.
final class PerformerCreditTests: XCTestCase {

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

    @discardableResult
    private func video() throws -> Asset {
        let name = "\(UUID().uuidString).mp4"
        let asset = Asset(relativePath: name, fileName: name)
        try store.insertAsset(asset)
        return asset
    }

    private func performer(_ name: String) throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:\(name)"))
    }

    private func proposal(_ credits: [ProposedCredit]) -> VideoMetadataProposal {
        var p = VideoMetadataProposal()
        p.actors = .init(credits, sourceNote: "a source")
        return p
    }

    // MARK: - What is worth storing

    func testACreditedNameIsKept() throws {
        let asset = try video()
        try performer("Alice Smith")

        let credits = VideoEnrichmentReview.credits(
            from: proposal([ProposedCredit(name: "Alice Smith", creditedAs: "Alicia S.")]),
            accepting: [VideoEnrichmentReview.Field.performers])
        try store.recordCredits(credits, forVideo: asset.id)

        XCTAssertEqual(try store.performerCredits(forVideo: asset.id).first?.creditedAs,
                       "Alicia S.")
    }

    /// ⚠️ A credit saying nothing is not stored. "Credited under their usual
    /// name" is what the edge already implies, and writing it for everyone
    /// would bury the handful that are actually interesting.
    func testAnOrdinaryCreditIsNotStored() throws {
        let credits = VideoEnrichmentReview.credits(
            from: proposal([ProposedCredit(name: "Alice Smith")]),
            accepting: [VideoEnrichmentReview.Field.performers])

        XCTAssertTrue(credits.isEmpty)
    }

    func testACreditRepeatingTheCanonicalNameIsNotStored() throws {
        let credits = VideoEnrichmentReview.credits(
            from: proposal([ProposedCredit(name: "Alice Smith", creditedAs: "alice smith")]),
            accepting: [VideoEnrichmentReview.Field.performers])

        XCTAssertTrue(credits.isEmpty, "differing only by case is the same name")
    }

    /// Billing alone is worth keeping even with no alias.
    func testBillingAloneIsWorthStoring() throws {
        let asset = try video()
        try performer("Alice Smith")

        let credits = VideoEnrichmentReview.credits(
            from: proposal([ProposedCredit(name: "Alice Smith", billing: 1)]),
            accepting: [VideoEnrichmentReview.Field.performers])
        try store.recordCredits(credits, forVideo: asset.id)

        XCTAssertEqual(try store.performerCredits(forVideo: asset.id).first?.billing, 1)
    }

    /// Nothing is stored for a field the operator did not accept.
    func testCreditsAreNotStoredWhenPerformersWereNotAccepted() {
        let credits = VideoEnrichmentReview.credits(
            from: proposal([ProposedCredit(name: "Alice Smith", creditedAs: "Alicia S.")]),
            accepting: [])

        XCTAssertTrue(credits.isEmpty)
    }

    // MARK: - Writing

    /// ⚠️ Same rule as `connectEdges`: no edge to a node this library does not
    /// have.
    func testACreditForAnUnknownPerformerIsSkipped() throws {
        let asset = try video()

        let written = try store.recordCredits(
            [ProposedCredit(name: "Nobody Here", creditedAs: "N.H.")], forVideo: asset.id)

        XCTAssertEqual(written, 0)
        XCTAssertTrue(try store.performerCredits(forVideo: asset.id).isEmpty)
    }

    func testRecordingACreditCreatesTheCastEdge() throws {
        let asset = try video()
        try performer("Alice Smith")

        try store.recordCredits([ProposedCredit(name: "Alice Smith", creditedAs: "Alicia S.")],
                                forVideo: asset.id)

        XCTAssertEqual(try store.performerIds(forVideo: asset.id), ["actor:Alice Smith"])
    }

    /// Re-running a match must not multiply the edge or lose the name.
    func testRecordingTheSameCreditTwiceIsIdempotent() throws {
        let asset = try video()
        try performer("Alice Smith")
        let credit = ProposedCredit(name: "Alice Smith", creditedAs: "Alicia S.")

        try store.recordCredits([credit], forVideo: asset.id)
        try store.recordCredits([credit], forVideo: asset.id)

        let stored = try store.performerCredits(forVideo: asset.id)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.creditedAs, "Alicia S.")
    }

    // MARK: - What the operator sees

    /// ⭐ Shown at review because a credited name that looks nothing like the
    /// performer is the clearest sign the source matched the wrong person.
    func testTheReviewRowShowsTheCreditedName() {
        XCTAssertEqual(
            VideoEnrichmentReview.described(
                ProposedCredit(name: "Alice Smith", creditedAs: "Alicia S.")),
            "Alice Smith (as Alicia S.)")
    }

    func testTheReviewRowStaysPlainForAnOrdinaryCredit() {
        XCTAssertEqual(
            VideoEnrichmentReview.described(ProposedCredit(name: "Alice Smith")),
            "Alice Smith")
    }

    /// The canonical name becomes the tag — never the alias, which would file
    /// the performer as a second person.
    func testTheAcceptedTagUsesTheCanonicalName() throws {
        let name = "\(UUID().uuidString).mp4"
        let asset = Asset(relativePath: name, fileName: name)

        let merged = VideoEnrichmentReview.merged(
            asset: asset,
            proposal: proposal([ProposedCredit(name: "Alice Smith", creditedAs: "Alicia S.")]),
            accepting: [VideoEnrichmentReview.Field.performers], acceptedTags: [])

        XCTAssertEqual(merged.actors, ["Alice Smith"])
    }

    /// A plain name still reads as one, so fixtures and call sites that name a
    /// performer and nothing else are unchanged.
    func testAPlainStringIsStillACredit() {
        let credit: ProposedCredit = "Alice Smith"
        XCTAssertEqual(credit.name, "Alice Smith")
        XCTAssertNil(credit.creditedAs)
    }
}
