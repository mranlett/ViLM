// NamelessNodeRepairTests.swift
// Recovering identity for rows already damaged on the device (#the 2026-08-10 report).
//
// 🚨 The safety properties matter more than the happy path here. This writes to
// identity columns across a real library, and a repair that guesses is worse
// than one that reports and stops.

import XCTest
import GRDB
@testable import LibraryCore

final class NamelessNodeRepairTests: XCTestCase {

    private var url: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Repair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store = try LibraryStore(at: url)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: url)
    }

    /// A row with an id and nothing else, credited by one video that names it.
    @discardableResult
    private func damagedNode(creditedAs names: [String],
                             on videoActors: [String]? = nil) throws -> String {
        let uid = UUID().uuidString
        try store.saveEntityProfile(EntityProfile(id: uid))
        let asset = Asset(relativePath: "\(UUID()).mp4", fileName: "v.mp4",
                          tags: (videoActors ?? names).map { "actor:\($0)" })
        try store.insertAsset(asset)
        try store.linkPerformer(uid, toVideo: asset.id)
        return uid
    }

    // MARK: - Recovery

    func testTheNameIsRecoveredFromTheVideoThatCreditsIt() throws {
        let uid = try damagedNode(creditedAs: ["Tom Example"])

        let found = try store.namelessNodes()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.recoveredName, "Tom Example")
        XCTAssertEqual(found.first?.videoCount, 1)
    }

    func testRepairingWritesBothIdentityColumns() throws {
        let uid = try damagedNode(creditedAs: ["Tom Example"])

        XCTAssertEqual(try store.repairNamelessNodes(), 1)

        let fixed = try XCTUnwrap(try store.fetchEntityProfile(for: uid))
        XCTAssertEqual(fixed.displayName, "Tom Example")
        XCTAssertEqual(fixed.entityType, "actor")
        XCTAssertEqual(fixed.name, "Tom Example", "no longer renders as its uid")
        XCTAssertEqual(try store.fetchEntityProfile(named: "Tom Example", type: "actor")?.id, uid,
                       "and is findable by name, which is what stops a duplicate")
    }

    /// ⭐ Only the identity columns. A row the operator had already matched by
    /// hand keeps its source link and everything else.
    func testEverythingElseOnTheRowIsUntouched() throws {
        let uid = UUID().uuidString
        var damaged = EntityProfile(id: uid)
        damaged.bio = "typed by hand"
        damaged.enrichmentSourceId = "p-99"
        damaged.rating = 4
        try store.saveEntityProfile(damaged)
        let asset = Asset(relativePath: "\(UUID()).mp4", fileName: "v.mp4",
                          tags: ["actor:Tom Example"])
        try store.insertAsset(asset)
        try store.linkPerformer(uid, toVideo: asset.id)

        try store.repairNamelessNodes()

        let fixed = try XCTUnwrap(try store.fetchEntityProfile(for: uid))
        XCTAssertEqual(fixed.bio, "typed by hand")
        XCTAssertEqual(fixed.enrichmentSourceId, "p-99")
        XCTAssertEqual(fixed.rating, 4)
    }

    // MARK: - 🚨 What it refuses to do

    /// Two names on the crediting videos is not a name. Reported, not guessed.
    func testANodeWithDisagreeingNamesIsReportedAndLeftAlone() throws {
        let uid = UUID().uuidString
        try store.saveEntityProfile(EntityProfile(id: uid))
        for name in ["Tom Example", "Thomas Example"] {
            let asset = Asset(relativePath: "\(UUID()).mp4", fileName: "v.mp4",
                              tags: ["actor:\(name)"])
            try store.insertAsset(asset)
            try store.linkPerformer(uid, toVideo: asset.id)
        }

        let found = try XCTUnwrap(try store.namelessNodes().first)
        XCTAssertNil(found.recoveredName)
        XCTAssertFalse(found.isRepairable)
        XCTAssertEqual(try store.repairNamelessNodes(), 0)
        XCTAssertNil(try store.fetchEntityProfile(for: uid)?.displayName)
    }

    /// ⚠️ A name a healthy profile already owns is refused. Repairing onto it
    /// would turn one broken row into two rows for one person — the very
    /// duplicate this whole area keeps producing.
    func testANameAlreadyOwnedByAHealthyProfileIsRefused() throws {
        var existing = try store.newEntityProfile(named: "Tom Example", type: "actor")
        existing.bio = "the real one"
        try store.saveEntityProfile(existing)

        let uid = UUID().uuidString
        try store.saveEntityProfile(EntityProfile(id: uid))
        let asset = Asset(relativePath: "\(UUID()).mp4", fileName: "v.mp4",
                          tags: ["actor:Tom Example"])
        try store.insertAsset(asset)
        try store.linkPerformer(uid, toVideo: asset.id)

        XCTAssertEqual(try store.repairNamelessNodes(), 0)
        XCTAssertNil(try store.fetchEntityProfile(for: uid)?.displayName)
        XCTAssertEqual(try store.fetchEntityProfile(named: "Tom Example", type: "actor")?.bio,
                       "the real one", "the healthy row is untouched")
    }

    /// A damaged row with no edge has nothing to recover from. Listed so it can
    /// be dealt with by hand, never invented.
    func testANodeWithNoCreditingVideoIsReportedAsUnrepairable() throws {
        let uid = UUID().uuidString
        try store.saveEntityProfile(EntityProfile(id: uid))

        let found = try XCTUnwrap(try store.namelessNodes().first)
        XCTAssertNil(found.recoveredName)
        XCTAssertEqual(found.videoCount, 0)
        XCTAssertEqual(try store.repairNamelessNodes(), 0)
    }

    /// ⭐ Healthy rows are not candidates at all — the sweep must not touch a
    /// library that has nothing wrong with it.
    func testAHealthyLibraryHasNothingToRepair() throws {
        let profile = try store.newEntityProfile(named: "Ann Example", type: "actor")
        try store.saveEntityProfile(profile)

        XCTAssertTrue(try store.namelessNodes().isEmpty)
        XCTAssertEqual(try store.repairNamelessNodes(), 0)
    }

    /// ⚠️ Idempotent. Running it twice must not re-write or re-count.
    func testRunningItTwiceChangesNothingTheSecondTime() throws {
        try damagedNode(creditedAs: ["Tom Example"])

        XCTAssertEqual(try store.repairNamelessNodes(), 1)
        XCTAssertEqual(try store.repairNamelessNodes(), 0)
        XCTAssertTrue(try store.namelessNodes().isEmpty)
    }
}
