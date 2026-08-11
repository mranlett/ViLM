// StaleMatchAudit.swift
// Matches the source says are gone or moved (#49).
//
// 🔴 REPORT, NEVER REPAIR. An upstream deletion is evidence about the source's
// records, not an instruction about ours. Records are removed upstream for
// reasons that have nothing to do with this library — a duplicate merged, a
// record reorganised, a moderator acting — and clearing a local match
// automatically would discard one the operator may have confirmed by hand, on
// the strength of a flag whose meaning is not ours to interpret.
//
// ⚠️ Pure. Deciding what to report is separable from finding it out, and only
// the deciding needs testing hard.

import Foundation
import GRDB

/// What a fetch CONCLUDED about a record.
///
/// 🚨 There is deliberately no `unknown` case, and that absence is the design.
///
/// D2 names three states that look alike: deleted upstream, never matched, and
/// unreachable. Collapsing the third into the first would report a deletion
/// every time the connection drops — a false finding arriving in bulk, which
/// teaches the operator to distrust the whole audit.
///
/// A failed fetch concluded NOTHING, so there is no value here to express it
/// with. A caller that cannot reach the source simply does not call. That makes
/// U2 a property of the type rather than a rule someone has to remember.
public enum SourceRecordState: Equatable, Sendable {
    /// Fetched, and the source still has it.
    case present
    /// Fetched, and the source says it is gone.
    case deleted
    /// Fetched, and the source says it moved. NOT a deletion.
    case merged(into: String)

    /// 🚨 Fetched, and the source has NO RECORD under that id.
    ///
    /// Added 2026-08-11 after measuring the device: 301 matches checked, 21
    /// returned no record at all, and **zero** carried a `deleted` flag. The
    /// source does not tombstone a removed performer — it simply stops
    /// resolving the id, so this is the only signal that will ever arrive, and
    /// the spec as written could never have reported anything.
    ///
    /// ⚠️ This does NOT break the rule that there is no `unknown` case. That
    /// rule exists so a FAILED FETCH cannot be recorded as a conclusion. This
    /// is not a failure to reach the source; it is a definite answer from it —
    /// "I have no record under that id" — and the two are already counted
    /// apart in `SourceRecheck`.
    ///
    /// ⭐ Reported as unresolved rather than deleted, because an id that stops
    /// resolving is ambiguous between three things: removed upstream, merged
    /// away with the old id retired, or an id that was wrong when we stored it.
    /// All three want the operator to look; only one of them is a deletion.
    case unresolved
}

/// One match worth telling the operator about.
public struct StaleMatchFinding: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case deleted
        /// The source has no record under the id we hold — see
        /// `SourceRecordState.unresolved`.
        case unresolved
        /// ⭐ Carries where it went, because the right action is to re-point
        /// rather than clear — and an audit that says "gone" when the source
        /// said "moved" gives advice that loses a good identity.
        case merged(into: String)
    }

    public let nodeId: String
    public let source: String
    public let sourceId: String
    /// What a person calls this. An id is not a finding anyone can act on.
    public let displayName: String
    public let kind: Kind
    /// When the source was seen to have changed it.
    public let seenAt: Date?

    /// Which table the match lives in — videos and entities are separate.
    ///
    /// 🚨 Carried rather than inferred. Both node kinds are identified by UUID
    /// strings, so there is nothing about `nodeId` to tell them apart: a caller
    /// that guesses would send every actor's finding to the video table, where
    /// it would silently match nothing and report success.
    ///
    /// Set by `staleMatchFindings()`, which queried the two tables separately
    /// and is the only thing that actually knows.
    public internal(set) var isVideo: Bool = false

    public var id: String { "\(nodeId)|\(source)" }
}

/// One match worth asking the source about again.
public struct RecheckTarget: Equatable, Sendable {
    public let nodeId: String
    /// The record to fetch — and the id the result is recorded against, so a
    /// re-check can never flag a match to something else.
    public let sourceId: String
    public let isVideo: Bool

    public init(nodeId: String, sourceId: String, isVideo: Bool) {
        self.nodeId = nodeId
        self.sourceId = sourceId
        self.isVideo = isVideo
    }
}

public enum StaleMatchAudit {

    /// Findings from what has been PERSISTED. No network, so the audit opens at
    /// any time — which is the whole reason #48 stores the flag rather than
    /// merely observing it.
    ///
    /// - Parameter displayNames: node id → what to call it. A node with no name
    ///   is still reported, under its id: an unnameable stale match is exactly
    ///   the kind that would otherwise never be looked at.
    public static func findings(from matches: [NodeMatch],
                                displayNames: [String: String]) -> [StaleMatchFinding] {
        matches.compactMap { match -> StaleMatchFinding? in
            let kind: StaleMatchFinding.Kind
            // ⚠️ Merged is tested FIRST. A record can carry both marks — some
            // sources tombstone a record and record where it went — and
            // reporting that as a plain deletion discards the forwarding
            // address, which is the more useful half.
            if let into = match.mergedInto, !into.isEmpty {
                kind = .merged(into: into)
            } else if match.deletedAt != nil {
                kind = .deleted
            } else if match.unresolvedAt != nil {
                // ⚠️ Ranked BELOW an explicit deletion. If the source ever does
                // tell us a record was removed, that is the better answer.
                kind = .unresolved
            } else {
                // U5 — never matched, or matched and fine. Neither belongs
                // here; an unmatched node is the identity-gap worklist's.
                return nil
            }
            return StaleMatchFinding(
                nodeId: match.nodeId, source: match.source, sourceId: match.sourceId,
                displayName: displayNames[match.nodeId] ?? match.nodeId,
                kind: kind,
                seenAt: match.deletedAt ?? match.unresolvedAt ?? match.checkedAt)
        }
        // Merges first: they are resolvable in one action, deletions need a
        // decision. Then by name, so the list does not reshuffle between runs.
        .sorted {
            let (a, b) = ($0.isMerge, $1.isMerge)
            return a == b
                ? $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                : a
        }
    }

    /// What the audit should say at the top, which differs by more than a count.
    public static func headline(_ findings: [StaleMatchFinding]) -> String {
        guard !findings.isEmpty else {
            return "Every match still resolves to a record at its source."
        }
        let merged = findings.filter(\.isMerge).count
        let unresolved = findings.filter { $0.kind == .unresolved }.count
        let deleted = findings.count - merged - unresolved
        var parts: [String] = []
        if merged > 0 {
            parts.append("\(merged) moved and can be re-pointed")
        }
        if deleted > 0 {
            parts.append("\(deleted) no longer exist\(deleted == 1 ? "s" : "") at the source")
        }
        // ⭐ Worded as the source's answer, not as a verdict. The id stopped
        // resolving; whether that is a deletion, a merge we cannot follow, or
        // an id that was always wrong is exactly what the operator decides.
        if unresolved > 0 {
            parts.append("\(unresolved) no longer resolve\(unresolved == 1 ? "s" : "") "
                         + "to any record")
        }
        return parts.joined(separator: "; ") + "."
    }
}

public extension StaleMatchFinding {
    var isMerge: Bool { if case .merged = kind { return true }; return false }
}

public extension LibraryStore {

    /// Records a fetch's conclusion.
    ///
    /// ⭐ Takes a CONCLUSION rather than raw flags, so "I could not reach the
    /// source" has no way to be expressed as "the source deleted it".
    /// - Parameter sourceId: the record that was fetched. The update applies
    ///   only if the node is still matched to it — see the underlying
    ///   `recordSourceState` for why fetching a candidate must not be able to
    ///   flag a match to something else.
    func recordSourceState(_ state: SourceRecordState, nodeId: String,
                           source: String, sourceId: String, isVideo: Bool,
                           at date: Date = Date()) throws {
        switch state {
        case .present:
            try recordSourceState(nodeId: nodeId, source: source, sourceId: sourceId,
                                  isVideo: isVideo, at: date)
        case .deleted:
            try recordSourceState(nodeId: nodeId, source: source, sourceId: sourceId,
                                  isVideo: isVideo, deletedAt: date, at: date)
        case .merged(let into):
            try recordSourceState(nodeId: nodeId, source: source, sourceId: sourceId,
                                  isVideo: isVideo, mergedInto: into, at: date)
        case .unresolved:
            try recordSourceState(nodeId: nodeId, source: source, sourceId: sourceId,
                                  isVideo: isVideo, unresolvedAt: date, at: date)
        }
    }

    /// Every match this library holds against one source, for re-checking.
    ///
    /// 🚨 The audit is otherwise PASSIVE — it reads flags earlier fetches
    /// happened to persist, which is the economy D4 chose. But on a library
    /// where no fetch has run since the feature shipped, that means the screen
    /// reports "nothing missing" forever and never can report anything else.
    /// A feature that cannot demonstrate itself is one nobody trusts.
    ///
    /// ⚠️ Only nodes WITH a match edge. The flag lives on the edge, so a node
    /// marked `matched` with no edge — what `Missing Identities` lists — cannot
    /// carry one and is not worth spending a request on.
    func matchesToRecheck(source: String) throws -> [RecheckTarget] {
        try dbQueue.read { db in
            let videos = try Row.fetchAll(db, sql: """
                SELECT video_id AS n, source_id AS s FROM video_match WHERE source = ?
                """, arguments: [source])
                .map { RecheckTarget(nodeId: $0["n"], sourceId: $0["s"], isVideo: true) }
            let entities = try Row.fetchAll(db, sql: """
                SELECT entity_id AS n, source_id AS s FROM entity_match WHERE source = ?
                """, arguments: [source])
                .map { RecheckTarget(nodeId: $0["n"], sourceId: $0["s"], isVideo: false) }
            // Entities first: performers are the only type the source forwards,
            // so they are the only ones that can yield a re-pointable finding.
            return entities + videos
        }
    }

    /// The audit, named for what a person would look for.
    func staleMatchFindings() throws -> [StaleMatchFinding] {
        var names: [String: String] = [:]
        for profile in try fetchAllEntityProfiles() { names[profile.id] = profile.name }
        for asset in try fetchAllAssets() {
            names[asset.id.uuidString] = ActorKnownFor.displayTitle(asset)
        }
        let videos = try staleMatches(isVideo: true)
        let entities = try staleMatches(isVideo: false)
        let videoIds = Set(videos.map(\.nodeId))
        return StaleMatchAudit.findings(from: videos + entities, displayNames: names)
            .map { finding in
                var finding = finding
                finding.isVideo = videoIds.contains(finding.nodeId)
                return finding
            }
    }
}

// MARK: - Resolving a finding (#50)

/// What happened to a match the operator acted on, kept so the deletion stays
/// auditable after the match itself is gone.
///
/// 🚨 This type exists because the spec contradicted itself and the audit found
/// it. U4 required clearing to remove "the match edge and the columns
/// together"; Decision 3 required keeping the old source id so the deletion
/// could be explained later. Both cannot hold — the columns ARE where the id
/// lives.
///
/// ⭐ Resolution: the profile clears COMPLETELY, and the history lives here
/// instead. A half-cleared node — columns gone, edge left, or the reverse — is
/// precisely the state `Missing Identities` exists to find, and a repair tool
/// must not manufacture them.
public struct ResolvedStaleMatch: Codable, Equatable, Sendable, FetchableRecord {
    public let nodeId: String
    public let source: String
    /// What it USED to be matched to. The whole point of the record.
    public let formerSourceId: String
    public let resolvedAt: Date
    public let outcome: Outcome

    public enum Outcome: String, Codable, Equatable, Sendable {
        case cleared
        case rePointed
    }
}

public extension LibraryStore {

    /// Re-points a merged match at its forwarding address.
    ///
    /// ⭐ ONE transaction. The edge, the columns and the audit record move
    /// together or not at all — a half-applied re-point would leave a node
    /// pointing at a record the source says is gone, with the finding cleared
    /// and nothing to notice by.
    ///
    /// ⚠️ Refusing changes nothing, which is why this is only called on accept.
    func rePointMatch(nodeId: String, source: String, isVideo: Bool,
                      to newSourceId: String, at date: Date = Date()) throws {
        let table = isVideo ? "video_match" : "entity_match"
        let column = isVideo ? "video_id" : "entity_id"
        try dbQueue.write { db in
            guard let former = try String.fetchOne(db, sql: """
                SELECT source_id FROM \(table) WHERE \(column) = ? AND source = ?
                """, arguments: [nodeId, source]) else { return }

            try db.execute(sql: """
                UPDATE \(table)
                   SET source_id = ?, merged_into = NULL, deleted_at = NULL, checked_at = ?
                 WHERE \(column) = ? AND source = ?
                """, arguments: [newSourceId, date, nodeId, source])

            // ⚠️ The profile's own column follows the edge. Leaving it on the
            // old id is the drift `confirmEntityMatch` exists to prevent.
            if !isVideo {
                try db.execute(sql: """
                    UPDATE entity_profiles SET enrichment_source_id = ? WHERE id = ?
                    """, arguments: [newSourceId, nodeId])
            }
            try Self.recordResolution(.init(nodeId: nodeId, source: source,
                                            formerSourceId: former, resolvedAt: date,
                                            outcome: .rePointed), in: db)
        }
    }

    /// Clears a match the source no longer has.
    ///
    /// 🚨 Removes the edge AND the columns. A node left with one but not the
    /// other claims an identity it cannot produce, which is exactly what
    /// `Missing Identities` reports and what no amount of re-matching fixes.
    func clearStaleMatch(nodeId: String, source: String, isVideo: Bool,
                         at date: Date = Date()) throws {
        let table = isVideo ? "video_match" : "entity_match"
        let column = isVideo ? "video_id" : "entity_id"
        try dbQueue.write { db in
            guard let former = try String.fetchOne(db, sql: """
                SELECT source_id FROM \(table) WHERE \(column) = ? AND source = ?
                """, arguments: [nodeId, source]) else { return }

            try db.execute(sql: "DELETE FROM \(table) WHERE \(column) = ? AND source = ?",
                           arguments: [nodeId, source])
            if !isVideo {
                try db.execute(sql: """
                    UPDATE entity_profiles
                       SET enrichment_source_id = NULL, enrichment_state = NULL
                     WHERE id = ?
                    """, arguments: [nodeId])
            }
            try Self.recordResolution(.init(nodeId: nodeId, source: source,
                                            formerSourceId: former, resolvedAt: date,
                                            outcome: .cleared), in: db)
        }
    }

    /// What this library has resolved, and what each used to point at.
    func resolvedStaleMatches() throws -> [ResolvedStaleMatch] {
        try dbQueue.read { db in
            try ResolvedStaleMatch.fetchAll(db, sql: """
                SELECT node_id AS nodeId, source, former_source_id AS formerSourceId,
                       resolved_at AS resolvedAt, outcome
                  FROM resolved_stale_match ORDER BY resolved_at DESC
                """)
        }
    }

    private static func recordResolution(_ r: ResolvedStaleMatch, in db: Database) throws {
        try db.execute(sql: """
            INSERT OR REPLACE INTO resolved_stale_match
                (node_id, source, former_source_id, resolved_at, outcome)
            VALUES (?, ?, ?, ?, ?)
            """, arguments: [r.nodeId, r.source, r.formerSourceId,
                             r.resolvedAt, r.outcome.rawValue])
    }
}
