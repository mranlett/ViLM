import XCTest
@testable import LibraryCore

/// Characterization tests for asset grid ordering (issue #3, Phase 0).
///
/// F5 replaces per-sort `attributesOfItem` calls with a persisted `file_size`
/// column. These pin the ordering that must survive that change — the acceptance
/// criterion is "sort order byte-identical to today's for an unchanged library".
final class AssetSortTests: XCTestCase {

    private func asset(
        _ fileName: String,
        season: Int? = nil,
        episode: Int? = nil,
        created: TimeInterval = 0
    ) -> Asset {
        var a = Asset(relativePath: fileName, fileName: fileName)
        a.seasonNumber = season
        a.episodeNumber = episode
        return a
    }

    // MARK: - Name

    func testNameSortUsesNaturalNumericOrderingNotLexicographic() {
        let assets = [asset("clip10.mp4"), asset("clip2.mp4"), asset("clip1.mp4")]
        let names = AssetSort.sorted(assets, by: .name, ascending: true).map(\.fileName)
        XCTAssertEqual(names, ["clip1.mp4", "clip2.mp4", "clip10.mp4"],
                       "localizedStandardCompare puts clip2 before clip10, unlike a plain < comparison")
    }

    func testNameSortIsCaseAndDiacriticTolerant() {
        let assets = [asset("Zebra.mp4"), asset("apple.mp4"), asset("Émile.mp4")]
        let names = AssetSort.sorted(assets, by: .name, ascending: true).map(\.fileName)
        XCTAssertEqual(names.first, "apple.mp4", "lowercase 'apple' sorts before 'Zebra' — not ASCII order")
        XCTAssertEqual(names.count, 3)
    }

    func testDescendingNameSortIsTheReverse() {
        let assets = [asset("a.mp4"), asset("b.mp4"), asset("c.mp4")]
        XCTAssertEqual(AssetSort.sorted(assets, by: .name, ascending: false).map(\.fileName),
                       ["c.mp4", "b.mp4", "a.mp4"])
    }

    // MARK: - Size

    func testSizeSortOrdersBySuppliedSizes() {
        let a = asset("a.mp4"), b = asset("b.mp4"), c = asset("c.mp4")
        let sizes: [Asset.ID: Int64] = [a.id: 300, b.id: 100, c.id: 200]
        XCTAssertEqual(AssetSort.sorted([a, b, c], by: .size, ascending: true, fileSizes: sizes).map(\.fileName),
                       ["b.mp4", "c.mp4", "a.mp4"])
        XCTAssertEqual(AssetSort.sorted([a, b, c], by: .size, ascending: false, fileSizes: sizes).map(\.fileName),
                       ["a.mp4", "c.mp4", "b.mp4"])
    }

    func testAMissingSizeCountsAsZeroAndSortsFirstAscending() {
        let a = asset("a.mp4"), b = asset("b.mp4")
        let sizes: [Asset.ID: Int64] = [a.id: 500]     // b is absent
        XCTAssertEqual(AssetSort.sorted([a, b], by: .size, ascending: true, fileSizes: sizes).map(\.fileName),
                       ["b.mp4", "a.mp4"], "an unknown size is treated as 0, not skipped")
    }

    func testSizeSortBeforeSizesLoadKeepsEveryAssetAndDoesNotCrash() {
        // The real pre-backfill state: sorting by size with an empty lookup.
        let assets = (0..<200).map { asset("clip\($0).mp4") }
        for ascending in [true, false] {
            let out = AssetSort.sorted(assets, by: .size, ascending: ascending, fileSizes: [:])
            XCTAssertEqual(out.count, 200, "no assets lost when every size is unknown")
            XCTAssertEqual(Set(out.map(\.id)).count, 200, "and none duplicated")
        }
    }

    // MARK: - Series order

    func testSeriesOrderIsSeasonThenEpisode() {
        let assets = [
            asset("s2e1.mp4", season: 2, episode: 1),
            asset("s1e2.mp4", season: 1, episode: 2),
            asset("s1e1.mp4", season: 1, episode: 1),
        ]
        XCTAssertEqual(AssetSort.sorted(assets, by: .seriesOrder, ascending: true).map(\.fileName),
                       ["s1e1.mp4", "s1e2.mp4", "s2e1.mp4"])
    }

    func testAMissingSeasonIsTreatedAsSeasonOne() {
        let unnumbered = asset("original.mp4", season: nil, episode: 1)
        let seasonTwo  = asset("s2e1.mp4", season: 2, episode: 1)
        XCTAssertTrue(AssetSort.seriesOrderPrecedes(unnumbered, seasonTwo),
                      "an unnumbered entry is the original, i.e. season 1")
    }

    func testAMissingEpisodeSortsLastWithinItsSeason() {
        let numbered = asset("s1e5.mp4", season: 1, episode: 5)
        let extra    = asset("s1extra.mp4", season: 1, episode: nil)
        XCTAssertTrue(AssetSort.seriesOrderPrecedes(numbered, extra),
                      "numbered episodes lead; unnumbered extras trail")
        XCTAssertFalse(AssetSort.seriesOrderPrecedes(extra, numbered))
    }

    func testSeriesOrderFallsBackToFilenameWhenSeasonEpisodeAndDateMatch() {
        let a = asset("aaa.mp4", season: 1, episode: 1)
        let b = asset("bbb.mp4", season: 1, episode: 1)
        XCTAssertTrue(AssetSort.seriesOrderPrecedes(a, b))
        XCTAssertFalse(AssetSort.seriesOrderPrecedes(b, a))
    }

    // MARK: - Invariants across every mode

    func testEverySortModePreservesTheFullSetInBothDirections() {
        let assets = (0..<50).map {
            asset("clip\($0).mp4", season: $0 % 3, episode: $0 % 5)
        }
        let sizes = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, Int64($0.fileName.count)) })
        for option in AssetSort.Option.allCases {
            for ascending in [true, false] {
                let out = AssetSort.sorted(assets, by: option, ascending: ascending, fileSizes: sizes)
                XCTAssertEqual(Set(out.map(\.id)), Set(assets.map(\.id)),
                               "\(option.rawValue) ascending=\(ascending) must neither lose nor invent assets")
                XCTAssertEqual(out.count, assets.count)
            }
        }
    }

    func testSortOptionRawValuesMatchTheUIPicker() {
        // These strings are user-visible in the sort menu and are persisted.
        XCTAssertEqual(AssetSort.Option.seriesOrder.rawValue, "Series Order")
        XCTAssertEqual(AssetSort.Option.name.rawValue, "Name")
        XCTAssertEqual(AssetSort.Option.date.rawValue, "Date Added")
        XCTAssertEqual(AssetSort.Option.size.rawValue, "File Size")
        XCTAssertEqual(AssetSort.Option.releaseDate.rawValue, "Release Date")
        XCTAssertEqual(AssetSort.Option.allCases.count, 5)
    }

    /// ⚠️ Undated videos sort LAST ascending. They are not "very old", they are
    /// unknown, and leading a career view with them opens it on the records
    /// that say nothing about it.
    func testUndatedVideosSortLastInAscendingReleaseOrder() {
        let dated = Asset(relativePath: "a.mp4", fileName: "a.mp4",
                          tags: [], releaseDate: "2020-01-01")
        let undated = Asset(relativePath: "b.mp4", fileName: "b.mp4", tags: [])

        let out = AssetSort.sorted([undated, dated], by: .releaseDate, ascending: true)
        XCTAssertEqual(out.map(\.fileName), ["a.mp4", "b.mp4"])
    }

    func testReleaseOrderIsChronological() {
        let older = Asset(relativePath: "a.mp4", fileName: "a.mp4",
                          tags: [], releaseDate: "2018-03-04")
        let newer = Asset(relativePath: "b.mp4", fileName: "b.mp4",
                          tags: [], releaseDate: "2024-11-30")

        XCTAssertTrue(AssetSort.releaseDatePrecedes(older, newer))
        XCTAssertFalse(AssetSort.releaseDatePrecedes(newer, older))
    }

    /// An empty string is not a date. Treating it as one would sort those
    /// records to the front of every chronological view.
    func testAnEmptyReleaseDateCountsAsUnknown() {
        let blank = Asset(relativePath: "a.mp4", fileName: "a.mp4",
                          tags: [], releaseDate: "   ")
        let dated = Asset(relativePath: "b.mp4", fileName: "b.mp4",
                          tags: [], releaseDate: "2001-01-01")

        XCTAssertTrue(AssetSort.releaseDatePrecedes(dated, blank))
    }

    func testEmptyInputIsHandledForEveryMode() {
        for option in AssetSort.Option.allCases {
            XCTAssertEqual(AssetSort.sorted([], by: option, ascending: true).count, 0)
        }
    }
}
