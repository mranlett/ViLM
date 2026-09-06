// ProfileThumbnailNamingTests.swift
// The derivative naming and, more importantly, the freshness rule.
//
// The freshness assertions are the ones that matter. A derivative keyed on
// path alone reproduces #21 exactly — the primary photo's filename is fixed
// per entity, so starring a different photo overwrites it in place and a
// presence check keeps serving the old face. That bug cost a spike to find
// once; these tests are why it does not cost a second one.

import XCTest
@testable import LibraryCore

final class ProfileThumbnailNamingTests: XCTestCase {

    // MARK: - Naming

    func testAPrimaryFileGetsASizeSuffixedDerivative() {
        XCTAssertEqual(
            ProfileThumbnailNaming.fileName(forSourceFileName: "A1B2.jpg", maxPixelSize: 384),
            "A1B2@384.jpg")
    }

    func testAGalleryFileKeepsItsContentHashInTheDerivativeName() {
        // Gallery photos are content-addressed; the hash must survive so two
        // gallery entries never collide on one derivative.
        XCTAssertEqual(
            ProfileThumbnailNaming.fileName(forSourceFileName: "A1B2_9f86d0.jpg", maxPixelSize: 384),
            "A1B2_9f86d0@384.jpg")
    }

    func testTwoSizesCoexistRatherThanOverwritingEachOther() {
        let small = ProfileThumbnailNaming.fileName(forSourceFileName: "A1B2.jpg", maxPixelSize: 384)
        let large = ProfileThumbnailNaming.fileName(forSourceFileName: "A1B2.jpg", maxPixelSize: 768)
        XCTAssertNotEqual(small, large)
    }

    func testAnEmptyNameYieldsNoDerivativeRatherThanAGuess() {
        XCTAssertNil(ProfileThumbnailNaming.fileName(forSourceFileName: ""))
        XCTAssertNil(ProfileThumbnailNaming.fileName(forSourceFileName: "   "))
    }

    func testANonPositiveSizeYieldsNoDerivative() {
        XCTAssertNil(ProfileThumbnailNaming.fileName(forSourceFileName: "A1B2.jpg", maxPixelSize: 0))
        XCTAssertNil(ProfileThumbnailNaming.fileName(forSourceFileName: "A1B2.jpg", maxPixelSize: -1))
    }

    func testAnExtensionlessSourceStillNames() {
        XCTAssertEqual(
            ProfileThumbnailNaming.fileName(forSourceFileName: "A1B2", maxPixelSize: 384),
            "A1B2@384.jpg")
    }

    // MARK: - 🚨 Freshness — the #21 shape

    func testADerivativeOlderThanItsSourceIsStale() {
        // Starring a different photo rewrites the fixed primary filename. The
        // derivative must not be served after that.
        let source = Date(timeIntervalSince1970: 2_000)
        let derivative = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(ProfileThumbnailNaming.isFresh(derivativeModified: derivative,
                                                      sourceModified: source))
    }

    func testADerivativeNewerThanItsSourceIsFresh() {
        let source = Date(timeIntervalSince1970: 1_000)
        let derivative = Date(timeIntervalSince1970: 2_000)
        XCTAssertTrue(ProfileThumbnailNaming.isFresh(derivativeModified: derivative,
                                                     sourceModified: source))
    }

    func testEqualTimestampsCountAsFresh() {
        // A derivative written in the same second as its source is a
        // derivative OF that source, not a stale one.
        let t = Date(timeIntervalSince1970: 1_500)
        XCTAssertTrue(ProfileThumbnailNaming.isFresh(derivativeModified: t, sourceModified: t))
    }

    func testFreshnessIsAComparisonNotAPresenceCheck() {
        // The regression guard stated as a property: for a FIXED filename, the
        // answer must change when only the source's timestamp changes. A
        // presence check cannot distinguish these two cases; this one must.
        let derivative = Date(timeIntervalSince1970: 1_500)
        let beforeEdit = Date(timeIntervalSince1970: 1_000)
        let afterEdit  = Date(timeIntervalSince1970: 2_000)
        XCTAssertTrue(ProfileThumbnailNaming.isFresh(derivativeModified: derivative,
                                                     sourceModified: beforeEdit))
        XCTAssertFalse(ProfileThumbnailNaming.isFresh(derivativeModified: derivative,
                                                      sourceModified: afterEdit),
                       "a re-starred primary must invalidate its derivative")
    }

    func testTheDerivativeDirectorySitsBesideProfilesAndThumbnails() {
        XCTAssertEqual(ProfileThumbnailNaming.relativePath, ".catalog/profileThumbs")
        XCTAssertEqual(ProfileThumbnailNaming.directoryName, "profileThumbs")
    }
}
