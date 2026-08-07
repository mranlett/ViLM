import XCTest
@testable import LibraryCore

/// What a sync does with external identities.
///
/// ⭐ A match TRAVELS, unlike phase 1's edge attributes which the operator
/// settled as local bookkeeping. "This performer is that record" is a fact
/// about the world and is as true in one library as in another.
final class NodeMatchFederationTests: XCTestCase {

    private var directory: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        store = try LibraryStore(at: directory)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func actor(_ name: String) throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:\(name)"))
    }

    private func export(_ matches: [NodeMatch]) -> ActorLibraryExport {
        var e = ActorLibraryExport(formatVersion: ActorLibraryExport.currentFormatVersion,
                                   exportedAt: Date(), profiles: [], photos: [])
        e.entityMatches = matches
        return e
    }

    // MARK: - Additive

    func testAnIdentityThisLibraryLacksIsLearned() throws {
        try actor("Alice")

        let result = try store.applyGraphMerge(export([
            .init(nodeId: "actor:Alice", source: "A", sourceId: "a-1", method: .operator)
        ]))

        XCTAssertEqual(result.newMatches, 1)
        XCTAssertEqual(try store.matches(forEntity: "actor:Alice").first?.sourceId, "a-1")
    }

    func testAgreeingOnAnIdentityIsSilent() throws {
        try actor("Alice")
        try store.recordMatch(.init(nodeId: "actor:Alice", source: "A", sourceId: "a-1",
                                    method: .name), isVideo: false)

        let result = try store.applyGraphMerge(export([
            .init(nodeId: "actor:Alice", source: "A", sourceId: "a-1", method: .operator)
        ]))

        XCTAssertEqual(result.newMatches, 0)
        XCTAssertTrue(result.disagreements.isEmpty)
    }

    /// ⭐ A source this library does not use is still worth taking — an id
    /// costs nothing to hold and may matter the day that source is installed.
    func testAnIdentityFromAnUnusedSourceIsStillTaken() throws {
        try actor("Alice")
        try store.recordMatch(.init(nodeId: "actor:Alice", source: "A", sourceId: "a-1",
                                    method: .name), isVideo: false)

        let result = try store.applyGraphMerge(export([
            .init(nodeId: "actor:Alice", source: "B", sourceId: "b-9", method: .name)
        ]))

        XCTAssertEqual(result.newMatches, 1)
        XCTAssertEqual(Set(try store.matches(forEntity: "actor:Alice").map(\.source)),
                       ["A", "B"])
    }

    /// An identity naming someone this library has never heard of is skipped
    /// rather than conjuring the node — the same rule every other edge follows.
    func testAnIdentityForAnUnknownNodeIsSkipped() throws {
        let result = try store.applyGraphMerge(export([
            .init(nodeId: "actor:Nobody", source: "A", sourceId: "a-1", method: .name)
        ]))

        XCTAssertEqual(result.newMatches, 0)
        XCTAssertTrue(result.disagreements.isEmpty, "absence is not disagreement")
    }

    // MARK: - 🚨 The disagreement that matters most

    /// The two libraries do not merely describe this node differently — they
    /// believe it is a different person. Reported, and written nowhere.
    func testTwoDifferentIdentitiesInOneSourceAreReportedNotResolved() throws {
        try actor("Alice")
        try store.recordMatch(.init(nodeId: "actor:Alice", source: "A", sourceId: "mine",
                                    method: .operator), isVideo: false)

        let result = try store.applyGraphMerge(export([
            .init(nodeId: "actor:Alice", source: "A", sourceId: "theirs", method: .operator)
        ]))

        XCTAssertEqual(result.newMatches, 0)
        XCTAssertEqual(result.disagreements.first?.subject, .nodeIdentity)
        XCTAssertEqual(result.disagreements.first?.mine, "mine")
        XCTAssertEqual(result.disagreements.first?.theirs, "theirs")
        XCTAssertEqual(try store.matches(forEntity: "actor:Alice").first?.sourceId, "mine",
                       "my answer stands")
    }

    // MARK: - The format

    /// 🚨 The standing trap: a hand-written decoder beside a synthesized
    /// encoder. Adding a property updates one side and not the other, silently
    /// — which is exactly how the whole graph was discarded on import earlier.
    func testMatchesSurviveAFileRoundTrip() throws {
        try actor("Alice")
        try store.recordMatch(.init(nodeId: "actor:Alice", source: "A", sourceId: "a-1",
                                    method: .fingerprint), isVideo: false)

        let data = try JSONEncoder().encode(try store.exportGraph(includingPhotoData: false))
        let decoded = try JSONDecoder().decode(ActorLibraryExport.self, from: data)

        XCTAssertEqual(decoded.entityMatches.count, 1)
        XCTAssertEqual(decoded.entityMatches.first?.method, .fingerprint)
    }

    /// A file written before v31 decodes as "knew nothing about identities",
    /// never as a failure.
    func testAnOlderExportWithNoMatchesStillDecodes() throws {
        let json = #"{"formatVersion":2,"exportedAt":0,"profiles":[],"photos":[]}"#
        let decoded = try JSONDecoder().decode(ActorLibraryExport.self, from: Data(json.utf8))

        XCTAssertTrue(decoded.entityMatches.isEmpty)
    }

    /// ⚠️ A VIDEO match never travels — its node id is a video id, local to the
    /// library holding the file.
    func testVideoMatchesAreNotCarriedByAnExport() throws {
        let name = "\(UUID().uuidString).mp4"
        let asset = Asset(relativePath: name, fileName: name)
        try store.insertAsset(asset)
        try store.recordMatch(.init(nodeId: asset.id.uuidString, source: "A",
                                    sourceId: "v-1", method: .fingerprint), isVideo: true)

        let exported = try store.exportGraph(includingPhotoData: false)

        XCTAssertTrue(exported.entityMatches.isEmpty)
    }
}
