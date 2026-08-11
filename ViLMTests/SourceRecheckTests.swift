// SourceRecheckTests.swift
// The sweep's accounting: what it records, and what it refuses to.
//
// 🚨 U2 is the property that matters most in this whole feature, and it was
// only ever verified by putting a phone into airplane mode. It says a failure
// to reach the source must never be recorded as a deletion — and a sweep is
// where that goes catastrophically wrong, because one dropped connection would
// mark an entire library gone in a single pass.
//
// ⭐ The fetch is injected, so every outcome including a total network failure
// is reachable without a provider, a registry or a network.

import XCTest
import LibraryCore
@testable import ViLM

final class SourceRecheckTests: XCTestCase {

    private func targets(_ n: Int) -> [RecheckTarget] {
        (0..<n).map { RecheckTarget(nodeId: "n-\($0)", sourceId: "s-\($0)", isVideo: false) }
    }

    /// Collects what the sweep decided to persist.
    private final class Recorder {
        var written: [(String, SourceRecordState)] = []
        func record(_ t: RecheckTarget, _ s: SourceRecordState) { written.append((t.nodeId, s)) }
    }

    // MARK: - 🚨 U2 — a failure is never a deletion

    /// The airplane-mode sweep. 1,245 unreachable records must produce ZERO
    /// writes — not 1,245 deletions.
    func testATotalNetworkFailureRecordsNothing() async {
        let recorder = Recorder()

        let summary = await SourceRecheck.run(
            targets: targets(50),
            ask: { _ in .unreachable },
            record: recorder.record)

        XCTAssertTrue(recorder.written.isEmpty, "not one conclusion was given")
        XCTAssertEqual(summary.unreachable, 50)
        XCTAssertEqual(summary.recorded, 0)
        XCTAssertEqual(summary.checked, 50)
    }

    /// ⚠️ And it SAYS so. A sweep that failed throughout must not read as a
    /// clean bill of health.
    func testAFailedSweepReportsTheFailures() async {
        let summary = await SourceRecheck.run(
            targets: targets(10), ask: { _ in .unreachable }, record: { _, _ in })

        let sentence = summary.sentence(of: 10)
        XCTAssertTrue(sentence.contains("10 could not be reached"), sentence)
        XCTAssertTrue(sentence.contains("left as they were"), sentence)
    }

    // MARK: - 🚨 notFound is its own answer

    /// The distinction that cost a day. A timeout means the source said
    /// nothing; `notFound` means it answered "no record under that id" — and
    /// if the source returns deleted records as null, that is the only signal
    /// there will ever be.
    func testNotFoundIsCountedApartFromUnreachable() async {
        let recorder = Recorder()

        let summary = await SourceRecheck.run(
            targets: targets(4),
            ask: { t in t.nodeId == "n-0" || t.nodeId == "n-1" ? .notFound : .unreachable },
            record: recorder.record)

        XCTAssertEqual(summary.notFound, 2)
        XCTAssertEqual(summary.unreachable, 2)
        XCTAssertTrue(recorder.written.isEmpty, "neither is a conclusion to record")
    }

    /// ⚠️ Counted, NOT flagged as a deletion. A missing id is still ambiguous
    /// between "removed" and "merged away under a new id".
    func testNotFoundIsReportedInWordsTheOperatorCanActOn() async {
        let summary = await SourceRecheck.run(
            targets: targets(3), ask: { _ in .notFound }, record: { _, _ in })

        let sentence = summary.sentence(of: 3)
        XCTAssertTrue(sentence.contains("3 returned no record"), sentence)
        XCTAssertTrue(sentence.contains("may report deletions this way"), sentence)
    }

    // MARK: - What it does record

    func testAnAnsweredStateIsRecorded() async {
        let recorder = Recorder()

        let summary = await SourceRecheck.run(
            targets: targets(3),
            ask: { t in
                switch t.nodeId {
                case "n-0": return .state(.deleted)
                case "n-1": return .state(.merged(into: "p-new"))
                default:    return .state(.present)
                }
            },
            record: recorder.record)

        XCTAssertEqual(summary.recorded, 3)
        XCTAssertEqual(recorder.written.map(\.1),
                       [.deleted, .merged(into: "p-new"), .present])
    }

    /// ⭐ `.present` is recorded too. Stamping a healthy match is what turns
    /// "nothing missing" from a statement about our ignorance into one about
    /// the source.
    func testAHealthyRecordIsStillWrittenDown() async {
        let recorder = Recorder()

        _ = await SourceRecheck.run(targets: targets(1),
                                    ask: { _ in .state(.present) },
                                    record: recorder.record)

        XCTAssertEqual(recorder.written.count, 1)
    }

    // MARK: - Stopping

    /// ⚠️ What has been checked stays checked — the screen promises this.
    func testStoppingKeepsWhatWasAlreadyRecorded() async {
        let recorder = Recorder()
        var seen = 0

        let summary = await SourceRecheck.run(
            targets: targets(10),
            ask: { _ in seen += 1; return .state(.present) },
            record: recorder.record,
            isCancelled: { seen >= 3 })

        XCTAssertEqual(recorder.written.count, 3)
        XCTAssertEqual(summary.checked, 3)
        XCTAssertLessThan(summary.checked, 10, "it stopped early")
    }

    func testProgressIsReportedAsItGoes() async {
        var ticks: [Int] = []

        _ = await SourceRecheck.run(targets: targets(3),
                                    ask: { _ in .state(.present) },
                                    record: { _, _ in },
                                    progress: { ticks.append($0) })

        XCTAssertEqual(ticks, [1, 2, 3])
    }

    func testAnEmptySweepSaysSoWithoutFailing() async {
        let summary = await SourceRecheck.run(targets: [], ask: { _ in .unreachable },
                                              record: { _, _ in })

        XCTAssertEqual(summary, .init())
        XCTAssertEqual(summary.sentence(of: 0), "Checked 0 of 0.")
    }
}
