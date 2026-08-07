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
        try tag("Tall", .performerAttribute)
        let v = try video(["tag:Tall"])

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

/// The CSV round-trip's graph half. An enriched file used to land its tags as
/// bare strings, so running the enricher left the graph exactly as it was.
final class PerformerTagImportTests: XCTestCase {

    private var libraryURL: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        libraryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PerfTags-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        store = try LibraryStore(at: libraryURL)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: libraryURL)
    }

    private func actor(_ name: String, tags: [String]) throws -> String {
        var p = EntityProfile(id: "actor:\(name)")
        p.tags = tags
        try store.saveEntityProfile(p)
        return p.id
    }

    /// ⚠️ The inference the taxonomy allows: a tag arriving ON a person is
    /// known to describe a person, so it needs no classification step.
    func testAnUnknownTagOnAnActorBecomesAPerformerAttribute() throws {
        let id = try actor("Alice Example", tags: ["Tall"])

        let result = try store.connectPerformerTags(for: [id])

        XCTAssertEqual(result.created, 1)
        XCTAssertEqual(result.linked, 1)
        XCTAssertEqual(try store.fetchTagVocabulary().first?.resolvedKind(),
                       TagKind.performerAttribute)
        XCTAssertEqual(try store.edgeCount(.performerTag), 1)
    }

    /// ⚠️ A tag already known as something else keeps its kind, and gets no
    /// edge — an arriving file does not outrank a decision already made.
    func testAnExistingClassificationIsNotOverruled() throws {
        try store.saveTagRecord(TagRecord(displayName: "Climbing", kind: .action))
        let id = try actor("Alice Example", tags: ["Climbing"])

        let result = try store.connectPerformerTags(for: [id])

        XCTAssertEqual(result.created, 0)
        XCTAssertEqual(result.linked, 0, "an action does not attach to a person")
        XCTAssertEqual(try store.fetchTagVocabulary().first?.resolvedKind(), TagKind.action)
    }

    func testRunningTwiceAddsNothing() throws {
        let id = try actor("Alice Example", tags: ["Tall"])

        try store.connectPerformerTags(for: [id])
        try store.connectPerformerTags(for: [id])

        XCTAssertEqual(try store.edgeCount(.performerTag), 1)
        XCTAssertEqual(try store.fetchTagVocabulary().count, 1)
    }

    /// Case variants are one tag, not two.
    func testSpellingVariantsResolveToOneTag() throws {
        let a = try actor("Alice Example", tags: ["Tall"])
        let b = try actor("Bob Example", tags: ["tall"])

        try store.connectPerformerTags(for: [a, b])

        XCTAssertEqual(try store.fetchTagVocabulary().count, 1)
        XCTAssertEqual(try store.edgeCount(.performerTag), 2)
    }

    /// Studios are not people.
    func testNonActorProfilesAreIgnored() throws {
        var studio = EntityProfile(id: "studio:Example Studio")
        studio.tags = ["Tall"]
        try store.saveEntityProfile(studio)

        let result = try store.connectPerformerTags(for: ["studio:Example Studio"])

        XCTAssertEqual(result.created, 0)
        XCTAssertEqual(try store.edgeCount(.performerTag), 0)
    }
}
