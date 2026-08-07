import XCTest
@testable import LibraryCore

/// What a sync may do to the studio hierarchy.
///
/// 🚨 The merge's one rule is that it is **additive** — it fills gaps and never
/// overrules a decision the receiving library made. The studio-parent branch
/// broke that rule: an imprint this library had placed under one network was
/// silently re-parented to the sender's.
///
/// ⚠️ The defect predates the temporal migration; the old write was an
/// `ON CONFLICT DO UPDATE` and overwrote just as quietly. v30 made it worse
/// rather than causing it — the overruled parent is now demoted into dated
/// history, so a sync leaves a trail indistinguishable from a real acquisition.
final class GraphSyncStudioParentTests: XCTestCase {

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
    private func studio(_ name: String) throws -> String {
        let id = "studio:\(name)"
        try store.saveEntityProfile(EntityProfile(id: id))
        return id
    }

    /// An export carrying only a studio hierarchy.
    private func export(_ pairs: [(String, String)]) -> ActorLibraryExport {
        var e = ActorLibraryExport(formatVersion: ActorLibraryExport.currentFormatVersion,
                                   exportedAt: Date(), profiles: [], photos: [])
        e.studioParents = pairs.map { GraphEdgePair(from: "studio:\($0.0)",
                                                    to: "studio:\($0.1)") }
        return e
    }

    // MARK: - 🚨 The rule that was broken

    func testASyncNeverReparentsAStudioThisLibraryHasAlreadyPlaced() throws {
        let imprint = try studio("Coast Line")
        let mine = try studio("Old Network")
        _ = try studio("Example Network")
        try store.setStudioParent(mine, forStudio: imprint)

        let result = try store.applyGraphMerge(export([("Coast Line", "Example Network")]))

        XCTAssertEqual(try store.parentStudioId(of: imprint), mine,
                       "my answer stands")
        XCTAssertEqual(result.newStudioParents, 0)
        XCTAssertEqual(result.disagreements.count, 1)
        XCTAssertEqual(result.disagreements.first?.subject, .studioParent)
    }

    /// ⚠️ And it leaves no history either. A demoted period would read as a
    /// real acquisition on the studio's profile page.
    func testAnOverruledParentLeavesNoFalseHistory() throws {
        let imprint = try studio("Coast Line")
        let mine = try studio("Old Network")
        _ = try studio("Example Network")
        try store.setStudioParent(mine, forStudio: imprint)

        _ = try store.applyGraphMerge(export([("Coast Line", "Example Network")]))

        XCTAssertEqual(try store.studioParentHistory(of: imprint).count, 1,
                       "one period, not a fabricated succession")
    }

    /// The disagreement names both sides, so the operator can settle it.
    func testTheDisagreementCarriesBothAnswers() throws {
        let imprint = try studio("Coast Line")
        let mine = try studio("Old Network")
        _ = try studio("Example Network")
        try store.setStudioParent(mine, forStudio: imprint)

        let d = try XCTUnwrap(try store.applyGraphMerge(
            export([("Coast Line", "Example Network")])).disagreements.first)

        XCTAssertEqual(d.name, imprint)
        XCTAssertEqual(d.mine, mine)
        XCTAssertEqual(d.theirs, "studio:Example Network")
    }

    // MARK: - What it still does

    /// Genuinely additive: a gap gets filled.
    func testAStudioWithNoParentHereAcceptsTheSendersHierarchy() throws {
        let imprint = try studio("Coast Line")
        let network = try studio("Example Network")

        let result = try store.applyGraphMerge(export([("Coast Line", "Example Network")]))

        XCTAssertEqual(try store.parentStudioId(of: imprint), network)
        XCTAssertEqual(result.newStudioParents, 1)
        XCTAssertTrue(result.disagreements.isEmpty)
    }

    /// Agreement is not a conflict, and not a second write.
    func testAgreeingOnTheParentIsSilent() throws {
        let imprint = try studio("Coast Line")
        let network = try studio("Example Network")
        try store.setStudioParent(network, forStudio: imprint)

        let result = try store.applyGraphMerge(export([("Coast Line", "Example Network")]))

        XCTAssertEqual(result.newStudioParents, 0)
        XCTAssertTrue(result.disagreements.isEmpty)
        XCTAssertEqual(try store.studioParentHistory(of: imprint).count, 1)
    }

    /// An edge naming a studio this library has never heard of is skipped
    /// rather than conjuring the node.
    func testAnEdgeNamingAnUnknownStudioIsSkipped() throws {
        _ = try studio("Coast Line")

        let result = try store.applyGraphMerge(export([("Coast Line", "Never Heard Of")]))

        XCTAssertEqual(result.newStudioParents, 0)
        XCTAssertTrue(result.disagreements.isEmpty, "absence is not disagreement")
    }

    /// Re-running a sync must change nothing the second time.
    func testTheMergeIsIdempotent() throws {
        _ = try studio("Coast Line")
        _ = try studio("Example Network")

        _ = try store.applyGraphMerge(export([("Coast Line", "Example Network")]))
        let second = try store.applyGraphMerge(export([("Coast Line", "Example Network")]))

        XCTAssertEqual(second.newStudioParents, 0)
        XCTAssertTrue(second.disagreements.isEmpty)
        XCTAssertEqual(try store.studioParentHistory(of: "studio:Coast Line").count, 1)
    }
}
