// EntityTombstone.swift
// A record that an entity was deliberately removed.
//
// Sync compares what each library HAS. Without a record of removal it cannot
// tell "this library never had the actor" from "this library deleted the
// actor" — and a union of the two always resurrects the deleted one. Deleting
// in both places by hand is not a workaround either, because whichever library
// you delete from second gets the record copied back before you finish.
//
// Renames are the common source. Accepting a canonical name from a lookup is a
// delete plus a create; sync sees only the create, so the old name returns from
// the other library on the next pass.

import Foundation
import GRDB

public struct EntityTombstone: Codable, Equatable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "deleted_entities"

    /// The entity id that was removed, e.g. `actor:Helen B`.
    public let entityId: String
    public let deletedAt: Date
    /// The id it became, when the removal was a rename. Carried so a future
    /// version can rename rather than delete-and-copy; today it is provenance
    /// that makes a propagated deletion explicable rather than mysterious.
    public let replacedBy: String?

    public var id: String { entityId }

    public init(entityId: String, deletedAt: Date = Date(), replacedBy: String? = nil) {
        self.entityId = entityId
        self.deletedAt = deletedAt
        self.replacedBy = replacedBy
    }

    enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case deletedAt = "deleted_at"
        case replacedBy = "replaced_by"
    }
}

public enum TombstoneRules {

    /// Whether a deletion should be propagated to a library still holding the
    /// profile.
    ///
    /// A profile created AFTER the deletion was recorded is a deliberate
    /// re-creation and outranks the tombstone — otherwise re-adding an actor you
    /// once removed would be undone on the next sync, which is worse than the
    /// resurrection this exists to prevent.
    ///
    /// `createdAt` is the only timestamp the profile carries. It is a weak
    /// signal (an edit does not move it), but it is the right one here: the
    /// question is whether this record predates the deletion, not whether it has
    /// been touched since.
    public static func shouldPropagate(tombstone: EntityTombstone,
                                       to profile: EntityProfile?) -> Bool {
        guard let profile else { return false }   // nothing to delete
        guard let created = profile.createdAt else { return true }
        return created <= tombstone.deletedAt
    }

    /// Whether an incoming profile should be refused because it predates a
    /// recorded deletion.
    ///
    /// Distinct from `shouldPropagate`, which asks about a copy this library
    /// already holds. A library that has ALREADY removed the entity has nothing
    /// to delete — but it must still refuse the copy arriving in the same
    /// export, or the deletion is undone by the very sync meant to carry it.
    public static func suppressesImport(tombstone: EntityTombstone,
                                        incoming: EntityProfile?) -> Bool {
        guard let incoming else { return true }
        guard let created = incoming.createdAt else { return true }
        return created <= tombstone.deletedAt
    }

    /// The winning tombstone for an id across libraries: the most recent.
    public static func newest(_ tombstones: [EntityTombstone]) -> EntityTombstone? {
        tombstones.max { $0.deletedAt < $1.deletedAt }
    }
}
