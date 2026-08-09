// NodeResolver.swift
// Turns an id that arrived from ANOTHER library into an id valid in THIS one.
//
// 🚨 The federation boundary, and the whole point of phase 0. `applyGraphMerge`
// used to gate every incoming reference on `known.contains(incomingId)` and
// then write that same string. That is only correct while both libraries
// derive the same key from the same name — which stops being true the moment
// either side is re-keyed to opaque uids.
//
// ⭐ The invariant this type exists to enforce, stated once:
//
//     NO STRING FROM A PAYLOAD IS EVER WRITTEN TO A KEY COLUMN.
//
// An incoming id is evidence about WHICH node is meant. It is resolved to a
// local id, and the local id is what gets written. A sender's key is never
// adopted, because after v28 it may be an identifier minted on a machine this
// library has never seen.
//
// ⚠️ Deliberately total: every outcome is a named case rather than an optional,
// so a caller cannot conflate "this library has never heard of that node" with
// "that was not an id at all". They call for different handling and one of them
// is a bug in the sender.

import Foundation

/// What resolving an incoming reference produced.
public enum NodeResolution: Equatable, Sendable {

    /// A single local node carries this identity. The associated value is the
    /// **local** id, and is the only id a caller may write.
    case resolved(String)

    /// Parsed cleanly, and this library holds no node with that identity.
    ///
    /// ⚠️ NOT an error. It is the ordinary case for an edge naming a performer
    /// the receiver has never seen, and the caller decides whether to mint a
    /// node or skip — a decision that differs per call site and must not be
    /// made here.
    case absent

    /// 🚨 Not an id in this scheme — no colon, or an empty half.
    ///
    /// Kept separate from `.absent` because the handling is opposite: absent
    /// may justify minting a node, unparseable never does. Minting from a
    /// malformed string is how a library acquires a node named `""` or
    /// `actor:` that nothing can ever reach or remove.
    case unparseable

    /// 🚨 Two or more LOCAL nodes claim this identity, so there is no single
    /// right answer and picking one would silently attach an edge to the wrong
    /// node.
    ///
    /// ⚠️ Reachable in practice: v28's own D3 tag split creates two nodes
    /// sharing a display name, and a library carrying damage from an earlier
    /// build may hold genuine duplicates. Refusing is the only safe answer.
    case ambiguous

    /// The local id to write, or nil for every outcome that must not be written.
    public var writableLocalId: String? {
        if case let .resolved(id) = self { return id }
        return nil
    }
}

/// Resolves incoming node references against the local library.
///
/// Built once per merge and then consulted per reference — the local index is
/// read exactly once rather than per edge, which matters on a library holding
/// thousands of edges.
public struct NodeResolver: Sendable {

    /// resolution key → local id, for keys exactly one local node claims.
    private let unique: [String: String]

    /// Keys more than one local node claims. Held separately so `.ambiguous`
    /// is reported rather than silently resolving to whichever row was read
    /// last — a dictionary build alone would do exactly that.
    private let contested: Set<String>

    /// The one place the index is actually built. Both public initialisers
    /// funnel here so the contested-key rule cannot drift between them.
    private init(pairs: [(id: String, identity: NodeIdentity)]) {
        var unique: [String: String] = [:]
        var contested: Set<String> = []
        for (id, identity) in pairs {
            let key = identity.resolutionKey
            if let existing = unique[key], existing != id {
                contested.insert(key)
            } else {
                unique[key] = id
            }
        }
        // A contested key resolves to nothing at all, so a stale winner cannot
        // be handed out for a key already known to be ambiguous.
        for key in contested { unique.removeValue(forKey: key) }
        self.unique = unique
        self.contested = contested
    }

    /// - Parameter localIds: every node id in this library, in any order.
    ///
    /// ⚠️ Ids this build cannot parse are DROPPED from the index rather than
    /// rejected. A library holding an id shape from a newer build must still
    /// resolve everything else; refusing to construct would take the whole
    /// sync down over one row.
    ///
    /// 🚨 CORRECT ONLY BEFORE THE RE-KEY. Identity is recovered here by parsing
    /// the id, and after v28 an id is a uid with no colon in it — so
    /// `NodeIdentity.parse` returns nil for EVERY row and the "drop what cannot
    /// be parsed" rule above quietly empties the whole index. The resolver then
    /// answers `.absent` to everything and reports `indexedCount == 0`, which
    /// reads as a library with no nodes rather than as a resolver that cannot
    /// see them. Use `init(profiles:)` on any path that must outlive the re-key.
    public init(localIds: some Sequence<String>) {
        self.init(pairs: localIds.compactMap { id in
            NodeIdentity.parse(id).map { (id: id, identity: $0) }
        })
    }

    /// Builds the index from the profiles themselves rather than from their ids.
    ///
    /// ⭐ The re-key-proof initialiser, and the reason `EntityProfile` carries
    /// `entity_type` and `display_name` as columns at all. Identity comes from
    /// those columns via `type` and `name`, both of which prefer the stored
    /// value and fall back to the id — so this returns exactly what
    /// `init(localIds:)` returns today, and keeps returning it once ids stop
    /// encoding names. Phase 0's no-op discipline, applied to phase 0's own
    /// entry point.
    ///
    /// ⚠️ A profile with no discernible type, or no name, is dropped — the same
    /// two halves `NodeIdentity.parse` refuses, checked against the columns
    /// instead of against the id. A node whose kind is unknown cannot be
    /// compared against one whose kind is known without guessing, and a node
    /// with an empty name would claim the identity of every other nameless
    /// node in the library.
    ///
    /// 🚨 The empty-name half is NOT theoretical, and it is the one case where
    /// the two initialisers could disagree. The v34 backfill runs
    /// `WHERE instr(id, ':') > 1`, so a colonless id leaves `entity_type` NULL
    /// and both initialisers drop it — but `"actor:"` backfills to type
    /// `actor` and an EMPTY display name. `NodeIdentity.parse` rejects that id
    /// for its empty half; reading the columns has to reject it too, or phase 0
    /// stops being a no-op on precisely the malformed row this type exists to
    /// keep out of the index.
    public init(profiles: some Sequence<EntityProfile>) {
        self.init(pairs: profiles.compactMap { profile in
            guard let type = profile.type, !type.isEmpty else { return nil }
            let name = profile.name
            guard !name.isEmpty else { return nil }
            return (id: profile.id, identity: NodeIdentity(type: type, displayName: name))
        })
    }

    /// Resolves an id that arrived in a payload.
    public func resolve(_ incomingId: String) -> NodeResolution {
        guard let identity = NodeIdentity.parse(incomingId) else { return .unparseable }
        return resolve(identity)
    }

    /// Resolves a travelling identity directly, for payloads that carry one.
    public func resolve(_ identity: NodeIdentity) -> NodeResolution {
        let key = identity.resolutionKey
        if contested.contains(key) { return .ambiguous }
        if let local = unique[key] { return .resolved(local) }
        return .absent
    }

    /// Convenience for the common gate: the local id, or nil for anything that
    /// must not be written.
    ///
    /// ⚠️ Use only where `.absent`, `.unparseable` and `.ambiguous` genuinely
    /// warrant identical handling — which for edge endpoints they do, since
    /// all three mean "do not write this edge". Where they differ, switch on
    /// `resolve` and count them apart.
    public func localId(for incomingId: String) -> String? {
        resolve(incomingId).writableLocalId
    }

    /// How many local nodes were indexed. Exposed for the integrity report, so
    /// a resolver built from an empty library is visible rather than looking
    /// like a sync that legitimately matched nothing.
    public var indexedCount: Int { unique.count }

    /// Identities more than one local node claims.
    public var contestedKeyCount: Int { contested.count }
}

/// What a merge refused to write, and why.
///
/// ⭐ Every field is a REFUSAL, not a statistic. A sync that silently drops
/// edges is indistinguishable from one with nothing to do — and the whole
/// hazard phase 0 addresses is a boundary failing quietly.
public struct SyncIntegrityReport: Equatable, Sendable {

    /// References naming a node this library does not hold.
    public var absentNodes = 0

    /// 🚨 References that were not ids at all. Non-zero means the sender is
    /// emitting something this build cannot read — a bug, not a data gap.
    public var unparseableIds = 0

    /// 🚨 References whose identity is claimed by more than one local node.
    public var ambiguousNodes = 0

    /// Edges skipped because at least one endpoint did not resolve.
    public var skippedEdges = 0

    public init() {}

    /// Whether anything was refused. Drives whether the report is worth showing.
    public var isClean: Bool {
        absentNodes == 0 && unparseableIds == 0
            && ambiguousNodes == 0 && skippedEdges == 0
    }

    /// ⚠️ Non-zero here means a DEFECT rather than a difference between two
    /// libraries. Absent nodes are ordinary; these two are not.
    public var hasStructuralProblem: Bool {
        unparseableIds > 0 || ambiguousNodes > 0
    }

    /// Records one non-resolving outcome. Returns the writable local id, or nil.
    @discardableResult
    public mutating func note(_ resolution: NodeResolution) -> String? {
        switch resolution {
        case let .resolved(id):  return id
        case .absent:            absentNodes += 1
        case .unparseable:       unparseableIds += 1
        case .ambiguous:         ambiguousNodes += 1
        }
        return nil
    }
}
