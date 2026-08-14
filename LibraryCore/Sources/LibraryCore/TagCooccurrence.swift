// TagCooccurrence.swift
// Which tags travel together, and what that implies about the vocabulary.
//
// ⭐ Proposed by *What the Graph Could Answer* (section C): "tags that nearly
// always travel together are either duplicates awaiting a merge or a parent and
// child awaiting a hierarchy that does not exist yet. This is the evidence that
// would justify building tag parentage."
//
// 🚨 The two findings are NOT the same claim, and separating them is the whole
// design:
//
//   • **Containment** — A almost always appears with B, but B often appears
//     without A. That is a broad tag and a narrow one, and it argues for a
//     `tag_parent` edge. It does NOT argue for merging: the tags mean
//     different things and both are correct.
//   • **Merge** — A and B each nearly always appear with the other. Two names
//     for one idea, and one of them should go.
//
// A tool that reported both as "these tags are related" would invite exactly
// the wrong action on half its findings.
//
// ⚠️ This REPORTS and repairs nothing, like Impossible Data and unlike Studio
// Health. Whether a broad tag is genuinely the parent of a narrow one is a
// judgement about meaning, and co-occurrence cannot make it — two tags can
// travel together because the library is small, or because one operator
// habitually applies both.

import Foundation
import GRDB

/// One directed relationship between two tags.
public struct TagAffinity: Equatable, Sendable, Identifiable {
    /// The tag that implies the other.
    public let tag: String
    /// The tag it implies.
    public let implies: String
    /// Videos carrying both.
    public let together: Int
    /// Videos carrying `tag` at all.
    public let tagTotal: Int
    /// Videos carrying `implies` at all.
    public let impliesTotal: Int

    /// How often `tag` brings `implies` with it, 0...1.
    public var confidence: Double {
        tagTotal == 0 ? 0 : Double(together) / Double(tagTotal)
    }

    /// The reverse direction, which is what tells containment from a merge.
    public var reverseConfidence: Double {
        impliesTotal == 0 ? 0 : Double(together) / Double(impliesTotal)
    }

    public var id: String { "\(tag)→\(implies)" }

    public init(tag: String, implies: String, together: Int,
                tagTotal: Int, impliesTotal: Int) {
        self.tag = tag
        self.implies = implies
        self.together = together
        self.tagTotal = tagTotal
        self.impliesTotal = impliesTotal
    }
}

public struct TagAffinityReport: Equatable, Sendable {
    /// A narrow tag inside a broad one — the case for a hierarchy.
    public let containment: [TagAffinity]
    /// Two names for one idea — the case for a merge.
    public let merges: [TagAffinity]
    /// How many tags were considered at all, after the support floor.
    public let tagsConsidered: Int

    public var isEmpty: Bool { containment.isEmpty && merges.isEmpty }
}

public enum TagCooccurrence {

    /// ⚠️ Thresholds are arguments with measured defaults, not constants buried
    /// in the algorithm. Measured on the drive library 2026-08-14 (2,077
    /// videos, 42 tags in use, 4,558 edges): these produce **6** containment
    /// candidates and **0** merges — a short list worth reading, which is the
    /// only kind anybody reads.
    ///
    /// Loosening `containment` to 0.8 yields 11 and to 0.7 yields 22, at which
    /// point the list stops being evidence and becomes a correlation table.
    public struct Thresholds: Equatable, Sendable {
        /// Below this many shared videos, a ratio is noise. Two tags on two
        /// videos are "100% together" and mean nothing.
        public var minimumTogether: Int
        /// How strongly the narrow tag must imply the broad one.
        public var containment: Double
        /// ⭐ And how weakly the broad one may imply the narrow. Without this
        /// second bound every merge candidate also qualifies as containment.
        public var independence: Double
        /// Each implying the other this strongly is one idea under two names.
        public var merge: Double

        public init(minimumTogether: Int = 10, containment: Double = 0.9,
                    independence: Double = 0.5, merge: Double = 0.8) {
            self.minimumTogether = minimumTogether
            self.containment = containment
            self.independence = independence
            self.merge = merge
        }
    }

    /// - Parameter edges: every (video, tag) pair in the library. Duplicates are
    ///   tolerated — a video carrying one tag twice counts once.
    public static func analyse(edges: [GraphEdgePair],
                               thresholds: Thresholds = .init()) -> TagAffinityReport {
        // ⚠️ De-duplicated first. `video_tag` is a set in intent but the
        // analysis divides by these counts, so a repeated row would inflate a
        // confidence above 1 and float a spurious finding to the top.
        var tagsByVideo: [String: Set<String>] = [:]
        for edge in edges { tagsByVideo[edge.from, default: []].insert(edge.to) }

        var totals: [String: Int] = [:]
        var together: [Pair: Int] = [:]
        for tags in tagsByVideo.values {
            let sorted = tags.sorted()
            for tag in sorted { totals[tag, default: 0] += 1 }
            for i in sorted.indices {
                for j in sorted.indices where j > i {
                    together[Pair(sorted[i], sorted[j]), default: 0] += 1
                }
            }
        }

        var containment: [TagAffinity] = []
        var merges: [TagAffinity] = []

        for (pair, count) in together where count >= thresholds.minimumTogether {
            let a = TagAffinity(tag: pair.low, implies: pair.high, together: count,
                                tagTotal: totals[pair.low] ?? 0,
                                impliesTotal: totals[pair.high] ?? 0)
            let b = TagAffinity(tag: pair.high, implies: pair.low, together: count,
                                tagTotal: totals[pair.high] ?? 0,
                                impliesTotal: totals[pair.low] ?? 0)

            // 🚨 Merge is tested FIRST and wins. A pair where each implies the
            // other also satisfies containment in both directions, and
            // reporting it as a hierarchy would propose making a tag the parent
            // of its own synonym.
            if a.confidence >= thresholds.merge && b.confidence >= thresholds.merge {
                merges.append(a.confidence >= b.confidence ? a : b)
                continue
            }
            for candidate in [a, b]
            where candidate.confidence >= thresholds.containment
                && candidate.reverseConfidence < thresholds.independence {
                containment.append(candidate)
            }
        }

        return TagAffinityReport(
            // Strongest first, then by size, then by name so a redraw never
            // reorders a list the operator is reading.
            containment: containment.sorted(by: ordering),
            merges: merges.sorted(by: ordering),
            tagsConsidered: totals.count)
    }

    private static func ordering(_ x: TagAffinity, _ y: TagAffinity) -> Bool {
        if x.confidence != y.confidence { return x.confidence > y.confidence }
        if x.together != y.together { return x.together > y.together }
        return x.id < y.id
    }

    /// An unordered tag pair, so a video contributes one count per pair rather
    /// than two.
    private struct Pair: Hashable {
        let low: String
        let high: String
        init(_ a: String, _ b: String) {
            (low, high) = a <= b ? (a, b) : (b, a)
        }
    }
}

public extension LibraryStore {

    /// Every video↔tag edge, as portable pairs.
    func videoTagPairs() throws -> [GraphEdgePair] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT video_id, tag_id FROM video_tag")
                .map { GraphEdgePair(from: $0["video_id"], to: $0["tag_id"]) }
        }
    }

    /// What the tag vocabulary implies about itself.
    func tagAffinities(thresholds: TagCooccurrence.Thresholds = .init())
    throws -> TagAffinityReport {
        TagCooccurrence.analyse(edges: try videoTagPairs(), thresholds: thresholds)
    }
}
