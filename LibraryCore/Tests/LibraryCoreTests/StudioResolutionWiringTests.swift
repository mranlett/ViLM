import XCTest
@testable import LibraryCore

/// The studio policy as enrichment actually sees it: a proposal in, a decision
/// out, and a proposal carrying that decision for everything downstream.
final class StudioResolutionWiringTests: XCTestCase {

    private func proposal(studio: String?, parent: String? = nil) -> VideoMetadataProposal {
        var p = VideoMetadataProposal()
        p.studio = ProposedField(studio, sourceNote: studio == nil ? nil : "Example Source")
        p.studioSourceId = ProposedField(studio.map { "imprint-\($0)" })
        p.studioParent = ProposedField(parent)
        p.studioParentSourceId = ProposedField(parent.map { "parent-\($0)" })
        return p
    }

    private func verified(_ names: String...) -> (String) -> Bool {
        let set = Set(names)
        return { set.contains($0) }
    }

    // MARK: - Reading a proposal

    func testAnImprintAloneIsUsed() {
        let outcome = VideoEnrichmentReview.studioResolution(
            proposal: proposal(studio: "Example Studio"), held: [],
            isVerified: verified())

        guard case let .use(c) = outcome else { return XCTFail("expected .use, got \(outcome)") }
        XCTAssertEqual(c.name, "Example Studio")
        XCTAssertEqual(c.level, .imprint)
        XCTAssertEqual(c.sourceId, "imprint-Example Studio")
    }

    func testTheVerifiedOneWinsWhicheverLevelItIsOn() {
        let outcome = VideoEnrichmentReview.studioResolution(
            proposal: proposal(studio: "Example Studio", parent: "Example Network"),
            held: [],
            isVerified: verified("Example Network"))

        guard case let .use(c) = outcome else { return XCTFail("expected .use, got \(outcome)") }
        XCTAssertEqual(c.name, "Example Network")
        XCTAssertEqual(c.level, .parent)
    }

    /// ⚠️ Neither confirmed: the source offered two real names and nothing in
    /// the data says which the library should carry.
    func testTwoUnverifiedStudiosAsk() {
        let outcome = VideoEnrichmentReview.studioResolution(
            proposal: proposal(studio: "Example Studio", parent: "Example Network"),
            held: [],
            isVerified: verified())

        guard case let .ask(i, p) = outcome else { return XCTFail("expected .ask, got \(outcome)") }
        XCTAssertEqual(i.name, "Example Studio")
        XCTAssertEqual(p.name, "Example Network")
    }

    func testNoStudioAtAll() {
        XCTAssertEqual(
            VideoEnrichmentReview.studioResolution(proposal: proposal(studio: nil),
                                                   held: [],
                                                   isVerified: verified()),
            .none)
    }

    /// Whitespace is not a studio name.
    func testABlankStudioIsNotOffered() {
        XCTAssertEqual(
            VideoEnrichmentReview.studioResolution(proposal: proposal(studio: "   "),
                                                   held: [],
                                                   isVerified: verified()),
            .none)
    }

    // MARK: - Carrying the decision downstream

    func testTheResolvedProposalCarriesTheChosenStudio() {
        let original = proposal(studio: "Example Studio", parent: "Example Network")
        let parent = StudioResolution.Candidate(name: "Example Network",
                                                sourceId: "parent-Example Network",
                                                level: .parent, isVerified: true)

        let resolved = VideoEnrichmentReview.resolvingStudio(original, to: parent)

        XCTAssertEqual(resolved.studio.value, "Example Network")
        XCTAssertEqual(resolved.studioSourceId.value, "parent-Example Network")
    }

    /// ⚠️ The point of rewriting the proposal: review, merge and confirm all
    /// read the same field, so they cannot disagree about which studio this
    /// video is getting.
    func testReviewMergeAndConfirmAllAgreeWithTheChoice() {
        let asset = Asset(relativePath: "a.mp4", fileName: "a.mp4")
        let parent = StudioResolution.Candidate(name: "Example Network",
                                                sourceId: "parent-Example Network",
                                                level: .parent, isVerified: true)
        let resolved = VideoEnrichmentReview.resolvingStudio(
            proposal(studio: "Example Studio", parent: "Example Network"), to: parent)

        let rows = VideoEnrichmentReview.changes(for: asset, proposal: resolved)
        let studioRow = rows.first { $0.field == VideoEnrichmentReview.Field.studio }
        XCTAssertEqual(studioRow?.proposed, "Example Network")

        let merged = VideoEnrichmentReview.merged(
            asset: asset, proposal: resolved,
            accepting: [VideoEnrichmentReview.Field.studio])
        XCTAssertEqual(merged.studios, ["Example Network"])

        XCTAssertEqual(
            VideoEnrichmentReview.confirmedStudio(
                proposal: resolved, accepting: [VideoEnrichmentReview.Field.studio],
                asset: asset),
            "Example Network")
    }

    /// Choosing the imprint leaves the proposal exactly as the source sent it.
    func testChoosingTheImprintChangesNothing() {
        let original = proposal(studio: "Example Studio", parent: "Example Network")
        let imprint = StudioResolution.Candidate(name: "Example Studio",
                                                 sourceId: "imprint-Example Studio",
                                                 level: .imprint, isVerified: true)

        let resolved = VideoEnrichmentReview.resolvingStudio(original, to: imprint)

        XCTAssertEqual(resolved.studio.value, "Example Studio")
        XCTAssertEqual(resolved.studio.sourceNote, original.studio.sourceNote)
    }

    /// ⚠️ The network is still available after the choice, whichever way it
    /// went — the parent edge is recorded from it regardless of which name
    /// lands on the video.
    func testTheParentSurvivesTheChoice() {
        let original = proposal(studio: "Example Studio", parent: "Example Network")
        let imprint = StudioResolution.Candidate(name: "Example Studio",
                                                 sourceId: "imprint-Example Studio",
                                                 level: .imprint, isVerified: false)

        let resolved = VideoEnrichmentReview.resolvingStudio(original, to: imprint)

        XCTAssertEqual(resolved.studioParent.value, "Example Network")
        XCTAssertEqual(resolved.studioParentSourceId.value, "parent-Example Network")
    }
}
