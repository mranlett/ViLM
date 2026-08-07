// NodeMatch.swift
// A node's identity in an external source, as an edge rather than a column.
//
// 🚨 The Epic's D4 said this and it never happened: "a match is an edge to an
// external identity, and must be as durable as any other." It was four columns
// on the node — one source, one answer, no history — and every identity defect
// found on 2026-08-07 traced back to that shape.
//
// ⭐ The decisive difference: a column cannot record that something is MISSING.
// A node can hold `enrichmentState = matched` and a null `enrichmentSourceId`,
// and nothing distinguishes "never had one" from "we failed to write it down".
// Measured on the real library: 1,236 of 1,250 matched actors were in exactly
// that state, and none of them could ever acquire an id, because the tool that
// would supply one skips anything already matched. With an edge, "no row" is a
// queryable fact and those nodes become a worklist.

import Foundation
import GRDB

/// How a node came to be identified.
///
/// ⭐ Stored because the app already computes it and throws it away. The video
/// review sheet renders a fingerprint match with a green seal and everything
/// else with a question mark — it knows the difference in trust, and discarded
/// it on dismissal. Exactly the shape `credited_as` had.
public enum MatchMethod: String, Codable, Equatable, Sendable, CaseIterable {
    /// Identified by what the file LOOKS like. Survives re-encoding, so it
    /// identifies a file whose name, container and bitrate have all changed.
    case fingerprint
    /// Two or more cast names together. Plausible, which is not identified.
    case cast
    /// A text search on the title. The weakest.
    case title
    /// ⚠️ An EXACT name match, disambiguated where several people shared it.
    /// The only route an actor or studio has — they have no fingerprint and no
    /// cast — so without this they would all have to be recorded as `title`,
    /// which understates a match that required an exact name AND a
    /// disambiguation to survive.
    case name
    /// ⭐ The SOURCE's own record links these — no matching happened here at
    /// all. A scene record naming a confirmed performer is the source
    /// asserting the relationship, not this app inferring it.
    ///
    /// ⚠️ Its trust is INHERITED, not intrinsic. The link is only as good as
    /// the video match that reached it: a title-matched video is "plausible,
    /// not identified", so propagating its cast as confirmed identities would
    /// launder one guess into many. Callers must check the video's own method
    /// before writing these — see `MatchMethod.propagatesIdentity`.
    case linked
    /// A person chose it from a list. Trustworthy for a different reason than
    /// a fingerprint: someone looked.
    case `operator`
    /// ⚠️ Derived from an existing column during migration. The method was not
    /// recorded at the time and is genuinely unknown — this says so rather than
    /// guessing `operator` and inventing a person who never looked.
    case backfill

    /// How much the method itself justifies trusting the match.
    ///
    /// ⚠️ Ranks the METHOD, not the result. A title match can be perfectly
    /// correct; it just carries no evidence that it is.
    public var trust: Int {
        switch self {
        case .fingerprint: return 5
        case .operator:    return 4
        case .linked:      return 4
        case .name:        return 3
        case .cast:        return 2
        case .backfill:    return 1
        case .title:       return 0
        }
    }

    /// Whether a video matched THIS way may hand its identity to its cast.
    ///
    /// 🚨 Only the strong routes, and only while a person could still review.
    ///
    /// ⚠️ The risk is narrower than it first appears, and worth stating
    /// precisely. The performer's id and their NAME come from the same scene
    /// record, so they are consistent with each other: propagating attaches a
    /// CORRECT identity to a correctly-spelled person. What a weak video match
    /// gets wrong is whether that performer is in THIS video — and the original
    /// run already wrote their name onto it as a string, so the doubtful edge
    /// exists either way.
    ///
    /// The real cost is stickiness: an identified actor reads as verified and
    /// is skipped by every later tool. That is worth avoiding while the video
    /// is still in front of someone who can reject the match — hence this rule
    /// for live matching, and `propagateIdentitiesFromSettledMatch` for videos
    /// whose match was settled long ago and whose method was never recorded.
    public var propagatesIdentity: Bool {
        self == .fingerprint || self == .operator
    }

    public var displayName: String {
        switch self {
        case .fingerprint: return "visual fingerprint"
        case .cast:        return "cast"
        case .title:       return "title"
        case .name:        return "exact name"
        case .linked:      return "linked by the source"
        case .operator:    return "your choice"
        case .backfill:    return "recorded before the method was"
        }
    }
}

/// One node, identified in one source.
public struct NodeMatch: Codable, Equatable, Sendable, Identifiable {
    /// `assets.id` as a string, or an `entity_profiles.id`.
    public let nodeId: String
    /// Which service. Plain text, because naming a source in code is the
    /// repository asserting a dependency it does not have.
    public let source: String
    /// That service's own identifier for this node.
    public let sourceId: String
    public let method: MatchMethod
    public let matchedAt: Date

    public var id: String { "\(nodeId)|\(source)" }

    public init(nodeId: String, source: String, sourceId: String,
                method: MatchMethod, matchedAt: Date = Date()) {
        self.nodeId = nodeId
        self.source = source
        self.sourceId = sourceId
        self.method = method
        self.matchedAt = matchedAt
    }
}

public enum NodeMatchRanking {

    /// The match to act on when a node has several.
    ///
    /// ⭐ Ranked by METHOD first, not recency. A fingerprint from a year ago
    /// identifies a file better than a title guess made today — recency
    /// measures when someone last looked, not how well they saw.
    ///
    /// Recency breaks ties, so re-checking the same way does replace the older
    /// answer.
    public static func best(_ matches: [NodeMatch]) -> NodeMatch? {
        matches.max {
            $0.method.trust != $1.method.trust
                ? $0.method.trust < $1.method.trust
                : $0.matchedAt < $1.matchedAt
        }
    }

    /// Newest first — for showing a node's match history.
    public static func ordered(_ matches: [NodeMatch]) -> [NodeMatch] {
        matches.sorted { $0.matchedAt > $1.matchedAt }
    }
}
