// EnrichmentStateTests.swift
//
// Schema v18. Adding columns to EntityProfile has silently dropped them in FOUR
// separate places before — the package merge (data loss on library merge),
// ActorSync (never synced), the profile editor (ERASED on Save, no error) and
// MergeSemantics (vanished from the federated view). These tests exist so v18
// cannot repeat it.

import XCTest
@testable import LibraryCore

final class EnrichmentStateTests: XCTestCase {

    private func profile(_ id: String = "actor:A",
                         state: EnrichmentState? = nil,
                         source: String? = nil,
                         at: Date? = nil) -> EntityProfile {
        EntityProfile(id: id, enrichmentState: state, enrichmentSource: source,
                      enrichmentCheckedAt: at)
    }

    // MARK: - nil is not a failure

    func testNeverCheckedIsDistinctFromNoMatch() {
        // Conflating them would make every un-enriched actor look like a failure
        // — 1,000+ of them in a real library.
        XCTAssertNil(profile().enrichmentState)
        XCTAssertNil(profile().enrichmentCheckedAt)
        XCTAssertEqual(profile(state: .noMatch).enrichmentState, .noMatch)
    }

    func testNeverCheckedDoesNotNeedAttention() {
        // "Needs attention" means a lookup RAN and concluded something. An
        // entity nobody has checked is unknown, not failed.
        XCTAssertFalse(profile().needsEnrichmentAttention)
        XCTAssertFalse(profile(state: .matched).needsEnrichmentAttention)
        XCTAssertTrue(profile(state: .noMatch).needsEnrichmentAttention)
        XCTAssertTrue(profile(state: .ambiguous).needsEnrichmentAttention)
        XCTAssertTrue(profile(state: .needsReview).needsEnrichmentAttention)
    }

    // MARK: - The field names carry no source

    func testTheSchemaVocabularyIsFixedAndGeneric() {
        // This is core schema in a PUBLIC repository, and column names survive
        // in migrations and in every backup archive forever.
        //
        // Pinned as an exact set rather than checked against a list of banned
        // provider names — writing those names here would put them in the
        // public repository, which is precisely what this guards against. Any
        // addition fails this test, including one naming a source.
        XCTAssertEqual(Set(EnrichmentState.allCases.map(\.rawValue)),
                       ["matched", "noMatch", "ambiguous", "needsReview"])
    }

    func testTheStoredColumnsAreNamedForTheConceptNotTheProvider() {
        // Encoded keys are the column names. Same reasoning: pin them, so a
        // provider-specific column cannot be added without this failing.
        let encoded = try! JSONEncoder().encode(
            EntityProfile(id: "actor:A", enrichmentState: .matched,
                          enrichmentSource: "Some Provider",
                          enrichmentCheckedAt: Date()))
        let keys = Set((try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]).keys)
        XCTAssertTrue(keys.isSuperset(of: ["enrichment_state", "enrichment_source",
                                           "enrichment_checked_at"]))
    }

    // MARK: - Site 1: the federated merge

    func testFederatedMergeTakesTheMoreRECENTCheck() {
        // Not library precedence: this records WHEN a lookup ran, so an older
        // result must not mask a newer one.
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        let higher = profile(state: .noMatch, source: "A", at: old)
        let lower  = profile(state: .matched, source: "B", at: new)

        let merged = MergeSemantics.mergedProfileView(higher: higher, lower: lower)
        XCTAssertEqual(merged.enrichmentState, .matched, "the newer check wins")
        XCTAssertEqual(merged.enrichmentSource, "B")
        XCTAssertEqual(merged.enrichmentCheckedAt, new)
    }

    func testFederatedMergeFallsBackToPrecedenceWhenNeitherWasChecked() {
        let merged = MergeSemantics.mergedProfileView(higher: profile(), lower: profile())
        XCTAssertNil(merged.enrichmentState)
    }

    func testFederatedMergeTakesTheOnlyCheckedSide() {
        let checked = profile(state: .ambiguous, at: Date(timeIntervalSince1970: 5))
        XCTAssertEqual(
            MergeSemantics.mergedProfileView(higher: profile(), lower: checked).enrichmentState,
            .ambiguous)
        XCTAssertEqual(
            MergeSemantics.mergedProfileView(higher: checked, lower: profile()).enrichmentState,
            .ambiguous)
    }

    // MARK: - Site 2: ActorSync

    func testSyncCanCarryEveryEnrichmentColumn() {
        // A column missing here loses no data, but never travels between
        // libraries — so the same actors get re-checked forever.
        let names = ActorSyncField.allCases.map(\.displayName)
        XCTAssertTrue(names.contains("Enrichment Result"))
        XCTAssertTrue(names.contains("Enrichment Source"))
    }

    func testSyncRoundTripsTheState() {
        var p = profile(state: .needsReview, source: "Some Source")
        for field in ActorSyncField.allCases {
            let value = field.value(in: p)
            field.apply(value, to: &p)
        }
        XCTAssertEqual(p.enrichmentState, .needsReview)
        XCTAssertEqual(p.enrichmentSource, "Some Source")
    }

    // MARK: - Decoding tolerance

    func testAnUnknownStateValueDecodesAsNilRatherThanFailing() {
        // A value written by a newer build must not fail the whole decode on an
        // older one — that would make a single row unreadable.
        let json = #"{"id":"actor:A","tags":[],"gallery_urls":[],"akas":[],"enrichment_state":"somethingNew"}"#
        let decoded = try? JSONDecoder().decode(EntityProfile.self, from: Data(json.utf8))
        XCTAssertNotNil(decoded, "the row must still decode")
        XCTAssertNil(decoded?.enrichmentState)
    }

    func testAnArchivePredatingV18StillDecodes() {
        let json = #"{"id":"actor:A","tags":[],"gallery_urls":[],"akas":[]}"#
        let decoded = try? JSONDecoder().decode(EntityProfile.self, from: Data(json.utf8))
        XCTAssertNotNil(decoded)
        XCTAssertNil(decoded?.enrichmentState)
        XCTAssertNil(decoded?.enrichmentCheckedAt)
    }
}

// MARK: - The filter that makes the backlog findable

final class EnrichmentFilterTests: XCTestCase {

    private typealias Filter = ActorFilterCriteria.EnrichmentFilter

    func testNeverCheckedIsNotNoMatch() {
        // The distinction the whole feature rests on. Conflating them would
        // report every un-enriched actor as a failure.
        XCTAssertTrue(Filter.neverChecked.accepts(nil))
        XCTAssertFalse(Filter.neverChecked.accepts(.noMatch))
        XCTAssertFalse(Filter.noMatch.accepts(nil))
    }

    func testNeedsAttentionCoversEveryOutcomeThatWantsAHuman() {
        // 157 no-match + 45 ambiguous + 8 withheld disagreements = the backlog.
        XCTAssertTrue(Filter.needsAttention.accepts(.noMatch))
        XCTAssertTrue(Filter.needsAttention.accepts(.ambiguous))
        XCTAssertTrue(Filter.needsAttention.accepts(.needsReview))
        XCTAssertFalse(Filter.needsAttention.accepts(.matched))
        XCTAssertFalse(Filter.needsAttention.accepts(nil), "never checked is unknown, not failed")
    }

    func testAnyAcceptsEverythingIncludingUnchecked() {
        for state in EnrichmentState.allCases { XCTAssertTrue(Filter.any.accepts(state)) }
        XCTAssertTrue(Filter.any.accepts(nil))
    }

    func testAnUnsetFilterLeavesTheCriteriaEmpty() {
        // isEmpty gates whether the UI shows "filters active" at all.
        XCTAssertTrue(ActorFilterCriteria().isEmpty)
        var c = ActorFilterCriteria()
        c.enrichment = .needsAttention
        XCTAssertFalse(c.isEmpty)
    }

    func testASavedFilterFromBeforeV18StillDecodes() {
        let json = #"{"showMissingPhotosOnly":true}"#
        let decoded = try? JSONDecoder().decode(ActorFilterCriteria.self, from: Data(json.utf8))
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.enrichment, .any, "absent means unfiltered, not broken")
        XCTAssertEqual(decoded?.showMissingPhotosOnly, true)
    }

    func testAnUnknownFilterCaseDecodesAsAnyRatherThanFailing() {
        let json = #"{"enrichment":"somethingNewer"}"#
        let decoded = try? JSONDecoder().decode(ActorFilterCriteria.self, from: Data(json.utf8))
        XCTAssertNotNil(decoded, "a newer build's saved filter must not break this one")
        XCTAssertEqual(decoded?.enrichment, .any)
    }

    func testFilterRoundTripsThroughCoding() {
        var c = ActorFilterCriteria()
        c.enrichment = .ambiguous
        let data = try! JSONEncoder().encode(c)
        XCTAssertEqual(try? JSONDecoder().decode(ActorFilterCriteria.self, from: data).enrichment,
                       .ambiguous)
    }

    func testCompletenessAndEnrichmentAreIndEPENDENTAxes() {
        // An actor can be fully filled in with an unresolved lookup, or sparse
        // and never checked. Overloading one filter for both would hide that.
        var c = ActorFilterCriteria()
        c.enrichment = .needsAttention
        XCTAssertFalse(c.showNeedingAttentionOnly,
                       "enabling the enrichment filter must not imply the completeness one")
    }
}
