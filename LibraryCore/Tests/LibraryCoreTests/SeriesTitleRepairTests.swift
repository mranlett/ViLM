// SeriesTitleRepairTests.swift
// Titles filed under a series of their own (device report, 2026-08-11).
//
// 🚨 The dangerous half of this feature is what it must NOT touch. The operator
// uses the series field for two different things: a series the source supplied,
// and a grouping THEY created to sequence a studio's videos by episode number —
// which the source may not consider a series at all, and for which there is no
// other way to render the videos in order.
//
// A repair that flattened those would destroy hand-built structure that cannot
// be recovered from any source. So most of these tests are refusals.
//
// 🚨 Fixture titles are INVENTED. The first draft of this file copied a real
// title out of the screenshot attached to the report — the second time in one
// day, after the same rule was written at the top of `MergeByNameTests`. The
// D9 gate caught it. Never transcribe from the library, a screenshot or a bug
// report into a fixture; make one up.

import XCTest
@testable import LibraryCore

final class SeriesTitleRepairTests: XCTestCase {

    private func video(_ file: String, series: String? = nil,
                       episode: String? = nil, number: Int? = nil) -> Asset {
        var a = Asset(relativePath: "\(UUID()).mp4", fileName: file, tags: [])
        a.videoName = series
        a.episode = episode
        a.episodeNumber = number
        return a
    }

    // MARK: - 🚨 What it must not touch

    /// The operator's own sequencing group: several videos under one name.
    func testAGroupingWithSeveralMembersIsPreserved() {
        let report = SeriesTitleRepair.report(assets: [
            video("a.mp4", series: "Coast Line Nights", episode: "One"),
            video("b.mp4", series: "Coast Line Nights", episode: "Two"),
        ])

        XCTAssertTrue(report.repairable.isEmpty)
        XCTAssertEqual(report.preservedGroupings, 1)
    }

    /// ⭐ And a group of ONE is preserved when it carries an episode number —
    /// the operator is sequencing, and the second video may not be added yet.
    func testASingleVideoWithAnEpisodeNumberIsPreserved() {
        let report = SeriesTitleRepair.report(assets: [
            video("a.mp4", series: "Coast Line Nights", number: 1)
        ])

        XCTAssertTrue(report.repairable.isEmpty, "an episode number means sequencing")
        XCTAssertEqual(report.preservedGroupings, 1)
    }

    /// ⚠️ Both fields set and different. The series may be a real one-off, and
    /// choosing between them is a judgement, so it is reported and left alone.
    func testTwoDifferentValuesAreReportedRatherThanGuessed() {
        let report = SeriesTitleRepair.report(assets: [
            video("a.mp4", series: "Some Collection", episode: "A Night Out")
        ])

        XCTAssertTrue(report.repairable.isEmpty)
        XCTAssertEqual(report.needsAPerson.count, 1)
        XCTAssertEqual(report.needsAPerson.first?.episode, "A Night Out")
    }

    func testAVideoWithNoSeriesIsNotAFinding() {
        let report = SeriesTitleRepair.report(assets: [video("a.mp4", episode: "A Night Out")])
        XCTAssertTrue(report.repairable.isEmpty)
        XCTAssertTrue(report.needsAPerson.isEmpty)
    }

    // MARK: - ⭐ What it repairs

    /// The operator's first rule, stated outright: if they match, clear the
    /// series and keep the title.
    func testASeriesThatMerelyRepeatsTheTitleIsCleared() {
        let asset = video("a.mp4", series: "Harbour Nights", episode: "Harbour Nights")
        let finding = try! XCTUnwrap(
            SeriesTitleRepair.report(assets: [asset]).repairable.first)
        XCTAssertEqual(finding.kind, .duplicated)

        let fixed = try! XCTUnwrap(SeriesTitleRepair.repaired(asset, finding))
        XCTAssertNil(fixed.videoName)
        XCTAssertEqual(fixed.episode, "Harbour Nights", "the title is untouched")
    }

    /// Case-insensitively, because that is the same text.
    func testACaseVariantCountsAsARepeat() {
        let asset = video("a.mp4", series: "harbour nights", episode: "Harbour Nights")
        XCTAssertEqual(SeriesTitleRepair.report(assets: [asset]).repairable.first?.kind,
                       .duplicated)
    }

    /// The title is in the series field and the episode is empty — move it.
    func testATitleInTheSeriesFieldIsMovedToTheEpisode() {
        let asset = video("a.mp4", series: "Harbour Nights")
        let finding = try! XCTUnwrap(
            SeriesTitleRepair.report(assets: [asset]).repairable.first)
        XCTAssertEqual(finding.kind, .titleInSeriesField)

        let fixed = try! XCTUnwrap(SeriesTitleRepair.repaired(asset, finding))
        XCTAssertEqual(fixed.episode, "Harbour Nights")
        XCTAssertNil(fixed.videoName, "and the one-video series goes with it")
    }

    // MARK: - The whole library

    /// ⚠️ The grouping test is about the WHOLE set, not one video. Two videos
    /// sharing a name are a series even though each, alone, looks like a title.
    func testTheGroupingDecisionUsesEveryVideo() {
        let shared = SeriesTitleRepair.report(assets: [
            video("a.mp4", series: "Coast Line Nights"),
            video("b.mp4", series: "Coast Line Nights"),
            video("c.mp4", series: "A One Off"),
        ])

        XCTAssertEqual(shared.repairable.count, 1, "only the genuine one-off")
        XCTAssertEqual(shared.repairable.first?.series, "A One Off")
    }

    func testTheHeadlineSaysWhatWasLeftAlone() {
        let report = SeriesTitleRepair.report(assets: [
            video("a.mp4", series: "Coast Line Nights", episode: "One"),
            video("b.mp4", series: "Coast Line Nights", episode: "Two"),
            video("c.mp4", series: "A One Off"),
        ])

        let line = SeriesTitleRepair.headline(report)
        XCTAssertTrue(line.contains("1 real grouping left alone"), line)
    }

    func testACleanLibrarySaysSo() {
        XCTAssertTrue(SeriesTitleRepair.headline(
            SeriesTitleRepair.report(assets: [])).contains("names a real grouping"))
    }

    // MARK: - Applying it

    func testRepairingWritesAndIsIdempotent() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Series-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer {
            LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
            try? FileManager.default.removeItem(at: url)
        }
        let store = try LibraryStore(at: url)

        try store.insertAsset(video("a.mp4", series: "Harbour Nights"))
        try store.insertAsset(video("b.mp4", series: "Coast Line Nights", number: 1))

        XCTAssertEqual(try store.repairSeriesTitles(), 1)
        XCTAssertEqual(try store.repairSeriesTitles(), 0, "idempotent")

        let assets = try store.fetchAllAssets()
        let moved = try XCTUnwrap(assets.first { $0.fileName == "a.mp4" })
        XCTAssertEqual(moved.episode, "Harbour Nights")
        XCTAssertNil(moved.videoName)

        let kept = try XCTUnwrap(assets.first { $0.fileName == "b.mp4" })
        XCTAssertEqual(kept.videoName, "Coast Line Nights", "the sequencing group survives")
    }
}
