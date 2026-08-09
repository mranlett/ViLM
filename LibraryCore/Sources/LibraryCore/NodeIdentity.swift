// NodeIdentity.swift
// How a node is identified BETWEEN libraries, as opposed to within one.
//
// 🚨 Phase 0 of Opaque Node Identity, and the reason it exists. v28 makes
// `EntityProfile.id` an opaque uid that is minted locally and means nothing
// anywhere else. Today the federation boundary passes `EntityProfile.id`
// straight across and `applyGraphMerge` both LOOKS UP and STORES by it — which
// works only because two libraries derive the same string from the same name.
//
// The moment one library is re-keyed that stops being true, and it fails in
// both directions without raising anything:
//
//   v28 → old : the sender's uid is stored as a key, producing a DUPLICATE of
//               a performer the receiver already holds under its name key.
//   old → v28 : the lookup misses, and a node is created under an old-style
//               key whose edges reference uids and never join.
//
// ⭐ So identity between libraries becomes the triple D4 names — entity type,
// tag kind, display name — and a uid never crosses the boundary at all.
//
// ⚠️ This type is deliberately a NO-OP on today's schema. `resolutionKey`
// reproduces exactly what the current code uses as a key, so phase 0 changes
// no behaviour and can be shipped and exercised on real libraries BEFORE any
// re-keying exists to debug it against. That is the whole point of doing it
// first: it converts v28's riskiest unknown into tested code.

import Foundation

/// A node's identity as it travels between libraries.
///
/// ⚠️ Never a uid. A uid is minted locally and is meaningless elsewhere; two
/// libraries holding the same performer mint different ones.
public struct NodeIdentity: Codable, Equatable, Hashable, Sendable {

    /// `actor`, `studio`, or whatever prefix a future build introduces.
    ///
    /// ⚠️ A `String` rather than `GraphNodeKind`, so a node from a NEWER
    /// library travels through an older build intact instead of being dropped
    /// on the floor. The same discipline `GraphNodeKind.of` already follows:
    /// an unrecognised shape is a reason to leave something alone, not to
    /// discard it.
    public let type: String

    /// What the tag describes, for nodes that have a kind axis. Always nil for
    /// actors and studios.
    ///
    /// ⭐ Part of the identity because the Epic's D3 splits a colliding tag
    /// into an action and an attribute node SHARING a display name. Identity
    /// on name alone would refuse the split this whole spec exists to allow.
    public let tagKind: String?

    /// The name as a person reads it.
    public let displayName: String

    public init(type: String, tagKind: String? = nil, displayName: String) {
        self.type = type
        self.tagKind = tagKind
        self.displayName = displayName
    }
}

public extension NodeIdentity {

    /// Reads the identity out of a legacy `prefix:Name` id.
    ///
    /// ⚠️ Splits on the FIRST colon only. A studio named "Vol 2: The Return"
    /// contains one, and splitting on the last — or on all — would truncate
    /// the name and silently create a second node for it.
    ///
    /// Returns nil for a string with no colon at all, which is not an id in
    /// this scheme and must not be guessed at.
    static func parse(_ id: String) -> NodeIdentity? {
        guard let colon = id.firstIndex(of: ":") else { return nil }
        let type = String(id[id.startIndex..<colon])
        let name = String(id[id.index(after: colon)...])
        guard !type.isEmpty, !name.isEmpty else { return nil }
        return NodeIdentity(type: type, displayName: name)
    }

    /// The `prefix:Name` form, which is what a library that has NOT been
    /// re-keyed uses as its primary key.
    ///
    /// ⭐ Kept so a re-keyed library can still speak to an un-migrated one.
    /// D4's mixed state is supported rather than merely tolerated, and this is
    /// the method that makes it so.
    var legacyId: String { "\(type):\(displayName)" }

    /// What two libraries compare to decide they mean the same node.
    ///
    /// 🚨 EXACT for actors and studios, deliberately. Today's key is the exact
    /// display name, so folding case or spacing here would make phase 0 merge
    /// nodes that the current build keeps apart — a behaviour change smuggled
    /// in under a migration, and the hardest kind to notice.
    ///
    /// Tags fold, because `TagRecord.identityKey` already folds and the tag
    /// path in `applyGraphMerge` already resolves by it. Matching that is
    /// reproducing current behaviour, not inventing it.
    ///
    /// ⚠️ If name folding for performers is ever wanted, it is its own spec
    /// with its own review. It is not a detail of this one.
    var resolutionKey: String {
        let name = type == "tag" ? TagNormalizer.identityKey(displayName) : displayName
        return "\(type)\u{1F}\(tagKind ?? "")\u{1F}\(name)"
    }
}

public extension EntityProfile {
    /// This profile's travelling identity.
    ///
    /// ⚠️ Derived from `id` today because the id still encodes the name. After
    /// v28's re-keying it must come from the `entity_type` / `display_name`
    /// columns instead — this is the single place that changes, which is why
    /// callers go through it rather than parsing ids themselves.
    var nodeIdentity: NodeIdentity? { NodeIdentity.parse(id) }
}
