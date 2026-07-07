import XCTest
@testable import LibraryCore

final class EpisodeParserTests: XCTestCase {

    func testSeasonEpisodeCompact() {
        XCTAssertEqual(EpisodeParser.parse("S2E3"), .init(season: 2, episode: 3, isConfident: true))
        XCTAssertEqual(EpisodeParser.parse("s02e03"), .init(season: 2, episode: 3, isConfident: true))
    }

    func testCrossNotation() {
        XCTAssertEqual(EpisodeParser.parse("2x12"), .init(season: 2, episode: 12, isConfident: true))
    }

    func testSeasonWordEpisodeWord() {
        XCTAssertEqual(EpisodeParser.parse("Season 2 Episode 3"), .init(season: 2, episode: 3, isConfident: true))
    }

    func testOverloadedSeasonEpisode() {
        XCTAssertEqual(EpisodeParser.parse("2 Episode 12"), .init(season: 2, episode: 12, isConfident: true))
    }

    func testEpisodeOnly() {
        XCTAssertEqual(EpisodeParser.parse("Episode 12"), .init(episode: 12, isConfident: true))
        XCTAssertEqual(EpisodeParser.parse("Ep 12"), .init(episode: 12, isConfident: true))
        XCTAssertEqual(EpisodeParser.parse("E12"), .init(episode: 12, isConfident: true))
    }

    func testSeasonOnly() {
        XCTAssertEqual(EpisodeParser.parse("Season 4"), .init(season: 4, isConfident: true))
    }

    func testBareNumberIsEpisode() {
        XCTAssertEqual(EpisodeParser.parse("12"), .init(episode: 12, isConfident: true))
    }

    func testTwoBareNumbersAreAmbiguous() {
        let r = EpisodeParser.parse("2 12")
        XCTAssertEqual(r.season, 2)
        XCTAssertEqual(r.episode, 12)
        XCTAssertFalse(r.isConfident)
    }

    func testFreeformKeptAsTitleAndFlagged() {
        let r = EpisodeParser.parse("Valentine's Day")
        XCTAssertEqual(r.title, "Valentine's Day")
        XCTAssertNil(r.season)
        XCTAssertNil(r.episode)
        XCTAssertFalse(r.isConfident)
    }

    func testEmptyIsConfidentlyEmpty() {
        XCTAssertEqual(EpisodeParser.parse("  "), .init(isConfident: true))
    }
}
