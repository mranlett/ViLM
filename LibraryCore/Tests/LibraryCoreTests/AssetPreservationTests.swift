import XCTest
@testable import LibraryCore

/// The `Asset` mirror of `EntityProfilePreservationTests`.
///
/// That guard exists because a field added to `EntityProfile` was silently
/// dropped by one of eight copy sites, several times. `Asset` had no equivalent,
/// and the same class of defect duly appeared — `encode(to:)` listed fifteen
/// columns for a record with nineteen stored properties, so four were never
/// written by any update. Everything below asserts the property that was
/// missing: **what goes in comes back out.**
final class AssetPreservationTests: XCTestCase {

    private var libraryURL: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        libraryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssetPreservationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        store = try LibraryStore(at: libraryURL)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: libraryURL)
    }

    /// Every stored property set to a distinctive, non-default value.
    ///
    /// Defaults are deliberately avoided: a field that is dropped on save but
    /// happens to match its default reads as preserved, which is exactly how
    /// this defect survived a suite of 743 tests.
    private func fullyPopulated(id: UUID = UUID()) -> Asset {
        Asset(
            id: id,
            relativePath: "clips/a.mp4",
            fileName: "a.mp4",
            status: .reviewed,
            createdAt: Date(timeIntervalSince1970: 1_600_000_000),
            tags: ["actor:Alice Example", "tag:Outdoors", "studio:Example Studio"],
            externalLink: "https://example.com/video",
            notes: "a note",
            sourceDescription: "what the source says about this scene",
            sourceDescriptionFrom: "TestSource",
            sourceDescriptionAt: Date(timeIntervalSince1970: 1_690_000_000),
            rating: 4,
            videoName: "Example Series",
            seasonNumber: 2,
            episodeNumber: 7,
            episode: "Late Checkout",
            releaseDate: "2019-04-12",
            enrichmentState: .matched,
            enrichmentSource: "TestSource",
            enrichmentSourceId: "scene-12345",
            lookupRoute: VideoMatchRoute.cast.rawValue,
            enrichmentUrl: "https://example.com/scene/12345",
            enrichmentCheckedAt: Date(timeIntervalSince1970: 1_700_000_000),
            playCount: 9,
            lastPlayedAt: Date(timeIntervalSince1970: 1_650_000_000)
        )
    }

    // MARK: - The structural guard

    /// Fails when a stored property is added to `Asset`.
    ///
    /// It cannot say WHERE a new field was forgotten, but it forces a person to
    /// look at the copy sites below before the change can land.
    func testFieldCountIsPinned() {
        let count = Mirror(reflecting: fullyPopulated()).children.count
        XCTAssertEqual(count, 25, """
            Asset gained or lost a stored property (now \(count)).

            A new field must be carried by EVERY path that rebuilds an asset.
            Check each of these, then update this expected count:

              • Asset.encode(to:)                      — the GRDB write path. A column
                                                         omitted here is never written by
                                                         any UPDATE, silently.
              • Asset.init(from:)                      — the decode path
              • LibraryStore.saveAsset                 — INSERT OR IGNORE, scanner only
              • VideoTransferService.moveVideo         — rebuilds the asset in the
                                                         destination library
              • VideoEnrichmentReview.merged           — accepting a lookup
              • FileNameParser.applying                — accepting a parse
              • StudioConflictAudit.resolving          — resolving a studio conflict
              • AssetFilterCriteria / AssetSort        — if the field is filterable

            And add it to `fullyPopulated()` above with a NON-DEFAULT value, or the
            round-trip test below will pass while the field is being dropped.
            """)
    }

    // MARK: - The defect this file exists for

    /// V1: `encode(to:)` omitted `release_date`, `enrichment_state`,
    /// `enrichment_source` and `enrichment_checked_at`, so every acceptance path
    /// — per-video, batch and inspector — discarded them at save.
    func testEveryFieldSurvivesAnUpdate() throws {
        let original = fullyPopulated()
        try store.insertAsset(original)

        // Round-trip through a real UPDATE, which is the path that dropped them.
        try store.updateAsset(original)

        let fetched = try XCTUnwrap(try store.fetchAllAssets().first)

        XCTAssertEqual(fetched.id, original.id)
        XCTAssertEqual(fetched.relativePath, original.relativePath)
        XCTAssertEqual(fetched.fileName, original.fileName)
        XCTAssertEqual(fetched.status, original.status)
        XCTAssertEqual(fetched.tags, original.tags)
        XCTAssertEqual(fetched.externalLink, original.externalLink)
        XCTAssertEqual(fetched.notes, original.notes)
        XCTAssertEqual(fetched.rating, original.rating)
        XCTAssertEqual(fetched.videoName, original.videoName)
        XCTAssertEqual(fetched.seasonNumber, original.seasonNumber)
        XCTAssertEqual(fetched.episodeNumber, original.episodeNumber)
        XCTAssertEqual(fetched.episode, original.episode)
        XCTAssertEqual(fetched.playCount, original.playCount)

        // The four that were being dropped, plus the two added for V2.
        XCTAssertEqual(fetched.releaseDate, "2019-04-12",
                       "release date is the field the whole naming convention is sequenced behind")
        XCTAssertEqual(fetched.enrichmentState, .matched,
                       "without this VideoBatchPolicy.skipReason can never skip anything")
        XCTAssertEqual(fetched.enrichmentSource, "TestSource")
        XCTAssertEqual(fetched.enrichmentSourceId, "scene-12345",
                       "V2: without the id every run re-searches by name and re-guesses")
        XCTAssertEqual(fetched.enrichmentUrl, "https://example.com/scene/12345")
        XCTAssertEqual(fetched.enrichmentCheckedAt?.timeIntervalSince1970,
                       original.enrichmentCheckedAt?.timeIntervalSince1970)
        XCTAssertEqual(fetched.lastPlayedAt?.timeIntervalSince1970,
                       original.lastPlayedAt?.timeIntervalSince1970)
    }

    /// A freshly-opened store, not the one that wrote the row — an in-process
    /// cache could otherwise hand back the object that was never persisted.
    func testAMatchSurvivesAFreshOpen() throws {
        let id = UUID()
        try store.insertAsset(fullyPopulated(id: id))
        try store.updateAsset(fullyPopulated(id: id))

        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        let reopened = try LibraryStore(at: libraryURL)

        let fetched = try XCTUnwrap(try reopened.fetchAllAssets().first)
        XCTAssertEqual(fetched.enrichmentSourceId, "scene-12345")
        XCTAssertEqual(fetched.enrichmentUrl, "https://example.com/scene/12345")
        XCTAssertEqual(fetched.enrichmentState, .matched)
        XCTAssertNotNil(fetched.enrichmentCheckedAt)
    }

    /// The skip logic already exists and is correct; it was inert because the
    /// state it reads was never written. This asserts the two now agree.
    func testASettledMatchIsSkippedOnARerun() throws {
        let id = UUID()
        try store.insertAsset(fullyPopulated(id: id))
        try store.updateAsset(fullyPopulated(id: id))

        let fetched = try XCTUnwrap(try store.fetchAllAssets().first)
        XCTAssertEqual(VideoBatchPolicy.skipReason(for: fetched), "already matched",
                       "a persisted .matched state is what makes a re-run cheap")
    }

    /// An operator's "I looked, it isn't there" is the only state a machine
    /// never assigns. Losing it puts the row back in the queue forever.
    func testARuledOutVideoStaysRuledOut() throws {
        var asset = fullyPopulated()
        asset.enrichmentState = .unmatchable
        try store.insertAsset(asset)
        try store.updateAsset(asset)

        let fetched = try XCTUnwrap(try store.fetchAllAssets().first)
        XCTAssertEqual(fetched.enrichmentState, .unmatchable)
        XCTAssertEqual(VideoBatchPolicy.skipReason(for: fetched), "you ruled this one out")
    }

    /// Moving a video between libraries rebuilt the asset field by field and
    /// omitted the release date and the whole enrichment group — so a move
    /// silently discarded a confirmed match and the destination re-searched.
    func testAMoveBetweenLibrariesCarriesTheMatch() async throws {
        let sourceLib = libraryURL.appendingPathComponent("src", isDirectory: true)
        let destLib = libraryURL.appendingPathComponent("dst", isDirectory: true)
        for lib in [sourceLib, destLib] {
            try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        }
        // Must match fullyPopulated()'s relativePath, or the move aborts with
        // sourceFileMissing before it can prove anything.
        try FileManager.default.createDirectory(
            at: sourceLib.appendingPathComponent("clips", isDirectory: true),
            withIntermediateDirectories: true)
        try Data((0..<2_000).map { UInt8($0 % 251) })
            .write(to: sourceLib.appendingPathComponent("clips/a.mp4"))

        let sourceStore = try LibraryStore(at: sourceLib)
        try sourceStore.insertAsset(fullyPopulated())

        let outcome = try await VideoTransferService().moveVideo(
            try XCTUnwrap(try sourceStore.fetchAllAssets().first),
            from: sourceLib, to: destLib)

        let moved = try XCTUnwrap(try LibraryStore(at: destLib).fetchAllAssets()
            .first { $0.id == outcome.newAssetId })

        XCTAssertEqual(moved.releaseDate, "2019-04-12")
        XCTAssertEqual(moved.enrichmentState, .matched)
        XCTAssertEqual(moved.enrichmentSource, "TestSource")
        XCTAssertEqual(moved.enrichmentSourceId, "scene-12345",
                       "a move must not cost a confirmed match")
        XCTAssertEqual(moved.enrichmentUrl, "https://example.com/scene/12345")
        XCTAssertNotNil(moved.enrichmentCheckedAt)
    }

    // MARK: - V2: the match identity is recorded and cleared correctly

    func testRecordingAMatchKeepsTheSourceIdAndUrl() {
        let recorded = VideoEnrichmentReview.recordingOutcome(
            Asset(relativePath: "a.mp4", fileName: "a.mp4"),
            state: .matched, source: "TestSource",
            sourceId: "scene-999", sourceUrl: "https://example.com/scene/999")

        XCTAssertEqual(recorded.enrichmentSourceId, "scene-999")
        XCTAssertEqual(recorded.enrichmentUrl, "https://example.com/scene/999")
        XCTAssertEqual(recorded.enrichmentState, .matched)
    }

    /// An id that outlived its match would be read as evidence of one.
    func testANonMatchClearsAnyPreviousId() {
        var asset = fullyPopulated()
        XCTAssertNotNil(asset.enrichmentSourceId, "precondition")

        asset = VideoEnrichmentReview.recordingOutcome(
            asset, state: .noMatch, source: "TestSource")

        XCTAssertNil(asset.enrichmentSourceId)
        XCTAssertNil(asset.enrichmentUrl)
        XCTAssertEqual(asset.enrichmentState, .noMatch)
    }

    /// Re-confirming a match with a provider that supplies no id must not erase
    /// the id already stored — that would silently undo V2 on a refresh.
    func testReconfirmingWithoutAnIdKeepsTheStoredOne() {
        let asset = VideoEnrichmentReview.recordingOutcome(
            fullyPopulated(), state: .matched, source: "TestSource")

        XCTAssertEqual(asset.enrichmentSourceId, "scene-12345")
        XCTAssertEqual(asset.enrichmentUrl, "https://example.com/scene/12345")
    }

    /// A link describes the record it came from. Re-matching to a DIFFERENT
    /// record must not leave the old link attached to the new id — that is a
    /// provenance label pointing somewhere plausible and wrong, which is worse
    /// than showing none.
    func testRematchingToADifferentRecordDropsTheStaleUrl() {
        let rematched = VideoEnrichmentReview.recordingOutcome(
            fullyPopulated(), state: .matched, source: "TestSource",
            sourceId: "scene-different")

        XCTAssertEqual(rematched.enrichmentSourceId, "scene-different")
        XCTAssertNil(rematched.enrichmentUrl,
                     "the old link described scene-12345 and must not survive the change")
    }

    /// Ruling a video out must not leave it carrying the identity of a record
    /// it was matched to — an id outliving its match reads as evidence of one.
    func testRulingOutAMatchedVideoClearsItsIdentity() {
        let ruledOut = VideoEnrichmentReview.recordingOutcome(
            fullyPopulated(), state: .unmatchable, source: "TestSource")

        XCTAssertEqual(ruledOut.enrichmentState, .unmatchable)
        XCTAssertNil(ruledOut.enrichmentSourceId)
        XCTAssertNil(ruledOut.enrichmentUrl)
    }

    /// A link is not an identity. Recording one without an id would leave a
    /// match that can never be fetched by id (Plugin Architecture D10.6).
    func testAUrlWithoutAnIdIsNotRecorded() {
        let asset = VideoEnrichmentReview.recordingOutcome(
            Asset(relativePath: "a.mp4", fileName: "a.mp4"),
            state: .matched, source: "TestSource",
            sourceId: nil, sourceUrl: "https://example.com/scene/1")

        XCTAssertNil(asset.enrichmentUrl, "a URL alone is not a match")
        XCTAssertNil(asset.enrichmentSourceId)
    }

    func testRematchingToTheSameRecordKeepsTheUrl() {
        let same = VideoEnrichmentReview.recordingOutcome(
            fullyPopulated(), state: .matched, source: "TestSource",
            sourceId: "scene-12345")

        XCTAssertEqual(same.enrichmentUrl, "https://example.com/scene/12345")
    }

    /// `insertAsset` documents itself as writing "every column", unlike the
    /// scanner's INSERT-OR-IGNORE. It did not.
    func testInsertWritesEveryColumnToo() throws {
        try store.insertAsset(fullyPopulated())

        let fetched = try XCTUnwrap(try store.fetchAllAssets().first)
        XCTAssertEqual(fetched.releaseDate, "2019-04-12")
        XCTAssertEqual(fetched.enrichmentSourceId, "scene-12345")
        XCTAssertEqual(fetched.enrichmentState, .matched)
    }
}
