// StudioHierarchyTests.swift
// Studio Hierarchy from Above — H1 to H8.
//
// ⚠️ All names invented. This repository is public.

import XCTest
@testable import LibraryCore

final class StudioHierarchyTests: XCTestCase {

    private let network = LocalStudio(id: "net", name: "Example Network", sourceId: "S-NET")

    private func plan(_ arriving: [StudioRef], _ local: [LocalStudio],
                      parents: [String: String] = [:]) -> StudioHierarchyPlan {
        StudioHierarchy.plan(network: "net", arriving: arriving,
                             local: [network] + local,
                             parentOf: { parents[$0] })
    }

    private func ref(_ id: String, _ name: String) -> StudioRef {
        StudioRef(sourceId: id, name: name)
    }

    // MARK: - H1 — imprints become children, and nothing else moves

    func testH1AHeldImprintIsLinkedUnderTheNetwork() {
        let held = LocalStudio(id: "imp", name: "Example Imprint", sourceId: "S-IMP")
        let result = plan([ref("S-IMP", "Example Imprint")], [held])
        XCTAssertEqual(result.link.map(\.localId), ["imp"])
        XCTAssertTrue(result.create.isEmpty)
        XCTAssertTrue(result.cycles.isEmpty)
    }

    /// 🚨 H7 — resolved BY IDENTITY. A studio the operator has renamed locally
    /// must resolve to their row, not create a second one under the source's
    /// spelling.
    func testH7ARenamedStudioResolvesByIdentityNotByName() {
        let renamed = LocalStudio(id: "imp", name: "What I Call It", sourceId: "S-IMP")
        let result = plan([ref("S-IMP", "The Source's Name")], [renamed])
        XCTAssertEqual(result.link.map(\.localId), ["imp"])
        XCTAssertTrue(result.create.isEmpty, "renaming a studio must not duplicate it")
    }

    /// ⚠️ Name is the fallback ONLY where the local row carries no identity. A
    /// studio already holding a DIFFERENT source id is not this one however the
    /// names read.
    func testAStudioHoldingADifferentIdentityIsNotMatchedByName() {
        let other = LocalStudio(id: "other", name: "Example Imprint", sourceId: "S-OTHER")
        let result = plan([ref("S-IMP", "Example Imprint")], [other])
        XCTAssertTrue(result.link.isEmpty)
        XCTAssertEqual(result.create.map(\.ref.sourceId), ["S-IMP"])
    }

    func testAnUnmatchedLocalStudioStillResolvesByName() {
        let unmatched = LocalStudio(id: "imp", name: "Example Imprint", sourceId: nil)
        XCTAssertEqual(plan([ref("S-IMP", "Example Imprint")], [unmatched]).link.map(\.localId),
                       ["imp"])
    }

    // MARK: - 🚨 H2 — a cycle is refused, naming the chain

    func testH2ACycleIsRefusedAndTheChainIsNamed() {
        // The network is already beneath the imprint; filing the imprint under
        // the network would close the loop.
        let imprint = LocalStudio(id: "imp", name: "Example Imprint", sourceId: "S-IMP")
        let result = plan([ref("S-IMP", "Example Imprint")], [imprint],
                          parents: ["net": "imp"])
        XCTAssertEqual(result.cycles.count, 1)
        XCTAssertTrue(result.link.isEmpty, "and it is NOT linked")
        let chain = try? XCTUnwrap(result.cycles.first?.chain)
        XCTAssertTrue(chain?.contains("Example Imprint") == true)
        XCTAssertTrue(chain?.contains("Example Network") == true,
                      "the message has to say which loop closed")
    }

    func testAStudioBeneathItselfIsRefused() {
        let result = StudioHierarchy.plan(
            network: "net", arriving: [ref("S-NET", "Example Network")],
            local: [network], parentOf: { _ in nil })
        XCTAssertEqual(result.cycles.count, 1)
    }

    // MARK: - 🔴 H3 / D4 — a hand-set parent survives

    func testH3AHandSetParentSurvivesAFetchThatDisagrees() {
        let chosen = LocalStudio(id: "imp", name: "Example Imprint", sourceId: "S-IMP",
                                 parentId: "somewhere-else", parentWasHandSet: true)
        let result = plan([ref("S-IMP", "Example Imprint")], [chosen])
        XCTAssertTrue(result.link.isEmpty, "evidence does not overwrite a statement")
        XCTAssertEqual(result.handSetKept.map(\.sourceId), ["S-IMP"],
                       "and it is SAID — silently keeping it looks like silently ignoring")
    }

    /// ⚠️ A hand-set NIL is not a chosen parent. The flag marks a parent
    /// someone picked, and there is nothing to have picked when there is none.
    func testAStudioWithNoParentIsLinkedEvenIfFlaggedHandSet() {
        let none = LocalStudio(id: "imp", name: "Example Imprint", sourceId: "S-IMP",
                               parentId: nil, parentWasHandSet: true)
        XCTAssertEqual(plan([ref("S-IMP", "Example Imprint")], [none]).link.count, 1)
    }

    // MARK: - H4 — an imprint owning no videos is distinguishable

    func testH4AnImprintWithNoLocalVideosIsMarked() {
        let empty = LocalStudio(id: "imp", name: "Example Imprint", sourceId: "S-IMP",
                                hasVideos: false)
        XCTAssertEqual(plan([ref("S-IMP", "Example Imprint")], [empty]).link.first?.ownsNoVideos,
                       true)
    }

    /// A studio that did not exist a moment ago owns nothing by definition.
    func testACreatedImprintIsMarkedAsOwningNothing() {
        XCTAssertEqual(plan([ref("S-NEW", "Brand New")], []).create.first?.ownsNoVideos, true)
    }

    // MARK: - H6 — fetching twice adds nothing

    func testH6AlreadyFiledImprintsAreUnchanged() {
        let filed = LocalStudio(id: "imp", name: "Example Imprint", sourceId: "S-IMP",
                                parentId: "net")
        let result = plan([ref("S-IMP", "Example Imprint")], [filed])
        XCTAssertEqual(result.unchanged.map(\.sourceId), ["S-IMP"])
        XCTAssertTrue(result.isEmpty, "a second fetch proposes nothing")
    }

    // MARK: - 🔴 H5 / H8 — aliases

    func testH5AnAliasNamingAnotherLocalStudioIsOnlyACandidate() {
        let other = LocalStudio(id: "dupe", name: "Example Pictures")
        let plan = StudioHierarchy.aliasPlan(["Example Pictures"], for: "imp",
                                             local: [other])
        XCTAssertEqual(plan.candidates.map(\.localId), ["dupe"])
        XCTAssertTrue(plan.unmatched.isEmpty)
    }

    /// 🚨 H8 — an alias naming nothing local creates NOTHING. An alias is a
    /// spelling, not an entity.
    func testH8AnAliasWithNoLocalStudioCreatesNothingAndIsReported() {
        let plan = StudioHierarchy.aliasPlan(["Nobody Holds This"], for: "imp", local: [])
        XCTAssertTrue(plan.candidates.isEmpty)
        XCTAssertEqual(plan.unmatched, ["Nobody Holds This"])
    }

    /// An alias naming its OWN studio is not a duplicate of anything.
    func testAnAliasNamingItsOwnStudioIsNotACandidate() {
        let itself = LocalStudio(id: "imp", name: "Example Imprint")
        let plan = StudioHierarchy.aliasPlan(["Example Imprint"], for: "imp", local: [itself])
        XCTAssertTrue(plan.candidates.isEmpty)
        XCTAssertTrue(plan.unmatched.isEmpty)
    }
}
