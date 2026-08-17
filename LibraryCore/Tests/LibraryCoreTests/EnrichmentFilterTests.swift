// EnrichmentFilterTests.swift
// The filter an operator uses to find work, and whether it can be trusted.
//
// ⚠️ All names invented. This repository is public.

import XCTest
@testable import LibraryCore

final class EnrichmentFilterTrustTests: XCTestCase {

    // MARK: - 🚨 "Anything I have not resolved"

    /// ⚠️ `needsAttention` deliberately EXCLUDES never-checked — unknown is not
    /// failed, and conflating them reports every un-enriched record as a
    /// failure. That distinction is asserted in `EnrichmentStateTests` and is
    /// load-bearing for actors, which share this type by typealias.
    ///
    /// So the filter an operator actually wants — "what still needs me" — was
    /// two filters and a mental union. This is the union, added rather than
    /// achieved by widening the other and breaking it.
    func testNotResolvedSpansUnknownAndUnresolved() {
        XCTAssertTrue(EnrichmentFilter.notResolved.accepts(nil), "never looked at")
        XCTAssertTrue(EnrichmentFilter.notResolved.accepts(.noMatch))
        XCTAssertTrue(EnrichmentFilter.notResolved.accepts(.ambiguous))
    }

    /// And it excludes what IS settled — including the operator's own
    /// judgement that a video cannot be found.
    func testNotResolvedExcludesEverythingSettled() {
        XCTAssertFalse(EnrichmentFilter.notResolved.accepts(.matched))
        XCTAssertFalse(EnrichmentFilter.notResolved.accepts(.unmatchable),
                       "they decided; that is resolved")
        XCTAssertFalse(EnrichmentFilter.notResolved.accepts(
            .matched, route: VerifiedElsewhere.handVerifiedRoute))
    }

    /// 🚨 The distinction that was nearly destroyed. Pinned here as well as in
    /// EnrichmentStateTests, because it was a change I proposed and had to take
    /// back: widening `needsAttention` would have made every un-enriched ACTOR
    /// read as a failure.
    func testNeedsAttentionStillExcludesNeverChecked() {
        XCTAssertFalse(EnrichmentFilter.needsAttention.accepts(nil))
    }

    func testTheUnresolvedStatesStillNeedAttention() {
        for state in [EnrichmentState.noMatch, .ambiguous, .needsReview] {
            XCTAssertTrue(EnrichmentFilter.needsAttention.accepts(state), "\(state)")
        }
    }

    /// ⚠️ And the resolved ones still do not — including a hand-verified video,
    /// which is the whole reason it is recorded as `.matched`.
    func testResolvedRecordsDoNotNeedAttention() {
        XCTAssertFalse(EnrichmentFilter.needsAttention.accepts(.matched))
        XCTAssertFalse(EnrichmentFilter.needsAttention.accepts(.unmatchable))
        XCTAssertFalse(EnrichmentFilter.needsAttention.accepts(
            .matched, route: VerifiedElsewhere.handVerifiedRoute))
    }

    // MARK: - Telling your own work from the source's

    /// 🚨 Both say "we know what this is", but one is a fingerprint and the
    /// other is the operator's judgement from a page. Folding them together
    /// makes their own work unreviewable.
    func testVerifiedByHandIsDistinguishableFromAProviderMatch() {
        XCTAssertTrue(EnrichmentFilter.verifiedByHand.accepts(
            .matched, route: VerifiedElsewhere.handVerifiedRoute))
        XCTAssertFalse(EnrichmentFilter.verifiedByHand.accepts(.matched, route: "fingerprint"))
        XCTAssertFalse(EnrichmentFilter.verifiedByHand.accepts(.matched, route: nil))
    }

    /// ⚠️ The route alone is not enough. A cleared verification leaves no
    /// state, and a record with a leftover route but no match is not verified.
    func testTheStateAndTheRouteAreBothRequired() {
        XCTAssertFalse(EnrichmentFilter.verifiedByHand.accepts(
            nil, route: VerifiedElsewhere.handVerifiedRoute))
        XCTAssertFalse(EnrichmentFilter.verifiedByHand.accepts(
            .noMatch, route: VerifiedElsewhere.handVerifiedRoute))
    }

    /// ⭐ End to end through the real writer, so the filter and the recording
    /// cannot drift apart — they share one constant.
    func testWhatVerifiedElsewhereWritesIsWhatTheFilterFinds() {
        let asset = Asset(relativePath: "a.mp4", fileName: "a.mp4", contentKind: .scene)
        let recorded = VerifiedElsewhere.applying(
            ExternalVerification(source: "A Catalogue"), to: asset)

        var criteria = AssetFilterCriteria()
        let profiles = EntityProfileIndex([])
        func matches(_ a: Asset) -> Bool {
            criteria.matches(a, mappedActors: [], entityProfiles: profiles)
        }

        criteria.enrichment = .verifiedByHand
        XCTAssertTrue(matches(recorded))

        criteria.enrichment = .needsAttention
        XCTAssertFalse(matches(recorded), "it is resolved, so it is not work")

        let cleared = VerifiedElsewhere.clearing(from: recorded)
        criteria.enrichment = .verifiedByHand
        XCTAssertFalse(matches(cleared))
        // ⚠️ `notResolved`, not `needsAttention`. Clearing leaves NO state, and
        // "never looked at" is deliberately outside `needsAttention` — which is
        // exactly why the union case had to exist rather than the other being
        // widened.
        criteria.enrichment = .notResolved
        XCTAssertTrue(matches(cleared), "and clearing puts it back in the queue")
        criteria.enrichment = .needsAttention
        XCTAssertFalse(matches(cleared), "unknown is not failed")
    }

    // MARK: - 🚨 A saved collection survives a case it does not know

    /// A smart collection stores this by raw value, and the synthesized decoder
    /// THROWS on an unknown one — taking the whole filter down with it, which
    /// reads as a corrupted collection rather than an unfamiliar word.
    ///
    /// ⚠️ `ActorFilterCriteria` worked around this at its own call site;
    /// `AssetFilterCriteria` had no custom decoder and was unprotected. Fixed
    /// on the type, so both are covered and neither has to remember.
    func testAnUnknownCaseDecodesToAnyRatherThanThrowing() throws {
        let data = Data(#""somethingFromANewerBuild""#.utf8)
        let decoded = try JSONDecoder().decode(EnrichmentFilter.self, from: data)
        XCTAssertEqual(decoded, .any, "showing more is the safe direction")
    }

    func testAKnownCaseStillDecodesNormally() throws {
        let data = Data(#""verifiedByHand""#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(EnrichmentFilter.self, from: data),
                       .verifiedByHand)
    }

    /// And a whole SAVED filter survives it, which is the failure that would
    /// actually be seen — a smart collection written by a newer build.
    ///
    /// ⚠️ Built by round-tripping a real criteria and substituting the value,
    /// rather than by hand-writing partial JSON. `AssetFilterCriteria` decodes
    /// STRICTLY — Swift's synthesized decoder ignores property defaults, so
    /// every key must be present — and a hand-written fragment fails on the
    /// first missing key instead of on the thing under test. That strictness is
    /// a separate fragility and is NOT what this fixes.
    func testASavedFilterSurvivesAnUnknownCase() throws {
        var original = AssetFilterCriteria()
        original.enrichment = .matched
        let encoded = try JSONEncoder().encode(original)
        var text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        text = text.replacingOccurrences(of: "\"matched\"",
                                         with: "\"somethingFromANewerBuild\"")

        let decoded = try JSONDecoder().decode(AssetFilterCriteria.self,
                                               from: Data(text.utf8))
        XCTAssertEqual(decoded.enrichment, .any,
                       "an unfamiliar word must not take the whole collection down")
    }

    // MARK: - ⚠️ The shared type

    /// `ActorFilterCriteria.EnrichmentFilter` is a TYPEALIAS to this one, so a
    /// case removed here disappears from the actor filter too. `needsReview` is
    /// set by the actor enrichment path and must not be removed as "unused"
    /// because no video carries it.
    func testNeedsReviewIsStillReachableBecauseTheTypeIsShared() {
        XCTAssertTrue(EnrichmentFilter.allCases.contains(.needsReview))
        XCTAssertTrue(EnrichmentFilter.needsReview.accepts(.needsReview))
    }
}
