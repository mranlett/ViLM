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

    /// ⭐ POLICY REVERSED 2026-08-08, at the operator's direction: on a
    /// fingerprint match the source's value OVERWRITES a differing local one.
    ///
    /// This test previously asserted the opposite — "a conflict is never
    /// applied unattended" — on the reasoning that a conflict disagrees with
    /// something recorded deliberately. That reasoning holds for an ACTOR, whose
    /// profile is curated. It does not hold for a VIDEO, whose local title,
    /// season, date and studio were read off its filename by a parser. The
    /// source's record of the same scene is simply better.
    ///
    /// ⚠️ The protection now lives in the ROUTE, not the change kind — see the
    /// test below. A fingerprint identifies the file exactly; nothing else may
    /// overwrite anything.
    func testAFingerprintOverwritesAConflictingLocalValue() {
        let fields = VideoBatchPolicy.autoApplicableFields(
            route: .fingerprint,
            changes: [change("seriesTitle", .conflict), change("releaseDate", .fill)])
        XCTAssertEqual(fields, ["seriesTitle", "releaseDate"])
    }

    /// 🚨 The rule that now carries the whole weight: a GUESS overwrites
    /// nothing. A cast or title search returns what is plausible, and
    /// overwriting good local data on that basis is the one version of this
    /// policy that would be indefensible.
    func testASearchMatchOverwritesNothingEvenOnAConflict() {
        for route in [VideoMatchRoute.cast, .title] {
            XCTAssertTrue(VideoBatchPolicy.autoApplicableFields(
                route: route,
                changes: [change("seriesTitle", .conflict),
                          change("releaseDate", .fill)]).isEmpty,
                "a plausible match may not overwrite anything")
        }
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
        Asset(relativePath: "a.mp4", fileName: "a.mp4",
              contentKind: .scene, enrichmentState: state)
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
            Asset(relativePath: "a.mp4", fileName: "a.mp4", contentKind: .scene),
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

    /// ⚠️ Reversed deliberately. This previously asserted that a queued video
    /// comes back on every run.
    ///
    /// It cannot resolve itself: ambiguity means a person has to choose —
    /// between two scenes sharing a fingerprint, or between an imprint and its
    /// network — and a batch run makes neither choice. Re-examining spent a
    /// fingerprint and a rate-limited request to reach the same dead end, so a
    /// library accumulating ambiguities got slower every run while doing no
    /// more work, and looked like it had forgotten where it got to.
    ///
    /// Nothing is stranded: these are findable under Lookup Result →
    /// Ambiguous, and `Match Again` clears them once the missing answer —
    /// usually a confirmed studio — exists.
    func testAQueuedVideoIsNotExaminedAgain() {
        let queued = VideoEnrichmentReview.recordingOutcome(
            Asset(relativePath: "a.mp4", fileName: "a.mp4", contentKind: .scene),
            state: .ambiguous, source: "TestSource")

        XCTAssertNotNil(VideoBatchPolicy.skipReason(for: queued))
    }

    /// ⚠️ The states a re-run MUST still examine. Skipping one of these would
    /// mean a video that failed on a network blip, or one never looked at,
    /// silently never being tried again.
    func testAnUnresolvedVideoIsStillExamined() {
        for state in [EnrichmentState.noMatch, .needsReview] {
            let asset = VideoEnrichmentReview.recordingOutcome(
                Asset(relativePath: "a.mp4", fileName: "a.mp4", contentKind: .scene),
                state: state, source: "TestSource")
            XCTAssertNil(VideoBatchPolicy.skipReason(for: asset),
                         "\(state) has to come back")
        }
        XCTAssertNil(VideoBatchPolicy.skipReason(
            for: Asset(relativePath: "a.mp4", fileName: "a.mp4", contentKind: .scene)),
                     "never checked has to come back")
    }
}
