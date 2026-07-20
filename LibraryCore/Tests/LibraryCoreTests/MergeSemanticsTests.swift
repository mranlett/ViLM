import XCTest
@testable import LibraryCore

/// The shared, non-destructive merge primitives — exercised through the
/// asset-level merge used by restore-over-existing.
final class MergeSemanticsTests: XCTestCase {

    private func asset(
        id: UUID = UUID(),
        relativePath: String = "v.mp4",
        status: Asset.ReviewStatus = .unreviewed,
        tags: [String] = [],
        notes: String? = nil,
        rating: Int? = nil,
        playCount: Int = 0,
        lastPlayed: Date? = nil
    ) -> Asset {
        Asset(id: id, relativePath: relativePath, fileName: "v.mp4", status: status,
              tags: tags, notes: notes, rating: rating, playCount: playCount, lastPlayedAt: lastPlayed)
    }

    func testARealArchiveValueWinsAConflict() {
        let src = asset(notes: "archive note", rating: 5)
        let dst = asset(notes: "dest note", rating: 2)
        let merged = MergeSemantics.mergeAsset(source: src, into: dst)
        XCTAssertEqual(merged.rating, 5)
        XCTAssertEqual(merged.notes, "archive note")
    }

    func testAnEmptyArchiveValueNeverWipesTheDestination() {
        let src = asset(notes: nil, rating: nil)
        let dst = asset(notes: "keep me", rating: 4)
        let merged = MergeSemantics.mergeAsset(source: src, into: dst)
        XCTAssertEqual(merged.rating, 4, "nil archive rating must not wipe the destination's")
        XCTAssertEqual(merged.notes, "keep me")
    }

    func testTagsAreUnionedNotReplaced() {
        let src = asset(tags: ["tag:Action", "actor:Jane"])
        let dst = asset(tags: ["tag:Action", "tag:Drama"])
        let merged = MergeSemantics.mergeAsset(source: src, into: dst)
        XCTAssertEqual(Set(merged.tags), ["tag:Action", "tag:Drama", "actor:Jane"])
    }

    func testReviewStatusNeverRegresses() {
        // Restoring an older (unreviewed) snapshot must not un-review a video.
        let src = asset(status: .unreviewed)
        let dst = asset(status: .reviewed)
        XCTAssertEqual(MergeSemantics.mergeAsset(source: src, into: dst).status, .reviewed)
        // …and an archived reviewed status promotes an unreviewed destination.
        let src2 = asset(status: .reviewed)
        let dst2 = asset(status: .unreviewed)
        XCTAssertEqual(MergeSemantics.mergeAsset(source: src2, into: dst2).status, .reviewed)
    }

    func testPlayCountAndLastPlayedTakeTheHigherValues() {
        let earlier = Date(timeIntervalSince1970: 100)
        let later = Date(timeIntervalSince1970: 200)
        let src = asset(playCount: 2, lastPlayed: earlier)
        let dst = asset(playCount: 5, lastPlayed: later)
        let merged = MergeSemantics.mergeAsset(source: src, into: dst)
        XCTAssertEqual(merged.playCount, 5, "play count never regresses")
        XCTAssertEqual(merged.lastPlayedAt, later)
    }

    func testIdentityAndOnDiskFieldsStayWithTheDestination() {
        // The file may have been renamed since the backup — keep the current path.
        let id = UUID()
        let src = asset(id: id, relativePath: "old-name.mp4")
        let dst = asset(id: id, relativePath: "renamed.mp4")
        XCTAssertEqual(MergeSemantics.mergeAsset(source: src, into: dst).relativePath, "renamed.mp4")
    }
}
