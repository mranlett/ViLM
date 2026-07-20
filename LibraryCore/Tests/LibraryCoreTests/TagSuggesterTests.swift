import XCTest
@testable import LibraryCore

final class TagSuggesterTests: XCTestCase {

    // MARK: - Core delimiter behavior (one scenario per test, so a regression
    // in one case doesn't mask the status of the others)

    func testSplitsActorAndStudioByDash() {
        XCTAssertEqual(
            TagSuggester.suggestions(for: "Small Wren - Halfpipe.mp4"),
            ["Small Wren", "Halfpipe"]
        )
    }

    func testSplitsTwoActorsByDash() {
        XCTAssertEqual(
            TagSuggester.suggestions(for: "Alice Marsh - Peter Vance.mov"),
            ["Alice Marsh", "Peter Vance"]
        )
    }

    func testSplitsByAndKeyword() {
        XCTAssertEqual(
            TagSuggester.suggestions(for: "Luna and Vince.mkv"),
            ["Luna", "Vince"]
        )
    }

    func testAndKeywordIsCaseInsensitive() {
        // The " and " split uses a (?i) regex; an uppercase "AND" must split too.
        XCTAssertEqual(
            TagSuggester.suggestions(for: "Luna AND Vince.mkv"),
            ["Luna", "Vince"]
        )
    }

    func testSplitsByComma() {
        // The regex also treats a comma (with optional trailing space) as a
        // separator — a distinct branch from the " and " split.
        XCTAssertEqual(
            TagSuggester.suggestions(for: "Luna, Vince.mp4"),
            ["Luna", "Vince"]
        )
    }

    func testTrimsSurroundingWhitespaceAcrossMixedDelimiters() {
        XCTAssertEqual(
            TagSuggester.suggestions(for: "  Spaced out   -   tag  and tag2  .mp4"),
            ["Spaced out", "tag", "tag2"]
        )
    }

    func testNoSeparatorReturnsWholeNameAsOneSuggestion() {
        XCTAssertEqual(
            TagSuggester.suggestions(for: "No Separator At All.mp4"),
            ["No Separator At All"]
        )
    }

    // MARK: - Negative / edge cases (previously untested)

    func testDeduplicatesRepeatedTokensPreservingOrder() {
        // The same name appearing twice collapses to a single suggestion.
        XCTAssertEqual(
            TagSuggester.suggestions(for: "Jane and Jane.mp4"),
            ["Jane"]
        )
    }

    func testEmptyFilenameYieldsNoSuggestions() {
        XCTAssertEqual(TagSuggester.suggestions(for: ""), [])
    }

    func testWhitespaceOnlyFilenameYieldsNoSuggestions() {
        XCTAssertEqual(TagSuggester.suggestions(for: "    .mp4"), [])
    }

    func testDanglingDelimitersDoNotProduceEmptySuggestions() {
        // A trailing separator must not yield an empty-string tag.
        XCTAssertEqual(
            TagSuggester.suggestions(for: "Solo Name - .mp4"),
            ["Solo Name"]
        )
    }
}
