import XCTest
@testable import LibraryCore

/// What Connect the Graph claims it will do.
///
/// 🚨 `connectable` was `associations - alreadyConnected`: a TOTAL association
/// count minus a GLOBAL edge count. Two unrelated sets. On a real library it
/// reported 484 for a run that created 3, because the numerator counted credits
/// whose performer has no profile and the subtrahend counted edges that had
/// nothing to do with them.
final class ConnectPlanArithmeticTests: XCTestCase {

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

    @discardableResult
    private func video(_ tags: [String]) throws -> Asset {
        let asset = Asset(relativePath: "\(UUID()).mp4", fileName: "a.mp4", tags: tags)
        try store.saveAsset(asset)
        try store.updateAsset(asset)
        return asset
    }

    private func performer(_ name: String) throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:\(name)"))
    }

    // MARK: - 🚨 The reported defect

    /// A credit whose performer has no profile can NEVER become an edge, so it
    /// must not be counted as connectable.
    func testCreditsWithNoProfileAreNotCountedAsConnectable() throws {
        try performer("Known")
        _ = try video(["actor:Known", "actor:Missing One", "actor:Missing Two"])

        let plan = try store.connectPerformerEdges(dryRun: true)

        XCTAssertEqual(plan.associations, 3, "three credits exist")
        XCTAssertEqual(plan.skippedNoProfile, 2, "two can never connect")
        XCTAssertEqual(plan.connectable, 1, "only the one with a profile")
    }

    /// A second run adds nothing and must SAY it adds nothing.
    func testARerunReportsNothingLeftToConnect() throws {
        try performer("Known")
        _ = try video(["actor:Known"])

        _ = try store.connectPerformerEdges()
        let second = try store.connectPerformerEdges(dryRun: true)

        XCTAssertEqual(second.connectable, 0, "everything connectable is connected")
        XCTAssertEqual(second.alreadyConnected, 1)
    }

    /// ⚠️ The exact shape of the original defect: unconnectable credits inflate
    /// the total while existing edges are subtracted from it. The old formula
    /// gave a positive number here with nothing left to do.
    func testTheOldSubtractionWouldHaveOverstatedThis() throws {
        try performer("Known")
        _ = try video(["actor:Known", "actor:Missing One", "actor:Missing Two"])
        _ = try store.connectPerformerEdges()

        let plan = try store.connectPerformerEdges(dryRun: true)

        XCTAssertEqual(plan.connectable, 0, "nothing left that CAN be connected")
        // associations(3) - alreadyConnected(1) = 2 under the old formula.
        XCTAssertNotEqual(plan.connectable, plan.associations - plan.alreadyConnected,
                          "the old subtraction is exactly what this test exists to reject")
    }

    // MARK: - Studios

    func testStudioConnectableCountsOnlyWhatIsMissing() throws {
        try store.saveEntityProfile(EntityProfile(id: "studio:Coast Line"))
        _ = try video(["studio:Coast Line"])

        let first = try store.connectStudioEdges(dryRun: true)
        XCTAssertEqual(first.connectable, 1)

        _ = try store.connectStudioEdges()
        XCTAssertEqual(try store.connectStudioEdges(dryRun: true).connectable, 0)
    }

    // MARK: - Tags

    /// `videoEdges` is every wanted association, which is why it equals the
    /// table total on a re-run. `newVideoEdges` is what the run adds.
    func testTagPlanSeparatesNewEdgesFromTheWholeSet() throws {
        try store.saveTagRecord(TagRecord(displayName: "Outdoors", kind: .action))
        _ = try video(["tag:Outdoors"])

        let first = try store.connectTagEdges(dryRun: true)
        XCTAssertEqual(first.videoEdges, 1)
        XCTAssertEqual(first.newVideoEdges, 1)

        _ = try store.connectTagEdges()
        let second = try store.connectTagEdges(dryRun: true)

        XCTAssertEqual(second.videoEdges, 1, "the whole set is unchanged")
        XCTAssertEqual(second.newVideoEdges, 0, "and none of it is new")
    }
}
