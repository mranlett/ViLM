import XCTest
@testable import LibraryCore

final class ProfileImageNamingTests: XCTestCase {

    func testSafeIdReplacesColonAndSlash() {
        XCTAssertEqual(ProfileImageNaming.safeId(for: "actor:Jane/Doe"), "actor_Jane_Doe")
    }

    func testPrimaryFileName() {
        XCTAssertEqual(ProfileImageNaming.primaryFileName(for: "actor:Jane Doe"), "actor_Jane Doe.jpg")
    }

    func testGalleryFileNameIsDeterministic() {
        let a = ProfileImageNaming.galleryFileName(for: "actor:Jane Doe", token: "https://example.com/1.jpg")
        let b = ProfileImageNaming.galleryFileName(for: "actor:Jane Doe", token: "https://example.com/1.jpg")
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.hasPrefix("actor_Jane Doe_"))
    }

    func testGalleryFileNameDiffersByToken() {
        let a = ProfileImageNaming.galleryFileName(for: "actor:Jane Doe", token: "https://example.com/1.jpg")
        let b = ProfileImageNaming.galleryFileName(for: "actor:Jane Doe", token: "https://example.com/2.jpg")
        XCTAssertNotEqual(a, b)
    }

    func testFileNameNonGalleryIsPrimary() {
        let name = ProfileImageNaming.fileName(for: "actor:Jane Doe", token: "https://example.com/1.jpg", isGallery: false)
        XCTAssertEqual(name, ProfileImageNaming.primaryFileName(for: "actor:Jane Doe"))
    }

    func testFileNameGalleryUsesHash() {
        let name = ProfileImageNaming.fileName(for: "actor:Jane Doe", token: "https://example.com/1.jpg", isGallery: true)
        XCTAssertEqual(name, ProfileImageNaming.galleryFileName(for: "actor:Jane Doe", token: "https://example.com/1.jpg"))
    }

    func testLocalPrimarySentinelForcesPrimaryEvenWhenGallery() {
        let name = ProfileImageNaming.fileName(for: "actor:Jane Doe", token: ProfileImageNaming.localPrimaryToken, isGallery: true)
        XCTAssertEqual(name, ProfileImageNaming.primaryFileName(for: "actor:Jane Doe"))
    }

    func testGalleryFilePrefixMatchesGalleryFileName() {
        let prefix = ProfileImageNaming.galleryFilePrefix(for: "actor:Jane Doe")
        let full = ProfileImageNaming.galleryFileName(for: "actor:Jane Doe", token: "anything")
        XCTAssertTrue(full.hasPrefix(prefix))
    }
}
