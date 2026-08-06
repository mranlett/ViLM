import XCTest
@testable import LibraryCore

/// ⚠️ A moved video is rebuilt under a NEW id in the destination. Edges point
/// at ids, so none of the source's can follow it — the video would arrive with
/// its text intact and no place in the graph at all.
///
/// These pin the single-video connect the move now runs, including the things
/// it must refuse to do just because a move is convenient.
final class MoveIsGraphAwareTests: XCTestCase {

    private var libraryURL: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        libraryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoveGraph-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        store = try LibraryStore(at: libraryURL)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: libraryURL)
    }

    @discardableResult
    private func video(_ tags: [String]) throws -> UUID {
        let asset = Asset(relativePath: "\(UUID()).mp4", fileName: "a.mp4", tags: tags)
        try store.insertAsset(asset)
        return asset.id
    }

    private func profile(_ id: String) throws {
        try store.saveEntityProfile(EntityProfile(id: id))
    }

    private func tag(_ name: String, _ kind: TagKind?) throws {
        try store.saveTagRecord(TagRecord(displayName: name, kind: kind))
    }

    // MARK: - What arriving in a library gets you

    func testAnArrivingVideoIsWiredIn() throws {
        try profile("actor:Alice Example")
        try profile("studio:Example Studio")
        try tag("Climbing", .action)
        let v = try video(["actor:Alice Example", "studio:Example Studio", "tag:Climbing"])

        let written = try store.connectEdges(forVideo: v)

        XCTAssertEqual(written, 3)
        XCTAssertEqual(try store.performerIds(forVideo: v), ["actor:Alice Example"])
        XCTAssertEqual(try store.studioId(forVideo: v), "studio:Example Studio")
        XCTAssertEqual(try store.tagIds(forVideo: v), [TagNormalizer.identityKey("Climbing")])
    }

    func testConnectingTheSameVideoTwiceAddsNothing() throws {
        try profile("actor:Alice Example")
        let v = try video(["actor:Alice Example"])

        try store.connectEdges(forVideo: v)
        try store.connectEdges(forVideo: v)

        XCTAssertEqual(try store.edgeCount(.videoPerformer), 1)
    }

    /// It touches ONLY the video it was given.
    func testOtherVideosAreNotConnected() throws {
        try profile("actor:Alice Example")
        let mine = try video(["actor:Alice Example"])
        let other = try video(["actor:Alice Example"])

        try store.connectEdges(forVideo: mine)

        XCTAssertEqual(try store.performerIds(forVideo: other), [],
                       "a move is not a library-wide connect")
    }

    func testAnUnknownVideoIsHarmless() throws {
        XCTAssertEqual(try store.connectEdges(forVideo: UUID()), 0)
    }

    // MARK: - ⚠️ What a move must still refuse

    /// A credit naming someone with no profile in THIS library is skipped. A
    /// move must not mint a person, any more than a parse may.
    func testACreditWithNoProfileHereIsSkipped() throws {
        try profile("actor:Alice Example")
        let v = try video(["actor:Alice Example", "actor:Nobody Known"])

        try store.connectEdges(forVideo: v)

        XCTAssertEqual(try store.performerIds(forVideo: v), ["actor:Alice Example"])
        XCTAssertNil(try store.fetchEntityProfile(for: "actor:Nobody Known"))
    }

    /// ⚠️ Two studios stays unrepresented. Resolving it here would let a move
    /// quietly settle the question the conflict screen exists to ask.
    func testAVideoWithTwoStudiosArrivesWithoutAStudioEdge() throws {
        try profile("studio:Example Studio"); try profile("studio:Other Studio")
        let v = try video(["studio:Example Studio", "studio:Other Studio"])

        try store.connectEdges(forVideo: v)

        XCTAssertNil(try store.studioId(forVideo: v))
    }

    /// A trait describing a person is not attached to the video — the same
    /// decision the bulk connect makes, so a move cannot be a way around it.
    func testAPerformerTraitIsNotAttachedByAMove() throws {
        try tag("Redhead", .performerAttribute)
        let v = try video(["tag:Redhead"])

        try store.connectEdges(forVideo: v)

        XCTAssertEqual(try store.tagIds(forVideo: v), [])
    }

    func testAnUnclassifiedTagIsStagedNotDropped() throws {
        try tag("Unsorted", nil)
        let v = try video(["tag:Unsorted"])

        try store.connectEdges(forVideo: v)

        XCTAssertEqual(try store.tagIds(forVideo: v), [])
        XCTAssertEqual(try store.edgeCount(.pendingTagAssociation), 1)
    }

    /// A tag the destination has never heard of cannot be routed, so it is
    /// left in the text rather than invented into the vocabulary.
    func testATagMissingFromThisLibrarysVocabularyIsLeftAlone() throws {
        let v = try video(["tag:Never Promoted"])

        try store.connectEdges(forVideo: v)

        XCTAssertEqual(try store.tagIds(forVideo: v), [])
        XCTAssertEqual(try store.edgeCount(.pendingTagAssociation), 0)
        XCTAssertTrue(try store.fetchTagVocabulary().isEmpty)
    }
}
