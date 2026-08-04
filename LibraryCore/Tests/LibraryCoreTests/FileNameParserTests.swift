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
