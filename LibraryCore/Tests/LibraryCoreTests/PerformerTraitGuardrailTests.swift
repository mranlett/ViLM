import XCTest
@testable import LibraryCore

/// Whether a video match can put a performer's trait on the video.
///
/// 🚨 Reported by the operator: *"seems like the video matching is bringing
/// down actor tags and putting them on videos. Do we have guardrails to prevent
/// that now?"* There were none — and it was not merely old data.
///
/// The mechanism is worse than "no guard": a trait tag that has been CLASSIFIED
/// is in the vocabulary, so `isKnown` was true, so it was **pre-ticked**. Being
/// correctly identified as a performer trait is exactly what caused it to be
/// applied to the video by default.
final class PerformerTraitGuardrailTests: XCTestCase {

    private func asset(tags: [String] = []) -> Asset {
        Asset(relativePath: "v.mp4", fileName: "v.mp4", tags: tags)
    }

    private func proposal(tags: [String]) -> VideoMetadataProposal {
        var p = VideoMetadataProposal()
        p.tags = .init(tags)
        return p
    }

    private let traits: Set<String> = [TagNormalizer.identityKey("Tall")]

    // MARK: - The guardrail

    func testANewPerformerTraitIsOfferedButNeverPreTicked() {
        let options = VideoEnrichmentReview.tagOptions(
            for: asset(), proposal: proposal(tags: ["Tall", "Outdoor"]),
            knownTags: ["Tall", "Outdoor"], performerTraits: traits)

        let selection = VideoEnrichmentReview.defaultSelection(options)

        XCTAssertTrue(options.contains { $0.name == "Tall" }, "offered, not hidden")
        XCTAssertFalse(selection.contains("Tall"), "a video is not a tall")
        XCTAssertTrue(selection.contains("Outdoor"), "an ordinary known tag still ticks")
    }

    func testTheOptionSaysWhyItIsNotTicked() {
        let options = VideoEnrichmentReview.tagOptions(
            for: asset(), proposal: proposal(tags: ["Tall"]),
            knownTags: ["Tall"], performerTraits: traits)

        XCTAssertTrue(try XCTUnwrap(options.first).describesPerformer)
    }

    /// 🚨 The exact regression: being classified is what used to tick it.
    func testAClassifiedTraitIsNotTickedDespiteBeingInTheVocabulary() {
        let options = VideoEnrichmentReview.tagOptions(
            for: asset(), proposal: proposal(tags: ["Tall"]),
            knownTags: ["Tall"], performerTraits: traits)

        XCTAssertTrue(try! XCTUnwrap(options.first).isKnown, "it IS in the vocabulary")
        XCTAssertFalse(VideoEnrichmentReview.defaultSelection(options).contains("Tall"))
    }

    // MARK: - What must not change

    /// ⚠️ A trait ALREADY on the video stays ticked. Unticking is how it comes
    /// off, and silently proposing removal of applied tags is its own surprise.
    func testATraitAlreadyOnTheVideoStaysTicked() {
        let options = VideoEnrichmentReview.tagOptions(
            for: asset(tags: ["tag:Tall"]), proposal: proposal(tags: []),
            knownTags: ["Tall"], performerTraits: traits)

        XCTAssertTrue(VideoEnrichmentReview.defaultSelection(options).contains("Tall"))
    }

    /// Case differences must not defeat the guard.
    func testTheGuardMatchesOnFoldedIdentity() {
        let options = VideoEnrichmentReview.tagOptions(
            for: asset(), proposal: proposal(tags: ["TALL"]),
            knownTags: ["TALL"], performerTraits: traits)

        XCTAssertFalse(VideoEnrichmentReview.defaultSelection(options).contains("TALL"))
    }

    /// With no vocabulary kinds supplied, behaviour is exactly as before.
    func testWithNoTraitsSuppliedNothingChanges() {
        let options = VideoEnrichmentReview.tagOptions(
            for: asset(), proposal: proposal(tags: ["Tall"]),
            knownTags: ["Tall"])

        XCTAssertTrue(VideoEnrichmentReview.defaultSelection(options).contains("Tall"))
    }
}
