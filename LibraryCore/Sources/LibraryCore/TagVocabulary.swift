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

    /// One row of the classification worklist.
    public struct WorklistItem: Equatable, Sendable, Identifiable {
        public var id: String { record.identityKey }
        public let record: TagRecord
        /// How many videos carry it. Shown because the cost of getting a tag
        /// wrong scales with its use, and because it tells the operator which
        /// decisions are worth thinking about.
        public let uses: Int
        /// Every casing found in the library. More than one means spellings
        /// were merged, and the operator may want a different display name.
        public let spellings: [String]

        public var isClassified: Bool { record.kind != nil }
    }

    /// The worklist: what the library uses, what it is currently classified as,
    /// and how much each decision matters.
    ///
    /// ⚠️ Deliberately does NOT pre-select a kind. Ordering and grouping help
    /// the operator choose; a pre-filled default is inference wearing a
    /// declaration's clothes, and the taxonomy exists precisely so the graph
    /// stops being wired by things nobody chose.
    public static func worklist(assets: [Asset],
                                vocabulary: [TagRecord]) -> [WorklistItem] {
        var usesByIdentity: [String: Int] = [:]
        var spellingsByIdentity: [String: Set<String>] = [:]

        for asset in assets {
            // Counted per ASSET, not per string. An asset carrying two casings
            // of one tag is still one video using that tag, and `uses` is
            // documented as "how many videos carry it" — a figure the operator
            // reads to decide how much a classification matters.
            var countedHere: Set<String> = []
            for name in asset.actions {
                let key = TagNormalizer.identityKey(name)
                spellingsByIdentity[key, default: []].insert(name)
                guard countedHere.insert(key).inserted else { continue }
                usesByIdentity[key, default: 0] += 1
            }
        }

        return vocabulary
            .map { record in
                WorklistItem(
                    record: record,
                    uses: usesByIdentity[record.identityKey] ?? 0,
                    spellings: (spellingsByIdentity[record.identityKey] ?? []).sorted())
            }
            // Unclassified first — that is the work. Then most-used, so the
            // decisions that matter most are the ones in front of you.
            .sorted {
                if $0.isClassified != $1.isClassified { return !$0.isClassified }
                if $0.uses != $1.uses { return $0.uses > $1.uses }
                return $0.record.identityKey < $1.record.identityKey
            }
    }

    /// Tags in the vocabulary that no asset uses any more.
    ///
    /// Not deleted automatically. A tag falling to zero uses is exactly what a
    /// mistake looks like mid-correction, and quietly removing the operator's
    /// classification would lose work they will need again the moment the tag
    /// comes back.
    public static func unused(in worklist: [WorklistItem]) -> [WorklistItem] {
        worklist.filter { $0.uses == 0 }
    }

    /// Maps every spelling found in a library to the ONE spelling to show.
    ///
    /// The other half of "read as case insensitive, show with user preferred
    /// casing". Folding identity in the vocabulary is not enough on its own:
    /// every surface that lists tags derives its own set from raw strings, so
    /// two casings still render as two tags in the gallery and two entries in a
    /// filter. This is the primitive those surfaces share, so the rule is
    /// applied once rather than reimplemented per view.
    ///
    /// - Parameters:
    ///   - names: every occurrence, repeats included — repetition is what makes
    ///     one spelling more used than another.
    ///   - vocabulary: when a tag is known, its stored `displayName` wins. The
    ///     operator's choice outranks a head-count.
    /// - Returns: raw spelling → spelling to display. Names with only one
    ///   spelling map to themselves, so a caller can apply it unconditionally.
    public static func canonicalSpellings(_ names: [String],
                                          preferring vocabulary: [TagRecord] = []) -> [String: String] {
        var usesBySpelling: [String: Int] = [:]
        for name in names { usesBySpelling[name, default: 0] += 1 }

        let preferredByIdentity = Dictionary(
            vocabulary.map { ($0.identityKey, $0.displayName) },
            uniquingKeysWith: { a, _ in a })

        var bestByIdentity: [String: (name: String, uses: Int)] = [:]
        for (name, uses) in usesBySpelling {
            let key = TagNormalizer.identityKey(name)
            if let best = bestByIdentity[key] {
                // Ties break on the spelling so the result is stable across
                // runs — dictionary order is not.
                if uses > best.uses || (uses == best.uses && name < best.name) {
                    bestByIdentity[key] = (name, uses)
                }
            } else {
                bestByIdentity[key] = (name, uses)
            }
        }

        var canonical: [String: String] = [:]
        for name in usesBySpelling.keys {
            let key = TagNormalizer.identityKey(name)
            canonical[name] = preferredByIdentity[key] ?? bestByIdentity[key]?.name ?? name
        }
        return canonical
    }

    /// What a write may and may not do.
    public struct WriteCheck: Equatable, Sendable {
        /// Tags classified as describing the OTHER kind of node. Refused: the
        /// vocabulary already says this is wrong, so allowing it would knowingly
        /// mis-wire the graph.
        public let refused: [String]
        /// Tags with no kind yet. **Allowed**, and reported so they reach the
        /// worklist rather than being silently accumulated.
        public let unclassified: [String]

        public var isAllowed: Bool { refused.isEmpty }
    }

    /// ⚠️ Why unclassified is ALLOWED rather than refused.
    ///
    /// Refusing it deadlocks: a tag cannot be attached until it is classified,
    /// and cannot be classified until it exists — so no new tag could ever be
    /// created. Worse, in this phase there are no edges and no staging table,
    /// so a refusal would simply discard what the operator typed.
    ///
    /// The rule that actually protects the graph is narrower:
    /// **refuse what the vocabulary says is wrong, allow what it does not yet
    /// know, and report the unknown.** It loses nothing: an unclassified tag behaves exactly as
    /// tags do today and shows up on the worklist; a performer attribute
    /// cannot be added to a video, which is the mis-wiring D3 exists to stop.
    ///
    /// When edges land, `unclassified` becomes a pending association and the
    /// stricter rule in the Epic applies — at that point refusing costs nothing
    /// because the link is preserved.
    public static func check(adding updated: Asset,
                             against previous: Asset,
                             vocabulary: [TagRecord],
                             available: [TagKind] = TagKind.seed) -> WriteCheck {
        let alreadyThere = Set(previous.actions.map(TagNormalizer.identityKey))
        let byIdentity = Dictionary(
            vocabulary.map { ($0.identityKey, $0) }, uniquingKeysWith: { a, _ in a })

        var refused: [String] = []
        var unclassified: [String] = []
        for name in updated.actions {
            let key = TagNormalizer.identityKey(name)
            guard !alreadyThere.contains(key) else { continue }
            guard let record = byIdentity[key] else { unclassified.append(name); continue }
            if record.resolvedKind(from: available) == nil {
                unclassified.append(name)
            } else if !canAttach(record, to: .video, available: available) {
                refused.append(name)
            }
        }
        return WriteCheck(refused: refused, unclassified: unclassified)
    }

    /// The same check for a performer.
    public static func check(adding updated: EntityProfile,
                             against previous: EntityProfile,
                             vocabulary: [TagRecord],
                             available: [TagKind] = TagKind.seed) -> WriteCheck {
        let alreadyThere = Set(previous.tags.map(TagNormalizer.identityKey))
        let byIdentity = Dictionary(
            vocabulary.map { ($0.identityKey, $0) }, uniquingKeysWith: { a, _ in a })

        var refused: [String] = []
        var unclassified: [String] = []
        for name in updated.tags {
            let key = TagNormalizer.identityKey(name)
            guard !alreadyThere.contains(key) else { continue }
            guard let record = byIdentity[key] else { unclassified.append(name); continue }
            if record.resolvedKind(from: available) == nil {
                unclassified.append(name)
            } else if !canAttach(record, to: .performer, available: available) {
                refused.append(name)
            }
        }
        return WriteCheck(refused: refused, unclassified: unclassified)
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
