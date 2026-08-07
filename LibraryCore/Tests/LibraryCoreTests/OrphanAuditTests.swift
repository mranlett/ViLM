import XCTest
@testable import LibraryCore

/// What counts as an orphan, per node kind.
///
/// 🚨 Reported by the operator: *"the studio health tool ... offers to remove
/// orphaned profiles. It wants to remove orphaned studios and actors and
/// perhaps more."* One undifferentiated list and one "Delete All Orphans"
/// button, so arriving from a STUDIO problem deleted actors too.
///
/// Two of the rules were also wrong outright, and both would have destroyed
/// real work.
final class OrphanAuditTests: XCTestCase {

    private func input(profiles: [String],
                       strings: Set<String> = [],
                       performerEdges: Set<String> = [],
                       studioEdges: Set<String> = [],
                       parents: Set<String> = []) -> OrphanAudit.Input {
        .init(profiles: profiles, referencedByString: strings,
              performersWithEdges: performerEdges, studiosWithEdges: studioEdges,
              studiosWithChildren: parents)
    }

    // MARK: - The kinds are separate

    func testOrphansAreGroupedByNodeKind() {
        let found = OrphanAudit.findings(input(
            profiles: ["actor:Alice", "studio:Coast Line"]))

        XCTAssertEqual(found[.actor]?.map(\.displayName), ["Alice"])
        XCTAssertEqual(found[.studio]?.map(\.displayName), ["Coast Line"])
    }

    /// The property the operator actually asked for: acting on one kind can
    /// never reach another.
    func testAKindWithNoOrphansIsAbsentEntirely() {
        let found = OrphanAudit.findings(input(
            profiles: ["actor:Alice", "studio:Coast Line"],
            strings: ["studio:Coast Line"]))

        XCTAssertEqual(found[.actor]?.count, 1)
        XCTAssertNil(found[.studio])
    }

    // MARK: - 🚨 A network with imprints is not an orphan

    /// Having no videos of its own is the NORMAL state of a parent company.
    /// The old check offered to delete the top of every hierarchy.
    func testANetworkWithImprintsIsNeverAnOrphan() {
        let found = OrphanAudit.findings(input(
            profiles: ["studio:Example Network"],
            parents: ["studio:Example Network"]))

        XCTAssertNil(found[.studio], "deleting it discards the hierarchy, silently")
    }

    /// A studio with neither videos nor imprints genuinely is one.
    func testAStudioWithNoVideosAndNoImprintsIsAnOrphan() {
        let found = OrphanAudit.findings(input(profiles: ["studio:Coast Line"]))

        XCTAssertEqual(found[.studio]?.map(\.displayName), ["Coast Line"])
    }

    func testAStudioReachableByEdgeIsNotAnOrphan() {
        let found = OrphanAudit.findings(input(
            profiles: ["studio:Coast Line"], studioEdges: ["studio:Coast Line"]))

        XCTAssertNil(found[.studio])
    }

    // MARK: - ⚠️ Edges count, not just strings

    /// Once the migration retires the tag strings this is the only thing still
    /// pointing at a performer. A string-only check would then propose deleting
    /// the library's entire cast.
    func testAnActorReachableOnlyByEdgeIsNotAnOrphan() {
        let found = OrphanAudit.findings(input(
            profiles: ["actor:Alice"], performerEdges: ["actor:Alice"]))

        XCTAssertNil(found[.actor])
    }

    func testAnActorNamedByAVideoStringIsNotAnOrphan() {
        let found = OrphanAudit.findings(input(
            profiles: ["actor:Alice"], strings: ["actor:Alice"]))

        XCTAssertNil(found[.actor])
    }

    // MARK: - Safety

    /// ⚠️ An id shape this build does not recognise is left alone. Not knowing
    /// what something is, is a reason not to delete it.
    func testAnUnrecognisedIdIsNeverReportedAsAnOrphan() {
        let found = OrphanAudit.findings(input(
            profiles: ["series:Some Series", "tag:blonde", "whatever"]))

        XCTAssertTrue(found.values.allSatisfy(\.isEmpty) || found.isEmpty)
    }

    func testFindingsAreSortedByDisplayName() {
        let found = OrphanAudit.findings(input(
            profiles: ["actor:Zoe", "actor:alice", "actor:Bob"]))

        XCTAssertEqual(found[.actor]?.map(\.displayName), ["alice", "Bob", "Zoe"])
    }
}
