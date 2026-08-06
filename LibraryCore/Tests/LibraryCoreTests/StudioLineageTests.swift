import XCTest
@testable import LibraryCore

/// A studio's place in the hierarchy.
///
/// The empty case matters most: `studio_parent` is unpopulated for most of a
/// library, so "nothing to show" is the common answer rather than the edge one,
/// and the page has to be able to ask.
final class StudioLineageTests: XCTestCase {

    private func edge(_ imprint: String, under network: String) -> GraphEdgePair {
        GraphEdgePair(from: "studio:\(imprint)", to: "studio:\(network)")
    }

    private let counts = [
        "studio:Example Network": 12,
        "studio:Coast Line": 40,
        "studio:Harbour Lane": 7,
        "studio:Cedar Street": 25,
    ]

    // MARK: - Nothing recorded

    func testAStudioWithNoEdgesHasEmptyLineage() {
        let lineage = StudioLineage.build(for: "studio:Coast Line", pairs: [],
                                          videoCounts: counts)
        XCTAssertTrue(lineage.isEmpty)
        XCTAssertNil(lineage.parent)
        XCTAssertTrue(lineage.siblings.isEmpty)
        XCTAssertTrue(lineage.children.isEmpty)
    }

    /// A studio unrelated to the edges that exist is still empty — the builder
    /// must not hand back somebody else's family.
    func testAnUnrelatedStudioIsEmpty() {
        let lineage = StudioLineage.build(
            for: "studio:Silver River",
            pairs: [edge("Coast Line", under: "Example Network")],
            videoCounts: counts)
        XCTAssertTrue(lineage.isEmpty)
    }

    // MARK: - Upward

    func testTheNetworkIsFoundWithItsCount() {
        let lineage = StudioLineage.build(
            for: "studio:Coast Line",
            pairs: [edge("Coast Line", under: "Example Network")],
            videoCounts: counts)

        XCTAssertEqual(lineage.parent, StudioLineage.Relative(name: "Example Network",
                                                              videoCount: 12))
    }

    // MARK: - Sideways

    /// ⚠️ The studio being looked at is never its own sibling.
    func testSiblingsExcludeTheStudioItself() {
        let lineage = StudioLineage.build(
            for: "studio:Coast Line",
            pairs: [edge("Coast Line", under: "Example Network"),
                    edge("Harbour Lane", under: "Example Network"),
                    edge("Cedar Street", under: "Example Network")],
            videoCounts: counts)

        XCTAssertEqual(lineage.siblings.map(\.name), ["Cedar Street", "Harbour Lane"])
        XCTAssertFalse(lineage.siblings.contains { $0.name == "Coast Line" })
    }

    func testAnOnlyImprintHasNoSiblings() {
        let lineage = StudioLineage.build(
            for: "studio:Coast Line",
            pairs: [edge("Coast Line", under: "Example Network")],
            videoCounts: counts)

        XCTAssertTrue(lineage.siblings.isEmpty)
        XCTAssertFalse(lineage.isEmpty, "it still has a network")
    }

    // MARK: - Downward

    func testChildrenAreTheImprintsBeneath() {
        let lineage = StudioLineage.build(
            for: "studio:Example Network",
            pairs: [edge("Coast Line", under: "Example Network"),
                    edge("Harbour Lane", under: "Example Network")],
            videoCounts: counts)

        XCTAssertEqual(lineage.children.map(\.name), ["Coast Line", "Harbour Lane"])
        XCTAssertNil(lineage.parent, "the network itself has none here")
    }

    /// One level only. A grandchild belongs on its own parent's page — the
    /// walk that gathers a whole tree is `studioIdWithDescendants`, and it
    /// exists for filtering, not for this.
    func testOnlyOneLevelOfChildrenIsReturned() {
        let lineage = StudioLineage.build(
            for: "studio:Example Network",
            pairs: [edge("Coast Line", under: "Example Network"),
                    edge("Harbour Lane", under: "Coast Line")],
            videoCounts: counts)

        XCTAssertEqual(lineage.children.map(\.name), ["Coast Line"])
    }

    /// A studio can be both — an imprint that owns imprints of its own.
    func testAStudioCanHaveBothANetworkAndImprints() {
        let lineage = StudioLineage.build(
            for: "studio:Coast Line",
            pairs: [edge("Coast Line", under: "Example Network"),
                    edge("Harbour Lane", under: "Coast Line")],
            videoCounts: counts)

        XCTAssertEqual(lineage.parent?.name, "Example Network")
        XCTAssertEqual(lineage.children.map(\.name), ["Harbour Lane"])
    }

    // MARK: - Ordering and counts

    /// Busiest first: the imprint carrying most of the library is the one worth
    /// seeing, and ties order alphabetically rather than by table order.
    func testRelativesAreOrderedByVideoCountThenName() {
        let lineage = StudioLineage.build(
            for: "studio:Example Network",
            pairs: [edge("Harbour Lane", under: "Example Network"),
                    edge("Coast Line", under: "Example Network"),
                    edge("Cedar Street", under: "Example Network")],
            videoCounts: counts)

        XCTAssertEqual(lineage.children.map(\.name),
                       ["Coast Line", "Cedar Street", "Harbour Lane"])
        XCTAssertEqual(lineage.children.map(\.videoCount), [40, 25, 7])
    }

    /// A studio the counts know nothing about reads as zero rather than being
    /// dropped — it is still a real edge, and hiding it would make the
    /// hierarchy look incomplete.
    func testAStudioWithNoVideosStillAppears() {
        let lineage = StudioLineage.build(
            for: "studio:Example Network",
            pairs: [edge("Quiet Bay", under: "Example Network")],
            videoCounts: counts)

        XCTAssertEqual(lineage.children, [StudioLineage.Relative(name: "Quiet Bay",
                                                                 videoCount: 0)])
    }
}
