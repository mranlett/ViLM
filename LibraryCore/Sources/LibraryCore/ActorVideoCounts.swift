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

        // ⭐ The crediting rule itself lives in `ActorCredits` — this used to
        // carry its own copy, as did `ActorKnownFor`, and a third consumer
        // (`PerformerExposure`, #62) is what made three copies of a subtle rule
        // untenable. Counting is all that is left here.
        ActorCredits.byActor(assets: assets, profiles: profiles).mapValues(\.count)
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
