// IdentityUpgradeRemainingTests.swift
// The signal that decides whether the Identity Upgrade row appears at all.
//
// ⚠️ All names invented. This repository is public.

import XCTest
import GRDB
@testable import LibraryCore

final class IdentityUpgradeRemainingTests: XCTestCase {

    private var libraryURL: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        libraryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("IdRemain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        store = try LibraryStore(at: libraryURL)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: libraryURL)
    }

    /// An upgraded library reports nothing to do, which is what hides the row.
    func testAnUpgradedLibraryHasNothingRemaining() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Alice Example"))
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE entity_profiles SET uid = id")
        }
        XCTAssertEqual(try store.identityUpgradeRemaining(), 0)
    }

    /// 🚨 A library that still carries name-shaped ids reports them, so the row
    /// comes back. This is the case that made hiding the tool safe rather than
    /// deleting it: nothing else in the app detects this state.
    func testANameKeyedLibraryReportsWhatIsLeft() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Alice Example"))
        try store.saveEntityProfile(EntityProfile(id: "studio:Example Pictures"))
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE entity_profiles SET uid = ?", arguments: [UUID().uuidString])
        }
        XCTAssertEqual(try store.identityUpgradeRemaining(), 2)
    }

    /// ⚠️ A profile with no uid is not counted. The engine's own statement is
    /// `WHERE uid IS NOT NULL`, and counting rows it would not touch would put
    /// a row on the Settings screen that runs and then reports zero — exactly
    /// the dead control this signal exists to remove.
    func testAProfileWithNoUidIsNotCounted() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Alice Example"))
        XCTAssertEqual(try store.identityUpgradeRemaining(), 0)
    }
}
