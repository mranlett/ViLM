import XCTest
@testable import LibraryCore

/// What an unattended actor run may do — and, mostly, may not.
///
/// ⚠️ These deliberately mirror `VideoBatchPolicyTests` decision for decision.
/// Batch actor enrichment used to live outside the app with its own overwrite
/// rules, so "match everything" meant one thing for videos and another for
/// people. Where the two policies agree, that is the point.
final class ActorBatchPolicyTests: XCTestCase {

    private func profile(_ state: EnrichmentState?) -> EntityProfile {
        var p = EntityProfile(id: "actor:Alice Example")
        p.enrichmentState = state
        return p
    }

    private func change(_ id: String, _ kind: ProposedChange.Kind) -> ProposedChange {
        ProposedChange(id: id, label: id, current: nil, proposed: "value",
                       kind: kind, sourceNote: nil)
    }

    // MARK: - What a re-run walks past

    func testAMatchedOrRuledOutActorIsSkipped() {
        XCTAssertNotNil(ActorBatchPolicy.skipReason(for: profile(.matched)))
        XCTAssertNotNil(ActorBatchPolicy.skipReason(for: profile(.unmatchable)))
    }

    /// ⚠️ Same rule the video side needed: ambiguity means a PERSON has to
    /// choose, and a re-run cannot. Examining it again spends a rate-limited
    /// request to reach the same dead end.
    func testAnAmbiguousActorIsSkipped() {
        XCTAssertNotNil(ActorBatchPolicy.skipReason(for: profile(.ambiguous)))
    }

    /// ⚠️ The states that MUST still come back. Skipping one of these would
    /// mean an actor whose lookup failed on a network blip is silently never
    /// tried again.
    func testUnresolvedActorsAreStillExamined() {
        XCTAssertNil(ActorBatchPolicy.skipReason(for: profile(.noMatch)))
        XCTAssertNil(ActorBatchPolicy.skipReason(for: profile(.needsReview)))
        XCTAssertNil(ActorBatchPolicy.skipReason(for: profile(nil)))
    }

    // MARK: - What it may write

    func testOnlyFillsAreWritten() {
        let fields = ActorBatchPolicy.autoApplicableFields([
            change("bio", .fill),
            change("birthYear", .conflict),
            change("gender", .unchanged),
        ])

        XCTAssertEqual(fields, ["bio"],
                       "a conflict means the library already holds a value")
    }

    /// ⚠️ Never unattended, even into an empty slot. A wrong photo is
    /// immediately and visibly wrong on every screen the person appears on,
    /// and an unattended run has nobody to notice.
    func testAPhotoIsNeverSetUnattendedEvenWhenTheSlotIsEmpty() {
        let fields = ActorBatchPolicy.autoApplicableFields([
            change(ActorEnrichment.Field.photoUrl, .fill),
            change("bio", .fill),
        ])

        XCTAssertEqual(fields, ["bio"])
    }

    func testNothingToWriteIsNotAnError() {
        XCTAssertTrue(ActorBatchPolicy.autoApplicableFields([]).isEmpty)
    }

    // MARK: - ⚠️ When it refuses to decide

    /// Two people share a name often enough that picking the first is how a bio
    /// lands on the wrong person — and the match would then be recorded, so
    /// nothing brings it back for review.
    func testOnlyASingleCandidateIsDecisive() {
        XCTAssertTrue(ActorBatchPolicy.isDecisive(candidateCount: 1))
        XCTAssertFalse(ActorBatchPolicy.isDecisive(candidateCount: 2))
        XCTAssertFalse(ActorBatchPolicy.isDecisive(candidateCount: 0))
    }

    // MARK: - What each outcome records

    func testQueuedIsRecordedAsAmbiguousNotMatched() {
        XCTAssertEqual(ActorBatchOutcome.queued(candidateCount: 3).recordedState, .ambiguous)
        XCTAssertEqual(ActorBatchOutcome.applied(fields: ["bio"]).recordedState, .matched)
        XCTAssertEqual(ActorBatchOutcome.noMatch.recordedState, .noMatch)
    }

    /// ⚠️ A failure is not a verdict. Recording one would let a network blip
    /// permanently mark somebody as unfindable.
    func testAFailureRecordsNothing() {
        XCTAssertNil(ActorBatchOutcome.failed("timeout").recordedState)
        XCTAssertNil(ActorBatchOutcome.skipped(reason: "already matched").recordedState)
    }

    // MARK: - The report

    func testTheTalliesAddUpToWhatWasExamined() {
        var report = ActorBatchReport()
        report.record(.applied(fields: ["bio", "gender"]))
        report.record(.queued(candidateCount: 2))
        report.record(.noMatch)
        report.record(.failed("timeout"))
        report.record(.skipped(reason: "already matched"))

        // `examined` deliberately excludes skips — nothing was looked up for
        // those — and the four that were add up exactly.
        XCTAssertEqual(report.examined, 4)
        XCTAssertEqual(report.applied + report.queued + report.noMatch + report.failed, 4)
        XCTAssertEqual(report.skipped, 1)
        XCTAssertEqual(report.fieldsWritten, 2)
    }
}
