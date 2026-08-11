// SameIdentityAuditTests.swift
// Two profiles, one source identity (device report, 2026-08-11).
//
// 🚨 The rows this exists for cannot be reached any other way. The
// `entityIdForWriting` defect left shadow profiles with an id, a photo and a
// source id but NO name and NO videos — invisible to the actor grid, unfindable
// by name, and invisible to *Duplicate Performers*, which compares names. Their
// source id is the only handle on them that exists.

import XCTest
import GRDB
@testable import LibraryCore

final class SameIdentityAuditTests: XCTestCase {

    private var url: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SameId-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store = try LibraryStore(at: url)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    private func actor(_ name: String?, sourceId: String, photo: String? = nil,
                       bio: String? = nil) throws -> EntityProfile {
        var p = EntityProfile(id: UUID().uuidString,
                              entityType: name == nil ? nil : "actor",
                              displayName: name)
        p.enrichmentSourceId = sourceId
        p.enrichmentSource = "TheSource"
        p.photoUrl = photo
        p.bio = bio
        try store.saveEntityProfile(p)
        return p
    }

    @discardableResult
    private func video(crediting name: String) throws -> Asset {
        let a = Asset(relativePath: "\(UUID()).mp4", fileName: "v.mp4",
                      tags: ["actor:\(name)"])
        try store.insertAsset(a)
        return a
    }

    // MARK: - Finding them

    func testTwoProfilesSharingASourceIdAreReported() throws {
        try actor("Ann Example", sourceId: "p-1")
        try actor("Ann Exampel", sourceId: "p-1")

        let found = try store.sameIdentityFindings()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.members.count, 2)
    }

    /// 🚨 The shadow row — the case nothing else can see.
    func testANamelessShadowIsFoundThroughItsSourceId() throws {
        let real = try actor("Ann Example", sourceId: "p-1")
        try actor(nil, sourceId: "p-1", photo: "https://example.test/a.jpg")

        let found = try XCTUnwrap(try store.sameIdentityFindings().first)
        XCTAssertTrue(found.isUnambiguous, "only one member has a name")
        XCTAssertEqual(found.recommendedSurvivor?.id, real.id,
                       "a named row always outranks a nameless one")
        XCTAssertTrue(found.members.last?.isNameless ?? false)
    }

    /// ⭐ A named row wins even when the nameless one has more of everything
    /// else — an unusable identity is not a candidate.
    func testANamedRowOutranksANamelessOneWithMoreVideos() throws {
        try video(crediting: "Ann Example")
        let named = try actor("Ann Example", sourceId: "p-1")
        try actor(nil, sourceId: "p-1", photo: "p.jpg", bio: "a fuller record")

        let found = try XCTUnwrap(try store.sameIdentityFindings().first)
        XCTAssertEqual(found.recommendedSurvivor?.id, named.id)
    }

    // MARK: - What it must NOT report

    func testAProfileWithNoSourceIdIsNotADuplicate() throws {
        var a = EntityProfile(id: UUID().uuidString, entityType: "actor", displayName: "Ann Example")
        var b = EntityProfile(id: UUID().uuidString, entityType: "actor", displayName: "Bea Example")
        a.enrichmentSourceId = nil; b.enrichmentSourceId = ""
        try store.saveEntityProfile(a); try store.saveEntityProfile(b)

        XCTAssertTrue(try store.sameIdentityFindings().isEmpty)
    }

    func testOneProfilePerSourceIdIsClean() throws {
        try actor("Ann Example", sourceId: "p-1")
        try actor("Bea Example", sourceId: "p-2")

        XCTAssertTrue(try store.sameIdentityFindings().isEmpty)
        XCTAssertTrue(SameIdentityAudit.headline([]).contains("No two profiles"))
    }

    /// ⚠️ An actor and a studio could carry the same opaque id from different
    /// endpoints. Merging across kinds is far worse than missing a duplicate.
    func testTheSameIdOnDifferentKindsIsNotADuplicate() throws {
        try actor("Ann Example", sourceId: "shared")
        var studio = EntityProfile(id: UUID().uuidString, entityType: "studio",
                                   displayName: "Coast Line")
        studio.enrichmentSourceId = "shared"
        try store.saveEntityProfile(studio)

        XCTAssertTrue(try store.sameIdentityFindings().isEmpty)
    }

    // MARK: - Merging

    func testMergingMovesTheVideosAndRemovesTheLoser() throws {
        let keep = try actor("Ann Example", sourceId: "p-1")
        let lose = try actor("Ann Exampel", sourceId: "p-1")
        let asset = try video(crediting: "Ann Exampel")
        try store.linkPerformer(lose.id, toVideo: asset.id)

        try store.mergeSameIdentity(losing: lose.id, into: keep.id)

        XCTAssertNil(try store.fetchEntityProfile(for: lose.id), "the loser is gone")
        let edges = try store.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT performer_id FROM video_performer")
        }
        XCTAssertEqual(edges, [keep.id], "its videos moved rather than vanishing")
    }

    /// ⭐ The loser's name survives as an alias, so a later import spelling it
    /// the old way still resolves to the right person.
    func testTheLosersNameBecomesAnAlias() throws {
        let keep = try actor("Ann Example", sourceId: "p-1")
        let lose = try actor("Ann Exampel", sourceId: "p-1")

        try store.mergeSameIdentity(losing: lose.id, into: keep.id)

        let merged = try XCTUnwrap(try store.fetchEntityProfile(for: keep.id))
        XCTAssertTrue(merged.akas.contains("Ann Exampel"))
    }

    /// ⚠️ A uid is not an alias anybody will search for.
    func testANamelessLoserContributesNoAlias() throws {
        let keep = try actor("Ann Example", sourceId: "p-1")
        let lose = try actor(nil, sourceId: "p-1", photo: "shadow.jpg")

        try store.mergeSameIdentity(losing: lose.id, into: keep.id)

        let merged = try XCTUnwrap(try store.fetchEntityProfile(for: keep.id))
        XCTAssertTrue(merged.akas.isEmpty)
        XCTAssertEqual(merged.name, "Ann Example")
    }

    /// The survivor keeps what it had, and gains only what it lacked.
    func testTheSurvivorKeepsItsOwnValuesAndFillsGaps() throws {
        let keep = try actor("Ann Example", sourceId: "p-1", bio: "the curated bio")
        let lose = try actor(nil, sourceId: "p-1", photo: "https://example.test/shadow.jpg")

        try store.mergeSameIdentity(losing: lose.id, into: keep.id)

        let merged = try XCTUnwrap(try store.fetchEntityProfile(for: keep.id))
        XCTAssertEqual(merged.bio, "the curated bio", "its own value wins")
        XCTAssertEqual(merged.photoUrl, "https://example.test/shadow.jpg",
                       "and the gap is filled from the row being absorbed")
    }

    /// ⚠️ Idempotent, and it clears the finding.
    func testMergingClearsTheFindingAndRunsOnce() throws {
        let keep = try actor("Ann Example", sourceId: "p-1")
        let lose = try actor(nil, sourceId: "p-1")

        try store.mergeSameIdentity(losing: lose.id, into: keep.id)
        XCTAssertTrue(try store.sameIdentityFindings().isEmpty)

        try store.mergeSameIdentity(losing: lose.id, into: keep.id)
        XCTAssertNotNil(try store.fetchEntityProfile(for: keep.id), "a second run is a no-op")
    }

    /// 🚨 Merging a node into itself must not delete it.
    func testMergingAProfileIntoItselfIsRefused() throws {
        let keep = try actor("Ann Example", sourceId: "p-1")

        try store.mergeSameIdentity(losing: keep.id, into: keep.id)

        XCTAssertNotNil(try store.fetchEntityProfile(for: keep.id))
    }

    // MARK: - The library afterwards

    /// ⭐ The invariant this audit exists to restore.
    func testTheLibraryHoldsTheInvariantAfterMerging() throws {
        let keep = try actor("Ann Example", sourceId: "p-1")
        let lose = try actor(nil, sourceId: "p-1")
        let asset = try video(crediting: "Ann Example")
        try store.linkPerformer(keep.id, toVideo: asset.id)
        try store.confirmEntityMatch(keep.id, source: "TheSource",
                                     sourceId: "p-1", method: .name)

        try store.mergeSameIdentity(losing: lose.id, into: keep.id)

        try assertLibraryInvariants(store)
    }
}
