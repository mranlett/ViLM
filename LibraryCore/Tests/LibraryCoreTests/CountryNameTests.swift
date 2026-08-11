// CountryNameTests.swift
// One stored form per country (device report, 2026-08-11).
//
// 🚨 Measured before building: 94 stored values that were really 57 countries,
// 37 split across a flagged and an unflagged form, and 1,309 of 1,332 profiles
// on a split value. Filtering by country offered the same country twice with
// different people under each.
//
// ⚠️ The risk in a rule like this is over-reach. A country name can legitimately
// contain an accent, an apostrophe or a hyphen, and a fold that ate those would
// merge countries that are genuinely different — a far worse outcome than the
// duplication it set out to fix.

import XCTest
import GRDB
@testable import LibraryCore

final class CountryNameTests: XCTestCase {

    // MARK: - 🚨 The flag comes off

    func testAFlagIsRemoved() {
        XCTAssertEqual(CountryName.canonical("US 🇺🇸"), "US")
        XCTAssertEqual(CountryName.canonical("Russia 🇷🇺"), "Russia")
        XCTAssertEqual(CountryName.canonical("Czech Republic 🇨🇿"), "Czech Republic")
    }

    /// ⭐ The whole point: the two stored forms become one value.
    func testTheTwoFormsCollapseToTheSameString() {
        XCTAssertEqual(CountryName.canonical("US 🇺🇸"), CountryName.canonical("US"))
        XCTAssertEqual(CountryName.canonical("UK 🇬🇧"), CountryName.canonical("UK"))
    }

    func testABareNameIsUnchanged() {
        XCTAssertEqual(CountryName.canonical("Hungary"), "Hungary")
    }

    // MARK: - ⚠️ What it must NOT touch

    /// A fold that ate these would merge genuinely different countries.
    func testRealNamesKeepTheirPunctuationAndAccents() {
        XCTAssertEqual(CountryName.canonical("Côte d'Ivoire"), "Côte d'Ivoire")
        XCTAssertEqual(CountryName.canonical("Timor-Leste"), "Timor-Leste")
        XCTAssertEqual(CountryName.canonical("Bosnia and Herzegovina"),
                       "Bosnia and Herzegovina")
        XCTAssertEqual(CountryName.canonical("Trinidad & Tobago"), "Trinidad & Tobago")
    }

    /// ⭐ Case is preserved. "US" and "us" are not the same stored value, and
    /// folding case here would overrule the operator's spelling — a different
    /// decision from removing decoration, and not one this rule makes.
    func testCaseIsNotFolded() {
        XCTAssertEqual(CountryName.canonical("us"), "us")
    }

    // MARK: - Edges

    func testNilAndBlankBecomeNil() {
        XCTAssertNil(CountryName.canonical(nil))
        XCTAssertNil(CountryName.canonical(""))
        XCTAssertNil(CountryName.canonical("   "))
    }

    /// A value that is ONLY a flag has no name left, and an empty string would
    /// render as a country with no name rather than as no country.
    func testAValueThatIsOnlyAFlagBecomesNil() {
        XCTAssertNil(CountryName.canonical("🇺🇸"))
    }

    func testItIsIdempotent() {
        let once = CountryName.canonical("US 🇺🇸")
        XCTAssertEqual(CountryName.canonical(once), once)
    }

    // MARK: - 🚨 Enforced at the store, not at the call sites

    func testSavingCanonicalisesTheCountry() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Country-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer {
            LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
            try? FileManager.default.removeItem(at: url)
        }
        let store = try LibraryStore(at: url)

        var flagged = try store.newEntityProfile(named: "Ann Example", type: "actor")
        flagged.countryOfOrigin = "US 🇺🇸"
        try store.saveEntityProfile(flagged)

        var bare = try store.newEntityProfile(named: "Bea Example", type: "actor")
        bare.countryOfOrigin = "US"
        try store.saveEntityProfile(bare)

        let stored = Set(try store.fetchAllEntityProfiles().compactMap(\.countryOfOrigin))
        XCTAssertEqual(stored, ["US"],
                       "one country, one value — whichever writer got there first")
    }

    /// ⚠️ The old data. Migration v40 repairs what the previous writers left.
    func testTheMigrationRepairsExistingRows() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CountryMig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer {
            LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
            try? FileManager.default.removeItem(at: url)
        }
        let store = try LibraryStore(at: url)

        // Written behind the store's back, as the old writers did.
        let profile = try store.newEntityProfile(named: "Ann Example", type: "actor")
        try store.saveEntityProfile(profile)
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE entity_profiles SET country_of_origin = ? WHERE id = ?",
                           arguments: ["Russia 🇷🇺", profile.id])
        }
        XCTAssertEqual(try store.fetchEntityProfile(for: profile.id)?.countryOfOrigin,
                       "Russia 🇷🇺", "the flagged form is what v40 has to find")

        // ⚠️ v40 already ran when the store opened, and GRDB will not repeat
        // an applied migration. Forgetting it is what puts this library back
        // in the state a real device was in before the upgrade.
        try store.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v40'")
        }
        try store.migrate()

        XCTAssertEqual(try store.fetchEntityProfile(for: profile.id)?.countryOfOrigin,
                       "Russia")
    }
}
