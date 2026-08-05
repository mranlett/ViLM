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

    // MARK: - The worklist

    func testUnclassifiedTagsComeFirst() {
        let assets = [asset(["tag:Climbing", "tag:Unsorted"])]
        let vocab = [TagRecord(displayName: "Climbing", kind: .action),
                     TagRecord(displayName: "Unsorted")]

        let items = TagVocabulary.worklist(assets: assets, vocabulary: vocab)

        XCTAssertEqual(items.map(\.record.displayName), ["Unsorted", "Climbing"],
                       "the work comes first")
    }

    func testWithinAGroupTheMostUsedComesFirst() {
        var assets = Array(repeating: asset(["tag:Common"]), count: 5)
        assets.append(asset(["tag:Rare"]))
        let vocab = [TagRecord(displayName: "Rare"), TagRecord(displayName: "Common")]

        let items = TagVocabulary.worklist(assets: assets, vocabulary: vocab)

        XCTAssertEqual(items.map(\.record.displayName), ["Common", "Rare"])
        XCTAssertEqual(items.first?.uses, 5)
    }

    /// Merged spellings are surfaced so the operator can pick a different
    /// display name rather than discovering the merge later.
    func testMergedSpellingsAreReported() {
        let assets = [asset(["tag:SCUBA"]), asset(["tag:Scuba"])]
        let vocab = [TagRecord(displayName: "SCUBA")]

        let item = try? XCTUnwrap(
            TagVocabulary.worklist(assets: assets, vocabulary: vocab).first)

        XCTAssertEqual(item?.spellings, ["SCUBA", "Scuba"])
        XCTAssertEqual(item?.uses, 2, "both spellings count toward the same tag")
    }

    /// `uses` means videos, not tag strings. One asset carrying two casings of
    /// the same tag is one video using it, not two.
    func testUsesCountsVideosNotStrings() {
        let doubled = asset(["tag:SCUBA", "tag:Scuba"])
        let vocab = [TagRecord(displayName: "SCUBA")]

        let item = TagVocabulary.worklist(assets: [doubled], vocabulary: vocab).first

        XCTAssertEqual(item?.uses, 1, "one video, however many spellings it carries")
        XCTAssertEqual(item?.spellings, ["SCUBA", "Scuba"], "but both spellings are reported")
    }

    /// ⚠️ The worklist must not pre-select. Ordering helps; choosing does not.
    func testTheWorklistNeverPreSelectsAKind() {
        let vocab = [TagRecord(displayName: "Unsorted")]

        let items = TagVocabulary.worklist(assets: [asset(["tag:Unsorted"])],
                                           vocabulary: vocab)

        XCTAssertNil(items.first?.record.kind)
        XCTAssertFalse(items.first?.isClassified ?? true)
    }

    func testATagNoLongerUsedIsReportedNotRemoved() {
        let vocab = [TagRecord(displayName: "Gone", kind: .action)]

        let items = TagVocabulary.worklist(assets: [], vocabulary: vocab)

        XCTAssertEqual(TagVocabulary.unused(in: items).map(\.record.displayName), ["Gone"])
        XCTAssertEqual(items.first?.record.resolvedKind(), TagKind.action,
                       "a tag falling to zero uses keeps its classification")
    }

    // MARK: - Canonical spellings for display

    /// The defect the operator found: two casings rendered as two tags in the
    /// gallery, because every listing surface derives its own set from raw
    /// strings and never asks the vocabulary.
    func testTwoCasingsCollapseToOneDisplayName() {
        let map = TagVocabulary.canonicalSpellings(["GROUP", "GROUP", "GROUP"])

        XCTAssertEqual(map["GROUP"], "GROUP")
        XCTAssertEqual(map["GROUP"], "GROUP", "the rarer casing displays as the common one")
        XCTAssertEqual(Set(map.values).count, 1, "one tag, one display name")
    }

    func testASingleSpellingMapsToItself() {
        let map = TagVocabulary.canonicalSpellings(["Outdoors", "Climbing"])

        XCTAssertEqual(map["Outdoors"], "Outdoors")
        XCTAssertEqual(map["Climbing"], "Climbing")
    }

    /// The operator's stored choice outranks a head-count.
    func testTheVocabularysDisplayNameWinsOverUsage() {
        let map = TagVocabulary.canonicalSpellings(
            ["GROUP", "GROUP", "GROUP", "GROUP"],
            preferring: [TagRecord(displayName: "GROUP")])

        XCTAssertEqual(map["GROUP"], "GROUP")
        XCTAssertEqual(map["GROUP"], "GROUP")
    }

    func testCanonicalSpellingsAreStableAcrossOrderings() {
        let a = TagVocabulary.canonicalSpellings(["GROUP", "GROUP"])
        let b = TagVocabulary.canonicalSpellings(["GROUP", "GROUP"])

        XCTAssertEqual(a["GROUP"], b["GROUP"])
        XCTAssertEqual(a["GROUP"], b["GROUP"])
    }

    func testUnrelatedTagsAreNotMerged() {
        let map = TagVocabulary.canonicalSpellings(["Climbing", "Climbdown"])

        XCTAssertEqual(Set(map.values), ["Climbing", "Climbdown"])
    }

    // MARK: - The write check (what actually gates a save)

    /// ⚠️ The deadlock the check exists to avoid: refusing unclassified tags
    /// would mean no new tag could ever be created — it cannot be classified
    /// until it exists, and cannot exist until it is classified.
    func testANewUnknownTagIsAllowedAndReported() {
        let check = TagVocabulary.check(adding: asset(["tag:BrandNew"]),
                                        against: asset([]),
                                        vocabulary: vocabulary)

        XCTAssertTrue(check.isAllowed, "a new tag must be creatable")
        XCTAssertEqual(check.unclassified, ["BrandNew"], "and must reach the worklist")
    }

    func testAKnownButUnclassifiedTagIsAllowedAndReported() {
        let check = TagVocabulary.check(adding: asset(["tag:Unsorted"]),
                                        against: asset([]),
                                        vocabulary: vocabulary)

        XCTAssertTrue(check.isAllowed)
        XCTAssertEqual(check.unclassified, ["Unsorted"])
    }

    /// The rule that actually protects the graph.
    func testAPerformerAttributeIsRefusedOnAVideo() {
        let check = TagVocabulary.check(adding: asset(["tag:Redhead"]),
                                        against: asset([]),
                                        vocabulary: vocabulary)

        XCTAssertFalse(check.isAllowed)
        XCTAssertEqual(check.refused, ["Redhead"])
    }

    func testActionAndVideoAttributeAreAllowedOnAVideo() {
        let check = TagVocabulary.check(adding: asset(["tag:Climbing", "tag:Compilation"]),
                                        against: asset([]),
                                        vocabulary: vocabulary)

        XCTAssertTrue(check.isAllowed)
        XCTAssertTrue(check.unclassified.isEmpty)
    }

    /// The 31 videos already carrying an attribute tag stay editable.
    func testAPreExistingAttributeTagDoesNotBlockAnEdit() {
        let before = asset(["tag:Redhead"])
        let after = asset(["tag:Redhead", "tag:Climbing"])

        let check = TagVocabulary.check(adding: after, against: before,
                                        vocabulary: vocabulary)

        XCTAssertTrue(check.isAllowed, "what is already there is not re-judged")
        XCTAssertTrue(check.refused.isEmpty)
    }

    func testAnActionIsRefusedOnAPerformer() {
        let before = EntityProfile(id: "actor:Alice Example")
        var after = before
        after.tags = ["Climbing"]

        let check = TagVocabulary.check(adding: after, against: before,
                                        vocabulary: vocabulary)

        XCTAssertEqual(check.refused, ["Climbing"])
    }

    func testAnAttributeIsAllowedOnAPerformer() {
        let before = EntityProfile(id: "actor:Alice Example")
        var after = before
        after.tags = ["Redhead"]

        XCTAssertTrue(TagVocabulary.check(adding: after, against: before,
                                          vocabulary: vocabulary).isAllowed)
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
