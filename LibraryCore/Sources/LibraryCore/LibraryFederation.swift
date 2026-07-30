// LibraryFederation.swift
// Pure helpers for the multi-library session (federated view): several
// libraries open at once, rendered as one union without any on-disk merging.
// See plans/dual-library-session.md.

import Foundation

public enum LibraryFederation {
    /// The result of admitting a newly-attached library's assets into the
    /// session union.
    public struct UnionPartition: Sendable {
        /// Rows to include, in their original order.
        public let included: [Asset]
        /// Ids excluded because a higher-precedence open library already has
        /// the same id. This happens with backup-cloned libraries (restore
        /// duplicates row ids); the copies are literally the same catalog row,
        /// so the higher-precedence one is shown and these are hidden.
        public let excludedIDs: [Asset.ID]
    }

    /// Partitions `incoming` (an attaching library's assets) against the ids
    /// already present in the union. First occurrence in precedence order
    /// wins; order within `incoming` is preserved.
    public static func partitionForUnion(
        incoming: [Asset], existingIDs: Set<Asset.ID>
    ) -> UnionPartition {
        var included: [Asset] = []
        var excluded: [Asset.ID] = []
        for asset in incoming {
            if existingIDs.contains(asset.id) {
                excluded.append(asset.id)
            } else {
                included.append(asset)
            }
        }
        return UnionPartition(included: included, excludedIDs: excluded)
    }
}
