import XCTest
@testable import LibraryCore

final class TagNormalizerTests: XCTestCase {
    
    func testNormalizeValue() {
        XCTAssertEqual(TagNormalizer.normalize(tagValue: "running"), "Running")
        XCTAssertEqual(TagNormalizer.normalize(tagValue: "running fast"), "Running Fast")
        XCTAssertEqual(TagNormalizer.normalize(tagValue: "  Spaced Out "), "Spaced Out")
    }
    
    func testTitleCased() {
        XCTAssertEqual(TagNormalizer.titleCased("the return of the king"), "The Return Of The King")
        // Capitalization the writer typed is PRESERVED. The previous rule
        // lowercased everything past the first letter, which flattened every
        // acronym and every name with a capital inside it — POV to Pov, SCUBA to
        // Scuba, O'Brien to O'brien. There is no way to tell an acronym from a
        // shouted ordinary word without a dictionary, so the cost of getting it
        // wrong decides: preserving is recoverable by retyping, flattening
        // destroys information for good.
        //
        // The price is that shouting survives too, which is the deliberate
        // trade.
        XCTAssertEqual(TagNormalizer.titleCased("THE HEIST"), "THE HEIST")
        XCTAssertEqual(TagNormalizer.titleCased("iCarly gOES hOME"), "iCarly gOES hOME")
        // Apostrophes are NOT word breaks (the key difference from .capitalized).
        XCTAssertEqual(TagNormalizer.titleCased("valentine's day"), "Valentine's Day")
        // Hyphens ARE word breaks, and the hyphen is preserved.
        XCTAssertEqual(TagNormalizer.titleCased("spider-man"), "Spider-Man")
        XCTAssertEqual(TagNormalizer.titleCased("x-men: first class"), "X-Men: First Class")
        // Collapses/ trims whitespace.
        XCTAssertEqual(TagNormalizer.titleCased("  pilot   episode  "), "Pilot Episode")
        XCTAssertEqual(TagNormalizer.titleCased(""), "")
        XCTAssertEqual(TagNormalizer.titleCased("   "), "")
    }

    func testNormalizeFullTag() {
        XCTAssertEqual(TagNormalizer.normalize(fullTag: "actor:luna"), "actor:Luna")
        XCTAssertEqual(TagNormalizer.normalize(fullTag: "tag:running fast"), "tag:Running Fast")
        // No prefix
        XCTAssertEqual(TagNormalizer.normalize(fullTag: "lone tag"), "Lone Tag")
    }
    
    func testAssetNormalization() {
        let asset = Asset(
            relativePath: "test.mp4",
            fileName: "test.mp4",
            tags: ["actor:vince palmer", "tag:running"]
        )
        
        XCTAssertEqual(asset.tags, ["actor:Vince Palmer", "tag:Running"])
    }
    
    func testAssetStudios() {
        let asset = Asset(
            relativePath: "test.mp4",
            fileName: "test.mp4",
            tags: ["studio:halfpipe", "actor:luna"]
        )
        
        XCTAssertEqual(asset.studios, ["Halfpipe"])
    }
    
    func testSuggestedFileNameFromTags() {
        var asset = Asset(
            relativePath: "my_video.mp4",
            fileName: "my_video.mp4",
            tags: ["actor:Luna", "actor:Vince", "tag:Running", "studio:Halfpipe"]
        )
        XCTAssertEqual(asset.suggestedFileNameFromTags, "Luna, Vince - Running - Halfpipe.mp4")
        
        // No studios
        asset.tags = ["actor:Luna", "tag:Running Fast"]
        XCTAssertEqual(asset.suggestedFileNameFromTags, "Luna - Running Fast.mp4")
        
        // No tags at all
        asset.tags = []
        XCTAssertNil(asset.suggestedFileNameFromTags)
        
        // No extension
        asset = Asset(
            relativePath: "my_video",
            fileName: "my_video",
            tags: ["actor:Luna"]
        )
        XCTAssertEqual(asset.suggestedFileNameFromTags, "Luna")
    }
}

/// The capitalization contract, stated as the cases that drove it.
extension TagNormalizerTests {

    /// Acronyms. The reported failure: these were being flattened to Pov, Scuba.
    func testAcronymsSurvive() {
        XCTAssertEqual(TagNormalizer.normalize(tagValue: "POV"), "POV")
        XCTAssertEqual(TagNormalizer.normalize(tagValue: "SCUBA"), "SCUBA")
        XCTAssertEqual(TagNormalizer.normalize(tagValue: "SCUBA (30+)"), "SCUBA (30+)")
        XCTAssertEqual(TagNormalizer.normalize(tagValue: "4K Available"), "4K Available")
    }

    /// Names with a capital inside them — the other half of the report.
    func testInternalCapitalsSurvive() {
        XCTAssertEqual(TagNormalizer.normalize(tagValue: "Erin O'Brien"), "Erin O'Brien")
        XCTAssertEqual(TagNormalizer.normalize(tagValue: "Anna MacLeod"), "Anna MacLeod")
        XCTAssertEqual(TagNormalizer.normalize(tagValue: "RoseAnn Blue"), "RoseAnn Blue")
        XCTAssertEqual(TagNormalizer.normalize(tagValue: "iPhone Footage"), "iPhone Footage")
    }

    /// Unstyled input is still tidied — the reason this function exists.
    func testAllLowercaseIsStillCapitalized() {
        XCTAssertEqual(TagNormalizer.normalize(tagValue: "running fast"), "Running Fast")
        XCTAssertEqual(TagNormalizer.normalize(tagValue: "  outdoors  "), "Outdoors")
        XCTAssertEqual(TagNormalizer.normalize(tagValue: "spider-man"), "Spider-Man")
    }

    /// A word already capitalized correctly is left exactly as it is, rather
    /// than being rebuilt into the same string by a different route.
    func testAlreadyCorrectInputIsUnchanged() {
        for value in ["Deep Dive", "Big Skies", "Valentine's Day", "X-Men"] {
            XCTAssertEqual(TagNormalizer.normalize(tagValue: value), value)
        }
    }

    /// Entries written under the OLD rule read "Pov" and "Scuba". A writer typing
    /// "POV" today must not create a second tag beside the first.
    func testOldAndNewSpellingsAreRecognizedAsOneTag() {
        XCTAssertTrue(TagNormalizer.isSameTag("Pov", "POV"))
        XCTAssertTrue(TagNormalizer.isSameTag("Scuba", "SCUBA"))
        XCTAssertTrue(TagNormalizer.isSameTag("Erin O'brien", "Erin O'Brien"))
        XCTAssertFalse(TagNormalizer.isSameTag("Climbing", "Climbdown"))
    }

    func testPrefixedTagsKeepTheirCategory() {
        XCTAssertEqual(TagNormalizer.normalize(fullTag: "tag:POV"), "tag:POV")
        XCTAssertEqual(TagNormalizer.normalize(fullTag: "actor:erin o'Brien"),
                       "actor:Erin o'Brien")
    }
}
