// ActorVideoCounts.swift
// How many videos each actor appears in.
//
// Lives here rather than in the view because it is the kind of thing that must
// be tested against the computation it replaces: the numbers it produces are
// displayed on every card and drive both a filter and a sort, so a subtle
// disagreement would be visible everywhere and obvious nowhere.

import Foundation

public enum ActorVideoCounts {

    /// Every actor's video count, in ONE pass over the assets.
    ///
    /// An asset counts for an actor when it credits their name directly, **or**
    /// credits any name on their AKA list. An asset that does both counts once —
    /// this counts assets, not name matches.
    ///
    /// - Parameter profiles: the library's profiles. Only actors' AKA lists are
    ///   read; an actor with no profile row still counts by name.
    public static func build(assets: [Asset],
                             profiles: EntityProfileIndex) -> [String: Int] {

        // aka -> the actors who list it. Several actors may list the same alias,
        // so the value is a set rather than a single owner.
        //
        // ⭐ Three separate id assumptions used to live in this loop: filtering
        // by `hasPrefix("actor:")`, deriving the canonical name with
        // `dropFirst`, and iterating a dictionary keyed by id. After the re-key
        // the filter matches nothing, so the whole AKA map would come out empty
        // and every alias would silently stop crediting its owner.
        var akaOwners: [String: Set<String>] = [:]
        for profile in profiles.actors {
            let canonical = profile.name
            for aka in profile.akas where !aka.isEmpty {
                akaOwners[aka, default: []].insert(canonical)
            }
        }

        var counts: [String: Int] = [:]
        for asset in assets {
            var credited = Set<String>()
            for name in asset.actors {
                // The literal name always credits: an actor with no profile row
                // still has videos.
                credited.insert(name)
                if let owners = akaOwners[name] { credited.formUnion(owners) }
            }
            for actor in credited { counts[actor, default: 0] += 1 }
        }
        return counts
    }

    /// The previous per-actor computation, kept so a test can assert the fast
    /// path agrees with it.
    ///
    /// **Not for production use** — this is O(assets) per actor and allocates a
    /// `Set` per asset, which is what made sorting 1,335 actors unusable. It
    /// exists to be the oracle, not the implementation.
    static func referenceCount(for actor: String,
                               assets: [Asset],
                               profiles: EntityProfileIndex) -> Int {
        let akas = Set(profiles[actor: actor]?.akas ?? [])
        return assets.filter { asset in
            if asset.actors.contains(actor) { return true }
            return !Set(asset.actors).isDisjoint(with: akas)
        }.count
    }
}
