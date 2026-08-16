// FileMetadataStageATests.swift
// F5 Stage A — size and modified date (#9).
//
// ⚠️ All names invented. This repository is public.

import XCTest
@testable import LibraryCore

final class FileMetadataStageATests: XCTestCase {

    private func asset(_ name: String, size: Int64? = nil, modified: Date? = nil) -> Asset {
        Asset(relativePath: name, fileName: name, fileSize: size, modifiedAt: modified)
    }

    private let t0 = Date(timeIntervalSince1970: 1_600_000_000)

    /// Runs a pass over a fake filesystem, returning the summary and writes.
    private func run(_ assets: [Asset], disk: [String: FileFacts],
                     cancelAfter: Int? = nil) -> (StageASummary, [String: Asset]) {
        var written: [String: Asset] = [:]
        var seen = 0
        let summary = FileMetadataStageA.backfill(
            assets,
            facts: { disk[$0.relativePath] },
            isCancelled: {
                defer { seen += 1 }
                return cancelAfter.map { seen >= $0 } ?? false
            },
            write: { written[$0.relativePath] = $0 })
        return (summary, written)
    }

    // MARK: - Measuring

    func testAnUnmeasuredFileIsMeasured() {
        let (summary, written) = run([asset("a.mp4")],
                                     disk: ["a.mp4": FileFacts(size: 42, modified: t0)])
        XCTAssertEqual(summary.measured, 1)
        XCTAssertEqual(written["a.mp4"]?.fileSize, 42)
        XCTAssertEqual(written["a.mp4"]?.modifiedAt, t0)
    }

    /// ⭐ An unchanged row is NOT rewritten. Without this, a backfill over an
    /// unchanged library is a full table write every time it runs.
    func testAnAlreadyCorrectRowIsNotRewritten() {
        let (summary, written) = run([asset("a.mp4", size: 42, modified: t0)],
                                     disk: ["a.mp4": FileFacts(size: 42, modified: t0)])
        XCTAssertEqual(summary.unchanged, 1)
        XCTAssertEqual(summary.measured, 0)
        XCTAssertTrue(written.isEmpty, "no write at all")
    }

    // MARK: - 🚨 The precision boundary

    /// A stored date reads back rounded to the millisecond, so a live
    /// `FileManager` value is microseconds away from what was written. Compared
    /// exactly, EVERY row is stale on EVERY pass — the whole table rewritten
    /// forever, reported as "refreshed", which looks like the feature working.
    ///
    /// ⚠️ Same boundary that broke `EntityTombstone.shouldPropagate`. Asserted
    /// here rather than rediscovered there.
    func testASubMillisecondDifferenceIsNotStaleness() {
        let stored = t0
        let onDisk = t0.addingTimeInterval(0.0004)
        let (summary, written) = run([asset("a.mp4", size: 42, modified: stored)],
                                     disk: ["a.mp4": FileFacts(size: 42, modified: onDisk)])
        XCTAssertEqual(summary.unchanged, 1, "rounding is not a change")
        XCTAssertTrue(written.isEmpty)
    }

    /// ⚠️ And the tolerance is the granularity and nothing more generous, or
    /// real edits within the same second stop being noticed.
    func testARealEditIsStillDetected() {
        let (summary, written) = run(
            [asset("a.mp4", size: 42, modified: t0)],
            disk: ["a.mp4": FileFacts(size: 42, modified: t0.addingTimeInterval(0.5))])
        XCTAssertEqual(summary.refreshed, 1)
        XCTAssertEqual(written["a.mp4"]?.modifiedAt, t0.addingTimeInterval(0.5))
    }

    func testAChangedSizeIsStalenessEvenAtTheSameInstant() {
        let (summary, _) = run([asset("a.mp4", size: 42, modified: t0)],
                               disk: ["a.mp4": FileFacts(size: 99, modified: t0)])
        XCTAssertEqual(summary.refreshed, 1)
    }

    // MARK: - 🚨 A missing file does not destroy a good measurement

    /// An unplugged drive is not evidence that a file has no size. Blanking the
    /// row would throw away a correct measurement and force a re-measure from
    /// nothing the next time the volume appears.
    func testAMissingFileLeavesTheRecordedValuesAlone() {
        let (summary, written) = run([asset("gone.mp4", size: 42, modified: t0)], disk: [:])
        XCTAssertEqual(summary.missing, 1)
        XCTAssertTrue(written.isEmpty, "the recorded size survives the drive being away")
    }

    // MARK: - Cancellation and resumability

    /// Cancelling leaves what was written written. That is a supported state,
    /// not damage: null means "not measured yet" and readers fall back.
    func testCancellingKeepsWhatWasAlreadyWrittenAndReportsTheRest() {
        let assets = (1...5).map { asset("\($0).mp4") }
        var disk: [String: FileFacts] = [:]
        for i in 1...5 { disk["\(i).mp4"] = FileFacts(size: Int64(i), modified: t0) }

        let (summary, written) = run(assets, disk: disk, cancelAfter: 2)

        XCTAssertEqual(summary.measured, 2)
        XCTAssertEqual(summary.remaining, 3)
        XCTAssertEqual(written.count, 2)
        XCTAssertEqual(summary.considered, 5, "every input is accounted for")
    }

    /// ⭐ Resumable by construction: re-running does the rest and re-does
    /// nothing. There is no checkpoint to keep consistent — which matters
    /// because a checkpoint is exactly the state that goes wrong when the
    /// process dies, the case it would exist for.
    func testResumingDoesTheRestAndRedoesNothing() {
        var assets = (1...5).map { asset("\($0).mp4") }
        var disk: [String: FileFacts] = [:]
        for i in 1...5 { disk["\(i).mp4"] = FileFacts(size: Int64(i), modified: t0) }

        let (_, firstWrites) = run(assets, disk: disk, cancelAfter: 2)
        // Fold the partial result back in, as a real resume would.
        assets = assets.map { firstWrites[$0.relativePath] ?? $0 }

        let (second, secondWrites) = run(assets, disk: disk)

        XCTAssertEqual(second.measured, 3, "only the ones left")
        XCTAssertEqual(second.unchanged, 2, "the finished ones are not touched again")
        XCTAssertEqual(secondWrites.count, 3)
    }

    // MARK: - 🚨 Sorting reads the catalogue, not the disk

    /// The acceptance criterion in testable form. A fully-backfilled library
    /// must reach the filesystem ZERO times to sort by size.
    func testSortingAFullyMeasuredLibraryReadsNoFiles() {
        let assets = (1...50).map { asset("\($0).mp4", size: Int64($0), modified: t0) }
        var reads = 0
        let (sizes, read) = FileMetadataStageA.sizes(for: assets) { _ in
            reads += 1; return 0
        }
        XCTAssertEqual(read, 0)
        XCTAssertEqual(reads, 0, "not one stat call")
        XCTAssertEqual(sizes.count, 50)
    }

    /// ⚠️ And the fallback is KEPT. A library never backfilled, or cancelled
    /// halfway, still sorts correctly — degrading to the old behaviour for the
    /// rows that lack a value is the entire reason the columns are nullable.
    func testAnUnmeasuredRowStillFallsBackToTheDisk() {
        let assets = [asset("measured.mp4", size: 10, modified: t0), asset("not.mp4")]
        let (sizes, read) = FileMetadataStageA.sizes(for: assets) { _ in 99 }
        XCTAssertEqual(read, 1, "only the unmeasured one")
        XCTAssertEqual(sizes[assets[0].id], 10)
        XCTAssertEqual(sizes[assets[1].id], 99)
    }
}
