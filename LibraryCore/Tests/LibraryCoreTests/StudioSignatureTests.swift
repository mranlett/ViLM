// StudioSignatureTests.swift
// When in a career a studio works, and what the number must refuse to claim.
//
// ⚠️ All names invented — this repository is public.

import XCTest
@testable import LibraryCore

final class StudioSignatureTests: XCTestCase {

    private func observations(_ studio: String,
                              stages: [Int],
                              performerPrefix: String = "p") -> [CareerStageObservation] {
        stages.enumerated().map {
            CareerStageObservation(studioId: studio,
                                   performerId: "\(performerPrefix)\($0.offset)",
                                   yearsIntoCareer: $0.element)
        }
    }

    private func signature(_ report: StudioSignatureReport, _ id: String) -> StudioSignature? {
        report.signatures.first { $0.studioId == id }
    }

    // MARK: - The characters

    /// A studio that keeps appearing in somebody's first two years.
    func testAStudioThatWorksWithNewcomersIsADiscoveryHouse() {
        let report = StudioSignatureAnalysis.analyse(
            observations("Northwind", stages: [0, 0, 1, 1, 0, 2]))

        XCTAssertEqual(signature(report, "Northwind")?.character, .discovery)
        XCTAssertEqual(signature(report, "Northwind")?.shareInFirstTwoYears ?? 0, 5.0 / 6.0,
                       accuracy: 0.001)
    }

    func testAStudioWorkingDeepIntoCareersIsALateCareerLabel() {
        let report = StudioSignatureAnalysis.analyse(
            observations("Lantern", stages: [11, 12, 14, 15, 20]))

        XCTAssertEqual(signature(report, "Lantern")?.character, .lateCareer)
    }

    /// ⭐ Most studios are neither, and saying so is the point. A screen where
    /// every studio has a striking character is a screen nobody believes.
    func testAnOrdinaryStudioIsNeitherAndIsStillReported() {
        let report = StudioSignatureAnalysis.analyse(
            observations("Meridian", stages: [3, 4, 5, 6, 7]))

        XCTAssertEqual(signature(report, "Meridian")?.character, .established)
    }

    /// ⚠️ A studio can be mostly-early AND have a tail long enough to push its
    /// median past the late-career line. The early share is the more specific
    /// claim, so it wins.
    func testMostlyEarlyWithALongTailIsStillADiscoveryHouse() {
        let report = StudioSignatureAnalysis.analyse(
            observations("Harbour", stages: [0, 0, 0, 1, 30, 32, 34]))

        XCTAssertEqual(signature(report, "Harbour")?.character, .discovery)
    }

    // MARK: - 🚨 What it refuses to claim

    /// Below the evidence floor a "signature" is one or two videos and the word
    /// is a lie. Counted, not silently dropped.
    func testAStudioWithTooLittleEvidenceIsExcludedAndCounted() {
        let report = StudioSignatureAnalysis.analyse(
            observations("Tiny", stages: [0, 1]) + observations("Big", stages: [3, 4, 5, 6, 7]))

        XCTAssertNil(signature(report, "Tiny"))
        XCTAssertEqual(report.studiosBelowEvidenceFloor, 1)
        XCTAssertEqual(report.signatures.count, 1)
    }

    /// 🚨 A video released before the performer's recorded career start is a
    /// contradiction between two records. It must not enter the arithmetic —
    /// and must not vanish either.
    func testImpossibleObservationsAreExcludedAndSurfaced() {
        let report = StudioSignatureAnalysis.analyse(
            observations("Northwind", stages: [-41, -3, 8, 9, 10, 11, 12]))

        XCTAssertEqual(report.impossibleObservations, 2)
        XCTAssertEqual(signature(report, "Northwind")?.observations, 5,
                       "only the usable five are counted")
        XCTAssertEqual(signature(report, "Northwind")?.medianYearsIntoCareer, 10)
    }

    /// ⭐ The reason the median exists. One impossible record would drag a mean
    /// far enough to invent a discovery house; excluded, it cannot — and even
    /// an extreme LEGITIMATE outlier barely moves the median.
    func testOneExtremeOutlierDoesNotDecideTheCharacter() {
        let withOutlier = StudioSignatureAnalysis.analyse(
            observations("Lantern", stages: [11, 12, 14, 15, 0]))

        XCTAssertEqual(signature(withOutlier, "Lantern")?.character, .lateCareer,
                       "a single early appearance does not make a discovery house")
    }

    /// ⚠️ Twenty observations of one performer is not twenty pieces of
    /// evidence, and the two counts together are the only way to see it.
    func testDistinctPerformersAreCountedApartFromObservations() {
        let repeated = (0..<8).map {
            CareerStageObservation(studioId: "Solo", performerId: "one", yearsIntoCareer: $0)
        }
        let report = StudioSignatureAnalysis.analyse(repeated)

        XCTAssertEqual(signature(report, "Solo")?.observations, 8)
        XCTAssertEqual(signature(report, "Solo")?.performers, 1)
    }

    // MARK: - Arithmetic

    /// 🚨 Taking the lower middle on an even count would bias every such studio
    /// a year earlier — exactly the direction that manufactures discovery
    /// houses out of ordinary ones.
    func testTheMedianOfAnEvenCountIsTheAverageOfTheMiddleTwo() {
        XCTAssertEqual(StudioSignatureAnalysis.median(of: [2, 4]), 3)
        XCTAssertEqual(StudioSignatureAnalysis.median(of: [1, 2, 3, 10]), 2.5)
        XCTAssertEqual(StudioSignatureAnalysis.median(of: [5]), 5)
    }

    func testAStudioWithNoUsableObservationsProducesNoSignature() {
        let report = StudioSignatureAnalysis.analyse(observations("Ghost", stages: [-1, -2, -3]))

        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(report.impossibleObservations, 3)
    }
}
