import XCTest
@testable import LibraryCore

/// Splitting a title into series / season / episode / name.
///
/// The examples are ordinary episodic media on purpose. The rules are not
/// specific to any genre or source, and the tests should read that way too.
final class MediaTitleParserTests: XCTestCase {

    // MARK: - Season and episode together

    func testSeasonAndEpisodeMarker() {
        let p = MediaTitleParser.parse("Seeing Red - S50:E30")
        XCTAssertEqual(p.seriesName, "Seeing Red")
        XCTAssertEqual(p.seasonNumber, 50)
        XCTAssertEqual(p.episodeNumber, 30)
        XCTAssertNil(p.title, "nothing followed the marker")
    }

    func testSeasonEpisodeWithTrailingTitle() {
        let p = MediaTitleParser.parse("The Office S02E01 Diversity Day")
        XCTAssertEqual(p.seriesName, "The Office")
        XCTAssertEqual(p.seasonNumber, 2)
        XCTAssertEqual(p.episodeNumber, 1)
        XCTAssertEqual(p.title, "Diversity Day")
    }

    // MARK: - A single index

    func testEpisodeKeyword() {
        let p = MediaTitleParser.parse("Star Wars - Episode 4 - A New Hope")
        XCTAssertEqual(p.seriesName, "Star Wars")
        XCTAssertEqual(p.episodeNumber, 4)
        XCTAssertEqual(p.title, "A New Hope")
    }

    /// The shape most scene records actually use.
    func testSceneKeyword() {
        let p = MediaTitleParser.parse("Night Shift - Scene 2 - Closing Time")
        XCTAssertEqual(p.seriesName, "Night Shift")
        XCTAssertEqual(p.episodeNumber, 2)
        XCTAssertEqual(p.title, "Closing Time")
    }

    /// Real records are punctuated inconsistently — a missing space before the
    /// dash must not change the reading.
    func testToleratesRaggedPunctuation() {
        let p = MediaTitleParser.parse("Weekend Away - Scene 2- Late Checkout")
        XCTAssertEqual(p.seriesName, "Weekend Away")
        XCTAssertEqual(p.episodeNumber, 2)
        XCTAssertEqual(p.title, "Late Checkout")
    }

    func testPartAndChapterAlsoCount() {
        XCTAssertEqual(MediaTitleParser.parse("Long Story Part 3").episodeNumber, 3)
        XCTAssertEqual(MediaTitleParser.parse("Long Story Chapter 12").episodeNumber, 12)
    }

    // MARK: - Numbered volumes

    func testNumberSignReadsAsTheVolume() {
        let p = MediaTitleParser.parse("Road Trip #02, Scene #02")
        XCTAssertEqual(p.seriesName, "Road Trip")
        XCTAssertEqual(p.seasonNumber, 2, "the volume within the line")
        XCTAssertEqual(p.episodeNumber, 2, "the scene within that volume")
    }

    /// ⚠️ A trailing digit IS read as a volume, and this is knowingly wrong for
    /// a series genuinely named "Catch 22".
    ///
    /// The operator's call, on the grounds that a number at the end of one of
    /// these titles is a volume far more often than it is part of the name —
    /// so the minority gets corrected by hand rather than the majority getting
    /// entered by hand.
    func testATrailingDigitIsReadAsAVolume() {
        let p = MediaTitleParser.parse("Catch 22 - Scene 3")
        XCTAssertEqual(p.seriesName, "Catch")
        XCTAssertEqual(p.seasonNumber, 22)
        XCTAssertEqual(p.episodeNumber, 3)
    }

    /// The case the policy is FOR: a numbered entry with its own title.
    func testANumberedEntryKeepsItsTitle() {
        let p = MediaTitleParser.parse("Star Wars 4 A New Hope")
        XCTAssertEqual(p.seriesName, "Star Wars")
        XCTAssertEqual(p.seasonNumber, 4)
        XCTAssertEqual(p.title, "A New Hope")
    }

    func testABareTrailingNumberNeedsNoTitle() {
        let p = MediaTitleParser.parse("Road Trip 12")
        XCTAssertEqual(p.seriesName, "Road Trip")
        XCTAssertEqual(p.seasonNumber, 12)
        XCTAssertNil(p.title)
    }

    /// ⚠️ The guard that keeps the policy from eating dates: a year is not a
    /// plausible volume, so it is left in the name.
    func testAYearIsNotAVolume() {
        let p = MediaTitleParser.parse("Anniversary 1999")
        XCTAssertNil(p.seasonNumber)
        XCTAssertEqual(p.title, "Anniversary 1999")
    }

    func testLeadingNumberSignIsATitleNotStructure() {
        let p = MediaTitleParser.parse("#1 Fan")
        XCTAssertEqual(p.title, "#1 Fan")
        XCTAssertFalse(p.isStructured, "nothing precedes the number, so it is not a series")
    }

    // MARK: - Refusing to guess

    /// The rule that matters most. Dashes are punctuation far more often than
    /// structure, and a wrong split rewrites two fields on a record that was
    /// already right.
    func testBareDashIsNeverASeparator() {
        let p = MediaTitleParser.parse("Eat - Pray - Love")
        XCTAssertEqual(p.title, "Eat - Pray - Love")
        XCTAssertNil(p.seriesName)
        XCTAssertNil(p.episodeNumber)
    }

    func testPlainTitlePassesThroughUntouched() {
        let p = MediaTitleParser.parse("A Quiet Arrangement")
        XCTAssertEqual(p.title, "A Quiet Arrangement")
        XCTAssertFalse(p.isStructured)
    }

    func testColonTitleIsNotSplit() {
        let p = MediaTitleParser.parse("Riverside Crossing: A Winter Tale")
        XCTAssertEqual(p.title, "Riverside Crossing: A Winter Tale")
        XCTAssertNil(p.seriesName)
    }

    /// Years, resolutions and catalogue ids sit next to keywords and are not
    /// episode numbers.
    func testImplausiblyLargeNumbersAreIgnored() {
        let p = MediaTitleParser.parse("Documentary Part 2019")
        XCTAssertNil(p.episodeNumber)
        XCTAssertEqual(p.title, "Documentary Part 2019")
    }

    func testEmptyInput() {
        let p = MediaTitleParser.parse("   ")
        XCTAssertNil(p.title)
        XCTAssertFalse(p.isStructured)
    }

    // MARK: - Catalogue codes

    /// Some records carry only the distributor's serial as the title.
    /// Proposing that as an episode name replaces a real name with a
    /// meaningless one, so callers need to be able to spot it.
    func testRecognisesBareCatalogueCodes() {
        XCTAssertTrue(MediaTitleParser.isBareCatalogueCode("ABCD-373"))
        XCTAssertTrue(MediaTitleParser.isBareCatalogueCode("EFGHI-608"))
        XCTAssertTrue(MediaTitleParser.isBareCatalogueCode("JKLM-761"))
        XCTAssertTrue(MediaTitleParser.isBareCatalogueCode("11510923"))
    }

    func testRealTitlesAreNotMistakenForCodes() {
        XCTAssertFalse(MediaTitleParser.isBareCatalogueCode("Just Rivals"))
        XCTAssertFalse(MediaTitleParser.isBareCatalogueCode("A New Hope"))
        XCTAssertFalse(MediaTitleParser.isBareCatalogueCode("Star Wars - Episode 4"))
        XCTAssertFalse(MediaTitleParser.isBareCatalogueCode(""))
    }
}

/// The release date must survive a round-trip through the database.
///
/// A field added to `Asset` has three places to reach: the memberwise init, the
/// coding keys, and the custom `init(from:)`. Missing the third compiles
/// cleanly and silently returns nil on every load — the same failure that cost
/// this project AKAs, career span, enrichment state and links.
final class AssetReleaseDateTests: XCTestCase {

    func testReleaseDateSurvivesACodingRoundTrip() throws {
        let asset = Asset(relativePath: "a.mp4", fileName: "a.mp4", releaseDate: "2024-05-30")
        let data = try JSONEncoder().encode(asset)
        let decoded = try JSONDecoder().decode(Asset.self, from: data)
        XCTAssertEqual(decoded.releaseDate, "2024-05-30")
    }

    func testAbsentReleaseDateDecodesAsNilRatherThanFailing() throws {
        let asset = Asset(relativePath: "a.mp4", fileName: "a.mp4")
        let decoded = try JSONDecoder().decode(Asset.self, from: JSONEncoder().encode(asset))
        XCTAssertNil(decoded.releaseDate)
    }
}
