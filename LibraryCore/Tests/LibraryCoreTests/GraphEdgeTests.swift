import XCTest
@testable import LibraryCore

/// Phase D — the edges.
///
/// These assert properties the SCHEMA guarantees, rather than what any code
/// remembers to do. The point of moving the graph out of strings is that the
/// constraints stop being conventions.
final class GraphEdgeTests: XCTestCase {

    private var libraryURL: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        libraryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphEdge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        store = try LibraryStore(at: libraryURL)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: libraryURL)
    }

    private func makeVideo() throws -> UUID {
        let asset = Asset(relativePath: "\(UUID()).mp4", fileName: "a.mp4")
        try store.insertAsset(asset)
        return asset.id
    }

    private func makeProfile(_ id: String) throws {
        try store.saveEntityProfile(EntityProfile(id: id))
    }

    // MARK: - Cardinality is structural

    /// A scene has one releasing studio. Setting another REPLACES it rather
    /// than adding — which is what the studio-conflict audit exists to detect
    /// today, made impossible instead of merely detectable.
    func testAVideoHasExactlyOneStudio() throws {
        let video = try makeVideo()
        try makeProfile("studio:Example Studio")
        try makeProfile("studio:Other Studio")

        try store.setStudio("studio:Example Studio", forVideo: video)
        try store.setStudio("studio:Other Studio", forVideo: video)

        XCTAssertEqual(try store.studioId(forVideo: video), "studio:Other Studio")
        XCTAssertEqual(try store.edgeCount(.videoStudio), 1,
                       "a second studio replaces the first; it never joins it")
    }

    func testAVideoMayHaveManyPerformers() throws {
        let video = try makeVideo()
        try makeProfile("actor:Alice Example")
        try makeProfile("actor:Bob Example")

        try store.linkPerformer("actor:Alice Example", toVideo: video)
        try store.linkPerformer("actor:Bob Example", toVideo: video)

        XCTAssertEqual(try store.performerIds(forVideo: video),
                       ["actor:Alice Example", "actor:Bob Example"])
    }

    /// Crediting the same performer twice is one edge, not an error and not two.
    func testCreditingTwiceIsIdempotent() throws {
        let video = try makeVideo()
        try makeProfile("actor:Alice Example")

        try store.linkPerformer("actor:Alice Example", toVideo: video)
        try store.linkPerformer("actor:Alice Example", toVideo: video)

        XCTAssertEqual(try store.edgeCount(.videoPerformer), 1)
    }

    // MARK: - The query that used to be a scan

    /// "Which videos feature this performer" was a walk over every asset in the
    /// library with the names compared by hand, aliases reconciled in code.
    func testVideosForAPerformerIsOneQuery() throws {
        let a = try makeVideo(), b = try makeVideo(), c = try makeVideo()
        try makeProfile("actor:Alice Example")
        try store.linkPerformer("actor:Alice Example", toVideo: a)
        try store.linkPerformer("actor:Alice Example", toVideo: c)

        let found = Set(try store.videoIds(forPerformer: "actor:Alice Example"))

        XCTAssertEqual(found, [a, c])
        XCTAssertFalse(found.contains(b))
    }

    // MARK: - Deletion

    /// Deleting a video removes its edges and nothing else. The performers it
    /// credited are people and they survive it — a rule stated explicitly, and
    /// one no cleanup pass may quietly reverse.
    func testDeletingAVideoLeavesItsPerformersIntact() throws {
        let video = try makeVideo()
        try makeProfile("actor:Alice Example")
        try store.linkPerformer("actor:Alice Example", toVideo: video)

        try store.deleteAsset(XCTUnwrap(try store.fetchAllAssets().first { $0.id == video }))

        XCTAssertEqual(try store.edgeCount(.videoPerformer), 0, "the edge goes")
        XCTAssertNotNil(try store.fetchEntityProfile(for: "actor:Alice Example"),
                        "the person does not")
    }

    /// A performer at zero videos is still someone the library knows about.
    func testAPerformerWithNoVideosSurvives() throws {
        try makeProfile("actor:Alice Example")

        XCTAssertNotNil(try store.fetchEntityProfile(for: "actor:Alice Example"))
        XCTAssertEqual(try store.edgeCount(.videoPerformer), 0)
    }

    // MARK: - Studio hierarchy

    /// Absence means root. There is no NULL-parent row to interpret.
    func testAStudioWithNoParentRowIsARoot() throws {
        try makeProfile("studio:Example Studio")

        XCTAssertEqual(try store.studioIdWithDescendants("studio:Example Studio"),
                       ["studio:Example Studio"])
    }

    /// The reason the hierarchy exists: a filter on a network must find the
    /// imprints beneath it, which today it does not.
    func testANetworkFindsItsImprints() throws {
        for id in ["studio:Network", "studio:Imprint", "studio:Deeper"] { try makeProfile(id) }
        try store.setStudioParent("studio:Network", forStudio: "studio:Imprint")
        try store.setStudioParent("studio:Imprint", forStudio: "studio:Deeper")

        XCTAssertEqual(Set(try store.studioIdWithDescendants("studio:Network")),
                       ["studio:Network", "studio:Imprint", "studio:Deeper"],
                       "transitively, not just one level")
    }

    /// ⚠️ CHANGED by the temporal migration (v30), deliberately.
    ///
    /// This used to assert one ROW after a reassignment — "reassigned, not
    /// accumulated" — because the table could hold only one parent per studio,
    /// forever. It now holds a history: the old ownership was true and stopped
    /// being true, and erasing it was the thing phase 2 exists to stop.
    ///
    /// The invariant that survives is the one that was actually meant: **at
    /// most one CURRENT parent.**
    func testAStudioHasAtMostOneCurrentParent() throws {
        for id in ["studio:Imprint", "studio:Network", "studio:Other"] { try makeProfile(id) }

        try store.setStudioParent("studio:Network", forStudio: "studio:Imprint")
        try store.setStudioParent("studio:Other", forStudio: "studio:Imprint")

        XCTAssertEqual(try store.parentStudioId(of: "studio:Imprint"), "studio:Other",
                       "the latest assignment is the current one")
        XCTAssertEqual(try store.studioParentPairs().count, 1,
                       "one CURRENT parent, whatever the history holds")
        XCTAssertEqual(try store.edgeCount(.studioParent), 2,
                       "and the former ownership is kept rather than erased")
    }

    /// ⚠️ Without this a parent-studio filter recurses forever.
    func testAStudioCannotBecomeItsOwnAncestor() throws {
        for id in ["studio:A", "studio:B"] { try makeProfile(id) }
        try store.setStudioParent("studio:A", forStudio: "studio:B")

        XCTAssertThrowsError(try store.setStudioParent("studio:B", forStudio: "studio:A")) {
            guard case GraphEdgeError.cycle = $0 else {
                return XCTFail("expected a cycle error, got \($0)")
            }
        }
    }

    func testAStudioCannotBeItsOwnParent() throws {
        try makeProfile("studio:A")

        XCTAssertThrowsError(try store.setStudioParent("studio:A", forStudio: "studio:A"))
    }

    /// ⚠️ Deleting a network PROMOTES its imprints rather than deleting them.
    /// The cascade removes the hierarchy row, not the profile it points at.
    func testDeletingANetworkPromotesItsImprints() throws {
        for id in ["studio:Imprint", "studio:Network"] { try makeProfile(id) }
        try store.setStudioParent("studio:Network", forStudio: "studio:Imprint")

        try store.deleteEntityProfile(for: "studio:Network")

        XCTAssertEqual(try store.edgeCount(.studioParent), 0, "the hierarchy row goes")
        XCTAssertNotNil(try store.fetchEntityProfile(for: "studio:Imprint"),
                        "the imprint becomes a root, it is not deleted with its parent")
    }

    // MARK: - Pending associations

    /// Not an edge: invisible to every graph query until someone says what the
    /// tag describes.
    func testAPendingAssociationIsNotAnEdge() throws {
        let video = try makeVideo()
        try store.saveTagRecord(TagRecord(displayName: "Unsorted"))
        try store.addPendingTagAssociation(TagNormalizer.identityKey("Unsorted"), forVideo: video)

        XCTAssertEqual(try store.tagIds(forVideo: video), [], "no edge exists")
        XCTAssertEqual(try store.edgeCount(.pendingTagAssociation), 1, "but the link survives")
    }

    /// It must not outlive the video it referred to, or a later classification
    /// would materialise a link to nothing.
    func testDeletingAVideoPurgesItsPendingAssociations() throws {
        let video = try makeVideo()
        try store.saveTagRecord(TagRecord(displayName: "Unsorted"))
        try store.addPendingTagAssociation(TagNormalizer.identityKey("Unsorted"), forVideo: video)

        try store.deleteAsset(XCTUnwrap(try store.fetchAllAssets().first { $0.id == video }))

        XCTAssertEqual(try store.edgeCount(.pendingTagAssociation), 0)
    }

    // MARK: - The migration has not started

    /// ⚠️ Creating the tables changes nothing. The legacy strings stay
    /// authoritative until the connect step has run and been verified, which is
    /// what makes this migration safe to ship on its own.
    func testCreatingTheTablesWritesNoEdges() throws {
        try store.insertAsset(Asset(relativePath: "b.mp4", fileName: "b.mp4",
                                    tags: ["actor:Alice Example", "studio:Example Studio",
                                           "tag:Outdoors"]))

        for kind in GraphEdgeKind.allCases {
            XCTAssertEqual(try store.edgeCount(kind), 0,
                           "\(kind.rawValue) must stay empty until the connect step runs")
        }
    }
}
