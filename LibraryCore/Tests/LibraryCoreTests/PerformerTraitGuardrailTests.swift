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

    private let traits: Set<String> = [TagNormalizer.identityKey("Redhead")]

    // MARK: - The guardrail

    func testANewPerformerTraitIsOfferedButNeverPreTicked() {
        let options = VideoEnrichmentReview.tagOptions(
            for: asset(), proposal: proposal(tags: ["Redhead", "Outdoor"]),
            knownTags: ["Redhead", "Outdoor"], performerTraits: traits)

        let selection = VideoEnrichmentReview.defaultSelection(options)

        XCTAssertTrue(options.contains { $0.name == "Redhead" }, "offered, not hidden")
        XCTAssertFalse(selection.contains("Redhead"), "a video is not a redhead")
        XCTAssertTrue(selection.contains("Outdoor"), "an ordinary known tag still ticks")
    }

    func testTheOptionSaysWhyItIsNotTicked() {
        let options = VideoEnrichmentReview.tagOptions(
            for: asset(), proposal: proposal(tags: ["Redhead"]),
            knownTags: ["Redhead"], performerTraits: traits)

        XCTAssertTrue(try XCTUnwrap(options.first).describesPerformer)
    }

    /// 🚨 The exact regression: being classified is what used to tick it.
    func testAClassifiedTraitIsNotTickedDespiteBeingInTheVocabulary() {
        let options = VideoEnrichmentReview.tagOptions(
            for: asset(), proposal: proposal(tags: ["Redhead"]),
            knownTags: ["Redhead"], performerTraits: traits)

        XCTAssertTrue(try! XCTUnwrap(options.first).isKnown, "it IS in the vocabulary")
        XCTAssertFalse(VideoEnrichmentReview.defaultSelection(options).contains("Redhead"))
    }

    // MARK: - What must not change

    /// ⚠️ A trait ALREADY on the video stays ticked. Unticking is how it comes
    /// off, and silently proposing removal of applied tags is its own surprise.
    func testATraitAlreadyOnTheVideoStaysTicked() {
        let options = VideoEnrichmentReview.tagOptions(
            for: asset(tags: ["tag:Redhead"]), proposal: proposal(tags: []),
            knownTags: ["Redhead"], performerTraits: traits)

        XCTAssertTrue(VideoEnrichmentReview.defaultSelection(options).contains("Redhead"))
    }

    /// Case differences must not defeat the guard.
    func testTheGuardMatchesOnFoldedIdentity() {
        let options = VideoEnrichmentReview.tagOptions(
            for: asset(), proposal: proposal(tags: ["REDHEAD"]),
            knownTags: ["REDHEAD"], performerTraits: traits)

        XCTAssertFalse(VideoEnrichmentReview.defaultSelection(options).contains("REDHEAD"))
    }

    /// With no vocabulary kinds supplied, behaviour is exactly as before.
    func testWithNoTraitsSuppliedNothingChanges() {
        let options = VideoEnrichmentReview.tagOptions(
            for: asset(), proposal: proposal(tags: ["Redhead"]),
            knownTags: ["Redhead"])

        XCTAssertTrue(VideoEnrichmentReview.defaultSelection(options).contains("Redhead"))
    }
}
