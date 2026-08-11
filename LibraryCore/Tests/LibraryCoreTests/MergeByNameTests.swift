// MergeByNameTests.swift
// Merging duplicate performers (device report, 2026-08-10).
//
// 🚨 `renameTagGlobally` matches `actor:Name` strings in `Asset.tags`. Before
// the v28 re-key a profile id WAS that string, so *Duplicate Performers* could
// pass ids and it worked. Afterwards an id became a uid, the rename matched
// nothing, and the merge quietly did nothing — while the caller discarded the
// outcome and counted it a success.
//
// ⭐ These pin the contract the screen depends on, because the screen itself is
// a view and cannot assert it.
//
// 🚨 The fixture names are INVENTED, following the "… Example" convention used
// throughout these tests. The defect was found from a screenshot of the real
// screen, and the first draft of this file copied the performer's actual name
// out of it — a D9 leak into a public repo, caught before it was pushed only
// because the push was held. Never transcribe a name out of the library, a
// screenshot or a bug report into a fixture.

import XCTest
import GRDB
@testable import LibraryCore

final class MergeByNameTests: XCTestCase {

    private var url: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store = try LibraryStore(at: url)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: url)
    }

    /// 🚨 Puts the library in the state the device is in: re-keyed, so
    /// `newEntityProfile` mints uids. Without this the ids ARE `actor:Name`
    /// and the defect cannot reproduce — which is precisely why it survived
    /// the re-key unnoticed.
    private func markRekeyed() throws {
        let uid = UUID().uuidString
        try store.saveEntityProfile(EntityProfile(id: uid, entityType: "actor",
                                                  displayName: "Sentinel"))
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE entity_profiles SET uid = id WHERE id = ?",
                           arguments: [uid])
        }
    }

    /// Two profiles for one person, and a video filed under the losing name.
    private func twoProfiles() throws -> (losing: EntityProfile, surviving: EntityProfile) {
        try markRekeyed()
        let losing = try store.newEntityProfile(named: "Nora", type: "actor")
        var surviving = try store.newEntityProfile(named: "Nora Example", type: "actor")
        surviving.akas = ["Nora"]
        try store.saveEntityProfile(losing)
        try store.saveEntityProfile(surviving)

        let asset = Asset(relativePath: "\(UUID()).mp4", fileName: "v.mp4",
                          tags: ["actor:Nora"])
        try store.insertAsset(asset)
        return (losing, surviving)
    }

    // MARK: - 🚨 The defect

    /// Passing profile IDS — what the screen did — matches nothing and reports
    /// it. The screen ignored the report, which is why it looked like it worked.
    func testMergingByProfileIdChangesNothingAndSaysSo() throws {
        let (losing, surviving) = try twoProfiles()

        let outcome = try store.renameTagGlobally(oldTag: losing.id, newTag: surviving.id)

        XCTAssertFalse(outcome.changedAnything,
                       "a uid matches no tag — and the outcome must admit it")
        XCTAssertEqual(outcome.videosChanged, 0)
        XCTAssertEqual(try store.fetchAllAssets().first?.tags, ["actor:Nora"],
                       "the video is untouched, so the duplicate survives")
    }

    // MARK: - ⭐ The contract the screen now uses

    func testMergingByTagStringMovesTheVideo() throws {
        _ = try twoProfiles()

        let outcome = try store.renameTagGlobally(oldTag: "actor:Nora",
                                                  newTag: "actor:Nora Example")

        XCTAssertTrue(outcome.changedAnything)
        XCTAssertEqual(outcome.videosChanged, 1)
        XCTAssertEqual(try store.fetchAllAssets().first?.tags, ["actor:Nora Example"])
    }

    /// ⚠️ And one profile is left, not two. A merge that moved the videos but
    /// left both rows would put the duplicate straight back on the list.
    func testOnlyTheSurvivingProfileRemains() throws {
        _ = try twoProfiles()

        _ = try store.renameTagGlobally(oldTag: "actor:Nora", newTag: "actor:Nora Example")

        let actors = try store.fetchAllEntityProfiles()
            .filter { $0.type == "actor" && $0.name != "Sentinel" }
        XCTAssertEqual(actors.map(\.name), ["Nora Example"])
    }

    /// ⭐ The surviving profile keeps what the operator curated. A merge that
    /// let the losing row overwrite the fuller one would lose real work.
    func testTheSurvivingProfileKeepsItsOwnValues() throws {
        try markRekeyed()
        let losing = try store.newEntityProfile(named: "Nora", type: "actor")
        var surviving = try store.newEntityProfile(named: "Nora Example", type: "actor")
        surviving.akas = ["Nora"]
        surviving.bio = "the fuller record"
        try store.saveEntityProfile(losing)
        try store.saveEntityProfile(surviving)

        _ = try store.renameTagGlobally(oldTag: "actor:Nora", newTag: "actor:Nora Example")

        XCTAssertEqual(try store.fetchEntityProfile(named: "Nora Example", type: "actor")?.bio,
                       "the fuller record")
    }
}
