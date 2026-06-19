import XCTest
@testable import LibraryCore

final class TagSuggesterTests: XCTestCase {
    
    func testSuggestionsForFilenames() {
        // User example 1
        XCTAssertEqual(
            TagSuggester.suggestions(for: "Small Wren - Halfpipe.mp4"),
            ["Small Wren", "Halfpipe"]
        )
        
        // User example 2
        XCTAssertEqual(
            TagSuggester.suggestions(for: "Alice Marsh - Peter Vance.mov"),
            ["Alice Marsh", "Peter Vance"]
        )
        
        // User example 3
        XCTAssertEqual(
            TagSuggester.suggestions(for: "Luna and Vince.mkv"),
            ["Luna", "Vince"]
        )
        
        // Edge cases
        XCTAssertEqual(
            TagSuggester.suggestions(for: "  Spaced out   -   tag  and tag2  .mp4"),
            ["Spaced out", "tag", "tag2"]
        )
        
        XCTAssertEqual(
            TagSuggester.suggestions(for: "No Separator At All.mp4"),
            ["No Separator At All"]
        )
    }
}
