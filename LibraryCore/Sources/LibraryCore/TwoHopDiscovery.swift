// TwoHopDiscovery.swift
// Performers who share a studio but have never shared a video.
//
// ⭐ From *What the Graph Could Answer*, section D: "reachable in one query,
// unanswerable from strings" — and the spike's argument for the whole Epic.
// Nothing in any single record connects two people who never appeared together;
// only the path through a studio does.
//
// 🚨 THE THRESHOLD IS THE FEATURE. Measured on the drive library 2026-08-14:
// 35,458 pairs share at least one studio and have never co-starred. That is not
// a discovery list, it is 93% of everybody — sharing ONE studio is close to
// universal and means nothing. Requiring three drops it to 285, which is a list
// a person can actually read.
//
// ⭐ And the ranking matters as much as the floor. Two performers who share
// three studios and work almost nowhere else are strongly connected; two who
// share three out of forty are barely connected at all. The overlap — shared
// studios over the studios either has worked for — separates them, and both
// numbers are reported so the reading can be disagreed with.

import Foundation
import GRDB

/// Two performers connected by studios rather than by a video.
public struct StudioNeighbour: Equatable, Sendable, Identifiable {
    public let performer: String
    public let other: String
    public let sharedStudios: Int
    /// How many studios each has worked for at all.
    public let performerStudios: Int
    public let otherStudios: Int

    /// Shared studios over the union of both — 1.0 means neither has worked
    /// anywhere the other has not.
    public var overlap: Double {
        let union = performerStudios + otherStudios - sharedStudios
        return union == 0 ? 0 : Double(sharedStudios) / Double(union)
    }

    public var id: String { "\(performer)|\(other)" }

    public init(performer: String, other: String, sharedStudios: Int,
                performerStudios: Int, otherStudios: Int) {
        self.performer = performer
        self.other = other
        self.sharedStudios = sharedStudios
        self.performerStudios = performerStudios
        self.otherStudios = otherStudios
    }
}

public struct TwoHopReport: Equatable, Sendable {
    public let neighbours: [StudioNeighbour]
    /// Pairs sharing at least one studio, before any floor.
    public let pairsSharingAStudio: Int
    /// 🚨 Pairs dropped because they HAVE appeared together. Reported, because
    /// it is the measure of how much of the graph is already visible without
    /// this feature.
    public let alreadyCoStarred: Int

    public var isEmpty: Bool { neighbours.isEmpty }
}

public enum TwoHopDiscovery {

    /// ⚠️ Measured defaults. On the drive library a floor of one gives 35,458
    /// pairs, two gives 2,048 and three gives 285 — the first list worth
    /// opening. The most any non-co-starring pair shares is seven.
    public struct Thresholds: Equatable, Sendable {
        public var minimumSharedStudios: Int

        public init(minimumSharedStudios: Int = 3) {
            self.minimumSharedStudios = minimumSharedStudios
        }
    }

    /// - Parameters:
    ///   - videoPerformer: `from` video id, `to` performer id.
    ///   - videoStudio: `from` video id, `to` studio id.
    public static func analyse(videoPerformer: [GraphEdgePair],
                               videoStudio: [GraphEdgePair],
                               thresholds: Thresholds = .init()) -> TwoHopReport {
        var performersByVideo: [String: Set<String>] = [:]
        for edge in videoPerformer { performersByVideo[edge.from, default: []].insert(edge.to) }
        var studiosByVideo: [String: Set<String>] = [:]
        for edge in videoStudio { studiosByVideo[edge.from, default: []].insert(edge.to) }

        // Who has worked for whom, and who has stood next to whom.
        var studiosByPerformer: [String: Set<String>] = [:]
        var performersByStudio: [String: Set<String>] = [:]
        var coStarred: Set<Pair> = []

        for (video, performers) in performersByVideo {
            for studio in studiosByVideo[video] ?? [] {
                for performer in performers {
                    studiosByPerformer[performer, default: []].insert(studio)
                    performersByStudio[studio, default: []].insert(performer)
                }
            }
            // ⚠️ Co-starring is recorded from the VIDEO, independently of
            // whether that video carries a studio. A pair who appeared together
            // in an unattributed video have still appeared together, and
            // offering them as a discovery would be plainly wrong.
            let cast = performers.sorted()
            for i in cast.indices {
                for j in cast.indices where j > i { coStarred.insert(Pair(cast[i], cast[j])) }
            }
        }

        var shared: [Pair: Int] = [:]
        for performers in performersByStudio.values {
            let sorted = performers.sorted()
            for i in sorted.indices {
                for j in sorted.indices where j > i {
                    shared[Pair(sorted[i], sorted[j]), default: 0] += 1
                }
            }
        }

        var neighbours: [StudioNeighbour] = []
        var alreadyCoStarred = 0
        for (pair, count) in shared {
            if coStarred.contains(pair) { alreadyCoStarred += 1; continue }
            guard count >= thresholds.minimumSharedStudios else { continue }
            neighbours.append(StudioNeighbour(
                performer: pair.low, other: pair.high, sharedStudios: count,
                performerStudios: studiosByPerformer[pair.low]?.count ?? 0,
                otherStudios: studiosByPerformer[pair.high]?.count ?? 0))
        }

        return TwoHopReport(
            // ⭐ Exclusivity first, then substance. The floor guarantees the
            // pair share enough to matter; the overlap orders by how much of
            // each performer's working life the other accounts for.
            neighbours: neighbours.sorted {
                if $0.overlap != $1.overlap { return $0.overlap > $1.overlap }
                if $0.sharedStudios != $1.sharedStudios { return $0.sharedStudios > $1.sharedStudios }
                return $0.id < $1.id
            },
            pairsSharingAStudio: shared.count,
            alreadyCoStarred: alreadyCoStarred)
    }

    private struct Pair: Hashable {
        let low: String
        let high: String
        init(_ a: String, _ b: String) { (low, high) = a <= b ? (a, b) : (b, a) }
    }
}

public extension LibraryStore {

    /// Every video↔performer edge, as portable pairs.
    func videoPerformerPairs() throws -> [GraphEdgePair] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT video_id, performer_id FROM video_performer")
                .map { GraphEdgePair(from: $0["video_id"], to: $0["performer_id"]) }
        }
    }

    /// Every video↔studio edge, as portable pairs.
    func videoStudioPairs() throws -> [GraphEdgePair] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT video_id, studio_id FROM video_studio")
                .map { GraphEdgePair(from: $0["video_id"], to: $0["studio_id"]) }
        }
    }

    func studioNeighbours(thresholds: TwoHopDiscovery.Thresholds = .init())
    throws -> TwoHopReport {
        TwoHopDiscovery.analyse(videoPerformer: try videoPerformerPairs(),
                                videoStudio: try videoStudioPairs(),
                                thresholds: thresholds)
    }
}
