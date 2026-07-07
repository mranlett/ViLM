import XCTest
@testable import LibraryCore

final class SeriesEpisodeTests: XCTestCase {

    private func asset(
        series: String? = nil,
        season: Int? = nil,
        episodeNumber: Int? = nil,
        episodeTitle: String? = nil,
        tags: [String] = []
    ) -> Asset {
        Asset(
            relativePath: "v.mp4",
            fileName: "v.mp4",
            tags: tags,
            videoName: series,
            seasonNumber: season,
            episodeNumber: episodeNumber,
            episode: episodeTitle
        )
    }

    func testTitleBlockStandalone() {
        XCTAssertEqual(asset(series: "Parker in the Park").seriesTitleBlock, "Parker in the Park")
    }

    func testTitleBlockMovieNumber() {
        XCTAssertEqual(asset(series: "Star Wars", season: 3).seriesTitleBlock, "Star Wars 3")
    }

    func testTitleBlockEpisodeOnly() {
        XCTAssertEqual(asset(series: "Spiderman and Friends", episodeNumber: 6).seriesTitleBlock,
                       "Spiderman and Friends Episode 6")
    }

    func testTitleBlockSeasonAndEpisode() {
        XCTAssertEqual(asset(series: "Training", season: 2, episodeNumber: 12).seriesTitleBlock,
                       "Training 2 Episode 12")
    }

    func testTitleBlockEverything() {
        let block = asset(series: "Married with Children", season: 4, episodeNumber: 6, episodeTitle: "The Wedding").seriesTitleBlock
        XCTAssertEqual(block, "Married with Children 4 Episode 6 The Wedding")
    }

    func testTitleBlockEmpty() {
        XCTAssertEqual(asset().seriesTitleBlock, "")
    }

    // MARK: - Filename assembly

    func testFilenameStandalone() {
        XCTAssertEqual(asset(series: "Parker in the Park").suggestedFileNameFromTags,
                       "Parker in the Park.mp4")
    }

    func testFilenameEverything() {
        let a = asset(
            series: "Married with Children",
            season: 4,
            episodeNumber: 6,
            episodeTitle: "The Wedding",
            tags: ["actor:Al Bundy", "actor:Peg", "tag:Comedy", "studio:Fox"]
        )
        XCTAssertEqual(a.suggestedFileNameFromTags,
                       "Al Bundy, Peg - Married with Children 4 Episode 6 The Wedding - Comedy - Fox.mp4")
    }

    func testFilenameSeasonEpisodeNoActors() {
        XCTAssertEqual(asset(series: "Training", season: 2, episodeNumber: 12).suggestedFileNameFromTags,
                       "Training 2 Episode 12.mp4")
    }

    func testFilenameActorsAndSeriesOnly() {
        let a = asset(series: "Star Wars", season: 3, tags: ["actor:Luke"])
        XCTAssertEqual(a.suggestedFileNameFromTags, "Luke - Star Wars 3.mp4")
    }

    func testFilenameNilWhenNoMetadata() {
        XCTAssertNil(asset().suggestedFileNameFromTags)
    }
}
