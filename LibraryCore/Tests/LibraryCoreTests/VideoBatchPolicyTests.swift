import XCTest
@testable import LibraryCore

/// What a batch run is allowed to do without being watched.
///
/// The line is drawn on HOW a match was found, not on how convincing it looks.
/// A fingerprint either matches a recorded one or it does not; a cast search
/// returns things that are merely plausible, and plausible is not identified.
final class VideoBatchPolicyTests: XCTestCase {

    private func change(_ field: String, _ kind: VideoFieldChange.Kind) -> VideoFieldChange {
        VideoFieldChange(field: field, label: field, kind: kind, current: "", proposed: "x")
    }

    // MARK: - Who may apply unattended

    func testOnlyFingerprintMatchesApplyThemselves() {
        XCTAssertTrue(VideoMatchRoute.fingerprint.isAutoApplicable)
        XCTAssertFalse(VideoMatchRoute.cast.isAutoApplicable)
        XCTAssertFalse(VideoMatchRoute.title.isAutoApplicable)
    }

    func testAFingerprintMatchWritesItsFills() {
        let fields = VideoBatchPolicy.autoApplicableFields(
            route: .fingerprint,
            changes: [change("episodeTitle", .fill), change("releaseDate", .fill)])
        XCTAssertEqual(fields, ["episodeTitle", "releaseDate"])
    }

    /// The rule that protects work already done. A conflict disagrees with
    /// something recorded deliberately, and resolving those unattended across a
    /// library is invisible until long after it happened.
    func testAConflictIsNeverAppliedUnattended() {
        let fields = VideoBatchPolicy.autoApplicableFields(
            route: .fingerprint,
            changes: [change("seriesTitle", .conflict), change("releaseDate", .fill)])
        XCTAssertEqual(fields, ["releaseDate"])
    }

    func testASearchMatchWritesNothingAtAll() {
        for route in [VideoMatchRoute.cast, .title] {
            XCTAssertTrue(VideoBatchPolicy.autoApplicableFields(
                route: route, changes: [change("episodeTitle", .fill)]).isEmpty)
        }
    }

    // MARK: - What gets examined

    func testAlreadyMatchedAndRuledOutAreSkipped() {
        XCTAssertNotNil(VideoBatchPolicy.skipReason(for: asset(.matched)))
        XCTAssertNotNil(VideoBatchPolicy.skipReason(for: asset(.unmatchable)))
    }

    /// A previous failure is retried: the source gains records constantly, so
    /// last month's "not found" is not evidence about today.
    func testAPreviousNoMatchIsTriedAgain() {
        XCTAssertNil(VideoBatchPolicy.skipReason(for: asset(.noMatch)))
        XCTAssertNil(VideoBatchPolicy.skipReason(for: asset(nil)))
    }

    private func asset(_ state: EnrichmentState?) -> Asset {
        Asset(relativePath: "a.mp4", fileName: "a.mp4", enrichmentState: state)
    }

    // MARK: - What gets recorded

    func testAQueuedMatchIsNotRecordedAsMatched() {
        XCTAssertEqual(VideoBatchOutcome.queued(route: .cast, candidateCount: 3).recordedState,
                       .ambiguous,
                       "recording it as matched would remove it from the queue it just entered")
    }

    func testAppliedRecordsMatched() {
        XCTAssertEqual(
            VideoBatchOutcome.applied(route: .fingerprint, fields: ["a"], tags: []).recordedState,
            .matched)
    }

    /// A failure is not a verdict — leaving the state alone means the next run
    /// retries rather than treating a network blip as an answer.
    func testAFailureRecordsNothing() {
        XCTAssertNil(VideoBatchOutcome.failed("timeout").recordedState)
        XCTAssertNil(VideoBatchOutcome.skipped(reason: "already matched").recordedState)
    }

    // MARK: - Reporting

    func testTheReportCountsWhatNobodyReviewed() {
        var report = VideoBatchReport()
        report.record(.applied(route: .fingerprint, fields: ["a", "b"], tags: ["t"]))
        report.record(.queued(route: .cast, candidateCount: 2))
        report.record(.noMatch)
        XCTAssertEqual(report.applied, 1)
        XCTAssertEqual(report.queued, 1)
        XCTAssertEqual(report.noMatch, 1)
        XCTAssertEqual(report.fieldsWritten, 3, "the number nobody looked at")
        XCTAssertEqual(report.examined, 3)
    }
}

/// The round trip the whole feature rests on: match it, record it, never be
/// asked about it again.
extension VideoBatchPolicyTests {

    func testAConfirmedMatchIsNeverExaminedAgain() {
        let matched = VideoEnrichmentReview.recordingOutcome(
            Asset(relativePath: "a.mp4", fileName: "a.mp4"),
            state: .matched, source: "TestSource")
        XCTAssertEqual(VideoBatchPolicy.skipReason(for: matched), "already matched")
    }

    /// A match that adds nothing is still a match — the state is what stops it
    /// being re-examined, not whether any field changed.
    func testAMatchThatAddsNothingStillCounts() {
        let unchanged = VideoEnrichmentReview.recordingOutcome(
            Asset(relativePath: "a.mp4", fileName: "a.mp4", tags: ["actor:Someone"]),
            state: .matched, source: "TestSource")
        XCTAssertEqual(unchanged.tags, ["actor:Someone"], "nothing was written")
        XCTAssertNotNil(VideoBatchPolicy.skipReason(for: unchanged), "but it is still skipped")
    }

    /// A queued video is genuinely undecided, so it DOES come back until
    /// someone resolves it. That is the state a manual match has to overwrite.
    func testAQueuedVideoReturnsUntilItIsResolved() {
        let queued = VideoEnrichmentReview.recordingOutcome(
            Asset(relativePath: "a.mp4", fileName: "a.mp4"),
            state: .ambiguous, source: "TestSource")
        XCTAssertNil(VideoBatchPolicy.skipReason(for: queued))

        let resolved = VideoEnrichmentReview.recordingOutcome(
            queued, state: .matched, source: "TestSource")
        XCTAssertNotNil(VideoBatchPolicy.skipReason(for: resolved))
    }
}
