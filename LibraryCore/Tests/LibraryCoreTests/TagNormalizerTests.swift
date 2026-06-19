import XCTest
@testable import LibraryCore

final class TagNormalizerTests: XCTestCase {
    
    func testNormalizeValue() {
        XCTAssertEqual(TagNormalizer.normalize(tagValue: "running"), "Running")
        XCTAssertEqual(TagNormalizer.normalize(tagValue: "running fast"), "Running Fast")
        XCTAssertEqual(TagNormalizer.normalize(tagValue: "  Spaced Out "), "Spaced Out")
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
