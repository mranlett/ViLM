// VerifiedElsewhereTests.swift
// Verified Elsewhere — V1 to V7.
//
// ⚠️ All names invented, and NO SOURCE IS NAMED. The fixtures use a placeholder
// because the point of the feature is that core never enumerates sources, and a
// test that hard-codes a real one would be the first place that leaked.

import XCTest
@testable import LibraryCore

final class VerifiedElsewhereTests: XCTestCase {

    private let providers: Set<String> = ["Example Provider"]

    /// ⚠️ DECLARED. `VideoBatchPolicy` checks the privacy boundary before the
    /// match state, so an undeclared video is skipped as "not declared yet"
    /// whatever its match says — which the first version of these tests
    /// discovered by asserting the wrong reason. A video being verified against
    /// an outside listing has necessarily been declared, so the fixture says so.
    private func asset() -> Asset {
        Asset(relativePath: "a.mp4", fileName: "a.mp4", tags: ["actor:Alice Example"],
              contentKind: .scene)
    }

    // MARK: - V7 — a link is a link

    func testV7ANonURLIsRefusedRatherThanStored() {
        let result = VerifiedElsewhere.read(source: "A Catalogue", reference: "1",
                                           link: "not a link at all")
        guard case let .failure(refusal) = result else { return XCTFail("expected refusal") }
        XCTAssertEqual(refusal, .linkIsNotAURL("not a link at all"))
        XCTAssertFalse(refusal.reason.isEmpty, "a refusal has to say what to do instead")
    }

    /// ⚠️ Empty and unusable are DIFFERENT answers: "I did not keep the address"
    /// against "here is something that looks like one and is not".
    func testAnEmptyLinkIsAcceptedAndAnUnusableOneIsNot() {
        guard case .success(let ok) = VerifiedElsewhere.read(
            source: "A Catalogue", reference: nil, link: "") else {
            return XCTFail("an empty link is fine")
        }
        XCTAssertNil(ok.link)
        guard case .failure = VerifiedElsewhere.read(
            source: "A Catalogue", reference: nil, link: "example.com/thing") else {
            return XCTFail("a scheme-less string is not a link")
        }
    }

    func testASourceIsRequired() {
        guard case let .failure(refusal) = VerifiedElsewhere.read(
            source: "   ", reference: nil, link: nil) else { return XCTFail("expected refusal") }
        XCTAssertEqual(refusal, .noSource)
    }

    // MARK: - V1 — it leaves the lookup queue

    func testV1RecordingItTakesTheVideoOutOfTheQueue() throws {
        let verification = ExternalVerification(
            source: "A Catalogue", reference: "106720",
            link: URL(string: "https://example.com/listing?id=106720"))
        let updated = VerifiedElsewhere.applying(verification, to: asset())

        XCTAssertEqual(updated.enrichmentState, .matched)
        XCTAssertEqual(VideoBatchPolicy.skipReason(for: updated), "already matched",
                       "the existing policy is what removes it — nothing new was invented")
        XCTAssertEqual(updated.enrichmentSource, "A Catalogue")
        XCTAssertEqual(updated.enrichmentSourceId, "106720")
        XCTAssertNotNil(updated.enrichmentCheckedAt)
    }

    // MARK: - 🔴 V3 — a statement outranks evidence

    func testV3AnAutomatedRunMayNotOverwriteWhatThePersonEntered() {
        let byHand = VerifiedElsewhere.applying(
            ExternalVerification(source: "A Catalogue"), to: asset())
        XCTAssertFalse(VerifiedElsewhere.mayOverwrite(byHand, withSource: "Example Provider",
                                                      knownProviders: providers))
    }

    /// ⭐ Re-verifying against the SAME place is a correction of the operator's
    /// own record, not an overwrite of it.
    func testReVerifyingAgainstTheSameSourceIsAllowed() {
        let byHand = VerifiedElsewhere.applying(
            ExternalVerification(source: "A Catalogue"), to: asset())
        XCTAssertTrue(VerifiedElsewhere.mayOverwrite(byHand, withSource: "a catalogue",
                                                     knownProviders: providers))
    }

    /// And the contrast: a video matched by a provider is freely re-matched by
    /// that provider. A test of the refusal alone would pass on code that had
    /// frozen every record.
    func testAProviderMatchIsStillFreelyOverwritten() {
        var matched = asset()
        matched.enrichmentState = .matched
        matched.enrichmentSource = "Example Provider"
        XCTAssertTrue(VerifiedElsewhere.mayOverwrite(matched, withSource: "Example Provider",
                                                     knownProviders: providers))
    }

    // MARK: - V4 — free text, and core enumerates nothing

    /// 🚨 The test that would fail if anyone added an enum. Any string the
    /// operator types is a source, including one no provider has ever heard of.
    func testV4AnySourceNameIsAcceptedIncludingOneNothingKnowsAbout() {
        for name in ["A Catalogue", "a friend's spreadsheet", "the disc sleeve", "書店"] {
            guard case let .success(v) = VerifiedElsewhere.read(
                source: name, reference: nil, link: nil) else {
                return XCTFail("\(name) should be acceptable")
            }
            XCTAssertEqual(v.source, name)
            let updated = VerifiedElsewhere.applying(v, to: asset())
            XCTAssertTrue(VerifiedElsewhere.wasVerifiedByHand(updated,
                                                              knownProviders: providers))
        }
    }

    /// ⭐ Derived from the record, not stored as a flag. Two sources of truth
    /// about one fact disagree the first time anything else writes the source.
    func testAProviderMatchIsNotReportedAsVerifiedByHand() {
        var matched = asset()
        matched.enrichmentState = .matched
        matched.enrichmentSource = "Example Provider"
        XCTAssertFalse(VerifiedElsewhere.wasVerifiedByHand(matched, knownProviders: providers))
    }

    /// An unmatched video with a leftover source name is not "verified by hand"
    /// either — the state is half of the answer.
    func testAnUnmatchedVideoIsNeverReportedAsVerified() {
        var stray = asset()
        stray.enrichmentSource = "A Catalogue"
        stray.enrichmentState = nil
        XCTAssertFalse(VerifiedElsewhere.wasVerifiedByHand(stray, knownProviders: providers))
    }

    // MARK: - 🚨 V6 — clearing leaves nothing behind

    func testV6ClearingRemovesEveryFieldTheRecordingSet() {
        let recorded = VerifiedElsewhere.applying(
            ExternalVerification(source: "A Catalogue", reference: "106720",
                                 link: URL(string: "https://example.com/x")),
            to: asset())
        let cleared = VerifiedElsewhere.clearing(from: recorded)

        XCTAssertNil(cleared.enrichmentState)
        XCTAssertNil(cleared.enrichmentSource)
        XCTAssertNil(cleared.enrichmentSourceId, "a lingering reference reads as a match")
        XCTAssertNil(cleared.enrichmentUrl)
        XCTAssertNil(cleared.enrichmentCheckedAt)
        XCTAssertNil(cleared.lookupRoute)
        XCTAssertNil(VideoBatchPolicy.skipReason(for: cleared), "and it is back in the queue")
    }

    /// ⚠️ Clearing must not take the operator's OWN data with it. The point of
    /// the feature is the metadata they entered; only the provenance is undone.
    func testClearingLeavesTheOperatorsMetadataAlone() {
        var recorded = VerifiedElsewhere.applying(
            ExternalVerification(source: "A Catalogue"), to: asset())
        recorded.episode = "A Title They Typed"
        recorded.rating = 4
        let cleared = VerifiedElsewhere.clearing(from: recorded)
        XCTAssertEqual(cleared.episode, "A Title They Typed")
        XCTAssertEqual(cleared.rating, 4)
        XCTAssertEqual(cleared.tags, ["actor:Alice Example"])
    }
}
