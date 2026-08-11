// PhotoTopUpConvergenceTests.swift
// The worklist has to be finishable (device report, 2026-08-10).
//
// 🚨 "Fewer than N photos" is a question about OUR holdings, but whether it can
// ever be satisfied depends on the SOURCE's. A performer the source has one
// picture of can never reach a threshold of three, so they sat on the list
// permanently and cost a request on every run — the list could not be worked to
// the end, which is the one property a worklist has to have.

import XCTest
@testable import LibraryCore

final class PhotoTopUpConvergenceTests: XCTestCase {

    private func actor(_ name: String, photos: Int,
                       askedAt: Date? = nil, held: Int? = nil) -> EntityProfile {
        var p = EntityProfile(id: UUID().uuidString, entityType: "actor", displayName: name)
        p.enrichmentSource = "TheSource"
        p.enrichmentSourceId = "p-\(name)"
        p.galleryUrls = (0..<photos).map { "https://example.test/\(name)-\($0).jpg" }
        p.photoTopUpAt = askedAt
        p.photoTopUpHeld = held
        return p
    }

    // MARK: - 🚨 It converges

    func testAPerformerTheSourceHasNothingMoreForLeavesTheList() {
        let thin = actor("Ann", photos: 1)
        XCTAssertEqual(ActorPhotoTopUp.worklist([thin], threshold: 3).count, 1)

        let asked = ActorPhotoTopUp.markingExhausted(thin)

        XCTAssertTrue(ActorPhotoTopUp.worklist([asked], threshold: 3).isEmpty,
                      "asked, and the source had nothing more")
    }

    /// ⚠️ And it stays gone across runs, which is the actual complaint —
    /// re-opening the tool must not resurrect them.
    func testItStaysGoneOnALaterRun() {
        let asked = ActorPhotoTopUp.markingExhausted(actor("Ann", photos: 1))
        for _ in 0..<3 {
            XCTAssertTrue(ActorPhotoTopUp.worklist([asked], threshold: 3).isEmpty)
        }
    }

    // MARK: - ⭐ But it is not permanent

    /// A picture arriving by ANY route re-qualifies them, with nothing else
    /// having to remember to clear a flag. This is why the mark stores the
    /// count held rather than being a boolean.
    func testANewPhotoFromAnyRouteBringsThemBack() {
        var asked = ActorPhotoTopUp.markingExhausted(actor("Ann", photos: 1))
        XCTAssertTrue(ActorPhotoTopUp.worklist([asked], threshold: 3).isEmpty)

        // Added by an enrichment, or by hand — not by this tool.
        asked.galleryUrls.append("https://example.test/Ann-new.jpg")

        XCTAssertEqual(ActorPhotoTopUp.worklist([asked], threshold: 3).count, 1,
                       "the source may have gained pictures since")
    }

    /// ⚠️ And they can always be shown deliberately. "Nothing more" is a fact
    /// about a moment, not forever.
    func testTheyCanBeAskedForExplicitly() {
        let asked = ActorPhotoTopUp.markingExhausted(actor("Ann", photos: 1))

        XCTAssertEqual(
            ActorPhotoTopUp.worklist([asked], threshold: 3, includingExhausted: true).count, 1)
    }

    // MARK: - What must not change

    /// 🚨 Never asked is not asked-and-empty. A performer with no mark stays on
    /// the list — otherwise the fix would hide the very people it exists for.
    func testAPerformerNeverAskedIsUnaffected() {
        XCTAssertEqual(ActorPhotoTopUp.worklist([actor("Ann", photos: 1)], threshold: 3).count, 1)
    }

    /// A half-written mark is not a mark. Neither column alone means anything.
    func testAMarkWithOnlyOneHalfIsIgnored() {
        XCTAssertFalse(ActorPhotoTopUp.isExhausted(actor("Ann", photos: 1, askedAt: Date())))
        XCTAssertFalse(ActorPhotoTopUp.isExhausted(actor("Ann", photos: 1, held: 1)))
    }

    /// ⭐ Someone already above the threshold is still absent for the ordinary
    /// reason, mark or no mark.
    func testAWellCoveredPerformerIsStillAbsent() {
        XCTAssertTrue(ActorPhotoTopUp.worklist([actor("Ann", photos: 5)], threshold: 3).isEmpty)
    }

    /// ⚠️ The mark records what was held AT THE TIME, so a performer who has
    /// since LOST a photo does not silently reappear on a technicality.
    func testLosingAPhotoDoesNotResurrectThem() {
        var asked = ActorPhotoTopUp.markingExhausted(actor("Ann", photos: 2))
        asked.galleryUrls.removeLast()

        XCTAssertTrue(ActorPhotoTopUp.worklist([asked], threshold: 3).isEmpty,
                      "fewer than we held is not evidence the source gained any")
    }
}
