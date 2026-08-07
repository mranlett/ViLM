import XCTest
@testable import LibraryCore

/// One studio stored under two spellings.
///
/// 🚨 These were routed to *Repair Tag Spelling* until 2026-08-06, which reads
/// `Asset.actions` — `tag:` values only. It could never have seen a `studio:`
/// value. The first test below is the one that proves why this file exists.
final class StudioSpellingAuditTests: XCTestCase {

    private func asset(studio: String) -> Asset {
        Asset(relativePath: "\(UUID()).mp4", fileName: "a.mp4",
              tags: ["studio:\(studio)"])
    }

    // MARK: - 🚨 Why the old routing could not work

    /// The tag tool's input is `Asset.actions`, and a studio is not in it.
    func testTheTagToolCannotSeeStudiosAtAll() {
        let assets = [asset(studio: "Coast Line"), asset(studio: "Coastline")]

        XCTAssertTrue(TagCaseAudit.tagCounts(in: assets).isEmpty,
                      "a studio never appears in the tag tool's input")
        XCTAssertEqual(StudioSpellingAudit.collisions(in: assets).count, 1,
                       "but the studio audit sees it")
    }

    // MARK: - Detection

    /// ⚠️ Folded with `StudioResolution.identity`, not `lowercased()` — the
    /// run-together spellings are the majority of real collisions and a
    /// case-only fold misses every one of them.
    func testSpacingDifferencesCollide() {
        let found = StudioSpellingAudit.collisions(in: [
            asset(studio: "Coast Line"), asset(studio: "Coastline"),
        ])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(Set(found[0].spellings.map(\.spelling)), ["Coast Line", "Coastline"])
    }

    func testCaseDifferencesCollide() {
        XCTAssertEqual(StudioSpellingAudit.collisions(in: [
            asset(studio: "Silver River"), asset(studio: "SILVER RIVER"),
        ]).count, 1)
    }

    func testGenuinelyDifferentStudiosDoNotCollide() {
        XCTAssertTrue(StudioSpellingAudit.collisions(in: [
            asset(studio: "Coast Line"), asset(studio: "Silver River"),
        ]).isEmpty)
    }

    func testOneSpellingIsNotACollision() {
        XCTAssertTrue(StudioSpellingAudit.collisions(in: [
            asset(studio: "Coast Line"), asset(studio: "Coast Line"),
        ]).isEmpty)
    }

    // MARK: - Which spelling to keep

    func testTheMostUsedSpellingWins() {
        var assets = [Asset](repeating: asset(studio: "Coastline"), count: 5)
        assets.append(asset(studio: "Coast Line"))

        XCTAssertEqual(StudioSpellingAudit.collisions(in: assets).first?.suggestedKeeper,
                       "Coastline")
    }

    /// ⚠️ On a tie, the SPACED form wins. A run-together name is what a source
    /// produces when it drops the spaces; the spaced one is what a person
    /// wrote.
    func testATieGoesToTheSpacedSpelling() {
        let found = StudioSpellingAudit.collisions(in: [
            asset(studio: "Coastline"), asset(studio: "Coast Line"),
        ])
        XCTAssertEqual(found.first?.suggestedKeeper, "Coast Line")
        XCTAssertEqual(found.first?.losers, ["Coastline"])
    }

    func testBiggestCollisionLeads() {
        var assets = [Asset](repeating: asset(studio: "Coast Line"), count: 4)
        assets.append(contentsOf: [Asset](repeating: asset(studio: "Coastline"), count: 4))
        assets.append(asset(studio: "Silver River"))
        assets.append(asset(studio: "SilverRiver"))

        XCTAssertEqual(StudioSpellingAudit.collisions(in: assets).first?.key,
                       StudioResolution.identity("Coast Line"))
    }

    /// Counted per asset — a video naming the same studio twice counts once.
    func testCountsAreByVideo() {
        let doubled = Asset(relativePath: "a.mp4", fileName: "a.mp4",
                            tags: ["studio:Coast Line", "studio:Coast Line"])
        let other = asset(studio: "Coastline")

        let found = StudioSpellingAudit.collisions(in: [doubled, other])
        XCTAssertEqual(found.first?.totalUses, 2)
    }

    // MARK: - Routing

    /// The finding must name the studio tool, not the tag one.
    func testTheFindingRoutesToTheStudioTool() {
        XCTAssertEqual(StudioCheck(kind: .spellingCollision, items: ["x"]).fix,
                       .repairStudioSpelling)
    }
}
