// StudioHierarchyPlan.swift
// What arrives when you ask a network for its imprints, and what to do with it.
//
// 🚨 A PLAN, NOT A WRITE. Every rule the spec argues about lives here as a pure
// function so it can be tested without a database and read without a source:
// which imprints already exist, which would close a cycle, which parent the
// operator set by hand, and which aliases are candidates rather than merges.
//
// ⭐ Why it exists at all: reading a studio's `parent` alone discovers a
// network's imprints ONE MATCHED VIDEO AT A TIME. 115 hierarchy rows
// accumulated that way. The source can answer the whole question in one
// request.

import Foundation

/// A studio the library already holds, as the planner needs to see it.
public struct LocalStudio: Equatable, Sendable {
    public let id: String
    public let name: String
    /// The source's id for it, when it carries a confirmed match.
    public let sourceId: String?
    /// Its current parent, and whether a person chose it.
    public let parentId: String?
    /// 🚨 D4 — a parent the operator set by hand is never re-pointed by the
    /// source. Evidence does not overwrite a statement, here as everywhere.
    public let parentWasHandSet: Bool
    /// Whether the library holds any video from this studio.
    public let hasVideos: Bool

    public init(id: String, name: String, sourceId: String? = nil,
                parentId: String? = nil, parentWasHandSet: Bool = false,
                hasVideos: Bool = true) {
        self.id = id
        self.name = name
        self.sourceId = sourceId
        self.parentId = parentId
        self.parentWasHandSet = parentWasHandSet
        self.hasVideos = hasVideos
    }
}

/// One imprint that would be filed under the network.
public struct PlannedImprint: Equatable, Sendable, Identifiable {
    public let ref: StudioRef
    /// The local studio it resolved to, or nil when it would be created.
    public let localId: String?
    /// 🚨 Derived, never stored. "The library owns nothing from this" becomes
    /// false by itself the moment a video arrives, so recording it as a state
    /// would leave a mark nobody knows to clear.
    public let ownsNoVideos: Bool

    public var id: String { ref.sourceId }
}

public struct StudioHierarchyPlan: Equatable, Sendable {
    /// Held locally, and would be filed under the network.
    public var link: [PlannedImprint] = []
    /// Not held locally. Created AND MARKED — the operator's decision, so the
    /// hierarchy is complete and an imprint they own nothing from is still
    /// visibly distinct from one they do.
    public var create: [PlannedImprint] = []
    /// 🚨 Refused because the link would close a loop, with the chain named so
    /// the message can say WHICH one.
    public var cycles: [(imprint: StudioRef, chain: [String])] = []
    /// Already filed correctly. H6 — fetching twice adds nothing.
    public var unchanged: [StudioRef] = []
    /// 🔴 D4 — a hand-set parent that the source disagrees with. Left exactly
    /// as it is, and SAID, because silently keeping it looks identical to
    /// silently ignoring the source.
    public var handSetKept: [StudioRef] = []

    public var isEmpty: Bool {
        link.isEmpty && create.isEmpty && cycles.isEmpty && handSetKept.isEmpty
    }

    public static func == (a: StudioHierarchyPlan, b: StudioHierarchyPlan) -> Bool {
        a.link == b.link && a.create == b.create && a.unchanged == b.unchanged
            && a.handSetKept == b.handSetKept
            && a.cycles.map(\.imprint) == b.cycles.map(\.imprint)
            && a.cycles.map(\.chain) == b.cycles.map(\.chain)
    }
}

/// What a studio's aliases mean for the library.
///
/// 🔴 D3/H5 — CANDIDATES FOR REVIEW, never an automatic merge. Merging two
/// studios re-points every video and every hierarchy row beneath them, and no
/// alias is worth doing that unasked.
public struct StudioAliasPlan: Equatable, Sendable {
    /// An alias naming a studio the library holds separately — offered to Fix
    /// Duplicate Studios.
    public var candidates: [(alias: String, localId: String)] = []
    /// 🚨 H8 — an alias naming nothing local. Reported, and creates NOTHING: an
    /// alias is a spelling, not an entity, and minting a studio from one would
    /// fill the list with names that describe no record.
    public var unmatched: [String] = []

    public static func == (a: StudioAliasPlan, b: StudioAliasPlan) -> Bool {
        a.candidates.map(\.alias) == b.candidates.map(\.alias)
            && a.candidates.map(\.localId) == b.candidates.map(\.localId)
            && a.unmatched == b.unmatched
    }
}

public enum StudioHierarchy {

    /// Resolves an arriving imprint against what the library already holds.
    ///
    /// 🚨 BY IDENTITY FIRST (H7). Matching on name would create a duplicate
    /// whenever the operator has renamed a studio locally: the source's
    /// spelling and theirs become two rows for one studio.
    ///
    /// ⚠️ Name is the fallback and ONLY for a local studio carrying no source
    /// id. A studio that already holds a different identity is not this one, no
    /// matter how the names read — that is a disagreement to report, not a
    /// match to assume.
    static func resolve(_ ref: StudioRef, in local: [LocalStudio]) -> LocalStudio? {
        if let byIdentity = local.first(where: { $0.sourceId == ref.sourceId }) {
            return byIdentity
        }
        return local.first {
            $0.sourceId == nil
                && $0.name.caseInsensitiveCompare(ref.name) == .orderedSame
        }
    }

    /// What filing these imprints under `network` would do.
    ///
    /// - Parameters:
    ///   - networkLocalId: the local studio the imprints belong under.
    ///   - arriving: what the source says its imprints are.
    ///   - local: every studio the library holds.
    ///   - parentOf: the current parent chain lookup, used to refuse cycles.
    public static func plan(network networkLocalId: String,
                            arriving: [StudioRef],
                            local: [LocalStudio],
                            parentOf: (String) -> String?) -> StudioHierarchyPlan {
        var plan = StudioHierarchyPlan()

        for ref in arriving {
            let resolved = resolve(ref, in: local)

            // 🚨 D2 — a studio may not become its own ancestor. The chain is
            // carried so the refusal can name which loop closed rather than
            // saying "cycle" and leaving the operator to find it.
            if let resolved, let chain = ancestryLoop(child: resolved.id,
                                                     newParent: networkLocalId,
                                                     parentOf: parentOf, local: local) {
                plan.cycles.append((imprint: ref, chain: chain))
                continue
            }

            guard let resolved else {
                // Not held. Created and marked — and it owns no videos by
                // definition, since it did not exist a moment ago.
                plan.create.append(PlannedImprint(ref: ref, localId: nil, ownsNoVideos: true))
                continue
            }

            if resolved.parentId == networkLocalId {
                plan.unchanged.append(ref)
                continue
            }

            // 🔴 D4 — a hand-set parent wins, even a hand-set NIL is not one:
            // the flag marks a parent someone chose, and there is no parent to
            // have chosen when there is none.
            if resolved.parentWasHandSet, resolved.parentId != nil {
                plan.handSetKept.append(ref)
                continue
            }

            plan.link.append(PlannedImprint(ref: ref, localId: resolved.id,
                                            ownsNoVideos: !resolved.hasVideos))
        }

        return plan
    }

    /// The chain that would close, or nil when the link is safe.
    private static func ancestryLoop(child: String, newParent: String,
                                     parentOf: (String) -> String?,
                                     local: [LocalStudio]) -> [String]? {
        func name(_ id: String) -> String {
            local.first { $0.id == id }?.name ?? id
        }
        // A studio under itself is the shortest loop there is.
        if child == newParent { return [name(child), name(child)] }

        var chain = [name(newParent)]
        var seen: Set<String> = [newParent]
        var cursor: String? = parentOf(newParent)
        while let current = cursor {
            chain.append(name(current))
            if current == child { return chain + [name(newParent)] }
            // A pre-existing loop above us is not this link's fault, but
            // walking it forever would be.
            if seen.contains(current) { return nil }
            seen.insert(current)
            cursor = parentOf(current)
        }
        return nil
    }

    /// What a studio's aliases offer.
    public static func aliasPlan(_ aliases: [String], for studioLocalId: String,
                                 local: [LocalStudio]) -> StudioAliasPlan {
        var plan = StudioAliasPlan()
        for alias in aliases {
            let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // An alias naming the studio it belongs to is not a duplicate.
            guard let other = local.first(where: {
                $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
            }), other.id != studioLocalId else {
                if !local.contains(where: {
                    $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
                }) {
                    plan.unmatched.append(trimmed)
                }
                continue
            }
            plan.candidates.append((alias: trimmed, localId: other.id))
        }
        return plan
    }
}
