// HeadToHeadModelTests.swift
// The comparison game: who is eligible, what a choice changes, and what it
// must never touch.
//
// 🚨 The spec's hardest promise is a NEGATIVE one — #43, "the feature never
// writes to the library". A negative is exactly what a person testing by hand
// cannot check: nothing on screen would look different if the game quietly
// rewrote a rating. It is asserted here by comparing the whole library before
// and after a session.

import XCTest
import LibraryCore
@testable import ViLM

@MainActor
final class HeadToHeadModelTests: XCTestCase {

    private var url: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HtH-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store = try LibraryStore(at: url)
        LibrarySession.shared.setPrimary(url)
    }

    override func tearDownWithError() throws {
        LibrarySession.shared.setPrimary(nil)
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: url)
    }

    /// ⚠️ A photo is what makes a performer eligible — the game shows pictures,
    /// so someone without one cannot be judged.
    @discardableResult
    private func contender(_ name: String, gender: String = "Female",
                           rating: Int? = nil) throws -> EntityProfile {
        var p = try store.newEntityProfile(named: name, type: "actor")
        p.photoUrl = "https://example.test/\(name).jpg"
        p.gender = gender
        p.rating = rating
        try store.saveEntityProfile(p)
        return p
    }

    private func index() throws -> EntityProfileIndex {
        EntityProfileIndex(try store.fetchAllEntityProfiles())
    }

    private func loaded(pool: ActorFilterCriteria = .init()) async throws -> HeadToHeadModel {
        let m = HeadToHeadModel()
        await m.load(profiles: try index(), assets: try store.fetchAllAssets(),
                     photoFileNames: [], pool: pool, fallbackLibrary: url)
        return m
    }

    private func genderPool(_ gender: String) -> ActorFilterCriteria {
        var c = ActorFilterCriteria()
        c.selectedGenders = [gender]
        return c
    }

    // MARK: - 🚨 #43 — it never writes to the library

    /// The promise a person cannot check by playing. Every profile is compared
    /// before and after, so a stray rating or enrichment write would show up
    /// even though nothing on screen would.
    func testPlayingChangesNothingInTheLibrary() async throws {
        try contender("Ann Example", rating: 3)
        try contender("Bea Example", rating: 5)
        let before = try store.fetchAllEntityProfiles().sorted { $0.id < $1.id }

        let m = try await loaded()
        guard case .playing = m.state else { return XCTFail("expected a pair") }
        m.choose(.left)
        m.choose(.right)

        let after = try store.fetchAllEntityProfiles().sorted { $0.id < $1.id }
        XCTAssertEqual(before, after, "the game is read-only over profiles")
    }

    /// ⭐ And it must not touch the videos either.
    func testPlayingChangesNoVideo() async throws {
        try contender("Ann Example")
        try contender("Bea Example")
        let asset = Asset(relativePath: "v.mp4", fileName: "v.mp4",
                          tags: ["actor:Ann Example"])
        try store.insertAsset(asset)
        let before = try store.fetchAllAssets()

        let m = try await loaded()
        m.choose(.left)

        XCTAssertEqual(try store.fetchAllAssets(), before)
    }

    // MARK: - Scores

    func testAChoiceIsRecordedAndCounted() async throws {
        try contender("Ann Example")
        try contender("Bea Example")
        let m = try await loaded()

        m.choose(.left)

        XCTAssertEqual(m.comparedThisSession, 1)
        XCTAssertTrue(m.canUndo, "the safety net for a game with no confirmation")
    }

    // MARK: - 🚨 T12 — an unplayable pool is refused WITH a reason

    /// Refused rather than entered and then stuck, and the reason names the
    /// eligible count so the operator knows what to widen.
    func testAPoolWithOneContenderIsRefusedWithAReason() async throws {
        try contender("Ann Example", gender: "Female")
        try contender("Bob Example", gender: "Male")

        let m = try await loaded(pool: genderPool("Female"))

        guard case let .unplayable(reason) = m.state else {
            return XCTFail("expected a refusal, got \(m.state)")
        }
        XCTAssertFalse(reason.isEmpty, "and it says why")
    }

    func testAnEmptyLibraryIsRefusedRatherThanCrashing() async throws {
        let m = try await loaded()

        guard case .unplayable = m.state else {
            return XCTFail("expected a refusal, got \(m.state)")
        }
    }

    /// ⚠️ A performer with no picture cannot be judged, so they are not a
    /// contender however well they match the pool.
    func testAPerformerWithNoPictureIsNotEligible() async throws {
        try contender("Ann Example")
        var noPhoto = try store.newEntityProfile(named: "Bea Example", type: "actor")
        noPhoto.gender = "Female"
        try store.saveEntityProfile(noPhoto)

        let m = try await loaded()

        XCTAssertEqual(m.poolCount, 1)
        guard case .unplayable = m.state else {
            return XCTFail("one eligible contender is not a game")
        }
    }

    // MARK: - 🚨 D1b — the pool decides who plays

    func testTheFilterNarrowsThePool() async throws {
        try contender("Ann Example", gender: "Female")
        try contender("Bea Example", gender: "Female")
        try contender("Bob Example", gender: "Male")

        let all = try await loaded()
        XCTAssertEqual(all.poolCount, 3)

        let filtered = try await loaded(pool: genderPool("Female"))
        XCTAssertEqual(filtered.poolCount, 2, "the same matcher the actor grid uses")
        guard case .playing = filtered.state else { return XCTFail("two is playable") }
    }

    /// ⭐ T11 — a filtered session feeds the SAME ladder. Scores are not
    /// per-pool, or a filter would quietly fork the ranking.
    func testAFilteredSessionUpdatesTheSameScoresAsAnUnfilteredOne() async throws {
        try contender("Ann Example", gender: "Female")
        try contender("Bea Example", gender: "Female")
        try contender("Bob Example", gender: "Male")

        let filtered = try await loaded(pool: genderPool("Female"))
        guard case .playing = filtered.state else { return XCTFail("expected a pair") }
        filtered.choose(.left)

        // Reopening unfiltered must see the comparison the filtered session made.
        let unfiltered = try await loaded()
        XCTAssertEqual(unfiltered.poolCount, 3)
        let records = try store.preferenceRecords(subject: .actor)
        let moved = records.values.filter { $0.comparisons > 0 }
        XCTAssertEqual(moved.count, 2, "one comparison moved exactly two contenders")
    }

    // MARK: - 🚨 D1 / #38 — the same game over VIDEOS

    /// A video contender needs a picture on disk, not a picture in the record.
    /// Its still is a generated artifact, so the fixture generates one.
    @discardableResult
    private func video(_ name: String, still: Bool = true,
                       rating: Int? = nil, tags: [String] = []) throws -> Asset {
        let asset = Asset(relativePath: "\(name).mp4", fileName: "\(name).mp4",
                          tags: tags, rating: rating, videoName: name)
        try store.insertAsset(asset)
        if still { try writeStill(for: asset.id) }
        return asset
    }

    private func writeStill(for id: Asset.ID) throws {
        let dir = url.appendingPathComponent(".catalog/thumbnails")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // ⚠️ Contents are never decoded by the eligibility check — it is a
        // directory listing, and a byte is enough to make the file exist.
        try Data([0x00]).write(to: dir.appendingPathComponent("\(id.uuidString).jpg"))
    }

    private func loadedVideos(pool: AssetFilterCriteria = .init()) async throws -> HeadToHeadModel {
        let m = HeadToHeadModel()
        await m.loadVideos(assets: try store.fetchAllAssets(), profiles: try index(),
                           akaMap: [:], pool: pool, fallbackLibrary: url)
        return m
    }

    /// 🚨 #43 again, for the second subject. The read-only promise is a
    /// property of the FEATURE, not of the actor screen, and a video session
    /// writing a rating would be exactly as invisible.
    func testPlayingOverVideosChangesNothingInTheLibrary() async throws {
        try video("Alpha", rating: 3)
        try video("Beta", rating: 5)
        let before = try store.fetchAllAssets().sorted { $0.id.uuidString < $1.id.uuidString }

        let m = try await loadedVideos()
        guard case .playing = m.state else { return XCTFail("expected a pair") }
        m.choose(.left)
        m.choose(.draw)

        let after = try store.fetchAllAssets().sorted { $0.id.uuidString < $1.id.uuidString }
        XCTAssertEqual(before, after, "the game is read-only over videos too")
    }

    func testAVideoChoiceIsRecordedAgainstTheVideoLadder() async throws {
        try video("Alpha")
        try video("Beta")

        let m = try await loadedVideos()
        m.choose(.left)

        XCTAssertEqual(m.comparedThisSession, 1)
        let videos = try store.preferenceRecords(subject: .video)
        XCTAssertEqual(videos.values.filter { $0.comparisons > 0 }.count, 2)
        // 🚨 One mechanic, two LADDERS. A video comparison landing on the actor
        // ladder would corrupt a ranking nobody was playing.
        XCTAssertTrue(try store.preferenceRecords(subject: .actor).isEmpty,
                      "a video session never touches the actor standings")
    }

    /// ⚠️ D9/T8 for videos: a contender with no image cannot play. A library
    /// that has not generated stills yet would otherwise offer black rectangles.
    func testAVideoWithNoStillIsNotEligible() async throws {
        try video("Alpha")
        try video("Beta", still: false)

        let m = try await loadedVideos()

        XCTAssertEqual(m.poolCount, 1)
        guard case .unplayable(let reason) = m.state else {
            return XCTFail("one eligible video is not a game, got \(m.state)")
        }
        XCTAssertTrue(reason.contains("still"), "and the refusal says what is missing")
    }

    /// T12 for videos — refused with a reason rather than entered and stuck.
    func testALibraryWithNoStillsIsRefusedWithAReason() async throws {
        try video("Alpha", still: false)
        try video("Beta", still: false)

        let m = try await loadedVideos()

        guard case .unplayable(let reason) = m.state else {
            return XCTFail("expected a refusal, got \(m.state)")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    /// D1b — the video pool decides what plays, using the same criteria the
    /// video grid uses.
    func testTheVideoPoolNarrowsTheField() async throws {
        try video("Alpha", rating: 5)
        try video("Beta", rating: 5)
        try video("Gamma", rating: 1)

        let all = try await loadedVideos()
        XCTAssertEqual(all.poolCount, 3)

        var pool = AssetFilterCriteria()
        pool.minRating = 4
        let filtered = try await loadedVideos(pool: pool)
        XCTAssertEqual(filtered.poolCount, 2, "the same matcher the video grid uses")
        guard case .playing = filtered.state else { return XCTFail("two is playable") }
    }

    /// D9 — a hand-set rating seeds a video's first score, exactly as it seeds
    /// a performer's. The arrow points one way: read, never written.
    func testAHandSetVideoRatingSeedsItsFirstScore() async throws {
        let top = try video("Alpha", rating: 5)
        let bottom = try video("Beta", rating: 1)

        let m = try await loadedVideos()
        // ⚠️ A DRAW, not a win. Which contender lands on the left is
        // deliberately randomised, so any test asserting on the winner would
        // pass four times in five. A draw touches both and preserves their
        // order, which is exactly the seeding claim being made.
        m.choose(.draw)

        let records = try store.preferenceRecords(subject: .video)
        guard let high = records[top.id.uuidString],
              let low = records[bottom.id.uuidString] else {
            return XCTFail("both compared videos have a standing")
        }
        XCTAssertGreaterThan(high.score, low.score,
                             "a 5-star video does not start level with a 1-star one")
        let ratings = try store.fetchAllAssets()
            .reduce(into: [UUID: Int?]()) { $0[$1.id] = $1.rating }
        XCTAssertEqual(ratings[top.id], 5,
                       "and the rating it was seeded FROM is untouched")
    }
}
