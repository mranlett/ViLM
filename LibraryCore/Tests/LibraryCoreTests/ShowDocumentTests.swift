import XCTest
@testable import LibraryCore

/// D8 — the show-level `tvshow.nfo` (Metadata Sidecars, SPEC-VILM-031).
///
/// 🚨 An episode sidecar carries no studio and no tags — Kodi keeps those on
/// the show — so without this the Episodic grammar silently drops the two
/// fields this library is best at: studio on 88% of videos, and tags widely
/// used. The renderer existed and was tested from the day it was written; what
/// did not exist was anything that CALLED it.
///
/// ⚠️ All names invented. This repository is public.
final class ShowDocumentTests: XCTestCase {

    private var dir: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Show-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try LibraryStore(at: dir)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnection(forLibraryAt: dir)
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func addFile(_ path: String, kind: ContentKind? = .episodic,
                         series: String? = "Coast Line", tags: [String] = []) throws -> Asset {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("video".utf8).write(to: url)
        var a = Asset(relativePath: path, fileName: (path as NSString).lastPathComponent,
                      tags: tags, contentKind: kind)
        a.videoName = series
        a.episodeNumber = 1
        try store.insertAsset(a)
        return a
    }

    private func move(_ asset: Asset, to target: String) -> PlannedMove {
        PlannedMove(assetId: asset.id, from: asset.relativePath, to: target, title: "Example")
    }

    private func run(_ moves: [PlannedMove]) throws {
        _ = try RelocationMover(store: store).run(
            RelocationPlan(moves: moves, alreadyInPlace: 0, unfilable: [], collisions: []),
            libraryURL: dir, runId: "run-\(UUID().uuidString)")
    }

    private func read(_ path: String) -> String? {
        try? String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: - The aggregation, pure

    func testTheShowDocumentCarriesEveryStudioAndTagInTheSeries() throws {
        let a = try addFile("a.mp4", tags: ["studio:Silver River", "tag:Climbing"])
        let b = try addFile("b.mp4", tags: ["studio:Coast Line", "tag:Diving"])

        let doc = try XCTUnwrap(MetadataSidecar.showDocument(series: "Coast Line", from: [a, b]))
        XCTAssertTrue(doc.contains("<studio>Silver River</studio>"))
        XCTAssertTrue(doc.contains("<studio>Coast Line</studio>"))
        XCTAssertTrue(doc.contains("<tag>Climbing</tag>"))
        XCTAssertTrue(doc.contains("<tag>Diving</tag>"))
    }

    /// 🚨 D4 applies PER VIDEO, not to the folder. A video that may not leave
    /// the device must not have its studio and tags leave inside a document
    /// written for its neighbours.
    func testPersonalAndUndeclaredVideosContributeNothing() throws {
        let personal = try addFile("p.mp4", kind: .personal, tags: ["studio:Example Pictures"])
        let undeclared = try addFile("u.mp4", kind: nil, tags: ["studio:Example Imprint"])
        let fine = try addFile("f.mp4", tags: ["studio:Silver River"])

        let doc = try XCTUnwrap(MetadataSidecar.showDocument(
            series: "Coast Line", from: [personal, undeclared, fine]))
        XCTAssertFalse(doc.contains("Example Pictures"))
        XCTAssertFalse(doc.contains("Example Imprint"))
        XCTAssertTrue(doc.contains("Silver River"))
    }

    /// ⚠️ S5's rule one level up — nothing eligible means no file, not an empty
    /// claim about a series.
    func testNothingEligibleProducesNoDocumentAtAll() throws {
        let personal = try addFile("p.mp4", kind: .personal, tags: ["studio:Example Pictures"])
        XCTAssertNil(MetadataSidecar.showDocument(series: "Coast Line", from: [personal]))
        XCTAssertNil(MetadataSidecar.showDocument(series: "Coast Line", from: []))
    }

    /// ⭐ Rewritten on every move in the series, so unstable ordering would
    /// churn the file with no change in meaning.
    func testStudiosAndTagsAreDistinctAndStablyOrdered() throws {
        let a = try addFile("a.mp4", tags: ["studio:Silver River", "tag:Diving"])
        let b = try addFile("b.mp4", tags: ["studio:Silver River", "tag:Climbing"])

        let first = try XCTUnwrap(MetadataSidecar.showDocument(series: "Coast Line", from: [a, b]))
        let second = try XCTUnwrap(MetadataSidecar.showDocument(series: "Coast Line", from: [b, a]))
        XCTAssertEqual(first, second, "argument order must not change the document")
        XCTAssertEqual(first.components(separatedBy: "<studio>Silver River</studio>").count - 1, 1,
                       "a studio shared by two episodes is named once")
        XCTAssertTrue(first.range(of: "<tag>Climbing</tag>")!.lowerBound
                        < first.range(of: "<tag>Diving</tag>")!.lowerBound,
                      "sorted, not whatever order the assets arrived in")
    }

    // MARK: - Written by the move that files the episode

    func testMovingAnEpisodeWritesTheShowDocumentAtTheSeriesRoot() throws {
        let asset = try addFile("loose.mp4", tags: ["studio:Silver River", "tag:Climbing"])
        try run([move(asset, to: "Coast Line/Season 01/Coast Line - S01E01.mp4")])

        // 🚨 The SERIES root, not the season folder — that is where Kodi reads it.
        let doc = try XCTUnwrap(read("Coast Line/tvshow.nfo"))
        XCTAssertTrue(doc.contains("<title>Coast Line</title>"))
        XCTAssertTrue(doc.contains("<studio>Silver River</studio>"))
        XCTAssertTrue(doc.contains("<tag>Climbing</tag>"))
        XCTAssertNil(read("Coast Line/Season 01/tvshow.nfo"))
    }

    /// ⚠️ The scene and film grammars are `Folder/File.ext`. Writing a show
    /// document for a studio folder would claim every studio is a TV series.
    func testASceneMoveWritesNoShowDocument() throws {
        let asset = try addFile("loose.mp4", kind: .scene, series: nil,
                                tags: ["studio:Silver River"])
        try run([move(asset, to: "Silver River/Silver River - 2019-04-12.mp4")])

        XCTAssertNil(read("Silver River/tvshow.nfo"))
    }

    // MARK: - 🚨 The stale one goes (S6, one level up)

    func testRefilingTheLastEpisodeClearsTheOldSeriesDocument() throws {
        let asset = try addFile("Old Name/Season 01/Old Name - S01E01.mp4",
                                tags: ["studio:Silver River"])
        try run([move(asset, to: "Coast Line/Season 01/Coast Line - S01E01.mp4")])

        XCTAssertNotNil(read("Coast Line/tvshow.nfo"))
        XCTAssertNil(read("Old Name/tvshow.nfo"),
                     "a document naming studios for a folder that no longer holds them "
                     + "is authoritative-looking metadata attached to nothing")
    }

    /// ⚠️ The other direction. A series that still has episodes keeps its
    /// document — removing it whenever any episode moved would delete the file
    /// this feature exists to maintain.
    func testASeriesThatStillHasEpisodesKeepsItsDocument() throws {
        let staying = try addFile("Old Name/Season 01/Old Name - S01E02.mp4",
                                  series: "Old Name", tags: ["studio:Coast Line"])
        _ = staying
        let leaving = try addFile("Old Name/Season 01/Old Name - S01E01.mp4",
                                  series: "Old Name", tags: ["studio:Silver River"])

        // Seed the document the way a previous run would have.
        try Data("<tvshow></tvshow>".utf8)
            .write(to: dir.appendingPathComponent("Old Name/tvshow.nfo"))

        try run([move(leaving, to: "Coast Line/Season 01/Coast Line - S01E01.mp4")])

        XCTAssertNotNil(read("Old Name/tvshow.nfo"),
                        "one episode leaving is not the series ending")
    }
}
