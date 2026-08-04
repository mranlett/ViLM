// ActorFilterCriteria.swift
// Moved here from the app target so its matching and sorting logic is pure,
// unit-tested, and cannot drift from what the Actor Gallery actually shows.
// Mirrors AssetFilterCriteria, which received this treatment earlier.
//
// The advanced-filter model for the Actor Gallery: quick maintenance filters
// (missing photo/gender/needs-attention), demographic filters, tag sets, and
// sort options. Codable so a filter can be persisted as the default.

import Foundation

public struct ActorFilterCriteria: Equatable, Codable, Sendable {
    public enum Logic: String, CaseIterable, Equatable, Codable, Sendable { case and = "AND", or = "OR" }

    /// The enrichment outcomes worth filtering on.
    ///
    /// `neverChecked` is not an `EnrichmentState` — it is the ABSENCE of one,
    /// and conflating it with `noMatch` would make every un-enriched actor look
    /// like a failure. It gets a filter case but no stored value.
    public enum EnrichmentFilter: String, CaseIterable, Equatable, Codable, Sendable {
        case any
        case needsAttention
        case noMatch
        case ambiguous
        case needsReview
        case matched
        case neverChecked

        public var displayName: String {
            switch self {
            case .any: return "Any"
            case .needsAttention: return "Needs attention"
            case .noMatch: return "No match"
            case .ambiguous: return "Ambiguous"
            case .needsReview: return "Needs review"
            case .matched: return "Matched"
            case .neverChecked: return "Not yet checked"
            }
        }

        /// Does a profile's recorded state satisfy this filter?
        public func accepts(_ state: EnrichmentState?) -> Bool {
            switch self {
            case .any:            return true
            case .neverChecked:   return state == nil
            case .needsAttention: return state?.needsAttention ?? false
            case .noMatch:        return state == .noMatch
            case .ambiguous:      return state == .ambiguous
            case .needsReview:    return state == .needsReview
            case .matched:        return state == .matched
            }
        }
    }

    public enum SortOption: String, CaseIterable, Codable, Sendable { case name = "Name", age = "Age", videoCount = "Video Count", dateAdded = "Date Added", rating = "Rating" }

    public var showMissingPhotosOnly: Bool = false
    public var showMissingGenderOnly: Bool = false
    public var showNeedingAttentionOnly: Bool = false

    /// Filter on what an external lookup concluded (schema v18).
    ///
    /// Deliberately separate from `showNeedingAttentionOnly`, which means
    /// "missing photo, bio or tags" — data completeness. These are different
    /// questions: an actor can be fully filled in and still have an unresolved
    /// lookup, or be sparse and never have been checked.
    public var enrichment: EnrichmentFilter = .any

    public var selectedGenders: Set<String> = []
    public var hairColor: String = ""
    public var country: String = ""

    // "Empty"/"Blank" filters: match actors *missing* a biographical detail, so
    // the gaps can be found and filled directly from the gallery. (Gender's
    // empty case is covered by `showMissingGenderOnly` above.) When one of these
    // is on, its paired value filter (`hairColor`/`country`) is ignored.
    public var matchEmptyHairColor: Bool = false
    public var matchEmptyCountry: Bool = false
    public var matchEmptyBirthYear: Bool = false

    // Minimum favorite rating (nil = any).
    public var minRating: Int? = nil

    public var tagsLogic: Logic = .and
    public var selectedTags: Set<String> = []

    public var minVideos: Int? = nil
    public var maxVideos: Int? = nil
    public var minAge: Int? = nil
    public var maxAge: Int? = nil

    public var sortBy: SortOption = .name
    public var sortDescending: Bool = false

    public var isEmpty: Bool {
        !showMissingPhotosOnly && !showMissingGenderOnly && !showNeedingAttentionOnly &&
        enrichment == .any &&
        selectedGenders.isEmpty && hairColor.isEmpty && country.isEmpty &&
        !matchEmptyHairColor && !matchEmptyCountry && !matchEmptyBirthYear && minRating == nil &&
        selectedTags.isEmpty && minVideos == nil && maxVideos == nil && minAge == nil && maxAge == nil
    }

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case showMissingPhotosOnly, showMissingGenderOnly, showNeedingAttentionOnly, enrichment
        case selectedGenders, hairColor, country
        case matchEmptyHairColor, matchEmptyCountry, matchEmptyBirthYear
        case minRating
        case tagsLogic, selectedTags
        case minVideos, maxVideos, minAge, maxAge
        case sortBy, sortDescending
    }

    // Decode every field with a default so adding new keys (like the "empty"
    // flags) never fails to decode a filter saved by an older build — a missing
    // key falls back to its default instead of throwing and silently discarding
    // the user's saved default filter. `encode` is synthesized from CodingKeys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showMissingPhotosOnly = try c.decodeIfPresent(Bool.self, forKey: .showMissingPhotosOnly) ?? false
        showMissingGenderOnly = try c.decodeIfPresent(Bool.self, forKey: .showMissingGenderOnly) ?? false
        showNeedingAttentionOnly = try c.decodeIfPresent(Bool.self, forKey: .showNeedingAttentionOnly) ?? false
        // Tolerant: a saved filter from before v18 has no value, and one written
        // by a newer build may carry a case this one does not know.
        enrichment = (try? c.decodeIfPresent(EnrichmentFilter.self, forKey: .enrichment)) .flatMap { $0 } ?? .any
        selectedGenders = try c.decodeIfPresent(Set<String>.self, forKey: .selectedGenders) ?? []
        hairColor = try c.decodeIfPresent(String.self, forKey: .hairColor) ?? ""
        country = try c.decodeIfPresent(String.self, forKey: .country) ?? ""
        matchEmptyHairColor = try c.decodeIfPresent(Bool.self, forKey: .matchEmptyHairColor) ?? false
        matchEmptyCountry = try c.decodeIfPresent(Bool.self, forKey: .matchEmptyCountry) ?? false
        matchEmptyBirthYear = try c.decodeIfPresent(Bool.self, forKey: .matchEmptyBirthYear) ?? false
        minRating = try c.decodeIfPresent(Int.self, forKey: .minRating)
        tagsLogic = try c.decodeIfPresent(Logic.self, forKey: .tagsLogic) ?? .and
        selectedTags = try c.decodeIfPresent(Set<String>.self, forKey: .selectedTags) ?? []
        minVideos = try c.decodeIfPresent(Int.self, forKey: .minVideos)
        maxVideos = try c.decodeIfPresent(Int.self, forKey: .maxVideos)
        minAge = try c.decodeIfPresent(Int.self, forKey: .minAge)
        maxAge = try c.decodeIfPresent(Int.self, forKey: .maxAge)
        sortBy = try c.decodeIfPresent(SortOption.self, forKey: .sortBy) ?? .name
        sortDescending = try c.decodeIfPresent(Bool.self, forKey: .sortDescending) ?? false
    }
}
