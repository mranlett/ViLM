import XCTest
@testable import LibraryCore

/// Tests for the merge policy and review model (Plugin Architecture, D5).
///
/// These cover T4 (non-destructive merge), T5 (conflicts never auto-applied) and
/// the structural half of T6 — a plugin returns a proposal and nothing else, so
/// every write goes through `apply` with an explicit accept set.
final class EnrichmentReviewTests: XCTestCase {

    private func profile(
        bio: String? = nil, photoUrl: String? = nil, gender: String? = nil,
        hairColor: String? = nil, birthYear: Int? = nil, country: String? = nil,
        rating: Int? = nil, tags: [String] = [], gallery: [String] = [], akas: [String] = []
    ) -> EntityProfile {
        EntityProfile(id: "actor:Jane", bio: bio, photoUrl: photoUrl, homePage: "home",
                      gender: gender, hairColor: hairColor, birthYear: birthYear,
                      countryOfOrigin: country, rating: rating, tags: tags,
                      galleryUrls: gallery, akas: akas,
                      createdAt: Date(timeIntervalSince1970: 0))
    }

    private func review(_ p: EntityProfile?, _ proposal: ActorMetadataProposal) -> EnrichmentReview {
        ActorEnrichment.review(profile: p, proposal: proposal, sourceName: "Test Source")
    }

    private func change(_ r: EnrichmentReview, _ id: String) -> ProposedChange? {
        r.changes.first { $0.id == id }
    }

    // MARK: - Classification

    func testAValueIntoAnEmptyFieldIsAFill() {
        var p = ActorMetadataProposal()
        p.bio = ProposedField("a bio")
        let r = review(profile(), p)
        XCTAssertEqual(change(r, ActorEnrichment.Field.bio)?.kind, .fill)
    }

    func testADifferentValueOverAPopulatedFieldIsAConflict() {
        var p = ActorMetadataProposal()
        p.hairColor = ProposedField("Blonde")
        let r = review(profile(hairColor: "Brown"), p)
        let c = change(r, ActorEnrichment.Field.hairColor)
        XCTAssertEqual(c?.kind, .conflict)
        XCTAssertEqual(c?.current, "Brown")
        XCTAssertEqual(c?.proposed, "Blonde")
    }

    func testTheSameValueIsUnchanged() {
        var p = ActorMetadataProposal()
        p.gender = ProposedField("Female")
        let r = review(profile(gender: "Female"), p)
        XCTAssertEqual(change(r, ActorEnrichment.Field.gender)?.kind, .unchanged)
    }

    /// The rule the whole policy rests on.
    func testASILENTSourceIsUnchangedAndNeverClearsAPopulatedField() {
        let p = ActorMetadataProposal()          // proposes nothing at all
        let r = review(profile(bio: "kept", hairColor: "Brown", birthYear: 1990), p)
        XCTAssertTrue(r.changes.allSatisfy { $0.kind == .unchanged })
        XCTAssertFalse(r.hasAnythingToApply)

        let merged = ActorEnrichment.apply(p, to: profile(bio: "kept", hairColor: "Brown", birthYear: 1990),
                                           entityId: "actor:Jane", accepting: ActorEnrichment.Field.all.reduce(into: Set()) { $0.insert($1) })
        XCTAssertEqual(merged.bio, "kept", "accepting everything must still not clear on silence")
        XCTAssertEqual(merged.hairColor, "Brown")
        XCTAssertEqual(merged.birthYear, 1990)
    }

    func testWhitespaceOnlyValuesCountAsEmptyOnBothSides() {
        var p = ActorMetadataProposal()
        p.bio = ProposedField("   ")
        let r = review(profile(bio: "  "), p)
        let c = change(r, ActorEnrichment.Field.bio)
        XCTAssertEqual(c?.kind, .unchanged)
        XCTAssertNil(c?.current)
        XCTAssertNil(c?.proposed)
    }

    // MARK: - T5 — conflicts are never auto-applied

    func testDefaultSelectionTicksFillsAndNotConflicts() {
        var p = ActorMetadataProposal()
        p.bio = ProposedField("new bio")            // fill
        p.hairColor = ProposedField("Blonde")       // conflict
        let r = review(profile(hairColor: "Brown"), p)

        XCTAssertEqual(r.defaultAccepted, [ActorEnrichment.Field.bio])
        XCTAssertFalse(r.defaultAccepted.contains(ActorEnrichment.Field.hairColor),
                       "a disagreement must never be pre-ticked")
    }

    func testApplyingTheDefaultSelectionLeavesConflictsUntouched() {
        var p = ActorMetadataProposal()
        p.bio = ProposedField("new bio")
        p.hairColor = ProposedField("Blonde")
        let existing = profile(hairColor: "Brown")
        let r = review(existing, p)

        let merged = ActorEnrichment.apply(p, to: existing, entityId: "actor:Jane",
                                           accepting: r.defaultAccepted)
        XCTAssertEqual(merged.bio, "new bio", "the fill lands")
        XCTAssertEqual(merged.hairColor, "Brown", "the conflict does NOT")
    }

    func testAConflictIsAppliedONLYWhenExplicitlyAccepted() {
        var p = ActorMetadataProposal()
        p.hairColor = ProposedField("Blonde")
        let existing = profile(hairColor: "Brown")
        let merged = ActorEnrichment.apply(p, to: existing, entityId: "actor:Jane",
                                           accepting: [ActorEnrichment.Field.hairColor])
        XCTAssertEqual(merged.hairColor, "Blonde")
    }

    // MARK: - T4 — non-destructive

    func testFieldsNotAcceptedAreLeftExactlyAsTheyWere() {
        var p = ActorMetadataProposal()
        p.bio = ProposedField("proposed")
        p.gender = ProposedField("Male")
        let existing = profile(bio: "original", gender: "Female")
        let merged = ActorEnrichment.apply(p, to: existing, entityId: "actor:Jane", accepting: [])
        XCTAssertEqual(merged.bio, "original")
        XCTAssertEqual(merged.gender, "Female")
    }

    func testCuratedFieldsAreNeverProposableAndAlwaysSurvive() {
        var p = ActorMetadataProposal()
        p.bio = ProposedField("new")
        let existing = profile(bio: "old", rating: 5, gallery: ["g1", "g2"])
        let merged = ActorEnrichment.apply(p, to: existing, entityId: "actor:Jane",
                                           accepting: Set(ActorEnrichment.Field.all))
        XCTAssertEqual(merged.rating, 5, "rating is user-authored; no plugin may touch it")
        XCTAssertEqual(merged.galleryUrls, ["g1", "g2"], "curated gallery survives")
        XCTAssertEqual(merged.homePage, "home", "not proposable, so preserved")
    }

    func testCreatedAtIsPreservedFromTheExistingProfile() {
        let existing = profile()
        let merged = ActorEnrichment.apply(ActorMetadataProposal(), to: existing,
                                           entityId: "actor:Jane", accepting: [],
                                           now: Date(timeIntervalSince1970: 999))
        XCTAssertEqual(merged.createdAt, Date(timeIntervalSince1970: 0))
    }

    func testANewProfileCanBeCreatedFromAProposal() {
        var p = ActorMetadataProposal()
        p.bio = ProposedField("a bio")
        p.birthYear = ProposedField(1990)
        let r = review(nil, p)
        XCTAssertEqual(r.fills.count, 2, "everything is a fill when there is no profile")

        let merged = ActorEnrichment.apply(p, to: nil, entityId: "actor:Jane",
                                           accepting: r.defaultAccepted,
                                           now: Date(timeIntervalSince1970: 500))
        XCTAssertEqual(merged.bio, "a bio")
        XCTAssertEqual(merged.birthYear, 1990)
        XCTAssertEqual(merged.createdAt, Date(timeIntervalSince1970: 500))
    }

    // MARK: - Collections union, never replace

    func testCollectionsUnionSoNothingCuratedIsLost() {
        var p = ActorMetadataProposal()
        p.akas = ProposedField(["Janet", "J.D."])
        let existing = profile(akas: ["Jane Doe"])
        let merged = ActorEnrichment.apply(p, to: existing, entityId: "actor:Jane",
                                           accepting: [ActorEnrichment.Field.akas])
        XCTAssertEqual(merged.akas, ["Jane Doe", "Janet", "J.D."],
                       "existing entries lead, additions follow")
    }

    func testACollectionProposalIsAFillWhenItAddsAndUnchangedWhenItDoesNot() {
        var adds = ActorMetadataProposal()
        adds.tags = ProposedField(["Redhead", "Scuba"])
        XCTAssertEqual(change(review(profile(tags: ["Redhead"]), adds), ActorEnrichment.Field.tags)?.kind,
                       .fill)

        var nothingNew = ActorMetadataProposal()
        nothingNew.tags = ProposedField(["Redhead"])
        XCTAssertEqual(change(review(profile(tags: ["Redhead"]), nothingNew), ActorEnrichment.Field.tags)?.kind,
                       .unchanged, "proposing what is already there is not a change")
    }

    func testCollectionUnionIsCaseInsensitiveAndKeepsExistingCasing() {
        var p = ActorMetadataProposal()
        p.tags = ProposedField(["REDHEAD", "Regional"])
        let merged = ActorEnrichment.apply(p, to: profile(tags: ["Redhead"]),
                                           entityId: "actor:Jane",
                                           accepting: [ActorEnrichment.Field.tags])
        XCTAssertEqual(merged.tags, ["Redhead", "Regional"], "no case-variant duplicate")
    }

    func testACollectionIsNeverAConflict() {
        var p = ActorMetadataProposal()
        p.akas = ProposedField(["Totally", "Different"])
        let r = review(profile(akas: ["Existing"]), p)
        XCTAssertNotEqual(change(r, ActorEnrichment.Field.akas)?.kind, .conflict,
                          "union semantics mean nothing is at risk, so there is nothing to arbitrate")
    }

    // MARK: - Review shape

    func testTheReviewPartitionsEveryFieldExactlyOnce() {
        var p = ActorMetadataProposal()
        p.bio = ProposedField("new")
        p.hairColor = ProposedField("Blonde")
        let r = review(profile(hairColor: "Brown"), p)
        XCTAssertEqual(r.fills.count + r.conflicts.count + r.unchanged.count, r.changes.count)
        XCTAssertEqual(Set(r.changes.map(\.id)).count, r.changes.count, "no duplicate field rows")
        XCTAssertEqual(Set(r.changes.map(\.id)), Set(ActorEnrichment.Field.all),
                       "every reviewable field appears, so nothing is silently skipped")
    }

    func testAnEmptyProposalReportsNothingToApply() {
        let r = review(profile(bio: "x"), ActorMetadataProposal())
        XCTAssertFalse(r.hasAnythingToApply)
        XCTAssertTrue(r.actionable.isEmpty)
        XCTAssertTrue(r.defaultAccepted.isEmpty)
    }

    func testTheSourceNoteReachesTheReviewRow() {
        var p = ActorMetadataProposal()
        p.bio = ProposedField("a bio", sourceNote: "Example Source")
        let r = review(profile(), p)
        XCTAssertEqual(change(r, ActorEnrichment.Field.bio)?.sourceNote, "Example Source")
        XCTAssertEqual(r.sourceName, "Test Source")
    }

    func testTheProposedPhotoURLIsRenderedAsAString() {
        var p = ActorMetadataProposal()
        p.photoURL = ProposedField(URL(string: "https://example.test/p.jpg")!)
        let r = review(profile(), p)
        XCTAssertEqual(change(r, ActorEnrichment.Field.photoUrl)?.proposed,
                       "https://example.test/p.jpg")

        let merged = ActorEnrichment.apply(p, to: nil, entityId: "actor:Jane",
                                           accepting: [ActorEnrichment.Field.photoUrl])
        XCTAssertEqual(merged.photoUrl, "https://example.test/p.jpg")
    }

    func testAnExistingPhotoIsAConflictRatherThanASilentReplacement() {
        var p = ActorMetadataProposal()
        p.photoURL = ProposedField(URL(string: "https://example.test/new.jpg")!)
        let r = review(profile(photoUrl: "https://example.test/curated.jpg"), p)
        XCTAssertEqual(change(r, ActorEnrichment.Field.photoUrl)?.kind, .conflict,
                       "curated artwork is never silently replaced")
    }

    // MARK: - Fields the schema cannot yet hold

    func testProposedFieldsWithNoStorageAreIgnoredRatherThanInvented() {
        var p = ActorMetadataProposal()
        p.careerStartYear = ProposedField(2010)
        p.birthDate = ProposedField("1990-01-01")
        p.externalLinks = ProposedField([URL(string: "https://example.test")!])
        let r = review(profile(), p)
        XCTAssertFalse(r.hasAnythingToApply,
                       "a proposal core cannot store yet must not appear as an applicable change")
    }
}
