// MatchConfidenceStoreTests.swift
// Match Confidence, against a real database: recording (D3) and the queue.
//
// ⚠️ All names invented. This repository is public.

import XCTest
import GRDB
@testable import LibraryCore

final class MatchConfidenceStoreTests: XCTestCase {

    private var libraryURL: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        libraryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MatchConf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        store = try LibraryStore(at: libraryURL)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: libraryURL)
    }

    @discardableResult
    private func video(_ name: String, duration: Double?) throws -> Asset {
        let asset = Asset(relativePath: name, fileName: name, duration: duration)
        try store.insertAsset(asset)
        return asset
    }

    private func match(_ asset: Asset, method: MatchMethod = .fingerprint,
                       confidence: MatchConfidence = MatchConfidence()) throws {
        var m = NodeMatch(nodeId: asset.id.uuidString, source: "Example Source",
                          sourceId: "abc", method: method, matchedAt: Date())
        m.confidence = confidence
        try store.recordMatch(m, isVideo: true)
    }

    private func stored(_ asset: Asset) throws -> Row? {
        try store.dbQueue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT submissions, fingerprint_duration, algorithm, confidence_as_of
                  FROM video_match WHERE video_id = ?
                """, arguments: [asset.id.uuidString])
        }
    }

    // MARK: - 🚨 D3 — recorded on the edge, with an as-of

    func testConfidenceIsStoredOnTheMatchEdge() throws {
        let asset = try video("a.mp4", duration: 1800)
        try match(asset, confidence: MatchConfidence(submissions: 12,
                                                     fingerprintDuration: 1799,
                                                     algorithm: "phash"))
        let row = try XCTUnwrap(try stored(asset))
        XCTAssertEqual(row["submissions"], 12)
        XCTAssertEqual(row["fingerprint_duration"], 1799.0)
        XCTAssertEqual(row["algorithm"], "phash")
        XCTAssertNotNil(row["confidence_as_of"] as Date?, "a confidence with no date cannot be aged")
    }

    /// 🚨 C5 — a source that says nothing leaves the match exactly as before,
    /// including leaving the as-of empty. A timestamp on an empty confidence
    /// would claim we asked and were told nothing, which is a different fact.
    func testASilentSourceStampsNothing() throws {
        let asset = try video("a.mp4", duration: 1800)
        try match(asset)
        let row = try XCTUnwrap(try stored(asset))
        XCTAssertNil(row["submissions"] as Int?)
        XCTAssertNil(row["confidence_as_of"] as Date?)
    }

    /// Re-matching the same node in the same source REPLACES its confidence,
    /// matching how the rest of the row already behaves — a second opinion from
    /// the same place is a correction, not an accumulation.
    func testRematchingReplacesTheConfidence() throws {
        let asset = try video("a.mp4", duration: 1800)
        try match(asset, confidence: MatchConfidence(submissions: 1))
        try match(asset, confidence: MatchConfidence(submissions: 40))
        XCTAssertEqual(try XCTUnwrap(try stored(asset))["submissions"], 40)
    }

    // MARK: - The queue

    func testTheQueueListsOnlyDoubtfulFingerprintMatches() throws {
        let doubtful = try video("doubtful.mp4", duration: 1800)
        try match(doubtful, confidence: MatchConfidence(submissions: 1))

        let solid = try video("solid.mp4", duration: 1800)
        try match(solid, confidence: MatchConfidence(submissions: 40, fingerprintDuration: 1801))

        let byHand = try video("byhand.mp4", duration: 1800)
        try match(byHand, method: .operator, confidence: MatchConfidence(submissions: 1))

        let queue = try store.lowConfidenceMatches()
        XCTAssertEqual(queue.map(\.fileName), ["doubtful.mp4"])
        XCTAssertEqual(queue.first?.doubts, [.singleSubmission])
    }

    /// ⚠️ BOTH runtimes are carried, not a verdict. "They disagree" is not
    /// actionable; 1800 against 3600 is, because it reads as a different cut.
    func testTheRowCarriesTheEvidenceNotJustTheVerdict() throws {
        let asset = try video("a.mp4", duration: 1800)
        try match(asset, confidence: MatchConfidence(submissions: 1, fingerprintDuration: 3600))

        let row = try XCTUnwrap(try store.lowConfidenceMatches().first)
        XCTAssertEqual(row.localDuration, 1800)
        XCTAssertEqual(row.claimedDuration, 3600)
        XCTAssertEqual(row.submissions, 1)
        XCTAssertEqual(Set(row.doubts), [.durationDisagrees, .singleSubmission])
    }

    /// Worst first — a row with two doubts outranks one, and a duration
    /// disagreement outranks a lone submitter.
    func testTheQueueIsOrderedWorstFirst() throws {
        let both = try video("both.mp4", duration: 1800)
        try match(both, confidence: MatchConfidence(submissions: 1, fingerprintDuration: 60))
        let onlyDuration = try video("duration.mp4", duration: 1800)
        try match(onlyDuration, confidence: MatchConfidence(submissions: 9, fingerprintDuration: 60))
        let onlySubmission = try video("submission.mp4", duration: 1800)
        try match(onlySubmission, confidence: MatchConfidence(submissions: 1))

        XCTAssertEqual(try store.lowConfidenceMatches().map(\.fileName),
                       ["both.mp4", "duration.mp4", "submission.mp4"])
    }

    /// 🚨 An unmeasured video raises no doubt. Its only fault would be that
    /// Measure Videos has not run, and a queue full of those buries the real
    /// ones.
    func testAnUnmeasuredVideoIsNotQueued() throws {
        let asset = try video("a.mp4", duration: nil)
        try match(asset, confidence: MatchConfidence(fingerprintDuration: 3600))
        XCTAssertTrue(try store.lowConfidenceMatches().isEmpty)
    }

    /// 🚨 The honest denominator. An empty queue over 773 unassessed matches is
    /// not a clean library, and the screen has to be able to say so.
    func testUnassessedMatchesAreCountedSeparately() throws {
        let silent = try video("silent.mp4", duration: 1800)
        try match(silent)
        let assessed = try video("assessed.mp4", duration: 1800)
        try match(assessed, confidence: MatchConfidence(submissions: 40))

        XCTAssertTrue(try store.lowConfidenceMatches().isEmpty, "neither is doubtful…")
        XCTAssertEqual(try store.fingerprintMatchesWithoutConfidence(), 1,
                       "…but one of them was never assessed at all")
    }
}
