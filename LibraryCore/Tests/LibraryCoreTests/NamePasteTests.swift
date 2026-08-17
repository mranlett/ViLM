// NamePasteTests.swift
// Pasting a cast list read off a page.
//
// ⚠️ All names invented. This repository is public.

import XCTest
@testable import LibraryCore

final class NamePasteTests: XCTestCase {

    /// ⚠️ The library's OWN spelling differs from the source's in casing,
    /// which is the whole point of canonicalising a paste.
    private let vocabulary = NameVocabulary(
        actors: ["Alice Example", "Bob Example", "Carol Example", "Bill and Ted"],
        studios: ["Example Pictures"],
        tags: ["Outdoors"])

    private func read(_ text: String, as kind: NamePaste.Kind = .actor) -> PastedNames {
        NamePaste.read(text, as: kind, vocabulary: vocabulary)
    }

    // MARK: - The ordinary case

    func testACommaSeparatedListBecomesNames() {
        let names = read("Alice Example, Bob Example, Carol Example")
        XCTAssertEqual(names.known, ["Alice Example", "Bob Example", "Carol Example"])
        XCTAssertTrue(names.unknown.isEmpty)
    }

    func testNewlinesSemicolonsAndAmpersandsAlsoSeparate() {
        XCTAssertEqual(read("Alice Example\nBob Example").known.count, 2)
        XCTAssertEqual(read("Alice Example; Bob Example").known.count, 2)
        XCTAssertEqual(read("Alice Example & Bob Example").known.count, 2)
    }

    /// 🚨 The library's spelling wins. A source that writes a name differently
    /// must not split one performer into two records — the defect #76 was.
    func testTheLibrarysSpellingWinsOverThePastedOne() {
        XCTAssertEqual(read("ALICE EXAMPLE, bob example").known,
                       ["Alice Example", "Bob Example"])
    }

    func testRepeatsAreCollapsed() {
        XCTAssertEqual(read("Alice Example, Alice Example, ALICE EXAMPLE").known,
                       ["Alice Example"])
    }

    // MARK: - 🚨 Nothing is created

    func testAnUnknownNameIsReportedAndNotAdopted() {
        let names = read("Alice Example, Someone Unheard Of")
        XCTAssertEqual(names.known, ["Alice Example"])
        XCTAssertEqual(names.unknown, ["Someone Unheard Of"])
        XCTAssertEqual(NamePaste.tags(for: names, as: .actor), ["actor:Alice Example"],
                       "only the known ones become tags")
    }

    // MARK: - ⚠️ "and" is a second chance, not a separator

    /// A real name containing "and" survives, because the whole segment is
    /// tried first. Splitting on the word at the top level fails silently,
    /// which is the worst way for a paste to be wrong.
    func testANameContainingAndIsNotSplit() {
        XCTAssertEqual(read("Bill and Ted").known, ["Bill and Ted"])
    }

    /// And a segment the library does NOT recognise gets one more chance to be
    /// two people.
    func testAnUnrecognisedSegmentIsRetriedAsTwoNames() {
        let names = read("Alice Example and Bob Example")
        XCTAssertEqual(names.known, ["Alice Example", "Bob Example"])
        XCTAssertTrue(names.unknown.isEmpty)
    }

    /// ⚠️ And when splitting does not help either, BOTH halves are not invented
    /// as unknowns — the failure is reported once, as the two parts.
    func testSplittingThatHelpsNobodyStillReportsWhatWasThere() {
        let names = read("Nobody Here and Nobody There")
        XCTAssertEqual(names.known, [])
        XCTAssertEqual(names.unknown, ["Nobody Here", "Nobody There"])
    }

    // MARK: - What a pasted line carries around a name

    func testListMarkersAreStripped() {
        XCTAssertEqual(read("- Alice Example\n* Bob Example\n1. Carol Example").known,
                       ["Alice Example", "Bob Example", "Carol Example"])
    }

    /// ⚠️ These listings routinely write "Name (as Something Else)". The
    /// credited-as spelling belongs to the appearance, not the person, so it is
    /// not part of the name being looked up.
    func testATrailingParentheticalIsDropped() {
        XCTAssertEqual(read("Alice Example (as Ally X)").known, ["Alice Example"])
    }

    func testWhitespaceAndEmptySegmentsAreIgnored() {
        XCTAssertTrue(read("  ,  ,\n\n  ").isEmpty)
    }

    // MARK: - The other kinds

    func testTagsAndStudiosUseTheirOwnVocabularies() {
        XCTAssertEqual(read("Outdoors", as: .tag).known, ["Outdoors"])
        XCTAssertEqual(NamePaste.tags(for: read("Outdoors", as: .tag), as: .tag),
                       ["tag:Outdoors"])
        XCTAssertEqual(read("Example Pictures", as: .studio).known, ["Example Pictures"])
        // ⚠️ A performer is not a tag. The vocabularies are separate and a name
        // in the wrong box is unknown, not silently accepted.
        XCTAssertEqual(read("Alice Example", as: .tag).unknown, ["Alice Example"])
    }
}
