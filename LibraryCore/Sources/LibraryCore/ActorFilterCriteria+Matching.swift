// ActorFilterCriteria+Matching.swift
// The Actor Gallery's filter-and-sort pipeline, extracted from ActorGridView.
//
// Why this exists (issue #14, F7): the pipeline used to run INSIDE the view's
// `body`, and body evaluated it three times per pass on top of four more
// full-library vocabulary scans. Measured on device, the actor gallery produced
// ~31,000 allocations per rendered cell, 99.6% transient, averaging 267 bytes —
// the signature of string churn, not images. AssetGridView already caches its
// equivalent in `@State displayedAssets`; the actor grid never got that.
//
// Moving the logic here makes it pure and testable, which must come BEFORE any
// caching change so the cached output can be proven identical to today's.
// Behaviour is preserved exactly, including the ordering of each filter.

import Foundation

public extension ActorFilterCriteria {

    /// Everything the pipeline needs to know about one actor, gathered by the
    /// caller so this stays pure and free of view or filesystem access.
    struct ActorContext: Sendable {
        public let profile: EntityProfile?
        public let videoCount: Int
        /// True when a profile photo exists on disk, under either the primary or
        /// the hashed gallery naming scheme.
        public let hasLocalPhoto: Bool

        public init(profile: EntityProfile?, videoCount: Int, hasLocalPhoto: Bool) {
            self.profile = profile
            self.videoCount = videoCount
            self.hasLocalPhoto = hasLocalPhoto
        }
    }

    /// Does one actor survive the criteria?
    ///
    /// Filter order is preserved from the original inline implementation. Order
    /// does not affect the result — every clause is a conjunction — but keeping
    /// it makes the two readable side by side.
    func matches(actor: String, context: ActorContext) -> Bool {
        let profile = context.profile

        if showMissingPhotosOnly {
            if profile?.photoUrl != nil { return false }
            if context.hasLocalPhoto { return false }
        }

        if showMissingGenderOnly {
            guard (profile?.gender ?? "").trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        }

        if showNeedingAttentionOnly {
            let hasPhoto = context.hasLocalPhoto || profile?.photoUrl != nil
            let hasBio = !(profile?.bio ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            let hasTags = !(profile?.tags ?? []).isEmpty
            guard !hasPhoto || !hasBio || !hasTags else { return false }
        }

        if !selectedGenders.isEmpty {
            // Case-insensitive on both sides: stored values are lowercased here,
            // so the selected values must be too, or "Male" never equals "male".
            let wanted = Set(selectedGenders.map { $0.lowercased() })
            let values = Self.multiValues(profile?.gender)
            guard !wanted.isDisjoint(with: values) else { return false }
        }

        if matchEmptyHairColor {
            guard (profile?.hairColor ?? "").trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        } else if !hairColor.isEmpty {
            guard Self.multiValues(profile?.hairColor).contains(hairColor.lowercased()) else { return false }
        }

        if matchEmptyCountry {
            guard (profile?.countryOfOrigin ?? "").trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        } else if !country.isEmpty {
            guard Self.multiValues(profile?.countryOfOrigin).contains(country.lowercased()) else { return false }
        }

        // "No date of birth" — includes actors with no profile at all.
        if matchEmptyBirthYear {
            guard profile?.birthYear == nil else { return false }
        }

        if let minRating {
            guard (profile?.rating ?? 0) >= minRating else { return false }
        }

        if !selectedTags.isEmpty {
            let actorTags = Set(profile?.tags ?? [])
            let ok = tagsLogic == .and
                ? selectedTags.isSubset(of: actorTags)
                : !selectedTags.isDisjoint(with: actorTags)
            guard ok else { return false }
        }

        if let minVideos, context.videoCount < minVideos { return false }
        if let maxVideos, context.videoCount > maxVideos { return false }

        // An actor with no birth year counts as age 0 for the minimum, but is
        // EXCLUDED by a maximum — preserved from the original, asymmetric on purpose.
        if let minAge, (profile?.age ?? 0) < minAge { return false }
        if let maxAge {
            guard let age = profile?.age, age <= maxAge else { return false }
        }

        return true
    }

    /// Ordering for two actors under the current sort. Every mode falls back to
    /// name so the result is deterministic when the primary key ties.
    func precedes(_ a: String, _ b: String,
                  contextFor: (String) -> ActorContext) -> Bool {
        let ascending = !sortDescending
        switch sortBy {
        case .name:
            return ascending ? a < b : a > b
        case .age:
            let x = contextFor(a).profile?.age ?? 0
            let y = contextFor(b).profile?.age ?? 0
            if x != y { return ascending ? x < y : x > y }
            return ascending ? a < b : a > b
        case .videoCount:
            let x = contextFor(a).videoCount
            let y = contextFor(b).videoCount
            if x != y { return ascending ? x < y : x > y }
            return ascending ? a < b : a > b
        case .dateAdded:
            let x = contextFor(a).profile?.createdAt ?? Date.distantPast
            let y = contextFor(b).profile?.createdAt ?? Date.distantPast
            if x != y { return ascending ? x < y : x > y }
            return ascending ? a < b : a > b
        case .rating:
            let x = contextFor(a).profile?.rating ?? 0
            let y = contextFor(b).profile?.rating ?? 0
            if x != y { return ascending ? x < y : x > y }
            return ascending ? a < b : a > b
        }
    }

    /// Filter, then sort. The whole pipeline in one call.
    ///
    /// `searchText` and `alphaFilter` are passed separately because they are view
    /// state rather than saved criteria, matching how the grid holds them.
    func apply(to actors: [String],
               searchText: String = "",
               alphaFilter: Character? = nil,
               contextFor: (String) -> ActorContext) -> [String] {
        var result = actors

        if !searchText.isEmpty {
            result = result.filter { $0.localizedCaseInsensitiveContains(searchText) }
        }
        if let alphaFilter {
            result = result.filter { $0.uppercased().hasPrefix(String(alphaFilter)) }
        }
        result = result.filter { matches(actor: $0, context: contextFor($0)) }
        result.sort { precedes($0, $1, contextFor: contextFor) }
        return result
    }

    /// Splits a comma-separated field into trimmed, lowercased values.
    /// Several profile fields carry multiple values this way (e.g. "Brown, Red").
    static func multiValues(_ field: String?) -> [String] {
        guard let field else { return [] }
        return field.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }
}
