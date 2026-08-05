import XCTest
@testable import LibraryCore

/// Videos carrying more than one studio.
///
/// A scene has one releasing studio, so this is exactly wrong rather than
/// probably wrong — no vocabulary, no threshold, no judgement in the detection.
final class StudioConflictAuditTests: XCTestCase {

    private func asset(_ studios: [String], extra: [String] = []) -> Asset {
        Asset(relativePath: "\(UUID()).mp4", fileName: "a.mp4",
              tags: studios.map { "studio:\($0)" } + extra)
    }

    func testOneStudioIsNotAConflict() {
        XCTAssertTrue(StudioConflictAudit.conflicts(in: [asset(["Right"])]).isEmpty)
        XCTAssertTrue(StudioConflictAudit.conflicts(in: [asset([])]).isEmpty)
    }

    func testTwoStudiosOnOneVideoIsAConflict() {
        let found = StudioConflictAudit.conflicts(in: [asset(["Wrong", "Right"])])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].studios, ["Right", "Wrong"], "sorted, so the group is stable")
        XCTAssertEqual(found[0].videoCount, 1)
    }

    /// The same wrong pairing repeats — one bad run produces it across every
    /// video it touched — so they are resolved together.
    func testTheSamePairingIsOneGroup() {
        let found = StudioConflictAudit.conflicts(in: [
            asset(["Wrong", "Right"]), asset(["Right", "Wrong"]), asset(["Other", "Right"])
        ])
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found[0].videoCount, 2, "biggest group first")
    }

    /// The best evidence available: a studio standing alone across many videos
    /// is established; one that only ever appears beside another arrived by
    /// accident.
    func testTheStudioUsedAloneElsewhereIsSuggested() {
        var library = [Asset](repeating: asset(["Right"]), count: 5)
        library.append(asset(["Wrong", "Right"]))
        let found = StudioConflictAudit.conflicts(in: library)
        XCTAssertEqual(found[0].suggestedKeeper, "Right")
    }

    /// A broken video cannot be evidence about which of its own studios is
    /// right, so only single-studio videos count toward that.
    func testConflictedVideosDoNotVoteOnThemselves() {
        let library = [asset(["Wrong", "Right"]), asset(["Wrong", "Right"]),
                       asset(["Wrong", "Right"]), asset(["Right"])]
        XCTAssertEqual(StudioConflictAudit.conflicts(in: library)[0].suggestedKeeper, "Right",
                       "three uses of Wrong, all of them inside the broken state")
    }

    func testResolvingKeepsOnlyTheChosenStudio() {
        let resolved = StudioConflictAudit.resolving(asset(["Wrong", "Right"]), keeping: "Right")
        XCTAssertEqual(resolved.studios, ["Right"])
    }

    /// Cast and tags share the same array and must survive untouched.
    func testResolvingLeavesEverythingElseAlone() {
        let subject = asset(["Wrong", "Right"], extra: ["actor:Someone", "tag:Outdoors"])
        let resolved = StudioConflictAudit.resolving(subject, keeping: "Right")
        XCTAssertEqual(resolved.studios, ["Right"])
        XCTAssertEqual(resolved.actors, ["Someone"])
        XCTAssertEqual(resolved.actions, ["Outdoors"])
    }

    func testResolvingIsCaseInsensitive() {
        let resolved = StudioConflictAudit.resolving(asset(["Wrong", "Right"]), keeping: "right")
        XCTAssertEqual(resolved.studios, ["Right"], "the stored spelling survives")
    }
}
