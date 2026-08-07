import XCTest
@testable import LibraryCore

/// Triaging series names before removing them in bulk.
///
/// This screen deletes, and series is the one entity with no node, no
/// provenance and no undo — so the rules about what is offered and what is
/// touched carry more weight than usual.
final class SeriesNameAuditTests: XCTestCase {

    private func asset(series: String?, matched: Bool = false,
                       season: Int? = nil, episode: Int? = nil,
                       title: String? = nil) -> Asset {
        var a = Asset(relativePath: "\(UUID()).mp4", fileName: "a.mp4", tags: [])
        a.videoName = series
        a.seasonNumber = season
        a.episodeNumber = episode
        a.episode = title
        a.enrichmentState = matched ? .matched : nil
        return a
    }

    // MARK: - Usage

    func testNamesAreCountedByVideo() {
        let usage = SeriesNameAudit.usage(in: [
            asset(series: "Kept"), asset(series: "Kept"), asset(series: "Stray"),
        ])

        XCTAssertEqual(usage.map(\.name), ["Kept", "Stray"])
        XCTAssertEqual(usage.map(\.videoCount), [2, 1])
    }

    /// Most-used first: this screen deletes, so the entries most likely worth
    /// keeping should be visible without scrolling.
    func testMostUsedLeads() {
        var assets = [Asset](repeating: asset(series: "Big"), count: 5)
        assets.append(asset(series: "Small"))

        XCTAssertEqual(SeriesNameAudit.usage(in: assets).first?.name, "Big")
    }

    func testTiesOrderAlphabetically() {
        let usage = SeriesNameAudit.usage(in: [asset(series: "Beta"), asset(series: "Alpha")])
        XCTAssertEqual(usage.map(\.name), ["Alpha", "Beta"])
    }

    func testVideosWithNoSeriesAreIgnored() {
        let usage = SeriesNameAudit.usage(in: [asset(series: nil), asset(series: "   ")])
        XCTAssertTrue(usage.isEmpty)
    }

    /// ⚠️ A hint, not provenance — the column does not record who wrote it.
    func testMatchedCountIsReportedSeparatelyFromTheTotal() {
        let usage = SeriesNameAudit.usage(in: [
            asset(series: "Mixed", matched: true),
            asset(series: "Mixed", matched: false),
        ])

        XCTAssertEqual(usage.first?.videoCount, 2)
        XCTAssertEqual(usage.first?.matchedCount, 1)
    }

    /// A series exists to group videos, so one grouping nothing is usually not
    /// a series — the strongest signal available for a title that leaked in.
    func testASingleUseNameIsFlagged() {
        let usage = SeriesNameAudit.usage(in: [
            asset(series: "Once"), asset(series: "Twice"), asset(series: "Twice"),
        ])

        XCTAssertTrue(usage.first(where: { $0.name == "Once" })?.isSingleUse ?? false)
        XCTAssertFalse(usage.first(where: { $0.name == "Twice" })?.isSingleUse ?? true)
    }

    // MARK: - What would change

    func testAffectedAssetsAreOnlyThoseCarryingTheChosenNames() {
        let assets = [asset(series: "Go"), asset(series: "Stay"), asset(series: "Go")]
        let affected = SeriesNameAudit.affectedAssets(in: assets, clearing: ["Go"])

        XCTAssertEqual(affected.count, 2)
        XCTAssertTrue(affected.allSatisfy { $0.videoName == "Go" })
    }

    func testNothingChosenAffectsNothing() {
        XCTAssertTrue(SeriesNameAudit.affectedAssets(in: [asset(series: "Any")],
                                                     clearing: []).isEmpty)
    }

    // MARK: - 🚨 What is actually cleared

    /// The operator's case: a series name set BY HAND so episode numbers sort.
    /// Removing the name must not take the numbering with it by default.
    func testClearingASeriesKeepsEpisodeInfoByDefault() {
        let cleared = SeriesNameAudit.cleared(
            asset(series: "Grouping", season: 2, episode: 7, title: "Something"),
            includingEpisodeInfo: false)

        XCTAssertNil(cleared.videoName)
        XCTAssertEqual(cleared.seasonNumber, 2)
        XCTAssertEqual(cleared.episodeNumber, 7)
        XCTAssertEqual(cleared.episode, "Something")
    }

    /// Opted into explicitly, for the case where a bad match wrote the whole
    /// block and all of it is wrong.
    func testEpisodeInfoIsClearedOnlyWhenAsked() {
        let cleared = SeriesNameAudit.cleared(
            asset(series: "Bad", season: 1, episode: 3, title: "Wrong"),
            includingEpisodeInfo: true)

        XCTAssertNil(cleared.videoName)
        XCTAssertNil(cleared.seasonNumber)
        XCTAssertNil(cleared.episodeNumber)
        XCTAssertNil(cleared.episode)
    }

    /// Nothing else on the record is touched — this tool removes a name, and a
    /// cleanup that quietly altered tags or ratings would be unauditable.
    func testClearingTouchesNothingElse() {
        var a = asset(series: "Bad")
        a.tags = ["actor:Someone", "studio:Example Studio"]
        a.rating = 4
        a.notes = "kept"

        let cleared = SeriesNameAudit.cleared(a, includingEpisodeInfo: true)

        XCTAssertEqual(cleared.tags, a.tags)
        XCTAssertEqual(cleared.rating, 4)
        XCTAssertEqual(cleared.notes, "kept")
        XCTAssertEqual(cleared.id, a.id)
    }
}
