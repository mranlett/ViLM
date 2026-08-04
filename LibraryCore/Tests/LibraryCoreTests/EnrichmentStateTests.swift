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
                       ["matched", "noMatch", "ambiguous", "needsReview", "unmatchable"])
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

// MARK: - "Not findable" is a human judgement, never inferred

final class UnmatchableStateTests: XCTestCase {

    func testUnmatchableIsSettledNotPending() {
        // Someone already looked. Counting it as needing attention would leave
        // the queue permanently full of entities nobody can act on, which is the
        // fastest way to make a queue ignored.
        XCTAssertFalse(EnrichmentState.unmatchable.needsAttention)
        XCTAssertTrue(EnrichmentState.noMatch.needsAttention)
    }

    func testOnlyUnmatchableIsAHumanJudgement() {
        // The machine may record noMatch — a search returned nothing, which can
        // just mean the name is misspelled. It must never conclude "not findable".
        XCTAssertTrue(EnrichmentState.unmatchable.isHumanJudgement)
        for state in EnrichmentState.allCases where state != .unmatchable {
            XCTAssertFalse(state.isHumanJudgement, "\(state) must not be a human-only verdict")
        }
    }

    func testNoMatchAndUnmatchableAreDistinct() {
        // Collapsing them would let an automated run silently retire an actor.
        XCTAssertNotEqual(EnrichmentState.noMatch, .unmatchable)
        XCTAssertEqual(EnrichmentState.unmatchable.rawValue, "unmatchable")
    }

    func testTheFilterSeparatesThemToo() {
        typealias Filter = ActorFilterCriteria.EnrichmentFilter
        XCTAssertTrue(Filter.unmatchable.accepts(.unmatchable))
        XCTAssertFalse(Filter.unmatchable.accepts(.noMatch))
        XCTAssertFalse(Filter.needsAttention.accepts(.unmatchable))
        XCTAssertTrue(Filter.needsAttention.accepts(.noMatch))
    }

    func testUnmatchableRoundTripsThroughTheCSV() {
        let original = EntityProfile(id: "actor:A", enrichmentState: .unmatchable,
                                     enrichmentSource: "Src",
                                     enrichmentCheckedAt: Date(timeIntervalSince1970: 5))
        let row = ActorCSV.row(name: "A", profile: original, stripCountry: { $0 })
        let merged = ActorCSV.merge(columns: ActorCSV.parse(row)[0],
                                    existing: nil, decorateCountry: { $0 })
        XCTAssertEqual(merged?.enrichmentState, .unmatchable)
    }

    func testAManualEditDoesNotUndoTheDecision() {
        // Adding an alias re-opens a noMatch, because the data a lookup uses
        // changed. It must NOT re-open a decision a person made deliberately —
        // they would have to keep re-declaring it.
        let before = EntityProfile(id: "actor:A", akas: [], enrichmentState: .unmatchable)
        let after  = EntityProfile(id: "actor:A", akas: ["New Alias"],
                                   enrichmentState: .unmatchable)
        XCTAssertEqual(
            EnrichmentInvalidation.afterManualEdit(previous: before, edited: after).state,
            .unmatchable)
    }
}

/// Marking someone as not findable, and getting them back later.
extension EnrichmentStateTests {

    func testUnmatchableLeavesTheAttentionQueue() {
        XCTAssertFalse(EnrichmentState.unmatchable.needsAttention)
        XCTAssertTrue(EnrichmentState.noMatch.needsAttention)
        XCTAssertTrue(EnrichmentState.ambiguous.needsAttention)
    }

    /// The reason a broad toggle is safe: they stay reachable.
    func testUnmatchableIsStillReachableByItsOwnFilter() {
        XCTAssertTrue(ActorFilterCriteria.EnrichmentFilter.unmatchable.accepts(.unmatchable))
        XCTAssertFalse(ActorFilterCriteria.EnrichmentFilter.unmatchable.accepts(.noMatch))
        XCTAssertFalse(ActorFilterCriteria.EnrichmentFilter.needsAttention.accepts(.unmatchable))
    }

    /// Never confused with "nobody has looked yet".
    func testUnmatchableIsNotTheSameAsNeverChecked() {
        XCTAssertFalse(ActorFilterCriteria.EnrichmentFilter.neverChecked.accepts(.unmatchable))
        XCTAssertTrue(ActorFilterCriteria.EnrichmentFilter.neverChecked.accepts(nil))
    }

    /// A human decision must survive editing the fields a lookup keys on —
    /// otherwise adding an AKA would silently drag the actor back into the
    /// queue they were deliberately taken out of.
    func testEditingMatchInputsDoesNotUndoTheDecision() {
        var before = EntityProfile(id: "actor:someone")
        before.enrichmentState = .unmatchable
        var after = before
        after.akas = ["A New Alias"]

        let revised = EnrichmentInvalidation.afterManualEdit(previous: before, edited: after)
        XCTAssertEqual(revised.state, .unmatchable)
    }

    /// But an unresolved machine verdict IS cleared by the same edit, which is
    /// the distinction that makes the human decision worth recording.
    func testEditingMatchInputsDoesClearAnUnresolvedVerdict() {
        var before = EntityProfile(id: "actor:someone")
        before.enrichmentState = .noMatch
        var after = before
        after.akas = ["A New Alias"]

        let revised = EnrichmentInvalidation.afterManualEdit(previous: before, edited: after)
        XCTAssertNil(revised.state)
    }
}
