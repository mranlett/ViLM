import XCTest
@testable import LibraryCore

/// Reading a filename back into fields.
///
/// The governing rule is that POSITION is not evidence. The generator emits
/// Actors - Series - Tags - Studio with any section optional, so three segments
/// could be actors/series/tags or actors/tags/studio. Placing by position is how
/// a parser files a studio as a tag across a thousand records without anyone
/// noticing. The library's own vocabulary decides; anything it cannot place is
/// reported rather than forced into whichever slot is free.
final class FileNameParserTests: XCTestCase {

    private let vocabulary = NameVocabulary(
        actors: ["Alice Example", "Bob Example", "Carol Example"],
        studios: ["Example Pictures", "Second Studio"],
        tags: ["Outdoors", "Night"])

    private func parse(_ name: String) -> ParsedFileName {
        FileNameParser.parse(fileName: name, vocabulary: vocabulary)
    }

    // MARK: - The full shape

    func testAllFourSections() {
        let p = parse("Alice Example - Some Series S01E02 - Outdoors - Example Pictures.mp4")
        XCTAssertEqual(p.actors, ["Alice Example"])
        XCTAssertEqual(p.seriesBlock, "Some Series S01E02")
        XCTAssertEqual(p.tags, ["Outdoors"])
        XCTAssertEqual(p.studios, ["Example Pictures"])
        XCTAssertTrue(p.unrecognised.isEmpty)
    }

    /// The common real shape: the series block is the section usually missing.
    func testActorsTagsStudioWithNoSeries() {
        let p = parse("Alice Example - Outdoors - Example Pictures.mp4")
        XCTAssertEqual(p.actors, ["Alice Example"])
        XCTAssertEqual(p.tags, ["Outdoors"])
        XCTAssertEqual(p.studios, ["Example Pictures"])
        XCTAssertNil(p.seriesBlock, "nothing here is a series")
    }

    /// Same segment count as the case above, and a different reading. Only the
    /// vocabulary can tell them apart.
    func testSameShapeDifferentMeaning() {
        let p = parse("Alice Example - Outdoors - Night.mp4")
        XCTAssertEqual(p.tags, ["Outdoors", "Night"])
        XCTAssertTrue(p.studios.isEmpty, "position would have called Night a studio")
    }

    func testMultiplePerformers() {
        XCTAssertEqual(parse("Alice Example, Bob Example - Outdoors.mp4").actors,
                       ["Alice Example", "Bob Example"])
        XCTAssertEqual(parse("Alice Example and Bob Example - Outdoors.mp4").actors,
                       ["Alice Example", "Bob Example"])
    }

    // MARK: - Refusing to guess

    /// The property that matters most: an unknown word is reported, never
    /// filed. A wrong guess here is invisible and repeated across the library.
    func testUnknownSegmentsAreReportedNotFiled() {
        let p = parse("Someone Unknown - Mystery Thing.mp4")
        XCTAssertTrue(p.actors.isEmpty)
        XCTAssertTrue(p.tags.isEmpty)
        XCTAssertTrue(p.studios.isEmpty)
        XCTAssertEqual(p.unrecognised, ["Someone Unknown", "Mystery Thing"])
    }

    /// A single unplaced segment AFTER a recognised actor list is the series
    /// block — the one section that is free text and so can never be in any
    /// vocabulary.
    func testAFreeTextSegmentAfterActorsReadsAsTheSeries() {
        let p = parse("Alice Example - Some Series Episode 3.mp4")
        XCTAssertEqual(p.seriesBlock, "Some Series Episode 3")
        XCTAssertTrue(p.unrecognised.isEmpty)
    }

    /// But a free-text segment with no actors before it is claimed by nothing.
    func testAFreeTextSegmentWithNoActorsIsNotAssumedToBeASeries() {
        let p = parse("Mystery Thing.mp4")
        XCTAssertNil(p.seriesBlock)
        XCTAssertEqual(p.unrecognised, ["Mystery Thing"])
    }

    func testAMixedSegmentIsNotPlaced() {
        let p = parse("Alice Example, Not A Known Person - Outdoors.mp4")
        XCTAssertTrue(p.actors.isEmpty, "a partly-recognised list is not evidence")
        XCTAssertEqual(p.unrecognised, ["Alice Example, Not A Known Person"])
    }

    func testAnUnstructuredNameYieldsNothing() {
        let p = parse("IMG_4021.mp4")
        XCTAssertTrue(p.isEmpty)
        XCTAssertEqual(p.unrecognised, ["IMG_4021"])
    }

    func testConfidenceReflectsHowMuchWasPlaced() {
        XCTAssertEqual(parse("Alice Example - Outdoors - Example Pictures.mp4").confidence, 1.0)
        XCTAssertEqual(parse("IMG_4021.mp4").confidence, 0.0)
    }

    // MARK: - Round trip

    /// The parser is the inverse of the generator, so a name the generator
    /// produced must read back as the fields it was built from.
    func testRoundTripsWhatTheGeneratorProduces() throws {
        let asset = Asset(relativePath: "x.mp4", fileName: "x.mp4",
                          tags: ["actor:Alice Example", "tag:Outdoors",
                                 "studio:Example Pictures"])
        let generated = try XCTUnwrap(asset.suggestedFileNameFromTags)
        let parsed = FileNameParser.parse(fileName: generated, vocabulary: vocabulary)
        XCTAssertEqual(parsed.actors, ["Alice Example"])
        XCTAssertEqual(parsed.tags, ["Outdoors"])
        XCTAssertEqual(parsed.studios, ["Example Pictures"])
    }

    // MARK: - Applying

    /// Parsing is evidence about a file, not a correction of the operator's
    /// work. It adds; it never removes and never overwrites.
    func testOnlyMissingFieldsAreOffered() {
        let asset = Asset(relativePath: "x.mp4", fileName: "x.mp4",
                          tags: ["actor:Alice Example"], videoName: "My Own Series")
        var parsed = ParsedFileName()
        parsed.actors = ["Alice Example", "Bob Example"]
        parsed.studios = ["Example Pictures"]
        parsed.seriesBlock = "Something Else"

        let additions = FileNameParser.additions(for: asset, parsed: parsed)
        XCTAssertEqual(additions.tags.sorted(), ["actor:Bob Example", "studio:Example Pictures"])
        XCTAssertNil(additions.seriesBlock, "a series already entered is never replaced")
    }

    func testASeriesIsOfferedWhenTheRecordHasNone() {
        let asset = Asset(relativePath: "x.mp4", fileName: "x.mp4")
        var parsed = ParsedFileName()
        parsed.seriesBlock = "Some Series"
        XCTAssertEqual(FileNameParser.additions(for: asset, parsed: parsed).seriesBlock,
                       "Some Series")
    }

    // MARK: - Vocabulary

    func testVocabularyIsBuiltFromTheLibrary() {
        let vocab = NameVocabulary(assets: [
            Asset(relativePath: "a.mp4", fileName: "a.mp4",
                  tags: ["actor:Someone", "studio:Somewhere", "tag:Something"])
        ])
        XCTAssertTrue(vocab.actors.contains("someone"))
        XCTAssertTrue(vocab.studios.contains("somewhere"))
        XCTAssertTrue(vocab.tags.contains("something"))
    }

    func testMatchingIsCaseInsensitive() {
        let p = FileNameParser.parse(fileName: "alice example - OUTDOORS.mp4",
                                     vocabulary: vocabulary)
        XCTAssertEqual(p.actors, ["alice example"])
        XCTAssertEqual(p.tags, ["OUTDOORS"])
    }
}

/// Planning a review pass over the whole library.
extension FileNameParserTests {

    private var vocab: NameVocabulary {
        NameVocabulary(actors: ["Alice Example"], studios: ["Example Pictures"],
                       tags: ["Outdoors"])
    }

    func testFilesThatChangeNothingAreNotListed() {
        let already = Asset(relativePath: "a.mp4",
                            fileName: "Alice Example - Outdoors.mp4",
                            tags: ["actor:Alice Example", "tag:Outdoors"])
        XCTAssertTrue(FileNameParser.plan(assets: [already], vocabulary: vocab).isEmpty,
                      "a row that changes nothing buries the rows that do")
    }

    func testCleanestReadingsComeFirst() {
        // TWO unplaced segments: the single-unplaced case is claimed as the
        // series block by design, so it reads clean and is not a messy example.
        let messy = Asset(relativePath: "b.mp4",
                          fileName: "Who Is This - Something Unknown - Outdoors.mp4")
        let clean = Asset(relativePath: "c.mp4",
                          fileName: "Alice Example - Outdoors - Example Pictures.mp4")
        let plan = FileNameParser.plan(assets: [messy, clean], vocabulary: vocab)
        XCTAssertEqual(plan.first?.fileName, clean.fileName)
        XCTAssertTrue(plan.first?.isClean == true)
        XCTAssertFalse(plan.last?.isClean == true)
    }

    /// Unreadable names are a finding, not an absence.
    func testUnreadableNamesAreReportedSeparately() {
        let mystery = Asset(relativePath: "d.mp4", fileName: "IMG_4021.mp4")
        XCTAssertTrue(FileNameParser.plan(assets: [mystery], vocabulary: vocab).isEmpty)
        XCTAssertEqual(FileNameParser.unreadable(assets: [mystery], vocabulary: vocab).count, 1)
    }

    func testApplyingAddsOnlyWhatIsMissing() {
        let asset = Asset(relativePath: "e.mp4",
                          fileName: "Alice Example - Outdoors - Example Pictures.mp4",
                          tags: ["actor:Alice Example", "tag:Mine"])
        let plan = FileNameParser.plan(assets: [asset], vocabulary: vocab)
        let updated = FileNameParser.applying(plan[0], to: asset)
        XCTAssertTrue(updated.tags.contains("tag:Mine"), "existing tags survive")
        XCTAssertTrue(updated.studios.contains("Example Pictures"))
        XCTAssertEqual(updated.actors, ["Alice Example"], "no duplicate actor")
    }
}

/// Pooling the vocabulary across several libraries.
///
/// Reading one library at a time was wrong twice over: the other went
/// untouched, and the vocabulary came from a smaller pool — so a name the two
/// TOGETHER could explain was reported as unreadable.
extension FileNameParserTests {

    func testPooledVocabularyReadsWhatNeitherLibraryCouldAlone() {
        // One library knows the performer, the other knows the studio.
        let libraryA = [Asset(relativePath: "a.mp4", fileName: "a.mp4",
                              tags: ["actor:Alice Example"])]
        let libraryB = [Asset(relativePath: "b.mp4", fileName: "b.mp4",
                              tags: ["studio:Example Pictures"])]
        let subject = Asset(relativePath: "c.mp4",
                            fileName: "Alice Example - Example Pictures.mp4")

        let alone = FileNameParser.parse(fileName: subject.fileName,
                                         vocabulary: NameVocabulary(assets: libraryA))
        XCTAssertEqual(alone.studios, [], "library A has never heard of that studio")
        // A lone unplaced segment following a recognised actor is claimed as
        // the SERIES block — so on its own, library A files the studio as a
        // series name. Silently wrong, which is exactly why pooling matters.
        XCTAssertEqual(alone.seriesBlock, "Example Pictures")

        let pooled = FileNameParser.parse(fileName: subject.fileName,
                                          vocabulary: NameVocabulary(assets: libraryA + libraryB))
        XCTAssertEqual(pooled.actors, ["Alice Example"])
        XCTAssertEqual(pooled.studios, ["Example Pictures"])
        XCTAssertTrue(pooled.unrecognised.isEmpty, "together they explain the whole name")
    }
}

/// Why a "partly read" row is safe to accept in bulk.
extension FileNameParserTests {

    /// A partial reading offers ONLY vocabulary matches. The unplaced text is
    /// dropped, never guessed at — so its additions are exactly as trustworthy
    /// as a fully-read row's.
    func testPartialReadingsOfferOnlyRecognisedValues() {
        let vocab = NameVocabulary(actors: ["Alice Example"], studios: [], tags: ["Outdoors"])
        let parsed = FileNameParser.parse(
            fileName: "Alice Example - Who Knows - Outdoors - Mystery Studio.mp4",
            vocabulary: vocab)

        XCTAssertEqual(parsed.actors, ["Alice Example"])
        XCTAssertEqual(parsed.tags, ["Outdoors"])
        XCTAssertEqual(parsed.unrecognised, ["Who Knows", "Mystery Studio"])
        XCTAssertTrue(parsed.studios.isEmpty, "an unknown word is never filed as a studio")
        XCTAssertNil(parsed.seriesBlock, "and never inferred as a series either")
    }

    /// The inference rule fires ONLY when a single segment is unplaced — and
    /// such a row lands in the clean group. So no partial row ever contains a
    /// guessed value, which is what makes bulk acceptance safe.
    func testTheInferenceRuleNeverAppliesToAPartialReading() {
        let vocab = NameVocabulary(actors: ["Alice Example"])
        let oneUnplaced = FileNameParser.parse(fileName: "Alice Example - Some Series.mp4",
                                               vocabulary: vocab)
        XCTAssertNotNil(oneUnplaced.seriesBlock)
        XCTAssertTrue(oneUnplaced.unrecognised.isEmpty, "inferred ⇒ clean, not partial")

        let twoUnplaced = FileNameParser.parse(fileName: "Alice Example - A - B.mp4",
                                               vocabulary: vocab)
        XCTAssertNil(twoUnplaced.seriesBlock, "two unplaced ⇒ nothing is inferred")
        XCTAssertEqual(twoUnplaced.unrecognised.count, 2)
    }
}

/// Downloaded and hand-entered metadata outranks anything read from a filename.
extension FileNameParserTests {

    func testAFilenameNeverAddsASecondStudio() {
        // The record already knows the sub-studio that released it; the
        // filename only knows the parent brand.
        let asset = Asset(relativePath: "a.mp4",
                          fileName: "Alice Example - Example Brand.mp4",
                          tags: ["studio:Example Sub-Studio"])
        var parsed = ParsedFileName()
        parsed.studios = ["Example Brand"]

        let additions = FileNameParser.additions(for: asset, parsed: parsed)
        XCTAssertFalse(additions.tags.contains { $0.hasPrefix("studio:") },
                       "a recorded studio outranks the filename's")
    }

    func testAFilenameStudioIsUsedWhenTheRecordHasNone() {
        let asset = Asset(relativePath: "a.mp4", fileName: "Alice Example - Example Brand.mp4")
        var parsed = ParsedFileName()
        parsed.studios = ["Example Brand"]
        XCTAssertEqual(FileNameParser.additions(for: asset, parsed: parsed).tags,
                       ["studio:Example Brand"])
    }

    /// Cast and tags still accumulate — a video genuinely has several, and a
    /// name the record lacks is new information rather than a contradiction.
    func testCastAndTagsStillAccumulate() {
        let asset = Asset(relativePath: "a.mp4", fileName: "a.mp4",
                          tags: ["actor:Alice Example", "tag:Night"])
        var parsed = ParsedFileName()
        parsed.actors = ["Bob Example"]
        parsed.tags = ["Outdoors"]
        let additions = FileNameParser.additions(for: asset, parsed: parsed).tags
        XCTAssertTrue(additions.contains("actor:Bob Example"))
        XCTAssertTrue(additions.contains("tag:Outdoors"))
    }
}
