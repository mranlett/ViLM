// IdentityGapAudit.swift
// Nodes that claim to be matched and hold no external identity.
//
// 🚨 The query a column could not answer. `enrichmentState = matched` beside a
// null `enrichmentSourceId` is indistinguishable from a node nobody ever looked
// up — so these were invisible AND unreachable, because `skipReason` returns
// "already matched" and the tool that would supply an id refuses to examine
// them. Measured when the match edges shipped: 1,236 of 1,250 actors.
//
// ⭐ What makes this a WORKLIST rather than a list is the second question: for
// each one, is there a route back? A performer credited on a video that IS
// matched can be recovered by refreshing that video, because the source's scene
// record links to their confirmed profile. One credited only on unmatched
// videos cannot, and needs a person.
//
// Reporting the difference is the whole value. A flat list of 243 names tells
// an operator nothing about which of them a single unattended pass would fix.

import Foundation

/// One node claiming a match it cannot prove.
public struct IdentityGap: Equatable, Sendable, Identifiable {
    public let nodeId: String
    /// 🚨 Optional, because a row whose `entity_type` was never written has no
    /// kind — and those are exactly the rows worth reporting. This used to be
    /// non-optional, so the audit DROPPED them and told the operator the
    /// library was clean while holding broken records.
    public let kind: GraphNodeKind?
    /// Videos crediting this node, across both representations.
    public let videoCount: Int
    /// ...of which are themselves matched, and so could hand an identity down.
    public let matchedVideoCount: Int

    public var id: String { nodeId }

    /// ⚠️ STORED. Derived from the id, this returned a chopped-up uid on every
    /// re-keyed library — and it is both what the worklist shows and what the
    /// list sorts by.
    public let displayName: String

    /// ⭐ Whether `Refresh Matched Videos` would reach this one.
    ///
    /// A matched video's source record links to the confirmed profiles of its
    /// cast, so refreshing it hands those identities down. With no matched
    /// video crediting this node there is nothing to refresh and no link to
    /// follow.
    public var isRecoverableByRefresh: Bool { matchedVideoCount > 0 }

    /// ⚠️ The node has no kind and no name of its own — it renders as its own
    /// uid. Not a missing identity in the ordinary sense: the record itself is
    /// damaged, and matching it again just repeats the cycle.
    public var isDamaged: Bool { kind == nil }

    public init(nodeId: String, kind: GraphNodeKind?,
                videoCount: Int, matchedVideoCount: Int,
                displayName: String? = nil) {
        self.nodeId = nodeId
        self.kind = kind
        // ⚠️ Falls back to the id rather than to nothing. A damaged row has no
        // name to show, and a blank line is one nobody can act on.
        self.displayName = displayName
            ?? kind.flatMap { k in
                nodeId.hasPrefix(k.prefix) ? String(nodeId.dropFirst(k.prefix.count)) : nil
            }
            ?? nodeId
        self.videoCount = videoCount
        self.matchedVideoCount = matchedVideoCount
    }
}

/// What the audit found, already sorted into the two piles that differ in what
/// the operator should do about them.
public struct IdentityGapReport: Equatable, Sendable {
    public let gaps: [IdentityGap]

    public init(gaps: [IdentityGap]) { self.gaps = gaps }

    /// A single unattended pass fixes these.
    public var recoverable: [IdentityGap] { gaps.filter(\.isRecoverableByRefresh) }
    /// ⚠️ These need a person: nothing links to them from a matched video.
    public var needsAPerson: [IdentityGap] { gaps.filter { !$0.isRecoverableByRefresh } }

    public func of(_ kind: GraphNodeKind) -> [IdentityGap] {
        gaps.filter { $0.kind == kind }
    }

    public var isEmpty: Bool { gaps.isEmpty }

    /// What to say at the top, which differs by more than a number.
    public var headline: String {
        if gaps.isEmpty {
            return "Every matched record carries an identity."
        }
        let r = recoverable.count, n = needsAPerson.count
        if n == 0 {
            return "\(r) record\(r == 1 ? "" : "s") can be recovered by refreshing the videos they appear in."
        }
        if r == 0 {
            return "\(n) record\(n == 1 ? "" : "s") claim a match with nothing to look it up by, and no matched video links to them."
        }
        return "\(r) can be recovered automatically; \(n) need you."
    }
}

public enum IdentityGapAudit {

    public struct Input: Sendable {
        /// Nodes claiming `matched` with no identity edge, each carrying its
        /// kind and name rather than leaving them to be guessed from the id.
        public let missing: [ProfileRef]
        /// Videos crediting each node, by node id.
        public let videosByNode: [String: Int]
        /// ...of which are matched.
        public let matchedVideosByNode: [String: Int]

        public init(missing: [ProfileRef], videosByNode: [String: Int],
                    matchedVideosByNode: [String: Int]) {
            self.missing = missing
            self.videosByNode = videosByNode
            self.matchedVideosByNode = matchedVideosByNode
        }
    }

    /// ⚠️ Recoverable ones come FIRST, and within each pile the most-credited
    /// come first. An operator working down the list should meet the ones a
    /// single pass would fix before the ones costing a lookup each — and among
    /// those needing a person, the ones appearing in most videos matter most.
    public static func report(_ input: Input) -> IdentityGapReport {
        let gaps = input.missing.compactMap { ref -> IdentityGap? in
            // 🚨 A uid-keyed row with no columns is DAMAGED, and reported.
            // It used to be skipped alongside genuinely foreign ids, so the
            // audit stayed silent about the most broken thing it could find.
            //
            // ⚠️ Narrowly: only a UUID-shaped id qualifies. That is precisely
            // what this build mints, so a row carrying one and no columns is
            // ours and unfinished. `tag:blonde` or any other shape this build
            // does not manage is still skipped rather than guessed at — the
            // property `testAnUnrecognisedIdIsIgnored` protects.
            guard ref.kind != nil || UUID(uuidString: ref.id) != nil else { return nil }
            let id = ref.id
            return IdentityGap(nodeId: id, kind: ref.kind,
                               videoCount: input.videosByNode[id] ?? 0,
                               matchedVideoCount: input.matchedVideosByNode[id] ?? 0,
                               displayName: ref.name ?? id)
        }
        .sorted {
            // Damaged first: an ordinary gap is fixed by matching, this one is
            // not, and burying it under a hundred routine rows is how it stays
            // unfixed.
            if $0.isDamaged != $1.isDamaged { return $0.isDamaged }
            if $0.isRecoverableByRefresh != $1.isRecoverableByRefresh {
                return $0.isRecoverableByRefresh
            }
            if $0.videoCount != $1.videoCount { return $0.videoCount > $1.videoCount }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                == .orderedAscending
        }
        return IdentityGapReport(gaps: gaps)
    }
}
