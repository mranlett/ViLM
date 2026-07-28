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

    public var isEmpty: Bool {
        reviewStatus == .all && minRating == nil && minActorRating == nil &&
        selectedActors.isEmpty && selectedTags.isEmpty && selectedStudios.isEmpty &&
        selectedActorTags.isEmpty && selectedActorHairColors.isEmpty && selectedActorGenders.isEmpty
    }

    public init() {}
}

extension AssetFilterCriteria {
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
        entityProfiles: [String: EntityProfile]
    ) -> Bool {
        // Review status
        switch reviewStatus {
        case .all: break
        case .reviewed: if asset.status != .reviewed { return false }
        case .unreviewed: if asset.status != .unreviewed { return false }
        }

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

        // Tags (the video's own action tags)
        if !selectedTags.isEmpty {
            let assetTags = Set(asset.actions)
            if tagsLogic == .and {
                if !selectedTags.isSubset(of: assetTags) { return false }
            } else {
                if selectedTags.isDisjoint(with: assetTags) { return false }
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

        // Actor-metadata filters match a video through the profiles of the
        // actors appearing in it. Each specified set must pass.
        let assetActorProfiles = mappedActors.compactMap { entityProfiles["actor:\($0)"] }

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
