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

    /// ⚠️ Takes LEGACY `type:Name` ids with no columns, so every test below
    /// this line is a characterisation of a library that has not been
    /// re-keyed. They are unchanged from before `ProfileRef` existed, and
    /// their passing is the assertion that nothing about the old shape moved.
    /// The re-keyed shape is exercised separately at the bottom of the file.
    private func input(profiles: [String],
                       strings: Set<String> = [],
                       performerEdges: Set<String> = [],
                       studioEdges: Set<String> = [],
                       parents: Set<String> = []) -> OrphanAudit.Input {
        .init(profiles: profiles.map { ProfileRef(id: $0) }, referencedByString: strings,
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

    // MARK: - 🚨 The re-keyed library

    /// A profile whose id is a uid and whose kind lives in a column.
    private func rekeyed(_ type: String, _ name: String,
                         uid: String = UUID().uuidString) -> ProfileRef {
        ProfileRef(id: uid, entityType: type, displayName: name)
    }

    /// K1 — the defect. Every id is a uid, `GraphNodeKind.of` answers nil for
    /// all of them, and the audit reported a library with three dangling
    /// profiles as perfectly clean.
    func testARekeyedLibrarysOrphansAreStillFound() {
        let found = OrphanAudit.findings(.init(
            profiles: [rekeyed("actor", "Alice"), rekeyed("studio", "Coast Line")],
            referencedByString: []))

        XCTAssertEqual(found[.actor]?.map(\.displayName), ["Alice"])
        XCTAssertEqual(found[.studio]?.map(\.displayName), ["Coast Line"])
    }

    /// K2 — 🚨 the hazard the obvious fix would have shipped. Resolving the
    /// KIND without also resolving the NAME makes every node reachable, and
    /// then matches none of them against the `actor:Name` strings the videos
    /// actually carry — so the whole cast of the library is reported orphaned
    /// and offered to a destructive button.
    func testANodeReferredToOnlyByATagStringIsNotAnOrphanAfterTheRekey() {
        let found = OrphanAudit.findings(.init(
            profiles: [rekeyed("actor", "Alice")],
            referencedByString: ["actor:Alice"]))

        XCTAssertTrue(found[.actor]?.isEmpty ?? true,
                      "a video names her; she is not an orphan")
    }

    /// K3 — ⚠️ and a case difference between the profile and the tag does not
    /// make her one either. On this path a miss means "offered for deletion",
    /// so the comparison errs toward "something refers to it".
    func testACaseDifferenceDoesNotMakeANodeAnOrphan() {
        let found = OrphanAudit.findings(.init(
            profiles: [rekeyed("actor", "Alice Vance")],
            referencedByString: ["actor:alice vance"]))

        XCTAssertTrue(found[.actor]?.isEmpty ?? true)
    }

    /// K4 — the edge path keeps working, and it speaks in ids on both sides.
    func testAnEdgeStillRescuesARekeyedNode() {
        let uid = UUID().uuidString
        let found = OrphanAudit.findings(.init(
            profiles: [rekeyed("actor", "Alice", uid: uid)],
            referencedByString: [],
            performersWithEdges: [uid]))

        XCTAssertTrue(found[.actor]?.isEmpty ?? true)
    }

    /// K5 — ⚠️ the name shown on the deletion confirmation is the real one.
    /// Chopping `"actor:".count` off a uid handed the operator a fragment of a
    /// UUID and asked them to approve deleting it.
    func testTheReportedNameIsNotAChoppedUpUid() {
        let uid = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
        let found = OrphanAudit.findings(.init(
            profiles: [rekeyed("actor", "Alice", uid: uid)],
            referencedByString: []))

        XCTAssertEqual(found[.actor]?.first?.displayName, "Alice")
        XCTAssertEqual(found[.actor]?.first?.id, uid, "the id is still the uid")
    }

    /// K6 — a uid-keyed row whose columns were never backfilled has no
    /// knowable kind, and is therefore left alone rather than deleted.
    func testAUidWithNoColumnsIsLeftAlone() {
        let found = OrphanAudit.findings(.init(
            profiles: [ProfileRef(id: UUID().uuidString)],
            referencedByString: []))

        XCTAssertTrue(found.values.allSatisfy(\.isEmpty) || found.isEmpty)
    }
}
