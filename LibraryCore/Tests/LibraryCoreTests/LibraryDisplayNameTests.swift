import XCTest
@testable import LibraryCore

/// Path-based library naming for the multi-library session: prettified full
/// paths, and shortest-unique-suffix chip labels (the user's canonical case:
/// two libraries both named "Videos", told apart only by volume/route).
final class LibraryDisplayNameTests: XCTestCase {

    private let home = "/Users/matt"

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    func testUniqueFolderNamesUseJustTheFolderName() {
        let main = url("/Users/matt/Movies/MainLibrary")
        let portable = url("/Volumes/PortableSSD/TravelSet")
        let labels = LibraryDisplayName.labels(for: [main, portable], homeDirectory: home)
        XCTAssertEqual(labels[main]?.short, "MainLibrary")
        XCTAssertEqual(labels[portable]?.short, "TravelSet")
    }

    func testCollidingFolderNamesWalkUpToTheDifferentiator() {
        // The canonical case: both are ".../Downloads/Videos" — only the
        // home-vs-volume root tells them apart.
        let main = url("/Users/matt/Downloads/Videos")
        let portable = url("/Volumes/PortableSSD/Downloads/Videos")
        let labels = LibraryDisplayName.labels(for: [main, portable], homeDirectory: home)
        XCTAssertEqual(labels[main]?.short, "~/…/Videos")
        XCTAssertEqual(labels[portable]?.short, "PortableSSD/…/Videos")
    }

    func testParentDisambiguationNeedsNoEllipsis() {
        let a = url("/Users/matt/Archive/Videos")
        let b = url("/Users/matt/Current/Videos")
        let labels = LibraryDisplayName.labels(for: [a, b], homeDirectory: home)
        XCTAssertEqual(labels[a]?.short, "Archive/Videos")
        XCTAssertEqual(labels[b]?.short, "Current/Videos")
    }

    func testFullPathsArePrettified() {
        let main = url("/Users/matt/Downloads/Videos")
        let portable = url("/Volumes/PortableSSD/Downloads/Videos")
        let labels = LibraryDisplayName.labels(for: [main, portable], homeDirectory: home)
        XCTAssertEqual(labels[main]?.full, "~/Downloads/Videos")
        XCTAssertEqual(labels[portable]?.full, "PortableSSD/Downloads/Videos")
    }

    func testThreeLibrariesStayMutuallyUnique() {
        let a = url("/Users/matt/Downloads/Videos")
        let b = url("/Volumes/PortableSSD/Downloads/Videos")
        let c = url("/Volumes/BackupHDD/Downloads/Videos")
        let labels = LibraryDisplayName.labels(for: [a, b, c], homeDirectory: home)
        let shorts = [labels[a]?.short, labels[b]?.short, labels[c]?.short].compactMap { $0 }
        XCTAssertEqual(Set(shorts).count, 3, "all chip labels distinct: \(shorts)")
        XCTAssertEqual(labels[b]?.short, "PortableSSD/…/Videos")
    }

    func testSingleLibraryIsJustItsFolderName() {
        let main = url("/Users/matt/Movies/Library")
        let labels = LibraryDisplayName.labels(for: [main], homeDirectory: home)
        XCTAssertEqual(labels[main]?.short, "Library")
        XCTAssertEqual(labels[main]?.full, "~/Movies/Library")
    }
}
