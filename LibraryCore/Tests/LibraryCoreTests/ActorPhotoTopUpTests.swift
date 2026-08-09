// ActorPhotoTopUpTests.swift
// Topping up thin galleries (#44).
//
// 🚨 P1 is the reason this file exists. R4 of the Actor & Tag Browsing spec was
// three stacked bugs about a starred photo not becoming the profile picture,
// each invisible until the one before it was fixed. A tool that re-fetches
// images is exactly where a fourth comes from, and the assertion that stops it
// is that `photoUrl` is untouched no matter what the source sends.

import XCTest
@testable import LibraryCore

final class ActorPhotoTopUpTests: XCTestCase {

    private func actor(_ name: String, photo: String? = nil, gallery: [String] = [],
                       sourceId: String? = "p-1", source: String? = "TheSource")
    -> EntityProfile {
        var p = EntityProfile(id: UUID().uuidString, entityType: "actor", displayName: name)
        p.photoUrl = photo
        p.galleryUrls = gallery
        p.enrichmentSourceId = sourceId
        p.enrichmentSource = source
        return p
    }

    private func urls(_ s: String...) -> [URL] { s.compactMap(URL.init(string:)) }

    // MARK: - 🚨 P1 — the starred primary is untouchable

    func testP1TheHandSetPrimaryIsNeverChanged() {
        let profile = actor("Vera Example", photo: "https://mine/starred.jpg")

        let updated = ActorPhotoTopUp.applying(
            urls("https://src/a.jpg", "https://src/b.jpg"), to: profile)

        XCTAssertEqual(updated?.photoUrl, "https://mine/starred.jpg",
                       "the source's idea of a primary is not the operator's choice")
        XCTAssertEqual(updated?.galleryUrls, ["https://src/a.jpg", "https://src/b.jpg"])
    }

    /// ⚠️ Even when the source sends an image that IS the current primary. It
    /// joins the gallery like any other; it does not reassign anything.
    func testTheSourceReturningThePrimaryDoesNotReassignIt() {
        let profile = actor("Vera Example", photo: "https://src/a.jpg")

        let updated = ActorPhotoTopUp.applying(urls("https://src/a.jpg"), to: profile)

        XCTAssertEqual(updated?.photoUrl, "https://src/a.jpg")
        XCTAssertEqual(updated?.galleryUrls, ["https://src/a.jpg"])
    }

    // MARK: - Adding, never replacing

    /// 🚨 Photos the operator added by hand survive. Replacing the array
    /// instead of appending would discard them silently.
    func testExistingGalleryEntriesSurvive() {
        let profile = actor("Vera Example", photo: "https://mine/p.jpg",
                            gallery: ["https://mine/hand-added.jpg"])

        let updated = ActorPhotoTopUp.applying(urls("https://src/new.jpg"), to: profile)

        XCTAssertEqual(updated?.galleryUrls,
                       ["https://mine/hand-added.jpg", "https://src/new.jpg"])
    }

    func testAlreadyHeldImagesAreNotAddedAgain() {
        let profile = actor("Vera Example", gallery: ["https://src/a.jpg"])
        XCTAssertNil(ActorPhotoTopUp.applying(urls("https://src/a.jpg"), to: profile),
                     "nothing new means no change at all")
    }

    /// ⚠️ A source listing one image twice must not add two entries.
    func testARepeatedSourceImageIsAddedOnce() {
        let profile = actor("Vera Example")
        let updated = ActorPhotoTopUp.applying(
            urls("https://src/a.jpg", "https://src/a.jpg"), to: profile)

        XCTAssertEqual(updated?.galleryUrls, ["https://src/a.jpg"])
    }

    func testNothingFetchedIsNoChange() {
        XCTAssertNil(ActorPhotoTopUp.applying([], to: actor("Vera Example")))
    }

    // MARK: - The worklist

    func testTheThinnestComeFirst() {
        let list = ActorPhotoTopUp.worklist([
            actor("Two", photo: "p", gallery: ["a"]),
            actor("None"),
            actor("One", photo: "p"),
        ], threshold: 5)

        XCTAssertEqual(list.map(\.profile.name), ["None", "One", "Two"])
        XCTAssertEqual(list.map(\.photoCount), [0, 1, 2])
    }

    /// ⚠️ Ties break by name. Hundreds of actors have exactly one photo, and
    /// without this the list would reshuffle every time it opened.
    func testTiesBreakByNameSoTheListIsStable() {
        let profiles = [actor("Charlie", photo: "p"), actor("alpha", photo: "p"),
                        actor("Bravo", photo: "p")]
        let forward = ActorPhotoTopUp.worklist(profiles).map(\.profile.name)
        let backward = ActorPhotoTopUp.worklist(profiles.reversed()).map(\.profile.name)

        XCTAssertEqual(forward, ["alpha", "Bravo", "Charlie"])
        XCTAssertEqual(forward, backward)
    }

    func testAdequatelyCoveredActorsAreLeftOut() {
        let list = ActorPhotoTopUp.worklist([
            actor("Thin", photo: "p"),
            actor("Covered", photo: "p", gallery: ["a", "b", "c"]),
        ])
        XCTAssertEqual(list.map(\.profile.name), ["Thin"])
    }

    /// ⚠️ A profile whose primary also appears in its gallery has ONE picture,
    /// not two — counting it twice would hide a thin profile from the very
    /// list built to find it.
    func testAPrimaryThatIsAlsoInTheGalleryCountsOnce() {
        let profile = actor("Vera Example", photo: "https://src/a.jpg",
                            gallery: ["https://src/a.jpg"])
        XCTAssertEqual(ActorPhotoTopUp.imageCount(profile), 1)
        XCTAssertEqual(ActorPhotoTopUp.worklist([profile]).count, 1, "still needs topping up")
    }

    // MARK: - Who can actually be fetched

    /// ⚠️ Listed, not dropped. An unmatched performer with one photo belongs in
    /// a list of people with one photo; hiding them leaves the operator
    /// wondering why the count does not add up.
    func testAnUnmatchedActorIsListedButFlaggedAsUnfetchable() {
        let list = ActorPhotoTopUp.worklist([
            actor("Matched", photo: "p"),
            actor("Unmatched", photo: "p", sourceId: nil, source: nil),
        ])

        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list.first { $0.profile.name == "Unmatched" }?.canFetch, false)
        XCTAssertEqual(list.first { $0.profile.name == "Matched" }?.canFetch, true)
    }

    func testAnEmptySourceIdCountsAsUnmatched() {
        let list = ActorPhotoTopUp.worklist([actor("Blank", photo: "p", sourceId: "")])
        XCTAssertEqual(list.first?.canFetch, false)
    }
}
