import XCTest
@testable import LibraryCore

/// What happens to a node's EDGES when it is renamed or merged.
///
/// 🚨 They were destroyed. `video_performer`, `performer_tag`, `video_studio`
/// and `studio_parent` all reference `entity_profiles` with ON DELETE CASCADE,
/// and a rename deletes the old profile row — so renaming or merging an actor
/// silently wiped every cast edge they had, and merging two studios wiped the
/// hierarchy with them.
///
/// ⚠️ It looked fine. The tag STRINGS on the videos were rewritten correctly,
/// so browsing, filtering and counts all still worked; only the graph was gone.
/// Found before building the alias-merge tool, which would have done this 43
/// times in one pass.
final class RenamePreservesEdgesTests: XCTestCase {

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
    private func video(tags: [String] = []) throws -> Asset {
        let name = "\(UUID().uuidString).mp4"
        let asset = Asset(relativePath: name, fileName: name, tags: tags)
        try store.insertAsset(asset)
        return asset
    }

    private func profile(_ id: String) throws {
        try store.saveEntityProfile(EntityProfile(id: id))
    }

    // MARK: - Performers

    /// A pure rename: the cast edge follows the person.
    func testRenamingAnActorMovesTheirCastEdges() throws {
        let asset = try video(tags: ["actor:Venlowe"])
        try profile("actor:Venlowe")
        try store.linkPerformer("actor:Venlowe", toVideo: asset.id)

        try store.renameTagGlobally(oldTag: "actor:Venlowe", newTag: "actor:Marta Venlowe")

        XCTAssertEqual(try store.performerIds(forVideo: asset.id), ["actor:Marta Venlowe"])
    }

    /// 🚨 The merge case — what the alias tool does 43 times.
    func testMergingTwoActorsKeepsBothTheirCastEdges() throws {
        let a = try video(tags: ["actor:Venlowe"])
        let b = try video(tags: ["actor:Marta Venlowe"])
        try profile("actor:Venlowe")
        try profile("actor:Marta Venlowe")
        try store.linkPerformer("actor:Venlowe", toVideo: a.id)
        try store.linkPerformer("actor:Marta Venlowe", toVideo: b.id)

        try store.renameTagGlobally(oldTag: "actor:Venlowe", newTag: "actor:Marta Venlowe")

        XCTAssertEqual(try store.performerIds(forVideo: a.id), ["actor:Marta Venlowe"],
                       "the losing profile's video keeps its cast")
        XCTAssertEqual(try store.performerIds(forVideo: b.id), ["actor:Marta Venlowe"])
    }

    /// Both sides already on the same video collapse to one edge, not an error.
    func testAVideoCreditingBothHalvesEndsWithOneEdge() throws {
        let asset = try video(tags: ["actor:Venlowe", "actor:Marta Venlowe"])
        try profile("actor:Venlowe")
        try profile("actor:Marta Venlowe")
        try store.linkPerformer("actor:Venlowe", toVideo: asset.id)
        try store.linkPerformer("actor:Marta Venlowe", toVideo: asset.id)

        try store.renameTagGlobally(oldTag: "actor:Venlowe", newTag: "actor:Marta Venlowe")

        XCTAssertEqual(try store.performerIds(forVideo: asset.id), ["actor:Marta Venlowe"])
    }

    /// A performer's traits travel too.
    func testAPerformersTraitEdgesFollowTheRename() throws {
        try profile("actor:Venlowe")
        try profile("actor:Marta Venlowe")
        try store.saveTagRecord(TagRecord(displayName: "Tall", kind: .performerAttribute))
        try store.linkTag(TagNormalizer.identityKey("Tall"), toPerformer: "actor:Venlowe")

        try store.renameTagGlobally(oldTag: "actor:Venlowe", newTag: "actor:Marta Venlowe")

        XCTAssertEqual(try store.performerTagPairs().map(\.from), ["actor:Marta Venlowe"])
    }

    // MARK: - Studios

    func testMergingTwoStudiosKeepsTheReleasingEdge() throws {
        let asset = try video(tags: ["studio:Coast Line"])
        try profile("studio:Coast Line")
        try profile("studio:Coastline")
        try store.setStudio("studio:Coast Line", forVideo: asset.id)

        try store.renameTagGlobally(oldTag: "studio:Coast Line", newTag: "studio:Coastline")

        XCTAssertEqual(try store.studioId(forVideo: asset.id), "studio:Coastline")
    }

    /// 🚨 The hierarchy survives a studio rename.
    func testRenamingAStudioKeepsItsPlaceInTheHierarchy() throws {
        try profile("studio:Coast Line")
        try profile("studio:Example Network")
        try store.setStudioParent("studio:Example Network", forStudio: "studio:Coast Line")

        try store.renameTagGlobally(oldTag: "studio:Coast Line", newTag: "studio:Coastline")

        XCTAssertEqual(try store.parentStudioId(of: "studio:Coastline"),
                       "studio:Example Network")
    }

    /// Renaming the NETWORK keeps its imprints beneath it.
    func testRenamingANetworkKeepsItsImprints() throws {
        try profile("studio:Coast Line")
        try profile("studio:Example Network")
        try profile("studio:Example Group")
        try store.setStudioParent("studio:Example Network", forStudio: "studio:Coast Line")

        try store.renameTagGlobally(oldTag: "studio:Example Network",
                                    newTag: "studio:Example Group")

        XCTAssertEqual(try store.parentStudioId(of: "studio:Coast Line"),
                       "studio:Example Group")
    }

    /// ⚠️ Merging a child into its own parent must not leave a self-loop, which
    /// is a cycle the hierarchy refuses everywhere else.
    func testMergingAnImprintIntoItsParentLeavesNoSelfLoop() throws {
        try profile("studio:Coast Line")
        try profile("studio:Example Network")
        try store.setStudioParent("studio:Example Network", forStudio: "studio:Coast Line")

        try store.renameTagGlobally(oldTag: "studio:Coast Line",
                                    newTag: "studio:Example Network")

        XCTAssertNil(try store.parentStudioId(of: "studio:Example Network"),
                     "a studio cannot own itself")
    }
}
