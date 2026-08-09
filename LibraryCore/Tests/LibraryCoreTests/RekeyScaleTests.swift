// RekeyScaleTests.swift
// The re-key at the drive library's scale, so a pathological cost is a test
// failure rather than a watchdog kill during the one irreversible operation.

import XCTest
@testable import LibraryCore

final class RekeyScaleTests: XCTestCase {

    private var url: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RekeyScale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store = try LibraryStore(at: url)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: url)
    }

    /// 🚨 The photo mapping is the quadratic one: every file is matched against
    /// every profile's safe id. At the drive library's shape — ~1,800 profiles,
    /// ~9,000 files — that is sixteen million comparisons, and it used to build
    /// two throwaway Strings inside each.
    ///
    /// ⚠️ A generous ceiling on purpose. This is a regression guard against
    /// re-introducing per-comparison allocation, not a benchmark — a machine
    /// under load must not fail it spuriously.
    func testPlanningTheRekeyIsNotQuadraticallyExpensive() throws {
        let profileCount = 1_800
        try store.dbQueue.write { db in
            for i in 0..<profileCount {
                try EntityProfile(id: "actor:Performer \(i)").insert(db)
            }
        }
        // Four photos each, the shape a well-enriched library actually has.
        let dir = url.appendingPathComponent(".catalog/profiles")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<profileCount {
            let safe = ProfileImageNaming.safeId(for: "actor:Performer \(i)")
            try Data("x".utf8).write(to: dir.appendingPathComponent("\(safe).jpg"))
            for g in 0..<3 {
                try Data("x".utf8).write(to: dir.appendingPathComponent("\(safe)_\(g).jpg"))
            }
        }

        let started = Date()
        let plan = try store.rekeyPlan()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(plan.nodeCount, profileCount)
        XCTAssertEqual(plan.photoCount, profileCount * 4)
        XCTAssertLessThan(elapsed, 10.0,
                          "planning took \(elapsed)s — the file/profile match has regressed")
    }

    /// ⚠️ The whole operation at scale, including the copy and delete phases —
    /// which used to run a `fileExists` per photo rather than one listing.
    func testTheWholeRekeyCompletesAtLibraryScale() throws {
        let profileCount = 600
        try store.dbQueue.write { db in
            for i in 0..<profileCount {
                try EntityProfile(id: "actor:Performer \(i)").insert(db)
            }
        }
        let dir = url.appendingPathComponent(".catalog/profiles")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<profileCount {
            let safe = ProfileImageNaming.safeId(for: "actor:Performer \(i)")
            try Data("x".utf8).write(to: dir.appendingPathComponent("\(safe).jpg"))
        }

        let started = Date()
        let result = try store.performIdentityRekey()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(result.nodesRekeyed, profileCount)
        XCTAssertEqual(result.photosCopied, profileCount)
        XCTAssertEqual(result.photosDeleted, profileCount)
        XCTAssertLessThan(elapsed, 20.0, "the re-key took \(elapsed)s at 600 profiles")

        // And every name still resolves afterwards.
        XCTAssertNotNil(try store.fetchEntityProfile(named: "Performer 42", type: "actor"))
    }
}
