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

    /// The kind a profile id belongs to, or nil for anything unrecognised.
    ///
    /// ⚠️ nil is deliberately NOT treated as deletable. An id shape this build
    /// does not know is a reason to leave it alone, not a reason to remove it.
    public static func of(_ id: String) -> GraphNodeKind? {
        allCases.first { id.hasPrefix($0.prefix) }
    }
}

/// One profile nothing refers to.
public struct OrphanFinding: Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: GraphNodeKind

    /// The name as a person reads it.
    public var displayName: String {
        String(id.dropFirst(kind.prefix.count))
    }

    public init(id: String, kind: GraphNodeKind) {
        self.id = id
        self.kind = kind
    }
}

public enum OrphanAudit {

    /// Everything the audit needs, so the rule is pure and testable.
    public struct Input: Sendable {
        /// Every profile in the library.
        public let profiles: [String]
        /// Every `actor:`/`studio:` string carried on a video.
        public let referencedByString: Set<String>
        /// Performer ids reachable through a `video_performer` edge.
        public let performersWithEdges: Set<String>
        /// Studio ids reachable through a `video_studio` edge.
        public let studiosWithEdges: Set<String>
        /// Studio ids that are the PARENT of at least one other studio.
        public let studiosWithChildren: Set<String>

        public init(profiles: [String],
                    referencedByString: Set<String>,
                    performersWithEdges: Set<String> = [],
                    studiosWithEdges: Set<String> = [],
                    studiosWithChildren: Set<String> = []) {
            self.profiles = profiles
            self.referencedByString = referencedByString
            self.performersWithEdges = performersWithEdges
            self.studiosWithEdges = studiosWithEdges
            self.studiosWithChildren = studiosWithChildren
        }
    }

    /// Orphans, by node kind.
    ///
    /// A profile is an orphan only when **nothing at all** points at it: no tag
    /// string, no edge, and — for a studio — no imprint beneath it.
    public static func findings(_ input: Input) -> [GraphNodeKind: [OrphanFinding]] {
        var out: [GraphNodeKind: [OrphanFinding]] = [:]

        for id in input.profiles {
            guard let kind = GraphNodeKind.of(id) else { continue }
            if input.referencedByString.contains(id) { continue }

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
            }

            out[kind, default: []].append(OrphanFinding(id: id, kind: kind))
        }

        for kind in out.keys {
            out[kind]?.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }
        return out
    }
}
