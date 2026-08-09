// GraphTableTests.swift
// The canonical list of graph tables, checked against the real schema.

import XCTest
import GRDB
@testable import LibraryCore

final class GraphTableTests: XCTestCase {

    private var url: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphTable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store = try LibraryStore(at: url)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: url)
    }

    /// 🚨 The guard against the next table being added and forgotten.
    ///
    /// A new relationship table that references `entity_profiles` but is absent
    /// from `GraphTable` would be silently skipped by the re-key and by every
    /// rename — leaving orphaned edges with nothing reporting it. That is
    /// exactly what happened when `entity_match` arrived in v31.
    func testEveryTableReferencingEntityProfilesIsListed() throws {
        let referencing: Set<String> = try store.dbQueue.read { db in
            var found: Set<String> = []
            let tables = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                 WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                   AND name NOT LIKE 'grdb_%'
                """)
            for table in tables where table != "entity_profiles" {
                let keys = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(table))")
                if keys.contains(where: { ($0["table"] as String?) == "entity_profiles" }) {
                    found.insert(table)
                }
            }
            return found
        }

        let listed = Set(GraphTable.allCases.filter { !$0.entityColumns.isEmpty }.map(\.rawValue))
        XCTAssertEqual(referencing, listed,
                       "a table references entity_profiles but is not in GraphTable — "
                       + "the re-key and every rename would skip it")
    }

    /// ⚠️ Every listed column must actually exist, or the re-key's UPDATE
    /// would fail at the worst possible moment.
    func testEveryListedColumnExistsInItsTable() throws {
        try store.dbQueue.read { db in
            for (table, column) in GraphTable.entityReferences {
                let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
                    .compactMap { $0["name"] as String? }
                XCTAssertTrue(columns.contains(column),
                              "\(table).\(column) is listed but does not exist")
            }
        }
    }

    /// ⚠️ The counted set is everything, including the two tables keyed on tag
    /// identity — they are never re-pointed, but a change in their row count
    /// still means something went wrong.
    func testCountedIncludesTheTablesThatAreNeverRePointed() {
        XCTAssertTrue(GraphTable.counted.contains("video_tag"))
        XCTAssertTrue(GraphTable.counted.contains("pending_tag_association"))
        XCTAssertTrue(GraphTable.videoTag.entityColumns.isEmpty,
                      "tag tables key on tag identity, not an entity id")
        XCTAssertTrue(GraphTable.pendingTagAssociation.entityColumns.isEmpty)
    }

    /// A hierarchy row names two nodes; re-pointing one would leave half the
    /// edge behind.
    func testTheHierarchyTableCarriesBothOfItsEndpoints() {
        XCTAssertEqual(Set(GraphTable.studioParent.entityColumns),
                       ["studio_id", "parent_studio_id"])
    }

    /// The UI asks the domain for a label rather than switching on SQL names.
    func testEveryTableHasALabelAndUnknownOnesPassThrough() {
        for table in GraphTable.allCases {
            XCTAssertFalse(table.displayName.isEmpty)
            XCTAssertNotEqual(table.displayName, table.rawValue,
                              "\(table.rawValue) still shows its SQL name")
        }
        XCTAssertEqual(GraphTable.label(for: "something_new"), "something_new")
    }
}
