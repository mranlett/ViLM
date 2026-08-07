// StudioLineage.swift
// A studio's place in the hierarchy: its network, its imprints, and the other
// imprints of the same network.
//
// This is the one relationship a studio genuinely owns. An actor profile
// answers "who is this person"; a studio profile has almost nothing to say
// about a company except who owns it and what it owns — which is why the actor
// page, reused for studios, showed a birth date and no lineage at all.
//
// Pure, like the rest of the graph logic: it takes the edges and the counts and
// arranges them. `LibraryStore` gathers.

import Foundation

/// One period during which a studio belonged to a network.
///
/// ⚠️ `from == nil` means "as far back as we know", not "never". Every row the
/// temporal migration created carries nil, because the hierarchy was recorded
/// before anyone could say when it began.
public struct StudioParentPeriod: Equatable, Sendable, Identifiable {
    public let parentId: String
    public let from: String?
    public let to: String?

    public var id: String { "\(parentId)|\(from ?? "")|\(to ?? "")" }
    public var isCurrent: Bool { to == nil }

    public var parentName: String { StudioLineage.displayName(parentId) }

    /// How to phrase the period. Deliberately says nothing it does not know —
    /// an unknown start reads as plain ownership rather than inventing a date.
    public var displayText: String {
        switch (from, to) {
        case let (start?, nil):   return "\(parentName) since \(start)"
        case let (start?, end?):  return "\(parentName) \(start)–\(end)"
        case let (nil, end?):     return "\(parentName) until \(end)"
        case (nil, nil):          return parentName
        }
    }

    public init(parentId: String, from: String?, to: String?) {
        self.parentId = parentId
        self.from = from
        self.to = to
    }
}

public struct StudioLineage: Equatable, Sendable {

    /// A studio adjacent to this one, with enough to render a row.
    public struct Relative: Equatable, Sendable, Identifiable {
        /// The display name, not the node id — this is what a pivot filters on
        /// and what the grid files under.
        public let name: String
        public let videoCount: Int

        public var id: String { name }

        public init(name: String, videoCount: Int) {
            self.name = name
            self.videoCount = videoCount
        }
    }

    /// The network that owns this studio.
    public let parent: Relative?
    /// The other imprints of that network. Empty when there is no network, or
    /// when this is its only imprint.
    public let siblings: [Relative]
    /// The imprints this studio owns — one level down, not the whole tree.
    public let children: [Relative]

    /// Whether there is anything to show.
    ///
    /// ⚠️ The page must ask this rather than rendering three empty groups. With
    /// `studio_parent` unpopulated this is true for every studio in the
    /// library, so the empty case is the common one, not the edge case.
    public var isEmpty: Bool {
        parent == nil && siblings.isEmpty && children.isEmpty
    }

    public init(parent: Relative?, siblings: [Relative], children: [Relative]) {
        self.parent = parent
        self.siblings = siblings
        self.children = children
    }

    /// Arranges the edges around one studio.
    ///
    /// - Parameters:
    ///   - studioId: the node id, `studio:Name`.
    ///   - pairs: every `studio_parent` edge; `from` is the imprint, `to` the network.
    ///   - videoCounts: videos per studio node id.
    public static func build(for studioId: String,
                             pairs: [GraphEdgePair],
                             videoCounts: [String: Int]) -> StudioLineage {
        var parentOf: [String: String] = [:]
        var childrenOf: [String: [String]] = [:]
        for pair in pairs {
            parentOf[pair.from] = pair.to
            childrenOf[pair.to, default: []].append(pair.from)
        }

        func relative(_ id: String) -> Relative {
            Relative(name: displayName(id), videoCount: videoCounts[id] ?? 0)
        }

        let parentId = parentOf[studioId]

        // ⚠️ Excludes this studio. A network's other imprints are its siblings;
        // listing the studio you are already looking at as its own sibling is
        // the kind of thing that makes a page look broken.
        let siblings = (parentId.flatMap { childrenOf[$0] } ?? [])
            .filter { $0 != studioId }
            .map(relative)
            .sorted(by: byNameDescendingCount)

        let children = (childrenOf[studioId] ?? [])
            .map(relative)
            .sorted(by: byNameDescendingCount)

        return StudioLineage(parent: parentId.map(relative),
                             siblings: siblings,
                             children: children)
    }

    /// Busiest first, then alphabetical — the imprint carrying the most of the
    /// library is the one worth seeing, and ties order predictably rather than
    /// by whatever the table returned.
    private static func byNameDescendingCount(_ a: Relative, _ b: Relative) -> Bool {
        a.videoCount != b.videoCount ? a.videoCount > b.videoCount : a.name < b.name
    }

    static func displayName(_ id: String) -> String {
        id.hasPrefix("studio:") ? String(id.dropFirst(7)) : id
    }
}

/// Splits a network's videos by which studio in the family released them.
///
/// The graph's answer to "show me this network's catalogue": one list would
/// merge an imprint's releases into its parent's and lose the distinction the
/// hierarchy exists to record. Separated, the page says both things at once —
/// everything the family put out, and who put out what.
///
/// Pure and here rather than in the view for the usual reason: the ordering and
/// the two-studio rule below are decisions, and decisions belong somewhere they
/// can be tested.
public enum StudioFamilyGrouping {

    public struct Section: Equatable, Sendable, Identifiable {
        public let studio: String
        public let assets: [Asset]

        public var id: String { studio }

        public init(studio: String, assets: [Asset]) {
            self.studio = studio
            self.assets = assets
        }
    }

    /// - Parameters:
    ///   - assets: the videos already filtered to this family.
    ///   - root: the studio whose page this is.
    ///   - family: every studio name in the family, root included.
    public static func sections(assets: [Asset],
                                root: String,
                                family: Set<String>) -> [Section] {
        var buckets: [String: [Asset]] = [:]
        for asset in assets {
            // ⚠️ The studio that put it in this family — not `studios.first`.
            // A video carrying two studios is a known defect, and picking
            // blindly would file it under a studio that is not in this family
            // at all, dropping it from a page it belongs on.
            guard let studio = asset.studios.first(where: { family.contains($0) })
            else { continue }
            buckets[studio, default: []].append(asset)
        }

        // The root leads even when an imprint carries more — it is the page you
        // are on. Imprints follow busiest-first, matching how the lineage block
        // orders them, so the two readings of the hierarchy agree.
        let imprints = buckets.keys.filter { $0 != root }
            .sorted {
                let a = buckets[$0]?.count ?? 0, b = buckets[$1]?.count ?? 0
                return a != b ? a > b : $0 < $1
            }

        return ([root] + imprints).compactMap { name in
            guard let found = buckets[name], !found.isEmpty else { return nil }
            return Section(studio: name, assets: found)
        }
    }
}
