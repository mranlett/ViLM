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
            + newTags + classifiedTags + newPerformerTags + newStudioParents > 0
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
        export.studioParents = try studioParentPairs()
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
        let currentParents = Dictionary(
            try studioParentPairs().map { ($0.from, $0.to) }, uniquingKeysWith: { a, _ in a })

        for edge in export.studioParents
        where known.contains(edge.from) && known.contains(edge.to) {
            if let mine = currentParents[edge.from] {
                // Already the same answer: nothing to do, and not a conflict.
                guard mine != edge.to else { continue }
                disagreements.append(GraphDisagreement(
                    subject: .studioParent, name: edge.from, mine: mine, theirs: edge.to))
                continue
            }
            do {
                // Genuinely additive: this library had no network for it.
                try setStudioParent(edge.to, forStudio: edge.from, source: .operator)
                newStudioParents += 1
            } catch is GraphEdgeError {
                // ⚠️ Counted, not thrown. Two libraries can each hold half of a
                // hierarchy that only loops once combined, and one bad pairing
                // must not abandon an otherwise good sync partway through.
                refusedCycles += 1
            }
        }

        return GraphMergeResult(
            actors: .init(new: actors.newActorCount, updated: actors.updatedActorCount,
                          photos: actors.newPhotoCount),
            newStudios: newStudios, updatedStudios: updatedStudios,
            newTags: newTags, classifiedTags: classifiedTags,
            newPerformerTags: newPerformerTags, newStudioParents: newStudioParents,
            refusedCycles: refusedCycles, disagreements: disagreements)
    }
}
