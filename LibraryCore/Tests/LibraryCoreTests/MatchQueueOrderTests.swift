import XCTest
@testable import LibraryCore

/// How a disambiguation queue is arranged, and how a video's reason survives.
///
/// ⭐ The operator's ask: *"the 1 option Fingerprint matches are the easiest to
/// click through and I'd like to group those and knock them all out quickly."*
/// Presented in crawl order the easy and the hard interleave, so ten minutes
/// cannot be spent on the ten that would actually close.
final class MatchQueueOrderTests: XCTestCase {

    private func entry(_ route: VideoMatchRoute, _ count: Int) -> MatchQueueEntry {
        MatchQueueEntry(route: route, candidateCount: count)
    }

    // MARK: - Quickest first

    /// ⚠️ Candidate count dominates and the route breaks ties — NOT the other
    /// way round. A title search returning one candidate is still one
    /// comparison; a fingerprint returning eight is still eight.
    func testFewerCandidatesWinsOverAStrongerRoute() {
        let items = [entry(.fingerprint, 8), entry(.title, 1)]

        let ordered = MatchQueueOrder.easiest.arrange(items) { $0 }

        XCTAssertEqual(ordered.first?.candidateCount, 1)
    }

    /// Among equal counts, the stronger route is the quicker decision.
    func testTheRouteBreaksTiesOnCount() {
        let items = [entry(.title, 1), entry(.cast, 1), entry(.fingerprint, 1)]

        let ordered = MatchQueueOrder.easiest.arrange(items) { $0 }

        XCTAssertEqual(ordered.map(\.route), [.fingerprint, .cast, .title])
    }

    /// ⚠️ Stable, so resolving one item does not reshuffle the rest under the
    /// operator — disorienting in exactly the mode meant for working fast.
    func testEqualEntriesKeepTheOrderTheyWereFoundIn() {
        let items = [("a", entry(.cast, 3)), ("b", entry(.cast, 3)), ("c", entry(.cast, 3))]

        let ordered = MatchQueueOrder.easiest.arrange(items) { $0.1 }

        XCTAssertEqual(ordered.map(\.0), ["a", "b", "c"])
    }

    // MARK: - The other orders

    func testDiscoveredOrderChangesNothing() {
        let items = [entry(.title, 9), entry(.fingerprint, 1)]

        XCTAssertEqual(MatchQueueOrder.discovered.arrange(items) { $0 }, items)
    }

    /// Grouping by route ignores the count, so one KIND can be worked through.
    func testGroupingByRouteIgnoresCandidateCount() {
        let items = [entry(.title, 1), entry(.fingerprint, 20), entry(.cast, 2)]

        let ordered = MatchQueueOrder.route.arrange(items) { $0 }

        XCTAssertEqual(ordered.map(\.route), [.fingerprint, .cast, .title])
    }

    func testAnEmptyQueueIsHandled() {
        XCTAssertTrue(MatchQueueOrder.easiest.arrange([MatchQueueEntry]()) { $0 }.isEmpty)
    }
}

/// Why a video needs attention, after the run's screen has closed.
///
/// 🚨 `enrichmentState` says a video needs a person and never says why. The
/// reason lived only in the batch run's in-memory queue, so two hundred
/// "ambiguous" videos were one undifferentiated pile — the one-candidate
/// fingerprint hits indistinguishable from the twelve-candidate title guesses.
final class LookupRouteFilterTests: XCTestCase {

    func testTheRouteSurvivesInTheOutcome() {
        XCTAssertEqual(VideoBatchOutcome.queued(route: .title, candidateCount: 3)
                        .attemptedRoute, .title)
        XCTAssertEqual(VideoBatchOutcome.applied(route: .fingerprint, fields: [], tags: [])
                        .attemptedRoute, .fingerprint)
    }

    /// ⚠️ nil for a no-match: several routes were tried and all failed, so
    /// naming one would be arbitrary. A skip never looked at all.
    func testOutcomesThatNamedNoRouteReportNone() {
        XCTAssertNil(VideoBatchOutcome.noMatch.attemptedRoute)
        XCTAssertNil(VideoBatchOutcome.skipped(reason: "already matched").attemptedRoute)
        XCTAssertNil(VideoBatchOutcome.failed("timeout").attemptedRoute)
    }

    func testTheFilterSelectsOneRoute() {
        XCTAssertTrue(LookupRouteFilter.fingerprint.accepts("fingerprint"))
        XCTAssertFalse(LookupRouteFilter.fingerprint.accepts("title"))
        XCTAssertFalse(LookupRouteFilter.fingerprint.accepts(nil))
    }

    func testAnyAcceptsEverythingIncludingUnrecorded() {
        for value in ["fingerprint", "cast", "title", nil] {
            XCTAssertTrue(LookupRouteFilter.any.accepts(value))
        }
    }

    /// ⚠️ Never looked up, or looked up before the app kept this. Both mean
    /// unknown, and an empty string is not a route.
    func testUnrecordedCoversBothNilAndEmpty() {
        XCTAssertTrue(LookupRouteFilter.unrecorded.accepts(nil))
        XCTAssertTrue(LookupRouteFilter.unrecorded.accepts(""))
        XCTAssertFalse(LookupRouteFilter.unrecorded.accepts("cast"))
    }

    /// ⭐ The two dimensions COMPOSE — which is the whole reason this is not
    /// more `EnrichmentFilter` cases.
    func testTheRouteFilterIsIndependentOfTheResultFilter() {
        var asset = Asset(relativePath: "v.mp4", fileName: "v.mp4")
        asset.enrichmentState = .ambiguous
        asset.lookupRoute = VideoMatchRoute.fingerprint.rawValue

        var quickPile = AssetFilterCriteria()
        quickPile.enrichment = .ambiguous
        quickPile.lookupRoute = .fingerprint
        XCTAssertTrue(quickPile.matches(asset, mappedActors: [], entityProfiles: [:]))

        var investigations = quickPile
        investigations.lookupRoute = .title
        XCTAssertFalse(investigations.matches(asset, mappedActors: [], entityProfiles: [:]))
    }
}
