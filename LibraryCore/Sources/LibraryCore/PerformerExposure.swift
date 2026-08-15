// PerformerExposure.swift
// Whether a performer's NAME may be sent to an external source.
//
// 🚨 The other half of the privacy boundary (#62). `ProviderBoundary` guards
// videos, and it guards them by reading `contentKind` — a property of an asset.
// Actor enrichment is keyed by a performer's name, so that gate cannot reach
// it: a performer the operator added while tagging a home video, a family
// member or a friend, can have their name searched at a third party through a
// door the video boundary does not cover.
//
// ⭐ It needs NO new declaration, which is what makes it decidable. A
// performer's exposure is derived from the videos they appear in, and those are
// exactly what #59 taught the library to declare. 1,352 of 1,353 profiles carry
// at least one video edge, so declaring videos gives performers decidability for
// free — no second surface, and nothing extra for the operator to maintain.
//
// ⚠️ The same asymmetry decides this as decides `ProviderBoundary`: fail-open is
// irreversible, because a name that reaches a third party cannot be recalled,
// while fail-closed costs a delay.

import Foundation

/// Whether a performer's name may leave the device, derived from their videos.
///
/// ⭐ A namespace and a pure rule, deliberately — the same shape as
/// `ProviderBoundary`, so a test can name the decision and a provider double can
/// assert it was never reached.
public enum PerformerExposure {

    /// Why sending a performer's name was refused.
    public enum Refusal: Equatable, Sendable {
        /// Every video crediting them is declared personal.
        case personalOnly
        /// Nothing crediting them is declared commercial, and something is still
        /// undeclared. Actionable: declaring those videos settles it.
        case undeclared
        /// No videos credit them at all, so there is no evidence either way.
        ///
        /// 🚨 Refused. Undecidable is not the same as safe — this is the
        /// `nil`-content-kind rule applied one level up, and for the identical
        /// reason.
        case noVideos

        public var reason: String {
            switch self {
            case .personalOnly:
                return "Every video this performer appears in is one of your own, "
                     + "so their name is never sent to an external source."
            case .undeclared:
                return "None of this performer's videos have been declared as personal "
                     + "or commercial yet. Nothing is sent until they have been — "
                     + "declare them and try again."
            case .noVideos:
                return "No video in the library credits this performer, so there is "
                     + "nothing to say whether their name may be sent. Nothing is sent."
            }
        }

        /// The batch report's label, which groups by this string.
        ///
        /// ⚠️ Kept distinct per case rather than collapsing to one "name not
        /// sent" tally. A run that skipped 1,300 performers tells the operator
        /// almost nothing; a run that skipped 1,300 *because their videos are
        /// undeclared* tells them exactly what to go and do.
        public var shortReason: String {
            switch self {
            case .personalOnly: return "personal videos only — name not sent"
            case .undeclared: return "videos not declared yet — name not sent"
            case .noVideos: return "no videos credit them — name not sent"
            }
        }
    }

    /// The rule, over the content kinds of every video crediting one performer.
    ///
    /// ⭐ **One declared commercial appearance is enough.** This is the line
    /// worth arguing about, and it was argued: the alternative — refuse if ANY
    /// appearance is personal — would block a genuine commercial performer
    /// because the operator happened to tag them in one home video, and that
    /// performer's name was never private to begin with. Confirmed by the Human
    /// Operator 2026-08-15.
    ///
    /// ⚠️ The reverse reading is the dangerous one and is NOT what this does: a
    /// personal appearance never *grants* exposure, it simply does not remove
    /// exposure that a public commercial credit already established.
    public static func refusal(forVideoKinds kinds: [ContentKind?]) -> Refusal? {
        guard !kinds.isEmpty else { return .noVideos }
        // A single video that may itself be sent settles it.
        if kinds.contains(where: { ProviderBoundary.allows($0) }) { return nil }
        // ⚠️ Undeclared is reported ahead of personal-only when both are
        // present, because it is the one the operator can act on — declaring
        // those videos either grants exposure or confirms the refusal. Saying
        // "these are all your own videos" about a set that is merely
        // undeclared would be a statement the library cannot support.
        return kinds.contains(where: { $0 == nil }) ? .undeclared : .personalOnly
    }

    public static func allows(_ kinds: [ContentKind?]) -> Bool {
        refusal(forVideoKinds: kinds) == nil
    }

    /// Every performer's exposure, in ONE pass over the assets.
    ///
    /// Keyed by performer name, because crediting is by name and AKA — see
    /// `ActorCredits`, which this shares with the video count displayed beside
    /// the very same performer.
    ///
    /// ⚠️ A performer credited by NO asset is absent from the result rather than
    /// present with `.noVideos`. Callers must therefore treat a missing key as a
    /// refusal, which is what `refusal(forPerformer:in:)` exists to make hard to
    /// get wrong.
    public static func build(assets: [Asset],
                             profiles: EntityProfileIndex) -> [String: Refusal?] {
        ActorCredits.byActor(assets: assets, profiles: profiles)
            .mapValues { refusal(forVideoKinds: $0.map(\.contentKind)) }
    }

    /// One performer's refusal, reading a map built by `build`.
    ///
    /// 🚨 The lookup and the fail-closed default in one place. A caller writing
    /// `map[name] == nil` would read "absent" as "allowed" — the exact inversion
    /// this whole boundary exists to prevent, and it would compile.
    public static func refusal(forPerformer name: String,
                               in exposures: [String: Refusal?]) -> Refusal? {
        guard let known = exposures[name] else { return .noVideos }
        return known
    }
}

public extension LibraryStore {

    /// Every performer's exposure in THIS library.
    ///
    /// ⚠️ One pass over every asset and every profile. Callers hold the result
    /// for the duration of a run and re-ask it per performer — they must not
    /// call this per performer, which is what the batch run's
    /// `awaitingEnrichment` read already learned.
    ///
    /// 🚨 A throwing read rather than one that answers `[:]` on failure. An
    /// empty map is indistinguishable from "nobody is exposed", which fails
    /// closed and would look like the boundary working correctly while actually
    /// meaning the library could not be read.
    func performerExposures() throws -> [String: PerformerExposure.Refusal?] {
        PerformerExposure.build(assets: try fetchAllAssets(),
                                profiles: EntityProfileIndex(try fetchAllEntityProfiles()))
    }
}
