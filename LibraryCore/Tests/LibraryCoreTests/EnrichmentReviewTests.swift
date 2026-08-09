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
        adds.tags = ProposedField(["Tall", "Scuba"])
        XCTAssertEqual(change(review(profile(tags: ["Tall"]), adds), ActorEnrichment.Field.tags)?.kind,
                       .fill)

        var nothingNew = ActorMetadataProposal()
        nothingNew.tags = ProposedField(["Tall"])
        XCTAssertEqual(change(review(profile(tags: ["Tall"]), nothingNew), ActorEnrichment.Field.tags)?.kind,
                       .unchanged, "proposing what is already there is not a change")
    }

    func testCollectionUnionIsCaseInsensitiveAndKeepsExistingCasing() {
        var p = ActorMetadataProposal()
        p.tags = ProposedField(["TALL", "Freckled"])
        let merged = ActorEnrichment.apply(p, to: profile(tags: ["Tall"]),
                                           entityId: "actor:Jane",
                                           accepting: [ActorEnrichment.Field.tags])
        XCTAssertEqual(merged.tags, ["Tall", "Freckled"], "no case-variant duplicate")
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

    /// ⭐ STRENGTHENED 2026-08-08. This asserted that a differing photo appears
    /// as a `.conflict`; it now asserts the photo is not offered for
    /// replacement AT ALL once one exists.
    ///
    /// The original intent — "curated artwork is never silently replaced" — is
    /// preserved and made stronger: there is no longer a row that could be
    /// ticked to replace it, deliberately or otherwise.
    ///
    /// ⚠️ What changed is the reasoning. A differing photo URL is not a
    /// disagreement about WHO someone is, and listing it as one made every
    /// already-illustrated actor look like a conflict awaiting a decision.
    /// Choosing a picture belongs to the sheet's Photos section, which offers
    /// every image the source has rather than the single URL this row carried.
    func testAnExistingPhotoIsNotOfferedForReplacementAtAll() {
        var p = ActorMetadataProposal()
        p.photoURL = ProposedField(URL(string: "https://example.test/new.jpg")!)
        let r = review(profile(photoUrl: "https://example.test/curated.jpg"), p)
        XCTAssertNil(change(r, ActorEnrichment.Field.photoUrl),
                     "curated artwork is not even proposed for replacement")
    }

    /// ⚠️ ...but an actor with NO picture is still offered one. That is a gap,
    /// not a difference of opinion, and suppressing it would leave illustrated
    /// and unillustrated actors treated identically.
    func testAnActorWithNoPhotoIsStillOfferedOne() {
        var p = ActorMetadataProposal()
        p.photoURL = ProposedField(URL(string: "https://example.test/new.jpg")!)
        let r = review(profile(photoUrl: nil), p)
        XCTAssertEqual(change(r, ActorEnrichment.Field.photoUrl)?.kind, .fill)
    }

    // MARK: - Career span (schema v17)

    func testCareerFieldsNowLandRatherThanBeingDiscarded() {
        // Before v17 these were fetched over the network and dropped. This is
        // the assertion that they have somewhere to go.
        var p = ActorMetadataProposal()
        p.careerStartYear = ProposedField(2010, sourceNote: "Src")
        p.birthDate = ProposedField("1990-01-01", sourceNote: "Src")
        let r = review(profile(), p)

        XCTAssertEqual(change(r, ActorEnrichment.Field.careerStartYear)?.kind, .fill)
        XCTAssertEqual(change(r, ActorEnrichment.Field.birthDate)?.kind, .fill)

        let applied = ActorEnrichment.apply(p, to: profile(), entityId: "actor:A",
                                            accepting: r.defaultAccepted)
        XCTAssertEqual(applied.careerStartYear, 2010)
        XCTAssertEqual(applied.birthDate, "1990-01-01")
    }

    func testAnAbsentCareerEndNeverClearsARecordedOne() {
        // A missing end means the span is OPEN, not that the end should be
        // wiped. 75% of matched actors are in exactly this state.
        var p = ActorMetadataProposal()
        p.careerStartYear = ProposedField(2010)
        let existing = EntityProfile(id: "actor:A", careerStartYear: 2010, careerEndYear: 2014)
        let r = review(existing, p)
        XCTAssertEqual(change(r, ActorEnrichment.Field.careerEndYear)?.kind, .unchanged)

        let applied = ActorEnrichment.apply(p, to: existing, entityId: "actor:A",
                                            accepting: r.defaultAccepted)
        XCTAssertEqual(applied.careerEndYear, 2014)
    }

    func testADisagreeingBirthDateIsAConflictNotAFill() {
        var p = ActorMetadataProposal()
        p.birthDate = ProposedField("1992-04-18")
        let existing = EntityProfile(id: "actor:A", birthDate: "1997-01-01")
        XCTAssertEqual(change(review(existing, p), ActorEnrichment.Field.birthDate)?.kind,
                       .conflict)
    }

    // MARK: - External links (schema v19)

    func testExternalLinksNowLand() {
        // Superseded: these were proposed at 87.5% coverage and discarded for
        // want of a column. v19 gave them one.
        var p = ActorMetadataProposal()
        p.externalLinks = ProposedField([EntityLink(url: "https://example.test", label: "Example")])
        let r = review(profile(), p)
        XCTAssertTrue(r.hasAnythingToApply)
        XCTAssertEqual(change(r, ActorEnrichment.Field.links)?.kind, .fill)
    }

    func testTheReviewShowsLabelsRatherThanRawURLs() {
        // A wall of URLs is unreadable; the label is what the operator decides on.
        var p = ActorMetadataProposal()
        p.externalLinks = ProposedField([EntityLink(url: "https://a.test", label: "Somewhere")])
        XCTAssertEqual(change(review(profile(), p), ActorEnrichment.Field.links)?.proposed,
                       "Somewhere")
    }
}

// MARK: - Gallery photos

final class EnrichmentGalleryTests: XCTestCase {

    private func proposal(_ urls: [String]) -> ActorMetadataProposal {
        var p = ActorMetadataProposal()
        p.galleryURLs = .init(urls.compactMap(URL.init(string:)), sourceNote: "Src")
        return p
    }

    private func profile(gallery: [String]) -> EntityProfile {
        EntityProfile(id: "actor:A", galleryUrls: gallery)
    }

    func testNoPhotosAcceptedAddsNothing() {
        // The default. Photos cost bandwidth and storage per actor, so an empty
        // selection must be a true no-op rather than "import everything".
        let result = ActorEnrichment.apply(
            proposal(["https://x/1.jpg", "https://x/2.jpg"]),
            to: profile(gallery: ["https://x/keep.jpg"]),
            entityId: "actor:A",
            accepting: [])
        XCTAssertEqual(result.galleryUrls, ["https://x/keep.jpg"])
    }

    func testOnlyTickedPhotosAreAdded() {
        let result = ActorEnrichment.apply(
            proposal(["https://x/1.jpg", "https://x/2.jpg", "https://x/3.jpg"]),
            to: profile(gallery: []),
            entityId: "actor:A",
            accepting: [],
            acceptingGalleryURLs: ["https://x/1.jpg", "https://x/3.jpg"])
        XCTAssertEqual(result.galleryUrls, ["https://x/1.jpg", "https://x/3.jpg"])
    }

    func testCuratedPhotosAreNeverRemoved() {
        // Union, like tags and AKAs. Enrichment can add but never take away.
        let result = ActorEnrichment.apply(
            proposal(["https://x/new.jpg"]),
            to: profile(gallery: ["https://x/mine.jpg"]),
            entityId: "actor:A",
            accepting: [],
            acceptingGalleryURLs: ["https://x/new.jpg"])
        XCTAssertEqual(result.galleryUrls, ["https://x/mine.jpg", "https://x/new.jpg"])
    }

    func testExistingPhotoIsNotDuplicated() {
        let result = ActorEnrichment.apply(
            proposal(["https://x/same.jpg"]),
            to: profile(gallery: ["https://x/same.jpg"]),
            entityId: "actor:A",
            accepting: [],
            acceptingGalleryURLs: ["https://x/same.jpg"])
        XCTAssertEqual(result.galleryUrls, ["https://x/same.jpg"])
    }

    func testExistingOrderIsPreserved() {
        // A gallery that reshuffles on import looks like data loss.
        let result = ActorEnrichment.apply(
            proposal(["https://x/c.jpg"]),
            to: profile(gallery: ["https://x/a.jpg", "https://x/b.jpg"]),
            entityId: "actor:A",
            accepting: [],
            acceptingGalleryURLs: ["https://x/c.jpg"])
        XCTAssertEqual(result.galleryUrls,
                       ["https://x/a.jpg", "https://x/b.jpg", "https://x/c.jpg"])
    }

    func testGalleryIsUntouchedWhenTheSourceOffersNone() {
        let result = ActorEnrichment.apply(
            ActorMetadataProposal(),
            to: profile(gallery: ["https://x/a.jpg"]),
            entityId: "actor:A",
            accepting: [])
        XCTAssertEqual(result.galleryUrls, ["https://x/a.jpg"])
    }
}

// MARK: - Country carries a display flag; comparison must ignore it

final class EnrichmentCountryComparisonTests: XCTestCase {

    private func review(_ stored: String?, _ proposed: String?) -> ProposedChange? {
        var p = ActorMetadataProposal()
        p.countryOfOrigin = .init(proposed, sourceNote: "Src")
        let profile = EntityProfile(id: "actor:A", countryOfOrigin: stored)
        return ActorEnrichment.review(profile: profile, proposal: p, sourceName: "Src")
            .changes.first { $0.id == ActorEnrichment.Field.countryOfOrigin }
    }

    func testAStoredFlagDoesNotMakeAnIdenticalCountryLookLikeAConflict() {
        // Reported: every enrichment proposed replacing "US 🇺🇸" with "US".
        // A conflict on every actor is noise that teaches people to skim.
        XCTAssertEqual(review("US 🇺🇸", "US")?.kind, .unchanged)
        XCTAssertEqual(review("Russia 🇷🇺", "Russia")?.kind, .unchanged)
        XCTAssertEqual(review("Czech Republic 🇨🇿", "Czech Republic")?.kind, .unchanged)
    }

    func testARealCountryDisagreementIsStillAConflict() {
        // The fix must not make every country look identical.
        XCTAssertEqual(review("US 🇺🇸", "Hungary")?.kind, .conflict)
        XCTAssertEqual(review("UK 🇬🇧", "US")?.kind, .conflict)
    }

    func testABlankCountryIsStillAFill() {
        XCTAssertEqual(review(nil, "Hungary")?.kind, .fill)
    }

    func testComparisonIsCaseInsensitive() {
        XCTAssertEqual(review("hungary", "Hungary")?.kind, .unchanged)
    }

    func testTheSourceSayingNothingIsNeverAChange() {
        XCTAssertEqual(review("US 🇺🇸", nil)?.kind, .unchanged)
    }

    func testTheKeyStripsOnlyDecoration() {
        XCTAssertEqual(ActorEnrichment.countryKey("US 🇺🇸"), "us")
        XCTAssertEqual(ActorEnrichment.countryKey("Czech Republic 🇨🇿"), "czech republic")
        XCTAssertNotEqual(ActorEnrichment.countryKey("US"), ActorEnrichment.countryKey("Hungary"))
    }
}
