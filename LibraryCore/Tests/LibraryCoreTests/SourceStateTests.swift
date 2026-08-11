// SourceStateTests.swift
// What the source says about a record we hold (#48 — U6–U8, U13).
//
// 🚨 U7 is the one that would have shipped broken. D4 says the flag rides along
// on fetches the app already makes, which reads as "there is nothing to store".
// But the audit is opened LATER, and a flag seen during a fetch and thrown away
// is a flag the audit never sees — the same shape as the scene description this
// project fetched and discarded for months.

import XCTest
import GRDB
@testable import LibraryCore

final class SourceStateTests: XCTestCase {

    private var url: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceState-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store = try LibraryStore(at: url)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    private func matchedVideo(_ sourceId: String = "s-1") throws -> UUID {
        let asset = Asset(relativePath: "\(UUID()).mp4", fileName: "v.mp4", tags: [])
        try store.insertAsset(asset)
        try store.recordMatch(NodeMatch(nodeId: asset.id.uuidString, source: "TheSource",
                                        sourceId: sourceId, method: .title), isVideo: true)
        return asset.id
    }

    @discardableResult
    private func matchedActor(_ name: String = "Vera Example") throws -> String {
        let p = EntityProfile(id: UUID().uuidString, entityType: "actor", displayName: name)
        try store.saveEntityProfile(p)
        try store.recordMatch(NodeMatch(nodeId: p.id, source: "TheSource",
                                        sourceId: "p-1", method: .name), isVideo: false)
        return p.id
    }

    // MARK: - 🚨 U7 — it has to survive the session that saw it

    func testU7AFlagPersistsAndIsReadableWithoutTheNetwork() throws {
        let id = try matchedVideo()
        try store.recordSourceState(nodeId: id.uuidString, source: "TheSource", sourceId: "s-1",
                                    isVideo: true, deletedAt: Date())

        // Reopen, as the audit would on a later launch.
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        let reopened = try LibraryStore(at: url)

        let stale = try reopened.staleMatches(isVideo: true)
        XCTAssertEqual(stale.count, 1)
        XCTAssertNotNil(stale.first?.deletedAt)
    }

    // MARK: - U8 — an as-of, not a bare flag

    /// ⚠️ "Deleted upstream" with no date cannot be aged, and a finding from
    /// three months ago is indistinguishable from one found this morning.
    func testU8TheFlagCarriesWhenItWasSeen() throws {
        let id = try matchedVideo()
        let seen = Date(timeIntervalSince1970: 1_700_000_000)
        try store.recordSourceState(nodeId: id.uuidString, source: "TheSource", sourceId: "s-1",
                                    isVideo: true, deletedAt: seen)

        let match = try XCTUnwrap(try store.staleMatches(isVideo: true).first)
        XCTAssertEqual(match.deletedAt?.timeIntervalSince1970 ?? 0,
                       seen.timeIntervalSince1970, accuracy: 1)
        XCTAssertNotNil(match.checkedAt, "and when we last had an answer at all")
    }

    /// ⭐ `checkedAt` is stamped even when nothing is wrong. Without it there is
    /// no way to tell "confirmed still there" from "never asked", and an audit
    /// that cannot distinguish those reports its own ignorance as a clean bill.
    func testAnOrdinaryCheckIsRecordedEvenWhenTheRecordIsFine() throws {
        let id = try matchedVideo()
        try store.recordSourceState(nodeId: id.uuidString, source: "TheSource", sourceId: "s-1", isVideo: true)

        XCTAssertTrue(try store.staleMatches(isVideo: true).isEmpty, "nothing to report")
        let match = try XCTUnwrap(try store.matches(forVideo: id).first)
        XCTAssertNotNil(match.checkedAt)
        XCTAssertNil(match.deletedAt)
    }

    // MARK: - 🚨 U13 — a flag can go away

    /// Upstream deletions are reversible: a moderator restores a record, a
    /// merge is undone. A flag that only accumulates leaves permanent false
    /// findings, and an audit that cannot be cleared is one people stop reading.
    func testU13AValidFetchClearsAnExistingFlag() throws {
        let id = try matchedVideo()
        try store.recordSourceState(nodeId: id.uuidString, source: "TheSource", sourceId: "s-1",
                                    isVideo: true, deletedAt: Date())
        XCTAssertEqual(try store.staleMatches(isVideo: true).count, 1)

        try store.recordSourceState(nodeId: id.uuidString, source: "TheSource", sourceId: "s-1", isVideo: true)

        XCTAssertTrue(try store.staleMatches(isVideo: true).isEmpty)
    }

    func testAMergeMarkAlsoClears() throws {
        let id = try matchedActor()
        try store.recordSourceState(nodeId: id, source: "TheSource", sourceId: "p-1",
                                    isVideo: false, mergedInto: "p-99")
        XCTAssertEqual(try store.staleMatches(isVideo: false).count, 1)

        try store.recordSourceState(nodeId: id, source: "TheSource", sourceId: "p-1", isVideo: false)
        XCTAssertTrue(try store.staleMatches(isVideo: false).isEmpty)
    }

    // MARK: - 🔴 A merge is not a deletion

    func testAMergedRecordCarriesWhereItWentAndIsNotMarkedDeleted() throws {
        let id = try matchedActor()
        try store.recordSourceState(nodeId: id, source: "TheSource", sourceId: "p-1",
                                    isVideo: false, mergedInto: "p-99")

        let match = try XCTUnwrap(try store.staleMatches(isVideo: false).first)
        XCTAssertEqual(match.mergedInto, "p-99")
        XCTAssertNil(match.deletedAt, "merged is a different state from deleted")
        XCTAssertTrue(match.isStale)
    }

    // MARK: - U6 — both types, and scoped correctly

    func testU6BothMatchTablesCarryTheState() throws {
        let video = try matchedVideo()
        let actor = try matchedActor()
        try store.recordSourceState(nodeId: video.uuidString, source: "TheSource", sourceId: "s-1",
                                    isVideo: true, deletedAt: Date())
        try store.recordSourceState(nodeId: actor, source: "TheSource", sourceId: "p-1",
                                    isVideo: false, deletedAt: Date())

        XCTAssertEqual(try store.staleMatches(isVideo: true).count, 1)
        XCTAssertEqual(try store.staleMatches(isVideo: false).count, 1)
    }

    /// ⚠️ Scoped to a source. A record gone from one provider says nothing
    /// about another, and marking both would report a deletion that no source
    /// ever asserted.
    func testMarkingOneSourceLeavesAnotherAlone() throws {
        let id = try matchedVideo()
        try store.recordMatch(NodeMatch(nodeId: id.uuidString, source: "Elsewhere",
                                        sourceId: "x-1", method: .title), isVideo: true)

        try store.recordSourceState(nodeId: id.uuidString, source: "TheSource", sourceId: "s-1",
                                    isVideo: true, deletedAt: Date())

        let stale = try store.staleMatches(isVideo: true)
        XCTAssertEqual(stale.map(\.source), ["TheSource"])
    }

    // MARK: - 🚨 Scoped to the record that was actually fetched

    /// The trap the `sourceId` parameter exists to close.
    ///
    /// Re-matching means fetching several candidates from the same source to
    /// compare them, and each carries its own state. Keyed on `(node, source)`
    /// alone, looking at a candidate the source had deleted would stamp
    /// "deleted" onto this node's existing, healthy match to a DIFFERENT
    /// record — a finding fabricated entirely by looking at something else.
    func testFetchingADifferentRecordCannotFlagThisNodesMatch() throws {
        _ = try matchedVideo("s-1")
        let id = try matchedVideo("s-KEEP")

        // The operator opens the re-match picker and a candidate is fetched.
        // The source says THAT record is gone. It is not the one we hold.
        try store.recordSourceState(.deleted, nodeId: id.uuidString, source: "TheSource",
                                    sourceId: "s-SOMETHING-ELSE", isVideo: true)

        XCTAssertTrue(try store.staleMatches(isVideo: true).isEmpty,
                      "a deleted candidate says nothing about the record we matched")
        let match = try XCTUnwrap(try store.matches(forVideo: id).first)
        XCTAssertNil(match.deletedAt)
        XCTAssertNil(match.checkedAt, "and it is not even evidence of a check")
    }

    /// ⚠️ The other half: the SAME record still flags normally. A scope that
    /// rejected everything would pass the test above and break the feature.
    func testFetchingTheMatchedRecordStillFlagsIt() throws {
        let id = try matchedVideo("s-KEEP")
        try store.recordSourceState(.deleted, nodeId: id.uuidString, source: "TheSource",
                                    sourceId: "s-KEEP", isVideo: true)

        XCTAssertEqual(try store.staleMatches(isVideo: true).count, 1)
    }

    // MARK: - Nothing is reported without evidence

    func testAFreshLibraryReportsNothing() throws {
        _ = try matchedVideo()
        XCTAssertTrue(try store.staleMatches(isVideo: true).isEmpty,
                      "never asked is not the same as gone")
    }

    /// 🚨 Recording state must not invent a match. A node the library never
    /// matched cannot become stale.
    func testMarkingAnUnmatchedNodeCreatesNothing() throws {
        try store.recordSourceState(nodeId: UUID().uuidString, source: "TheSource", sourceId: "s-1",
                                    isVideo: true, deletedAt: Date())
        XCTAssertTrue(try store.staleMatches(isVideo: true).isEmpty)
    }

    // MARK: - 🚨 The third answer, measured on the device 2026-08-11

    /// 301 matches checked, 21 returned no record at all, and ZERO carried a
    /// `deleted` flag. The source does not tombstone a removed performer — it
    /// stops resolving the id. Without this state the audit could never report
    /// anything, however correct the rest of it was.
    func testAnUnresolvedIdIsRecordedAndReported() throws {
        let id = try matchedActor()
        try store.recordSourceState(.unresolved, nodeId: id, source: "TheSource",
                                    sourceId: "p-1", isVideo: false)

        let match = try XCTUnwrap(try store.staleMatches(isVideo: false).first)
        XCTAssertNotNil(match.unresolvedAt)
        XCTAssertTrue(match.isStale)
    }

    /// 🚨 Not recorded as a deletion. The source said "no record under that
    /// id", which is ambiguous between removed, merged away with the old id
    /// retired, and an id that was wrong when we stored it.
    func testAnUnresolvedIdIsNotADeletion() throws {
        let id = try matchedActor()
        try store.recordSourceState(.unresolved, nodeId: id, source: "TheSource",
                                    sourceId: "p-1", isVideo: false)

        let match = try XCTUnwrap(try store.staleMatches(isVideo: false).first)
        XCTAssertNil(match.deletedAt, "we were not told it was deleted")
        XCTAssertNil(match.mergedInto)

        let finding = try XCTUnwrap(try store.staleMatchFindings().first)
        XCTAssertEqual(finding.kind, .unresolved)
    }

    /// ⭐ And it clears like any other mark when the id resolves again — an id
    /// can come back, and a flag that only accumulates leaves false findings.
    func testAResolvingFetchClearsIt() throws {
        let id = try matchedActor()
        try store.recordSourceState(.unresolved, nodeId: id, source: "TheSource",
                                    sourceId: "p-1", isVideo: false)
        XCTAssertEqual(try store.staleMatches(isVideo: false).count, 1)

        try store.recordSourceState(.present, nodeId: id, source: "TheSource",
                                    sourceId: "p-1", isVideo: false)

        XCTAssertTrue(try store.staleMatches(isVideo: false).isEmpty)
    }

    /// ⚠️ U2 still holds. An unreachable source is not an unresolved id — the
    /// caller records nothing at all, and there is no value here to say
    /// otherwise with.
    func testAnUnreachableSourceStillRecordsNothing() throws {
        _ = try matchedActor()
        XCTAssertTrue(try store.staleMatches(isVideo: false).isEmpty)
    }

    /// The headline names it in the source's terms, not as a verdict.
    func testTheHeadlineSaysItDoesNotResolve() throws {
        let id = try matchedActor()
        try store.recordSourceState(.unresolved, nodeId: id, source: "TheSource",
                                    sourceId: "p-1", isVideo: false)

        let line = StaleMatchAudit.headline(try store.staleMatchFindings())
        XCTAssertTrue(line.contains("no longer resolve"), line)
        XCTAssertFalse(line.contains("no longer exist"), "that is a different claim")
    }
}
