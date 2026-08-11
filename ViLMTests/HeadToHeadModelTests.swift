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
}
