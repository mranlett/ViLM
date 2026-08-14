// TagCooccurrenceTests.swift
// What tags travelling together does and does not prove.
//
// ⚠️ All tag names invented — this repository is public.
//
// 🚨 The distinction under test is the one the feature exists for: containment
// (a narrow tag inside a broad one, which argues for a hierarchy) is NOT the
// same finding as a merge (two names for one idea). A tool that confused them
// would invite the wrong action on half its findings.

import XCTest
@testable import LibraryCore

final class TagCooccurrenceTests: XCTestCase {

    /// `video 1: [a, b]` shorthand.
    private func edges(_ rows: [(String, [String])]) -> [GraphEdgePair] {
        rows.flatMap { row in row.1.map { GraphEdgePair(from: row.0, to: $0) } }
    }

    private func library(narrow: Int, broadOnly: Int,
                         narrowTag: String = "Kayaking",
                         broadTag: String = "Watersports") -> [GraphEdgePair] {
        var rows: [(String, [String])] = []
        for i in 0..<narrow { rows.append(("v-n\(i)", [narrowTag, broadTag])) }
        for i in 0..<broadOnly { rows.append(("v-b\(i)", [broadTag])) }
        return edges(rows)
    }

    // MARK: - Containment: the case for a hierarchy

    /// The shape the graph spike predicted: a narrow tag always accompanied by
    /// a broad one, which frequently appears without it.
    func testANarrowTagInsideABroadOneIsReportedAsContainment() {
        let report = TagCooccurrence.analyse(edges: library(narrow: 20, broadOnly: 60))

        XCTAssertEqual(report.merges.count, 0, "these are not synonyms")
        XCTAssertEqual(report.containment.count, 1)
        let finding = try? XCTUnwrap(report.containment.first)
        XCTAssertEqual(finding?.tag, "Kayaking")
        XCTAssertEqual(finding?.implies, "Watersports")
        XCTAssertEqual(finding?.confidence, 1.0)
        XCTAssertEqual(finding?.reverseConfidence, 0.25)
    }

    /// 🚨 Direction is the finding. Reported the other way round it would
    /// propose making the narrow tag the parent of the broad one.
    func testContainmentIsReportedInOneDirectionOnly() {
        let report = TagCooccurrence.analyse(edges: library(narrow: 20, broadOnly: 60))

        XCTAssertFalse(report.containment.contains { $0.tag == "Watersports" },
                       "the broad tag does not imply the narrow one")
    }

    // MARK: - Merge: the case for one name, not two

    /// Each implying the other is one idea under two names.
    func testTwoNamesForOneIdeaAreReportedAsAMergeAndNotAsAHierarchy() {
        let report = TagCooccurrence.analyse(edges: library(narrow: 30, broadOnly: 0,
                                                            narrowTag: "Cycling",
                                                            broadTag: "Biking"))

        XCTAssertEqual(report.merges.count, 1)
        XCTAssertTrue(report.containment.isEmpty,
                      "a synonym pair must never be proposed as a parent and child")
    }

    /// ⭐ The guard that makes the two findings distinguishable at all. Without
    /// the independence bound, a mutual pair satisfies containment in both
    /// directions and would be reported twice, as a hierarchy, wrongly.
    func testAMutualPairIsNeverAlsoReportedAsContainment() {
        let report = TagCooccurrence.analyse(edges: library(narrow: 30, broadOnly: 1,
                                                            narrowTag: "Cycling",
                                                            broadTag: "Biking"))

        XCTAssertEqual(report.merges.count, 1)
        XCTAssertEqual(report.containment.count, 0)
    }

    /// 🚨 The middle zone, and the only test that pins the independence bound.
    ///
    /// A implies B strongly (0.95) but B is not much bigger than A — it appears
    /// without A only 39% of the time. That is a heavy overlap, not a broad
    /// category containing a narrow one, and calling it a hierarchy would claim
    /// more than the numbers support. It is not a merge either, so nothing
    /// should be reported.
    ///
    /// ⚠️ Added after mutation testing: deleting the independence bound left
    /// all eight other tests passing, because a mutual pair is caught by the
    /// merge branch first and never reaches containment. Without this fixture
    /// the bound was decorative as far as the suite could tell.
    func testAHeavyOverlapIsNeitherAHierarchyNorAMerge() {
        var rows: [(String, [String])] = []
        for i in 0..<19 { rows.append(("v-p\(i)", ["Surfing", "Beaches"])) }
        rows.append(("v-s0", ["Surfing"]))                                  // A: 20 total
        for i in 0..<12 { rows.append(("v-b\(i)", ["Beaches"])) }           // B: 31 total

        let report = TagCooccurrence.analyse(edges: edges(rows))

        XCTAssertTrue(report.containment.isEmpty,
                      "0.95 one way and 0.61 back is an overlap, not a parent and child")
        XCTAssertTrue(report.merges.isEmpty, "nor is it two names for one idea")
    }

    // MARK: - Refusing to report noise

    /// ⚠️ Two tags on two videos are "100% together" and mean nothing. The
    /// support floor is what keeps a ratio from being mistaken for evidence.
    func testAPairTooSmallToMeanAnythingIsNotReported() {
        let report = TagCooccurrence.analyse(edges: library(narrow: 3, broadOnly: 40))

        XCTAssertTrue(report.isEmpty, "three shared videos is not evidence of anything")
    }

    func testTagsThatNeverTravelTogetherProduceNothing() {
        let report = TagCooccurrence.analyse(edges: edges(
            (0..<20).map { ("v-a\($0)", ["Baking"]) } + (0..<20).map { ("v-b\($0)", ["Welding"]) }))

        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(report.tagsConsidered, 2, "both were examined; neither implied the other")
    }

    /// A tag that mostly-but-not-always brings another is not containment at
    /// the default threshold — the line has to be somewhere, and 0.9 is where
    /// the measured library produces a list worth reading.
    func testAMerelyCommonPairingIsNotContainment() {
        var rows: [(String, [String])] = []
        for i in 0..<15 { rows.append(("v-n\(i)", ["Sailing", "Watersports"])) }
        for i in 0..<10 { rows.append(("v-x\(i)", ["Sailing"])) }   // 60% only
        for i in 0..<40 { rows.append(("v-b\(i)", ["Watersports"])) }

        XCTAssertTrue(TagCooccurrence.analyse(edges: edges(rows)).containment.isEmpty)
    }

    // MARK: - Arithmetic that would quietly corrupt a ranking

    /// 🚨 A repeated edge must not inflate a confidence past 1. `video_tag` is
    /// a set in intent, and the analysis divides by these counts.
    func testARepeatedEdgeIsCountedOnce() {
        var rows: [(String, [String])] = []
        for i in 0..<20 { rows.append(("v-n\(i)", ["Kayaking", "Watersports", "Kayaking"])) }
        for i in 0..<60 { rows.append(("v-b\(i)", ["Watersports"])) }

        let report = TagCooccurrence.analyse(edges: edges(rows))
        XCTAssertEqual(report.containment.first?.confidence, 1.0)
        XCTAssertEqual(report.containment.first?.together, 20)
    }

    /// Deterministic order, so a redraw never reshuffles a list being read.
    func testFindingsAreOrderedStrongestFirst() {
        var rows: [(String, [String])] = []
        for i in 0..<20 { rows.append(("v-p\(i)", ["Kayaking", "Watersports"])) }
        for i in 0..<20 { rows.append(("v-q\(i)", ["Rowing", "Watersports"])) }
        // ⚠️ ONE stray Rowing, not five. Five put it at 0.8 and below the
        // containment threshold entirely, so the first version of this test
        // asserted ordering against a list of one — it passed for the wrong
        // reason in the other direction. Both must qualify for the order
        // between them to mean anything.
        rows.append(("v-r0", ["Rowing"]))
        for i in 0..<80 { rows.append(("v-b\(i)", ["Watersports"])) }

        let found = TagCooccurrence.analyse(edges: edges(rows)).containment
        XCTAssertEqual(found.map(\.tag), ["Kayaking", "Rowing"])
    }
}
