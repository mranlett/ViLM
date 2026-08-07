// AliasSplitAudit.swift
// One performer recorded as two profiles, found by their own alias lists.
//
// 🚨 The damage the credited-name inversion caused. The video plugin used to
// prefer the name a performer was CREDITED under in a scene over their
// canonical name, so a performer who worked under three aliases became three
// profiles — each holding part of a filmography, none holding all of it, and
// nothing recording that they were one person.
//
// ⭐ The evidence is already in the data. When the library holds a profile
// named `Venlowe` AND a profile whose `akas` list contains "Venlowe", those two
// records are almost certainly the same person — and the second one says so
// itself. Measured on the drive library: 43 such pairs across 1,306 profiles.
//
// ⚠️ Almost certainly, not certainly. A short alias can belong to more than one
// performer — the real library has `Corvyn` listed as an alias of BOTH
// `Halloway Pike` and `Sable Quintero`. Nothing here merges anything; it assembles
// the evidence and hands it to a person.

import Foundation

/// One profile that looks like an alias of another, with everything needed to
/// judge it.
public struct AliasSplitCandidate: Equatable, Sendable, Identifiable {

    /// A profile claiming the alias, and what makes it plausible.
    public struct Claimant: Equatable, Sendable, Identifiable {
        public let id: String
        /// Videos filed under this profile.
        public let videoCount: Int
        /// Whether a lookup has confirmed this profile against a source.
        public let isMatched: Bool
        public let birthYear: Int?

        public var displayName: String {
            id.hasPrefix("actor:") ? String(id.dropFirst(6)) : id
        }

        public init(id: String, videoCount: Int, isMatched: Bool, birthYear: Int?) {
            self.id = id
            self.videoCount = videoCount
            self.isMatched = isMatched
            self.birthYear = birthYear
        }
    }

    /// The profile whose NAME appears in someone else's alias list.
    public let alias: Claimant
    /// Every profile listing that name as an alias, best-evidenced first.
    public let claimants: [Claimant]

    public var id: String { alias.id }

    /// ⚠️ More than one performer claims this name, so no merge can be
    /// suggested — only presented. This is the `Corvyn` case.
    public var isAmbiguous: Bool { claimants.count > 1 }

    /// The single obvious answer, or nil when a person has to choose.
    public var unambiguousClaimant: Claimant? {
        isAmbiguous ? nil : claimants.first
    }

    /// How many videos would be brought together by merging.
    public var combinedVideos: Int {
        alias.videoCount + (claimants.first?.videoCount ?? 0)
    }

    public init(alias: Claimant, claimants: [Claimant]) {
        self.alias = alias
        self.claimants = claimants
    }
}

public enum AliasSplitAudit {

    public struct Input: Sendable {
        /// Every actor profile: its id, its alias list, and what is known of it.
        public let profiles: [(id: String, akas: [String], isMatched: Bool, birthYear: Int?)]
        /// Videos per profile id.
        public let videoCounts: [String: Int]

        public init(profiles: [(id: String, akas: [String], isMatched: Bool, birthYear: Int?)],
                    videoCounts: [String: Int]) {
            self.profiles = profiles
            self.videoCounts = videoCounts
        }
    }

    /// Profiles whose name is recorded as an alias of a different profile.
    ///
    /// Unambiguous candidates come first — those are the ones a person can
    /// settle at a glance — then by how many videos a merge would reunite,
    /// since that is what makes one worth doing.
    public static func findings(_ input: Input) -> [AliasSplitCandidate] {
        func fold(_ value: String) -> String {
            TagNormalizer.identityKey(value)
        }

        // Folded name → profile id, so a case difference is not a second person.
        var byName: [String: String] = [:]
        for profile in input.profiles {
            let bare = profile.id.hasPrefix("actor:")
                ? String(profile.id.dropFirst(6)) : profile.id
            byName[fold(bare)] = profile.id
        }

        func claimant(_ id: String) -> AliasSplitCandidate.Claimant? {
            guard let p = input.profiles.first(where: { $0.id == id }) else { return nil }
            return .init(id: id, videoCount: input.videoCounts[id] ?? 0,
                         isMatched: p.isMatched, birthYear: p.birthYear)
        }

        // alias profile id → the profiles listing it
        var claims: [String: [String]] = [:]
        for profile in input.profiles {
            for aka in profile.akas {
                guard let aliasId = byName[fold(aka)], aliasId != profile.id else { continue }
                // ⚠️ De-duplicated: a profile listing the same alias twice, or
                // under two spellings, is one claim and not two.
                if claims[aliasId]?.contains(profile.id) != true {
                    claims[aliasId, default: []].append(profile.id)
                }
            }
        }

        return claims.compactMap { aliasId, claimantIds -> AliasSplitCandidate? in
            guard let alias = claimant(aliasId) else { return nil }
            let found = claimantIds.compactMap(claimant)
                // Most-evidenced first: a confirmed profile with a filmography
                // is a likelier home than an empty unmatched one.
                .sorted {
                    $0.isMatched != $1.isMatched ? $0.isMatched : $0.videoCount > $1.videoCount
                }
            guard !found.isEmpty else { return nil }
            return AliasSplitCandidate(alias: alias, claimants: found)
        }
        .sorted {
            if $0.isAmbiguous != $1.isAmbiguous { return !$0.isAmbiguous }
            if $0.combinedVideos != $1.combinedVideos { return $0.combinedVideos > $1.combinedVideos }
            return $0.alias.displayName.localizedCaseInsensitiveCompare(
                $1.alias.displayName) == .orderedAscending
        }
    }
}
