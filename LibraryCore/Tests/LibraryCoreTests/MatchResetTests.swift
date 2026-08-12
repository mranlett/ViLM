import XCTest
@testable import LibraryCore

/// The one-time reset that returns videos to the queue so they can be matched
/// again under the studio-hierarchy rules.
///
/// Destructive over the whole library, so what it must NOT touch matters more
/// than what it does.
final class MatchResetTests: XCTestCase {

    private var libraryURL: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        libraryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MatchReset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        store = try LibraryStore(at: libraryURL)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: libraryURL)
    }

    @discardableResult
    private func insert(_ state: EnrichmentState?, id: UUID = UUID()) throws -> UUID {
        try store.insertAsset(Asset(
            id: id,
            relativePath: "\(id).mp4", fileName: "a.mp4",
            tags: ["actor:Alice Example", "studio:Example Studio", "tag:Outdoors"],
            rating: 4,
            videoName: "Example Series",
            // Declared, so these exercise the enrichment-state logic rather
            // than stopping at the privacy boundary (#59).
            contentKind: .scene,
            releaseDate: "2019-04-12",
            enrichmentState: state,
            enrichmentSource: state == nil ? nil : "TestSource",
            enrichmentSourceId: state == .matched ? "scene-1" : nil,
            enrichmentUrl: state == .matched ? "https://example.com/scene/1" : nil,
            enrichmentCheckedAt: state == nil ? nil : Date()))
        return id
    }

    private func fetch(_ id: UUID) throws -> Asset {
        try XCTUnwrap(try store.fetchAllAssets().first { $0.id == id })
    }

    // MARK: - Counting before writing

    func testThePlanCountsEachStateSeparately() throws {
        try insert(.matched); try insert(.matched)
        try insert(.unmatchable)
        try insert(.noMatch); try insert(.ambiguous)
        try insert(nil)

        let plan = try store.planMatchReset()

        XCTAssertEqual(plan.matched, 2)
        XCTAssertEqual(plan.ruledOut, 1)
        XCTAssertEqual(plan.unresolved, 2)
        XCTAssertEqual(plan.clearable, 4, "what a default reset would touch")
        XCTAssertEqual(plan.total, 5, "never-looked-at videos are not in scope")
    }

    // MARK: - What it clears

    func testAMatchedVideoReturnsToTheQueue() throws {
        let id = try insert(.matched)

        try store.resetMatchStatus()

        let asset = try fetch(id)
        XCTAssertNil(asset.enrichmentState)
        XCTAssertNil(asset.enrichmentSource)
        XCTAssertNil(asset.enrichmentSourceId)
        XCTAssertNil(asset.enrichmentUrl)
        XCTAssertNil(asset.enrichmentCheckedAt)
        XCTAssertNil(VideoBatchPolicy.skipReason(for: asset),
                     "and is therefore examined again on the next run")
    }

    // MARK: - ⚠️ What it must NOT clear

    /// The whole point of the reset is to match again — against metadata the
    /// library already holds. Emptying it would be data loss dressed as a retry.
    func testEveryValueAMatchWroteSurvives() throws {
        let id = try insert(.matched)

        try store.resetMatchStatus()

        let asset = try fetch(id)
        XCTAssertEqual(asset.releaseDate, "2019-04-12")
        XCTAssertEqual(asset.videoName, "Example Series")
        XCTAssertEqual(asset.rating, 4)
        XCTAssertEqual(asset.actors, ["Alice Example"])
        XCTAssertEqual(asset.studios, ["Example Studio"])
        XCTAssertEqual(asset.actions, ["Outdoors"])
    }

    /// ⚠️ `unmatchable` is a human decision — the one state a machine never
    /// assigns. Clearing it by default would return videos to a queue they were
    /// deliberately removed from, and nothing could re-derive the judgement.
    func testARuledOutVideoIsLeftAloneByDefault() throws {
        let id = try insert(.unmatchable)

        try store.resetMatchStatus()

        let asset = try fetch(id)
        XCTAssertEqual(asset.enrichmentState, .unmatchable)
        XCTAssertEqual(VideoBatchPolicy.skipReason(for: asset), "you ruled this one out",
                       "it stays out of the queue")
    }

    func testRuledOutIsClearedOnlyWhenExplicitlyAskedFor() throws {
        let id = try insert(.unmatchable)

        try store.resetMatchStatus(includingRuledOut: true)

        XCTAssertNil(try fetch(id).enrichmentState)
    }

    func testAVideoNeverLookedAtIsUntouched() throws {
        let id = try insert(nil)

        XCTAssertEqual(try store.resetMatchStatus(), 0, "there was nothing to clear")
        XCTAssertNil(try fetch(id).enrichmentState)
    }

    // MARK: - Reporting and repetition

    func testItReportsHowManyItCleared() throws {
        try insert(.matched); try insert(.noMatch); try insert(.unmatchable)

        XCTAssertEqual(try store.resetMatchStatus(), 2, "ruled-out is not counted")
    }

    /// Running it twice is harmless — the second pass finds nothing left.
    func testASecondResetIsANoOp() throws {
        try insert(.matched)
        _ = try store.resetMatchStatus()

        XCTAssertEqual(try store.resetMatchStatus(), 0)
    }

    func testTheResetSurvivesAReopen() throws {
        let id = try insert(.matched)
        try store.resetMatchStatus()

        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        store = try LibraryStore(at: libraryURL)

        XCTAssertNil(try fetch(id).enrichmentState)
    }
}
