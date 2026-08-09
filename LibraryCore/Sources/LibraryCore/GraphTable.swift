// GraphTable.swift
// Every table the graph keeps its edges in, named once.
//
// 🚨 These lists existed in THREE places: the re-key's `rekeyedTables` and
// `countedTables`, the rename's inline edge-moving loop, and the upgrade
// screen's label map. Adding a relationship table meant finding all three, and
// missing one is silent — a rename would leave orphaned edges, or the migration
// would re-point rows it never counted.
//
// ⚠️ That has already happened once. `entity_match` arrived with v31 carrying
// the same ON DELETE CASCADE as the rest, and was omitted from the rename's
// list — so merging two profiles discarded the identity one of them had just
// been confirmed with. The fix at the time was to add it to that one list. This
// type is the fix to the shape of the problem.
//
// ⭐ The display names live here too, so the UI never has to read a SQL table
// name. A screen asking "what is `performer_tag` called?" is a screen coupled
// to the schema.

import Foundation

/// A table whose rows reference the graph.
public enum GraphTable: String, CaseIterable, Sendable {
    case videoPerformer = "video_performer"
    case videoStudio = "video_studio"
    case videoTag = "video_tag"
    case performerTag = "performer_tag"
    case studioParent = "studio_parent"
    case entityMatch = "entity_match"
    case pendingTagAssociation = "pending_tag_association"

    /// The columns in this table that hold an `entity_profiles.id`.
    ///
    /// ⚠️ EMPTY for the two tables keyed on tag identity rather than on an
    /// entity id. They are still counted by the migration's V3 gate — a change
    /// in their row count means something went wrong — but they must never be
    /// re-pointed, because the ids they hold are not entity ids at all.
    ///
    /// ⭐ `studioParent` has TWO. A hierarchy row names a child and a parent,
    /// and re-pointing only one of them would leave half the edge behind.
    public var entityColumns: [String] {
        switch self {
        case .videoPerformer:        return ["performer_id"]
        case .videoStudio:           return ["studio_id"]
        case .performerTag:          return ["performer_id"]
        case .studioParent:          return ["studio_id", "parent_studio_id"]
        case .entityMatch:           return ["entity_id"]
        case .videoTag,
             .pendingTagAssociation: return []
        }
    }

    /// What to call this on screen.
    public var displayName: String {
        switch self {
        case .videoPerformer:        return "Cast credits"
        case .videoStudio:           return "Studios"
        case .videoTag:              return "Tags on videos"
        case .performerTag:          return "Traits on performers"
        case .studioParent:          return "Studio hierarchy"
        case .entityMatch:           return "External identities"
        case .pendingTagAssociation: return "Tag links waiting"
        }
    }

    /// Every `(table, column)` pair that has to be re-pointed when a node's id
    /// changes — the re-key, and a rename or merge before the re-key.
    public static var entityReferences: [(table: String, column: String)] {
        allCases.flatMap { table in
            table.entityColumns.map { (table: table.rawValue, column: $0) }
        }
    }

    /// Every table whose row count must be unchanged by the migration.
    public static var counted: [String] { allCases.map(\.rawValue) }

    /// The label for a raw table name, for a caller holding one from a report.
    public static func label(for rawName: String) -> String {
        GraphTable(rawValue: rawName)?.displayName ?? rawName
    }
}
