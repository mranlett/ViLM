// AliasMergeTests.swift
// Merging two performer profiles (device report, 2026-08-10).
//
// 🚨 The screenshot said "Merge 950B2335-… into BD9CCF-…" and tapping Merge
// did nothing, while the row disappeared as though it had worked. Two defects
// in one view:
//
//   • profile IDS were passed to `renameTagGlobally`, which matches
//     `actor:Name` strings in `Asset.tags`. Before the re-key an id WAS that
//     string, so it worked by coincidence and stopped silently afterwards.
//
//   • the outcome was discarded with `_ =`, so a rename that matched nothing
//     counted as a merge.
//
// ⚠️ The second is the one that made it invisible. A no-op that reports
// failure gets fixed the day it appears; a no-op that reports success is found
// weeks later by someone wondering why the duplicates keep coming back.

import XCTest
import LibraryCore
@testable import ViLM

final class AliasMergeTests: XCTestCase {

    private var url: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AliasMerge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store = try LibraryStore(at: url)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    private func actor(_ name: String, akas: [String] = []) throws -> EntityProfile {
        var p = try store.newEntityProfile(named: name, type: "actor")
        p.akas = akas
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

    // MARK: - ⭐ It actually merges

    func testMergingByNameMovesTheVideoAndReportsSuccess() throws {
        try actor("Nora")
        try actor("Nora Example", akas: ["Nora"])
        try video(crediting: "Nora")

        let outcome = AliasMerge.perform(losing: "Nora", surviving: "Nora Example", in: url)

        XCTAssertEqual(outcome, .merged)
        XCTAssertNil(outcome.message, "nothing to warn about")
        XCTAssertEqual(try store.fetchAllAssets().first?.tags, ["actor:Nora Example"])
    }

    func testOnlyTheSurvivingProfileRemains() throws {
        try actor("Nora")
        try actor("Nora Example", akas: ["Nora"])
        try video(crediting: "Nora")

        _ = AliasMerge.perform(losing: "Nora", surviving: "Nora Example", in: url)

        let actors = try store.fetchAllEntityProfiles()
            .filter { $0.type == "actor" }
        XCTAssertEqual(actors.map(\.name), ["Nora Example"])
    }

    // MARK: - 🚨 A no-op is reported as a no-op

    /// The exact defect: a name nothing is filed under changes nothing, and
    /// the screen must be told so rather than counting it as a merge.
    func testMergingAnUnknownNameReportsThatNothingChanged() throws {
        try actor("Nora Example")

        let outcome = AliasMerge.perform(losing: "Nobody Here",
                                         surviving: "Nora Example", in: url)

        XCTAssertEqual(outcome, .nothingChanged(losing: "Nobody Here"))
        XCTAssertNotNil(outcome.message, "the operator is told")
        XCTAssertTrue(outcome.message?.contains("Nobody Here") ?? false,
                      "and told WHICH name found nothing")
    }

    /// ⚠️ Merging a name into itself is refused rather than attempted — the
    /// store early-returns on it, which would otherwise surface as the
    /// confusing "nothing changed" for an action that made no sense.
    func testMergingANameIntoItselfIsRefused() throws {
        try actor("Nora Example")

        let outcome = AliasMerge.perform(losing: "Nora Example",
                                         surviving: "Nora Example", in: url)

        XCTAssertEqual(outcome, .nothingChanged(losing: "Nora Example"))
    }

    /// ⭐ Case-insensitively, because that is the same node.
    func testMergingANameIntoItsOwnCaseVariantIsRefused() throws {
        try actor("Nora Example")

        let outcome = AliasMerge.perform(losing: "nora example",
                                         surviving: "Nora Example", in: url)

        XCTAssertEqual(outcome, .nothingChanged(losing: "nora example"))
    }

    // MARK: - 🚨 The regression guard

    /// A profile ID must never be accepted as a name — this is what the
    /// screen passed, and it matches nothing.
    ///
    /// ⚠️ The uid is spelled out rather than taken from `profile.id`. On a
    /// re-keyed device that IS what an id looks like, and it is exactly what
    /// the screen passed; writing it literally means this test does not
    /// depend on the fixture library having been re-keyed, which is the
    /// condition that hid the defect in the first place.
    func testAProfileIdFindsNothingAndSaysSo() throws {
        try actor("Nora Example")
        try actor("Nora")
        try video(crediting: "Nora")

        let uid = "5B1C0A2E-7C4D-4F3A-9E21-2B7A66C1D904"
        let outcome = AliasMerge.perform(losing: uid, surviving: "Nora Example", in: url)

        XCTAssertEqual(outcome, .nothingChanged(losing: uid),
                       "a uid is not a name, and the caller is told")
        XCTAssertEqual(try store.fetchAllAssets().first?.tags, ["actor:Nora"],
                       "and the library is untouched")
    }
}
