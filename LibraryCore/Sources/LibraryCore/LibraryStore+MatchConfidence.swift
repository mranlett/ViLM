// LibraryStore+MatchConfidence.swift
// The review queue: fingerprint matches the source's own data does not
// strongly support.
//
// 🔴 D4 — A QUEUE, AND NOTHING ELSE. Every row here is an invitation to look.
// Nothing in this file un-matches, re-matches, hides or re-queues anything, and
// no caller is handed the means to do it as a consequence of doubt. A
// low-confidence match is still very often right; the failure this addresses is
// that a doubtful one currently looks exactly like a certain one.

import Foundation
import GRDB

/// One fingerprint match worth a second look, with the evidence.
///
/// ⚠️ Carries BOTH runtimes rather than a verdict. "The durations disagree" is
/// not actionable — 28:14 against 61:02 is, because the operator can see at a
/// glance that it is a different cut rather than a re-encode.
public struct LowConfidenceMatch: Equatable, Sendable, Identifiable {
    public let videoId: UUID
    public let title: String
    public let fileName: String
    public let source: String
    public let sourceId: String
    public let doubts: [MatchDoubt]
    public let localDuration: Double?
    public let claimedDuration: Double?
    public let submissions: Int?
    /// 🚨 When the confidence was recorded, not when it was read. A submission
    /// count is a snapshot of a crowd that keeps moving.
    public let asOf: Date?

    public var id: UUID { videoId }
}

public extension LibraryStore {

    /// Fingerprint matches whose confidence is doubtful.
    ///
    /// ⭐ Computed from what is already stored — the match edge's confidence
    /// columns and the video's own measured runtime — so it costs one query and
    /// no network. That is what makes it a queue the operator can open at any
    /// time rather than a report that has to be "run".
    ///
    /// ⚠️ A video with no measured duration and no submission count produces no
    /// row. It is not evidence of a good match; it is the absence of anything
    /// to judge, and filling the queue with those would bury the real ones.
    func lowConfidenceMatches() throws -> [LowConfidenceMatch] {
        let assets = try fetchAllAssets()
        var byId: [String: Asset] = [:]
        for asset in assets { byId[asset.id.uuidString] = asset }

        let rows: [LowConfidenceMatch] = try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT video_id, source, source_id, method,
                       submissions, fingerprint_duration, confidence_as_of
                  FROM video_match
                 WHERE method = ? AND deleted_at IS NULL
                """, arguments: [MatchMethod.fingerprint.rawValue])
                .compactMap { row -> LowConfidenceMatch? in
                    let videoId: String = row["video_id"]
                    guard let asset = byId[videoId], let uuid = UUID(uuidString: videoId)
                    else { return nil }

                    let confidence = MatchConfidence(
                        submissions: row["submissions"],
                        fingerprintDuration: row["fingerprint_duration"],
                        algorithm: nil,
                        asOf: row["confidence_as_of"])

                    let found = MatchConfidenceRules.doubts(
                        method: .fingerprint,
                        localDuration: asset.duration,
                        confidence: confidence)
                    guard !found.isEmpty else { return nil }

                    return LowConfidenceMatch(
                        videoId: uuid,
                        title: ActorKnownFor.displayTitle(asset),
                        fileName: asset.fileName,
                        source: row["source"],
                        sourceId: row["source_id"],
                        doubts: found,
                        localDuration: asset.duration,
                        claimedDuration: confidence.fingerprintDuration,
                        submissions: confidence.submissions,
                        asOf: confidence.asOf)
                }
        }

        // Worst first: a duration disagreement is stronger evidence than a lone
        // submitter, and a row carrying both is the one to look at first.
        return rows.sorted { a, b in
            if a.doubts.count != b.doubts.count { return a.doubts.count > b.doubts.count }
            let aDuration = a.doubts.contains(.durationDisagrees)
            let bDuration = b.doubts.contains(.durationDisagrees)
            if aDuration != bDuration { return aDuration }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    /// How many fingerprint matches carry no recorded confidence at all.
    ///
    /// ⭐ The honest denominator. Until a provider supplies these fields every
    /// existing match reads as "not doubtful", which is indistinguishable from
    /// "checked and fine" unless the screen says how many were never assessed.
    /// 773 silent rows behind an empty queue is not the same as a clean library.
    func fingerprintMatchesWithoutConfidence() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT count(*) FROM video_match
                 WHERE method = ? AND deleted_at IS NULL
                   AND submissions IS NULL AND fingerprint_duration IS NULL
                """, arguments: [MatchMethod.fingerprint.rawValue]) ?? 0
        }
    }
}
