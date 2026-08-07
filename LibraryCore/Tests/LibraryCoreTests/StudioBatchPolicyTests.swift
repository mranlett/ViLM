import XCTest
@testable import LibraryCore

/// What an unattended studio run may do.
///
/// The rules it shares with the actor side are tested here too rather than
/// assumed: they are the same rules deliberately, and a drift between the two
/// is exactly the defect this policy exists to prevent.
final class StudioBatchPolicyTests: XCTestCase {

    private func proposal(bio: String? = nil,
                          homePage: String? = nil,
                          akas: [String]? = nil,
                          links: [EntityLink]? = nil,
                          logo: URL? = nil,
                          parent: String? = nil) -> StudioMetadataProposal {
        var p = StudioMetadataProposal()
        p.bio = ProposedField(bio)
        p.homePage = ProposedField(homePage)
        p.akas = ProposedField(akas)
        p.externalLinks = ProposedField(links)
        p.logoURL = ProposedField(logo)
        p.parentName = ProposedField(parent)
        return p
    }

    private func studio(_ name: String = "Coast Line") -> EntityProfile {
        EntityProfile(id: "studio:\(name)")
    }

    // MARK: - Skipping

    /// Identical to the actor and video rules, `ambiguous` included: a re-run
    /// cannot make a choice a person has to make, so examining it again spends
    /// a request to reach the same dead end.
    func testSettledAndPendingStudiosAreSkipped() {
        for state in [EnrichmentState.matched, .unmatchable, .ambiguous] {
            var profile = studio()
            profile.enrichmentState = state
            XCTAssertNotNil(StudioBatchPolicy.skipReason(for: profile),
                            "\(state) should be skipped")
        }
    }

    /// A previous `noMatch` IS retried — the source gains records constantly,
    /// and a verdict from last month is not evidence about today.
    func testANoMatchIsRetried() {
        var profile = studio()
        profile.enrichmentState = .noMatch
        XCTAssertNil(StudioBatchPolicy.skipReason(for: profile))
    }

    func testAnUntouchedStudioIsExamined() {
        XCTAssertNil(StudioBatchPolicy.skipReason(for: studio()))
    }

    // MARK: - One candidate or ask

    func testOneCandidateIsDecisive() {
        XCTAssertTrue(StudioBatchPolicy.isDecisive(candidateCount: 1))
    }

    /// Two networks can use the same imprint name — which is exactly why a
    /// studio carries a source id at all.
    func testSeveralCandidatesAreNot() {
        XCTAssertFalse(StudioBatchPolicy.isDecisive(candidateCount: 2))
        XCTAssertFalse(StudioBatchPolicy.isDecisive(candidateCount: 0))
    }

    // MARK: - Fills only

    func testEmptySlotsAreFilled() {
        let fields = StudioBatchPolicy.autoApplicableFields(
            current: studio(),
            proposal: proposal(bio: "A label.", homePage: "https://example.com",
                               akas: ["Coastline"],
                               links: [EntityLink(url: "https://example.com/x", label: "X")]))

        XCTAssertEqual(fields, [StudioBatchPolicy.Field.bio,
                                StudioBatchPolicy.Field.homePage,
                                StudioBatchPolicy.Field.akas,
                                StudioBatchPolicy.Field.links])
    }

    /// A conflict means the library already holds a value, and replacing it
    /// unattended discards work nobody agreed to discard.
    func testPopulatedFieldsAreNeverOverwritten() {
        var current = studio()
        current.bio = "What the operator wrote."
        current.homePage = "https://operator.example"
        current.akas = ["Coastline"]
        current.links = [EntityLink(url: "https://operator.example/a", label: "A")]

        let fields = StudioBatchPolicy.autoApplicableFields(
            current: current,
            proposal: proposal(bio: "What the source says.",
                               homePage: "https://source.example",
                               akas: ["Something else"],
                               links: [EntityLink(url: "https://source.example/b", label: "B")]))

        XCTAssertTrue(fields.isEmpty)
    }

    /// ⚠️ `nil` means the source had nothing to say, which must never clear a
    /// populated field (D5) — nor count as something written.
    func testAnAbsentValueIsNotAFill() {
        XCTAssertTrue(StudioBatchPolicy.autoApplicableFields(
            current: studio(), proposal: proposal()).isEmpty)
    }

    func testAnEmptyListIsNotAFill() {
        XCTAssertTrue(StudioBatchPolicy.autoApplicableFields(
            current: studio(), proposal: proposal(akas: [], links: [])).isEmpty)
    }

    /// ⚠️ The logo is the studio's photo: wrong is immediately visible on every
    /// screen, and an unattended run has nobody to notice.
    func testTheLogoIsNeverAppliedUnattended() {
        let fields = StudioBatchPolicy.autoApplicableFields(
            current: studio(),
            proposal: proposal(logo: URL(string: "https://example.com/logo.png")))

        XCTAssertFalse(fields.contains(StudioBatchPolicy.Field.logoUrl))
        XCTAssertTrue(StudioBatchPolicy.neverUnattended.contains(StudioBatchPolicy.Field.logoUrl))
    }

    /// ⚠️ The name is the join key every video's `studio:` tag is filed under.
    /// Changing it is a library-wide rename, not a field update.
    func testTheNameIsNeverRewrittenUnattended() {
        var p = proposal()
        p.name = ProposedField("Coast Line Pictures")
        XCTAssertFalse(StudioBatchPolicy.autoApplicableFields(current: studio(), proposal: p)
            .contains(StudioBatchPolicy.Field.name))
    }

    // MARK: - The parent

    func testANetworkTheLibraryLacksIsRecorded() {
        XCTAssertEqual(
            StudioBatchPolicy.parentDisposition(existing: nil,
                                                proposal: proposal(parent: "Example Network")),
            .recorded(name: "Example Network", sourceId: nil))
    }

    /// ⚠️ Reported, never overwritten. Which company owns an imprint is a fact
    /// about the world the operator may know better than the source.
    func testADifferentNetworkIsAConflictNotAnOverwrite() {
        XCTAssertEqual(
            StudioBatchPolicy.parentDisposition(existing: "Silver River",
                                                proposal: proposal(parent: "Example Network")),
            .conflict(existing: "Silver River", offered: "Example Network"))
    }

    /// Folded, so a respelling of the same network is a non-event rather than
    /// a disagreement that fills the report with noise.
    func testARespellingOfTheSameNetworkIsNotAConflict() {
        XCTAssertEqual(
            StudioBatchPolicy.parentDisposition(existing: "Example Network",
                                                proposal: proposal(parent: "ExampleNetwork")),
            .unchanged)
    }

    func testNoNetworkOfferedIsNotADisposition() {
        XCTAssertEqual(
            StudioBatchPolicy.parentDisposition(existing: nil, proposal: proposal()),
            .none)
        XCTAssertEqual(
            StudioBatchPolicy.parentDisposition(existing: nil, proposal: proposal(parent: "   ")),
            .none)
    }

    // MARK: - Recorded state

    func testAppliedIsMatchedAndQueuedIsAmbiguous() {
        XCTAssertEqual(StudioBatchOutcome.applied(fields: [], parent: .none).recordedState,
                       .matched)
        XCTAssertEqual(StudioBatchOutcome.queued(candidateCount: 3).recordedState, .ambiguous)
        XCTAssertEqual(StudioBatchOutcome.noMatch.recordedState, .noMatch)
    }

    /// ⚠️ A failure is not a verdict — the next run must try again rather than
    /// treat a network blip as an answer.
    func testFailuresAndSkipsRecordNothing() {
        XCTAssertNil(StudioBatchOutcome.failed("timeout").recordedState)
        XCTAssertNil(StudioBatchOutcome.skipped(reason: "already matched").recordedState)
    }

    // MARK: - The report

    func testTheReportCountsParentsSeparatelyFromFields() {
        var report = StudioBatchReport()
        report.record(.applied(fields: ["bio"], parent: .recorded(name: "Example Network", sourceId: nil)))
        report.record(.applied(fields: ["bio", "akas"],
                               parent: .conflict(existing: "A", offered: "B")))
        report.record(.applied(fields: [], parent: .unchanged))
        report.record(.queued(candidateCount: 2))
        report.record(.noMatch)
        report.record(.failed("timeout"))
        report.record(.skipped(reason: "already matched"))

        XCTAssertEqual(report.applied, 3)
        XCTAssertEqual(report.fieldsWritten, 3)
        XCTAssertEqual(report.parentsRecorded, 1)
        XCTAssertEqual(report.parentConflicts, 1)
        XCTAssertEqual(report.examined, 6, "applied + queued + noMatch + failed")
        XCTAssertEqual(report.skipped, 1)
    }
}
