import XCTest
@testable import LibraryCore

/// Studio Hierarchy from Above — the seam between the pure planner and the
/// database.
///
/// `StudioHierarchyTests` proves the RULES without a store. This proves the two
/// halves that were built and never joined: gathering what the planner needs
/// out of the library, and turning a plan it produced into rows.
///
/// ⚠️ All names invented. This repository is public.
final class StudioHierarchyApplyTests: XCTestCase {

    private var libraryURL: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        libraryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioHierarchy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        store = try LibraryStore(at: libraryURL)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: libraryURL)
    }

    @discardableResult
    private func studio(_ name: String, sourceId: String? = nil) throws -> String {
        _ = try store.ensureStudioProfile(name)
        let id = try XCTUnwrap(try store.entityId(named: name, type: "studio"))
        if let sourceId {
            var p = try XCTUnwrap(try store.fetchEntityProfile(for: id))
            p.enrichmentSourceId = sourceId
            try store.saveEntityProfile(p)
        }
        return id
    }

    @discardableResult
    private func video(under studioName: String) throws -> UUID {
        let asset = Asset(relativePath: "\(UUID()).mp4", fileName: "a.mp4",
                          tags: ["studio:\(studioName)"])
        try store.insertAsset(asset)
        return asset.id
    }

    private func local(_ name: String, in studios: [LocalStudio]) throws -> LocalStudio {
        try XCTUnwrap(studios.first { $0.name == name })
    }

    // MARK: - Gathering: the four facts the planner branches on

    func testLocalStudiosCarriesTheSourceIdentity() throws {
        try studio("Example Network", sourceId: "S-NET")
        try studio("Coast Line")

        let studios = try store.localStudios()
        XCTAssertEqual(try local("Example Network", in: studios).sourceId, "S-NET")
        XCTAssertNil(try local("Coast Line", in: studios).sourceId,
                     "a studio nobody matched carries no identity, and resolves by name")
    }

    func testLocalStudiosCarriesTheCurrentParent() throws {
        let network = try studio("Example Network")
        let imprint = try studio("Coast Line")
        try store.setStudioParent(network, forStudio: imprint)

        XCTAssertEqual(try local("Coast Line", in: try store.localStudios()).parentId, network)
    }

    /// 🔴 D4 — "the operator chose this" is the EDGE's provenance. A source
    /// writes `.download`; only a person writes `.operator`.
    func testAHandSetParentIsReportedAsHandSetAndADownloadedOneIsNot() throws {
        let network = try studio("Example Network")
        let chosen = try studio("Coast Line")
        let fetched = try studio("Silver River")
        try store.setStudioParent(network, forStudio: chosen, source: .operator)
        try store.setStudioParent(network, forStudio: fetched, source: .download)

        let studios = try store.localStudios()
        XCTAssertTrue(try local("Coast Line", in: studios).parentWasHandSet)
        XCTAssertFalse(try local("Silver River", in: studios).parentWasHandSet,
                       "otherwise every fetched parent would be treated as a statement")
    }

    /// H4 — the mark the operator asked for, derived rather than stored.
    func testAStudioWithNoVideosIsDistinguishableFromOneWithThem() throws {
        try studio("Coast Line")
        try studio("Silver River")
        try video(under: "Coast Line")

        let studios = try store.localStudios()
        XCTAssertTrue(try local("Coast Line", in: studios).hasVideos)
        XCTAssertFalse(try local("Silver River", in: studios).hasVideos)
    }

    // MARK: - Applying: what the plan actually writes

    /// H1 — an imprint the library already holds is filed under the network.
    func testAHeldImprintIsLinkedUnderTheNetwork() throws {
        let network = try studio("Example Network", sourceId: "S-NET")
        let imprint = try studio("Coast Line", sourceId: "S-COAST")

        let plan = StudioHierarchy.plan(
            network: network, arriving: [StudioRef(sourceId: "S-COAST", name: "Coast Line")],
            local: try store.localStudios(), parentOf: { try? self.store.parentStudioId(of: $0) })
        let outcome = try store.applyStudioHierarchy(plan, under: network, source: "Example Source")

        XCTAssertEqual(outcome.linked, ["Coast Line"])
        XCTAssertTrue(outcome.created.isEmpty)
        XCTAssertEqual(try store.parentStudioId(of: imprint), network)
    }

    /// The operator's decision: create AND mark. The creation half.
    func testAnImprintTheLibraryDoesNotHoldIsCreatedAndFiled() throws {
        let network = try studio("Example Network", sourceId: "S-NET")

        let plan = StudioHierarchy.plan(
            network: network, arriving: [StudioRef(sourceId: "S-NEW", name: "Silver River")],
            local: try store.localStudios(), parentOf: { try? self.store.parentStudioId(of: $0) })
        let outcome = try store.applyStudioHierarchy(plan, under: network, source: "Example Source")

        XCTAssertEqual(outcome.created, ["Silver River"])
        let created = try XCTUnwrap(try store.entityId(named: "Silver River", type: "studio"))
        XCTAssertEqual(try store.parentStudioId(of: created), network)
    }

    /// ⚠️ It arrived carrying the source's own id. Minting it unclaimed would
    /// discard an identity the library was handed and send the operator to
    /// match it by name later.
    func testACreatedImprintIsConfirmedAgainstTheSourceThatNamedIt() throws {
        let network = try studio("Example Network", sourceId: "S-NET")

        let plan = StudioHierarchy.plan(
            network: network, arriving: [StudioRef(sourceId: "S-NEW", name: "Silver River")],
            local: try store.localStudios(), parentOf: { try? self.store.parentStudioId(of: $0) })
        try store.applyStudioHierarchy(plan, under: network, source: "Example Source")

        let id = try XCTUnwrap(try store.entityId(named: "Silver River", type: "studio"))
        let profile = try XCTUnwrap(try store.fetchEntityProfile(for: id))
        XCTAssertEqual(profile.enrichmentState, .matched)
        XCTAssertEqual(profile.enrichmentSourceId, "S-NEW")
        XCTAssertEqual(profile.enrichmentSource, "Example Source")
    }

    /// H6 — fetching the same network twice adds nothing the second time.
    func testFetchingTheSameNetworkTwiceWritesNothingTheSecondTime() throws {
        let network = try studio("Example Network", sourceId: "S-NET")
        let arriving = [StudioRef(sourceId: "S-COAST", name: "Coast Line")]
        try studio("Coast Line", sourceId: "S-COAST")

        func planNow() throws -> StudioHierarchyPlan {
            StudioHierarchy.plan(network: network, arriving: arriving,
                                 local: try store.localStudios(),
                                 parentOf: { try? self.store.parentStudioId(of: $0) })
        }
        try store.applyStudioHierarchy(try planNow(), under: network, source: "Example Source")

        let second = try planNow()
        XCTAssertTrue(second.isEmpty, "the second fetch proposes nothing")
        XCTAssertEqual(second.unchanged.map(\.sourceId), ["S-COAST"])
        XCTAssertEqual(try store.studioParentHistory(of:
            try XCTUnwrap(try store.entityId(named: "Coast Line", type: "studio"))).count, 1,
            "and re-asserting the same parent does not open a second period")
    }

    /// 🔴 D4 end to end — a hand-set parent survives a fetch that disagrees,
    /// and the disagreement is reported rather than silently dropped.
    func testAHandSetParentIsNotRepointedByTheSource() throws {
        let network = try studio("Example Network", sourceId: "S-NET")
        let elsewhere = try studio("Other Network")
        let imprint = try studio("Coast Line", sourceId: "S-COAST")
        try store.setStudioParent(elsewhere, forStudio: imprint, source: .operator)

        let plan = StudioHierarchy.plan(
            network: network, arriving: [StudioRef(sourceId: "S-COAST", name: "Coast Line")],
            local: try store.localStudios(), parentOf: { try? self.store.parentStudioId(of: $0) })
        let outcome = try store.applyStudioHierarchy(plan, under: network, source: "Example Source")

        XCTAssertEqual(plan.handSetKept.map(\.name), ["Coast Line"], "and it is SAID")
        XCTAssertTrue(outcome.linked.isEmpty)
        XCTAssertEqual(try store.parentStudioId(of: imprint), elsewhere,
                       "evidence does not overwrite a statement")
    }

    /// 🚨 H2 — a cycle never reaches the writes.
    func testACycleIsRefusedAndNothingIsWritten() throws {
        let network = try studio("Example Network", sourceId: "S-NET")
        let imprint = try studio("Coast Line", sourceId: "S-COAST")
        try store.setStudioParent(imprint, forStudio: network)

        let plan = StudioHierarchy.plan(
            network: network, arriving: [StudioRef(sourceId: "S-COAST", name: "Coast Line")],
            local: try store.localStudios(), parentOf: { try? self.store.parentStudioId(of: $0) })
        let outcome = try store.applyStudioHierarchy(plan, under: network, source: "Example Source")

        XCTAssertEqual(plan.cycles.count, 1)
        XCTAssertTrue(outcome.isEmpty)
        XCTAssertNil(try store.parentStudioId(of: imprint),
                     "the imprint keeps its own place; the network stays beneath it")
        XCTAssertEqual(try store.parentStudioId(of: network), imprint)
    }

    // MARK: - 🚨 The mark has to survive the orphan audit

    /// Without this the next "Remove Orphaned Profiles" silently undoes the
    /// whole feature: a created imprint is a leaf with no videos, no children
    /// and no tag string, which is exactly the shape the audit deletes.
    func testAFiledImprintOwningNoVideosIsNotOfferedForDeletion() throws {
        let network = try studio("Example Network", sourceId: "S-NET")
        try video(under: "Example Network")
        let plan = StudioHierarchy.plan(
            network: network, arriving: [StudioRef(sourceId: "S-NEW", name: "Silver River")],
            local: try store.localStudios(), parentOf: { try? self.store.parentStudioId(of: $0) })
        try store.applyStudioHierarchy(plan, under: network, source: "Example Source")

        let orphans = try store.auditOrphans()[.studio] ?? []
        XCTAssertFalse(orphans.contains { $0.displayName == "Silver River" },
                       "an imprint the operator deliberately filed is referred to, by its network")
    }

    /// ⚠️ The other direction — the rule must not spare every empty studio, or
    /// the audit stops finding the ones it exists to find.
    func testAStudioWithNoVideosAndNoPlaceInTheHierarchyIsStillAnOrphan() throws {
        try studio("Silver River")

        let orphans = try store.auditOrphans()[.studio] ?? []
        XCTAssertTrue(orphans.contains { $0.displayName == "Silver River" })
    }
}
