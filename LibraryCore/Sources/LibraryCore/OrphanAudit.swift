// OrphanAudit.swift
// Profiles nothing refers to any more, grouped by what kind of node they are.
//
// 🚨 This exists because "Remove Orphaned Profiles" treated every node kind as
// one undifferentiated pile. It fetched every `EntityProfile`, kept the ones no
// video's tag string named, and offered a single "Delete All Orphans" — so
// clicking through from Studio Health, which had found an orphaned STUDIO,
// deleted orphaned actors as well. The operator asked for exactly the right
// thing: the node kinds are distinct, and each deserves its own health check
// and its own cleanup.
//
// Two of the old rules were also simply wrong now that edges exist:
//
//   🚨 A NETWORK with imprints was "orphaned". A network owning three labels
//      usually has no videos filed under its own name — that is what a network
//      IS — so the old check offered to delete the top of every hierarchy the
//      operator had built. The `studio_parent` cascade means the imprints
//      survive as roots, so the deletion is quiet: the hierarchy vanishes and
//      nothing says so.
//
//   🚨 An imprint the operator FILED under a network read as orphaned. See
//      the studio case below: the hierarchy is a reference, both ways.
//
//   ⚠️ Only tag STRINGS were consulted. An actor reachable through a
//      `video_performer` edge but not named in any tag array reads as orphaned,
//      which is precisely the state the string-retirement migration produces.

import Foundation

/// What kind of node a profile is.
public enum GraphNodeKind: String, Equatable, Sendable, CaseIterable {
    case actor
    case studio

    /// The id prefix this kind uses.
    public var prefix: String { "\(rawValue):" }

    public var singular: String { rawValue }
    public var plural: String { "\(rawValue)s" }

    /// The kind a `type:Name` STRING belongs to, or nil for anything
    /// unrecognised.
    ///
    /// ⚠️ For tag strings off a video — `asset.tags` — which keep the
    /// `type:Name` shape permanently. Do NOT call this on an
    /// `EntityProfile.id`: after the re-key an id is a uid and this answers
    /// nil for every profile in the library. Use `ProfileRef.kind`.
    ///
    /// ⚠️ nil is deliberately NOT treated as deletable. An id shape this build
    /// does not know is a reason to leave it alone, not a reason to remove it.
    public static func of(_ id: String) -> GraphNodeKind? {
        allCases.first { id.hasPrefix($0.prefix) }
    }
}

/// A profile reduced to the three things an audit needs to reason about it.
///
/// 🚨 An id alone is no longer enough, and both audits assumed it was. Each
/// derived a node's KIND with `id.hasPrefix("actor:")` and its NAME by chopping
/// that prefix off — true only while the id encodes the name. After the re-key
/// every id is a uid, so `GraphNodeKind.of` returned nil for all of them, every
/// profile was skipped, and both audits reported a perfectly healthy library
/// however much was wrong with it. A health check that cannot fail is worse
/// than no health check, because it is believed.
///
/// ⚠️ The name matters as much as the kind. `OrphanAudit` decides whether a
/// video refers to a node, and a video refers to it BY STRING — so the audit
/// has to be able to reconstruct that string. Fixing the kind alone would have
/// resolved every node and then matched none of them against the tag strings,
/// turning an inert audit into one proposing to delete the entire cast of the
/// library. `TagCleanupView` wires that straight to `deleteEntityProfile`.
public struct ProfileRef: Equatable, Sendable {
    public let id: String
    public let entityType: String?
    public let displayName: String?

    public init(id: String, entityType: String? = nil, displayName: String? = nil) {
        self.id = id
        self.entityType = entityType
        self.displayName = displayName
    }

    /// ⚠️ Columns first; the id shape is only a fallback, for a library that
    /// has not been re-keyed and for rows whose columns were never backfilled.
    public var kind: GraphNodeKind? {
        if let entityType, let kind = GraphNodeKind(rawValue: entityType) { return kind }
        return GraphNodeKind.of(id)
    }

    /// The name a person reads.
    public var name: String? {
        if let displayName, !displayName.isEmpty { return displayName }
        guard let kind, id.hasPrefix(kind.prefix) else { return nil }
        return String(id.dropFirst(kind.prefix.count))
    }

    /// The `type:Name` string a video's tag array would carry for this node —
    /// what the old code got for free by the id BEING that string.
    public var tagString: String? {
        guard let kind, let name else { return nil }
        return "\(kind.prefix)\(name)"
    }
}

/// One profile nothing refers to.
public struct OrphanFinding: Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: GraphNodeKind

    /// The name as a person reads it.
    ///
    /// ⚠️ STORED, not derived. Chopping the prefix off a uid produced a
    /// mangled fragment of it — and this is the text on a deletion
    /// confirmation, so an operator was being asked to approve the removal of
    /// something they could not identify.
    public let displayName: String

    public init(id: String, kind: GraphNodeKind, displayName: String? = nil) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
            ?? (id.hasPrefix(kind.prefix) ? String(id.dropFirst(kind.prefix.count)) : id)
    }
}

public enum OrphanAudit {

    /// Everything the audit needs, so the rule is pure and testable.
    public struct Input: Sendable {
        /// Every profile in the library, each carrying its kind and its name
        /// rather than leaving them to be guessed from the id.
        public let profiles: [ProfileRef]
        /// Every `actor:`/`studio:` string carried on a video.
        public let referencedByString: Set<String>
        /// Performer ids reachable through a `video_performer` edge.
        public let performersWithEdges: Set<String>
        /// Studio ids reachable through a `video_studio` edge.
        public let studiosWithEdges: Set<String>
        /// Studio ids that are the PARENT of at least one other studio.
        public let studiosWithChildren: Set<String>
        /// Studio ids filed BENEATH a network — the other half of the same
        /// fact, and the one that keeps a known-but-empty imprint alive.
        public let studiosWithParent: Set<String>

        public init(profiles: [ProfileRef],
                    referencedByString: Set<String>,
                    performersWithEdges: Set<String> = [],
                    studiosWithEdges: Set<String> = [],
                    studiosWithChildren: Set<String> = [],
                    studiosWithParent: Set<String> = []) {
            self.profiles = profiles
            self.referencedByString = referencedByString
            self.performersWithEdges = performersWithEdges
            self.studiosWithEdges = studiosWithEdges
            self.studiosWithChildren = studiosWithChildren
            self.studiosWithParent = studiosWithParent
        }
    }

    /// Orphans, by node kind.
    ///
    /// A profile is an orphan only when **nothing at all** points at it: no tag
    /// string, no edge, and — for a studio — no imprint beneath it.
    public static func findings(_ input: Input) -> [GraphNodeKind: [OrphanFinding]] {
        var out: [GraphNodeKind: [OrphanFinding]] = [:]

        // 🚨 Case-folded. The reference test used to be an exact string match,
        // which was safe only because both sides were literally the same
        // string — the id. Reconstructing it from `display_name` reintroduces
        // the possibility of a case difference between the profile and the tag
        // on the video, and on THIS path a miss means "orphan", which means
        // offered for deletion. Erring toward "something refers to it" is the
        // only acceptable direction for the error.
        let referenced = Set(input.referencedByString.map { $0.lowercased() })

        for ref in input.profiles {
            guard let kind = ref.kind else { continue }
            if let tag = ref.tagString, referenced.contains(tag.lowercased()) { continue }

            let id = ref.id

            switch kind {
            case .actor:
                // ⚠️ An edge counts. Once the migration retires the strings this
                // is the ONLY thing that will still point at a performer, and a
                // check reading strings alone would then propose deleting the
                // entire cast of the library.
                if input.performersWithEdges.contains(id) { continue }
            case .studio:
                if input.studiosWithEdges.contains(id) { continue }
                // 🚨 A network with imprints is not an orphan. Having no videos
                // of its own is the normal state of a parent company, and
                // deleting it discards a hierarchy the operator built — quietly,
                // because the cascade promotes the imprints to roots rather than
                // failing.
                if input.studiosWithChildren.contains(id) { continue }
                // 🚨 Nor is an imprint filed under one. Asking a network for
                // its imprints deliberately creates studios the library owns
                // no videos from — a leaf with no videos, no children and no
                // tag string is EXACTLY the shape this audit offers to delete,
                // so without this the next cleanup silently undoes the feature.
                //
                // ⭐ The rule is the mirror of the one above rather than a
                // special case for how the row arrived: participating in the
                // hierarchy at all, as parent or as child, is what makes a
                // studio referred to. A row that arrived some other way and
                // has a network is spared for the same honest reason.
                //
                // ⚠️ Removing one deliberately is still possible, and is the
                // tombstone's job — an explicit deletion, not a sweep.
                if input.studiosWithParent.contains(id) { continue }
            }

            out[kind, default: []].append(
                OrphanFinding(id: id, kind: kind, displayName: ref.name ?? id))
        }

        for kind in out.keys {
            out[kind]?.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }
        return out
    }
}
