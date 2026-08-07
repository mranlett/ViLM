import XCTest
@testable import LibraryCore

/// Repairing a tag's spelling.
///
/// 🚨 Reported from the device as *"the spelling fix is not working"*. It was
/// not one bug but four, each of which independently reduced the repair to a
/// no-op — and every one of them still printed "Repaired N tags", because the
/// count came from the loop rather than from anything that happened.
///
///   1. The old spelling was NORMALIZED before being searched for, so the
///      lowercase `tag:pov` was looked up as `tag:Pov` and matched nothing.
///      The losing spelling in a case-collision is by definition the one that
///      is not canonical, so this removed exactly the rows being repaired.
///   2. A case-only repair normalized to the SAME string and returned early.
///   3. The chosen spelling was re-normalized, so `Point of View` was written
///      back as `Point Of View` — the tool overruling the answer it asked for.
///   4. The tag VOCABULARY was never touched, so the old spelling came back
///      from `tags` even when the videos had been rewritten.
final class TagSpellingRepairTests: XCTestCase {

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
    private func video(tags: [String]) throws -> Asset {
        let name = "\(UUID().uuidString).mp4"
        let asset = Asset(relativePath: name, fileName: name, tags: tags)
        try store.insertAsset(asset)
        return asset
    }

    private func tags(of asset: Asset) throws -> [String] {
        try XCTUnwrap(try store.fetchAllAssets().first { $0.id == asset.id }).tags
    }

    // MARK: - 1. The old spelling is matched as stored

    func testALowercaseSpellingIsFoundAndRepaired() throws {
        let asset = try video(tags: ["tag:pov"])

        let outcome = try store.renameTagGlobally(oldTag: "tag:pov", newTag: "tag:POV")

        XCTAssertEqual(try tags(of: asset), ["tag:POV"])
        XCTAssertEqual(outcome.videosChanged, 1)
    }

    /// Every casing in the library is repaired, not just the one that happened
    /// to match — the filters already treat these as one tag.
    func testEveryCasingOfTheSameTagIsRepaired() throws {
        let a = try video(tags: ["tag:pov"])
        let b = try video(tags: ["tag:Pov"])
        let c = try video(tags: ["tag:pOv"])

        let outcome = try store.renameTagGlobally(oldTag: "tag:pov", newTag: "tag:POV")

        XCTAssertEqual(try tags(of: a), ["tag:POV"])
        XCTAssertEqual(try tags(of: b), ["tag:POV"])
        XCTAssertEqual(try tags(of: c), ["tag:POV"])
        XCTAssertEqual(outcome.videosChanged, 3)
    }

    /// Two spellings on ONE video collapse to a single tag rather than a
    /// duplicate pair.
    func testTwoSpellingsOnOneVideoCollapseToOne() throws {
        let asset = try video(tags: ["tag:pov", "tag:POV", "tag:Outdoor"])

        try store.renameTagGlobally(oldTag: "tag:pov", newTag: "tag:POV")

        XCTAssertEqual(try tags(of: asset), ["tag:POV", "tag:Outdoor"])
    }

    // MARK: - 2. A case-only repair is real work

    func testACaseOnlyRepairIsNotTreatedAsANoOp() throws {
        let asset = try video(tags: ["tag:blonde"])

        let outcome = try store.renameTagGlobally(oldTag: "tag:blonde", newTag: "tag:Blonde")

        XCTAssertEqual(try tags(of: asset), ["tag:Blonde"])
        XCTAssertTrue(outcome.changedAnything)
    }

    /// A genuine no-op still reports doing nothing.
    func testRenamingATagToItselfChangesNothingAndSaysSo() throws {
        try video(tags: ["tag:Blonde"])

        let outcome = try store.renameTagGlobally(oldTag: "tag:Blonde", newTag: "tag:Blonde")

        XCTAssertFalse(outcome.changedAnything)
    }

    /// ⚠️ The report that made this invisible: a rename matching nothing must
    /// not read as success.
    func testARenameThatMatchesNothingReportsNoChange() throws {
        try video(tags: ["tag:Outdoor"])

        let outcome = try store.renameTagGlobally(oldTag: "tag:Nonexistent",
                                                  newTag: "tag:Something")

        XCTAssertFalse(outcome.changedAnything)
        XCTAssertEqual(outcome.videosChanged, 0)
    }

    // MARK: - 3. The chosen spelling is the answer

    /// ⭐ The small-words case, fixed without compiling a list of small words
    /// into the app — which this module's opening rule forbids.
    func testTheOperatorsChosenSpellingIsWrittenUnchanged() throws {
        let asset = try video(tags: ["tag:point of view"])

        try store.renameTagGlobally(oldTag: "tag:point of view",
                                    newTag: "tag:Point of View")

        XCTAssertEqual(try tags(of: asset), ["tag:Point of View"],
                       "not Point Of View — the tool must not overrule the choice")
    }

    /// Deliberate capitalization survives, as it always did.
    func testAnAcronymSurvivesTheRepair() throws {
        let asset = try video(tags: ["tag:scuba"])

        try store.renameTagGlobally(oldTag: "tag:scuba", newTag: "tag:SCUBA")

        XCTAssertEqual(try tags(of: asset), ["tag:SCUBA"])
    }

    /// Whitespace is still tidied — that is not a capitalization decision.
    func testSurroundingWhitespaceIsStillCleanedUp() throws {
        let asset = try video(tags: ["tag:pov"])

        try store.renameTagGlobally(oldTag: "tag:pov", newTag: "tag:  Point   of View  ")

        XCTAssertEqual(try tags(of: asset), ["tag:Point of View"])
    }

    // MARK: - 4. The vocabulary moves too

    func testTheVocabularySpellingIsUpdated() throws {
        try store.saveTagRecord(TagRecord(displayName: "pov"))

        let outcome = try store.renameTagGlobally(oldTag: "tag:pov", newTag: "tag:POV")

        let record = try store.fetchTagVocabulary().first { $0.identityKey == TagNormalizer.identityKey("pov") }
        XCTAssertEqual(record?.displayName, "POV",
                       "otherwise the old spelling comes straight back from the vocabulary")
        XCTAssertTrue(outcome.vocabularyRespelled)
    }

    /// A case-only repair keeps the tag's classification — same identity, so
    /// nothing about what it describes has changed.
    func testACaseOnlyRepairKeepsTheTagsKind() throws {
        try store.saveTagRecord(TagRecord(displayName: "pov", kind: .videoAttribute))

        try store.renameTagGlobally(oldTag: "tag:pov", newTag: "tag:POV")

        let record = try store.fetchTagVocabulary().first { $0.displayName == "POV" }
        XCTAssertEqual(record?.kind, TagKind.videoAttribute.name)
    }

    /// 🚨 A repair to a genuinely DIFFERENT tag must move the edges with it, or
    /// they strand on a vocabulary row that no longer exists.
    func testRenamingToADifferentTagMovesItsEdges() throws {
        let asset = try video(tags: [])
        try store.saveTagRecord(TagRecord(displayName: "Blond", kind: .videoAttribute))
        try store.linkTag(TagNormalizer.identityKey("Blond"), toVideo: asset.id)

        try store.renameTagGlobally(oldTag: "tag:Blond", newTag: "tag:Blonde")

        XCTAssertEqual(try store.tagIds(forVideo: asset.id),
                       [TagNormalizer.identityKey("Blonde")])
        XCTAssertNil(try store.fetchTagVocabulary().first { $0.displayName == "Blond" })
    }
}
