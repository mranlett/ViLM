import XCTest
@testable import LibraryCore

/// Phase B — the tag taxonomy.
///
/// Everything here defends one rule: a tag may only be attached to the kind of
/// node it describes. A video is not a tall.
final class TagKindTests: XCTestCase {

    // MARK: - Enforcement

    func testAPerformerAttributeCannotAttachToAVideo() {
        XCTAssertFalse(TagKind.performerAttribute.canAttach(to: .video),
                       "the whole point of the taxonomy")
        XCTAssertTrue(TagKind.performerAttribute.canAttach(to: .performer))
    }

    func testAnActionCannotAttachToAPerformer() {
        XCTAssertFalse(TagKind.action.canAttach(to: .performer))
        XCTAssertTrue(TagKind.action.canAttach(to: .video))
    }

    func testAVideoAttributeIsAVideoTagButNotAnAction() {
        XCTAssertTrue(TagKind.videoAttribute.canAttach(to: .video))
        XCTAssertFalse(TagKind.videoAttribute.canAttach(to: .performer))
        XCTAssertNotEqual(TagKind.videoAttribute, TagKind.action,
                          "same target, different meaning — a filter must tell them apart")
    }

    /// A kind added later is enforced by the same code, with no new branches.
    /// This is what makes the model extensible rather than merely longer.
    func testAKindAddedLaterIsEnforcedWithoutNewCode() {
        let resolution = TagKind(name: "resolution", target: .video)

        XCTAssertTrue(resolution.canAttach(to: .video))
        XCTAssertFalse(resolution.canAttach(to: .performer))
    }

    // MARK: - Narrowing

    /// Only one kind targets performers, so a tag arriving on a performer still
    /// resolves without a human — the cheap half of the trade.
    func testATagArrivingOnAPerformerResolvesAutomatically() {
        XCTAssertEqual(TagKind.inferredKind(forTagArrivingOn: .performer),
                       TagKind.performerAttribute)
    }

    /// ⚠️ The cost of extension, asserted so it is a known property rather than
    /// a surprise: two kinds target videos, so the edge no longer decides.
    func testATagArrivingOnAVideoCannotBeResolvedAutomatically() {
        XCTAssertNil(TagKind.inferredKind(forTagArrivingOn: .video),
                     "action and video-attribute both apply — this must go to a human")
    }

    /// And the rule degrades correctly: with only one video kind available it
    /// resolves again. The ambiguity is in the vocabulary, not the algorithm.
    func testNarrowingResolvesWhenOnlyOneKindTargetsTheNode() {
        let onlyAction = [TagKind.action, TagKind.performerAttribute]

        XCTAssertEqual(TagKind.inferredKind(forTagArrivingOn: .video, from: onlyAction),
                       TagKind.action)
    }

    func testKindsTargetingANodeAreListedForTheWorklist() {
        let videoKinds = TagKind.kinds(targeting: .video)

        XCTAssertEqual(Set(videoKinds), [TagKind.action, TagKind.videoAttribute])
        XCTAssertEqual(TagKind.kinds(targeting: .performer), [TagKind.performerAttribute])
    }

    // MARK: - Case-insensitive identity

    /// The live defect: `SCUBA` (15 uses) and `Scuba` (1) were two rows for one
    /// tag, because nothing at the storage layer knew they were the same.
    func testCaseVariantsShareOneIdentity() {
        XCTAssertEqual(TagNormalizer.identityKey("SCUBA"),
                       TagNormalizer.identityKey("Scuba"))
        XCTAssertEqual(TagNormalizer.identityKey("Scuba"),
                       TagNormalizer.identityKey("scuba"))
    }

    func testDifferentTagsKeepDifferentIdentities() {
        XCTAssertNotEqual(TagNormalizer.identityKey("Climbing"),
                          TagNormalizer.identityKey("Climbdown"))
    }

    func testSurroundingWhitespaceIsNotIdentity() {
        XCTAssertEqual(TagNormalizer.identityKey("  Outdoors "),
                       TagNormalizer.identityKey("Outdoors"))
    }

    /// ⚠️ The invariant that keeps the index and the comparison from drifting.
    ///
    /// If these ever disagree, a lookup and a uniqueness constraint hold
    /// different opinions about what one entity is — a worse defect than the
    /// duplicate rows this replaces, and one that would surface as a mystery.
    func testIdentityKeyAgreesWithIsSameTag() {
        let samples = ["SCUBA", "Scuba", "scuba", "Outdoors", "outdoors",
                       "Café", "Cafe", "O'Brien", "o'brien", "MacLeod",
                       "Climbing", "Climbdown", "  Outdoors  "]

        for a in samples {
            for b in samples {
                XCTAssertEqual(
                    TagNormalizer.isSameTag(a.trimmingCharacters(in: .whitespaces),
                                            b.trimmingCharacters(in: .whitespaces)),
                    TagNormalizer.identityKey(a) == TagNormalizer.identityKey(b),
                    "identity disagreed for \"\(a)\" vs \"\(b)\"")
            }
        }
    }

    /// Identity folds; DISPLAY does not. The operator's capitals survive, which
    /// is the half of the decision that makes folding acceptable at all.
    func testFoldingIdentityDoesNotFlattenDisplay() {
        XCTAssertEqual(TagNormalizer.normalize(tagValue: "SCUBA"), "SCUBA")
        XCTAssertEqual(TagNormalizer.normalize(tagValue: "MacLeod"), "MacLeod")
        XCTAssertNotEqual(TagNormalizer.identityKey("SCUBA"), "SCUBA",
                          "the key is folded even though the display is not")
    }
}
