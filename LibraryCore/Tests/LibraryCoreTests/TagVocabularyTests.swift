import XCTest
@testable import LibraryCore

final class TagVocabularyPersistenceTests: XCTestCase {

    private var libraryURL: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        libraryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TagVocabPersist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        store = try LibraryStore(at: libraryURL)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: libraryURL)
    }

    private func insert(_ tags: [String]) throws {
        try store.insertAsset(Asset(relativePath: "\(UUID()).mp4",
                                    fileName: "a.mp4", tags: tags))
    }

    func testPromotionDiscoversTheLibrarysTags() throws {
        try insert(["tag:Climbing", "actor:Alice Example"])
        try insert(["tag:Outdoors"])

        let new = try store.promoteTagVocabulary()

        XCTAssertEqual(Set(new.map(\.displayName)), ["Climbing", "Outdoors"])
        XCTAssertEqual(try store.fetchTagVocabulary().count, 2)
    }

    /// ⚠️ The property that matters most: re-running must never undo work.
    func testRepromotingDoesNotResetAClassification() throws {
        try insert(["tag:Climbing"])
        try store.promoteTagVocabulary()

        try store.saveTagRecord(TagRecord(displayName: "Climbing", kind: .action))
        let newlyFound = try store.promoteTagVocabulary()

        XCTAssertTrue(newlyFound.isEmpty, "nothing new to report")
        let stored = try XCTUnwrap(try store.fetchTagVocabulary().first)
        XCTAssertEqual(stored.resolvedKind(), TagKind.action,
                       "a re-run must not undo a classification")
        XCTAssertEqual(try store.fetchTagVocabulary().count, 1)
    }

    func testPromotionReportsOnlyWhatIsNew() throws {
        try insert(["tag:Climbing"])
        try store.promoteTagVocabulary()

        try insert(["tag:Outdoors"])
        let new = try store.promoteTagVocabulary()

        XCTAssertEqual(new.map(\.displayName), ["Outdoors"])
        XCTAssertEqual(try store.fetchTagVocabulary().count, 2)
    }

    /// The unique index is the last line of defence for the live case pair.
    func testCaseVariantsCannotBecomeTwoRows() throws {
        try insert(["tag:SCUBA"])
        try insert(["tag:Scuba"])

        try store.promoteTagVocabulary()

        XCTAssertEqual(try store.fetchTagVocabulary().count, 1,
                       "one tag, however it was spelled")
    }

    func testClassificationSurvivesAReopen() throws {
        try insert(["tag:Climbing"])
        try store.promoteTagVocabulary()
        try store.saveTagRecord(TagRecord(displayName: "Climbing", kind: .action))

        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        let reopened = try LibraryStore(at: libraryURL)

        XCTAssertEqual(try reopened.fetchTagVocabulary().first?.resolvedKind(),
                       TagKind.action)
    }
}

final class TagVocabularyTests: XCTestCase {

    private func asset(_ tags: [String]) -> Asset {
        Asset(relativePath: "a.mp4", fileName: "a.mp4", tags: tags)
    }

    // MARK: - Promotion

    func testEachDistinctTagBecomesOneRecord() {
        let records = TagVocabulary.promoting([
            asset(["tag:Outdoors", "tag:Climbing"]),
            asset(["tag:Outdoors"])
        ])

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Set(records.map(\.displayName)), ["Outdoors", "Climbing"])
    }

    /// The live defect: one tag stored under two casings became two things.
    func testCaseVariantsMergeIntoOneRecord() {
        let records = TagVocabulary.promoting([
            asset(["tag:SCUBA"]), asset(["tag:Scuba"]), asset(["tag:scuba"])
        ])

        XCTAssertEqual(records.count, 1, "three spellings, one tag")
    }

    /// 15 uses against 1 in the real library — showing the operator the rarer
    /// spelling would be a visible regression from what they typed most.
    func testTheMostUsedSpellingWinsTheDisplayName() {
        var assets = Array(repeating: asset(["tag:SCUBA"]), count: 15)
        assets.append(asset(["tag:Scuba"]))

        let records = TagVocabulary.promoting(assets)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.displayName, "SCUBA")
    }

    /// Dictionary iteration order is not stable across runs, so a tie must not
    /// be resolved by it — the same library has to promote the same way twice.
    /// With three or more casings the winner must be compared against its
    /// rivals, not against a running total — otherwise an early merge inflates
    /// one spelling and it wins on arithmetic rather than on use.
    func testTheMostUsedSpellingWinsAcrossThreeCasings() {
        var assets = Array(repeating: asset(["tag:scuba"]), count: 2)
        assets += Array(repeating: asset(["tag:Scuba"]), count: 3)
        assets += Array(repeating: asset(["tag:SCUBA"]), count: 9)

        let records = TagVocabulary.promoting(assets)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.displayName, "SCUBA")
    }

    /// The worklist should start where it matters most.
    func testPromotionOrdersByUseDescending() {
        var assets = [asset(["tag:Rare"])]
        assets += Array(repeating: asset(["tag:Common"]), count: 5)

        XCTAssertEqual(TagVocabulary.promoting(assets).map(\.displayName),
                       ["Common", "Rare"])
    }

    func testATieBreaksDeterministically() {
        let first = TagVocabulary.promoting([asset(["tag:SCUBA"]), asset(["tag:Scuba"])])
        let second = TagVocabulary.promoting([asset(["tag:Scuba"]), asset(["tag:SCUBA"])])

        XCTAssertEqual(first.first?.displayName, second.first?.displayName)
    }

    func testPromotedTagsStartUnclassified() {
        let records = TagVocabulary.promoting([asset(["tag:Outdoors"])])

        XCTAssertNil(records.first?.kind)
        XCTAssertEqual(TagVocabulary.unclassified(in: records).count, 1)
    }

    func testActorsAndStudiosAreNotTags() {
        let records = TagVocabulary.promoting([
            asset(["actor:Alice Example", "studio:Example Studio", "tag:Outdoors"])
        ])

        XCTAssertEqual(records.map(\.displayName), ["Outdoors"])
    }

    func testPromotionIsIdempotent() {
        let assets = [asset(["tag:Outdoors", "tag:Climbing"]), asset(["tag:Outdoors"])]

        XCTAssertEqual(TagVocabulary.promoting(assets).map(\.identityKey),
                       TagVocabulary.promoting(assets).map(\.identityKey))
    }

    // MARK: - Enforcement

    func testAnUnclassifiedTagAttachesToNothing() {
        let record = TagRecord(displayName: "Outdoors")

        XCTAssertFalse(TagVocabulary.canAttach(record, to: .video),
                       "unclassified is deliberately unusable")
        XCTAssertFalse(TagVocabulary.canAttach(record, to: .performer))
    }

    func testAPerformerAttributeCannotAttachToAVideo() {
        let record = TagRecord(displayName: "Redhead", kind: .performerAttribute)

        XCTAssertFalse(TagVocabulary.canAttach(record, to: .video),
                       "a video is not a redhead")
        XCTAssertTrue(TagVocabulary.canAttach(record, to: .performer))
    }

    func testAnActionCannotAttachToAPerformer() {
        let record = TagRecord(displayName: "Climbing", kind: .action)

        XCTAssertFalse(TagVocabulary.canAttach(record, to: .performer))
        XCTAssertTrue(TagVocabulary.canAttach(record, to: .video))
    }

    func testAVideoAttributeAttachesToAVideo() {
        let record = TagRecord(displayName: "Compilation", kind: .videoAttribute)

        XCTAssertTrue(TagVocabulary.canAttach(record, to: .video))
        XCTAssertFalse(TagVocabulary.canAttach(record, to: .performer))
    }

    /// A tag the vocabulary has never heard of is not a licence to attach.
    func testAnUnknownTagAttachesToNothing() {
        XCTAssertFalse(TagVocabulary.canAttach(nil, to: .video))
        XCTAssertFalse(TagVocabulary.canAttach(nil, to: .performer))
    }

    // MARK: - The write boundary

    private var vocabulary: [TagRecord] {
        [TagRecord(displayName: "Climbing", kind: .action),
         TagRecord(displayName: "Redhead", kind: .performerAttribute),
         TagRecord(displayName: "Compilation", kind: .videoAttribute),
         TagRecord(displayName: "Unsorted")]
    }

    func testAddingAnAttributeTagToAVideoIsRefused() {
        let before = asset([])
        let after = asset(["tag:Redhead"])

        XCTAssertEqual(
            TagVocabulary.disallowedAdditions(from: before, to: after, vocabulary: vocabulary),
            ["Redhead"])
    }

    func testAddingAnActionOrVideoAttributeToAVideoIsAllowed() {
        let after = asset(["tag:Climbing", "tag:Compilation"])

        XCTAssertTrue(
            TagVocabulary.disallowedAdditions(from: asset([]), to: after,
                                              vocabulary: vocabulary).isEmpty)
    }

    func testAddingAnUnclassifiedTagIsRefused() {
        let after = asset(["tag:Unsorted"])

        XCTAssertEqual(
            TagVocabulary.disallowedAdditions(from: asset([]), to: after,
                                              vocabulary: vocabulary),
            ["Unsorted"])
    }

    /// ⚠️ The decision that keeps 31 real videos saveable. An attribute tag
    /// already on a video is left alone — enrichment corrects it later — so an
    /// unrelated edit to that video must not be blocked by it.
    func testAnAttributeTagAlreadyOnAVideoDoesNotBlockOtherEdits() {
        let before = asset(["tag:Redhead"])
        var after = before
        after.rating = 5
        after.tags = before.tags + ["tag:Climbing"]

        XCTAssertTrue(
            TagVocabulary.disallowedAdditions(from: before, to: after,
                                              vocabulary: vocabulary).isEmpty,
            "the pre-existing attribute tag must not make this video unsaveable")
    }

    /// Re-adding under a different casing is still not an addition.
    func testACaseVariantOfAnExistingTagIsNotAnAddition() {
        let before = asset(["tag:Redhead"])
        let after = asset(["tag:REDHEAD"])

        XCTAssertTrue(
            TagVocabulary.disallowedAdditions(from: before, to: after,
                                              vocabulary: vocabulary).isEmpty)
    }

    func testAddingAnActionTagToAPerformerIsRefused() {
        let before = EntityProfile(id: "actor:Alice Example")
        var after = before
        after.tags = ["Climbing"]

        XCTAssertEqual(
            TagVocabulary.disallowedAdditions(from: before, to: after, vocabulary: vocabulary),
            ["Climbing"])
    }

    func testAddingAnAttributeTagToAPerformerIsAllowed() {
        let before = EntityProfile(id: "actor:Alice Example")
        var after = before
        after.tags = ["Redhead"]

        XCTAssertTrue(
            TagVocabulary.disallowedAdditions(from: before, to: after,
                                              vocabulary: vocabulary).isEmpty)
    }

    /// A kind that is no longer defined must not silently become permissive.
    func testATagNamingARemovedKindAttachesToNothing() {
        var record = TagRecord(displayName: "Outdoors", kind: .action)
        record.kind = "a-kind-that-was-deleted"

        XCTAssertFalse(TagVocabulary.canAttach(record, to: .video))
        XCTAssertFalse(TagVocabulary.canAttach(record, to: .performer))
    }
}
