// GraphSync.swift
// Carries the graph — minus the videos — between libraries.
//
// Actors already travelled. What did not were the studios, the tag vocabulary,
// and the two edge kinds that name no video: a performer's traits, and which
// network owns which imprint. Those are facts about the WORLD rather than about
// one library's files, so every library should be able to hold them.
//
// ⚠️ Videos and their edges never travel. A video lives in one library and its
// id is local to it, so `video_performer`, `video_studio` and `video_tag` would
// point at nothing on the other side. Moving a video is a separate operation
// that rebuilds those edges from the video's own text — see
// `connectEdges(forVideo:)`.
//
// Additive, like the actor merge it extends: this fills gaps and adds edges.
// It never removes a studio, a tag or an edge the receiving library has, so a
// sync cannot be a way to lose work done on the other side.

import Foundation

/// One edge, as two ids. Enough for both kinds carried here, and portable
/// because neither id names a video.
public struct GraphEdgePair: Codable, Sendable, Equatable, Hashable {
    public let from: String
    public let to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

/// One period of studio ownership, as it travels.
///
/// ⭐ Why this is not a `GraphEdgePair`. The hierarchy is the one portable edge
/// with real **valid time** — an imprint is founded, acquired and retired on
/// actual dates — and a pair cannot carry them, so before this type the dates
/// stayed home and every received hierarchy arrived undated.
///
/// ⚠️ Decodes older exports unchanged. An entry written as `{from, to}` reads
/// back with both dates nil, which is exactly what an un-upgraded library means:
/// **unknown**, never "always". Newer exports likewise decode in older builds,
/// which ignore the two extra keys.
public struct StudioParentEdge: Codable, Sendable, Equatable, Hashable {
    public let from: String
    public let to: String
    /// nil = "as far back as we know".
    public let validFrom: String?
    /// nil = still current. At most one such period per studio.
    public let validTo: String?

    public var isCurrent: Bool { validTo == nil }

    public init(from: String, to: String, validFrom: String? = nil, validTo: String? = nil) {
        self.from = from
        self.to = to
        self.validFrom = validFrom
        self.validTo = validTo
    }
}

/// A fact the two libraries disagree about.
///
/// ⚠️ Reported rather than resolved. The merge is additive by design — it fills
/// gaps and never overwrites a decision the receiving library already made — so
/// a disagreement leaves BOTH sides exactly as they were. That is safe, but
/// silent, and a library quietly holding two answers to the same question is
/// worse than one that says so.
public struct GraphDisagreement: Sendable, Equatable, Identifiable {
    public enum Subject: String, Sendable, Equatable {
        /// The same tag classified differently on each side.
        case tagKind
        /// The same studio confirmed against different sources.
        case studioSource
        /// 🚨 The same imprint placed under a DIFFERENT network by each side.
        ///
        /// The graphs disagree about who owns a company, which changes what
        /// every family view and as-of query returns — a divergence in shape,
        /// not merely in content, exactly like `tagKind`.
        case studioParent
        /// The same ownership, dated differently — or two ownerships each
        /// claiming the same stretch of time.
        ///
        /// ⚠️ Distinct from `studioParent`: the two sides agree on WHO owns the
        /// imprint and disagree on WHEN. Writing both would give one studio two
        /// parents on the same date, which is the invariant the temporal shape
        /// exists to hold.
        case studioParentDate
        /// 🚨 The same node identified as DIFFERENT records in one source.
        ///
        /// The most consequential disagreement there is: the two libraries do
        /// not merely describe this node differently, they believe it is a
        /// different person or company. Everything downstream — the
        /// filmography, the enrichment, any future refresh — follows from which
        /// is right, and nothing here can tell.
        case nodeIdentity
    }

    public let subject: Subject
    /// The thing being disagreed about — a tag's identity key, a studio's id.
    public let name: String
    /// What this library holds.
    public let mine: String
    /// What the arriving export holds.
    public let theirs: String

    public var id: String { "\(subject.rawValue):\(name)" }

    public init(subject: Subject, name: String, mine: String, theirs: String) {
        self.subject = subject
        self.name = name
        self.mine = mine
        self.theirs = theirs
    }
}

/// What a sync did, counted so the operator can see it landed.
public struct GraphMergeResult: Sendable, Equatable {
    public let actors: ActorMergeCounts
    public let newStudios: Int
    public let updatedStudios: Int
    public let newTags: Int
    public let classifiedTags: Int
    public let newPerformerTags: Int
    public let newStudioParents: Int
    /// Hierarchy this library already agreed with, which gained a START DATE
    /// from the sender. Counted apart from `newStudioParents` because no new
    /// ownership was learned — an undated fact became a dated one.
    public let datedStudioParents: Int
    /// FORMER ownerships the sender knew about and this library did not.
    public let newStudioParentPeriods: Int
    /// External identities learned from the other library.
    public let newMatches: Int
    /// Hierarchy edges refused because taking them would have made a loop.
    public let refusedCycles: Int
    /// ⚠️ Facts the two libraries answer differently. Nothing was changed for
    /// these — they are here so the operator learns the disagreement exists.
    public let disagreements: [GraphDisagreement]

    public struct ActorMergeCounts: Sendable, Equatable {
        public let new: Int
        public let updated: Int
        public let photos: Int
        public init(new: Int, updated: Int, photos: Int) {
            self.new = new; self.updated = updated; self.photos = photos
        }
    }

    public var changedAnything: Bool {
        actors.new + actors.updated + actors.photos + newStudios + updatedStudios
            + newTags + classifiedTags + newPerformerTags + newStudioParents
            + datedStudioParents + newStudioParentPeriods + newMatches > 0
    }
}

extension LibraryStore {

    // MARK: - Export
    //
    // The two edge readers this needs live in LibraryStore.swift, where the
    // connection is — kept private rather than widened for one caller's
    // convenience.

    /// The actor library plus the rest of the portable graph.
    ///
    /// ⚠️ `onlyActorIds` narrows the ACTORS only. The studios, tags and edges
    /// always travel whole: they are library-wide facts, not per-actor ones,
    /// and the live sync applies actors in batches — so scoping them to a batch
    /// would mean each batch carried a different slice of the vocabulary and
    /// none carried all of it.
    public func exportGraph(onlyActorIds: Set<String>? = nil,
                            includingPhotoData: Bool = true) throws -> ActorLibraryExport {
        var export = try exportActorLibrary(onlyActorIds: onlyActorIds,
                                            includingPhotoData: includingPhotoData)
        export.studios = try fetchAllEntityProfiles().filter { $0.id.hasPrefix("studio:") }
        export.tags = try fetchTagVocabulary()
        export.performerTags = try performerTagPairs()
        export.studioParents = try studioParentEdges()
        // ⚠️ Entity matches only. A video match names a video id, which is
        // local to the library holding the file.
        export.entityMatches = try allEntityMatches()
        return export
    }

    // MARK: - Merge

    /// Applies everything an export carries, additively.
    public func applyGraphMerge(_ export: ActorLibraryExport) throws -> GraphMergeResult {
        let actors = try applyActorMerge(export)

        // Studios. A profile already here is left alone — it has been enriched
        // in THIS library, and the arriving copy is not automatically better.
        // Only genuinely absent studios are written, plus one narrow upgrade:
        // an unconfirmed studio learning that it IS confirmed elsewhere, since
        // that is knowledge rather than a competing opinion.
        var newStudios = 0, updatedStudios = 0
        var disagreements: [GraphDisagreement] = []
        for incoming in export.studios {
            guard let existing = try fetchEntityProfile(for: incoming.id) else {
                try saveEntityProfile(incoming)
                newStudios += 1
                continue
            }
            if existing.enrichmentState != .matched, incoming.enrichmentState == .matched {
                var upgraded = existing
                upgraded.enrichmentState = .matched
                upgraded.enrichmentSource = incoming.enrichmentSource
                upgraded.enrichmentCheckedAt = incoming.enrichmentCheckedAt
                try saveEntityProfile(upgraded)
                updatedStudios += 1
            } else if existing.enrichmentState == .matched,
                      incoming.enrichmentState == .matched,
                      let mine = existing.enrichmentSource,
                      let theirs = incoming.enrichmentSource,
                      mine != theirs {
                // Both confirmed, but against different sources. Neither is
                // wrong and neither wins — worth knowing about rather than
                // burying.
                disagreements.append(GraphDisagreement(
                    subject: .studioSource, name: incoming.id, mine: mine, theirs: theirs))
            }
        }

        // Tags. Same shape, and the same one upgrade: an unclassified tag may
        // learn its kind, but a tag already classified here is never
        // reclassified from outside — that is a decision this library's
        // operator made, and a sync must not overrule it silently.
        var newTags = 0, classifiedTags = 0
        let existingTags = try fetchTagVocabulary()
        for incoming in export.tags {
            guard let existing = existingTags.first(where: { $0.identityKey == incoming.identityKey })
            else {
                try saveTagRecord(incoming)
                newTags += 1
                continue
            }
            if existing.kind == nil, incoming.kind != nil {
                var upgraded = existing
                upgraded.kind = incoming.kind
                try saveTagRecord(upgraded)
                classifiedTags += 1
            } else if let mine = existing.kind, let theirs = incoming.kind, mine != theirs {
                // ⚠️ The one that matters most. A tag classified two ways means
                // the two libraries attach it to different KINDS of node, so
                // their graphs diverge in shape rather than merely in content.
                disagreements.append(GraphDisagreement(
                    subject: .tagKind, name: existing.displayName, mine: mine, theirs: theirs))
            }
        }

        // Edges. Both ends must exist here, or the edge names something this
        // library has never heard of — skipped rather than conjuring the node.
        let known = Set(try fetchAllEntityProfiles().map(\.id))
        let vocabulary = Set(try fetchTagVocabulary().map(\.identityKey))

        var newPerformerTags = 0
        let havePerformerTags = Set(try performerTagPairs())
        for edge in export.performerTags
        where !havePerformerTags.contains(edge)
            && known.contains(edge.from) && vocabulary.contains(edge.to) {
            try linkTag(edge.to, toPerformer: edge.from)
            newPerformerTags += 1
        }

        // 🚨 A studio that already has a parent here is NEVER re-parented by a
        // sync.
        //
        // This used to call `setStudioParent` whenever the incoming pair was
        // not already present — which, for an imprint this library had placed
        // under a different network, silently REPLACED the operator's answer
        // with the sender's. That contradicts this merge's one rule: additive,
        // never overruling, disagreements reported rather than resolved.
        //
        // ⚠️ The defect predates the temporal migration — the old write was an
        // `ON CONFLICT DO UPDATE` and overwrote just as quietly. v30 made it
        // worse rather than causing it: the receiver's parent is now demoted
        // into dated history, so the overrule leaves a trail that looks like a
        // real acquisition.
        var newStudioParents = 0, refusedCycles = 0
        var datedStudioParents = 0, newStudioParentPeriods = 0

        let incomingByStudio = Dictionary(grouping: export.studioParents, by: \.from)
        for (studioId, incoming) in incomingByStudio.sorted(by: { $0.key < $1.key })
        where known.contains(studioId) {

            // ---- The current ownership.
            let myCurrent = try studioParentHistory(of: studioId).first { $0.isCurrent }

            if let theirs = incoming.first(where: { $0.isCurrent }), known.contains(theirs.to) {
                if let mine = myCurrent {
                    if mine.parentId != theirs.to {
                        disagreements.append(GraphDisagreement(
                            subject: .studioParent, name: studioId,
                            mine: mine.parentId, theirs: theirs.to))
                    } else if mine.from == nil, let start = theirs.validFrom {
                        // ⭐ D4's first rule. Same answer, and the sender knows
                        // WHEN — additive, so take it.
                        try setStudioParentStart(start, forStudio: studioId)
                        datedStudioParents += 1
                    } else if let a = mine.from, let b = theirs.validFrom, a != b {
                        // Same network, two different acquisition dates. Neither
                        // side is obviously right, so neither is written.
                        disagreements.append(GraphDisagreement(
                            subject: .studioParentDate, name: studioId,
                            mine: a, theirs: b))
                    }
                } else {
                    do {
                        // Genuinely additive: this library had no network for it,
                        // and takes the sender's start date with it.
                        try setStudioParent(theirs.to, forStudio: studioId,
                                            since: theirs.validFrom, source: .operator)
                        newStudioParents += 1
                    } catch is GraphEdgeError {
                        // ⚠️ Counted, not thrown. Two libraries can each hold half
                        // of a hierarchy that only loops once combined, and one bad
                        // pairing must not abandon an otherwise good sync partway.
                        refusedCycles += 1
                    }
                }
            }

            // ---- Former ownerships.
            //
            // ⚠️ Read AFTER the current row settled above, because adopting a
            // start date shrinks the open period and decides whether an arriving
            // historical period overlaps it.
            var held = try studioParentHistory(of: studioId)

            for period in incoming where !period.isCurrent && known.contains(period.to) {
                let candidate = (period.validFrom, period.validTo)

                if held.contains(where: { $0.parentId == period.to
                                       && $0.from == period.validFrom
                                       && $0.to == period.validTo }) {
                    continue                                    // already held
                }
                if let clash = held.first(where: {
                    Self.periodsOverlap(($0.from, $0.to), candidate)
                }) {
                    // 🚨 Two ownerships claiming the same stretch of time. Writing
                    // both would make `studioParentPairs(asOf:)` return two parents
                    // for one date — the exact invariant the temporal shape exists
                    // to hold — so this is reported and neither side changes.
                    disagreements.append(GraphDisagreement(
                        subject: .studioParentDate, name: studioId,
                        mine: clash.displayText,
                        theirs: StudioParentPeriod(parentId: period.to,
                                                   from: period.validFrom,
                                                   to: period.validTo).displayText))
                    continue
                }
                guard let ended = period.validTo else { continue }
                try addStudioParentPeriod(period.to, forStudio: studioId,
                                          from: period.validFrom, to: ended,
                                          source: .operator)
                newStudioParentPeriods += 1
                held.append(StudioParentPeriod(parentId: period.to,
                                               from: period.validFrom, to: period.validTo))
            }
        }

        // Match edges (v31). Additive like everything else: a source the
        // receiver has no answer for is taken, agreement is silent, and a
        // DIFFERENT id for the same source is reported and written nowhere.
        var newMatches = 0
        let mine = Dictionary(
            grouping: try allEntityMatches(), by: { "\($0.nodeId)|\($0.source)" })
        for match in export.entityMatches where known.contains(match.nodeId) {
            if let held = mine["\(match.nodeId)|\(match.source)"]?.first {
                guard held.sourceId != match.sourceId else { continue }
                disagreements.append(GraphDisagreement(
                    subject: .nodeIdentity, name: match.nodeId,
                    mine: held.sourceId, theirs: match.sourceId))
                continue
            }
            // ⭐ A source this library does not use is still worth taking. An
            // id costs nothing to hold and may matter the day that source is
            // installed — refusing it would make the second library's work
            // unrecoverable rather than merely unused.
            try recordMatch(match, isVideo: false)
            newMatches += 1
        }

        return GraphMergeResult(
            actors: .init(new: actors.newActorCount, updated: actors.updatedActorCount,
                          photos: actors.newPhotoCount),
            newStudios: newStudios, updatedStudios: updatedStudios,
            newTags: newTags, classifiedTags: classifiedTags,
            newPerformerTags: newPerformerTags, newStudioParents: newStudioParents,
            datedStudioParents: datedStudioParents,
            newStudioParentPeriods: newStudioParentPeriods,
            newMatches: newMatches,
            refusedCycles: refusedCycles, disagreements: disagreements)
    }

    /// Do two ownership periods cover any of the same time?
    ///
    /// ⚠️ nil is an INFINITY, not a missing value: a nil start reaches back
    /// forever and a nil end runs forward forever. Treating either as "no
    /// match" would let an arriving period slot straight through an open one —
    /// and since every row v30 migrated carries a nil start, that is the common
    /// case rather than the corner case.
    ///
    /// Half-open `[from, to)`, so a period ending on the day another begins does
    /// NOT overlap — that is a handover, and `setStudioParent` deliberately
    /// writes one boundary date into both rows to make it exactly that.
    static func periodsOverlap(_ a: (String?, String?), _ b: (String?, String?)) -> Bool {
        let aStartsBeforeBEnds = (a.0 == nil || b.1 == nil) ? true : a.0! < b.1!
        let bStartsBeforeAEnds = (b.0 == nil || a.1 == nil) ? true : b.0! < a.1!
        return aStartsBeforeBEnds && bStartsBeforeAEnds
    }
}
