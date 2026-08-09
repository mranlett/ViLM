// PromoteIsIdempotentTests.swift
// Promoting studio strings to rows must be idempotent — in BOTH eras.
//
// 🚨 The test that should have existed when the minting decision landed.
// `promoteStudioProfiles` finds its work by comparing a `studio:Name` tag
// string against `entity_profiles.id`. That is only an anti-join while the id
// IS the name; after the re-key it matches nothing, so every studio in the
// library looks missing and is minted again — once per library per session.
//
// On the drive library that turned 469 studios into 1,116 across three
// launches, and nothing reported it, because minting a row is not an error.

import XCTest
import GRDB
@testable import LibraryCore

final class PromoteIsIdempotentTests: XCTestCase {

    private var url: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Promote-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store = try LibraryStore(at: url)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: url)
    }

    private func seedVideos(studios: [String]) throws {
        for studio in studios {
            let asset = Asset(relativePath: "\(UUID().uuidString).mp4",
                              fileName: "v.mp4", tags: ["studio:\(studio)"])
            try store.insertAsset(asset)
        }
    }

    private var studioCount: Int {
        get throws { try store.fetchAllEntityProfiles().filter { $0.type == "studio" }.count }
    }

    // MARK: - Before the re-key

    func testPromotingTwiceOnALegacyLibraryAddsNothingTheSecondTime() throws {
        try seedVideos(studios: ["Silver River", "Coast Line", "Harbour Lane"])

        XCTAssertEqual(try store.promoteStudioProfiles().count, 3)
        XCTAssertEqual(try studioCount, 3)

        XCTAssertEqual(try store.promoteStudioProfiles().count, 0, "nothing left to promote")
        XCTAssertEqual(try studioCount, 3)
    }

    // MARK: - 🚨 After the re-key — the case that failed

    func testPromotingTwiceOnARekeyedLibraryAddsNothingTheSecondTime() throws {
        try seedVideos(studios: ["Silver River", "Coast Line", "Harbour Lane"])
        _ = try store.promoteStudioProfiles()
        _ = try store.performIdentityRekey()
        XCTAssertTrue(try store.isRekeyed())
        XCTAssertEqual(try studioCount, 3)

        // Every subsequent launch calls this again.
        XCTAssertEqual(try store.promoteStudioProfiles().count, 0,
                       "a uid-keyed studio must not look missing")
        XCTAssertEqual(try studioCount, 3, "the row count must not move")

        _ = try store.promoteStudioProfiles()
        _ = try store.promoteStudioProfiles()
        XCTAssertEqual(try studioCount, 3, "three more launches, still three studios")
    }

    /// ⚠️ And a genuinely new studio arriving AFTER the re-key is still
    /// promoted — the fix must not turn the anti-join into "never do anything".
    func testANewStudioAfterTheRekeyIsStillPromoted() throws {
        try seedVideos(studios: ["Silver River"])
        _ = try store.promoteStudioProfiles()
        _ = try store.performIdentityRekey()

        try seedVideos(studios: ["Brand New Studio"])

        XCTAssertEqual(try store.promoteStudioProfiles().count, 1)
        XCTAssertEqual(try studioCount, 2)
        let minted = try XCTUnwrap(try store.fetchEntityProfile(named: "Brand New Studio",
                                                                type: "studio"))
        XCTAssertNil(NodeIdentity.parse(minted.id), "minted the library's own shape")
    }

    /// ⚠️ A studio whose NAME contains a colon must not be mis-sliced by the
    /// anti-join, which now takes `substr(value, 8)`.
    func testAColonInTheStudioNameSurvivesTheAntiJoin() throws {
        try seedVideos(studios: ["Vol 2: The Return"])
        _ = try store.promoteStudioProfiles()
        _ = try store.performIdentityRekey()

        XCTAssertEqual(try store.promoteStudioProfiles().count, 0)
        XCTAssertEqual(try studioCount, 1)
    }
}
