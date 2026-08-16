// SidecarBackfillTests.swift
// #75 — B1 to B4, plus the privacy finding the summary exists to surface.
//
// ⚠️ All names invented. This repository is public.

import XCTest
@testable import LibraryCore

final class SidecarBackfillTests: XCTestCase {

    private func asset(_ path: String, kind: ContentKind? = .scene,
                       tags: [String] = []) -> Asset {
        Asset(relativePath: path, fileName: (path as NSString).lastPathComponent,
              tags: tags, episode: "A Title", contentKind: kind)
    }

    /// Runs the pass over a fake disk, returning what it did and what landed.
    private func backfill(_ assets: [Asset], existing: Set<String> = [],
                          failing: Set<String> = [])
        -> (SidecarBackfillSummary, [String: String]) {
        var wrote: [String: String] = [:]
        let summary = SidecarBackfill.run(
            assets: assets,
            fileExists: { existing.contains($0) || wrote[$0] != nil },
            write: { path, document in
                if failing.contains(path) { throw CocoaError(.fileWriteNoPermission) }
                wrote[path] = document
            })
        return (summary, wrote)
    }

    // MARK: - B1 — a relocated video with no sidecar gains one

    func testB1AVideoWithNoSidecarGainsOne() {
        let (summary, wrote) = backfill([asset("Example Pictures/Example Pictures - Alice - 2019.mp4")])
        XCTAssertEqual(summary.written, 1)
        XCTAssertEqual(Array(wrote.keys), ["Example Pictures/Example Pictures - Alice - 2019.nfo"],
                       "named for the file it accompanies, beside it")
        XCTAssertTrue(wrote.values.first?.contains("<movie>") == true)
    }

    /// ⭐ Filing state is irrelevant — the sidecar does not care where the file
    /// sits, and an unfiled video leaving ViLM should mean something too.
    func testB1AVideoStillInTheLibraryRootAlsoGainsOne() {
        let (summary, wrote) = backfill([asset("loose file.mp4")])
        XCTAssertEqual(summary.written, 1)
        XCTAssertEqual(Array(wrote.keys), ["loose file.nfo"])
    }

    // MARK: - 🚨 B2 — personal and undeclared gain nothing, and are COUNTED

    /// Asserted for both states separately: they are different states that must
    /// produce the same silence, and undeclared is not the same as safe.
    func testB2PersonalAndUndeclaredGainNothingAndAreCounted() {
        let (summary, wrote) = backfill([
            asset("home/Beach Trip.mp4", kind: .personal),
            asset("unsorted/Something.mp4", kind: nil),
            asset("Example Pictures/A Scene.mp4", kind: .scene),
        ])
        XCTAssertEqual(summary.written, 1)
        XCTAssertEqual(summary.refused, 2)
        XCTAssertEqual(wrote.count, 1, "only the declared commercial video was written")
        XCTAssertNil(wrote["home/Beach Trip.nfo"])
        XCTAssertNil(wrote["unsorted/Something.nfo"])
    }

    /// 🚨 The count is the point. A run reporting only "wrote 1" over a library
    /// of three reads as two failures, and the operator cannot tell a refusal
    /// from a fault without it.
    func testB2EveryVideoLandsInExactlyOneBucket() {
        let (summary, _) = backfill(
            [asset("a.mp4"), asset("b.mp4"), asset("c.mp4", kind: .personal), asset("d.mp4")],
            existing: ["b.nfo"], failing: ["d.nfo"])
        XCTAssertEqual(summary.written, 1)
        XCTAssertEqual(summary.alreadyPresent, 1)
        XCTAssertEqual(summary.refused, 1)
        XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(summary.considered, 4, "the buckets must sum to the input")
    }

    // MARK: - B3 / B4 — additive and idempotent

    func testB3AnExistingSidecarIsNotRewritten() {
        let (summary, wrote) = backfill([asset("a.mp4")], existing: ["a.nfo"])
        XCTAssertEqual(summary.alreadyPresent, 1)
        XCTAssertEqual(summary.written, 0)
        XCTAssertTrue(wrote.isEmpty,
                      "another tool's document must never be overwritten")
    }

    /// B4 — the second run must be a no-op, which is what makes this safe to
    /// offer as a button rather than as a one-time migration.
    func testB4RunningItTwiceChangesNothingTheSecondTime() {
        let assets = [asset("a.mp4"), asset("b.mp4", kind: .personal)]
        var wrote: [String: String] = [:]
        func pass() -> SidecarBackfillSummary {
            SidecarBackfill.run(assets: assets,
                                fileExists: { wrote[$0] != nil },
                                write: { wrote[$0] = $1 })
        }
        let first = pass()
        let snapshot = wrote
        let second = pass()

        XCTAssertEqual(first.written, 1)
        XCTAssertEqual(second.written, 0)
        XCTAssertEqual(second.alreadyPresent, 1)
        XCTAssertEqual(wrote, snapshot, "the disk is byte-identical after the second run")
    }

    // MARK: - 🚨 The finding the summary exists to surface

    /// A plaintext document naming people and places, sitting beside personal
    /// content on removable media, is the thing D4 exists to prevent. This pass
    /// does not delete it — that is a decision about the operator's data — but
    /// refusing to write while saying nothing about the one already there would
    /// be the least useful possible response.
    func testPersonalContentThatAlreadyHasASidecarIsReported() {
        let (summary, wrote) = backfill([asset("home/Beach Trip.mp4", kind: .personal)],
                                        existing: ["home/Beach Trip.nfo"])
        XCTAssertEqual(summary.refused, 1)
        XCTAssertEqual(summary.refusedButPresent, 1)
        XCTAssertTrue(wrote.isEmpty, "and it is still not written to")
    }

    /// ⚠️ Pins the ORDER of the two checks. If existence were tested first, a
    /// personal video with a sidecar would count as `alreadyPresent` and the
    /// finding above would vanish into the comfortable bucket.
    func testTheRefusalIsDecidedBeforeExistenceNotAfter() {
        let (summary, _) = backfill([asset("home/x.mp4", kind: .personal)],
                                    existing: ["home/x.nfo"])
        XCTAssertEqual(summary.alreadyPresent, 0,
                       "a refusal is not an 'already present'")
        XCTAssertEqual(summary.refused, 1)
    }
}
