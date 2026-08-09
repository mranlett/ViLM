// LibraryStore+Graph.swift
// The graph half of the store: turning strings into edges, reading across both
// representations while the migration runs, and the edge tables themselves.
//
// Split out of `LibraryStore.swift` on 2026-08-07, which had reached 2,769
// lines with roughly half of it this. Nothing changed in the move.
//
// ⚠️ Why these sections belong together rather than one-per-file: they share
// the invariant that a video's cast, studio and tags live partly in `tags`
// strings and partly in edge tables until the retirement step runs. Every read
// here must see BOTH halves, and splitting the writers from the readers would
// let one side drift from that rule without anything noticing.

import Foundation
import GRDB

extension LibraryStore {

    // MARK: - Connecting: strings to edges

    /// What connecting performers would do, counted before anything is written.
    public struct ConnectPlan: Equatable, Sendable {
        /// Credits found in the legacy strings.
        public let associations: Int
        /// Distinct names among them that have no profile row, and so cannot be
        /// pointed at. Reported rather than created: inventing a person from a
        /// string is exactly what the parser is forbidden to do.
        public let missingProfiles: [String]
        /// Edges that already exist and would not be duplicated.
        public let alreadyConnected: Int
        /// 🚨 Credits that CAN be connected and are not yet — counted by
        /// intersecting the wanted pairs with the existing ones.
        ///
        /// This used to be `associations - alreadyConnected`, subtracting a
        /// GLOBAL edge count from a TOTAL association count. Two different
        /// sets: the numerator included credits whose performer has no profile
        /// and so can never become an edge, and the subtrahend counted edges
        /// that had nothing to do with them.
        ///
        /// On a real library that reported **484** when the run created
        /// **3** — reported from the device, 2026-08-07.
        public let connectable: Int
        /// Credits skipped because the name has no profile. `associations`
        /// minus this is what could ever be connected.
        public let skippedNoProfile: Int
    }

    /// Builds `video_performer` edges from the `actor:` strings.
    ///
    /// ⚠️ ADDITIVE AND NON-DESTRUCTIVE. The strings are read, never written and
    /// never removed — they stay authoritative until a separate, gated step
    /// retires them. Running this changes what the graph CAN answer, not what
    /// it says.
    ///
    /// Idempotent: an existing edge is left alone, so a re-run after adding
    /// videos connects only the new ones.
    ///
    /// ⚠️ A credit naming someone with no profile row is SKIPPED and reported.
    /// Creating the profile here would mint a person from a string that a
    /// filename parse may well have guessed — the one thing the parser itself
    /// is not allowed to do, and it must not happen by a side door.
    @discardableResult
    public func connectPerformerEdges(dryRun: Bool = false) throws -> ConnectPlan {
        let assets = try fetchAllAssets()
        // ⭐ A cast NAME is the input and an entity id is the output, so this is
        // a resolution and not a membership test. Identical today; after the
        // re-key the resolver returns the local uid, which is the id the edge
        // must name.
        let resolver = NodeResolver(profiles: try fetchAllEntityProfiles())

        var associations = 0
        var missing = Set<String>()
        var wanted: [(UUID, String)] = []

        for asset in assets {
            // Set: a video crediting the same performer twice is one credit.
            for name in Set(asset.actors) where !name.isEmpty {
                associations += 1
                if let id = resolver.localId(for: "actor:\(name)") {
                    wanted.append((asset.id, id))
                } else {
                    missing.insert(name)
                }
            }
        }

        // The pairs, not the count — the count cannot say which of `wanted`
        // is already present, which is the only question worth asking.
        let existingPairs: Set<String> = try dbQueue.read { db in
            Set(try Row.fetchAll(db, sql: "SELECT video_id, performer_id FROM video_performer")
                .map { "\($0["video_id"] as String)|\($0["performer_id"] as String)" })
        }
        let existing = existingPairs.count
        let notYetConnected = wanted.filter {
            !existingPairs.contains("\($0.0.uuidString)|\($0.1)")
        }.count

        if !dryRun {
            try dbQueue.write { db in
                for (videoId, performerId) in wanted {
                    // ⚠️ `inferred`, not `filename` or `download`. This walks
                    // `asset.tags`, and those came from every route there is —
                    // claiming a specific origin would be inventing provenance
                    // rather than recording it.
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO video_performer
                            (video_id, performer_id, source, recorded_at)
                        VALUES (?, ?, ?, ?)
                        """, arguments: [videoId.uuidString, performerId,
                                         EdgeProvenance.inferred.rawValue, Date()])
                }
            }
        }

        return ConnectPlan(associations: associations,
                           missingProfiles: missing.sorted(),
                           alreadyConnected: existing,
                           connectable: notYetConnected,
                           skippedNoProfile: associations - wanted.count)
    }

    /// Whether the edges reproduce what the strings say, for every video.
    ///
    /// ⚠️ The gate on retiring the strings. Counting edges alone would pass a
    /// migration that connected the right NUMBER of things to the wrong videos,
    /// so this compares per video and returns the ones that disagree.
    public func performerEdgeDisagreements() throws -> [UUID] {
        let assets = try fetchAllAssets()
        // 🚨 Resolved, not intersected. `actual` holds edge endpoints — LOCAL
        // ids — so after the re-key an intersection against name-form strings
        // would come back empty and report every video in the library as
        // disagreeing, on the one check that gates retiring the strings.
        let resolver = NodeResolver(profiles: try fetchAllEntityProfiles())

        var disagreeing: [UUID] = []
        for asset in assets {
            // Only credits that COULD become edges are compared: a name with no
            // profile is a known, reported gap, not a disagreement.
            let expected = Set(asset.actors.compactMap { resolver.localId(for: "actor:\($0)") })
            let actual = Set(try performerIds(forVideo: asset.id))
            if expected != actual { disagreeing.append(asset.id) }
        }
        return disagreeing
    }

    /// What connecting studios would do, and what stands in the way.
    public struct StudioConnectPlan: Equatable, Sendable {
        public let associations: Int
        public let missingProfiles: [String]
        public let alreadyConnected: Int
        /// ⚠️ Videos carrying MORE THAN ONE studio. These cannot be connected:
        /// `video_studio` permits one per video, so the schema now refuses what
        /// the strings were happy to hold. They are skipped and listed.
        public let conflicted: [UUID]
        /// Studio links that CAN be connected and are not yet.
        ///
        /// 🚨 Same correction as `ConnectPlan.connectable` — see there. The
        /// old subtraction happened to look plausible for studios because
        /// almost every studio has a profile, and was badly wrong for
        /// performers where 190 names do not.
        public let connectable: Int
        /// Videos whose studio has no profile row.
        public let skippedNoProfile: Int

        public var isBlocked: Bool { !conflicted.isEmpty }
    }

    /// Builds `video_studio` edges from the `studio:` strings.
    ///
    /// ⚠️ THE CONFLICT AUDIT BECOMES A GATE HERE. A scene has one releasing
    /// studio, and the primary key says so — so a video the strings gave two
    /// cannot be represented at all. Those videos are skipped and reported
    /// rather than one studio being picked arbitrarily: choosing for the
    /// operator would silently discard a fact nobody checked.
    ///
    /// Everything else behaves as the performer step: additive, idempotent,
    /// strings untouched, unknown studios reported rather than invented.
    @discardableResult
    public func connectStudioEdges(dryRun: Bool = false) throws -> StudioConnectPlan {
        let assets = try fetchAllAssets()
        let resolver = NodeResolver(profiles: try fetchAllEntityProfiles())

        var associations = 0
        var missing = Set<String>()
        var conflicted: [UUID] = []
        var wanted: [(UUID, String)] = []

        for asset in assets {
            let studios = Set(asset.studios.filter { !$0.isEmpty })
            guard !studios.isEmpty else { continue }
            guard studios.count == 1, let name = studios.first else {
                conflicted.append(asset.id)
                continue
            }
            associations += 1
            if let id = resolver.localId(for: "studio:\(name)") {
                wanted.append((asset.id, id))
            } else {
                missing.insert(name)
            }
        }

        let existingPairs: Set<String> = try dbQueue.read { db in
            Set(try Row.fetchAll(db, sql: "SELECT video_id, studio_id FROM video_studio")
                .map { "\($0["video_id"] as String)|\($0["studio_id"] as String)" })
        }
        let existing = existingPairs.count
        let notYetConnected = wanted.filter {
            !existingPairs.contains("\($0.0.uuidString)|\($0.1)")
        }.count

        if !dryRun {
            try dbQueue.write { db in
                for (videoId, studioId) in wanted {
                    // Provenance, same as the performer path. v29 added these
                    // columns and only that one path filled them, so studio and
                    // tag edges were being created with NULL provenance —
                    // D7 says every value carries its source, and an edge kind
                    // that quietly does not is worse than none doing it.
                    try db.execute(sql: """
                        INSERT INTO video_studio
                            (video_id, studio_id, source, recorded_at) VALUES (?, ?, ?, ?)
                        ON CONFLICT(video_id) DO UPDATE SET
                            studio_id = excluded.studio_id,
                            source = excluded.source,
                            recorded_at = excluded.recorded_at
                        """, arguments: [videoId.uuidString, studioId,
                                         EdgeProvenance.inferred.rawValue, Date()])
                }
            }
        }

        return StudioConnectPlan(associations: associations,
                                 missingProfiles: missing.sorted(),
                                 alreadyConnected: existing,
                                 conflicted: conflicted,
                                 connectable: notYetConnected,
                                 skippedNoProfile: associations - wanted.count)
    }

    /// Videos whose studio edge disagrees with their strings.
    ///
    /// Videos carrying two studios are excluded: they are a known, reported
    /// blocker rather than a disagreement, and counting them here would mean
    /// verification could never pass while one existed.
    public func studioEdgeDisagreements() throws -> [UUID] {
        let assets = try fetchAllAssets()
        let resolver = NodeResolver(profiles: try fetchAllEntityProfiles())

        var disagreeing: [UUID] = []
        for asset in assets {
            let studios = Set(asset.studios.filter { !$0.isEmpty })
            guard studios.count == 1, let name = studios.first else { continue }
            let expected = resolver.localId(for: "studio:\(name)")
            if try studioId(forVideo: asset.id) != expected { disagreeing.append(asset.id) }
        }
        return disagreeing
    }

    /// What connecting tags would do, split by what each tag turned out to be.
    public struct TagConnectPlan: Equatable, Sendable {
        /// Video associations that became real edges — action or video-attribute.
        ///
        /// ⚠️ Every wanted association, not just the new ones. That is why this
        /// figure equals the `video_tag` table total on a re-run and looks like
        /// the whole library was reconnected. `newVideoEdges` is what the run
        /// actually added.
        public let videoEdges: Int
        /// Performer associations that became real edges.
        public let performerEdges: Int
        /// Of `videoEdges`, the ones that did not already exist.
        public let newVideoEdges: Int
        /// Of `performerEdges`, the ones that did not already exist.
        public let newPerformerEdges: Int
        /// Associations staged because nobody has said what the tag describes.
        public let pending: Int
        /// ⚠️ PERFORMER attributes found on VIDEOS. Not edges, and deliberately
        /// not staged either: the decision is that enrichment corrects these per
        /// performer as each video is matched, because an attribute read off a
        /// video is a guess about which of its cast it describes.
        ///
        /// 🚨 THE VIDEOS, not a count and not merely a per-tag total.
        ///
        /// This was an `Int`, then `[String: Int]` — and the second fix stopped
        /// one level short. The screen could say "Redhead — 11 videos" but the
        /// only thing it could link to was the tag, and the tag page shows every
        /// video whose CAST carries that trait as well. So an operator chasing
        /// 11 videos was handed several hundred to scroll through.
        ///
        /// Keyed by tag, valued by the video ids that actually carry it. Now the
        /// screen can offer exactly those eleven.
        public let attributeTagsOnVideos: [String: [UUID]]

        /// Total associations, which is what the count used to be.
        public var attributeTagAssociations: Int {
            attributeTagsOnVideos.values.reduce(0) { $0 + $1.count }
        }
        /// Tags used by a video but absent from the vocabulary. Promotion should
        /// be run first; reported rather than created so the two steps stay
        /// separately checkable.
        public let unknownTags: [String]
    }

    /// Builds `video_tag` and `performer_tag` edges from the tag strings.
    ///
    /// ⚠️ The kind decides the destination, and there are four outcomes rather
    /// than two:
    ///
    /// | tag kind on a VIDEO | result |
    /// | --- | --- |
    /// | action, video-attribute | a `video_tag` edge |
    /// | performer-attribute | **nothing** — left for enrichment to correct |
    /// | unclassified | a pending association, so the link survives |
    /// | unknown to the vocabulary | reported |
    ///
    /// Additive, idempotent, and the strings are untouched.
    @discardableResult
    public func connectTagEdges(dryRun: Bool = false,
                                available: [TagKind] = TagKind.seed) throws -> TagConnectPlan {
        let assets = try fetchAllAssets()
        let profiles = try fetchAllEntityProfiles()
        let vocabulary = Dictionary(
            try fetchTagVocabulary().map { ($0.identityKey, $0) }, uniquingKeysWith: { a, _ in a })

        var videoEdges: [(UUID, String)] = []
        var performerEdges: [(String, String)] = []
        var pending: [(UUID, String)] = []
        var attributeOnVideo: [String: [UUID]] = [:]
        var unknown = Set<String>()

        for asset in assets {
            for name in Set(asset.actions) where !name.isEmpty {
                let key = TagNormalizer.identityKey(name)
                guard let record = vocabulary[key] else { unknown.insert(name); continue }
                guard let kind = record.resolvedKind(from: available) else {
                    pending.append((asset.id, key)); continue
                }
                if kind.canAttach(to: .video) {
                    videoEdges.append((asset.id, key))
                } else {
                    // A performer attribute sitting on a video. Left alone,
                    // but RECORDED by tag so the operator can find them —
                    // `record.displayName` rather than the folded key, because
                    // the key is not what any screen shows.
                    attributeOnVideo[record.displayName, default: []].append(asset.id)
                }
            }
        }

        for profile in profiles where profile.id.hasPrefix("actor:") {
            for name in Set(profile.tags) where !name.isEmpty {
                let key = TagNormalizer.identityKey(name)
                guard let record = vocabulary[key] else { unknown.insert(name); continue }
                guard let kind = record.resolvedKind(from: available) else { continue }
                if kind.canAttach(to: .performer) { performerEdges.append((profile.id, key)) }
            }
        }

        // Counted BEFORE the write, by intersection — after it, everything
        // looks already-connected and the run appears to have done nothing.
        let existingVideoTags: Set<String> = try dbQueue.read { db in
            Set(try Row.fetchAll(db, sql: "SELECT video_id, tag_id FROM video_tag")
                .map { "\($0["video_id"] as String)|\($0["tag_id"] as String)" })
        }
        let existingPerformerTags: Set<String> = try dbQueue.read { db in
            Set(try Row.fetchAll(db, sql: "SELECT performer_id, tag_id FROM performer_tag")
                .map { "\($0["performer_id"] as String)|\($0["tag_id"] as String)" })
        }
        let newVideoEdges = videoEdges.filter {
            !existingVideoTags.contains("\($0.0.uuidString)|\($0.1)")
        }.count
        let newPerformerEdges = performerEdges.filter {
            !existingPerformerTags.contains("\($0.0)|\($0.1)")
        }.count

        if !dryRun {
            try dbQueue.write { db in
                for (videoId, tagId) in videoEdges {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO video_tag
                            (video_id, tag_id, source, recorded_at) VALUES (?, ?, ?, ?)
                        """, arguments: [videoId.uuidString, tagId,
                                         EdgeProvenance.inferred.rawValue, Date()])
                }
                for (performerId, tagId) in performerEdges {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO performer_tag
                            (performer_id, tag_id, source, recorded_at) VALUES (?, ?, ?, ?)
                        """, arguments: [performerId, tagId,
                                         EdgeProvenance.inferred.rawValue, Date()])
                }
                for (videoId, tagId) in pending {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO pending_tag_association (video_id, tag_id)
                        VALUES (?, ?)
                        """, arguments: [videoId.uuidString, tagId])
                }
            }
        }

        return TagConnectPlan(videoEdges: videoEdges.count,
                              performerEdges: performerEdges.count,
                              newVideoEdges: newVideoEdges,
                              newPerformerEdges: newPerformerEdges,
                              pending: pending.count,
                              attributeTagsOnVideos: attributeOnVideo,
                              unknownTags: unknown.sorted())
    }

    /// Turns a tag's staged associations into edges, now that it has a kind.
    ///
    /// The other half of `pending_tag_association`: a parser finding that was
    /// held rather than lost is redeemed here. An association whose kind turns
    /// out to describe the other node type is DISCARDED and counted — that is
    /// the attribute-on-a-video case, and inventing an edge for it is exactly
    /// what the taxonomy exists to stop.
    ///
    /// - Returns: how many became edges, and how many were dropped.
    @discardableResult
    public func resolvePendingAssociations(forTag tagId: String,
                                           available: [TagKind] = TagKind.seed)
    throws -> (materialised: Int, discarded: Int) {
        let record = try fetchTagVocabulary().first { $0.identityKey == tagId }
        guard let kind = record?.resolvedKind(from: available) else { return (0, 0) }

        let videoIds: [String] = try dbQueue.read { db in
            try String.fetchAll(db, sql:
                "SELECT video_id FROM pending_tag_association WHERE tag_id = ?", arguments: [tagId])
        }
        guard !videoIds.isEmpty else { return (0, 0) }

        let becomesEdge = kind.canAttach(to: .video)
        try dbQueue.write { db in
            if becomesEdge {
                for videoId in videoIds {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO video_tag (video_id, tag_id) VALUES (?, ?)
                        """, arguments: [videoId, tagId])
                }
            }
            try db.execute(sql: "DELETE FROM pending_tag_association WHERE tag_id = ?",
                           arguments: [tagId])
        }
        return becomesEdge ? (videoIds.count, 0) : (0, videoIds.count)
    }

    // MARK: - Tags arriving on people

    /// Registers and connects the tags carried by actor profiles.
    ///
    /// ⚠️ A tag arriving ON A PERSON is known to describe a person — that is
    /// what the file it came from means. So an unknown one is created as a
    /// performer attribute rather than left unclassified, which is the one
    /// place the taxonomy can be inferred instead of asked about.
    ///
    /// Built for the CSV round-trip, which saved profiles and stopped: the tags
    /// landed as bare strings with no vocabulary record and no edge, so an
    /// enriched file made the graph no better than before it ran.
    ///
    /// Never reclassifies. A tag already known as something else keeps its
    /// kind, and simply gets no edge here — the arriving file does not outrank
    /// a decision already made.
    @discardableResult
    public func connectPerformerTags(for profileIds: [String],
                                     available: [TagKind] = TagKind.seed) throws
    -> (created: Int, linked: Int) {
        var created = 0, linked = 0
        var vocabulary = try fetchTagVocabulary()

        for id in profileIds where id.hasPrefix("actor:") {
            guard let profile = try fetchEntityProfile(for: id) else { continue }
            for raw in Set(profile.tags) where !raw.trimmingCharacters(in: .whitespaces).isEmpty {
                let key = TagNormalizer.identityKey(raw)
                var record = vocabulary.first { $0.identityKey == key }

                if record == nil {
                    let new = TagRecord(displayName: raw, kind: .performerAttribute)
                    try saveTagRecord(new)
                    vocabulary.append(new)
                    record = new
                    created += 1
                }

                guard let kind = record?.resolvedKind(from: available),
                      kind.canAttach(to: .performer) else { continue }
                try linkTag(key, toPerformer: id)
                linked += 1
            }
        }
        return (created, linked)
    }

    // MARK: - The edges that travel between libraries

    /// Performer traits, as portable pairs. Names no video, so it means the
    /// same thing in any library — see `GraphSync`.
    public func performerTagPairs() throws -> [GraphEdgePair] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT performer_id, tag_id FROM performer_tag")
                .map { GraphEdgePair(from: $0["performer_id"], to: $0["tag_id"]) }
        }
    }

    /// Which network owns which imprint, **as things stand now**.
    ///
    /// ⚠️ Current rows only. Every existing caller means "now", so "now" is the
    /// default and no call site changed when the table became temporal. A
    /// retired 2009 hierarchy must not be reported as a dangling parent
    /// forever, which is what including closed rows would do.
    public func studioParentPairs() throws -> [GraphEdgePair] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT studio_id, parent_studio_id FROM studio_parent
                 WHERE valid_to IS NULL
                """)
                .map { GraphEdgePair(from: $0["studio_id"], to: $0["parent_studio_id"]) }
        }
    }

    /// The hierarchy as it stood on a given day.
    ///
    /// ⚠️ A row with `valid_from = NULL` matches ANY date at or before its
    /// `valid_to`. NULL means "as far back as we know", not "never" — and since
    /// every row migrated by v30 carries NULL, reading it as "no match" would
    /// make the entire existing hierarchy vanish from as-of queries the day
    /// this shipped.
    public func studioParentPairs(asOf day: String) throws -> [GraphEdgePair] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT studio_id, parent_studio_id FROM studio_parent
                 WHERE (valid_from IS NULL OR valid_from <= ?)
                   AND (valid_to   IS NULL OR valid_to   >  ?)
                """, arguments: [day, day])
                .map { GraphEdgePair(from: $0["studio_id"], to: $0["parent_studio_id"]) }
        }
    }

    /// The hierarchy WITH its dates and its history — what a sync carries.
    ///
    /// ⚠️ Every period, not just the open one. `studioParentPairs()` answers
    /// "who owns this now", which is right for every reader inside this library
    /// and wrong for an export: a former ownership the operator recorded by hand
    /// is the scarcest fact in the graph, and dropping it means it can never
    /// reach the other library.
    public func studioParentEdges() throws -> [StudioParentEdge] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT studio_id, parent_studio_id, valid_from, valid_to
                  FROM studio_parent
                 ORDER BY studio_id, valid_from IS NULL DESC, valid_from
                """)
                .map { StudioParentEdge(from: $0["studio_id"], to: $0["parent_studio_id"],
                                        validFrom: $0["valid_from"], validTo: $0["valid_to"]) }
        }
    }

    /// Gives the CURRENT ownership a start date it did not have.
    ///
    /// ⚠️ Only ever fills a gap. Refuses when a start is already recorded — a
    /// date this library holds is an answer, and replacing it would be the same
    /// silent overrule the merge exists to avoid.
    @discardableResult
    public func setStudioParentStart(_ from: String, forStudio studioId: String) throws -> Bool {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE studio_parent SET valid_from = ?
                 WHERE studio_id = ? AND valid_to IS NULL AND valid_from IS NULL
                """, arguments: [from, studioId])
            return db.changesCount > 0
        }
    }

    /// Records a FORMER ownership — a period that has already ended.
    ///
    /// ⚠️ Closed periods only. An open period is `setStudioParent`'s business,
    /// because it has to close whatever it replaces; this one adds history
    /// beside the current row and touches nothing else.
    ///
    /// ⭐ No cycle check, deliberately. The walk in `setStudioParent` follows
    /// **current** rows, and a period that has ended cannot put a studio inside
    /// its own present hierarchy.
    public func addStudioParentPeriod(_ parentId: String, forStudio studioId: String,
                                      from: String?, to: String,
                                      source: EdgeProvenance = .download) throws {
        guard studioId != parentId else { throw GraphEdgeError.cycle(path: [studioId]) }
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO studio_parent
                    (studio_id, parent_studio_id, valid_from, valid_to, source, recorded_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [studioId, parentId, from, to, source.rawValue, Date()])
        }
    }

    /// The day part of a date, as the hierarchy stores it.
    static func isoDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: - Connecting one video

    /// Builds the edges for a SINGLE video from its own strings.
    ///
    /// Same routing as the bulk connect — a credit with no profile is skipped,
    /// two studios cannot be represented, a tag goes where its kind says — but
    /// scoped to one record so a video arriving from elsewhere can be wired in
    /// without re-scanning the library.
    ///
    /// ⚠️ Exists because a moved video is created under a NEW id in the
    /// destination. Edges point at ids, so none of the source's edges can
    /// follow it, and without this the video would sit in its new library with
    /// its text intact and no place in the graph until someone happened to run
    /// a full connect.
    @discardableResult
    public func connectEdges(forVideo videoId: UUID,
                             available: [TagKind] = TagKind.seed) throws -> Int {
        guard let asset = try fetchAllAssets().first(where: { $0.id == videoId }) else { return 0 }
        // 🚨 The id WRITTEN is the resolved one, not the name-form string that
        // found it. This is the federation invariant applied locally: a moved
        // video is rebuilt in a library that may already be re-keyed, and
        // writing `"actor:\(name)"` there would point the edge at nothing.
        let resolver = NodeResolver(profiles: try fetchAllEntityProfiles())
        let vocabulary = try fetchTagVocabulary()
        var written = 0

        for name in Set(asset.actors) {
            guard let performerId = resolver.localId(for: "actor:\(name)") else { continue }
            try linkPerformer(performerId, toVideo: videoId)
            written += 1
        }

        // One studio only. Two is the conflict the schema refuses, and picking
        // one here would make a move quietly resolve something the dedicated
        // screen exists to put in front of a person.
        let studios = Set(asset.studios.filter { !$0.isEmpty })
        if studios.count == 1, let name = studios.first,
           let studioId = resolver.localId(for: "studio:\(name)") {
            try setStudio(studioId, forVideo: videoId)
            written += 1
        }

        for raw in Set(asset.actions) {
            let key = TagNormalizer.identityKey(raw)
            guard let record = vocabulary.first(where: { $0.identityKey == key }) else { continue }
            guard let kind = record.resolvedKind(from: available) else {
                // Held rather than dropped, exactly as the bulk connect does.
                try addPendingTagAssociation(key, forVideo: videoId)
                continue
            }
            // A trait describing a person is left alone: which of the cast it
            // refers to is a guess, and a move must not be where that guess
            // gets made.
            guard kind.canAttach(to: .video) else { continue }
            try linkTag(key, toVideo: videoId)
            written += 1
        }
        return written
    }

    // MARK: - Reading across both representations
    //
    // ⚠️ Between connecting and retiring, a video's cast lives partly in edges
    // and partly in the legacy strings. Reads must not see either half alone,
    // or the same library answers differently depending on how far the
    // migration has run — and browse, filter and counts would shift under the
    // operator while nothing they did caused it.
    //
    // The union is what lets step 5 retire a string WITHOUT changing an answer:
    // the edge already says the same thing, so removing the string is invisible.
    // That property is the gate, and it is what these exist to make testable.

    /// A video's performers, from edges and strings together.
    public func resolvedPerformerIds(forVideo videoId: UUID, in asset: Asset? = nil)
    throws -> Set<String> {
        let fromEdges = Set(try performerIds(forVideo: videoId))
        let source = try asset ?? fetchAllAssets().first { $0.id == videoId }
        // 🚨 Both halves must be in the SAME namespace or the union stops being
        // a union. `fromEdges` holds local ids; after the re-key a name-form
        // string is a different key for the same person, so the set would hold
        // both and every performer would be counted twice — silently, on the
        // read that step 5 relies on to prove retiring a string changes nothing.
        //
        // ⚠️ A name with no profile resolves to nothing and is dropped, which
        // matches the edge side: there is no node to name.
        let resolver = NodeResolver(profiles: try fetchAllEntityProfiles())
        let fromStrings = Set((source?.actors ?? [])
            .compactMap { resolver.localId(for: "actor:\($0)") })
        return fromEdges.union(fromStrings)
    }

    /// A video's releasing studio.
    ///
    /// The EDGE wins where one exists: it is the representation the schema
    /// constrains, and a video the strings gave two studios has no edge at all
    /// — so falling back to the strings there would hand back an arbitrary one
    /// of the two, which is the choice this migration refuses to make.
    public func resolvedStudioId(forVideo videoId: UUID, in asset: Asset? = nil)
    throws -> String? {
        if let edge = try studioId(forVideo: videoId) { return edge }
        let source = try asset ?? fetchAllAssets().first { $0.id == videoId }
        let studios = Set((source?.studios ?? []).filter { !$0.isEmpty })
        guard studios.count == 1, let name = studios.first else { return nil }
        // ⚠️ Resolved, because the edge branch above returns a LOCAL id and a
        // caller cannot be asked to know which branch answered.
        return try NodeResolver(profiles: fetchAllEntityProfiles())
            .localId(for: "studio:\(name)")
    }

    /// A video's tags, folded so two spellings of one tag answer once.
    ///
    /// ⚠️ Deliberately does NOT include pending associations. A staged tag is
    /// not attached to anything yet — that is the whole point of staging it —
    /// and surfacing it here would put an unclassified tag back on the video by
    /// a different route.
    public func resolvedTagIds(forVideo videoId: UUID, in asset: Asset? = nil)
    throws -> Set<String> {
        let fromEdges = Set(try tagIds(forVideo: videoId))
        let source = try asset ?? fetchAllAssets().first { $0.id == videoId }
        let fromStrings = Set((source?.actions ?? []).map(TagNormalizer.identityKey))
        return fromEdges.union(fromStrings)
    }

    // MARK: - Retiring the strings

    /// Whether a tag's strings can be dropped: every video that carries it in a
    /// string also carries it as an edge.
    ///
    /// ⚠️ Scoped PER TAG. Gating the whole cleanup on "every tag is classified"
    /// would let one stubborn tag freeze the legacy representation for the
    /// entire library indefinitely; per tag, the migration makes progress the
    /// whole way there.
    ///
    /// A tag classified as describing a PERFORMER is never retirable from
    /// videos: its associations were deliberately not turned into edges, and
    /// dropping the strings would destroy the record that enrichment still has
    /// work to do.
    public func canRetireStrings(forTag tagId: String,
                                 available: [TagKind] = TagKind.seed) throws -> Bool {
        guard let record = try fetchTagVocabulary().first(where: { $0.identityKey == tagId }),
              let kind = record.resolvedKind(from: available),
              kind.canAttach(to: .video)
        else { return false }

        let pending = try dbQueue.read { db in
            try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM pending_tag_association WHERE tag_id = ?",
                arguments: [tagId]) ?? 0
        }
        guard pending == 0 else { return false }

        let edged = Set(try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT video_id FROM video_tag WHERE tag_id = ?",
                                arguments: [tagId])
        })
        for asset in try fetchAllAssets() {
            let carriesString = asset.actions.contains { TagNormalizer.identityKey($0) == tagId }
            if carriesString && !edged.contains(asset.id.uuidString) { return false }
        }
        return true
    }

    // MARK: - Resetting match status

    /// What a reset would affect, counted before anything is written.
    ///
    /// Separate from performing it because this is destructive over the whole
    /// library, and a number you can read beforehand is the difference between
    /// a decision and a surprise.
    public struct MatchResetPlan: Equatable, Sendable {
        /// Videos the source matched. Re-deriving these costs a re-run.
        public let matched: Int
        /// Videos a PERSON ruled out. Re-deriving these is impossible —
        /// nothing but the operator knows they looked.
        public let ruledOut: Int
        /// Searched but unresolved: no match, ambiguous, needs review.
        public let unresolved: Int

        public var clearable: Int { matched + unresolved }
        public var total: Int { matched + ruledOut + unresolved }
    }

    public func planMatchReset() throws -> MatchResetPlan {
        try dbQueue.read { db in
            func count(_ clause: String) throws -> Int {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assets WHERE \(clause)") ?? 0
            }
            return MatchResetPlan(
                matched: try count("enrichment_state = 'matched'"),
                ruledOut: try count("enrichment_state = 'unmatchable'"),
                unresolved: try count("""
                    enrichment_state IS NOT NULL
                    AND enrichment_state NOT IN ('matched', 'unmatchable')
                    """))
        }
    }

    /// Clears the record of having been matched, so videos return to the queue.
    ///
    /// ⚠️ Clears ONLY the match bookkeeping — state, source, source id, link and
    /// timestamp. Every value a match ever wrote is left exactly as it is:
    /// release date, cast, studio, title, tags. Those are the library's
    /// records, not the match's, and re-deriving them is what the re-run is
    /// for. A reset that emptied them would be a data loss dressed as a retry.
    ///
    /// ⚠️ `includingRuledOut` defaults to FALSE, and should stay false unless
    /// there is a reason. `unmatchable` means a person looked and concluded the
    /// source has no record — the one state a machine never assigns. Clearing
    /// it returns those videos to a queue they were deliberately removed from,
    /// and nothing can re-derive the judgement.
    ///
    /// Written in SQL rather than by loading every asset: this runs over the
    /// whole library, and decoding two thousand records to null five columns is
    /// a cost with nothing to show for it.
    ///
    /// - Returns: how many rows were cleared.
    @discardableResult
    public func resetMatchStatus(includingRuledOut: Bool = false) throws -> Int {
        try dbQueue.write { db in
            let keepRuledOut = includingRuledOut
                ? ""
                : "AND enrichment_state IS NOT 'unmatchable'"
            try db.execute(sql: """
                UPDATE assets SET
                    enrichment_state = NULL,
                    enrichment_source = NULL,
                    enrichment_source_id = NULL,
                    enrichment_url = NULL,
                    enrichment_checked_at = NULL
                WHERE enrichment_state IS NOT NULL \(keepRuledOut)
                """)
            return db.changesCount
        }
    }

}

// MARK: - Stale edges
//
// 🚨 The gap that made the verification unactionable. Connecting is
// additive-only — `INSERT OR IGNORE`, never a delete — and every path that
// writes `video_performer` or `video_studio` derives it from the video's tag
// strings. So the strings are the SOURCE and the edges are DERIVED.
//
// A derived set that can only grow is the defect. When a cast changes — a
// re-match replaces performers, or the operator edits the cast and re-fetches
// it — the old edge stays and nothing removes it. `performerEdgeDisagreements`
// then reports a difference forever, and re-running Connect the Graph cannot
// close it because connecting is exactly the operation that does not delete.
//
// ⚠️ Reported from the device 2026-08-08, and the operator's own remediation
// made it worse: deleting the cast and re-downloading it added the new edges
// and left the old, taking the count from one video to two.

public extension LibraryStore {

    /// One edge that no tag string on its video supports.
    struct StaleEdge: Equatable, Sendable, Identifiable {
        public let videoId: UUID
        public let fileName: String
        /// `actor:Name` or `studio:Name`.
        public let nodeId: String
        /// ⚠️ Whether the video still names ANY node of this kind.
        ///
        /// 🚨 The distinction that decides whether removing is safe. An edge on
        /// a video that names five other performers is genuinely stale — the
        /// cast changed and this one was left behind. An edge on a video that
        /// names NONE is a different situation: the strings may be missing
        /// rather than the edge wrong, and deleting on that basis would destroy
        /// the only remaining record of who is in it.
        public let videoNamesOthers: Bool

        public var id: String { "\(videoId.uuidString)|\(nodeId)" }

        public var displayName: String {
            guard let colon = nodeId.firstIndex(of: ":") else { return nodeId }
            return String(nodeId[nodeId.index(after: colon)...])
        }

        public init(videoId: UUID, fileName: String, nodeId: String,
                    videoNamesOthers: Bool) {
            self.videoId = videoId
            self.fileName = fileName
            self.nodeId = nodeId
            self.videoNamesOthers = videoNamesOthers
        }
    }

    /// Edges whose video no longer names them.
    ///
    /// Compared against the video's OWN strings, exactly as
    /// `performerEdgeDisagreements` does, so the two can never report
    /// different things about the same video.
    func staleEdges() throws -> [StaleEdge] {
        let assets = try fetchAllAssets()
        // 🚨 The names are resolved to local ids before being compared against
        // edge endpoints. Comparing the two namespaces raw would, after the
        // re-key, report EVERY edge in the library as stale — and this screen
        // offers to delete what it reports.
        let resolver = NodeResolver(profiles: try fetchAllEntityProfiles())
        var found: [StaleEdge] = []

        for asset in assets {
            let namedPerformers = Set(asset.actors.compactMap {
                resolver.localId(for: "actor:\($0)")
            })
            for edge in try performerIds(forVideo: asset.id)
            where !namedPerformers.contains(edge) {
                found.append(StaleEdge(videoId: asset.id, fileName: asset.fileName,
                                       nodeId: edge,
                                       videoNamesOthers: !namedPerformers.isEmpty))
            }

            let namedStudios = Set(asset.studios.filter { !$0.isEmpty }.compactMap {
                resolver.localId(for: "studio:\($0)")
            })
            if let edge = try studioId(forVideo: asset.id), !namedStudios.contains(edge) {
                found.append(StaleEdge(videoId: asset.id, fileName: asset.fileName,
                                       nodeId: edge,
                                       videoNamesOthers: !namedStudios.isEmpty))
            }
        }
        return found.sorted { $0.id < $1.id }
    }

    /// Removes exactly the edges given.
    ///
    /// ⭐ Takes the edges rather than re-deriving them, so what is removed is
    /// what the operator was shown. A second scan could legitimately return a
    /// different set — the library changes — and "I approved a list and
    /// something else was deleted" is not a defensible outcome for a
    /// destructive action.
    ///
    /// ⚠️ THE ONLY code in this file that deletes an edge. Everything else is
    /// `INSERT OR IGNORE`, and that asymmetry was the bug.
    @discardableResult
    func pruneStaleEdges(_ edges: [StaleEdge]) throws -> Int {
        guard !edges.isEmpty else { return 0 }
        return try dbQueue.write { db in
            var removed = 0
            for edge in edges {
                let table = edge.nodeId.hasPrefix("studio:") ? "video_studio" : "video_performer"
                let column = table == "video_studio" ? "studio_id" : "performer_id"
                try db.execute(
                    sql: "DELETE FROM \(table) WHERE video_id = ? AND \(column) = ?",
                    arguments: [edge.videoId.uuidString, edge.nodeId])
                removed += db.changesCount
            }
            return removed
        }
    }
}
