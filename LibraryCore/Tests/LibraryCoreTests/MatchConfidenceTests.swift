// MatchConfidenceTests.swift
// Match Confidence — C1 to C6.
//
// ⚠️ All names invented. This repository is public.

import XCTest
@testable import LibraryCore

final class MatchConfidenceTests: XCTestCase {

    private func doubts(_ method: MatchMethod = .fingerprint,
                        local: Double? = 1800,
                        submissions: Int? = nil,
                        claimed: Double? = nil) -> [MatchDoubt] {
        MatchConfidenceRules.doubts(
            method: method, localDuration: local,
            confidence: MatchConfidence(submissions: submissions,
                                        fingerprintDuration: claimed))
    }

    // MARK: - C1 — a crowd of one is not a crowd

    func testC1ASingleSubmissionIsDistinguishableFromACorroboratedOne() {
        XCTAssertEqual(doubts(submissions: 1), [.singleSubmission])
        XCTAssertTrue(doubts(submissions: 40).isEmpty)
    }

    /// ⚠️ `== 1`, not `<= 1`. Zero would be the source reporting a count of
    /// none — a different and stranger claim — and `nil` means it said nothing
    /// at all. Neither may be read as "one person".
    func testC1ZeroAndUnknownAreNotTheSameAsOne() {
        XCTAssertTrue(doubts(submissions: 0).isEmpty, "a reported zero is not a lone submitter")
        XCTAssertTrue(doubts(submissions: nil).isEmpty, "silence is not a claim")
    }

    // MARK: - 🔴 C2 — duration disagreement, the cheapest lie-detector

    func testC2AMaterialDurationDisagreementIsReported() {
        XCTAssertEqual(doubts(local: 1800, claimed: 1800 + 31), [.durationDisagrees])
    }

    /// The decided tolerance is 30 seconds, and it is ABSOLUTE rather than
    /// proportional: a percentage tolerates minutes on a long scene — which is
    /// a different cut, the exact thing this catches — and is far too tight on
    /// a short one.
    func testC2AnOrdinaryReEncodeIsNotADisagreement() {
        XCTAssertTrue(doubts(local: 1800, claimed: 1802).isEmpty)
        XCTAssertTrue(doubts(local: 1800, claimed: 1830).isEmpty, "exactly 30s is within tolerance")
        XCTAssertEqual(doubts(local: 1800, claimed: 1831), [.durationDisagrees])
    }

    func testC2ItIsSymmetricalShorterOrLonger() {
        XCTAssertEqual(doubts(local: 1800, claimed: 1700), [.durationDisagrees])
        XCTAssertEqual(doubts(local: 1700, claimed: 1800), [.durationDisagrees])
    }

    /// 🚨 C2's other half: a disagreement is REPORTED and does not reject.
    /// `doubts` is the only output, and it is a list of reasons to look.
    func testC2ADisagreementProducesAReasonToLookAndNothingElse() {
        let found = doubts(local: 1800, claimed: 3600)
        XCTAssertEqual(found, [.durationDisagrees])
        XCTAssertFalse(found.first!.reason.isEmpty,
                       "the row has to say what is wrong, or it is just a flag")
    }

    /// ⚠️ An UNMEASURED file raises no duration doubt. Absence of a measurement
    /// is not evidence of disagreement, and reporting one would fill the queue
    /// with videos whose only fault is that Measure Videos has not run.
    func testAnUnmeasuredFileIsNotDoubted() {
        XCTAssertTrue(doubts(local: nil, claimed: 3600).isEmpty)
    }

    /// And the mirror: a source that says nothing about runtime cannot disagree.
    func testASourceThatSaysNothingAboutRuntimeCannotDisagree() {
        XCTAssertTrue(doubts(local: 1800, claimed: nil).isEmpty)
    }

    // MARK: - 🚨 C3 — nothing is ever un-matched automatically

    /// The whole surface of this feature is a list of reasons and a boolean
    /// that puts a row on a screen. There is no API here that changes a match,
    /// which is the strongest form this guarantee can take — it is not a rule
    /// someone must remember, it is a thing that cannot be called.
    func testC3TheOnlyOutcomeOfDoubtIsThatSomethingIsListed() {
        let confidence = MatchConfidence(submissions: 1, fingerprintDuration: 60)
        XCTAssertTrue(MatchConfidenceRules.needsReview(
            method: .fingerprint, localDuration: 1800, confidence: confidence))
        // Both signals present, and the result is still just "look at this".
        XCTAssertEqual(
            Set(MatchConfidenceRules.doubts(method: .fingerprint, localDuration: 1800,
                                            confidence: confidence)),
            [.durationDisagrees, .singleSubmission])
    }

    // MARK: - C5 — a silent source changes nothing

    /// The most important negative case. A provider supplying no fingerprint
    /// metadata must leave every match exactly as it is today, which is only
    /// possible because absence is a state rather than a value.
    func testC5ASourceSupplyingNothingLeavesTheMatchAlone() {
        let silent = MatchConfidence()
        XCTAssertTrue(silent.isEmpty)
        XCTAssertFalse(MatchConfidenceRules.needsReview(
            method: .fingerprint, localDuration: 1800, confidence: silent))
    }

    // MARK: - 🔴 C6 — fingerprints only

    /// A match made by title, cast, or the operator's own hand has no
    /// fingerprint behind it, so there is nothing to doubt. Asserted for every
    /// other method rather than a sample, because the set is small and a new
    /// method arriving is exactly when this would be forgotten.
    func testC6NoOtherMatchMethodIsDoubted() {
        for method in MatchMethod.allCases where method != .fingerprint {
            XCTAssertTrue(
                doubts(method, local: 1800, submissions: 1, claimed: 60).isEmpty,
                "\(method) has no fingerprint behind it and must not be doubted")
        }
    }

    /// ⭐ And the contrast, asserted with it: the SAME evidence on a fingerprint
    /// match does produce doubt. A test of the negative alone would pass on
    /// code that had stopped doubting anything at all.
    func testC6TheSameEvidenceOnAFingerprintMatchDoesDoubt() {
        XCTAssertEqual(Set(doubts(.fingerprint, local: 1800, submissions: 1, claimed: 60)),
                       [.durationDisagrees, .singleSubmission])
    }
}
