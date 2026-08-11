// SameIdentityAudit.swift
// Two local profiles, one source identity.
//
// ⭐ The strongest duplicate signal the library has, and the only one that
// needs no judgement. *Duplicate Performers* compares names against aliases —
// a heuristic, and one that misses a pair whose names differ only by a space.
// A source id is not a heuristic: the source has already decided these are one
// person, and two local rows claiming it are that person recorded twice.
//
// 🚨 It also reaches rows nothing else can. The `entityIdForWriting` defect
// minted shadow profiles with an id, a photo and a source id — but no name and
// no videos. They cannot be found by name, do not appear in the actor grid,
// and *Duplicate Performers* cannot see them because they have no name to
// compare. Their source id is the only handle on them that exists.
//
// ⚠️ Pure. Deciding what is duplicated is separable from merging, and only the
// deciding needs testing hard.

import Foundation
import GRDB

/// One source identity claimed by more than one local profile.
public struct SameIdentityFinding: Equatable, Sendable, Identifiable {

    public struct Member: Equatable, Sendable, Identifiable {
        public let id: String
        /// What a person reads. For a shadow row this is the uid itself.
        public let displayName: String
        public let videoCount: Int
        /// ⚠️ No name of its own — a row the identity defect left behind.
        public let isNameless: Bool
        public let hasPhoto: Bool

        public init(id: String, displayName: String, videoCount: Int,
                    isNameless: Bool, hasPhoto: Bool) {
            self.id = id
            self.displayName = displayName
            self.videoCount = videoCount
            self.isNameless = isNameless
            self.hasPhoto = hasPhoto
        }
    }

    public let sourceId: String
    /// Best candidate to keep FIRST. See `recommendedSurvivor`.
    public let members: [Member]

    public var id: String { sourceId }

    /// The row that should survive a merge.
    ///
    /// ⭐ A named row always beats a nameless one, whatever else is true: the
    /// nameless row cannot be found, browsed or displayed, so keeping it would
    /// throw away the only usable identity in the group.
    public var recommendedSurvivor: Member? { members.first }

    /// ⚠️ True when every member is nameless. Nothing here can be merged into
    /// a usable node, so the group needs a different remedy — reported rather
    /// than silently skipped.
    public var isEntirelyNameless: Bool { members.allSatisfy(\.isNameless) }

    /// ⭐ Safe to apply without asking: exactly one member has a name, so
    /// there is no question of which spelling the operator wanted.
    public var isUnambiguous: Bool {
        members.filter { !$0.isNameless }.count == 1
    }
}

public enum SameIdentityAudit {

    /// - Parameter videoCounts: profile id → videos crediting it.
    public static func findings(profiles: [EntityProfile],
                                videoCounts: [String: Int]) -> [SameIdentityFinding] {
        var groups: [String: [EntityProfile]] = [:]
        for profile in profiles {
            guard let sid = profile.enrichmentSourceId, !sid.isEmpty else { continue }
            // 🚨 Grouped by the source id ALONE, never by kind-and-id. A shadow
            // row has no `entity_type` — that is what makes it a shadow — so
            // keying on the kind silently excluded exactly the rows this audit
            // exists to reach. Caught by its own tests.
            groups[sid, default: []].append(profile)
        }

        return groups.compactMap { sourceId, members -> SameIdentityFinding? in
            guard members.count > 1 else { return nil }
            // ⚠️ The cross-kind guard, applied to the group instead. An actor
            // and a studio could carry the same opaque id from different
            // endpoints, and merging across kinds is far worse than missing a
            // duplicate. A member with no kind joins whatever the named ones
            // are.
            guard Set(members.compactMap(\.type)).count <= 1 else { return nil }

            let ranked = members
                .map { profile -> SameIdentityFinding.Member in
                    let nameless = (profile.displayName ?? "").isEmpty
                    return .init(id: profile.id,
                                 displayName: profile.name,
                                 videoCount: videoCounts[profile.id] ?? 0,
                                 isNameless: nameless,
                                 hasPhoto: !(profile.photoUrl ?? "").isEmpty)
                }
                // Named first, then the one carrying the most videos, then the
                // id — so the recommendation never depends on load order.
                .sorted {
                    if $0.isNameless != $1.isNameless { return !$0.isNameless }
                    if $0.videoCount != $1.videoCount { return $0.videoCount > $1.videoCount }
                    return $0.id < $1.id
                }

            return SameIdentityFinding(sourceId: sourceId, members: ranked)
        }
        // Unambiguous groups first: they can be cleared in one tap, where a
        // pair of named profiles needs the operator to choose a spelling.
        .sorted {
            if $0.isUnambiguous != $1.isUnambiguous { return $0.isUnambiguous }
            return $0.members.first?.displayName.localizedStandardCompare(
                $1.members.first?.displayName ?? "") == .orderedAscending
        }
    }

    /// What to say at the top, which differs by more than a count.
    public static func headline(_ findings: [SameIdentityFinding]) -> String {
        guard !findings.isEmpty else {
            return "No two profiles claim the same identity at the source."
        }
        let clear = findings.filter(\.isUnambiguous).count
        let needsChoice = findings.count - clear
        var parts: [String] = []
        if clear > 0 {
            parts.append("\(clear) can be merged without a decision")
        }
        if needsChoice > 0 {
            parts.append("\(needsChoice) need\(needsChoice == 1 ? "s" : "") you to pick a name")
        }
        return parts.joined(separator: "; ") + "."
    }
}

public extension LibraryStore {

    /// Profiles that claim the same source identity as another.
    func sameIdentityFindings() throws -> [SameIdentityFinding] {
        let profiles = try fetchAllEntityProfiles()
        let index = EntityProfileIndex(profiles)
        let counts = ActorVideoCounts.build(assets: try fetchAllAssets(), profiles: index)

        // ⚠️ `ActorVideoCounts` is keyed by NAME, and a shadow row has none —
        // so it would report zero for exactly the rows this audit is for. That
        // is correct here (they genuinely have no videos), but the mapping has
        // to go through the name rather than assume the id is one.
        var byId: [String: Int] = [:]
        for profile in profiles where !(profile.displayName ?? "").isEmpty {
            byId[profile.id] = counts[profile.name] ?? 0
        }
        return SameIdentityAudit.findings(profiles: profiles, videoCounts: byId)
    }

    /// Folds one profile into another that shares its source identity.
    ///
    /// ⭐ Uses `MergeSemantics.mergedProfileView`, the project's single
    /// expression of "higher wins, lower fills gaps, lists union" — rather than
    /// a second field list that would drift from it.
    ///
    /// 🚨 Everything the loser has moves before it goes: its videos, its
    /// aliases, and its NAME as an alias of the survivor, so a later import
    /// naming the old spelling still resolves to the right person.
    func mergeSameIdentity(losing losingId: String, into survivingId: String) throws {
        guard losingId != survivingId else { return }
        guard var surviving = try fetchEntityProfile(for: survivingId),
              let losing = try fetchEntityProfile(for: losingId) else { return }

        // The survivor keeps its own identity; the loser fills gaps.
        surviving = MergeSemantics.mergedProfileView(higher: surviving, lower: losing)

        // ⚠️ The loser's NAME becomes an alias, but only when it had one and it
        // differs. A uid is not an alias anybody will ever search for.
        if let losingName = losing.displayName, !losingName.isEmpty,
           losingName.caseInsensitiveCompare(surviving.name) != .orderedSame,
           !surviving.akas.contains(where: { $0.caseInsensitiveCompare(losingName) == .orderedSame }) {
            surviving.akas.append(losingName)
        }

        try dbQueue.write { db in
            try surviving.update(db)
            // Edges move rather than being deleted with the row.
            try db.execute(sql: """
                UPDATE OR IGNORE video_performer SET performer_id = ? WHERE performer_id = ?
                """, arguments: [survivingId, losingId])
            try db.execute(sql: "DELETE FROM video_performer WHERE performer_id = ?",
                           arguments: [losingId])
            try db.execute(sql: "DELETE FROM entity_match WHERE entity_id = ?",
                           arguments: [losingId])
            try db.execute(sql: "DELETE FROM entity_profiles WHERE id = ?", arguments: [losingId])
        }
    }
}
