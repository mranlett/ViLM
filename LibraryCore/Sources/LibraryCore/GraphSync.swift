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
    public func exportGraph(includingPhotoData: Bool = true) throws -> ActorLibraryExport {
        var export = try exportActorLibrary(includingPhotoData: includingPhotoData)
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

        var newStudioParents = 0, refusedCycles = 0
        let haveStudioParents = Set(try studioParentPairs())
        for edge in export.studioParents
        where !haveStudioParents.contains(edge)
            && known.contains(edge.from) && known.contains(edge.to) {
            do {
                try setStudioParent(edge.to, forStudio: edge.from)
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
            refusedCycles: refusedCycles)
    }
}
