// UpstreamMergeAudit.swift
// The duplicate the source already resolved.
//
// ⭐ The alias-split problem, ALREADY SOLVED upstream. Duplicate performers are
// detected here from AKA overlap — a heuristic that produces false pairs, since
// two performers who share a common alias are not one person. When the source
// merged two of its own records, that is not a heuristic. It is a fact it
// recorded.
//
// 🚨 What this is FOR, and it is not more rows. `AliasSplitAudit` already
// produces candidates; a tool that produces more work to review is not an
// improvement. This exists to make a pair supported by both kinds of evidence
// rank above one supported by either, and to let the source settle the question
// the alias heuristic cannot answer: WHICH of several claimants is the survivor.
//
// ⭐ No new data is fetched for this. `entity_match.merged_into` is already
// written by the upstream-deletions work, and a pair falls straight out of it:
// one local profile matched to a record that was merged away, another matched
// to the record it was merged INTO. The spec argued at length about needing the
// survivor-side `merged_ids` list; it is not needed, because the losing side
// already names its destination.
//
// ⚠️ This never merges anything. D1 — an upstream merge says the SOURCE decided
// two of its records were one person, and a person still confirms.

import Foundation

/// Two local profiles the source has already merged into one record.
public struct UpstreamMergePair: Equatable, Sendable, Identifiable {
    /// Matched to the record that survived upstream.
    public let survivingId: String
    /// Matched to the record that was merged away.
    public let losingId: String
    public let source: String
    /// The surviving record's id at the source.
    public let survivingSourceId: String

    public var id: String { "\(source):\(losingId)->\(survivingId)" }

    public init(survivingId: String, losingId: String, source: String,
                survivingSourceId: String) {
        self.survivingId = survivingId
        self.losingId = losingId
        self.source = source
        self.survivingSourceId = survivingSourceId
    }
}

public enum UpstreamMergeAudit {

    /// Pairs where this library holds BOTH sides of an upstream merge.
    ///
    /// 🚨 M4 — direction. `merged_into` says *this record was merged AWAY*, so
    /// the profile carrying it is the LOSER and the profile matched to its
    /// destination is the survivor. Reading it the other way round would
    /// propose merging the survivor into the ghost.
    ///
    /// ⚠️ M5 — holding only one side yields nothing. That case is a staleness
    /// finding, not a duplicate one, and *Upstream Deletions* already reports
    /// it. Emitting it here too would put the same fact in two screens with two
    /// different suggested actions.
    public static func pairs(from matches: [NodeMatch]) -> [UpstreamMergePair] {
        // Surviving record id → the local profile matched to it, per source.
        var holderOfSourceId: [String: String] = [:]
        for match in matches {
            holderOfSourceId[key(match.source, match.sourceId)] = match.nodeId
        }

        var seen: Set<String> = []
        var out: [UpstreamMergePair] = []

        for match in matches {
            guard let destination = match.mergedInto,
                  !destination.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            // ⚠️ A record merged into itself is not a pair. Defensive: the
            // source should never say this, and treating it as one would
            // propose merging a profile into itself.
            guard destination != match.sourceId else { continue }
            guard let survivor = holderOfSourceId[key(match.source, destination)],
                  survivor != match.nodeId else { continue }

            let pair = UpstreamMergePair(survivingId: survivor,
                                         losingId: match.nodeId,
                                         source: match.source,
                                         survivingSourceId: destination)
            if seen.insert(pair.id).inserted { out.append(pair) }
        }

        // Stable, so the review list does not reshuffle between runs.
        return out.sorted { $0.id < $1.id }
    }

    /// Losing profile id → surviving profile id, the form `AliasSplitAudit`
    /// takes as evidence.
    public static func survivorByLoser(from matches: [NodeMatch]) -> [String: String] {
        var out: [String: String] = [:]
        for pair in pairs(from: matches) { out[pair.losingId] = pair.survivingId }
        return out
    }

    private static func key(_ source: String, _ sourceId: String) -> String {
        "\(source)\u{1}\(sourceId)"
    }
}
