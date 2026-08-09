// SourceGapReadOnlyTests.swift
// 🚨 The gap feature never writes to the library (#43, W8).
//
// D3: the app says "these exist and you do not have them" and stops. No
// fetching, no acquiring, no links followed automatically.
//
// ⚠️ Asserted against the DATABASE rather than by reading the code, because
// "nothing here writes" is a claim that decays. The reads this feature needs
// are the exact shape of the reads a future convenience write would piggyback
// on — "while we are here, mark it seen" — and a test that watches the whole
// catalogue is what makes that show up as a failure rather than a nicety.

import XCTest
import GRDB
@testable import LibraryCore

final class SourceGapReadOnlyTests: XCTestCase {

    private var url: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GapRO-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store = try LibraryStore(at: url)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: url)
    }

    /// A row count for every table the feature touches or could plausibly
    /// touch, so a write ANYWHERE shows up rather than only where expected.
    private func census() throws -> [String: Int] {
        try store.dbQueue.read { db in
            var out: [String: Int] = [:]
            let tables = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                 WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                   AND name NOT LIKE 'grdb_%'
                """)
            for table in tables {
                out[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(table)\"") ?? 0
            }
            return out
        }
    }

    private func seed() throws -> EntityProfile {
        var profile = EntityProfile(id: UUID().uuidString, entityType: "actor",
                                    displayName: "Vera Example")
        profile.enrichmentSource = "TheSource"
        profile.enrichmentSourceId = "p-1"
        profile.rating = 4
        try store.saveEntityProfile(profile)

        let asset = Asset(relativePath: "\(UUID()).mp4", fileName: "v.mp4",
                          tags: ["actor:Vera Example"])
        try store.insertAsset(asset)
        try store.recordMatch(NodeMatch(nodeId: asset.id.uuidString, source: "TheSource",
                                        sourceId: "s-held", method: .title,
                                        matchedAt: Date()), isVideo: true)
        return profile
    }

    // MARK: - 🚨 W8

    func testTheGapReadsChangeNothingInTheDatabase() throws {
        _ = try seed()
        let before = try census()

        // Everything the feature does against the library.
        let matches = try store.videoMatches(source: "TheSource")
        let footprint = try store.videoIdentityFootprint(forActor: "Vera Example",
                                                         source: "TheSource")
        _ = SourceGapAudit.report(
            sourceScenes: [SourceGap(sourceId: "s-held", title: "Held"),
                           SourceGap(sourceId: "s-new", title: "Missing")],
            source: "TheSource",
            localMatches: matches,
            localVideos: footprint.total,
            identifiedLocalVideos: footprint.identified,
            truncated: false)

        XCTAssertEqual(try census(), before, "not one row anywhere")
    }

    /// ⚠️ And specifically not `rating`. The gap feature reads a performer to
    /// ask about them; the same separation that keeps the game away from it
    /// applies here.
    func testAskingAboutAPerformerLeavesTheirRatingAlone() throws {
        let profile = try seed()
        _ = try store.videoIdentityFootprint(forActor: profile.name, source: "TheSource")

        XCTAssertEqual(try store.fetchEntityProfile(for: profile.id)?.rating, 4)
    }

    // MARK: - The reads themselves are correct

    func testTheFootprintCountsBothRepresentations() throws {
        let profile = try seed()

        // A second video, credited by EDGE rather than by tag string.
        let byEdge = Asset(relativePath: "\(UUID()).mp4", fileName: "e.mp4", tags: [])
        try store.insertAsset(byEdge)
        try store.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO video_performer (video_id, performer_id) VALUES (?, ?)",
                           arguments: [byEdge.id.uuidString, profile.id])
        }

        let footprint = try store.videoIdentityFootprint(forActor: "Vera Example",
                                                         source: "TheSource")
        XCTAssertEqual(footprint.total, 2, "a video connected either way still counts")
        XCTAssertEqual(footprint.identified, 1)
    }

    /// 🚨 Scoped by source at the SQL layer, so another provider's ids cannot
    /// reach the comparison even by a caller's mistake.
    func testVideoMatchesAreScopedToOneSource() throws {
        let profile = try seed()
        let other = Asset(relativePath: "\(UUID()).mp4", fileName: "o.mp4",
                          tags: ["actor:\(profile.name)"])
        try store.insertAsset(other)
        try store.recordMatch(NodeMatch(nodeId: other.id.uuidString, source: "Elsewhere",
                                        sourceId: "x-1", method: .title, matchedAt: Date()),
                              isVideo: true)

        XCTAssertEqual(try store.videoMatches(source: "TheSource").map(\.sourceId), ["s-held"])
        XCTAssertEqual(try store.videoMatches(source: "Elsewhere").map(\.sourceId), ["x-1"])
    }

    /// ⚠️ A performer whose name is a substring of another's must not borrow
    /// their videos — the reason the string half matches exactly rather than
    /// with LIKE.
    func testASubstringNameDoesNotBorrowVideos() throws {
        _ = try seed()
        let other = Asset(relativePath: "\(UUID()).mp4", fileName: "s.mp4",
                          tags: ["actor:Vera Example Two"])
        try store.insertAsset(other)

        XCTAssertEqual(try store.videoIdentityFootprint(forActor: "Vera Example",
                                                        source: "TheSource").total, 1)
    }
}
