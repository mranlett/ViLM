// LibraryStore+FilenameEdges.swift
// Names read out of a filename become edges that SAY they came from a filename
// (#77).
//
// 🚨 THE PROBLEM THIS SOLVES. The parse review wrote its findings as tag
// strings on the asset and nothing else. The bulk connect later walked those
// strings and turned them into edges marked `inferred` — the honest value for
// that pass, since `asset.tags` came from every route there is. So a name
// GUESSED from a filename arrived in the graph indistinguishable from one an
// operator typed or a source asserted.
//
// ⚠️ A filename guess is the least reliable origin the system has, and it was
// the one arriving with no label. `EdgeProvenance.filename` existed for exactly
// this and nothing wrote it.
//
// ⭐ Writing the edge here does not remove the tag string. Both are kept: the
// strings remain what the rest of the app reads, and the edge is the durable
// record of where the name came from. Replacing one with the other is a much
// larger change than recording the origin.

import Foundation
import GRDB

/// What recording a parse produced.
public struct FilenameEdgeResult: Equatable, Sendable {
    public var performers = 0
    public var studios = 0
    public var tags = 0

    /// 🚨 Names with no profile to point an edge at, so nothing was recorded
    /// for them. The tag string is still on the asset — the name is not lost —
    /// but the graph does not know it, and this is the count that says so. A
    /// silent zero here would read as "all recorded".
    public var unresolved: [String] = []

    public var total: Int { performers + studios + tags }
}

public extension LibraryStore {

    /// Records the names a filename parse contributed, as edges carrying
    /// `EdgeProvenance.filename`.
    ///
    /// - Parameter additions: prefixed tag strings exactly as the proposal
    ///   produced them — `actor:Name`, `studio:Name`, `tag:Name`. Anything
    ///   without a recognised prefix is ignored rather than guessed at.
    @discardableResult
    func recordFilenameDerived(_ additions: [String],
                               forVideo videoId: UUID) throws -> FilenameEdgeResult {
        guard !additions.isEmpty else { return FilenameEdgeResult() }

        var result = FilenameEdgeResult()
        // ⭐ A NAME is the input and an entity id is the output, so this is a
        // resolution rather than a membership test — the same reasoning the
        // bulk connect records, and the reason both must go through
        // `NodeResolver` rather than treating the prefixed name as an id.
        let resolver = NodeResolver(profiles: try fetchAllEntityProfiles())

        // ⚠️ A tag edge has a FOREIGN KEY to a tag record, so a tag the
        // vocabulary has never seen cannot be linked either. Assuming
        // otherwise — that only people and studios need a prior record —
        // produced a constraint failure the moment it was tested against a
        // real database, which is the argument for testing against one.
        let knownTags = Set(try fetchTagVocabulary().map(\.identityKey))

        for addition in additions {
            guard let separator = addition.firstIndex(of: ":") else { continue }
            let kind = String(addition[addition.startIndex..<separator])
            let name = String(addition[addition.index(after: separator)...])
            guard !name.isEmpty else { continue }

            switch kind {
            case "actor":
                guard let id = resolver.localId(for: addition) else {
                    result.unresolved.append(addition); continue
                }
                try linkPerformer(id, toVideo: videoId, source: .filename)
                result.performers += 1

            case "studio":
                guard let id = resolver.localId(for: addition) else {
                    result.unresolved.append(addition); continue
                }
                // ⚠️ Cannot downgrade a studio already asserted by something
                // better — `setStudio` owns that rule, and a filename is the
                // weakest origin there is, so this is the caller most likely
                // to have tried.
                try setStudio(id, forVideo: videoId, source: .filename)
                result.studios += 1

            case "tag":
                // Keyed by folded identity rather than by a profile, but the
                // record still has to exist — see `knownTags`.
                let key = TagNormalizer.identityKey(name)
                guard knownTags.contains(key) else {
                    result.unresolved.append(addition); continue
                }
                try linkTag(key, toVideo: videoId, source: .filename)
                result.tags += 1

            default:
                continue
            }
        }

        return result
    }
}
