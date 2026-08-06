import XCTest
@testable import LibraryCore

/// Splitting a network's catalogue by imprint.
///
/// The point of the split is that a merged list loses exactly the distinction
/// the hierarchy exists to record — so the rules about which section a video
/// lands in, and in what order sections appear, are the whole feature.
final class StudioFamilyGroupingTests: XCTestCase {

    private func asset(_ studios: [String]) -> Asset {
        Asset(relativePath: "\(UUID()).mp4", fileName: "a.mp4",
              tags: studios.map { "studio:\($0)" })
    }

    private let family: Set<String> = ["Example Network", "Coast Line", "Harbour Lane"]

    // MARK: - Which section a video lands in

    func testVideosAreSplitByTheStudioThatReleasedThem() {
        let sections = StudioFamilyGrouping.sections(
            assets: [asset(["Example Network"]), asset(["Coast Line"]), asset(["Coast Line"])],
            root: "Example Network", family: family)

        XCTAssertEqual(sections.map(\.studio), ["Example Network", "Coast Line"])
        XCTAssertEqual(sections.map(\.assets.count), [1, 2])
    }

    /// ⚠️ Not `studios.first`. A video carrying two studios is a known defect,
    /// and picking blindly would file it under a studio that is not in this
    /// family at all — dropping it from a page it belongs on.
    func testATwoStudioVideoIsFiledUnderTheStudioInThisFamily() {
        // `Asset.studios` sorts, so "Another Label" would come first.
        let sections = StudioFamilyGrouping.sections(
            assets: [asset(["Another Label", "Coast Line"])],
            root: "Example Network", family: family)

        XCTAssertEqual(sections.map(\.studio), ["Coast Line"])
        XCTAssertEqual(sections.first?.assets.count, 1)
    }

    /// It appears once, not once per studio it names.
    func testATwoStudioVideoIsNotDuplicatedAcrossSections() {
        let sections = StudioFamilyGrouping.sections(
            assets: [asset(["Coast Line", "Harbour Lane"])],
            root: "Example Network", family: family)

        XCTAssertEqual(sections.reduce(0) { $0 + $1.assets.count }, 1)
    }

    func testAVideoFromOutsideTheFamilyIsExcluded() {
        let sections = StudioFamilyGrouping.sections(
            assets: [asset(["Silver River"]), asset(["Coast Line"])],
            root: "Example Network", family: family)

        XCTAssertEqual(sections.map(\.studio), ["Coast Line"])
    }

    // MARK: - Ordering

    /// The root leads even when an imprint carries far more — it is the page
    /// you are on.
    func testTheRootLeadsEvenWhenAnImprintHasMore() {
        var assets = [Asset](repeating: asset(["Coast Line"]), count: 10)
        assets.append(asset(["Example Network"]))

        let sections = StudioFamilyGrouping.sections(
            assets: assets, root: "Example Network", family: family)

        XCTAssertEqual(sections.first?.studio, "Example Network")
        XCTAssertEqual(sections.first?.assets.count, 1)
    }

    /// Imprints busiest-first, matching how the lineage block orders them, so
    /// the two readings of the hierarchy agree.
    func testImprintsFollowBusiestFirst() {
        var assets = [Asset](repeating: asset(["Harbour Lane"]), count: 3)
        assets.append(contentsOf: [Asset](repeating: asset(["Coast Line"]), count: 7))

        let sections = StudioFamilyGrouping.sections(
            assets: assets, root: "Example Network", family: family)

        XCTAssertEqual(sections.map(\.studio), ["Coast Line", "Harbour Lane"])
    }

    func testTiesOrderAlphabetically() {
        let sections = StudioFamilyGrouping.sections(
            assets: [asset(["Harbour Lane"]), asset(["Coast Line"])],
            root: "Example Network", family: family)

        XCTAssertEqual(sections.map(\.studio), ["Coast Line", "Harbour Lane"])
    }

    // MARK: - Empties

    /// A network with nothing filed under its own name shows only its imprints
    /// rather than an empty section with a header.
    func testARootWithNoVideosOfItsOwnGetsNoSection() {
        let sections = StudioFamilyGrouping.sections(
            assets: [asset(["Coast Line"])], root: "Example Network", family: family)

        XCTAssertEqual(sections.map(\.studio), ["Coast Line"])
    }

    func testNoVideosMeansNoSections() {
        XCTAssertTrue(StudioFamilyGrouping.sections(
            assets: [], root: "Example Network", family: family).isEmpty)
    }

    /// One section is not a split. The view uses this to fall back to a plain
    /// grid — a single header over the whole page says nothing.
    func testAFamilyWhereOnlyOneStudioHasVideosYieldsOneSection() {
        let sections = StudioFamilyGrouping.sections(
            assets: [asset(["Coast Line"]), asset(["Coast Line"])],
            root: "Example Network", family: family)

        XCTAssertEqual(sections.count, 1)
    }
}
