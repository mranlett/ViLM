// LibraryInvariants.swift
// What must be true of a library after ANY sequence of operations.
//
// 🚨 The gap this closes. 138 test files and 1,790 tests, every one of which
// builds its own fixture, calls one function and asserts on that function —
// so six defects in a single session all lived in the SEAMS, with green units
// on both sides:
//
//   • `entityIdForWriting` returned an id for a row it never saved
//   • `apply(to: nil)` produced a node with no identity — and a unit test
//     already passed nil and passed, because it asserted the bio
//   • the merge screen passed uids to a function tested only with tags
//   • `recordSourceState` was complete, mutation-tested, and had NO CALLERS
//
// A unit test can only fail on what it thought to check. These assert
// properties of the WHOLE library instead, so a caller that skips a step or
// hands the wrong shape along is caught by the state it leaves behind rather
// than by someone having predicted the mistake.
//
// ⭐ Built on the app's own audits. They already encode these invariants — and
// running them here makes them tests of themselves, which matters because
// `IdentityGapAudit` was silently reporting a clean bill while dropping the
// most broken rows in the library.

import XCTest
import GRDB
@testable import LibraryCore

/// Every invariant, checked together. Call it after any journey.
///
/// - Parameter allowing: invariants a specific journey legitimately breaks —
///   named, so an exception is a deliberate statement rather than a silence.
func assertLibraryInvariants(_ store: LibraryStore,
                             allowing: Set<LibraryInvariant> = [],
                             file: StaticString = #filePath,
                             line: UInt = #line) throws {
    for invariant in LibraryInvariant.allCases where !allowing.contains(invariant) {
        try invariant.check(store, file: file, line: line)
    }
}

enum LibraryInvariant: CaseIterable {
    /// 🚨 Every node has a name and a kind. A row with an id and nothing else
    /// renders as its own uid, cannot be found by name, and is unreachable by
    /// every route the app offers.
    case everyNodeHasAnIdentity

    /// Every actor named on a video resolves to exactly one profile — no
    /// orphaned cast strings, and no name owned by two rows.
    case everyCreditedNameResolvesToOneProfile

    /// 🚨 A source id is a definitive identity. Two local rows claiming the
    /// same one are the same person recorded twice.
    case noTwoProfilesShareASourceIdentity

    /// A node marked `matched` carries the edge that proves what it matched.
    case everyMatchedNodeHasAnEdge

    /// No video is dated before a credited performer was born, and so on.
    case theGraphContainsNothingImpossible

    func check(_ store: LibraryStore, file: StaticString, line: UInt) throws {
        switch self {
        case .everyNodeHasAnIdentity:
            let nameless = try store.namelessNodes()
            XCTAssertTrue(nameless.isEmpty,
                          "\(nameless.count) node(s) carry an id and no identity: "
                          + nameless.map(\.nodeId).joined(separator: ", "),
                          file: file, line: line)

        case .everyCreditedNameResolvesToOneProfile:
            let profiles = try store.fetchAllEntityProfiles()
            let actors = profiles.filter { $0.type == "actor" }
            var owners: [String: Int] = [:]
            for actor in actors {
                owners[actor.name.lowercased(), default: 0] += 1
            }
            let duplicated = owners.filter { $0.value > 1 }.keys.sorted()
            XCTAssertTrue(duplicated.isEmpty,
                          "\(duplicated.count) name(s) owned by more than one profile",
                          file: file, line: line)

            let known = Set(actors.map { $0.name.lowercased() })
            var orphaned = Set<String>()
            for asset in try store.fetchAllAssets() {
                for name in asset.actors where !name.isEmpty {
                    if !known.contains(name.lowercased()) { orphaned.insert(name) }
                }
            }
            XCTAssertTrue(orphaned.isEmpty,
                          "\(orphaned.count) credited name(s) have no profile",
                          file: file, line: line)

        case .noTwoProfilesShareASourceIdentity:
            var bySource: [String: Int] = [:]
            for profile in try store.fetchAllEntityProfiles() {
                guard let sid = profile.enrichmentSourceId, !sid.isEmpty else { continue }
                bySource[sid, default: 0] += 1
            }
            let shared = bySource.filter { $0.value > 1 }
            XCTAssertTrue(shared.isEmpty,
                          "\(shared.count) source identit(ies) claimed by more than one profile",
                          file: file, line: line)

        case .everyMatchedNodeHasAnEdge:
            let (entities, videos) = try store.nodesMatchedWithoutAnEdge()
            XCTAssertTrue(entities.isEmpty && videos.isEmpty,
                          "\(entities.count) entit(ies) and \(videos.count) video(s) claim a "
                          + "match with no edge to show for it",
                          file: file, line: line)

        case .theGraphContainsNothingImpossible:
            let certain = try store.auditGraph().filter { $0.severity == .certain }
            XCTAssertTrue(certain.isEmpty,
                          "\(certain.count) impossible finding(s): "
                          + certain.map(\.title).joined(separator: "; "),
                          file: file, line: line)
        }
    }
}
