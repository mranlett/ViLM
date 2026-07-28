// ActorFilterCriteria.swift
// The advanced-filter model for the Actor Gallery: quick maintenance filters
// (missing photo/gender/needs-attention), demographic filters, tag sets, and
// sort options. Codable so a filter can be persisted as the default.

import Foundation

struct ActorFilterCriteria: Equatable, Codable {
    enum Logic: String, CaseIterable, Equatable, Codable { case and = "AND", or = "OR" }

    enum SortOption: String, CaseIterable, Codable { case name = "Name", age = "Age", videoCount = "Video Count", dateAdded = "Date Added", rating = "Rating" }

    var showMissingPhotosOnly: Bool = false
    var showMissingGenderOnly: Bool = false
    var showNeedingAttentionOnly: Bool = false

    var selectedGenders: Set<String> = []
    var hairColor: String = ""
    var country: String = ""

    // "Empty"/"Blank" filters: match actors *missing* a biographical detail, so
    // the gaps can be found and filled directly from the gallery. (Gender's
    // empty case is covered by `showMissingGenderOnly` above.) When one of these
    // is on, its paired value filter (`hairColor`/`country`) is ignored.
    var matchEmptyHairColor: Bool = false
    var matchEmptyCountry: Bool = false
    var matchEmptyBirthYear: Bool = false

    // Minimum favorite rating (nil = any).
    var minRating: Int? = nil

    var tagsLogic: Logic = .and
    var selectedTags: Set<String> = []

    var minVideos: Int? = nil
    var maxVideos: Int? = nil
    var minAge: Int? = nil
    var maxAge: Int? = nil

    var sortBy: SortOption = .name
    var sortDescending: Bool = false

    var isEmpty: Bool {
        !showMissingPhotosOnly && !showMissingGenderOnly && !showNeedingAttentionOnly &&
        selectedGenders.isEmpty && hairColor.isEmpty && country.isEmpty &&
        !matchEmptyHairColor && !matchEmptyCountry && !matchEmptyBirthYear && minRating == nil &&
        selectedTags.isEmpty && minVideos == nil && maxVideos == nil && minAge == nil && maxAge == nil
    }

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case showMissingPhotosOnly, showMissingGenderOnly, showNeedingAttentionOnly
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
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showMissingPhotosOnly = try c.decodeIfPresent(Bool.self, forKey: .showMissingPhotosOnly) ?? false
        showMissingGenderOnly = try c.decodeIfPresent(Bool.self, forKey: .showMissingGenderOnly) ?? false
        showNeedingAttentionOnly = try c.decodeIfPresent(Bool.self, forKey: .showNeedingAttentionOnly) ?? false
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
