// SourceGapAudit.swift
// What else is this performer in, that I do not have? (#39, #40)
//
// 🚨 A different KIND of tool from everything else here. Every other audit
// describes, corrects or connects what the library CONTAINS. This one reports
// on what is missing from it — the first time the app looks outward — and that
// changes what "wrong" means. An orphan audit that misses a row costs a repair;
// this one, wrong, sends the operator looking for something already on disk.
//
// ⭐ Possible only because of the match edges. The hard part was never asking
// the source what a performer appears in; it was answering "do I already have
// this?", which used to be a fuzzy title comparison and is now an exact lookup
// on the source's own scene id.
//
// ⚠️ Pure. No network, no store — the caller supplies the source's answer and
// this library's matches. Deciding what is missing is the part worth testing
// hard, and it tests without either.

import Foundation
import GRDB

/// One thing the source knows about and this library does not.
public struct SourceGap: Equatable, Sendable, Identifiable {
    /// The source's own scene id.
    public let sourceId: String
    public let title: String
    public let studioName: String?
    public let releaseDate: String?

    public var id: String { sourceId }

    public init(sourceId: String, title: String,
                studioName: String? = nil, releaseDate: String? = nil) {
        self.sourceId = sourceId
        self.title = title
        self.studioName = studioName
        self.releaseDate = releaseDate
    }
}

/// A gap list, and how much of it to believe.
///
/// 🔴 D1 — the decision the feature turns on. A blanket "some of these may
/// already be in your library" is useless: a caveat covering everything says
/// nothing about anything, and gets either ignored or generalised into distrust
/// of the whole list. The over-report is measurable PER ACTOR, locally, so this
/// carries the numbers that make it precise.
public struct SourceGapReport: Equatable, Sendable {
    public let gaps: [SourceGap]
    /// Videos in this library featuring the performer.
    public let localVideos: Int
    /// ...of which carry an identity, and so could be checked against.
    public let identifiedLocalVideos: Int
    /// ⚠️ True when the source's answer was capped. A truncated list
    /// UNDER-reports, which looks like good news and is the harder failure to
    /// notice.
    public let sourceTruncated: Bool

    /// How many of the gaps might be wrong.
    ///
    /// Each unidentified local video could be any one of these scenes, so the
    /// uncertainty is bounded by the smaller of the two counts — claiming more
    /// doubt than there are gaps would be its own kind of wrong.
    public var possiblyAlreadyHeld: Int {
        min(localVideos - identifiedLocalVideos, gaps.count)
    }

    /// ⭐ Exact when every local video featuring this performer is identified:
    /// there is nothing on disk that could be hiding in the list.
    public var isExact: Bool { possiblyAlreadyHeld == 0 }

    /// 🚨 No identified videos at all means no basis for comparison. The
    /// source's whole filmography would come back as "missing", which is not an
    /// answer — it is the question restated.
    public var hasNoBasis: Bool { localVideos > 0 && identifiedLocalVideos == 0 }

    /// One line the operator can act on, rather than a warning they will learn
    /// to skip.
    public var confidence: String {
        if hasNoBasis {
            return "None of your \(localVideos) video\(localVideos == 1 ? "" : "s") with this performer "
                + "carries an identity, so there is nothing to compare against. Match some of them first."
        }
        if gaps.isEmpty {
            return sourceTruncated
                ? "Nothing new in the first \(gaps.count + identifiedLocalVideos) the source listed."
                : "Nothing the source lists is missing from your library."
        }
        let head = "\(gaps.count) scene\(gaps.count == 1 ? "" : "s") you do not have."
        if isExact {
            return head + " All \(localVideos) of your video\(localVideos == 1 ? "" : "s") "
                + "with this performer are identified, so this list is exact."
        }
        let n = possiblyAlreadyHeld
        return head + " \(n) of your \(localVideos) videos with this performer "
            + "\(n == 1 ? "is" : "are") not identified, so up to \(n) of these may already be on disk."
    }
}

public enum SourceGapAudit {

    /// What the source lists for a performer, minus what this library already
    /// has from THAT source.
    ///
    /// - Parameters:
    ///   - sourceScenes: the source's answer, in its order.
    ///   - source: which provider answered. 🚨 Load-bearing — see below.
    ///   - localMatches: every match this library holds, any source.
    ///   - localVideos / identifiedLocalVideos: this performer's footprint on
    ///     disk, for the confidence line.
    ///   - truncated: whether the source's answer hit its limit.
    public static func report(sourceScenes: [SourceGap],
                              source: String,
                              localMatches: [NodeMatch],
                              localVideos: Int,
                              identifiedLocalVideos: Int,
                              truncated: Bool) -> SourceGapReport {

        // 🚨 Scoped to the SAME source, and this is not a formality. A scene id
        // from one provider means nothing to another; they are different
        // namespaces that happen to both be strings. Comparing across them
        // would mark a scene as "already held" because an unrelated provider
        // uses the same id — a false negative that hides a real gap, and is
        // invisible because the list simply comes back shorter.
        let held = Set(localMatches.filter { $0.source == source }.map(\.sourceId))

        var seen = Set<String>()
        var gaps: [SourceGap] = []
        for scene in sourceScenes {
            guard !held.contains(scene.sourceId) else { continue }
            // ⚠️ A source that lists one scene twice must not produce two gaps.
            guard seen.insert(scene.sourceId).inserted else { continue }
            gaps.append(scene)
        }

        return SourceGapReport(gaps: gaps,
                               localVideos: localVideos,
                               identifiedLocalVideos: max(0, min(identifiedLocalVideos, localVideos)),
                               sourceTruncated: truncated)
    }
}

public extension LibraryStore {

    /// Every video identity this library holds from one source.
    ///
    /// ⚠️ Filtered in SQL by source rather than in the caller. The whole point
    /// of `SourceGapAudit`'s scoping is that another provider's ids must never
    /// enter the comparison, and a read that hands back all of them invites
    /// exactly that mistake one call site later.
    func videoMatches(source: String) throws -> [NodeMatch] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT video_id, source, source_id, method, matched_at
                  FROM video_match WHERE source = ?
                """, arguments: [source]).map { row in
                NodeMatch(nodeId: row["video_id"], source: row["source"],
                          sourceId: row["source_id"],
                          method: MatchMethod(rawValue: row["method"]) ?? .title,
                          matchedAt: row["matched_at"] ?? Date())
            }
        }
    }

    /// How many videos feature this performer, and how many of those carry an
    /// identity — the two numbers D1's confidence line is built from.
    ///
    /// ⭐ Counts through BOTH representations, edges and tag strings, because a
    /// video connected one way and not the other is still a video the operator
    /// has. Undercounting here would overstate how exact a gap list is, which
    /// is the direction that misleads.
    func videoIdentityFootprint(forActor name: String,
                                source: String) throws -> (total: Int, identified: Int) {
        try dbQueue.read { db in
            var videos = Set<String>()

            // Through the graph.
            let byEdge = try String.fetchAll(db, sql: """
                SELECT vp.video_id FROM video_performer vp
                  JOIN entity_profiles p ON p.id = vp.performer_id
                 WHERE p.entity_type = 'actor' AND p.display_name = ?
                """, arguments: [name])
            videos.formUnion(byEdge)

            // ⚠️ And through the strings, which are still where much of the
            // library lives. `json_each` rather than a LIKE, so a performer
            // whose name is a substring of another's is not counted twice.
            let byString = try String.fetchAll(db, sql: """
                SELECT DISTINCT a.id FROM assets a, json_each(a.tags) j
                 WHERE j.value = ?
                """, arguments: ["actor:\(name)"])
            videos.formUnion(byString)

            guard !videos.isEmpty else { return (0, 0) }

            let identified = try Set(String.fetchAll(db, sql: """
                SELECT DISTINCT video_id FROM video_match WHERE source = ?
                """, arguments: [source]))
            return (videos.count, videos.filter { identified.contains($0) }.count)
        }
    }
}

// MARK: - What the source says about a record we hold (#48)

public extension LibraryStore {

    /// Records what a fetch learned about a record's continued existence.
    ///
    /// 🚨 Called wherever a record is fetched — a re-match, a refresh, an
    /// enrichment — because that is the whole economy of this feature: the flag
    /// rides along on requests already being made, so knowing costs nothing.
    ///
    /// ⚠️ `checkedAt` is stamped on EVERY call, including the ordinary one
    /// where nothing is wrong. Without it there is no way to tell "confirmed
    /// still there this morning" from "never asked", and an audit that cannot
    /// distinguish those is reporting its own ignorance as a clean bill.
    ///
    /// ⭐ And a flag can go AWAY. Upstream deletions are reversible — a
    /// moderator restores a record, a merge is undone — so a fetch that finds
    /// the record alive clears both marks. A flag that only accumulates leaves
    /// permanent false findings, and an audit that cannot be cleared is one
    /// people stop reading.
    /// 🚨 `sourceId` is the record that was actually FETCHED, and the update
    /// applies only if the node is still matched to it.
    ///
    /// Without that scope this is a live trap. Re-matching a video means
    /// fetching several candidates from the same source to compare them; each
    /// carries its own state. Keyed on `(node, source)` alone, fetching a
    /// candidate the source had deleted would stamp "deleted" onto the node's
    /// existing and perfectly healthy match to a DIFFERENT record — an entirely
    /// fabricated finding, produced by looking at something else.
    ///
    /// ⚠️ Required rather than defaulted, because every caller knows it: you
    /// cannot fetch a record without naming which one. A default would only
    /// serve callers who had stopped thinking about it.
    func recordSourceState(nodeId: String, source: String, sourceId: String,
                           isVideo: Bool,
                           deletedAt: Date? = nil, mergedInto: String? = nil,
                           at date: Date = Date()) throws {
        let table = isVideo ? "video_match" : "entity_match"
        let column = isVideo ? "video_id" : "entity_id"
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE \(table)
                   SET deleted_at = ?, merged_into = ?, checked_at = ?
                 WHERE \(column) = ? AND source = ? AND source_id = ?
                """, arguments: [deletedAt, mergedInto, date, nodeId, source, sourceId])
        }
    }

    /// Every match this library holds that the source says is gone or moved.
    ///
    /// ⚠️ Reads only what was PERSISTED. It performs no network access, which
    /// is the property that makes the audit openable at any time — and the
    /// reason the flag has to be stored rather than merely seen.
    func staleMatches(isVideo: Bool) throws -> [NodeMatch] {
        let table = isVideo ? "video_match" : "entity_match"
        let column = isVideo ? "video_id" : "entity_id"
        return try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT \(column), source, source_id, method, matched_at,
                       deleted_at, merged_into, checked_at
                  FROM \(table)
                 WHERE deleted_at IS NOT NULL OR merged_into IS NOT NULL
                """).compactMap { row in
                guard let method = MatchMethod(rawValue: row["method"]) else { return nil }
                return NodeMatch(nodeId: row[column], source: row["source"],
                                 sourceId: row["source_id"], method: method,
                                 matchedAt: row["matched_at"],
                                 deletedAt: row["deleted_at"],
                                 mergedInto: row["merged_into"],
                                 checkedAt: row["checked_at"])
            }
        }
    }
}
