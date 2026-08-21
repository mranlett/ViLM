import XCTest
@testable import LibraryCore

/// V3 in force, rather than merely correct (#79).
///
/// 🚨 `VerifiedElsewhere.mayOverwrite` and `wasVerifiedByHand` were complete,
/// tested and called by nothing, so the rule they encode — *a later automated
/// run does not overwrite the operator's values* — was not actually holding
/// anywhere. These tests are against the RUNS that would overwrite, which is
/// the only place the question can be answered.
///
/// ⚠️ All names invented. This repository is public.
final class VerifiedElsewhereEnforcementTests: XCTestCase {

    private let wired: Set<String> = ["Example Source"]

    private func handVerified(_ profile: EntityProfile = EntityProfile(id: "actor:Alice Example"))
        -> EntityProfile {
        VerifiedElsewhere.applying(
            ExternalVerification(source: "A Place We Cannot Query", reference: "12345"),
            to: profile)
    }

    // MARK: - 🚨 The escape that would have erased it

    /// A hand-verified profile is `matched` with no `entity_match` edge, which
    /// is EXACTLY the shape `identityNeedsEnrichment` describes. Without the
    /// guard the run examines it, and a `.noMatch` outcome records `.noMatch`
    /// and clears the id — the verification is not overwritten, it is gone.
    func testAHandVerifiedProfileIsSkippedEvenWhenItLooksLikeItNeedsEnrichment() {
        let reason = ActorBatchPolicy.skipReason(for: handVerified(),
                                                 identityNeedsEnrichment: true,
                                                 knownProviders: wired)
        XCTAssertEqual(reason, "you verified this one yourself")
    }

    /// ⚠️ The other direction, and it matters: the escape exists to rescue
    /// actors whose identity arrived without their details — 394 of them in a
    /// real library. Guarding V3 must not close that door.
    func testAProviderMatchedProfileAwaitingEnrichmentIsStillExamined() {
        var profile = EntityProfile(id: "actor:Alice Example")
        profile.enrichmentState = .matched
        profile.enrichmentSource = "Example Source"

        XCTAssertNil(ActorBatchPolicy.skipReason(for: profile,
                                                 identityNeedsEnrichment: true,
                                                 knownProviders: wired),
                     "the 394-actor rescue must survive the V3 guard")
    }

    /// ⚠️ An unreadable or unsupplied provider list errs toward SKIPPING. A
    /// caller that forgets protects the operator's records rather than
    /// exposing them — the same direction as the privacy boundary's empty map.
    func testAnEmptyProviderListErrsTowardSkipping() {
        var profile = EntityProfile(id: "actor:Alice Example")
        profile.enrichmentState = .matched
        profile.enrichmentSource = "Example Source"

        XCTAssertEqual(ActorBatchPolicy.skipReason(for: profile,
                                                   identityNeedsEnrichment: true,
                                                   knownProviders: []),
                       "you verified this one yourself")
    }

    /// An ordinary unmatched profile is unaffected — the guard must not become
    /// a reason to skip work that has never been looked at.
    func testAnUnmatchedProfileIsStillExamined() {
        XCTAssertNil(ActorBatchPolicy.skipReason(for: EntityProfile(id: "actor:Alice Example"),
                                                 knownProviders: wired))
    }

    // MARK: - ⚠️ The siblings (mistakes-log pattern 14)
    //
    // The video and studio runs are safe today because their skip rules have
    // no escape at all. That is a property of those rules, not a decision — so
    // it is pinned here. If an escape like the actor one is ever added, these
    // fail and say why.

    func testTheVideoRunSkipsAHandVerifiedVideo() {
        let asset = VerifiedElsewhere.applying(
            ExternalVerification(source: "A Place We Cannot Query"),
            to: Asset(relativePath: "a.mp4", fileName: "a.mp4",
                      contentKind: .scene))
        XCTAssertNotNil(VideoBatchPolicy.skipReason(for: asset),
                        "if an un-skip escape is added here, wire the V3 guard with it")
    }

    func testTheStudioRunSkipsAHandVerifiedStudio() {
        let studio = handVerified(EntityProfile(id: "studio:Example Studio"))
        XCTAssertNotNil(StudioBatchPolicy.skipReason(for: studio),
                        "if an un-skip escape is added here, wire the V3 guard with it")
    }

    // MARK: - ⚠️ A hand verification is not damage

    /// The feature exists to take a record OUT of the audits. Reporting it in
    /// this one as "matched without an edge" puts it straight back into one.
    func testAHandVerifiedProfileIsNotReportedAsAnIdentityGap() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Gaps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try LibraryStore(at: url)

        try store.saveEntityProfile(handVerified(EntityProfile(id: "actor:Alice Example")))
        var byProvider = EntityProfile(id: "actor:Bea Example")
        byProvider.enrichmentState = .matched
        byProvider.enrichmentSource = "Example Source"
        try store.saveEntityProfile(byProvider)

        let (entities, _) = try store.nodesMatchedWithoutAnEdge(knownProviders: wired)
        XCTAssertEqual(entities, ["actor:Bea Example"],
                       "the provider-matched one is a real gap; the hand-verified one is not")
    }

    /// 🚨 The opposite direction from the batch guard, and it is deliberate.
    /// A run that skips too much protects the operator; an AUDIT that excludes
    /// too much hides real gaps — so a caller that says nothing gets everything.
    func testACallerThatSuppliesNoProviderListIsToldAboutEverything() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Gaps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try LibraryStore(at: url)

        try store.saveEntityProfile(handVerified(EntityProfile(id: "actor:Alice Example")))

        let (entities, _) = try store.nodesMatchedWithoutAnEdge()
        XCTAssertEqual(entities, ["actor:Alice Example"],
                       "nil means 'the caller did not say', not 'exclude everything'")
    }

    /// ⚠️ An EMPTY set is a different answer from nil, and a meaningful one:
    /// no providers installed, so every named source is the operator's.
    func testAnEmptyProviderListMeansEveryNamedSourceIsTheOperators() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Gaps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try LibraryStore(at: url)

        try store.saveEntityProfile(handVerified(EntityProfile(id: "actor:Alice Example")))

        let (entities, _) = try store.nodesMatchedWithoutAnEdge(knownProviders: [])
        XCTAssertTrue(entities.isEmpty)
    }

    // MARK: - The guard's own rule, at the boundary

    /// Re-verifying against the SAME place the operator named is a correction
    /// of their own record, not an overwrite of it.
    func testTheOperatorMayCorrectTheirOwnRecordAgainstTheSameSource() {
        let asset = VerifiedElsewhere.applying(
            ExternalVerification(source: "A Place We Cannot Query"),
            to: Asset(relativePath: "a.mp4", fileName: "a.mp4"))

        XCTAssertTrue(VerifiedElsewhere.mayOverwrite(asset,
                                                     withSource: "A Place We Cannot Query",
                                                     knownProviders: wired))
        XCTAssertFalse(VerifiedElsewhere.mayOverwrite(asset,
                                                      withSource: "Example Source",
                                                      knownProviders: wired),
                       "a wired source may not overwrite a person's statement")
    }
}
