// PreferenceRecordTests.swift
// Head to Head — the schema half (#32).
//
// ⚠️ The property worth the most here is P1: absence means UNSCORED. D9 starts
// a new contender at the middle of the range, so if playing always wrote a row
// then "never played" and "played to exactly average" would be the same state —
// and D8's whole confidence story rests on telling them apart.
//
// 🚨 P6 is the one that protects operator data: nothing on this path touches
// `rating`.

import XCTest
import GRDB
@testable import LibraryCore

final class PreferenceRecordTests: XCTestCase {

    private var url: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Preference-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store = try LibraryStore(at: url)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - P1 — absence means unscored

    func testAContenderWithNoRowIsUnscoredRatherThanAverage() throws {
        XCTAssertNil(try store.preferenceRecord(subject: .actor, contenderId: "nobody"),
                     "never played is not the same as played to the middle")
        XCTAssertTrue(try store.preferenceRecords(subject: .actor).isEmpty)
    }

    func testASavedStandingReadsBack() throws {
        try store.savePreferenceRecord(
            PreferenceRecord(subject: .actor, contenderId: "a", score: 1712.5, comparisons: 14))

        let read = try XCTUnwrap(try store.preferenceRecord(subject: .actor, contenderId: "a"))
        XCTAssertEqual(read.score, 1712.5, accuracy: 0.000_001)
        XCTAssertEqual(read.comparisons, 14)
        XCTAssertFalse(read.retired)
        XCTAssertNotNil(read.updatedAt, "stamped on write, not by the caller")
    }

    // MARK: - P2 — the two subjects share a table without colliding

    /// ⭐ D1's "one mechanic, two subjects" is why this is one table. The
    /// primary key has to be (subject, id) or an actor and a video that happen
    /// to share an id would overwrite each other.
    func testAnActorAndAVideoMayShareAnIdWithoutColliding() throws {
        let shared = UUID().uuidString
        try store.savePreferenceRecord(
            PreferenceRecord(subject: .actor, contenderId: shared, score: 1700, comparisons: 5))
        try store.savePreferenceRecord(
            PreferenceRecord(subject: .video, contenderId: shared, score: 1300, comparisons: 9))

        XCTAssertEqual(try store.preferenceRecord(subject: .actor, contenderId: shared)?.score, 1700)
        XCTAssertEqual(try store.preferenceRecord(subject: .video, contenderId: shared)?.score, 1300)
    }

    func testRecordsAreScopedToTheirSubject() throws {
        try store.savePreferenceRecord(PreferenceRecord(subject: .actor, contenderId: "a"))
        try store.savePreferenceRecord(PreferenceRecord(subject: .video, contenderId: "v"))

        XCTAssertEqual(Array(try store.preferenceRecords(subject: .actor).keys), ["a"])
        XCTAssertEqual(Array(try store.preferenceRecords(subject: .video).keys), ["v"])
    }

    // MARK: - P3 — a second write updates rather than duplicating

    func testSavingTwiceUpdatesTheSameStanding() throws {
        try store.savePreferenceRecord(
            PreferenceRecord(subject: .actor, contenderId: "a", score: 1500, comparisons: 1))
        try store.savePreferenceRecord(
            PreferenceRecord(subject: .actor, contenderId: "a", score: 1560, comparisons: 2))

        XCTAssertEqual(try store.preferenceRecords(subject: .actor).count, 1)
        XCTAssertEqual(try store.preferenceRecord(subject: .actor, contenderId: "a")?.comparisons, 2)
    }

    // MARK: - P4 — retiring (D6's "neither")

    /// ⭐ Retiring keeps the score. "Does not belong in the ranking" is not
    /// "forget what we learned"; un-retiring must not restart from nothing.
    func testRetiringKeepsWhatWasLearned() throws {
        try store.savePreferenceRecord(
            PreferenceRecord(subject: .actor, contenderId: "a", score: 1820, comparisons: 22))

        try store.retirePreferenceContender(subject: .actor, contenderId: "a")

        let retired = try XCTUnwrap(try store.preferenceRecord(subject: .actor, contenderId: "a"))
        XCTAssertTrue(retired.retired)
        XCTAssertEqual(retired.score, 1820, accuracy: 0.000_001)
        XCTAssertEqual(retired.comparisons, 22)
    }

    /// ⚠️ Retiring a contender that has never played must not fail. "Neither"
    /// is answerable on the very first pair either contender appears in.
    func testANeverPlayedContenderCanBeRetired() throws {
        try store.retirePreferenceContender(subject: .actor, contenderId: "fresh")

        let record = try XCTUnwrap(try store.preferenceRecord(subject: .actor,
                                                              contenderId: "fresh"))
        XCTAssertTrue(record.retired)
        XCTAssertEqual(record.comparisons, 0)
    }

    func testRetiringIsReversible() throws {
        try store.retirePreferenceContender(subject: .actor, contenderId: "a")
        try store.retirePreferenceContender(subject: .actor, contenderId: "a", retired: false)

        XCTAssertEqual(try store.preferenceRecord(subject: .actor, contenderId: "a")?.retired,
                       false)
    }

    // MARK: - P5 — the migration is additive and safe to re-run

    /// ⚠️ Opening an existing library must not disturb it. Every migration in
    /// this project runs against the operator's live catalog.
    func testOpeningTwiceLeavesTheStandingsAlone() throws {
        try store.savePreferenceRecord(
            PreferenceRecord(subject: .actor, contenderId: "a", score: 1650, comparisons: 11))
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)

        let reopened = try LibraryStore(at: url)
        XCTAssertEqual(try reopened.preferenceRecord(subject: .actor, contenderId: "a")?.comparisons,
                       11)
    }

    // MARK: - 🚨 P6 — the schema keeps the game away from `rating`

    /// T5 at the storage layer. Playing writes `preference_score`; it has no
    /// reach into `entity_profiles` at all.
    func testStoringAStandingNeverTouchesTheProfileRating() throws {
        var profile = EntityProfile(id: UUID().uuidString, entityType: "actor",
                                    displayName: "Vera Example")
        profile.rating = 4
        try store.saveEntityProfile(profile)

        try store.savePreferenceRecord(
            PreferenceRecord(subject: .actor, contenderId: profile.id,
                             score: 1990, comparisons: 40))
        try store.retirePreferenceContender(subject: .actor, contenderId: profile.id)

        XCTAssertEqual(try store.fetchEntityProfile(for: profile.id)?.rating, 4,
                       "the hand-set rating is exactly as the operator left it")
    }

    /// ⚠️ And the reverse: the two live in different tables, so a profile write
    /// cannot clobber a standing either. This is the failure the v17/v18
    /// column-drop kept producing, and it is structurally impossible here.
    func testRewritingTheProfileDoesNotDisturbTheStanding() throws {
        let id = UUID().uuidString
        try store.saveEntityProfile(EntityProfile(id: id, entityType: "actor",
                                                  displayName: "Vera Example"))
        try store.savePreferenceRecord(
            PreferenceRecord(subject: .actor, contenderId: id, score: 1777, comparisons: 19))

        // The shape that dropped columns twice: rebuild the profile and save.
        var rebuilt = EntityProfile(id: id, entityType: "actor", displayName: "Vera Example")
        rebuilt.bio = "edited"
        try store.saveEntityProfile(rebuilt)

        let standing = try XCTUnwrap(try store.preferenceRecord(subject: .actor, contenderId: id))
        XCTAssertEqual(standing.score, 1777, accuracy: 0.000_001)
        XCTAssertEqual(standing.comparisons, 19)
    }
}
