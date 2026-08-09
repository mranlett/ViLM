// LibraryStore+GraphEdges.swift
// The edge tables directly: writing one edge, and every question asked of them.
//
// Split from `LibraryStore+Graph.swift` on 2026-08-07 — that file held both the
// MIGRATION from strings to edges and the edges themselves, which are different
// jobs with different lifetimes. The migration code is temporary and retires
// when the last string does; this is permanent.
//
// ⚠️ Everything here reads the edges ALONE, with no fallback to the legacy
// strings — deliberately, and the opposite of `LibraryStore+Graph.swift`. These
// are the graph's own answers. A caller that needs the union while both
// representations exist wants the readers in that file instead, and mixing the
// two is how a count comes out different depending on which one was asked.

import Foundation
import GRDB

extension LibraryStore {

    // MARK: - Graph edges
    //
    // ⚠️ Every one of these can THROW on a constraint, and that is the point.
    // A second studio on a video, a duplicate edge, a studio as its own parent
    // — the schema refuses them, so callers get an error instead of the graph
    // quietly acquiring something impossible.

    /// Credits a performer on a video. Idempotent: crediting twice is one edge.
    ///
    /// - Parameter source: where the credit came from. Defaults to `inferred`
    ///   because the callers that predate edge attributes are rewiring from
    ///   strings; a caller that knows better should say so.
    public func linkPerformer(_ performerId: String, toVideo videoId: UUID,
                              source: EdgeProvenance = .inferred) throws {
        try dbQueue.write { db in
            // Bound, not interpolated. The value is a fixed enum today and
            // interpolating it would still be a habit worth not having in a
            // file this size.
            try db.execute(sql: """
                INSERT OR IGNORE INTO video_performer
                    (video_id, performer_id, source, recorded_at)
                VALUES (?, ?, ?, ?)
                """, arguments: [videoId.uuidString, performerId,
                                 source.rawValue, Date()])
        }
    }

    /// Sets the releasing studio, REPLACING any existing one.
    ///
    /// A scene has one releasing studio, so this is an assignment rather than
    /// an addition — and the primary key means a caller cannot accidentally
    /// make it an addition.
    public func setStudio(_ studioId: String, forVideo videoId: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO video_studio (video_id, studio_id) VALUES (?, ?)
                ON CONFLICT(video_id) DO UPDATE SET studio_id = excluded.studio_id
                """, arguments: [videoId.uuidString, studioId])
        }
    }

    /// Attaches a tag to a video. `tagId` is the folded identity key.
    public func linkTag(_ tagId: String, toVideo videoId: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO video_tag (video_id, tag_id) VALUES (?, ?)
                """, arguments: [videoId.uuidString, tagId])
        }
    }

    public func linkTag(_ tagId: String, toPerformer performerId: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO performer_tag (performer_id, tag_id) VALUES (?, ?)
                """, arguments: [performerId, tagId])
        }
    }

    /// Records that `studioId` belongs to `parentId`.
    ///
    /// ⚠️ Refuses a cycle — a studio that would become its own ancestor. Not
    /// expressible as a SQLite constraint, and without it a parent-studio
    /// filter recurses forever.
    /// - Parameters:
    ///   - since: when the new ownership began. `nil` means "as far back as we
    ///     know", which is the honest value when a source names a parent but no
    ///     date — which is every source seen so far.
    ///
    /// ⚠️ A CHANGE of parent closes the previous row rather than overwriting
    /// it. The old ownership was true; it stopped being true. Overwriting threw
    /// that away, which is the whole reason for the temporal shape.
    ///
    /// ⚠️ Re-asserting the SAME parent is a no-op, not a new row. Match runs
    /// re-assert constantly, and each one opening a period would fill the table
    /// with adjacent identical rows.
    public func setStudioParent(_ parentId: String, forStudio studioId: String,
                                since: String? = nil,
                                source: EdgeProvenance = .download) throws {
        guard studioId != parentId else { throw GraphEdgeError.cycle(path: [studioId]) }

        var seen = [studioId]
        var current: String? = parentId
        while let id = current {
            if seen.contains(id) { throw GraphEdgeError.cycle(path: seen + [id]) }
            seen.append(id)
            // The CURRENT parent — a closed historical row must not make a
            // hierarchy look cyclic when it is only a former owner.
            current = try dbQueue.read { db in
                try String.fetchOne(db, sql: """
                    SELECT parent_studio_id FROM studio_parent
                     WHERE studio_id = ? AND valid_to IS NULL
                    """, arguments: [id])
            }
        }

        try dbQueue.write { db in
            let existing = try String.fetchOne(db, sql: """
                SELECT parent_studio_id FROM studio_parent
                 WHERE studio_id = ? AND valid_to IS NULL
                """, arguments: [studioId])

            if existing == parentId { return }

            // 🚨 The boundary is ONE date used twice, so the periods meet.
            //
            // Closing the old row at today while inserting the new one with
            // `valid_from = NULL` made the new period cover all of history —
            // and `studioParentPairs(asOf:)` then returned BOTH parents for any
            // past date, breaking the one-parent-at-a-time invariant the whole
            // temporal shape exists to hold. Found by an independent audit,
            // 2026-08-07; the existing tests missed it by always passing an
            // explicit `since`.
            //
            // NULL stays correct for a FIRST parent — "as far back as we know"
            // — and is only wrong when it follows something.
            let boundary = since ?? Self.isoDay(Date())

            if existing != nil {
                try db.execute(sql: """
                    UPDATE studio_parent SET valid_to = ?
                     WHERE studio_id = ? AND valid_to IS NULL
                    """, arguments: [boundary, studioId])
            }

            try db.execute(sql: """
                INSERT INTO studio_parent
                    (studio_id, parent_studio_id, valid_from, valid_to, source, recorded_at)
                VALUES (?, ?, ?, NULL, ?, ?)
                """, arguments: [studioId, parentId,
                                 existing == nil ? since : boundary,
                                 source.rawValue, Date()])
        }
    }

    /// Stages a tag found with no edge context — not an edge, and invisible to
    /// every graph query until someone says what the tag describes.
    public func addPendingTagAssociation(_ tagId: String, forVideo videoId: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO pending_tag_association (video_id, tag_id) VALUES (?, ?)
                """, arguments: [videoId.uuidString, tagId])
        }
    }

    // MARK: Reading the graph

    /// Records how a performer was credited in one video.
    ///
    /// ⚠️ Upserts the ATTRIBUTES onto an existing edge rather than replacing
    /// the edge. The edge itself is `(video, performer)` and does not change;
    /// what a match learns is how they were billed and where that came from.
    ///
    /// ⚠️ A nil argument leaves the stored value alone rather than clearing it
    /// — the same rule as `ProposedField`, where "the source said nothing" must
    /// never overwrite something already known (D5).
    public func recordPerformerCredit(_ credit: PerformerCredit,
                                      forVideo videoId: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO video_performer (video_id, performer_id)
                VALUES (?, ?)
                """, arguments: [videoId.uuidString, credit.performerId])
            try db.execute(sql: """
                UPDATE video_performer
                   SET credited_as = COALESCE(?, credited_as),
                       billing     = COALESCE(?, billing),
                       source      = COALESCE(?, source),
                       recorded_at = ?
                 WHERE video_id = ? AND performer_id = ?
                """, arguments: [credit.creditedAs, credit.billing,
                                 credit.source?.rawValue, Date(),
                                 videoId.uuidString, credit.performerId])
        }
    }

    /// Stores accepted credits against a video's cast edges.
    ///
    /// ⚠️ Only for performers this library actually has. A credit naming
    /// someone with no profile would create an edge to a node that does not
    /// exist — `connectEdges` has the same rule, and for the same reason.
    ///
    /// Returns how many were written, because "the source knew a credited name"
    /// and "we kept it" are different claims.
    @discardableResult
    public func recordCredits(_ credits: [ProposedCredit], forVideo videoId: UUID,
                              source: EdgeProvenance = .download) throws -> Int {
        guard !credits.isEmpty else { return 0 }
        let resolver = NodeResolver(profiles: try fetchAllEntityProfiles())
        var written = 0
        for credit in credits {
            // ⭐ Resolved: a credit edge must point at the local node.
            guard let performerId = resolver.localId(for: "actor:\(credit.name)")
            else { continue }
            try recordPerformerCredit(
                PerformerCredit(performerId: performerId,
                                creditedAs: credit.creditedAs,
                                billing: credit.billing,
                                source: source),
                forVideo: videoId)
            written += 1
        }
        return written
    }

    /// Writes an edge the way the code did before v29 existed: no provenance.
    ///
    /// ⚠️ Internal and for tests only. There is deliberately no public path to
    /// an unstamped edge — every writer now records where it got it — but a
    /// migrated library is full of them, and the read path's handling of that
    /// is worth asserting rather than assuming.
    ///
    /// Lives here because `dbQueue` is private to this file and stays that way.
    func insertLegacyPerformerEdge(_ performerId: String, forVideo videoId: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO video_performer (video_id, performer_id) VALUES (?, ?)
                """, arguments: [videoId.uuidString, performerId])
        }
    }

    /// Every credit on a video, with whatever is known about each.
    ///
    /// Ordered by billing where the source stated it, then by id so the result
    /// is stable — a list that reorders between reads looks like data changing.
    public func performerCredits(forVideo videoId: UUID) throws -> [PerformerCredit] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT performer_id, credited_as, billing, source
                  FROM video_performer
                 WHERE video_id = ?
                 ORDER BY billing IS NULL, billing, performer_id
                """, arguments: [videoId.uuidString])
                .map { row in
                    PerformerCredit(
                        performerId: row["performer_id"],
                        creditedAs: row["credited_as"],
                        billing: row["billing"],
                        source: (row["source"] as String?).flatMap(EdgeProvenance.init(rawValue:)))
                }
        }
    }

    /// How many edges of one kind carry each provenance.
    ///
    /// The figure that makes phase 1 worth having: it says how much of the
    /// graph is asserted by a source and how much was derived from strings —
    /// a question nothing could answer before.
    public func edgeProvenanceCounts(_ kind: GraphEdgeKind) throws -> [String: Int] {
        try dbQueue.read { db in
            var counts: [String: Int] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT COALESCE(source, 'unknown') AS s, COUNT(*) AS n
                  FROM \(kind.rawValue) GROUP BY s
                """) {
                counts[row["s"]] = row["n"]
            }
            return counts
        }
    }

    public func performerIds(forVideo videoId: UUID) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT performer_id FROM video_performer WHERE video_id = ? ORDER BY performer_id
                """, arguments: [videoId.uuidString])
        }
    }

    public func studioId(forVideo videoId: UUID) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT studio_id FROM video_studio WHERE video_id = ?",
                                arguments: [videoId.uuidString])
        }
    }

    /// The whole `video_studio` edge in one read.
    ///
    /// The audit asks about every video, and doing that through
    /// `studioId(forVideo:)` is one query per video — 2,104 of them on the
    /// drive library, each taking the read lock. One table scan instead.
    public func studioIdsByVideo() throws -> [UUID: String] {
        try dbQueue.read { db in
            var result: [UUID: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT video_id, studio_id FROM video_studio") {
                guard let id = UUID(uuidString: row["video_id"]) else { continue }
                result[id] = row["studio_id"]
            }
            return result
        }
    }

    /// Everything wrong with this library's studios.
    ///
    /// Gathers what `StudioAudit` needs and hands it over. The reads are all
    /// whole-table on purpose: the audit's questions are about the library
    /// entire, and asking them per record is what made an earlier version of
    /// `promoteStudioProfiles` unusable with the external drive attached.
    public func auditStudios() throws -> [StudioCheck] {
        return StudioAudit.run(StudioAudit.Input(
            assets: try fetchAllAssets(),
            profiles: EntityProfileIndex(try fetchAllEntityProfiles()),
            studioIdByVideo: try studioIdsByVideo(),
            parentPairs: try studioParentPairs()))
    }

    /// Data that is wrong, found by joining records that disagree.
    ///
    /// Whole-table reads, like `auditStudios`: the questions are about the
    /// library entire, and asking them per record is what made an earlier
    /// version of `promoteStudioProfiles` unusable with the drive attached.
    public func auditGraph() throws -> [GraphCheck] {
        return GraphAudit.run(GraphAudit.Input(
            assets: try fetchAllAssets(),
            profiles: EntityProfileIndex(try fetchAllEntityProfiles())))
    }

    public func tagIds(forVideo videoId: UUID) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql:
                "SELECT tag_id FROM video_tag WHERE video_id = ? ORDER BY tag_id",
                arguments: [videoId.uuidString])
        }
    }

    /// Videos featuring a performer — one query, where it used to be a scan of
    /// every asset in the library with the names compared by hand.
    public func videoIds(forPerformer performerId: String) throws -> [UUID] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql:
                "SELECT video_id FROM video_performer WHERE performer_id = ?",
                arguments: [performerId])
        }.compactMap(UUID.init(uuidString:))
    }

    /// Videos per studio, keyed by node id, counted from the TAGS.
    ///
    /// ⚠️ Deliberately not from `video_studio`. These counts sit beside links
    /// that pivot the grid, and the grid filters on the `studio:` string — so
    /// counting edges would print a number the very next click contradicts.
    /// The edge is the better representation and the string is what is
    /// displayed; until writes move to the edge, the display must agree with
    /// itself.
    public func studioVideoCounts() throws -> [String: Int] {
        try dbQueue.read { db in
            var counts: [String: Int] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT j.value AS studio, COUNT(DISTINCT assets.id) AS n
                FROM assets, json_each(assets.tags) j
                WHERE j.value LIKE 'studio:_%'
                GROUP BY j.value
                """) {
                counts[row["studio"]] = row["n"]
            }
            return counts
        }
    }

    /// A studio's network, its sibling imprints and its own imprints.
    public func studioLineage(for studioId: String) throws -> StudioLineage {
        // ⭐ Two columns for the studios, not every profile in the library.
        let names = try entityNamesById(ofType: "studio")
        return StudioLineage.build(for: studioId,
                                   pairs: try studioParentPairs(),
                                   videoCounts: try studioVideoCounts(),
                                   names: names)
    }

    /// The imprints directly beneath a network — one level, not the whole tree.
    ///
    /// Lifted out of `studioIdWithDescendants` so a profile page can ask what a
    /// studio's children are without walking every generation under it. The
    /// page shows one level; the walk exists for filtering.
    public func childStudioIds(of studioId: String) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT studio_id FROM studio_parent
                WHERE parent_studio_id = ? AND valid_to IS NULL
                ORDER BY studio_id
                """, arguments: [studioId])
        }
    }

    /// The network a studio belongs to now, if one is recorded.
    public func parentStudioId(of studioId: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: """
                SELECT parent_studio_id FROM studio_parent
                 WHERE studio_id = ? AND valid_to IS NULL
                """, arguments: [studioId])
        }
    }

    /// Opens a second period without closing the first, the way an incautious
    /// second writer would.
    ///
    /// ⚠️ Internal and for tests only. It exists to prove the **database**
    /// refuses this, rather than the application remembering to — a rule
    /// enforced only in `setStudioParent` would be one merge path away from
    /// being broken.
    func insertOpenStudioParentForTesting(_ parentId: String,
                                          forStudio studioId: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO studio_parent (studio_id, parent_studio_id, valid_from, valid_to)
                VALUES (?, ?, NULL, NULL)
                """, arguments: [studioId, parentId])
        }
    }

    /// Every network this studio has belonged to, oldest first.
    ///
    /// What the temporal shape buys on a profile page: *"Part of X since 2015,
    /// previously Y"* is a fact about a company and was unrepresentable before.
    public func studioParentHistory(of studioId: String) throws -> [StudioParentPeriod] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT parent_studio_id, valid_from, valid_to FROM studio_parent
                 WHERE studio_id = ?
                 ORDER BY valid_from IS NULL DESC, valid_from
                """, arguments: [studioId])
                .map { StudioParentPeriod(parentId: $0["parent_studio_id"],
                                          from: $0["valid_from"], to: $0["valid_to"]) }
        }
    }

    /// Videos released by a studio — the studio counterpart of
    /// `videoIds(forPerformer:)`, which did not exist because `video_studio`
    /// was only ever queried in the video direction.
    public func videoIds(forStudio studioId: String) throws -> [UUID] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql:
                "SELECT video_id FROM video_studio WHERE studio_id = ?",
                arguments: [studioId])
        }.compactMap(UUID.init(uuidString:))
    }

    /// A studio and every studio beneath it, so a filter on a network finds the
    /// imprints that belong to it.
    ///
    /// - Parameter asOf: the day to resolve ownership on. `nil` means now.
    ///
    /// ⭐ The as-of form is what stops the family view being an anachronism: a
    /// 2012 release belongs to the network that owned its imprint in 2012, not
    /// to whoever bought it in 2018.
    public func studioIdWithDescendants(_ studioId: String,
                                        asOf: String? = nil) throws -> [String] {
        var found = [studioId]
        var frontier = [studioId]
        while !frontier.isEmpty {
            let placeholders = frontier.map { _ in "?" }.joined(separator: ",")
            let children: [String] = try dbQueue.read { db in
                if let asOf {
                    return try String.fetchAll(db, sql: """
                        SELECT studio_id FROM studio_parent
                        WHERE parent_studio_id IN (\(placeholders))
                          AND (valid_from IS NULL OR valid_from <= ?)
                          AND (valid_to   IS NULL OR valid_to   >  ?)
                        """, arguments: StatementArguments(frontier + [asOf, asOf]))
                }
                return try String.fetchAll(db, sql: """
                    SELECT studio_id FROM studio_parent
                    WHERE parent_studio_id IN (\(placeholders))
                      AND valid_to IS NULL
                    """, arguments: StatementArguments(frontier))
            }
            // A cycle cannot be created through setStudioParent, but a database
            // edited by hand is not bound by that — so the walk stops rather
            // than looping.
            frontier = children.filter { !found.contains($0) }
            found.append(contentsOf: frontier)
        }
        return found
    }

    /// Counts, for asserting a migration reproduced what the strings said.
    public func edgeCount(_ kind: GraphEdgeKind) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(kind.rawValue)") ?? 0
        }
    }

}
