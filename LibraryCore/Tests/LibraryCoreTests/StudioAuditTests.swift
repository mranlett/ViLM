import XCTest
@testable import LibraryCore

/// The studio audit.
///
/// Two properties matter more than any individual check: it must agree with
/// the screens that fix these things (or the counts differ by which screen you
/// opened), and it must be silent about a clean library. A validator that
/// always finds something is one nobody reads.
final class StudioAuditTests: XCTestCase {

    private func asset(_ studios: [String], extra: [String] = []) -> Asset {
        Asset(relativePath: "\(UUID()).mp4", fileName: "a.mp4",
              tags: studios.map { "studio:\($0)" } + extra)
    }

    /// Everything present and correct, so every check has nothing to say.
    private func healthy(_ assets: [Asset]) -> StudioAudit.Input {
        let names = Set(assets.flatMap(\.studios))
        let ids = Set(names.map { "studio:\($0)" })
        var edges: [UUID: String] = [:]
        for a in assets where a.studios.count == 1 {
            edges[a.id] = "studio:\(a.studios[0])"
        }
        return StudioAudit.Input(assets: assets, profileIds: ids,
                                 confirmedStudioIds: ids,
                                 studioIdByVideo: edges, parentPairs: [])
    }

    // MARK: - Silence

    func testACleanLibraryReportsNothing() {
        let input = healthy([asset(["Silver River"]), asset(["Coast Line"])])
        XCTAssertTrue(StudioAudit.run(input).isEmpty)
    }

    func testAnEmptyLibraryReportsNothing() {
        XCTAssertTrue(StudioAudit.run(healthy([])).isEmpty)
    }

    // MARK: - Ordering

    /// Certain defects lead, whatever their size — an unconfirmed studio is a
    /// library that is unfinished, a two-studio video is one that is wrong.
    func testDefectsSortAboveUnfinishedWorkEvenWhenSmaller() {
        var assets = [Asset](repeating: asset(["Silver River"]), count: 20)
        assets.append(asset(["Coast Line", "Harbour Lane"]))

        var input = healthy(assets)
        input = StudioAudit.Input(assets: assets, profileIds: input.profileIds,
                                  confirmedStudioIds: [],   // nothing confirmed
                                  studioIdByVideo: input.studioIdByVideo,
                                  parentPairs: [])

        let checks = StudioAudit.run(input)
        XCTAssertEqual(checks.first?.kind, .multiStudioVideo,
                       "one broken video outranks twenty unconfirmed studios")
        XCTAssertTrue(checks.contains { $0.kind == .unconfirmed })
    }

    // MARK: - Spelling

    /// ⚠️ Folded through `StudioResolution.identity`, so a source that ran the
    /// spaces out of a name collides with the spelling already in the library.
    /// A case-only fold — what the tag audit does — misses these entirely.
    func testSpacingDifferencesCollideNotJustCase() {
        let input = healthy([asset(["Silver River"]), asset(["SilverRiver"])])
        let check = StudioAudit.spellingCollisions(input)
        XCTAssertEqual(check.count, 1)
        XCTAssertEqual(check.items[0], "Silver River · SilverRiver")
    }

    func testCaseOnlyDifferencesCollide() {
        let input = healthy([asset(["Coast Line"]), asset(["COAST LINE"])])
        XCTAssertEqual(StudioAudit.spellingCollisions(input).count, 1)
    }

    func testGenuinelyDifferentStudiosDoNotCollide() {
        let input = healthy([asset(["Silver River"]), asset(["Coast Line"])])
        XCTAssertTrue(StudioAudit.spellingCollisions(input).items.isEmpty)
    }

    // MARK: - Edges

    /// ⚠️ A two-studio video has no edge BY DESIGN — the graph refuses to pick
    /// one — so counting it as a missing edge would report one defect twice and
    /// make this check impossible to clear while a conflict existed.
    func testATwoStudioVideoIsNotAlsoAMissingEdge() {
        let conflicted = asset(["Coast Line", "Harbour Lane"])
        let input = StudioAudit.Input(
            assets: [conflicted],
            profileIds: ["studio:Coast Line", "studio:Harbour Lane"],
            confirmedStudioIds: ["studio:Coast Line", "studio:Harbour Lane"],
            studioIdByVideo: [:], parentPairs: [])

        XCTAssertTrue(StudioAudit.missingEdges(input).items.isEmpty)
        XCTAssertEqual(StudioAudit.multiStudioVideos(input).count, 1)
    }

    /// A studio with no profile cannot have an edge — `connectStudioEdges`
    /// skips it — so reporting it as a missing edge would be asking for a
    /// re-run that cannot help. It is a missing PROFILE.
    func testAStudioWithNoProfileIsNotReportedAsAMissingEdge() {
        let input = StudioAudit.Input(
            assets: [asset(["Silver River"])],
            profileIds: [], confirmedStudioIds: [],
            studioIdByVideo: [:], parentPairs: [])

        XCTAssertTrue(StudioAudit.missingEdges(input).items.isEmpty)
        XCTAssertEqual(StudioAudit.missingProfiles(input).count, 1)
    }

    func testAStudioWithAProfileAndNoEdgeIsReported() {
        let one = asset(["Silver River"])
        let input = StudioAudit.Input(
            assets: [one], profileIds: ["studio:Silver River"],
            confirmedStudioIds: ["studio:Silver River"],
            studioIdByVideo: [:], parentPairs: [])

        XCTAssertEqual(StudioAudit.missingEdges(input).items, ["Silver River — 1 video"])
    }

    func testAnEdgeNamingADifferentStudioIsADisagreement() {
        let one = asset(["Silver River"])
        let input = StudioAudit.Input(
            assets: [one], profileIds: ["studio:Silver River"],
            confirmedStudioIds: ["studio:Silver River"],
            studioIdByVideo: [one.id: "studio:Coast Line"], parentPairs: [])

        XCTAssertEqual(StudioAudit.edgeDisagreements(input).count, 1)
        XCTAssertTrue(StudioAudit.missingEdges(input).items.isEmpty,
                      "it has an edge — the wrong one, which is a different finding")
    }

    // MARK: - Profiles

    func testAProfileNoVideoUsesIsAnOrphan() {
        let input = StudioAudit.Input(
            assets: [asset(["Silver River"])],
            profileIds: ["studio:Silver River", "studio:Coast Line"],
            confirmedStudioIds: [], studioIdByVideo: [:], parentPairs: [])

        XCTAssertEqual(StudioAudit.orphanProfiles(input).items, ["Coast Line"])
    }

    /// The profile table holds actors and tags too, and neither is a studio
    /// orphan however few videos carries it.
    func testOnlyStudioProfilesCountAsStudioOrphans() {
        let input = StudioAudit.Input(
            assets: [asset(["Silver River"])],
            profileIds: ["studio:Silver River", "actor:Someone", "tag:Outdoors"],
            confirmedStudioIds: [], studioIdByVideo: [:], parentPairs: [])

        XCTAssertTrue(StudioAudit.orphanProfiles(input).items.isEmpty)
    }

    // MARK: - Lineage

    func testANetworkWithNoProfileIsDangling() {
        let input = StudioAudit.Input(
            assets: [asset(["Coast Line"])],
            profileIds: ["studio:Coast Line"],
            confirmedStudioIds: [], studioIdByVideo: [:],
            parentPairs: [GraphEdgePair(from: "studio:Coast Line", to: "studio:Example Network")])

        XCTAssertEqual(StudioAudit.danglingParents(input).items, ["Example Network"])
    }

    func testAKnownNetworkIsNotDangling() {
        let input = StudioAudit.Input(
            assets: [asset(["Coast Line"])],
            profileIds: ["studio:Coast Line", "studio:Example Network"],
            confirmedStudioIds: [], studioIdByVideo: [:],
            parentPairs: [GraphEdgePair(from: "studio:Coast Line", to: "studio:Example Network")])

        XCTAssertTrue(StudioAudit.danglingParents(input).items.isEmpty)
    }

    /// Cannot be created through `setStudioParent`, so finding one is evidence
    /// the database was edited by hand.
    func testAStudioBeneathItselfIsReported() {
        let input = StudioAudit.Input(
            assets: [], profileIds: [], confirmedStudioIds: [], studioIdByVideo: [:],
            parentPairs: [
                GraphEdgePair(from: "studio:Coast Line", to: "studio:Example Network"),
                GraphEdgePair(from: "studio:Example Network", to: "studio:Coast Line"),
            ])

        XCTAssertEqual(StudioAudit.parentCycles(input).count, 2,
                       "both studios in the loop have an unusable lineage")
    }

    /// The walk must terminate on a cycle rather than run forever — the whole
    /// reason it carries a visited set.
    func testASelfParentTerminates() {
        let input = StudioAudit.Input(
            assets: [], profileIds: [], confirmedStudioIds: [], studioIdByVideo: [:],
            parentPairs: [GraphEdgePair(from: "studio:Coast Line", to: "studio:Coast Line")])

        XCTAssertEqual(StudioAudit.parentCycles(input).items, ["Coast Line"])
    }

    func testADeepHierarchyIsNotACycle() {
        let input = StudioAudit.Input(
            assets: [], profileIds: [], confirmedStudioIds: [], studioIdByVideo: [:],
            parentPairs: [
                GraphEdgePair(from: "studio:Harbour Lane", to: "studio:Coast Line"),
                GraphEdgePair(from: "studio:Coast Line", to: "studio:Example Network"),
            ])

        XCTAssertTrue(StudioAudit.parentCycles(input).items.isEmpty)
    }

    // MARK: - Routing

    /// Each finding names the screen that resolves it. Two have none, and say
    /// so rather than pointing somewhere that cannot help.
    func testEveryFindingRoutesSomewhereOrAdmitsItCannot() {
        XCTAssertEqual(StudioCheck(kind: .multiStudioVideo, items: ["x"]).fix,
                       .fixDuplicateStudios)
        XCTAssertEqual(StudioCheck(kind: .unconfirmed, items: ["x"]).fix, .matchStudios)
        XCTAssertEqual(StudioCheck(kind: .parentCycle, items: ["x"]).fix, .none)
        XCTAssertEqual(StudioCheck(kind: .danglingParent, items: ["x"]).fix, .none)
    }

    /// Counted per video, biggest first — the entry worth acting on leads.
    func testFindingsAreOrderedBySize() {
        var assets = [Asset](repeating: asset(["Silver River"]), count: 3)
        assets.append(asset(["Coast Line"]))
        let input = StudioAudit.Input(
            assets: assets, profileIds: [], confirmedStudioIds: [],
            studioIdByVideo: [:], parentPairs: [])

        XCTAssertEqual(StudioAudit.missingProfiles(input).items,
                       ["Silver River — 3 videos", "Coast Line — 1 video"])
    }
}
