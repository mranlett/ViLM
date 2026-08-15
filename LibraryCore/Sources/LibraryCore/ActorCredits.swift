// ActorCredits.swift
// Which videos credit which performer. One rule, one place.
//
// ⚠️ This rule was written twice before it was written here — once in
// `ActorVideoCounts` and once in `ActorKnownFor` — and both copies carry a
// comment saying a second expression of it would drift. It is subtle enough to
// deserve the worry: an asset crediting BOTH a canonical name and one of that
// performer's aliases credits them ONCE, because this counts assets and not
// name matches.
//
// ⭐ `PerformerExposure` (#62) is the third consumer, and it is the one that
// made the duplication unacceptable rather than merely untidy. Exposure decides
// whether a name may be sent to a third party; if it credited by even a
// slightly different rule than the count displayed beside it, a performer could
// read as "in 3 of your videos" on one screen and be judged on a different
// three by the privacy boundary. That disagreement would be invisible and would
// fail in the unrecoverable direction.

import Foundation

public enum ActorCredits {

    /// Every crediting asset, per performer name, in ONE pass over the assets.
    ///
    /// An asset credits a performer when it names them directly **or** names any
    /// entry on their AKA list. An asset doing both appears once.
    ///
    /// - Parameter profiles: only actors' AKA lists are read. A performer with
    ///   no profile row is still credited by name — they have videos whether or
    ///   not anyone has made them a record.
    public static func byActor(assets: [Asset],
                               profiles: EntityProfileIndex) -> [String: [Asset]] {
        // ⚠️ Built ONCE, outside the loop. Rebuilding it per asset is
        // O(assets × profiles) and is what made sorting 1,335 performers
        // unusable the first time.
        let owners = akaOwners(in: profiles)
        var byActor: [String: [Asset]] = [:]
        for asset in assets {
            for actor in creditedNames(on: asset, akaOwners: owners) {
                byActor[actor, default: []].append(asset)
            }
        }
        return byActor
    }

    /// alias -> the performers who list it.
    ///
    /// ⚠️ A set, not a single owner: several performers may list the same alias,
    /// and picking one would silently drop the other's credit.
    ///
    /// ⭐ Reads `profile.name`, never a name parsed out of `profile.id`. Three
    /// separate id assumptions used to live in this loop — a `hasPrefix("actor:")`
    /// filter, a `dropFirst` to recover the name, and an id-keyed iteration — and
    /// after the re-key the filter matches nothing, so the whole AKA map comes
    /// out empty and every alias quietly stops crediting its owner.
    static func akaOwners(in profiles: EntityProfileIndex) -> [String: Set<String>] {
        var owners: [String: Set<String>] = [:]
        for profile in profiles.actors {
            let canonical = profile.name
            for aka in profile.akas where !aka.isEmpty {
                owners[aka, default: []].insert(canonical)
            }
        }
        return owners
    }

    /// Every performer one asset credits, deduplicated.
    static func creditedNames(on asset: Asset,
                              akaOwners: [String: Set<String>]) -> Set<String> {
        var credited = Set<String>()
        for name in asset.actors {
            // The literal name always credits: a performer with no profile row
            // still appears in the video.
            credited.insert(name)
            if let owners = akaOwners[name] { credited.formUnion(owners) }
        }
        return credited
    }
}
