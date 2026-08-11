// ResolvingProfileLookupTests.swift
// Looking a profile up by an id that might be a name form (device, 2026-08-11).
//
// 🚨 The bug this closes made EVERY actor's profile page and edit form blank on
// a re-keyed library, and it was invisible from the grid.
//
// `ProfileGraphHeaderView` derives its id from the SELECTION, so before a
// profile is loaded it has only `actor:Name` to offer. `fetchEntityProfile(for:)`
// is a primary-key lookup with no resolution, so on a re-keyed library that
// found nothing — and the page therefore never loaded the profile that would
// have supplied the real id. It needed the profile in order to find the profile.
//
// ⚠️ Self-perpetuating and silent: the actor grid and Library Statistics read a
// name-keyed in-memory index and looked perfectly healthy throughout, which is
// why this was mistaken for a filter problem when first reported on 2026-08-09.
//
// ⭐ The operator's own observation is what pinned it: after a match the page
// rendered, then went blank on returning to it IN THE SAME SESSION. Same data,
// same library — so it could only be the load path.

import XCTest
import GRDB
@testable import LibraryCore

final class ResolvingProfileLookupTests: XCTestCase {

    private var url: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Resolve-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store = try LibraryStore(at: url)
        try markRekeyed()
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: url)
    }

    /// 🚨 The condition the whole bug depends on. On a fresh library an id IS
    /// `actor:Name`, so the broken lookup succeeds and the defect is invisible.
    private func markRekeyed() throws {
        let uid = UUID().uuidString
        try store.saveEntityProfile(EntityProfile(id: uid, entityType: "actor",
                                                  displayName: "Sentinel Example"))
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE entity_profiles SET uid = id WHERE id = ?",
                           arguments: [uid])
        }
    }

    @discardableResult
    private func actor(_ name: String) throws -> EntityProfile {
        var p = try store.newEntityProfile(named: name, type: "actor")
        p.photoUrl = "https://example.test/\(name).jpg"
        p.bio = "a biography"
        try store.saveEntityProfile(p)
        return p
    }

    // MARK: - 🚨 The failure, and the fix

    /// What the profile page asks on first load.
    func testANameFormIdResolvesToTheStoredProfile() throws {
        let stored = try actor("Ann Example")
        XCTAssertNotEqual(stored.id, "actor:Ann Example", "the fixture must be uid-keyed")

        XCTAssertNil(try store.fetchEntityProfile(for: "actor:Ann Example"),
                     "the plain key lookup still finds nothing — that is the trap")

        let resolved = try XCTUnwrap(try store.fetchEntityProfileResolving("actor:Ann Example"))
        XCTAssertEqual(resolved.id, stored.id)
        XCTAssertEqual(resolved.bio, "a biography", "and it carries the real data")
    }

    /// ⭐ A stored uid still resolves directly — key first, so an exact match is
    /// never passed over in favour of a name match.
    func testAStoredIdStillResolvesDirectly() throws {
        let stored = try actor("Ann Example")
        XCTAssertEqual(try store.fetchEntityProfileResolving(stored.id)?.id, stored.id)
    }

    /// ⚠️ On a library that was never re-keyed the name form IS the key, and
    /// the direct lookup must still be what answers.
    func testALegacyKeyedLibraryIsUnaffected() throws {
        let legacyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: legacyURL) }
        let legacy = try LibraryStore(at: legacyURL)

        let p = try legacy.newEntityProfile(named: "Ann Example", type: "actor")
        try legacy.saveEntityProfile(p)
        XCTAssertEqual(p.id, "actor:Ann Example", "not re-keyed")

        XCTAssertEqual(try legacy.fetchEntityProfileResolving("actor:Ann Example")?.id, p.id)
    }

    // MARK: - What it must not do

    /// A name nothing is filed under stays nil rather than returning someone.
    func testAnUnknownNameFormResolvesToNothing() throws {
        try actor("Ann Example")
        XCTAssertNil(try store.fetchEntityProfileResolving("actor:Nobody Here"))
    }

    /// ⚠️ Kind-scoped. A studio and an actor may share a name, and resolving
    /// across kinds would show the wrong record on the page.
    func testItDoesNotCrossKinds() throws {
        try actor("Ann Example")
        XCTAssertNil(try store.fetchEntityProfileResolving("studio:Ann Example"))
    }

    /// An id that is neither a stored key nor a parseable name form.
    func testAnUnparseableIdResolvesToNothing() throws {
        XCTAssertNil(try store.fetchEntityProfileResolving("not-an-id"))
        XCTAssertNil(try store.fetchEntityProfileResolving(""))
    }
}
