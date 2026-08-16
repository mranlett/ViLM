// FilenameEdgeProvenanceTests.swift
// #77 — a name read out of a filename says so.
//
// ⚠️ All names invented. This repository is public.

import XCTest
import GRDB
@testable import LibraryCore

final class FilenameEdgeProvenanceTests: XCTestCase {

    private var libraryURL: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        libraryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FnEdges-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        store = try LibraryStore(at: libraryURL)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: libraryURL)
    }

    @discardableResult
    private func video() throws -> UUID {
        let asset = Asset(relativePath: "\(UUID()).mp4", fileName: "a.mp4")
        try store.insertAsset(asset)
        return asset.id
    }

    private func profile(_ id: String) throws {
        try store.saveEntityProfile(EntityProfile(id: id))
    }

    private func provenance(_ table: String, _ column: String, video: UUID) throws -> String? {
        try store.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT source FROM \(table) WHERE video_id = ?",
                                arguments: [video.uuidString])
        }
    }

    // MARK: - 🚨 The origin is recorded

    func testAPerformerReadFromAFilenameSaysSo() throws {
        try profile("actor:Alice Example")
        let v = try video()

        let result = try store.recordFilenameDerived(["actor:Alice Example"], forVideo: v)

        XCTAssertEqual(result.performers, 1)
        XCTAssertEqual(try provenance("video_performer", "source", video: v),
                       EdgeProvenance.filename.rawValue,
                       "not `inferred` — the origin IS known here")
    }

    func testAStudioAndATagAlsoCarryTheirOrigin() throws {
        try profile("studio:Example Pictures")
        try store.saveTagRecord(TagRecord(displayName: "Outdoors", kind: nil))
        let v = try video()

        let result = try store.recordFilenameDerived(
            ["studio:Example Pictures", "tag:Outdoors"], forVideo: v)

        XCTAssertEqual(result.studios, 1)
        XCTAssertEqual(result.tags, 1)
        XCTAssertEqual(try provenance("video_studio", "source", video: v),
                       EdgeProvenance.filename.rawValue)
        XCTAssertEqual(try provenance("video_tag", "source", video: v),
                       EdgeProvenance.filename.rawValue)
    }

    /// 🚨 A tag the vocabulary has never seen is reported, not linked.
    ///
    /// ⚠️ This test was written asserting the OPPOSITE — that a tag needs no
    /// prior record because it is keyed by its folded identity rather than by a
    /// profile. That is wrong: `video_tag` has a foreign key to the tag record,
    /// and the code written from that belief failed against a real database
    /// with a constraint error. Kept in this shape as the record of it, because
    /// the belief is a reasonable one to hold twice.
    func testATagWithNoRecordIsReportedRatherThanLinked() throws {
        let v = try video()
        let result = try store.recordFilenameDerived(["tag:Never Seen"], forVideo: v)
        XCTAssertEqual(result.tags, 0)
        XCTAssertEqual(result.unresolved, ["tag:Never Seen"])
    }

    // MARK: - 🚨 A name with nowhere to point is COUNTED, not swallowed

    func testANameWithNoProfileIsReportedRatherThanDropped() throws {
        let v = try video()

        let result = try store.recordFilenameDerived(
            ["actor:Nobody Here", "studio:No Such House"], forVideo: v)

        XCTAssertEqual(result.performers, 0)
        XCTAssertEqual(result.studios, 0)
        XCTAssertEqual(result.unresolved, ["actor:Nobody Here", "studio:No Such House"],
                       "the name is on the video but not in the graph, and that is a finding")
    }

    // MARK: - 🚨 A filename must never outrank something better

    /// The weakest origin there is, applied to the one edge kind that is an
    /// assignment rather than an addition. Downgrading here is exactly the
    /// laundering the bulk connect was doing.
    func testAFilenameDoesNotDowngradeAConfirmedStudio() throws {
        try profile("studio:Example Pictures")
        let v = try video()
        try store.setStudio("studio:Example Pictures", forVideo: v, source: .download)

        try store.recordFilenameDerived(["studio:Example Pictures"], forVideo: v)

        XCTAssertEqual(try provenance("video_studio", "source", video: v),
                       EdgeProvenance.download.rawValue,
                       "a confirmed studio is not rewritten by a filename guess")
    }

    /// ⚠️ The other direction, asserted with it. Refusing to downgrade must not
    /// become refusing to UPGRADE — a test of the first alone would pass on
    /// code that had frozen the field entirely.
    func testAConfirmedOriginStillUpgradesAFilenameOne() throws {
        try profile("studio:Example Pictures")
        let v = try video()
        try store.setStudio("studio:Example Pictures", forVideo: v, source: .filename)

        try store.setStudio("studio:Example Pictures", forVideo: v, source: .download)

        XCTAssertEqual(try provenance("video_studio", "source", video: v),
                       EdgeProvenance.download.rawValue)
    }

    /// A CHANGED studio always carries its own origin — the previous one
    /// described a different fact and has no claim on the new assertion.
    func testAChangedStudioTakesTheNewOrigin() throws {
        try profile("studio:Example Pictures"); try profile("studio:Other Pictures")
        let v = try video()
        try store.setStudio("studio:Other Pictures", forVideo: v, source: .download)

        try store.setStudio("studio:Example Pictures", forVideo: v, source: .filename)

        XCTAssertEqual(try provenance("video_studio", "source", video: v),
                       EdgeProvenance.filename.rawValue)
    }

    // MARK: - Shape

    func testAnUnrecognisedPrefixIsIgnoredRatherThanGuessedAt() throws {
        let v = try video()
        let result = try store.recordFilenameDerived(
            ["something:Odd", "no-prefix-at-all", "actor:"], forVideo: v)
        XCTAssertEqual(result.total, 0)
        XCTAssertTrue(result.unresolved.isEmpty, "not unresolved — not a name at all")
    }
}
