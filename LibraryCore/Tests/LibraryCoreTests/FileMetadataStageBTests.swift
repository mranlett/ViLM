// FileMetadataStageBTests.swift
// F6 Stage B — duration, dimensions and codec (#10).
//
// ⚠️ All names invented. This repository is public.

import XCTest
@testable import LibraryCore

final class FileMetadataStageBTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_600_000_000)

    private func asset(_ name: String, duration: Double? = nil, width: Int? = nil,
                       height: Int? = nil, codec: String? = nil,
                       modified: Date? = nil) -> Asset {
        Asset(relativePath: name, fileName: name, modifiedAt: modified,
              duration: duration, width: width, height: height, codec: codec)
    }

    private let facts = MediaFacts(duration: 120.5, width: 1920, height: 1080, codec: "avc1")

    private func run(_ assets: [Asset], readable: Set<String>,
                     onDisk: [String: Date] = [:], cancelAfter: Int? = nil)
        -> (StageBSummary, [String: Asset], opened: Int) {
        var written: [String: Asset] = [:]
        var opened = 0
        var seen = 0
        let summary = FileMetadataStageB.backfill(
            assets,
            modifiedOnDisk: { onDisk[$0.relativePath] },
            measure: { asset in
                opened += 1
                return readable.contains(asset.relativePath) ? self.facts : nil
            },
            isCancelled: {
                defer { seen += 1 }
                return cancelAfter.map { seen >= $0 } ?? false
            },
            write: { written[$0.relativePath] = $0 })
        return (summary, written, opened)
    }

    // MARK: - Measuring

    func testAnUnmeasuredFileIsOpenedAndRecorded() {
        let (summary, written, opened) = run([asset("a.mp4")], readable: ["a.mp4"])
        XCTAssertEqual(summary.measured, 1)
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(written["a.mp4"]?.duration, 120.5)
        XCTAssertEqual(written["a.mp4"]?.width, 1920)
        XCTAssertEqual(written["a.mp4"]?.height, 1080)
        XCTAssertEqual(written["a.mp4"]?.codec, "avc1")
    }

    /// 🚨 A measured file is never opened again. Opening is the entire cost of
    /// this stage, so an "already done" row that still gets opened means the
    /// second run costs exactly as much as the first.
    func testAMeasuredFileIsNotOpenedAgain() {
        let (summary, _, opened) = run(
            [asset("a.mp4", duration: 1, width: 2, height: 3, codec: "x")],
            readable: ["a.mp4"])
        XCTAssertEqual(summary.unchanged, 1)
        XCTAssertEqual(opened, 0, "not opened at all")
    }

    /// ⭐ Present means current UNLESS the file can be SHOWN to have changed.
    /// Requiring a matching modified date would re-open every file in a library
    /// where Stage A had never run — the one outcome this stage must not
    /// produce by accident.
    func testAMeasuredFileWithNoRecordedDateIsLeftAlone() {
        let (summary, _, opened) = run(
            [asset("a.mp4", duration: 1, width: 2, height: 3)],
            readable: ["a.mp4"], onDisk: ["a.mp4": t0])
        XCTAssertEqual(summary.unchanged, 1)
        XCTAssertEqual(opened, 0)
    }

    func testAFileChangedSinceItWasMeasuredIsReopened() {
        let (summary, _, opened) = run(
            [asset("a.mp4", duration: 1, width: 2, height: 3, modified: t0)],
            readable: ["a.mp4"], onDisk: ["a.mp4": t0.addingTimeInterval(60)])
        XCTAssertEqual(summary.measured, 1)
        XCTAssertEqual(opened, 1)
    }

    /// ⚠️ The same precision boundary as Stage A. Compared exactly, every
    /// measured file would be re-opened on every pass — which for this stage
    /// is not a wasted write but a full re-parse of the entire library.
    func testSubMillisecondRoundingDoesNotReopenTheLibrary() {
        let (summary, _, opened) = run(
            [asset("a.mp4", duration: 1, width: 2, height: 3, modified: t0)],
            readable: ["a.mp4"], onDisk: ["a.mp4": t0.addingTimeInterval(0.0004)])
        XCTAssertEqual(summary.unchanged, 1)
        XCTAssertEqual(opened, 0)
    }

    // MARK: - 🚨 One bad file must not cost the run

    func testAnUnreadableFileIsNamedAndTheRunContinues() {
        let (summary, written, _) = run(
            [asset("broken.mp4"), asset("fine.mp4")], readable: ["fine.mp4"])

        XCTAssertEqual(summary.unreadable, ["broken.mp4"])
        XCTAssertEqual(summary.measured, 1, "the rest of the library still got done")
        XCTAssertNil(written["broken.mp4"], "and its row is untouched")
        XCTAssertEqual(summary.considered, 2)
    }

    /// The list, not just the count. "1,290 of 1,300" with no names is a dead
    /// end for the one person who could do something about the other ten.
    func testUnreadableFilesAreNamedNotJustCounted() {
        let (summary, _, _) = run(
            [asset("a.mp4"), asset("b.mp4"), asset("c.mp4")], readable: ["b.mp4"])
        XCTAssertEqual(summary.unreadable, ["a.mp4", "c.mp4"])
    }

    // MARK: - Cancellation

    func testCancellingStopsOpeningFilesAndReportsWhatIsLeft() {
        let assets = (1...6).map { asset("\($0).mp4") }
        let (summary, written, opened) = run(
            assets, readable: Set(assets.map(\.relativePath)), cancelAfter: 2)

        XCTAssertEqual(summary.measured, 2)
        XCTAssertEqual(summary.remaining, 4)
        XCTAssertEqual(opened, 2, "cancelling means not opening, not opening and discarding")
        XCTAssertEqual(written.count, 2)
        XCTAssertEqual(summary.considered, 6)
    }

    // MARK: - 🚨 Display reads the catalogue

    func testDisplayingAMeasuredVideoOpensNothing() {
        let measured = asset("a.mp4", duration: 90, width: 1280, height: 720, codec: "hvc1")
        var opens = 0
        let (facts, opened) = FileMetadataStageB.display(for: measured) { _ in
            opens += 1; return nil
        }
        XCTAssertFalse(opened)
        XCTAssertEqual(opens, 0)
        XCTAssertEqual(facts?.duration, 90)
        XCTAssertEqual(facts?.width, 1280)
        XCTAssertEqual(facts?.codec, "hvc1")
    }

    /// ⚠️ And an unmeasured one still displays, by opening the file — the
    /// fallback that makes this whole stage optional.
    func testAnUnmeasuredVideoStillDisplaysByOpeningTheFile() {
        let (facts, opened) = FileMetadataStageB.display(for: asset("a.mp4")) { _ in
            MediaFacts(duration: 5, width: 640, height: 480, codec: nil)
        }
        XCTAssertTrue(opened)
        XCTAssertEqual(facts?.duration, 5)
    }

    /// A codec is the one field that may legitimately be absent, so its absence
    /// must not send the reader back to the file for the other three.
    func testAMissingCodecDoesNotForceAReopen() {
        let measured = asset("a.mp4", duration: 90, width: 1280, height: 720, codec: nil)
        let (_, opened) = FileMetadataStageB.display(for: measured) { _ in nil }
        XCTAssertFalse(opened)
    }
}
