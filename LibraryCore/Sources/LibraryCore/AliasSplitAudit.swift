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
// performer, and the library really does contain such a case: one alias listed
// against two separate profiles. Nothing here merges anything; it assembles the
// evidence and hands it to a person.
//
// 🚨 The names below (`Corvyn`, `Halloway Pike`, `Sable Quintero`) are INVENTED
// stand-ins for that case, and must stay invented. This repository is public;
// the shape is what documents the behaviour, and the real names document
// nothing that these do not. Do not "restore" them for fidelity.

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

        /// 🚨 Carried, not derived. It used to be sliced off the id, which
        /// stops working the moment an id is a uid — and this string is what
        /// the merge screen puts on its buttons, so it would offer "Keep
        /// 9F3C-…" instead of a person's name.
        public let displayName: String

        public init(id: String, displayName: String, videoCount: Int,
                    isMatched: Bool, birthYear: Int?) {
            self.id = id
            self.displayName = displayName
            self.videoCount = videoCount
            self.isMatched = isMatched
            self.birthYear = birthYear
        }
    }

    /// What supports this pair, and therefore how far to trust it.
    ///
    /// ⭐ D2 — the point is not more candidates, it is better-ranked ones. Alias
    /// overlap is a heuristic and produces false pairs; an upstream merge is a
    /// fact the source recorded. A pair carrying both is materially more
    /// certain than one carrying either.
    public enum Evidence: Int, Equatable, Sendable, Comparable {
        /// The source merged these two records AND their names overlap.
        case both = 0
        /// The source merged these two records.
        case upstreamMerge = 1
        /// One profile's name appears in the other's alias list.
        case aliasOverlap = 2

        public static func < (a: Evidence, b: Evidence) -> Bool {
            a.rawValue < b.rawValue
        }
    }

    /// The profile whose NAME appears in someone else's alias list.
    public let alias: Claimant
    /// Every profile listing that name as an alias, best-evidenced first.
    public let claimants: [Claimant]
    public let evidence: Evidence
    /// The claimant the SOURCE says survived, when it said so.
    public let upstreamSurvivorId: String?

    public var id: String { alias.id }

    /// ⚠️ More than one performer claims this name, so no merge can be
    /// suggested — only presented. This is the `Corvyn` case.
    ///
    /// ⭐ Unless the source already answered it. An upstream merge names WHICH
    /// record survived, which is exactly the question the alias heuristic
    /// cannot answer — so a pair the source settled is not ambiguous, however
    /// many profiles claim the name.
    public var isAmbiguous: Bool {
        if upstreamSurvivorId != nil { return false }
        return claimants.count > 1
    }

    /// The single obvious answer, or nil when a person has to choose.
    ///
    /// 🚨 M4 — when the source named a survivor, that is the one returned, even
    /// where it is not the best-evidenced claimant by the local heuristic.
    /// Returning the other would propose merging the survivor into the ghost.
    public var unambiguousClaimant: Claimant? {
        if let upstreamSurvivorId,
           let named = claimants.first(where: { $0.id == upstreamSurvivorId }) {
            return named
        }
        return isAmbiguous ? nil : claimants.first
    }

    /// How many videos would be brought together by merging.
    public var combinedVideos: Int {
        alias.videoCount + (claimants.first?.videoCount ?? 0)
    }

    /// ⭐ Defaults preserve the pre-#17 behaviour exactly, so every existing
    /// caller and test reads as "alias overlap, nothing from the source".
    public init(alias: Claimant, claimants: [Claimant],
                evidence: Evidence = .aliasOverlap,
                upstreamSurvivorId: String? = nil) {
        self.alias = alias
        self.claimants = claimants
        self.evidence = evidence
        self.upstreamSurvivorId = upstreamSurvivorId
    }
}

public enum AliasSplitAudit {

    public struct Input: Sendable {
        /// Every actor profile: its id, its alias list, and what is known of it.
        public let profiles: [(id: String, name: String, akas: [String], isMatched: Bool, birthYear: Int?)]
        /// Videos per profile id.
        public let videoCounts: [String: Int]

        /// Losing profile id → surviving profile id, where the SOURCE has
        /// already merged the two records. From `UpstreamMergeAudit`.
        ///
        /// ⭐ Empty is the pre-existing behaviour: alias overlap alone. A
        /// library that has never run a lookup keeps working unchanged.
        public let upstreamMerges: [String: String]

        public init(profiles: [(id: String, name: String, akas: [String], isMatched: Bool, birthYear: Int?)],
                    videoCounts: [String: Int],
                    upstreamMerges: [String: String] = [:]) {
            self.profiles = profiles
            self.videoCounts = videoCounts
            self.upstreamMerges = upstreamMerges
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
            byName[fold(profile.name)] = profile.id
        }

        func claimant(_ id: String) -> AliasSplitCandidate.Claimant? {
            guard let p = input.profiles.first(where: { $0.id == id }) else { return nil }
            return .init(id: id, displayName: p.name,
                         videoCount: input.videoCounts[id] ?? 0,
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

        var candidates = claims.compactMap { aliasId, claimantIds -> AliasSplitCandidate? in
            guard let alias = claimant(aliasId) else { return nil }
            let found = claimantIds.compactMap(claimant)
                // Most-evidenced first: a confirmed profile with a filmography
                // is a likelier home than an empty unmatched one.
                .sorted {
                    $0.isMatched != $1.isMatched ? $0.isMatched : $0.videoCount > $1.videoCount
                }
            guard !found.isEmpty else { return nil }

            // ⭐ The source agrees with the alias reading: same pair, same
            // direction. This is the strongest thing the audit can produce.
            if let survivor = input.upstreamMerges[aliasId],
               found.contains(where: { $0.id == survivor }) {
                return AliasSplitCandidate(alias: alias, claimants: found,
                                           evidence: .both, upstreamSurvivorId: survivor)
            }
            return AliasSplitCandidate(alias: alias, claimants: found)
        }

        // Pairs the source merged that the alias heuristic did not find — or
        // found pointing the OTHER WAY.
        //
        // 🚨 Direction disagreement is emitted separately rather than folded
        // into the alias candidate. The model puts the profile being folded in
        // the `alias` slot, so a candidate cannot express "merge the claimant
        // into the alias" — silently reusing the alias reading would propose
        // the merge backwards, which is the one thing M4 forbids. Two rows for
        // one pair is worth it: the operator sees the conflict, and the
        // source-backed row sorts first.
        let agreed = Set(candidates.filter { $0.evidence == .both }.map(\.alias.id))
        for (losing, surviving) in input.upstreamMerges where !agreed.contains(losing) {
            guard let alias = claimant(losing), let survivor = claimant(surviving) else { continue }
            candidates.append(AliasSplitCandidate(alias: alias, claimants: [survivor],
                                                  evidence: .upstreamMerge,
                                                  upstreamSurvivorId: surviving))
        }

        return candidates.sorted {
            // ⭐ Evidence first. D2's whole point: the ranking is the feature,
            // and a fact from the source outranks a name that merely overlaps.
            if $0.evidence != $1.evidence { return $0.evidence < $1.evidence }
            if $0.isAmbiguous != $1.isAmbiguous { return !$0.isAmbiguous }
            if $0.combinedVideos != $1.combinedVideos { return $0.combinedVideos > $1.combinedVideos }
            return $0.alias.displayName.localizedCaseInsensitiveCompare(
                $1.alias.displayName) == .orderedAscending
        }
    }
}
