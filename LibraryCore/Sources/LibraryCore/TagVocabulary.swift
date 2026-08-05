// TagVocabulary.swift
// The library's tags as things with an identity and a kind, rather than as
// strings scattered across every asset's tag array.
//
// This is the smallest step that makes the taxonomy real: a tag gains a stable
// identity (case- and diacritic-folded) and a kind saying what it describes.
// Edges come later; today's `tag:` strings continue to carry the associations.

import Foundation
import GRDB

/// One tag in the library's vocabulary.
public struct TagRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {

    public static let databaseTableName = "tags"

    /// Folded name. The identity — `SCUBA` and `Scuba` share one.
    public let identityKey: String

    /// The spelling to show, in whatever casing the operator prefers.
    public var displayName: String

    /// What this tag describes. `nil` means **unclassified**: no edge may be
    /// created for it, and it belongs on the worklist.
    public var kind: String?

    public init(displayName: String, kind: TagKind? = nil) {
        self.identityKey = TagNormalizer.identityKey(displayName)
        self.displayName = displayName
        self.kind = kind?.name
    }

    enum CodingKeys: String, CodingKey {
        case identityKey = "identity_key"
        case displayName = "display_name"
        case kind
    }

    /// The kind resolved against a set of known kinds, or nil when
    /// unclassified — or when the stored name matches no known kind, which is
    /// what an operator-defined kind looks like after it has been removed.
    public func resolvedKind(from available: [TagKind] = TagKind.seed) -> TagKind? {
        guard let kind else { return nil }
        return available.first { $0.name == kind }
    }
}

public enum TagVocabulary {

    /// Every distinct tag across the given assets, folded so that two spellings
    /// of one tag produce one record.
    ///
    /// ⚠️ Case variants MERGE rather than colliding, and the **most-used**
    /// spelling wins the display name. A real library held one tag under two
    /// casings, 15 uses against 1; rejecting the pair would have stranded real
    /// data on a technicality, and picking the wrong spelling would have shown
    /// the operator the rarer one.
    public static func promoting(_ assets: [Asset]) -> [TagRecord] {
        var usesBySpelling: [String: Int] = [:]
        for asset in assets {
            for name in asset.actions { usesBySpelling[name, default: 0] += 1 }
        }

        // The winning spelling and the merged total are tracked SEPARATELY.
        // Folding them into one figure compares each new spelling against a
        // running sum rather than against its rivals, so with three or more
        // casings the wrong one wins the display name.
        var totalByIdentity: [String: Int] = [:]
        var bestSpelling: [String: (name: String, uses: Int)] = [:]

        for (name, uses) in usesBySpelling {
            let key = TagNormalizer.identityKey(name)
            totalByIdentity[key, default: 0] += uses

            if let best = bestSpelling[key] {
                // Ties break on the spelling itself so the result never depends
                // on dictionary ordering, which is not stable across runs.
                if uses > best.uses || (uses == best.uses && name < best.name) {
                    bestSpelling[key] = (name, uses)
                }
            } else {
                bestSpelling[key] = (name, uses)
            }
        }

        // Most-used first, so the worklist starts where it matters. Equal
        // counts fall back to the folded key, keeping the order stable.
        return bestSpelling
            .map { (key, best) in (record: TagRecord(displayName: best.name),
                                   uses: totalByIdentity[key] ?? best.uses, key: key) }
            .sorted { ($0.uses, $1.key) > ($1.uses, $0.key) }
            .map(\.record)
    }

    /// Whether a tag may be attached to `target`.
    ///
    /// ⚠️ An unclassified tag attaches to NOTHING. That is the point: until a
    /// person says what a tag describes, the model refuses to wire it rather
    /// than guessing and being quietly wrong.
    public static func canAttach(_ record: TagRecord?,
                                 to target: TagKind.Target,
                                 available: [TagKind] = TagKind.seed) -> Bool {
        guard let kind = record?.resolvedKind(from: available) else { return false }
        return kind.canAttach(to: target)
    }

    /// The tags still needing a person.
    public static func unclassified(in records: [TagRecord]) -> [TagRecord] {
        records.filter { $0.kind == nil }
    }

    /// Tags a write would ADD to a video that it may not.
    ///
    /// ⚠️ Only ADDITIONS are checked, never what a record already holds. The
    /// library carries attribute tags on videos today — measured, 4 tags across
    /// 31 videos — and the decision is that enrichment corrects them per
    /// performer as each video is matched. A boundary that rejected any video
    /// *containing* one would make those 31 videos unsaveable: every unrelated
    /// edit to them would fail, which is a far worse outcome than the wiring
    /// error it was trying to prevent.
    ///
    /// So the rule is **"may not add"**, not "may not contain" — the graph
    /// stops getting worse immediately, and gets better as matching proceeds.
    ///
    /// An **unclassified** tag is refused too. Until a person says what a tag
    /// describes, attaching it is guessing.
    public static func disallowedAdditions(from previous: Asset,
                                           to updated: Asset,
                                           vocabulary: [TagRecord],
                                           available: [TagKind] = TagKind.seed) -> [String] {
        let alreadyThere = Set(previous.actions.map(TagNormalizer.identityKey))
        let byIdentity = Dictionary(
            vocabulary.map { ($0.identityKey, $0) }, uniquingKeysWith: { a, _ in a })

        return updated.actions.filter { name in
            let key = TagNormalizer.identityKey(name)
            guard !alreadyThere.contains(key) else { return false }
            return !canAttach(byIdentity[key], to: .video, available: available)
        }
    }

    /// The same rule for a performer: an action tag describes a video, not a
    /// person, and must not be added to one.
    public static func disallowedAdditions(from previous: EntityProfile,
                                           to updated: EntityProfile,
                                           vocabulary: [TagRecord],
                                           available: [TagKind] = TagKind.seed) -> [String] {
        let alreadyThere = Set(previous.tags.map(TagNormalizer.identityKey))
        let byIdentity = Dictionary(
            vocabulary.map { ($0.identityKey, $0) }, uniquingKeysWith: { a, _ in a })

        return updated.tags.filter { name in
            let key = TagNormalizer.identityKey(name)
            guard !alreadyThere.contains(key) else { return false }
            return !canAttach(byIdentity[key], to: .performer, available: available)
        }
    }
}
