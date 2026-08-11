// NamelessProfileRepro.swift
// The device report of 2026-08-10: matching a newly-added actor showed a UUID
// as the name being overwritten, and the actor stayed on Missing Identities.
// Reported again for actors added by hand while editing a video's details,
// which is what ruled enrichment out and found the real cause.
//
// 🚨 ROOT CAUSE — `entityIdForWriting` returned `newEntityProfile(...).id`, and
// that factory SAVES NOTHING. The id it handed back named no row. Everything
// downstream then keyed edges and columns to an identifier with nothing behind
// it, and one discarded value produced all three symptoms:
//
//   • the actor rendered as its own uid — `name` is
//     `displayName ?? parsed-id ?? id`, and a uid parses as neither
//   • `fetchEntityProfile(named:type:)` could not find it, so the next visit
//     minted a SECOND id for the same person
//   • `Missing Identities` dropped it for having no kind, and reported clean
//
// ⭐ The first symptom is now unrepresentable rather than merely fixed:
// `ActorEnrichment.apply` takes a non-optional profile, so the call that
// produced an identity-less row no longer compiles.

import XCTest
import GRDB
@testable import LibraryCore

final class NamelessProfileRepro: XCTestCase {

    private var url: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Nameless-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store = try LibraryStore(at: url)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - 🚨 The root cause

    /// Adding an actor by hand to a video's details goes through this.
    func testAnIdMintedForWritingHasARowBehindIt() throws {
        let id = try store.entityIdForWriting(named: "Tom Example", type: "actor")

        let saved = try XCTUnwrap(try store.fetchEntityProfile(for: id),
                                  "the id must name a row that exists")
        XCTAssertEqual(saved.displayName, "Tom Example")
        XCTAssertEqual(saved.entityType, "actor")
        XCTAssertEqual(saved.name, "Tom Example", "and never renders as its own uid")
    }

    /// ⚠️ And it is findable by the name it was created under — the lookup
    /// every later path uses. Without this the next visit mints a SECOND id for
    /// the same person, which is how one performer becomes two rows.
    func testTheMintedRowIsFoundByNameAfterwards() throws {
        let id = try store.entityIdForWriting(named: "Tom Example", type: "actor")
        XCTAssertEqual(try store.entityIdForWriting(named: "Tom Example", type: "actor"), id,
                       "asking twice returns the same node, not a duplicate")
        XCTAssertEqual(try store.fetchEntityProfile(named: "Tom Example", type: "actor")?.id, id)
    }

    /// ⭐ An existing row is never disturbed — minting only fills a gap.
    func testAnExistingRowIsReturnedUntouched() throws {
        var existing = try store.newEntityProfile(named: "Tom Example", type: "actor")
        existing.bio = "written by hand"
        try store.saveEntityProfile(existing)

        let id = try store.entityIdForWriting(named: "Tom Example", type: "actor")

        XCTAssertEqual(id, existing.id)
        XCTAssertEqual(try store.fetchEntityProfile(for: id)?.bio, "written by hand",
                       "minting must not overwrite the record it found")
    }

    // MARK: - 🚨 The audit no longer hides the damage

    /// Rows already damaged on the device look like this: an id, and nothing
    /// else. The audit used to drop them for having no kind — so the one screen
    /// that should have caught this reported the library clean.
    func testADamagedRowIsReportedRatherThanDropped() throws {
        let uid = UUID().uuidString
        var damaged = EntityProfile(id: uid)
        damaged.enrichmentState = .matched
        try store.saveEntityProfile(damaged)

        let gaps = try store.identityGaps().gaps
        XCTAssertEqual(gaps.count, 1, "reported, not silently dropped")
        XCTAssertNil(gaps.first?.kind)
        XCTAssertTrue(gaps.first?.isDamaged ?? false)
        XCTAssertEqual(gaps.first?.displayName, uid,
                       "under its uid, which is all there is to show")
    }

    /// ⚠️ Damaged rows sort FIRST. An ordinary gap is fixed by matching; this
    /// one is not, and burying it under a hundred routine rows is how it stays
    /// unfixed.
    func testDamagedRowsSortAboveOrdinaryGaps() throws {
        var ordinary = try store.newEntityProfile(named: "Ann Example", type: "actor")
        ordinary.enrichmentState = .matched
        try store.saveEntityProfile(ordinary)

        var damaged = EntityProfile(id: UUID().uuidString)
        damaged.enrichmentState = .matched
        try store.saveEntityProfile(damaged)

        let gaps = try store.identityGaps().gaps
        XCTAssertEqual(gaps.count, 2)
        XCTAssertTrue(gaps.first?.isDamaged ?? false)
        XCTAssertEqual(gaps.last?.displayName, "Ann Example")
    }

    /// ⭐ A well-formed gap is unaffected — the fix must not turn the audit
    /// into a screen that always has something to complain about.
    func testAWellFormedGapIsUnaffected() throws {
        var ordinary = try store.newEntityProfile(named: "Ann Example", type: "actor")
        ordinary.enrichmentState = .matched
        try store.saveEntityProfile(ordinary)

        let gap = try XCTUnwrap(try store.identityGaps().gaps.first)
        XCTAssertEqual(gap.kind, .actor)
        XCTAssertFalse(gap.isDamaged)
        XCTAssertEqual(gap.displayName, "Ann Example")
    }
}
