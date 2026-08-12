// CountryFlagDecorationTests.swift
// The flag is PRESENTATION, and these tests exist to keep it that way (#53).
//
// 🚨 Migration v40 took the flag out of `country_of_origin` because storing
// presentation alongside the value split 57 real countries into 94 stored
// ones — 1,309 of 1,332 profiles sat on a split value. Putting the flag back
// for display is safe; putting it back into anything that gets MATCHED or
// SAVED reintroduces exactly that.
//
// So the filter pickers decorate the label only. What is selected, searched,
// alpha-filtered and persisted stays the bare stored name.

import XCTest
@testable import ViLM
import LibraryCore

final class CountryFlagDecorationTests: XCTestCase {

    // MARK: - Decoration is display-only

    /// ⭐ The property that makes the label safe: whatever the decoration does,
    /// the storage canonicaliser undoes. Even if a decorated string reached a
    /// write, it could not split the data.
    func testCanonicalisingADecoratedNameGivesTheBareNameBack() {
        for country in ["United States", "Russia", "Czech Republic", "England", "Japan"] {
            XCTAssertEqual(CountryName.canonical(CountryFlagHelper.withFlag(country)),
                           CountryName.canonical(country),
                           "decorating \(country) survived canonicalisation")
        }
    }

    /// ⚠️ Idempotent. A label can be rendered from an already-decorated value
    /// — the editors decorate their text field — and two flags is the visible
    /// symptom of the value having been stored decorated.
    func testDecoratingTwiceAddsOneFlag() {
        let once = CountryFlagHelper.withFlag("Russia")
        XCTAssertEqual(CountryFlagHelper.withFlag(once), once)
    }

    /// A country nothing is known about is left exactly as it is, rather than
    /// being given a wrong flag or an empty space.
    func testAnUnknownCountryIsUnchanged() {
        XCTAssertEqual(CountryFlagHelper.withFlag("Atlantis"), "Atlantis")
    }

    func testAnEmptyValueStaysEmpty() {
        XCTAssertEqual(CountryFlagHelper.withFlag(""), "")
        XCTAssertEqual(CountryFlagHelper.withFlag("   "), "")
    }

    // MARK: - The 57-not-94 property

    /// 🚨 The point of the cleanup. Decoration must not merge two countries
    /// into one row, nor split one into two — the list has as many entries
    /// after decorating as before, and they still map back one-to-one.
    func testDecorationNeitherMergesNorSplitsCountries() {
        let stored = ["United States", "United Kingdom", "Russia", "Japan",
                      "Czech Republic", "England", "Scotland", "Atlantis"]

        let labels = stored.map { CountryFlagHelper.withFlag($0) }
        XCTAssertEqual(Set(labels).count, stored.count,
                       "two countries collapsed onto one label")

        // And every label still identifies the value it came from.
        for (value, label) in zip(stored, labels) {
            XCTAssertEqual(CountryName.canonical(label), CountryName.canonical(value))
        }
    }

    /// ⚠️ The one that would actually break filtering. The grid matches on the
    /// bare lowercased value, so a decorated string must never be what the
    /// selection holds — this asserts the two are genuinely different, which is
    /// why the label is applied at the `Text` and nowhere else.
    func testADecoratedLabelWouldNotMatchTheStoredValue() {
        let stored = "Russia"
        let label = CountryFlagHelper.withFlag(stored)

        XCTAssertNotEqual(label.lowercased(), stored.lowercased(),
                          "if these were equal this test could not detect the mistake")
        // The grid's comparison, reproduced.
        XCTAssertFalse([stored.lowercased()].contains(label.lowercased()),
                       "selecting a decorated label would match nobody")
        XCTAssertTrue([stored.lowercased()].contains(stored.lowercased()))
    }
}
