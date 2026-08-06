// CandidatePreference.swift
// Puts the ORIGINAL PRODUCTION ahead of a redistribution.
//
// The same scene is often listed twice: once by the studio that made it, and
// again — sometimes years later — by whoever licensed it. Both entries are
// real and both name a verified studio, so nothing about the two records says
// which is which. What separates them is time: the original cannot have been
// released after the copy.
//
// ⚠️ Reorders WITHIN a work, never across the list. The search already ranked
// candidates by how well they match the file, and sorting everything by date
// would throw that away to answer a question that only arises between two
// listings of the same scene.

import Foundation

public enum CandidatePreference {

    /// Reorders so that, among candidates that appear to be the same work, the
    /// earliest release comes first. Everything else keeps its position.
    ///
    /// Stable: candidates that are not duplicates of one another come back in
    /// exactly the order the source ranked them.
    public static func preferOriginalProduction(_ candidates: [PluginCandidate])
    -> [PluginCandidate] {
        // Group positions by work, so a group can be rewritten in place without
        // disturbing anything around it.
        var positionsByWork: [String: [Int]] = [:]
        for (position, candidate) in candidates.enumerated() {
            positionsByWork[workKey(candidate), default: []].append(position)
        }

        var reordered = candidates
        for (_, positions) in positionsByWork where positions.count > 1 {
            let group = positions.map { candidates[$0] }
            let byDate = group.enumerated().sorted { a, b in
                switch (a.element.releaseDate, b.element.releaseDate) {
                case let (x?, y?) where x != y:
                    return x < y
                // ⚠️ An undated candidate does NOT win. Nothing establishes it
                // as the original, and promoting it would let missing data
                // outrank a stated fact.
                case (nil, _?): return false
                case (_?, nil): return true
                default:
                    // Same date, or neither dated: leave the source's ranking
                    // alone rather than inventing an order.
                    return a.offset < b.offset
                }
            }.map(\.element)

            for (slot, position) in positions.enumerated() {
                reordered[position] = byDate[slot]
            }
        }
        return reordered
    }

    /// What counts as "the same work".
    ///
    /// Title and running time together: title alone merges genuinely different
    /// scenes that share a name, and duration alone merges everything a studio
    /// cut to the same length. A candidate with no duration is keyed on title
    /// alone, which is the most that can be said about it.
    static func workKey(_ candidate: PluginCandidate) -> String {
        let title = candidate.title
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let duration = candidate.durationSeconds else { return title }
        // Bucketed: two listings of one scene routinely differ by a few
        // seconds of trailer or slate, which is not a different work.
        return "\(title)#\(duration / 10)"
    }
}
