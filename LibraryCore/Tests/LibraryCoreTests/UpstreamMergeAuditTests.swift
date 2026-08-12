// UpstreamMergeAuditTests.swift
// The duplicate the source already resolved (M1–M5).
//
// ⚠️ All names here are invented. This repository is public — see the note in
// `AliasSplitAudit`. Do not replace them with anything from the library.

import XCTest
@testable import LibraryCore

final class UpstreamMergeAuditTests: XCTestCase {

    private func match(_ node: String, sourceId: String, mergedInto: String? = nil,
                       source: String = "src") -> NodeMatch {
        NodeMatch(nodeId: node, source: source, sourceId: sourceId, method: .`operator`,
                  matchedAt: Date(timeIntervalSince1970: 0),
                  deletedAt: nil, mergedInto: mergedInto, checkedAt: nil)
    }

    // MARK: - M1, M4 — the pair, and which way round it goes

    /// 🚨 M4. `merged_into` means *this record was merged AWAY*, so the profile
    /// carrying it LOSES. Reading it the other way proposes merging the
    /// survivor into the ghost.
    func testTheProfileWhoseRecordWasMergedAwayIsTheLoser() {
        let pairs = UpstreamMergeAudit.pairs(from: [
            match("keep", sourceId: "S"),
            match("fold", sourceId: "T", mergedInto: "S"),
        ])

        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.survivingId, "keep")
        XCTAssertEqual(pairs.first?.losingId, "fold")
        XCTAssertEqual(pairs.first?.survivingSourceId, "S")
    }

    // MARK: - M5 — one side only

    /// ⚠️ Holding only the losing side is a STALENESS finding, not a duplicate
    /// one. *Upstream Deletions* reports it; emitting it here too would put one
    /// fact in two screens suggesting two different actions.
    func testAMergeWhoseSurvivorThisLibraryDoesNotHoldYieldsNothing() {
        XCTAssertTrue(UpstreamMergeAudit.pairs(from: [
            match("fold", sourceId: "T", mergedInto: "S")
        ]).isEmpty)
    }

    func testAPlainMatchWithNoMergeYieldsNothing() {
        XCTAssertTrue(UpstreamMergeAudit.pairs(from: [
            match("a", sourceId: "S"), match("b", sourceId: "T"),
        ]).isEmpty)
    }

    // MARK: - Things the source should never say, and must not break us

    func testARecordMergedIntoItselfIsNotAPair() {
        XCTAssertTrue(UpstreamMergeAudit.pairs(from: [
            match("solo", sourceId: "S", mergedInto: "S")
        ]).isEmpty)
    }

    func testAnEmptyForwardingIdIsNotAPair() {
        XCTAssertTrue(UpstreamMergeAudit.pairs(from: [
            match("keep", sourceId: "S"),
            match("fold", sourceId: "T", mergedInto: "   "),
        ]).isEmpty)
    }

    /// ⚠️ Two sources can use the same record id for different people. Pairing
    /// across them would merge two unrelated performers.
    func testAMergeIsNotPairedAcrossDifferentSources() {
        XCTAssertTrue(UpstreamMergeAudit.pairs(from: [
            match("keep", sourceId: "S", source: "alpha"),
            match("fold", sourceId: "T", mergedInto: "S", source: "beta"),
        ]).isEmpty)
    }

    func testTheSameNodeOnBothSidesIsNotAPair() {
        XCTAssertTrue(UpstreamMergeAudit.pairs(from: [
            match("one", sourceId: "S"),
            match("one", sourceId: "T", mergedInto: "S"),
        ]).isEmpty)
    }

    /// Two locals merged into one survivor are two pairs, not one.
    func testTwoRecordsMergedIntoOneSurvivorGiveTwoPairs() {
        let pairs = UpstreamMergeAudit.pairs(from: [
            match("keep", sourceId: "S"),
            match("foldA", sourceId: "T", mergedInto: "S"),
            match("foldB", sourceId: "U", mergedInto: "S"),
        ])
        XCTAssertEqual(Set(pairs.map(\.losingId)), ["foldA", "foldB"])
        XCTAssertEqual(Set(pairs.map(\.survivingId)), ["keep"])
    }

    func testTheOrderIsStable() {
        let matches = [
            match("keep", sourceId: "S"),
            match("foldB", sourceId: "U", mergedInto: "S"),
            match("foldA", sourceId: "T", mergedInto: "S"),
        ]
        XCTAssertEqual(UpstreamMergeAudit.pairs(from: matches),
                       UpstreamMergeAudit.pairs(from: matches.reversed()))
    }

    func testSurvivorByLoserIsTheMapTheAuditConsumes() {
        let map = UpstreamMergeAudit.survivorByLoser(from: [
            match("keep", sourceId: "S"),
            match("fold", sourceId: "T", mergedInto: "S"),
        ])
        XCTAssertEqual(map, ["fold": "keep"])
    }
}
