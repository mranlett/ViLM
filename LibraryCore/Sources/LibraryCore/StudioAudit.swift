// StudioAudit.swift
// Everything wrong with the studios, in one place.
//
// Every condition here was already detectable before this existed. What was
// missing is a single answer to "are the studios in good shape", which
// otherwise means opening five screens and reading four counts — and two of
// these conditions had no surface at all, so nobody was reading them anywhere.
//
// ⚠️ This REPORTS and ROUTES. It does not fix.
//
// Every repair below already has a screen that does it carefully and asks the
// right question first. A validator that also repaired would be a second, less
// careful implementation of five existing tools, and the one most likely to be
// run without reading it. So each finding carries the screen that resolves it
// and nothing else.
//
// Pure, like `StudioConflictAudit` and `TagCaseAudit`: it takes what the
// library knows and returns what is wrong with it. `LibraryStore` gathers the
// inputs; nothing here opens a database or reaches a network.

import Foundation

/// The screen that resolves a finding.
///
/// Named rather than described so the core stays ignorant of the UI — the view
/// maps these to its own actions. `.none` is honest: two of these findings
/// have no repair tool yet, and saying so beats inventing a destination.
public enum StudioFix: String, Equatable, Sendable {
    case fixDuplicateStudios
    /// 🚨 NOT `repairTagSpelling`. That tool reads `Asset.actions`, which
    /// filters to `tag:` values — it never sees a `studio:` value, so routing
    /// studio collisions there sent the operator to a screen that could not
    /// fix them. Reported from the device, 2026-08-06.
    case repairStudioSpelling
    case connectTheGraph
    case matchStudios
    case matchAgain
    case removeOrphanedProfiles
    case none
}

/// One thing wrong with the studios, and how many times.
public struct StudioCheck: Equatable, Sendable, Identifiable {

    public enum Kind: String, Equatable, Sendable, CaseIterable {
        /// A video credited to more than one studio. Cannot be right: a scene
        /// has one releasing studio.
        case multiStudioVideo
        /// Two studios that differ only by case or spacing.
        case spellingCollision
        /// A studio in use with no profile row behind it.
        case missingProfile
        /// A studio nobody has confirmed against a source.
        case unconfirmed
        /// A studio string with no `video_studio` edge behind it.
        case missingEdge
        /// An edge that disagrees with the string it came from.
        case edgeDisagreement
        /// A studio profile no video uses.
        case orphanProfile
        /// A `studio_parent` row naming a studio with no profile.
        case danglingParent
        /// A studio beneath itself. Impossible through `setStudioParent`, and
        /// therefore evidence of a database edited by hand.
        case parentCycle
    }

    public let kind: Kind
    /// What is wrong, one line each, already in display form. Studio names, or
    /// a grouping like "Coast Line + Harbour Lane (12 videos)".
    public let items: [String]

    public var id: String { kind.rawValue }
    public var count: Int { items.count }

    public init(kind: Kind, items: [String]) {
        self.kind = kind
        self.items = items
    }

    /// Whether this is certainly wrong, or merely unfinished.
    ///
    /// The distinction matters because a library can sit indefinitely with
    /// unconfirmed studios and be fine, while a video carrying two studios is
    /// in a state no reading makes correct. Sorting the certain ones first
    /// means the list opens on what actually needs doing.
    public var isDefect: Bool {
        switch kind {
        case .multiStudioVideo, .spellingCollision, .missingEdge,
             .edgeDisagreement, .danglingParent, .parentCycle:
            return true
        case .unconfirmed, .missingProfile, .orphanProfile:
            return false
        }
    }

    public var fix: StudioFix {
        switch kind {
        case .multiStudioVideo:  return .fixDuplicateStudios
        case .spellingCollision: return .repairStudioSpelling
        case .missingProfile:    return .connectTheGraph
        case .unconfirmed:       return .matchStudios
        case .missingEdge:       return .connectTheGraph
        case .edgeDisagreement:  return .matchAgain
        case .orphanProfile:     return .removeOrphanedProfiles
        case .danglingParent:    return .none
        case .parentCycle:       return .none
        }
    }

    public var title: String {
        switch kind {
        case .multiStudioVideo:  return "Videos with two studios"
        case .spellingCollision: return "Studios spelled two ways"
        case .missingProfile:    return "Studios with no profile"
        case .unconfirmed:       return "Studios not yet confirmed"
        case .missingEdge:       return "Studios not connected to the graph"
        case .edgeDisagreement:  return "Edges that disagree with the tags"
        case .orphanProfile:     return "Studio profiles with no videos"
        case .danglingParent:    return "Networks with no profile"
        case .parentCycle:       return "A studio inside itself"
        }
    }

    /// Why it matters, in the operator's terms rather than the schema's.
    public var detail: String {
        switch kind {
        case .multiStudioVideo:
            return "A scene has one releasing studio, so these are in a state that cannot be right. Until they are resolved they get no studio edge at all — the graph refuses to guess which one."
        case .spellingCollision:
            return "The same studio stored under two spellings. The filters already fold case and spacing, so these are one studio everywhere it matters, and leaving them split shows two cards for one company."
        case .missingProfile:
            return "The name is on videos but nothing holds what is known about it — no logo, no links, and no way to record that it has been confirmed."
        case .unconfirmed:
            return "Nobody has checked these against a source. An unconfirmed studio cannot break a tie when a video offers both an imprint and its network, so each one is a question you will be asked later."
        case .missingEdge:
            return "The tag says which studio released these, but no edge does — so nothing that reads the graph can see it. Connect the Graph does not go back for what it skipped, so these need a re-run."
        case .edgeDisagreement:
            return "The edge and the tag name different studios. One of them is stale, and every graph query is currently trusting the edge."
        case .orphanProfile:
            return "Nothing in the library is filed under these any more. Usually what is left after a rename or a move."
        case .danglingParent:
            return "A network is recorded as owning an imprint, but the network itself has no profile — so its page would be empty and it cannot be confirmed."
        case .parentCycle:
            return "A studio is recorded as its own ancestor. This cannot be created through the app, so it came from a database edited by hand. Graph walks stop rather than loop, so nothing hangs — but the hierarchy beneath it is wrong."
        }
    }
}

public enum StudioAudit {

    /// Everything the audit needs, gathered by the caller.
    ///
    /// Passed in rather than read here so the whole audit is testable without a
    /// database — which matters, because several of these conditions are
    /// tedious to reproduce in a real library and trivial to state as data.
    public struct Input: Sendable {
        public let assets: [Asset]
        /// Every `entity_profiles` id, of every kind.
        public let profileIds: Set<String>
        /// Studio ids whose `enrichmentState` is `.matched`.
        public let confirmedStudioIds: Set<String>
        /// The `video_studio` edge, by video.
        public let studioIdByVideo: [UUID: String]
        /// The `studio_parent` edge: `from` is the imprint, `to` the network.
        public let parentPairs: [GraphEdgePair]

        public init(assets: [Asset],
                    profileIds: Set<String>,
                    confirmedStudioIds: Set<String>,
                    studioIdByVideo: [UUID: String],
                    parentPairs: [GraphEdgePair]) {
            self.assets = assets
            self.profileIds = profileIds
            self.confirmedStudioIds = confirmedStudioIds
            self.studioIdByVideo = studioIdByVideo
            self.parentPairs = parentPairs
        }
    }

    /// Runs every check, dropping the ones with nothing to say.
    ///
    /// Defects first, then the merely unfinished, each group by size — so the
    /// list opens on what is certainly wrong and on the decision that fixes the
    /// most records.
    public static func run(_ input: Input) -> [StudioCheck] {
        [
            multiStudioVideos(input),
            spellingCollisions(input),
            missingEdges(input),
            edgeDisagreements(input),
            danglingParents(input),
            parentCycles(input),
            missingProfiles(input),
            unconfirmed(input),
            orphanProfiles(input),
        ]
        .filter { !$0.items.isEmpty }
        .sorted {
            $0.isDefect != $1.isDefect ? $0.isDefect && !$1.isDefect
                                       : $0.count > $1.count
        }
    }

    // MARK: - The checks

    /// Delegated rather than reimplemented: `StudioConflictAudit` already
    /// groups these by the pairing, and the audit must agree with the screen
    /// that fixes them or the counts will differ by one screen.
    static func multiStudioVideos(_ input: Input) -> StudioCheck {
        StudioCheck(
            kind: .multiStudioVideo,
            items: StudioConflictAudit.conflicts(in: input.assets).map {
                "\($0.studios.joined(separator: " + ")) — \($0.videoCount) video\($0.videoCount == 1 ? "" : "s")"
            })
    }

    /// ⚠️ Folded through `StudioResolution.identity`, not `lowercased()`.
    ///
    /// The spellings that actually collide in a library are the ones a source
    /// ran the spaces out of, so a case-only fold — which is what the tag audit
    /// does — would miss the most common half of them.
    static func spellingCollisions(_ input: Input) -> StudioCheck {
        // ⚠️ Delegated, not reimplemented. This had its own inline grouping
        // while `StudioSpellingAudit` — the type behind the tool that FIXES
        // these — had another, so the audit and the repair screen could have
        // disagreed about what counts as a collision. Flagged by an
        // independent audit, 2026-08-07; the same reason `multiStudioVideos`
        // delegates to `StudioConflictAudit`.
        StudioCheck(
            kind: .spellingCollision,
            // Explicit closure rather than a key path: `spellings` is an array
            // of TUPLES, and a key path onto a tuple label does not compile.
            items: StudioSpellingAudit.collisions(in: input.assets).map { collision in
                collision.spellings.map { $0.spelling }.sorted().joined(separator: " · ")
            })
    }

    /// A studio named on a video that no `video_studio` edge records.
    ///
    /// ⚠️ Videos carrying two studios are excluded. They have no edge BY
    /// DESIGN — the graph refuses to pick one — so counting them here would
    /// report the same defect twice and make this check impossible to clear
    /// while one existed. `studioEdgeDisagreements()` excludes them for the
    /// same reason.
    static func missingEdges(_ input: Input) -> StudioCheck {
        var byStudio: [String: Int] = [:]
        for asset in input.assets {
            let studios = Set(asset.studios.filter { !$0.isEmpty })
            guard studios.count == 1, let name = studios.first else { continue }
            guard input.profileIds.contains("studio:\(name)") else { continue }
            if input.studioIdByVideo[asset.id] == nil {
                byStudio[name, default: 0] += 1
            }
        }
        return StudioCheck(kind: .missingEdge, items: describe(byStudio, unit: "video"))
    }

    /// An edge naming a different studio than the video's own tag.
    static func edgeDisagreements(_ input: Input) -> StudioCheck {
        var byStudio: [String: Int] = [:]
        for asset in input.assets {
            let studios = Set(asset.studios.filter { !$0.isEmpty })
            guard studios.count == 1, let name = studios.first else { continue }
            guard let edge = input.studioIdByVideo[asset.id] else { continue }
            if edge != "studio:\(name)" {
                byStudio[name, default: 0] += 1
            }
        }
        return StudioCheck(kind: .edgeDisagreement, items: describe(byStudio, unit: "video"))
    }

    static func missingProfiles(_ input: Input) -> StudioCheck {
        var counts: [String: Int] = [:]
        for asset in input.assets {
            for name in Set(asset.studios) where !name.isEmpty {
                guard !input.profileIds.contains("studio:\(name)") else { continue }
                counts[name, default: 0] += 1
            }
        }
        return StudioCheck(kind: .missingProfile, items: describe(counts, unit: "video"))
    }

    static func unconfirmed(_ input: Input) -> StudioCheck {
        var counts: [String: Int] = [:]
        for asset in input.assets {
            for name in Set(asset.studios) where !name.isEmpty {
                guard !input.confirmedStudioIds.contains("studio:\(name)") else { continue }
                counts[name, default: 0] += 1
            }
        }
        return StudioCheck(kind: .unconfirmed, items: describe(counts, unit: "video"))
    }

    /// A studio profile nothing is filed under.
    static func orphanProfiles(_ input: Input) -> StudioCheck {
        let inUse = Set(allStudioNames(input).map { "studio:\($0)" })
        let items = input.profileIds
            .filter { $0.hasPrefix("studio:") && !inUse.contains($0) }
            .map { String($0.dropFirst(7)) }
            .sorted()
        return StudioCheck(kind: .orphanProfile, items: items)
    }

    /// A `studio_parent` row pointing at a network with no profile.
    static func danglingParents(_ input: Input) -> StudioCheck {
        let items = Set(input.parentPairs.map(\.to))
            .filter { !input.profileIds.contains($0) }
            .map(displayName)
            .sorted()
        return StudioCheck(kind: .danglingParent, items: items)
    }

    /// A studio reachable from itself by following parents.
    ///
    /// Walks upward with a visited set rather than recursing, so a cycle is
    /// detected instead of overflowing the stack — the same reason
    /// `studioIdWithDescendants` walks downward with one.
    static func parentCycles(_ input: Input) -> StudioCheck {
        var parent: [String: String] = [:]
        for pair in input.parentPairs { parent[pair.from] = pair.to }

        var offenders: Set<String> = []
        for start in parent.keys {
            var seen: Set<String> = [start]
            var current = start
            while let next = parent[current] {
                if seen.contains(next) {
                    // Report the studio the walk started from: it is the one
                    // whose lineage is unusable, whichever link closed the loop.
                    offenders.insert(start)
                    break
                }
                seen.insert(next)
                current = next
            }
        }
        return StudioCheck(kind: .parentCycle, items: offenders.map(displayName).sorted())
    }

    // MARK: - Shared

    /// Every studio name the library actually uses, spelled as stored.
    static func allStudioNames(_ input: Input) -> Set<String> {
        var names: Set<String> = []
        for asset in input.assets {
            for name in asset.studios where !name.isEmpty { names.insert(name) }
        }
        return names
    }

    static func displayName(_ id: String) -> String {
        id.hasPrefix("studio:") ? String(id.dropFirst(7)) : id
    }

    /// Biggest first: the entry worth acting on leads.
    static func describe(_ counts: [String: Int], unit: String) -> [String] {
        counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\($0.key) — \($0.value) \(unit)\($0.value == 1 ? "" : "s")" }
    }
}
