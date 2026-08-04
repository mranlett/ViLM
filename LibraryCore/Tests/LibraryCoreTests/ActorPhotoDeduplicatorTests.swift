import XCTest
@testable import LibraryCore

/// The dedup planner. Deleting a photo is irreversible, so these pin the two
/// things that make it safe: the biggest version survives, and the profile is
/// never left pointing at a file that is about to be removed.
final class ActorPhotoDeduplicatorTests: XCTestCase {

    private func photo(_ token: String,
                       hash: String = "h",
                       phash: UInt64? = 0,
                       pixels: Int = 1000,
                       bytes: Int = 100,
                       primary: Bool = false) -> PhotoMeasurement {
        PhotoMeasurement(token: token, fileName: "\(token).jpg", contentHash: hash,
                         perceptualHash: phash, pixelCount: pixels, byteCount: bytes,
                         isPrimary: primary)
    }

    // MARK: - Exact duplicates

    func testIdenticalBytesCollapseAndKeepOne() {
        let groups = ActorPhotoDeduplicator.groups(actorId: "actor:a", photos: [
            photo("one", hash: "same", pixels: 500),
            photo("two", hash: "same", pixels: 500),
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].remove.count, 1)
        XCTAssertFalse(groups[0].isVisualMatch, "identical bytes need no visual judgement")
    }

    func testDistinctPhotosAreLeftAlone() {
        let groups = ActorPhotoDeduplicator.groups(actorId: "actor:a", photos: [
            photo("one", hash: "a", phash: 0b0000),
            photo("two", hash: "b", phash: UInt64.max),
        ])
        XCTAssertTrue(groups.isEmpty)
    }

    // MARK: - The stated requirement

    func testKeepsTheHighestResolutionVersion() {
        let groups = ActorPhotoDeduplicator.groups(actorId: "actor:a", photos: [
            photo("thumb", hash: "a", phash: 0b1010, pixels: 40_000),
            photo("full", hash: "b", phash: 0b1010, pixels: 1_500_000),
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].keep.token, "full")
        XCTAssertEqual(groups[0].remove.map(\.token), ["thumb"])
        XCTAssertTrue(groups[0].isVisualMatch)
    }

    /// Resolution outranks being the current primary — otherwise a small
    /// portrait set as the profile photo would keep beating the full-size
    /// version of the same picture, which is the whole problem being solved.
    func testResolutionBeatsPrimaryStatus() {
        let groups = ActorPhotoDeduplicator.groups(actorId: "actor:a", photos: [
            photo("small", hash: "a", phash: 0b11, pixels: 10_000, primary: true),
            photo("large", hash: "b", phash: 0b11, pixels: 900_000),
        ])
        XCTAssertEqual(groups[0].keep.token, "large")
        XCTAssertTrue(groups[0].changesPrimary)
    }

    func testPrimaryWinsOnlyWhenResolutionTies() {
        let ranked = ActorPhotoDeduplicator.rank([
            photo("gallery", pixels: 1000, bytes: 50),
            photo("primary", pixels: 1000, bytes: 50, primary: true),
        ])
        XCTAssertEqual(ranked.first?.token, "primary")
    }

    /// A near-miss must NOT be treated as the same picture: two shots from one
    /// shoot are similar, and deleting one is unrecoverable.
    func testDistantHashesAreNotClustered() {
        let far = UInt64(0b1111_1111_1111)   // 12 bits apart, over the threshold
        let groups = ActorPhotoDeduplicator.groups(actorId: "actor:a", photos: [
            photo("one", hash: "a", phash: 0),
            photo("two", hash: "b", phash: far),
        ])
        XCTAssertTrue(groups.isEmpty)
    }

    func testUndecodableImagesAreNeverVisuallyGrouped() {
        let groups = ActorPhotoDeduplicator.groups(actorId: "actor:a", photos: [
            photo("one", hash: "a", phash: nil),
            photo("two", hash: "b", phash: nil),
        ])
        XCTAssertTrue(groups.isEmpty, "no perceptual hash means no visual claim")
    }

    // MARK: - Rewriting the profile

    func testRemovedTokensLeaveTheGallery() {
        var profile = EntityProfile(id: "actor:a")
        profile.photoUrl = "full"
        profile.galleryUrls = ["full", "thumb", "other"]

        let groups = ActorPhotoDeduplicator.groups(actorId: "actor:a", photos: [
            photo("full", hash: "a", phash: 0b1, pixels: 900_000, primary: true),
            photo("thumb", hash: "b", phash: 0b1, pixels: 9_000),
        ])
        let revised = ActorPhotoDeduplicator.revised(profile: profile, applying: groups)
        XCTAssertEqual(revised.galleryUrls, ["full", "other"])
        XCTAssertEqual(revised.photoUrl, "full", "the surviving primary is untouched")
    }

    /// The case that would otherwise leave a broken portrait.
    func testPrimaryIsPromotedWhenTheOldOneIsRemoved() {
        var profile = EntityProfile(id: "actor:a")
        profile.photoUrl = "small"
        profile.galleryUrls = ["small", "large"]

        let groups = ActorPhotoDeduplicator.groups(actorId: "actor:a", photos: [
            photo("small", hash: "a", phash: 0b1, pixels: 10_000, primary: true),
            photo("large", hash: "b", phash: 0b1, pixels: 900_000),
        ])
        let revised = ActorPhotoDeduplicator.revised(profile: profile, applying: groups)
        XCTAssertEqual(revised.photoUrl, "large", "promoted to the survivor")
        XCTAssertFalse(revised.galleryUrls.contains("small"))
        XCTAssertTrue(revised.galleryUrls.contains("large"))
    }

    func testNothingToRemoveLeavesTheProfileIdentical() {
        var profile = EntityProfile(id: "actor:a")
        profile.galleryUrls = ["one", "two"]
        XCTAssertEqual(ActorPhotoDeduplicator.revised(profile: profile, applying: []), profile)
    }

    /// Plans must be reproducible: the same input cannot propose deleting a
    /// different file on a second run.
    func testPlanIsDeterministicForEquivalentPhotos() {
        let photos = [photo("b", hash: "x"), photo("a", hash: "x"), photo("c", hash: "x")]
        let first = ActorPhotoDeduplicator.groups(actorId: "actor:a", photos: photos)
        let second = ActorPhotoDeduplicator.groups(actorId: "actor:a", photos: photos.reversed())
        XCTAssertEqual(first.first?.keep.token, second.first?.keep.token)
    }
}
