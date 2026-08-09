// EntityProfileIndex.swift
// How the app finds a profile when all it has is a NAME.
//
// 🚨 The read-side counterpart to `NodeResolver`, and the second half of what
// makes v28 survivable. Every screen in the app reaches a profile the same way:
// it holds a cast name off a video — `asset.actors` — and looks it up in a
// `[String: EntityProfile]` keyed by `EntityProfile.id`. That works only while
// the id IS the name. After the re-key it is a uid, and all forty-odd of those
// lookups miss at once.
//
// ⭐ Why a type rather than re-keying the dictionary in place. A dictionary
// keyed by a differently-shaped `String` still compiles at every call site and
// simply returns nil — forty silent misses in the code that draws the library,
// caught by no test and no compiler. Changing the TYPE makes every one of them
// a build error. That property is the whole reason this exists; the ergonomics
// are a bonus.
//
// ⚠️ Scope: this is the DISPLAY and READ path. Writes go through
// `NodeResolver`, which refuses ambiguity rather than resolving it. The two
// differ deliberately — see `contestedIdentities`.

import Foundation

/// Profiles, reachable by identity instead of by primary key.
///
/// ⚠️ `Equatable` on `all` alone — the three indexes are derived from it, so
/// comparing them too would be the same answer at several times the cost. This
/// conformance exists because SwiftUI change-detection keys off it (see
/// `AssetsGridView.RecomputeSignature`), and it is compared on every filter
/// change over ~1,800 profiles.
public struct EntityProfileIndex: Sendable, Equatable {

    public static func == (lhs: EntityProfileIndex, rhs: EntityProfileIndex) -> Bool {
        lhs.all == rhs.all
    }

    /// Every profile, in no particular order. For the screens that summarise
    /// the whole set rather than looking one up.
    public let all: [EntityProfile]

    /// `NodeIdentity.resolutionKey` → profile.
    private let byIdentity: [String: EntityProfile]

    /// `EntityProfile.id` → profile, kept for the code that legitimately holds
    /// an id already — an edge endpoint, a route parameter, a saved selection.
    /// ⚠️ Not a fallback for name lookups. A caller with a name must go through
    /// the identity subscripts or it will start missing at the re-key.
    private let byId: [String: EntityProfile]

    /// Profiles grouped by entity type, so a screen can ask for "the actors"
    /// without testing `id.hasPrefix("actor:")` — which is itself a thing that
    /// stops working when the id stops carrying the type.
    private let byType: [String: [EntityProfile]]

    /// 🚨 Identities claimed by more than one profile.
    ///
    /// ⚠️ Unlike `NodeResolver`, this index does NOT refuse a contested
    /// identity — it picks one deterministically and records the collision
    /// here. The asymmetry is deliberate and worth stating:
    ///
    ///   `NodeResolver` guards WRITES. Attaching an edge to the wrong node is
    ///   corruption, so refusing is strictly better than guessing.
    ///
    ///   This guards READS. Showing one of two same-named performers is a
    ///   cosmetic error; showing NOTHING blanks the row and hides the very
    ///   duplicate the operator needs to see in order to merge it.
    ///
    /// The pre-flight reports duplicates before any re-keying, and the drive
    /// library has zero — but a library can acquire them later, and a blank
    /// screen is a bad way to find out.
    public let contestedIdentities: Set<String>

    /// ⚠️ Concrete on purpose, and the primary initialiser.
    ///
    /// The generic form below is convenient but expensive for the type-checker
    /// to resolve — an opaque parameter with a primary associated type. Call
    /// sites inside a SwiftUI `body` are frequently near the solver's budget
    /// already, and routing them through the generic overload was enough on its
    /// own to tip `AssetsGridView` into "unable to type-check in reasonable
    /// time" in three unrelated expressions. Prefer this one.
    public init(_ profiles: [EntityProfile]) {
        let all = profiles
        self.all = all

        var byIdentity: [String: EntityProfile] = [:]
        var byId: [String: EntityProfile] = [:]
        var byType: [String: [EntityProfile]] = [:]
        var contested: Set<String> = []

        for profile in all {
            byId[profile.id] = profile
            guard let type = profile.type, !type.isEmpty else { continue }
            byType[type, default: []].append(profile)

            let name = profile.name
            guard !name.isEmpty else { continue }
            let key = NodeIdentity(type: type, displayName: name).resolutionKey

            if let held = byIdentity[key], held.id != profile.id {
                contested.insert(key)
                // ⚠️ Deterministic tie-break, NOT last-writer-wins. The input
                // order here is a database read order, so picking the last
                // would make the app show a different profile from one launch
                // to the next for the same name — the hardest kind of bug to
                // be told about.
                if profile.id < held.id { byIdentity[key] = profile }
            } else {
                byIdentity[key] = profile
            }
        }

        self.byIdentity = byIdentity
        self.byId = byId
        self.byType = byType
        self.contestedIdentities = contested
    }

    // MARK: - Lookup by identity

    /// The profile for a node of `type` with this display name.
    ///
    /// ⭐ This is the call that survives the re-key, and today it returns
    /// exactly what `dict["\(type):\(name)"]` returned.
    public subscript(type type: String, name name: String) -> EntityProfile? {
        guard !name.isEmpty else { return nil }
        return byIdentity[NodeIdentity(type: type, displayName: name).resolutionKey]
    }

    public subscript(actor name: String) -> EntityProfile? { self[type: "actor", name: name] }
    public subscript(studio name: String) -> EntityProfile? { self[type: "studio", name: name] }
    public subscript(tag name: String) -> EntityProfile? { self[type: "tag", name: name] }

    // MARK: - Lookup by id

    /// For a caller that already holds a real id.
    ///
    /// ⚠️ Deliberately a named method rather than a plain subscript, so that a
    /// name being passed here reads wrong at the call site instead of quietly
    /// compiling.
    public func profile(id: String) -> EntityProfile? { byId[id] }

    // MARK: - Whole-set reads

    /// Every profile of one type. Replaces `filter { $0.id.hasPrefix("actor:") }`,
    /// which returns nothing at all once ids stop carrying their type.
    public func ofType(_ type: String) -> [EntityProfile] { byType[type] ?? [] }

    public var actors: [EntityProfile] { ofType("actor") }
    public var studios: [EntityProfile] { ofType("studio") }
    public var tags: [EntityProfile] { ofType("tag") }

    public var isEmpty: Bool { all.isEmpty }
    public var count: Int { all.count }

    /// Convenience for the callers holding something other than an array —
    /// `dict.values`, a `Set`, a lazy sequence.
    public init(_ profiles: some Sequence<EntityProfile>) {
        self.init(Array(profiles))
    }

    public static let empty = EntityProfileIndex([EntityProfile]())
}

public extension EntityProfileIndex {

    /// The multi-library display view: an ordered fold, primary library first.
    ///
    /// 🚨 Folded by IDENTITY, not by id — and that is a fix, not a refactor.
    /// `MergeSemantics.mergedProfileView(ordered:)` keys the fold on
    /// `EntityProfile.id`, which is correct only while two libraries derive the
    /// same id from the same name. After the re-key each library mints its OWN
    /// uid for the same performer, so an id-keyed fold stops matching them and
    /// the merged view silently shows the same person twice, once per library,
    /// each missing whatever the other held.
    ///
    /// ⭐ Identity is the right key by D4's rule: between libraries, a node is
    /// (entity type, tag kind, display name). This is that rule applied to the
    /// read path.
    ///
    /// ⚠️ DISPLAY ONLY, exactly as before — the merged form must never be
    /// written back, or one library's data lands in another.
    static func merged(ordered layers: [[EntityProfile]]) -> EntityProfileIndex {
        var foldedByKey: [String: EntityProfile] = [:]
        var order: [String] = []

        for layer in layers {
            for profile in layer {
                // Profiles with no usable identity still have to appear —
                // dropping them here would make a damaged row invisible rather
                // than fixable — so they fold under their own id.
                let key: String
                if let type = profile.type, !type.isEmpty, !profile.name.isEmpty {
                    key = NodeIdentity(type: type, displayName: profile.name).resolutionKey
                } else {
                    key = profile.id
                }

                if let higher = foldedByKey[key] {
                    foldedByKey[key] = MergeSemantics.mergedProfileView(higher: higher,
                                                                        lower: profile)
                } else {
                    foldedByKey[key] = profile
                    order.append(key)
                }
            }
        }

        return EntityProfileIndex(order.compactMap { foldedByKey[$0] })
    }
}
