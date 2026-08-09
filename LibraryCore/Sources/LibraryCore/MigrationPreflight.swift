// MigrationPreflight.swift
// What must be true before the re-keying tool touches anything.
//
// ⭐ Read-only, always. It answers "may this run?" and never changes a row, so
// it can be run as often as the operator likes and costs nothing to be wrong
// about in the safe direction.
//
// 🚨 It exists because the checks CANNOT live in the migration. v34 is a
// registered migration and runs on open; a gate there would either fail the
// app's startup or be bypassed entirely. D6 settled that split, and this is the
// other half of it.
//
// ⚠️ Two of these checks are here because the spec put them somewhere they
// could not work:
//
//   • The UNIQUE index on (entity_type, display_name). D1 asked for it in the
//     migration, where a violation would stop the library opening at all. Here
//     it is a REPORT — the duplicates are named and the operator decides.
//
//   • Free space. The four-phase photo move keeps both copies of every image
//     between phases 1 and 4, so this is required rather than advisory.

import Foundation
import GRDB

/// One identity claimed by more than one profile.
///
/// 🚨 Blocks the re-keying. Two rows sharing a name would each mint their own
/// uid, which is fine — but nothing downstream could then resolve that name to
/// one node, and every federation sync would pick arbitrarily between them.
public struct DuplicateIdentity: Equatable, Sendable, Identifiable {
    public let entityType: String
    public let displayName: String
    public let ids: [String]

    public var id: String { "\(entityType):\(displayName)" }

    public init(entityType: String, displayName: String, ids: [String]) {
        self.entityType = entityType
        self.displayName = displayName
        self.ids = ids
    }
}

/// Everything the tool checks before it is allowed to start.
public struct MigrationPreflight: Equatable, Sendable {

    /// Has v34 run? Without the columns there is nowhere to mint into.
    public let schemaReady: Bool

    /// 🚨 Identities claimed twice. See `DuplicateIdentity`.
    public let duplicates: [DuplicateIdentity]

    /// Profiles whose id yields no identity, so nothing can be derived for
    /// them. They cannot be re-keyed and must be fixed or removed first.
    public let unkeyableProfiles: [String]

    /// Edges pointing at a profile that does not exist. Re-pointing joins on
    /// the old id, so these would silently become NULL.
    public let danglingEdges: Int

    /// Bytes of profile and gallery images — what phase 1 must copy.
    public let photoBytes: Int64

    /// Bytes free on the volume holding the library.
    ///
    /// ⚠️ `nil` means the filesystem would not say. NOT zero — a volume that
    /// declines to report its free space is not a full volume, and conflating
    /// the two blocks a perfectly healthy library.
    public let freeBytes: Int64?

    /// Row counts per edge table, for V3 to assert against afterwards.
    ///
    /// ⚠️ Taken here for REPORTING only. The tool must re-take its own baseline
    /// inside the transaction that re-points — the library is in active use and
    /// a count read minutes earlier proves nothing about what it re-pointed.
    public let edgeCounts: [String: Int]

    /// Tombstones held. Reported so the count is visible, NOT because they are
    /// re-pointed — they are not, and cannot be. See `tombstoneNote`.
    public let tombstoneCount: Int

    public init(schemaReady: Bool, duplicates: [DuplicateIdentity],
                unkeyableProfiles: [String], danglingEdges: Int,
                photoBytes: Int64, freeBytes: Int64?,
                edgeCounts: [String: Int], tombstoneCount: Int) {
        self.schemaReady = schemaReady
        self.duplicates = duplicates
        self.unkeyableProfiles = unkeyableProfiles
        self.danglingEdges = danglingEdges
        self.photoBytes = photoBytes
        self.freeBytes = freeBytes
        self.edgeCounts = edgeCounts
        self.tombstoneCount = tombstoneCount
    }

    /// D3's formula: both copies exist between phases 1 and 4, plus room for
    /// the database to grow.
    public var requiredBytes: Int64 {
        Int64(Double(photoBytes) * 1.1) + 100 * 1_000_000
    }

    /// ⚠️ Unknown free space does NOT pass. It cannot be verified, and this is
    /// the gate in front of an irreversible operation — but it is reported as
    /// "could not be read" rather than as "the disk is full", because those
    /// call for completely different responses from the operator.
    public var hasEnoughSpace: Bool {
        guard let freeBytes else { return false }
        return freeBytes > requiredBytes
    }

    /// ⚠️ Stated wherever the tombstone count is shown, because the obvious
    /// reading of D1 is wrong and destructive.
    public static let tombstoneNote =
        "Tombstones are NOT re-keyed. Each names an entity that no longer "
        + "exists, so there is no row to mint a uid from — re-pointing them "
        + "would blank the deletion record and every deleted entity would "
        + "return on the next sync. They stay identified by name."

    /// Why this may not run. Empty means it may.
    public var blockers: [String] {
        var out: [String] = []
        if !schemaReady {
            out.append("The identity columns are missing — open the library once to apply v34.")
        }
        if !duplicates.isEmpty {
            out.append("\(duplicates.count) name\(duplicates.count == 1 ? " is" : "s are") "
                       + "claimed by more than one record. Merge them first; "
                       + "afterwards nothing could tell which one a name means.")
        }
        if !unkeyableProfiles.isEmpty {
            out.append("\(unkeyableProfiles.count) record\(unkeyableProfiles.count == 1 ? "" : "s") "
                       + "cannot be identified from their key and cannot be re-keyed.")
        }
        if danglingEdges > 0 {
            out.append("\(danglingEdges) edge\(danglingEdges == 1 ? "" : "s") point at a record "
                       + "that does not exist, and would be lost by re-pointing.")
        }
        if let freeBytes {
            if freeBytes <= requiredBytes {
                out.append("Not enough free space: needs "
                           + "\(MigrationPreflight.gb(requiredBytes)), has "
                           + "\(MigrationPreflight.gb(freeBytes)). Both copies of every "
                           + "photo exist while the move runs.")
            }
        } else {
            out.append("This volume would not report its free space, so the "
                       + "\(MigrationPreflight.gb(requiredBytes)) needed cannot be "
                       + "confirmed. Check there is room and re-run.")
        }
        return out
    }

    public var canProceed: Bool { blockers.isEmpty }

    static func gb(_ bytes: Int64) -> String {
        String(format: "%.2f GB", Double(bytes) / 1_000_000_000)
    }
}

public extension LibraryStore {

    /// Runs every gate. Changes nothing.
    func migrationPreflight() throws -> MigrationPreflight {
        let ready = try dbQueue.read { db in
            try db.columns(in: "entity_profiles").contains { $0.name == "uid" }
        }

        var duplicates: [DuplicateIdentity] = []
        var unkeyable: [String] = []
        if ready {
            try dbQueue.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT entity_type AS t, display_name AS n, group_concat(id, char(31)) AS ids
                      FROM entity_profiles
                     WHERE entity_type IS NOT NULL AND display_name IS NOT NULL
                     GROUP BY t, n HAVING COUNT(*) > 1
                    """)
                duplicates = rows.map {
                    DuplicateIdentity(entityType: $0["t"], displayName: $0["n"],
                                      ids: ($0["ids"] as String)
                                        .components(separatedBy: "\u{1F}"))
                }
                unkeyable = try String.fetchAll(db, sql: """
                    SELECT id FROM entity_profiles
                     WHERE entity_type IS NULL OR display_name IS NULL
                    """)
            }
        }

        // ⚠️ Every table whose column would be re-pointed. `deleted_entities`
        // is deliberately absent — it is not re-pointed, and joining it here
        // would report the 1,102 tombstones for genuinely-deleted entities as
        // dangling when they are correct.
        let dangling = try dbQueue.read { db -> Int in
            var total = 0
            for (table, column) in [("video_performer", "performer_id"),
                                    ("video_studio", "studio_id"),
                                    ("studio_parent", "studio_id"),
                                    ("studio_parent", "parent_studio_id"),
                                    ("entity_match", "entity_id")] {
                total += try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM \(table) t
                     WHERE NOT EXISTS (SELECT 1 FROM entity_profiles p WHERE p.id = t.\(column))
                    """) ?? 0
            }
            return total
        }

        var counts: [String: Int] = [:]
        try dbQueue.read { db in
            for table in ["video_performer", "video_studio", "video_tag",
                          "performer_tag", "studio_parent", "entity_match",
                          "pending_tag_association"] {
                counts[table] = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
            }
        }
        let tombstones = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM deleted_entities") ?? 0
        }

        return MigrationPreflight(
            schemaReady: ready,
            duplicates: duplicates,
            unkeyableProfiles: unkeyable,
            danglingEdges: dangling,
            photoBytes: Self.directoryBytes(profilesDirectory),
            freeBytes: Self.freeBytes(at: libraryURL),
            edgeCounts: counts,
            tombstoneCount: tombstones)
    }

    /// Where profile and gallery images live.
    var profilesDirectory: URL {
        libraryURL.appendingPathComponent(".catalog/profiles")
    }

    /// 🚨 ALLOCATED size, not logical size.
    ///
    /// A copy consumes whole allocation blocks, and the drive library lives on
    /// an ExFAT volume with a **256 KB** block. Across 9,202 mostly-small
    /// images that is nearly double: 1.61 GB of file contents occupy 3.17 GB of
    /// disk. Summing `fileSizeKey` under-reported the requirement by a factor
    /// the 10% margin could never absorb — the gate would have passed a run
    /// that then died halfway through copying.
    ///
    /// ⚠️ Measured per file, never estimated from a count. Image sizes vary by
    /// an order of magnitude.
    static func directoryBytes(_ directory: URL) -> Int64 {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        else { return 0 }
        return entries.reduce(Int64(0)) { total, url in
            let values = try? url.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey])
            // Falls back through progressively worse answers rather than
            // reporting nothing: an underestimate is still better than a zero.
            let size = values?.totalFileAllocatedSize
                ?? values?.fileAllocatedSize
                ?? values?.fileSize
                ?? 0
            return total + Int64(size)
        }
    }

    /// 🚨 `volumeAvailableCapacityForImportantUsage` is an APFS/HFS+ concept —
    /// it accounts for purgeable space — and returns nothing on **ExFAT**,
    /// which is what the drive library is formatted as. Coercing that to zero
    /// reported "0.00 GB free" on a volume with 239 GB and blocked the upgrade
    /// outright. Reported from the device 2026-08-08.
    ///
    /// ⚠️ Returns nil when nothing can be read, so the caller can say "could
    /// not be read" instead of "the disk is full".
    static func freeBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 {
            return important
        }
        if let plain = values?.volumeAvailableCapacity, plain > 0 {
            return Int64(plain)
        }
        return nil
    }
}
