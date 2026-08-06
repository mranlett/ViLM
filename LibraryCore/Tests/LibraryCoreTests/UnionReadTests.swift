import XCTest
@testable import LibraryCore

/// Phase D, step 4 — the read contract.
///
/// Mid-migration a video's facts live in two places at once. These pin the one
/// property that makes step 5 safe: **retiring a string does not change an
/// answer.** Every test here that reads before and after a retirement is
/// asserting exactly that, because the moment it stops holding, dropping a
/// string starts losing data.
final class UnionReadTests: XCTestCase {

    private var libraryURL: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        libraryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("UnionRead-\(UUID().uuidString)", isDirectory: true)
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

    private func profile(_ id: String, tags: [String] = []) throws {
        var p = EntityProfile(id: id)
        p.tags = tags
        try store.saveEntityProfile(p)
    }

    private func tag(_ name: String, _ kind: TagKind?) throws {
        try store.saveTagRecord(TagRecord(displayName: name, kind: kind))
    }

    /// Drops every `tag:`/`actor:`/`studio:` string matching `predicate`,
    /// standing in for what step 5 will do once the gate passes.
    private func retireStrings(where predicate: (String) -> Bool) throws {
        for asset in try store.fetchAllAssets() {
            var updated = asset
            updated.tags = asset.tags.filter { !predicate($0) }
            guard updated.tags != asset.tags else { continue }
            try store.updateAsset(updated)
        }
    }

    // MARK: - Before anything is connected

    /// Day zero: no edges exist at all, and the reads must still answer.
    /// Otherwise every screen goes blank the moment they are adopted, long
    /// before a migration has run.
    func testTheStringsAloneAnswerBeforeAnyEdgesExist() throws {
        try profile("actor:Alice Example")
        try profile("studio:Example Studio")
        try tag("Climbing", .action)
        let v = try video(["actor:Alice Example", "studio:Example Studio", "tag:Climbing"])

        XCTAssertEqual(try store.resolvedPerformerIds(forVideo: v), ["actor:Alice Example"])
        XCTAssertEqual(try store.resolvedStudioId(forVideo: v), "studio:Example Studio")
        XCTAssertEqual(try store.resolvedTagIds(forVideo: v),
                       [TagNormalizer.identityKey("Climbing")])
    }

    // MARK: - ⚠️ The property step 5 depends on

    func testRetiringAPerformerStringChangesNothing() throws {
        try profile("actor:Alice Example"); try profile("actor:Bob Example")
        let v = try video(["actor:Alice Example", "actor:Bob Example"])
        try store.connectPerformerEdges()

        let before = try store.resolvedPerformerIds(forVideo: v)
        try retireStrings { $0.hasPrefix("actor:") }

        XCTAssertEqual(try store.resolvedPerformerIds(forVideo: v), before)
        XCTAssertEqual(try store.fetchAllAssets().first { $0.id == v }?.actors, [],
                       "the strings really are gone — the edges are carrying it")
    }

    func testRetiringAStudioStringChangesNothing() throws {
        try profile("studio:Example Studio")
        let v = try video(["studio:Example Studio"])
        try store.connectStudioEdges()

        try retireStrings { $0.hasPrefix("studio:") }

        XCTAssertEqual(try store.resolvedStudioId(forVideo: v), "studio:Example Studio")
    }

    func testRetiringATagStringChangesNothing() throws {
        try tag("Climbing", .action)
        let v = try video(["tag:Climbing"])
        try store.connectTagEdges()

        try retireStrings { $0.hasPrefix("tag:") }

        XCTAssertEqual(try store.resolvedTagIds(forVideo: v),
                       [TagNormalizer.identityKey("Climbing")])
    }

    // MARK: - Half-migrated

    /// The shape an interrupted run leaves: one credit connected, one not.
    /// Reading either half alone would under-report the cast.
    func testAPartiallyConnectedVideoStillReadsWhole() throws {
        try profile("actor:Alice Example"); try profile("actor:Bob Example")
        let v = try video(["actor:Alice Example", "actor:Bob Example"])
        try store.linkPerformer("actor:Alice Example", toVideo: v)

        XCTAssertEqual(try store.resolvedPerformerIds(forVideo: v),
                       ["actor:Alice Example", "actor:Bob Example"])
    }

    /// ⚠️ The same fact in both representations is ONE answer, not two. A
    /// filter that counted it twice would double every connected video's
    /// tallies for the whole length of the migration.
    func testAFactPresentInBothIsCountedOnce() throws {
        try profile("actor:Alice Example")
        try tag("Climbing", .action)
        let v = try video(["actor:Alice Example", "tag:Climbing"])
        try store.connectPerformerEdges()
        try store.connectTagEdges()

        XCTAssertEqual(try store.resolvedPerformerIds(forVideo: v).count, 1)
        XCTAssertEqual(try store.resolvedTagIds(forVideo: v).count, 1)
    }

    /// Two spellings of one tag are one tag — the same folding the vocabulary
    /// uses, applied to reads, so a case variant does not read as a second tag.
    func testTagSpellingVariantsResolveToOneTag() throws {
        try tag("Climbing", .action)
        let v = try video(["tag:Climbing", "tag:climbing"])

        XCTAssertEqual(try store.resolvedTagIds(forVideo: v).count, 1)
    }

    // MARK: - ⚠️ Where the union deliberately does not apply

    /// A conflicted video has no studio edge by design. Falling back to the
    /// strings would hand back an arbitrary one of the two — the exact choice
    /// the conflict gate exists to refuse.
    func testAConflictedVideoReadsAsNoStudioRatherThanAGuess() throws {
        try profile("studio:Example Studio"); try profile("studio:Other Studio")
        let v = try video(["studio:Example Studio", "studio:Other Studio"])
        try store.connectStudioEdges()

        XCTAssertNil(try store.resolvedStudioId(forVideo: v))
    }

    /// A staged tag is not attached to anything yet. Surfacing pending
    /// associations here would put the unclassified tag back on the video by a
    /// side door, undoing the staging.
    func testAStagedTagDoesNotReadAsAttached() throws {
        try tag("Unsorted", nil)
        let v = try video(["tag:Unsorted"])
        try store.connectTagEdges()
        XCTAssertEqual(try store.edgeCount(.pendingTagAssociation), 1)

        // Still visible via its string — that is what keeps it from vanishing —
        // but nothing has been attached.
        XCTAssertEqual(try store.tagIds(forVideo: v), [])
    }

    /// An attribute tag describes a person, so it is never on a video's edges.
    /// It also must not be retirable, because the string is the only surviving
    /// record that enrichment still owes this video a correction.
    func testAPerformerAttributeTagIsNotRetirableFromVideos() throws {
        try tag("Redhead", .performerAttribute)
        try video(["tag:Redhead"])
        try store.connectTagEdges()

        XCTAssertFalse(try store.canRetireStrings(
            forTag: TagNormalizer.identityKey("Redhead")))
    }

    // MARK: - The per-tag gate

    func testATagIsRetirableOnceEveryCarrierHasItsEdge() throws {
        try tag("Climbing", .action)
        try video(["tag:Climbing"]); try video(["tag:Climbing"])
        try store.connectTagEdges()

        XCTAssertTrue(try store.canRetireStrings(forTag: TagNormalizer.identityKey("Climbing")))
    }

    func testATagIsNotRetirableWhileOneCarrierLacksItsEdge() throws {
        try tag("Climbing", .action)
        try video(["tag:Climbing"])
        try store.connectTagEdges()
        try video(["tag:Climbing"])   // arrived after the connect run

        XCTAssertFalse(try store.canRetireStrings(forTag: TagNormalizer.identityKey("Climbing")))
    }

    func testAnUnclassifiedTagIsNotRetirable() throws {
        try tag("Unsorted", nil)
        try video(["tag:Unsorted"])
        try store.connectTagEdges()

        XCTAssertFalse(try store.canRetireStrings(forTag: TagNormalizer.identityKey("Unsorted")))
    }

    /// ⚠️ Per tag, not per library. One stubborn unclassified tag must not
    /// freeze the legacy representation for everything else, or the migration
    /// stalls short of the finish line and stays there.
    func testOneBlockedTagDoesNotBlockTheRest() throws {
        try tag("Climbing", .action)
        try tag("Unsorted", nil)
        try video(["tag:Climbing", "tag:Unsorted"])
        try store.connectTagEdges()

        XCTAssertTrue(try store.canRetireStrings(forTag: TagNormalizer.identityKey("Climbing")))
        XCTAssertFalse(try store.canRetireStrings(forTag: TagNormalizer.identityKey("Unsorted")))
    }
}
