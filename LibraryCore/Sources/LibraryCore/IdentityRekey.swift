// IdentityRekey.swift
// The one irreversible operation in this project: names stop being keys.
//
// 🚨 FOUR PHASES, and the ORDER is the safety. D3, confirmed by the operator:
//
//   1. COPY   every photo to its uid-derived name — both names now exist
//   2. VERIFY the new files are all there — abort here and the database is
//             untouched, so nothing has happened at all
//   3. COMMIT the database change in ONE transaction
//   4. DELETE the old-named files — interruptible, idempotent, orphans harmless
//
// A crash at any point leaves BOTH copies of every file rather than neither.
// That is the only failure mode where nothing is lost, which is what makes it
// the right shape for a step that cannot be undone.
//
// ⚠️ Committing the database before copying the files would desynchronise disk
// from catalogue with no way back — the same class of failure as the Epic's V1,
// one layer down and irreversible.

import Foundation
import GRDB

/// What the re-key will do, computed before anything happens.
///
/// ⭐ Every phase takes THIS, rather than re-deriving. The four phases must
/// agree about which node becomes which uid and which file becomes which file;
/// re-deriving between them would let the library change underneath and hand
/// phase 4 a different answer than phase 1 acted on.
public struct RekeyPlan: Equatable, Sendable {
    /// old `prefix:Name` → freshly minted opaque id.
    public let uidByOldId: [String: String]
    /// old filename → new filename, both relative to the profiles directory.
    public let fileRenames: [String: String]
    /// Row counts per edge table at planning time, for V3.
    public let edgeCounts: [String: Int]

    public var nodeCount: Int { uidByOldId.count }
    public var photoCount: Int { fileRenames.count }

    public init(uidByOldId: [String: String], fileRenames: [String: String],
                edgeCounts: [String: Int]) {
        self.uidByOldId = uidByOldId
        self.fileRenames = fileRenames
        self.edgeCounts = edgeCounts
    }
}

public struct RekeyResult: Equatable, Sendable {
    public let nodesRekeyed: Int
    public let photosCopied: Int
    public let photosDeleted: Int
    public let edgesRepointed: [String: Int]

    public init(nodesRekeyed: Int, photosCopied: Int, photosDeleted: Int,
                edgesRepointed: [String: Int]) {
        self.nodesRekeyed = nodesRekeyed
        self.photosCopied = photosCopied
        self.photosDeleted = photosDeleted
        self.edgesRepointed = edgesRepointed
    }
}

public enum RekeyError: Error, Equatable {
    /// Phase 2 found fewer new files than phase 1 should have written.
    case photosMissing(expected: Int, found: Int)
    /// 🚨 An edge table's row count changed across the re-point. V3.
    case edgeCountChanged(table: String, before: Int, after: Int)
    /// A node still references an id that is not a known uid.
    case unresolvedReference(table: String, count: Int)
}

public extension LibraryStore {

    /// Every table whose column points at `entity_profiles.id`.
    ///
    /// 🚨 `deleted_entities` is deliberately ABSENT. A tombstone names an
    /// entity that no longer exists, so there is no row to mint a uid from —
    /// re-pointing it would blank the deletion record, and every deleted entity
    /// would return on the next federation sync. Tombstones stay name-keyed,
    /// which is what D4 requires and what the federation boundary implements.
    static let rekeyedTables: [(table: String, column: String)] = [
        ("video_performer", "performer_id"),
        ("video_studio", "studio_id"),
        ("performer_tag", "performer_id"),
        ("studio_parent", "studio_id"),
        ("studio_parent", "parent_studio_id"),
        ("entity_match", "entity_id"),
    ]

    /// Tables counted for V3. `video_tag` and `pending_tag_association` key on
    /// tag identity rather than on an entity id, so they are counted but never
    /// re-pointed — a change in either would mean something unrelated moved.
    static let countedTables = [
        "video_performer", "video_studio", "video_tag",
        "performer_tag", "studio_parent", "entity_match",
        "pending_tag_association",
    ]

    /// Works out what will happen. Changes nothing.
    func rekeyPlan(makeUid: () -> String = { UUID().uuidString }) throws -> RekeyPlan {
        let profiles = try fetchAllEntityProfiles()

        var uids: [String: String] = [:]
        for profile in profiles where NodeIdentity.parse(profile.id) != nil {
            uids[profile.id] = makeUid()
        }

        // ⭐ File mapping is built by SCANNING the directory and attributing
        // each file to the LONGEST matching safe id, not by trusting the
        // database's photo columns.
        //
        // ⚠️ Longest-match matters: `actor_Jane` is a prefix of `actor_Janet`,
        // and a performer named "Jane_abc" would otherwise look like a gallery
        // file belonging to "Jane". Scanning also carries across files the
        // database has forgotten, which a column-driven mapping would orphan.
        let directory = profilesDirectory
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let safeIds = uids.keys
            .map { (safe: ProfileImageNaming.safeId(for: $0), oldId: $0) }
            .sorted { $0.safe.count > $1.safe.count }

        var renames: [String: String] = [:]
        for file in existing {
            guard let owner = safeIds.first(where: { candidate in
                file == "\(candidate.safe).jpg" || file.hasPrefix("\(candidate.safe)_")
            }), let uid = uids[owner.oldId] else { continue }
            let newSafe = ProfileImageNaming.safeId(for: uid)
            renames[file] = newSafe + file.dropFirst(owner.safe.count)
        }

        var counts: [String: Int] = [:]
        try dbQueue.read { db in
            for table in Self.countedTables {
                counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
            }
        }

        return RekeyPlan(uidByOldId: uids, fileRenames: renames, edgeCounts: counts)
    }

    /// PHASE 1 — copy every photo to its new name. Both names now exist.
    ///
    /// ⚠️ Re-runnable and non-destructive: a file already copied is skipped, so
    /// an interrupted phase 1 is resumed simply by running it again.
    @discardableResult
    func rekeyCopyPhotos(_ plan: RekeyPlan) throws -> Int {
        let directory = profilesDirectory
        var copied = 0
        for (old, new) in plan.fileRenames {
            let source = directory.appendingPathComponent(old)
            let destination = directory.appendingPathComponent(new)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            if FileManager.default.fileExists(atPath: destination.path) { continue }
            try FileManager.default.copyItem(at: source, to: destination)
            copied += 1
        }
        return copied
    }

    /// PHASE 2 — every new name must exist before the database moves.
    ///
    /// 🚨 Aborting here leaves the database untouched, so a failure at this
    /// point means nothing happened at all. That is the whole reason the copy
    /// comes first.
    func rekeyVerifyPhotos(_ plan: RekeyPlan) throws {
        let directory = profilesDirectory
        // Only files whose SOURCE still exists are required: phase 4 of an
        // earlier run may already have removed originals.
        let expected = plan.fileRenames.filter {
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent($0.key).path)
                || FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent($0.value).path)
        }
        let found = expected.filter {
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent($0.value).path)
        }
        guard found.count == expected.count else {
            throw RekeyError.photosMissing(expected: expected.count, found: found.count)
        }
    }

    /// PHASE 3 — the database, in ONE transaction.
    ///
    /// 🚨 `defer_foreign_keys` is what makes this possible at all. Six tables
    /// carry a foreign key to `entity_profiles(id)` with `ON DELETE CASCADE`
    /// and no `ON UPDATE`, so changing a primary key would be rejected the
    /// moment it happened. Deferring moves every check to COMMIT, by which
    /// point parents and children have both moved and the graph is consistent.
    ///
    /// ⚠️ Children are re-pointed BEFORE the parent, while `entity_profiles.id`
    /// still holds the old value — that is what the join needs. With the checks
    /// deferred the intermediate state is allowed to be inconsistent; at commit
    /// it must not be, and V3 below proves it.
    func rekeyCommit(_ plan: RekeyPlan) throws -> RekeyResult {
        try dbQueue.write { db in
            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")

            var repointed: [String: Int] = [:]
            for (table, column) in Self.rekeyedTables {
                try db.execute(sql: """
                    UPDATE \(table) SET \(column) = (
                        SELECT uid FROM entity_profiles p WHERE p.id = \(table).\(column)
                    )
                    WHERE \(column) IN (SELECT id FROM entity_profiles WHERE uid IS NOT NULL)
                    """)
                repointed[table, default: 0] += db.changesCount
            }

            // The parent last. `uid` was written by the mint below in the same
            // statement set, so it is already present on every row.
            try db.execute(sql: "UPDATE entity_profiles SET id = uid WHERE uid IS NOT NULL")
            let nodes = db.changesCount

            // ⚠️ V3, INSIDE the transaction. A count taken before the write
            // began proves nothing about what this transaction did — the
            // library is in daily use.
            for table in Self.countedTables {
                let after = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
                guard let before = plan.edgeCounts[table], before == after else {
                    throw RekeyError.edgeCountChanged(
                        table: table, before: plan.edgeCounts[table] ?? -1, after: after)
                }
            }

            // 🚨 And that every reference resolves. A count can match while
            // pointing at the wrong rows; this asserts that none points at
            // something that is not a node.
            for (table, column) in Self.rekeyedTables {
                let orphans = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM \(table) t
                     WHERE NOT EXISTS (SELECT 1 FROM entity_profiles p WHERE p.id = t.\(column))
                    """) ?? 0
                guard orphans == 0 else {
                    throw RekeyError.unresolvedReference(table: table, count: orphans)
                }
            }

            return RekeyResult(nodesRekeyed: nodes,
                               photosCopied: plan.fileRenames.count,
                               photosDeleted: 0,
                               edgesRepointed: repointed)
        }
    }

    /// Writes the minted ids into the `uid` column. Additive and reversible —
    /// nothing reads `uid` until phase 3 moves `id` onto it.
    func rekeyMintUids(_ plan: RekeyPlan) throws {
        try dbQueue.write { db in
            for (oldId, uid) in plan.uidByOldId {
                try db.execute(sql: "UPDATE entity_profiles SET uid = ? WHERE id = ?",
                               arguments: [uid, oldId])
            }
        }
    }

    /// PHASE 4 — remove the old-named files.
    ///
    /// ⚠️ Idempotent and interruptible by design. Interrupted, it leaves some
    /// old names present, which is HARMLESS: the database already points at the
    /// new names, so those are unreferenced orphans. It must never treat a
    /// missing old file as an error, and it must be safe to run without
    /// checking whether it ran before.
    @discardableResult
    func rekeyDeleteOldPhotos(_ plan: RekeyPlan) throws -> Int {
        let directory = profilesDirectory
        var deleted = 0
        for (old, new) in plan.fileRenames {
            let oldURL = directory.appendingPathComponent(old)
            let newURL = directory.appendingPathComponent(new)
            // 🚨 Only ever delete an original whose copy is confirmed present.
            guard FileManager.default.fileExists(atPath: newURL.path),
                  FileManager.default.fileExists(atPath: oldURL.path),
                  old != new else { continue }
            try FileManager.default.removeItem(at: oldURL)
            deleted += 1
        }
        return deleted
    }
}
