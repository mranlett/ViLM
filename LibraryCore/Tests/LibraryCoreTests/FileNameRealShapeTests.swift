import XCTest
@testable import LibraryCore

/// Filename shapes taken from a real 2,104-video library.
///
/// The names are invented; the SHAPES are not. Each came from counting the
/// actual collection, and three of them are cases nobody would think to write
/// from imagination — which is the point. The parser's earlier tests all used
/// names I made up, and made-up names are tidy in exactly the ways real ones
/// are not.
///
/// Distribution measured across 2,104 records:
///   28 sparse (a single segment)
///   150 rich (four or more)
///   115 where the database knows something the filename never says
final class FileNameRealShapeTests: XCTestCase {

    /// What such a library holds after a round of matching.
    private let vocabulary = NameVocabulary(
        actors: ["Alice Example", "Bob Example", "Carol Example", "Dana Example"],
        studios: ["Example Studio", "Second Studio"],
        tags: ["Outdoors", "Night"])

    private func parse(_ name: String) -> ParsedFileName {
        FileNameParser.parse(fileName: name, vocabulary: vocabulary)
    }

    // MARK: - Sparse

    /// 28 of 2,104. Nothing to work with, and it must say so rather than
    /// inventing a reading.
    func testASingleSegmentYieldsNothingRatherThanAGuess() {
        let parsed = parse("Some Untitled Recording.mp4")
        XCTAssertTrue(parsed.isEmpty)
        XCTAssertNil(parsed.seriesBlock, "one segment is not a series")
        XCTAssertEqual(parsed.unrecognised, ["Some Untitled Recording"])
    }

    func testABareActorNameStillReads() {
        let parsed = parse("Alice Example.mp4")
        XCTAssertEqual(parsed.actors, ["Alice Example"])
        XCTAssertNil(parsed.seriesBlock)
    }

    // MARK: - Rich

    /// 150 of 2,104 carry all four sections.
    func testTheFullFourSectionShape() {
        let parsed = parse("Alice Example, Bob Example - The Long Weekend - Outdoors - Example Studio.mp4")
        XCTAssertEqual(parsed.actors, ["Alice Example", "Bob Example"])
        XCTAssertEqual(parsed.seriesBlock, "The Long Weekend")
        XCTAssertEqual(parsed.tags, ["Outdoors"])
        XCTAssertEqual(parsed.studios, ["Example Studio"])
        XCTAssertTrue(parsed.unrecognised.isEmpty)
    }

    // MARK: - Where the record knows more than the name

    /// Real shape: "Alice Example - Example Studio.mp4" where the database also holds a
    /// second performer the filename never mentions. Parsing is evidence about
    /// a FILE — it must never subtract from what the record already knows.
    func testAParseNeverRemovesCastTheFilenameOmits() {
        let asset = Asset(relativePath: "a.mp4",
                          fileName: "Alice Example - Example Studio.mp4",
                          tags: ["actor:Alice Example", "actor:Bob Example",
                                 "studio:Example Studio"])
        let parsed = parse(asset.fileName)
        let additions = FileNameParser.additions(for: asset, parsed: parsed)
        XCTAssertTrue(additions.tags.isEmpty, "nothing new, and nothing taken away")

        let applied = FileNameParser.applying(
            FileNameProposal(assetId: asset.id, fileName: asset.fileName, parsed: parsed,
                             additions: additions.tags, seriesBlock: additions.seriesBlock),
            to: asset)
        XCTAssertEqual(applied.actors.sorted(), ["Alice Example", "Bob Example"],
                       "the performer only the database knew is still there")
    }

    /// Real shape: the filename says "Example" where the database records
    /// "Example Studio". A short form of a recorded studio must not become a
    /// SECOND studio — the precedence rule, arriving from the filename side.
    func testAShortFormStudioDoesNotBecomeASecondStudio() {
        let asset = Asset(relativePath: "a.mp4",
                          fileName: "Alice Example - Example.mp4",
                          tags: ["actor:Alice Example", "studio:Example Studio"])
        let parsed = parse(asset.fileName)
        let additions = FileNameParser.additions(for: asset, parsed: parsed)
        XCTAssertFalse(additions.tags.contains { $0.hasPrefix("studio:") },
                       "a recorded studio outranks anything the filename says")

        let applied = FileNameParser.applying(
            FileNameProposal(assetId: asset.id, fileName: asset.fileName, parsed: parsed,
                             additions: additions.tags, seriesBlock: additions.seriesBlock),
            to: asset)
        XCTAssertEqual(applied.studios, ["Example Studio"], "exactly one studio")
    }

    /// Real shape: "Alice Example Bob Example - Example.mp4" — two performers
    /// run together with no separator at all. There is no honest way to split
    /// that, and guessing a boundary invents a person. It must land in
    /// `unrecognised` rather than becoming one wrong name or two.
    func testTwoNamesRunTogetherAreNotSplitOnAGuess() {
        let parsed = parse("Alice Example Bob Example - Example Studio.mp4")
        XCTAssertTrue(parsed.actors.isEmpty, "no boundary is inferred")
        XCTAssertEqual(parsed.unrecognised, ["Alice Example Bob Example"])
        XCTAssertEqual(parsed.studios, ["Example Studio"], "the rest still reads")
    }

    /// The same shape once someone has corrected it by hand: the vocabulary now
    /// contains the combined string, and the next pass reads it. This is why
    /// the tool tells you to run it again.
    func testACorrectionTeachesTheNextPass() {
        let taught = NameVocabulary(actors: ["Alice Example Bob Example"],
                                    studios: ["Example Studio"])
        let parsed = FileNameParser.parse(fileName: "Alice Example Bob Example - Example Studio.mp4",
                                          vocabulary: taught)
        XCTAssertEqual(parsed.actors, ["Alice Example Bob Example"])
        XCTAssertTrue(parsed.unrecognised.isEmpty)
    }

    // MARK: - Punctuation the real collection actually contains

    /// Real shape: "Alice Example Bob Example-  2 the return - Example.mp4" —
    /// a hyphen with no leading space, then a doubled space. The separator is
    /// " - " exactly, so this is ONE segment, not two.
    func testARaggedHyphenIsNotASeparator() {
        let parsed = parse("Alice Example-  2 the return - Example Studio.mp4")
        XCTAssertEqual(parsed.studios, ["Example Studio"])
        XCTAssertTrue(parsed.actors.isEmpty,
                      "the first segment is 'Alice Example-  2 the return', which is nobody")
    }

    func testAnUnseparatedListStillReadsWhenCommaDelimited() {
        XCTAssertEqual(parse("Alice Example, Bob Example - Outdoors.mp4").actors,
                       ["Alice Example", "Bob Example"])
        XCTAssertEqual(parse("Alice Example and Bob Example - Outdoors.mp4").actors,
                       ["Alice Example", "Bob Example"])
    }
}
