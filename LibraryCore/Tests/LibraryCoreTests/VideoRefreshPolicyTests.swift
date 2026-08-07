import XCTest
@testable import LibraryCore

/// Re-reading a video the library has already matched.
///
/// 🚨 Reported by the operator: after refining a library by hand, a batch run
/// reported 860 videos "skipped — already matched", and asked whether the newer
/// data (credited-as, imprint hierarchy, studio ids) would ever reach them.
/// It would not: `VideoBatchPolicy` skips a matched video BEFORE any fetch, so
/// no proposal is ever produced for it.
final class VideoRefreshPolicyTests: XCTestCase {

    private func asset(state: EnrichmentState?, sourceId: String? = nil) -> Asset {
        Asset(relativePath: "v.mp4", fileName: "v.mp4",
              enrichmentState: state, enrichmentSourceId: sourceId)
    }

    // MARK: - Who can be refreshed

    /// ⭐ The cheap path: a matched video already knows WHICH record it is, so
    /// this is a direct lookup — no fingerprint, no disk read, no search.
    func testAMatchedVideoWithASourceIdIsRefreshable() {
        let e = VideoRefreshPolicy.eligibility(for: asset(state: .matched, sourceId: "abc-123"))

        XCTAssertEqual(e, .refresh(sourceId: "abc-123"))
        XCTAssertTrue(e.isRefreshable)
        XCTAssertNil(e.reason)
    }

    /// ⚠️ Matched before the app recorded which record. There is nothing to
    /// look up, and saying so is more useful than silently skipping.
    func testAMatchedVideoWithNoSourceIdCannotBeRefreshed() {
        let e = VideoRefreshPolicy.eligibility(for: asset(state: .matched))

        XCTAssertEqual(e, .noSourceId)
        XCTAssertEqual(e.reason, "matched before the app recorded which record")
    }

    func testABlankSourceIdCountsAsNone() {
        XCTAssertEqual(VideoRefreshPolicy.eligibility(
            for: asset(state: .matched, sourceId: "   ")), .noSourceId)
    }

    /// An unmatched video is the other tool's job.
    func testAnUnmatchedVideoIsNotRefreshed() {
        XCTAssertEqual(VideoRefreshPolicy.eligibility(for: asset(state: nil)), .notMatched)
    }

    /// ⚠️ Re-reading a video the operator ruled out would overrule them.
    func testARuledOutVideoIsLeftAlone() {
        XCTAssertEqual(VideoRefreshPolicy.eligibility(
            for: asset(state: .unmatchable, sourceId: "abc")), .ruledOut)
    }

    func testAnAmbiguousVideoStillNeedsAPerson() {
        XCTAssertEqual(VideoRefreshPolicy.eligibility(
            for: asset(state: .ambiguous, sourceId: "abc")), .ambiguous)
    }

    // MARK: - What may be written unattended

    private func change(_ field: String, _ kind: VideoFieldChange.Kind) -> VideoFieldChange {
        .init(field: field, label: field, kind: kind,
              current: kind == .conflict ? "mine" : "", proposed: "theirs")
    }

    /// Fills only. A hand-refined library must not be undone by a source that
    /// has since changed its mind.
    func testOnlyFillsAreAppliedWithoutAsking() {
        let changes = [change("releaseDate", .fill), change("studio", .conflict)]

        XCTAssertEqual(VideoRefreshPolicy.autoApplicable(changes), ["releaseDate"])
        XCTAssertEqual(VideoRefreshPolicy.conflicts(changes).map(\.field), ["studio"])
    }

    func testNothingIsAppliedWhenEveryChangeIsAConflict() {
        XCTAssertTrue(VideoRefreshPolicy.autoApplicable(
            [change("studio", .conflict), change("seriesTitle", .conflict)]).isEmpty)
    }

    /// ⚠️ Tags stay a per-video decision. A source tags far more finely than a
    /// person does, and an unattended pass would bury a hand-built vocabulary
    /// across the whole library at once.
    func testTagsAreNotRefreshed() {
        XCTAssertFalse(VideoRefreshPolicy.refreshesTags)
    }

    // MARK: - Reporting

    func testFillingAndQueueingAreReportedSeparately() {
        XCTAssertEqual(VideoRefreshPolicy.outcome(filled: ["releaseDate"], conflicted: []),
                       .filled(fields: ["releaseDate"]))
        XCTAssertEqual(VideoRefreshPolicy.outcome(filled: [], conflicted: ["studio"]),
                       .queued(fields: ["studio"]))
        XCTAssertEqual(VideoRefreshPolicy.outcome(filled: [], conflicted: []),
                       .alreadyComplete)
        XCTAssertEqual(VideoRefreshPolicy.outcome(filled: ["b", "a"], conflicted: ["c"]),
                       .filledAndQueued(filled: ["a", "b"], queued: ["c"]))
    }

    /// The two questions the report has to answer separately: did it change
    /// anything, and is anything waiting on me.
    func testOutcomesSayWhetherTheyWroteAndWhetherTheyNeedAPerson() {
        XCTAssertTrue(VideoRefreshPolicy.Outcome.filled(fields: ["a"]).wroteAnything)
        XCTAssertFalse(VideoRefreshPolicy.Outcome.filled(fields: ["a"]).needsAPerson)

        XCTAssertFalse(VideoRefreshPolicy.Outcome.queued(fields: ["a"]).wroteAnything)
        XCTAssertTrue(VideoRefreshPolicy.Outcome.queued(fields: ["a"]).needsAPerson)

        let both = VideoRefreshPolicy.Outcome.filledAndQueued(filled: ["a"], queued: ["b"])
        XCTAssertTrue(both.wroteAnything)
        XCTAssertTrue(both.needsAPerson)
    }

    /// ⚠️ A failed request is not a verdict about the video, so it must not
    /// read as one — a re-run has to retry it.
    func testAFailureIsNeitherAWriteNorADecision() {
        let failed = VideoRefreshPolicy.Outcome.failed("timed out")

        XCTAssertFalse(failed.wroteAnything)
        XCTAssertFalse(failed.needsAPerson)
    }
}
