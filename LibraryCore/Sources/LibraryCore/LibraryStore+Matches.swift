// LibraryStore+Matches.swift
// Reading and writing the match edges (migration v31).
//
// ⚠️ Both representations are live. The `enrichment*` columns on the node stay
// authoritative until a per-node check shows the edges reproduce them — the
// same staging the string→edge migration uses, and for the same reason. Every
// read here therefore has to be explicit about WHICH it is answering from, and
// the union readers say so in their names.

import Foundation
import GRDB

extension LibraryStore {

    // MARK: - Writing

    /// Records that a node was identified in a source.
    ///
    /// ⚠️ Upserts on (node, source). Re-matching the same node in the same
    /// source REPLACES that source's answer rather than accumulating rows — a
    /// second opinion from the same place is a correction, not a second
    /// identity. A different source is a different row and both survive.
    public func recordMatch(_ match: NodeMatch, isVideo: Bool) throws {
        let table = isVideo ? "video_match" : "entity_match"
        let column = isVideo ? "video_id" : "entity_id"
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO \(table) (\(column), source, source_id, method, matched_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(\(column), source) DO UPDATE SET
                    source_id = excluded.source_id,
                    method = excluded.method,
                    matched_at = excluded.matched_at
                """, arguments: [match.nodeId, match.source, match.sourceId,
                                 match.method.rawValue, match.matchedAt])
        }
    }

    /// Forgets one source's answer for a node.
    ///
    /// ⚠️ Scoped to a source. Clearing "every match" would discard identities
    /// this library never asked about, which is the destructive reading of a
    /// re-match.
    public func removeMatch(nodeId: String, source: String, isVideo: Bool) throws {
        let table = isVideo ? "video_match" : "entity_match"
        let column = isVideo ? "video_id" : "entity_id"
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM \(table) WHERE \(column) = ? AND source = ?",
                           arguments: [nodeId, source])
        }
    }

    /// Records a match on a PROFILE — the columns and the edge together.
    ///
    /// ⭐ One entry point, because the two must not drift. Every call site that
    /// set `enrichmentSourceId` by hand is a site that could forget the edge,
    /// and "forgot" is exactly how 1,287 nodes ended up claiming to be matched
    /// with nothing to look up.
    ///
    /// ⚠️ The columns are still written. They stay authoritative until a
    /// per-node check shows the edges reproduce them, so writing only the edge
    /// would make a node look unmatched to every existing reader.
    public func confirmEntityMatch(_ entityId: String, source: String,
                                   sourceId: String?, method: MatchMethod) throws {
        guard var profile = try fetchEntityProfile(for: entityId) else { return }
        profile.enrichmentState = .matched
        profile.enrichmentSource = source
        profile.enrichmentCheckedAt = Date()
        // ⚠️ Never blanks an id this library holds — the same rule
        // `confirmStudio` follows, and for the same reason: replacing one would
        // silently re-point a confirmed match at something else.
        if let sourceId, !sourceId.isEmpty, (profile.enrichmentSourceId ?? "").isEmpty {
            profile.enrichmentSourceId = sourceId
        }
        try saveEntityProfile(profile)

        if let sourceId, !sourceId.isEmpty {
            try recordMatch(NodeMatch(nodeId: entityId, source: source,
                                      sourceId: sourceId, method: method),
                            isVideo: false)
        }
    }

    /// Records WHO a node is, without claiming its metadata has been fetched.
    ///
    /// 🚨 The distinction that matters. `confirmEntityMatch` sets
    /// `enrichmentState = .matched`, which means "a lookup ran and concluded" —
    /// and `ActorBatchPolicy.skipReason` skips anything in that state. So
    /// learning a performer's identity from a video match, and recording it as
    /// `.matched`, would make `Match All Actors` skip them: identified, and
    /// permanently without a bio, photos, birth date or career span.
    ///
    /// ⭐ Identity and enrichment are different questions. Knowing WHICH record
    /// a performer is does not mean their details have been downloaded — it
    /// means the next lookup can go straight to it.
    func recordDiscoveredIdentity(_ entityId: String, source: String,
                                  sourceId: String, method: MatchMethod) throws {
        guard var profile = try fetchEntityProfile(for: entityId) else { return }
        if (profile.enrichmentSourceId ?? "").isEmpty {
            profile.enrichmentSourceId = sourceId
            try saveEntityProfile(profile)
        }
        try recordMatch(NodeMatch(nodeId: entityId, source: source,
                                  sourceId: sourceId, method: method),
                        isVideo: false)
    }

    /// The same for a video.
    public func confirmVideoMatch(_ videoId: UUID, source: String,
                                  sourceId: String?, method: MatchMethod) throws {
        guard let sourceId, !sourceId.isEmpty else { return }
        try recordMatch(NodeMatch(nodeId: videoId.uuidString, source: source,
                                  sourceId: sourceId, method: method),
                        isVideo: true)
    }

    /// Hands a video's match down to the performers the source linked to it.
    ///
    /// ⭐ The source's scene record LINKS to confirmed performer records. Those
    /// links are identities the source already established — so a matched video
    /// can identify its whole cast, instead of leaving every performer to be
    /// re-matched by name, repeating a disambiguation that was already done.
    ///
    /// 🚨 Only from a STRONG video match. A title match is "plausible, not
    /// identified", and treating its cast links as confirmed would launder one
    /// guess into a dozen confidently wrong identities — across actors who then
    /// look verified and are skipped by every later tool.
    ///
    /// ⚠️ Never overrules an identity the library holds. A performer already
    /// matched keeps their answer; this only fills gaps.
    ///
    /// Returns how many performers gained one.
    @discardableResult
    public func propagateIdentities(_ credits: [ProposedCredit], source: String,
                                    videoMethod: MatchMethod) throws -> Int {
        guard videoMethod.propagatesIdentity else { return 0 }
        let known = Set(try fetchAllEntityProfiles().map(\.id))
        var written = 0

        for credit in credits {
            guard let sourceId = credit.sourceId, !sourceId.isEmpty else { continue }
            let entityId = "actor:\(credit.name)"
            guard known.contains(entityId) else { continue }
            // Already identified in this source: leave it entirely alone.
            guard try matches(forEntity: entityId)
                    .first(where: { $0.source == source }) == nil else { continue }

            // ⚠️ Identity only — the state is left alone. Marking these
            // `.matched` would make `Match All Actors` skip them, so a
            // performer identified by a video would never gain a bio or photos.
            try recordDiscoveredIdentity(entityId, source: source,
                                         sourceId: sourceId, method: .linked)
            written += 1
        }
        return written
    }

    /// Identities from a video matched BEFORE the method was recorded.
    ///
    /// 🚨 The situation this exists for: a full match run made before the app
    /// asked for performer ids leaves every video `.matched`, so `Match All
    /// Videos` skips them forever and the only other route is `Match Again` —
    /// which re-reads every file from disk and re-opens every ambiguity the
    /// operator already settled. That is a disproportionate price for data the
    /// source will hand over on a single lookup.
    ///
    /// ⚠️ Deliberately separate from `propagateIdentities`, and deliberately
    /// NOT reached by relaxing `propagatesIdentity`. The live rule should stay
    /// strict, because while a video is in front of someone it can still be
    /// rejected. This is the other case, and it takes a different view for a
    /// stated reason:
    ///
    /// ⭐ The performer's id and their NAME arrive in the same scene record and
    /// are consistent with each other. Propagating attaches a correct identity
    /// to a correctly-spelled person; what a weak video match gets wrong is
    /// whether that performer appears in THIS video — and the original run
    /// already wrote their name onto it. The doubtful edge exists either way,
    /// so the identity adds accuracy rather than error.
    @discardableResult
    public func propagateIdentitiesFromSettledMatch(
        _ credits: [ProposedCredit], source: String) throws -> Int {
        let known = Set(try fetchAllEntityProfiles().map(\.id))
        var written = 0
        for credit in credits {
            guard let sourceId = credit.sourceId, !sourceId.isEmpty else { continue }
            let entityId = "actor:\(credit.name)"
            guard known.contains(entityId) else { continue }
            guard try matches(forEntity: entityId)
                    .first(where: { $0.source == source }) == nil else { continue }
            // ⚠️ Identity only — the state is left alone. Marking these
            // `.matched` would make `Match All Actors` skip them, so a
            // performer identified by a video would never gain a bio or photos.
            try recordDiscoveredIdentity(entityId, source: source,
                                         sourceId: sourceId, method: .linked)
            written += 1
        }
        return written
    }

    // MARK: - Reading

    /// Every source that has identified this node, newest first.
    public func matches(forVideo videoId: UUID) throws -> [NodeMatch] {
        try readMatches(table: "video_match", column: "video_id", node: videoId.uuidString)
    }

    public func matches(forEntity entityId: String) throws -> [NodeMatch] {
        try readMatches(table: "entity_match", column: "entity_id", node: entityId)
    }

    private func readMatches(table: String, column: String, node: String) throws -> [NodeMatch] {
        let rows: [NodeMatch] = try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT \(column), source, source_id, method, matched_at
                  FROM \(table) WHERE \(column) = ?
                """, arguments: [node])
                .compactMap { row in
                    // ⚠️ An unrecognised method decodes as nil and the row is
                    // SKIPPED rather than defaulting — a value written by a
                    // newer build must not silently read as `backfill`, which
                    // would understate how well the node was identified.
                    guard let method = MatchMethod(rawValue: row["method"]) else { return nil }
                    return NodeMatch(nodeId: row[column], source: row["source"],
                                     sourceId: row["source_id"], method: method,
                                     matchedAt: row["matched_at"])
                }
        }
        return NodeMatchRanking.ordered(rows)
    }

    /// Every entity match in the library — what a sync carries.
    public func allEntityMatches() throws -> [NodeMatch] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT entity_id, source, source_id, method, matched_at
                  FROM entity_match
                """).compactMap { row in
                    guard let method = MatchMethod(rawValue: row["method"]) else { return nil }
                    return NodeMatch(nodeId: row["entity_id"], source: row["source"],
                                     sourceId: row["source_id"], method: method,
                                     matchedAt: row["matched_at"])
                }
        }
    }

    // MARK: - The migration's own questions

    /// Nodes claiming to be matched that have no match edge.
    ///
    /// 🚨 The 1,287. This is the query a column could not answer: a null
    /// `enrichmentSourceId` beside `enrichmentState = matched` is
    /// indistinguishable from a node nobody ever looked up, so those nodes were
    /// invisible AND unreachable — `skipReason` returns "already matched", so
    /// the tool that would supply an id refuses to examine them.
    ///
    /// Returns entity ids and video ids separately, because the tools that
    /// would repair them are different.
    public func nodesMatchedWithoutAnEdge() throws -> (entities: [String], videos: [UUID]) {
        try dbQueue.read { db in
            let entities = try String.fetchAll(db, sql: """
                SELECT p.id FROM entity_profiles p
                 WHERE p.enrichment_state = 'matched'
                   AND NOT EXISTS (SELECT 1 FROM entity_match m WHERE m.entity_id = p.id)
                 ORDER BY p.id
                """)
            let videos = try String.fetchAll(db, sql: """
                SELECT a.id FROM assets a
                 WHERE a.enrichment_state = 'matched'
                   AND NOT EXISTS (SELECT 1 FROM video_match m WHERE m.video_id = a.id)
                """).compactMap(UUID.init(uuidString:))
            return (entities, videos)
        }
    }

    /// The missing-identity worklist, with a route back for each entry.
    ///
    /// ⚠️ Counts videos across BOTH representations. Most of a library is still
    /// carried by `actor:` tag strings, so reading edges alone would report
    /// "0 videos" for nearly every gap — and "0 videos" is exactly what makes
    /// one look unrecoverable. The screen would then tell the operator to fix
    /// by hand what a single refresh would have fixed.
    public func identityGaps() throws -> IdentityGapReport {
        let (entities, _) = try nodesMatchedWithoutAnEdge()
        guard !entities.isEmpty else { return IdentityGapReport(gaps: []) }
        let wanted = Set(entities)

        var videos: [String: Set<UUID>] = [:]
        var matchedVideos: [String: Set<UUID>] = [:]

        // Edges.
        let performerRows: [(String, String)] = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT performer_id, video_id FROM video_performer")
                .map { ($0["performer_id"], $0["video_id"]) }
        }
        let studioRows: [(String, String)] = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT studio_id, video_id FROM video_studio")
                .map { ($0["studio_id"], $0["video_id"]) }
        }
        let matchedIds: Set<String> = try dbQueue.read { db in
            Set(try String.fetchAll(db, sql:
                "SELECT id FROM assets WHERE enrichment_state = 'matched'"))
        }
        for (node, video) in performerRows + studioRows where wanted.contains(node) {
            guard let uuid = UUID(uuidString: video) else { continue }
            videos[node, default: []].insert(uuid)
            if matchedIds.contains(video) { matchedVideos[node, default: []].insert(uuid) }
        }

        // Strings, which are still where most of the library lives.
        for asset in try fetchAllAssets() {
            let isMatched = asset.enrichmentState == .matched
            for name in Set(asset.actors) {
                let id = "actor:\(name)"
                guard wanted.contains(id) else { continue }
                videos[id, default: []].insert(asset.id)
                if isMatched { matchedVideos[id, default: []].insert(asset.id) }
            }
            for name in Set(asset.studios) {
                let id = "studio:\(name)"
                guard wanted.contains(id) else { continue }
                videos[id, default: []].insert(asset.id)
                if isMatched { matchedVideos[id, default: []].insert(asset.id) }
            }
        }

        return IdentityGapAudit.report(.init(
            missing: entities,
            videosByNode: videos.mapValues(\.count),
            matchedVideosByNode: matchedVideos.mapValues(\.count)))
    }

    /// Creates match edges from the identity columns, for everything that has
    /// one and no edge yet.
    ///
    /// ⚠️ A node marked `matched` with NO source id produces no row,
    /// deliberately. That absence is the finding — inventing a row with an
    /// empty id would bury exactly what this migration exists to surface.
    ///
    /// ⚠️ `method = .backfill`, never `.operator`. The method was not recorded
    /// at the time and is genuinely unknown; claiming a person chose it would
    /// invent evidence.
    ///
    /// Idempotent: re-running adds nothing, because it only writes where no
    /// edge exists.
    @discardableResult
    public func backfillMatchEdges() throws -> (entities: Int, videos: Int) {
        let now = Date()
        return try dbQueue.write { db in
            var entities = 0, videos = 0

            for row in try Row.fetchAll(db, sql: """
                SELECT p.id, p.enrichment_source, p.enrichment_source_id,
                       p.enrichment_checked_at
                  FROM entity_profiles p
                 WHERE p.enrichment_source_id IS NOT NULL
                   AND p.enrichment_source_id <> ''
                   AND NOT EXISTS (SELECT 1 FROM entity_match m WHERE m.entity_id = p.id)
                """) {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO entity_match
                        (entity_id, source, source_id, method, matched_at)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [row["id"],
                                     // A source that was never named still has
                                     // an id worth keeping; "unknown" is honest
                                     // and keeps the row addressable.
                                     (row["enrichment_source"] as String?) ?? "unknown",
                                     row["enrichment_source_id"],
                                     MatchMethod.backfill.rawValue,
                                     (row["enrichment_checked_at"] as Date?) ?? now])
                entities += 1
            }

            for row in try Row.fetchAll(db, sql: """
                SELECT a.id, a.enrichment_source, a.enrichment_source_id,
                       a.enrichment_checked_at
                  FROM assets a
                 WHERE a.enrichment_source_id IS NOT NULL
                   AND a.enrichment_source_id <> ''
                   AND NOT EXISTS (SELECT 1 FROM video_match m WHERE m.video_id = a.id)
                """) {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO video_match
                        (video_id, source, source_id, method, matched_at)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [row["id"],
                                     (row["enrichment_source"] as String?) ?? "unknown",
                                     row["enrichment_source_id"],
                                     MatchMethod.backfill.rawValue,
                                     (row["enrichment_checked_at"] as Date?) ?? now])
                videos += 1
            }

            return (entities, videos)
        }
    }
}
