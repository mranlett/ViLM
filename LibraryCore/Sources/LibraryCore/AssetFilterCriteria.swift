// AssetFilterCriteria.swift
// The advanced-filter model shared by every screen that filters videos (the
// All Assets grid and the Move-Between-Libraries page): review status, minimum
// rating, and AND/OR sets of actors, tags, studios, plus actor-metadata
// filters (tags, hair color, gender, country) that match videos through the
// actors appearing in them. Codable so a filter can be persisted as the
// default (AppStorage) or as a Smart Collection.
//
// Lives in LibraryCore (rather than the app target) so its matching logic is
// pure, unit-tested, and shared by both screens from one implementation — the
// two can't drift because there is only one `matches(...)`.

import Foundation

public struct AssetFilterCriteria: Equatable, Codable, Sendable {
    public enum Logic: String, CaseIterable, Equatable, Codable, Sendable { case and = "AND", or = "OR" }
    public enum ReviewStatusFilter: String, CaseIterable, Equatable, Codable, Sendable { case all = "All", reviewed = "Reviewed", unreviewed = "Unreviewed" }

    public var reviewStatus: ReviewStatusFilter = .all
    public var minRating: Int? = nil

    /// Filter on what an external lookup concluded (schema v22).
    ///
    /// The same axis the actor filter uses, and deliberately separate from
    /// review status: a video can be fully reviewed by you and still never have
    /// been looked up, or matched by a source and never watched.
    public var enrichment: EnrichmentFilter = .any

    /// HOW the last lookup reached this video (v32).
    ///
    /// ⭐ A separate dimension rather than more `EnrichmentFilter` cases,
    /// because the two compose: "ambiguous" AND "found by fingerprint" is the
    /// quick pile, and folding them into one enum would need a case per
    /// combination.
    /// ⚠️ Optional, and nil reads as `.any` — not because absence is
    /// meaningful, but because a synthesized decoder requires a key for every
    /// NON-optional property. A Smart Collection saved before this field
    /// existed must still load, which is what `minAgeAtRelease` above is
    /// Optional for too, and what `testOlderSavedFiltersStillDecode` pins.
    public var lookupRoute: LookupRouteFilter?

    /// The route filter as the UI reads it.
    public var effectiveLookupRoute: LookupRouteFilter {
        get { lookupRoute ?? .any }
        set { lookupRoute = newValue == .any ? nil : newValue }
    }



    public var actorsLogic: Logic = .and
    public var selectedActors: Set<String> = []

    public var tagsLogic: Logic = .and
    public var selectedTags: Set<String> = []

    public var studiosLogic: Logic = .and
    public var selectedStudios: Set<String> = []

    // Actor metadata filters
    public var actorTagsLogic: Logic = .and
    public var selectedActorTags: Set<String> = []

    public var actorHairColorsLogic: Logic = .or
    public var selectedActorHairColors: Set<String> = []

    public var actorGendersLogic: Logic = .or
    public var selectedActorGenders: Set<String> = []
    public var actorCountriesLogic: Logic = .or
    public var selectedActorCountries: Set<String> = []
    /// Matches videos featuring at least one actor rated ≥ this (nil = any).
    /// Optional, so filters saved before this field existed still decode.
    public var minActorRating: Int? = nil

    /// Matches videos where a credited performer was this old at RELEASE.
    ///
    /// ⭐ The library's first filter on a fact no single record holds: it needs
    /// the video's release date and the performer's birth date together, which
    /// is exactly the join the graph exists to make cheap.
    ///
    /// ⚠️ Matched against `AgeAtRelease.possibleAges`, never `years` — see
    /// `satisfiesAgeAtRelease`. Optional so filters saved before these fields
    /// existed still decode.
    public var minAgeAtRelease: Int? = nil
    public var maxAgeAtRelease: Int? = nil

    public var isEmpty: Bool {
        reviewStatus == .all && enrichment == .any && effectiveLookupRoute == .any &&
        minRating == nil && minActorRating == nil &&
        minAgeAtRelease == nil && maxAgeAtRelease == nil &&
        selectedActors.isEmpty && selectedTags.isEmpty && selectedStudios.isEmpty &&
        selectedActorTags.isEmpty && selectedActorHairColors.isEmpty && selectedActorGenders.isEmpty
    }

    public init() {}
}

extension AssetFilterCriteria {

    /// Whether one performer's age at release satisfies the age bounds.
    ///
    /// 🚨 **Every possible age must satisfy the bounds, not just the headline
    /// number.** `AgeAtRelease` distinguishes an exact answer from one derived
    /// from a birth YEAR, where the true figure is either that number or one
    /// less because whether the birthday had come round is unknown.
    ///
    /// So an approximate 18 covers 17. Filtering on `years` would report it as
    /// certainly 18 and include a record that might not qualify — the spike
    /// named this exact failure: *"an approximate 18 silently includes 17"*.
    ///
    /// ⚠️ This is deliberately the CONSERVATIVE reading, and it excludes some
    /// records that do qualify. That asymmetry is intended: a filter that
    /// wrongly includes states something the data does not support, while one
    /// that wrongly excludes merely shows less. `AgeAtRelease.displayText`
    /// already renders an approximate age as a range for the same reason, so
    /// the boundary case is visible rather than silently decided.
    func satisfiesAgeAtRelease(_ age: AgeAtRelease) -> Bool {
        let possible = age.possibleAges
        if let minAgeAtRelease, possible.lowerBound < minAgeAtRelease { return false }
        if let maxAgeAtRelease, possible.upperBound > maxAgeAtRelease { return false }
        return true
    }

    /// The actor names appearing in `asset`, with AKA aliases resolved to their
    /// canonical name via `akaMap`. Callers pass the resolved set into
    /// `matches(...)` so the matching stays pure and free of store lookups.
    public static func mappedActors(for asset: Asset, akaMap: [String: String]) -> Set<String> {
        Set(asset.actors.map { akaMap[$0] ?? $0 })
    }

    /// Whether `asset` passes this filter's criteria.
    ///
    /// Covers the *criteria* portion only — review status, rating, the
    /// actor/tag/studio sets, and the actor-metadata sets. Sidebar-category
    /// selection and free-text search remain the caller's responsibility, since
    /// those aren't part of the persisted filter model.
    ///
    /// - Parameters:
    ///   - asset: the video to test.
    ///   - mappedActors: `asset`'s actor names with AKA aliases already
    ///     resolved (see `mappedActors(for:akaMap:)`).
    ///   - entityProfiles: actor profiles keyed by `"actor:<name>"`, used only
    ///     by the actor-metadata filters (tags/hair/gender/country). Pass an
    ///     empty map when those filters aren't in use.
    public func matches(
        _ asset: Asset,
        mappedActors: Set<String>,
        entityProfiles: EntityProfileIndex
    ) -> Bool {
        // Review status
        switch reviewStatus {
        case .all: break
        case .reviewed: if asset.status != .reviewed { return false }
        case .unreviewed: if asset.status != .unreviewed { return false }
        }

        // What an external lookup concluded. A separate axis from review
        // status: one is whether YOU have seen it, the other whether a source
        // could identify it.
        if !enrichment.accepts(asset.enrichmentState, route: asset.lookupRoute) { return false }
        if !effectiveLookupRoute.accepts(asset.lookupRoute) { return false }

        // Minimum rating (an unrated video counts as 0).
        if let minRating {
            if (asset.rating ?? 0) < minRating { return false }
        }

        // Actors
        if !selectedActors.isEmpty {
            if actorsLogic == .and {
                if !selectedActors.isSubset(of: mappedActors) { return false }
            } else {
                if selectedActors.isDisjoint(with: mappedActors) { return false }
            }
        }

        // Tags (the video's own action tags).
        //
        // Matched on FOLDED identity, not raw spelling. The surfaces that offer
        // these filters now collapse two casings of a tag into one option, so
        // comparing raw strings here would show a single choice that silently
        // matched only the videos spelled the way the label happened to be —
        // a filter that looks unified and behaves partially.
        if !selectedTags.isEmpty {
            let assetTags = Set(asset.actions.map(TagNormalizer.identityKey))
            let wanted = Set(selectedTags.map(TagNormalizer.identityKey))
            if tagsLogic == .and {
                if !wanted.isSubset(of: assetTags) { return false }
            } else {
                if wanted.isDisjoint(with: assetTags) { return false }
            }
        }

        // Studios
        if !selectedStudios.isEmpty {
            let assetStudios = Set(asset.studios)
            if studiosLogic == .and {
                if !selectedStudios.isSubset(of: assetStudios) { return false }
            } else {
                if selectedStudios.isDisjoint(with: assetStudios) { return false }
            }
        }

        // Age at release. Needs the video's date and a performer's birth date
        // together — the first filter here that no single record can answer.
        if minAgeAtRelease != nil || maxAgeAtRelease != nil {
            let ages = mappedActors.compactMap { name in
                entityProfiles[actor: name].flatMap {
                    AgeAtReleaseCalculator.age(of: $0, at: asset.releaseDate)
                }
            }
            // ⚠️ A video whose ages cannot be established does NOT match. The
            // filter asks a question about age; a record that cannot answer it
            // has not answered yes.
            guard ages.contains(where: { satisfiesAgeAtRelease($0) }) else { return false }
        }

        // Actor-metadata filters match a video through the profiles of the
        // actors appearing in it. Each specified set must pass.
        let assetActorProfiles = mappedActors.compactMap { entityProfiles[actor: $0] }

        if !selectedActorTags.isEmpty {
            let allTagsInVideo = Set(assetActorProfiles.flatMap { $0.tags })
            if actorTagsLogic == .and {
                if !selectedActorTags.isSubset(of: allTagsInVideo) { return false }
            } else {
                if selectedActorTags.isDisjoint(with: allTagsInVideo) { return false }
            }
        }

        if !selectedActorHairColors.isEmpty {
            let allHairColorsInVideo = Self.splitMetadata(assetActorProfiles.compactMap { $0.hairColor })
            if actorHairColorsLogic == .and {
                if !selectedActorHairColors.isSubset(of: allHairColorsInVideo) { return false }
            } else {
                if selectedActorHairColors.isDisjoint(with: allHairColorsInVideo) { return false }
            }
        }

        if !selectedActorGenders.isEmpty {
            let allGendersInVideo = Self.splitMetadata(assetActorProfiles.compactMap { $0.gender })
            if actorGendersLogic == .and {
                if !selectedActorGenders.isSubset(of: allGendersInVideo) { return false }
            } else {
                if selectedActorGenders.isDisjoint(with: allGendersInVideo) { return false }
            }
        }

        if !selectedActorCountries.isEmpty {
            let allCountriesInVideo = Self.splitMetadata(assetActorProfiles.compactMap { $0.countryOfOrigin })
            if actorCountriesLogic == .and {
                if !selectedActorCountries.isSubset(of: allCountriesInVideo) { return false }
            } else {
                if selectedActorCountries.isDisjoint(with: allCountriesInVideo) { return false }
            }
        }

        // At least one featured actor rated at or above the bar. A video with
        // no rated actors (or no profiled actors at all) doesn't qualify.
        if let minActorRating {
            guard assetActorProfiles.contains(where: { ($0.rating ?? 0) >= minActorRating }) else {
                return false
            }
        }

        return true
    }

    /// Splits comma-separated metadata values (e.g. a profile whose hair color
    /// is "Brown, Blonde") into a trimmed, non-empty set.
    private static func splitMetadata(_ values: [String]) -> Set<String> {
        Set(values
            .flatMap { $0.components(separatedBy: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
    }
}
