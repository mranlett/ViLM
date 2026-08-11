// NamelessNodeRepair.swift
// Restoring identity to rows minted without one (the 2026-08-10 device report).
//
// 🚨 These rows exist because `entityIdForWriting` returned an id off a factory
// that saves nothing, so edges were written against an identifier with no row
// behind it. That is fixed at the source; this is for the damage already done.
//
// ⭐ The name is recoverable, and that is the whole reason this can be
// automatic. A damaged node still has EDGES — the videos that credited it — and
// those videos still carry the performer's name as a plain string in
// `Asset.actors`. The name was never lost; it was only never copied onto the
// row.
//
// ⚠️ Reports before it repairs, and repairs only what it can name. A row with
// no edge, or whose videos disagree about the name, is listed and left alone —
// guessing an identity is exactly the failure this whole area keeps producing.

import Foundation
import GRDB

/// One damaged node, and what can be done about it.
public struct NamelessNode: Equatable, Sendable, Identifiable {
    public let nodeId: String
    /// The name recovered from the videos crediting it, when they agree.
    public let recoveredName: String?
    /// How many videos credit this node.
    public let videoCount: Int

    public var id: String { nodeId }
    public var isRepairable: Bool { recoveredName != nil }
}

public extension LibraryStore {

    /// Profile rows carrying an id and no identity.
    ///
    /// ⚠️ Both columns must be absent. A row with a type and no name is a
    /// different (and lesser) problem, and sweeping it in here would let this
    /// repair rename things it does not understand.
    func namelessNodes() throws -> [NamelessNode] {
        let damaged: [String] = try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT id FROM entity_profiles
                 WHERE (display_name IS NULL OR display_name = '')
                   AND (entity_type  IS NULL OR entity_type  = '')
                 ORDER BY id
                """)
        }
        guard !damaged.isEmpty else { return [] }
        let wanted = Set(damaged)

        // node id -> the names the crediting videos use for it.
        var namesByNode: [String: Set<String>] = [:]
        var countByNode: [String: Int] = [:]

        let edges: [(String, String)] = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT performer_id, video_id FROM video_performer")
                .map { ($0["performer_id"], $0["video_id"]) }
        }
        var assetsById: [String: Asset] = [:]
        for asset in try fetchAllAssets() { assetsById[asset.id.uuidString] = asset }

        // Names already spoken for by a healthy row. ⚠️ Without this a damaged
        // node could be repaired onto a name another profile already owns,
        // turning one broken row into two rows for one person.
        let taken = Set(try fetchAllEntityProfiles()
            .filter { !wanted.contains($0.id) }
            .compactMap { $0.displayName?.lowercased() })

        // The resolver maps a cast string to the node it actually resolves to,
        // so a name that already points elsewhere is not misattributed here.
        let resolver = NodeResolver(profiles: try fetchAllEntityProfiles())

        for (nodeId, videoId) in edges where wanted.contains(nodeId) {
            countByNode[nodeId, default: 0] += 1
            guard let asset = assetsById[videoId] else { continue }
            for name in asset.actors where !name.isEmpty {
                // 🚨 Evidence is a name with NO HOME, or one already pointing
                // here. Requiring it to resolve to this node rejects everything
                // — a damaged row has no name for the resolver to match on,
                // which is the entire defect. The orphaned cast string IS the
                // missing identity.
                //
                // ⚠️ A name that resolves to a DIFFERENT node is not evidence:
                // that person has a healthy row, and borrowing their name here
                // would create the duplicate this is meant to prevent.
                let resolved = resolver.localId(for: "actor:\(name)")
                guard resolved == nil || resolved == nodeId else { continue }
                namesByNode[nodeId, default: []].insert(name)
            }
        }

        return damaged.map { id in
            let candidates = namesByNode[id] ?? []
            // ⚠️ Exactly one, and not already owned. Two disagreeing names is
            // not a name, and merging into an existing profile is a decision
            // nobody asked this to make.
            let recovered = candidates.count == 1
                ? candidates.first.flatMap { taken.contains($0.lowercased()) ? nil : $0 }
                : nil
            return NamelessNode(nodeId: id, recoveredName: recovered,
                                videoCount: countByNode[id] ?? 0)
        }
    }

    /// Writes the recovered identity back onto the rows that have one.
    ///
    /// ⭐ Only the two identity columns. Everything else on the row — a bio, a
    /// photo, a source id the operator matched by hand — is left exactly as it
    /// is: the row was never wrong, it was only anonymous.
    ///
    /// - Returns: how many rows were repaired.
    @discardableResult
    func repairNamelessNodes(_ nodes: [NamelessNode]? = nil) throws -> Int {
        let targets = try (nodes ?? namelessNodes()).filter(\.isRepairable)
        guard !targets.isEmpty else { return 0 }
        return try dbQueue.write { db in
            var repaired = 0
            for node in targets {
                guard let name = node.recoveredName else { continue }
                try db.execute(sql: """
                    UPDATE entity_profiles
                       SET display_name = ?, entity_type = 'actor'
                     WHERE id = ?
                       AND (display_name IS NULL OR display_name = '')
                    """, arguments: [name, node.nodeId])
                repaired += db.changesCount
            }
            return repaired
        }
    }
}
