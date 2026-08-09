// QuickActionPicker.swift
// The pure pick logic behind the Home Screen Quick Actions (and the in-app
// Dashboard shuffle menu). Each action resolves — at invocation time — to
// either a filtered list to open (Discover Mix) or a single video to play
// (the three direct-play actions). The Rediscover / Play-Something-New pools
// are the shared `LibraryQuery` pools; only the random-pick + fallback-ladder
// UX lives here. Pure + deterministic (inject `rng` and `now`) so it's unit
// testable and re-rolls fresh on every invocation in production.

import Foundation

public enum QuickAction: String, CaseIterable, Sendable {
    case discoverMix
    case actorSpotlight
    case rediscover
    case playSomethingNew
}

public enum QuickActionResult: Sendable, Equatable {
    /// Discover Mix: open All Assets pre-filtered.
    case openFilteredList(AssetFilterCriteria)
    /// The three direct-play actions: start this video.
    case play(Asset)
    /// Empty / unopened library — nothing to surface.
    case nothingAvailable
}

public struct QuickActionPicker {
    public init() {}

    public func pick(
        _ action: QuickAction,
        assets: [Asset],
        entityProfiles: EntityProfileIndex,
        akaMap: [String: String],
        now: Date = Date(),
        using rng: inout some RandomNumberGenerator
    ) -> QuickActionResult {
        switch action {
        case .playSomethingNew:
            return pickPlaySomethingNew(assets: assets, now: now, using: &rng)
        case .rediscover:
            return pickRediscover(assets: assets, now: now, using: &rng)
        case .actorSpotlight:
            return pickActorSpotlight(assets: assets, akaMap: akaMap, using: &rng)
        case .discoverMix:
            return pickDiscoverMix(assets: assets, entityProfiles: entityProfiles, akaMap: akaMap, using: &rng)
        }
    }

    // MARK: - Play Something New

    private func pickPlaySomethingNew(
        assets: [Asset], now: Date, using rng: inout some RandomNumberGenerator
    ) -> QuickActionResult {
        let unwatched = LibraryQuery.neverWatched.run(assets: assets, now: now)
        if let pick = unwatched.randomElement(using: &rng) { return .play(pick) }
        // Whole library watched: fall back to the least-recently-played video.
        if let leastRecent = assets.min(by: {
            ($0.lastPlayedAt ?? .distantPast) < ($1.lastPlayedAt ?? .distantPast)
        }) {
            return .play(leastRecent)
        }
        return .nothingAvailable
    }

    // MARK: - Rediscover

    private func pickRediscover(
        assets: [Asset], now: Date, using rng: inout some RandomNumberGenerator
    ) -> QuickActionResult {
        // Rung 1: the canonical Rediscover pool (4-5★, stale).
        if let pick = LibraryQuery.rediscover.run(assets: assets, now: now).randomElement(using: &rng) {
            return .play(pick)
        }
        let cutoff = now.addingTimeInterval(-LibraryQuery.rediscoverRecency)
        // Rung 2: loosen the rating bar to 3+, still stale.
        let looserRating = assets.filter { asset in
            guard (asset.rating ?? 0) >= 3 else { return false }
            if let played = asset.lastPlayedAt { return played <= cutoff }
            return asset.createdAt <= cutoff
        }
        if let pick = looserRating.randomElement(using: &rng) { return .play(pick) }
        // Rung 3: 3+★, any recency.
        let ratedOnly = assets.filter { ($0.rating ?? 0) >= 3 }
        if let pick = ratedOnly.randomElement(using: &rng) { return .play(pick) }
        return .nothingAvailable
    }

    // MARK: - Actor Spotlight

    private func pickActorSpotlight(
        assets: [Asset], akaMap: [String: String], using rng: inout some RandomNumberGenerator
    ) -> QuickActionResult {
        var byActor: [String: [Asset]] = [:]
        for asset in assets {
            for actor in AssetFilterCriteria.mappedActors(for: asset, akaMap: akaMap) {
                byActor[actor, default: []].append(asset)
            }
        }
        guard !byActor.isEmpty else { return .nothingAvailable }
        // Prefer actors with several videos; loosen the bar until one qualifies.
        for threshold in [3, 2, 1] {
            let eligible = byActor.keys.filter { (byActor[$0]?.count ?? 0) >= threshold }.sorted()
            if let actor = eligible.randomElement(using: &rng),
               let pick = (byActor[actor] ?? []).sorted(by: Self.byIdAsc).randomElement(using: &rng) {
                return .play(pick)
            }
        }
        return .nothingAvailable
    }

    // MARK: - Discover Mix

    private func pickDiscoverMix(
        assets: [Asset], entityProfiles: EntityProfileIndex, akaMap: [String: String],
        using rng: inout some RandomNumberGenerator
    ) -> QuickActionResult {
        let filmTags = Set(assets.flatMap { $0.actions }).sorted()
        guard !filmTags.isEmpty else { return .nothingAvailable }

        let actorTags = Set(assets.flatMap { asset in
            AssetFilterCriteria.mappedActors(for: asset, akaMap: akaMap)
                .compactMap { entityProfiles[actor: $0] }
                .flatMap { $0.tags }
        }).sorted()

        // Try random film × actor-tag pairings, re-rolling past empty ones.
        if !actorTags.isEmpty {
            for _ in 0..<12 {
                guard let film = filmTags.randomElement(using: &rng),
                      let actorTag = actorTags.randomElement(using: &rng) else { break }
                var criteria = AssetFilterCriteria()
                criteria.selectedTags = [film]
                criteria.selectedActorTags = [actorTag]
                let matches = assets.contains { asset in
                    criteria.matches(
                        asset,
                        mappedActors: AssetFilterCriteria.mappedActors(for: asset, akaMap: akaMap),
                        entityProfiles: entityProfiles)
                }
                if matches { return .openFilteredList(criteria) }
            }
        }
        // No workable pairing: a single random film tag is guaranteed non-empty.
        if let film = filmTags.randomElement(using: &rng) {
            var criteria = AssetFilterCriteria()
            criteria.selectedTags = [film]
            return .openFilteredList(criteria)
        }
        return .nothingAvailable
    }

    private static func byIdAsc(_ a: Asset, _ b: Asset) -> Bool {
        a.id.uuidString < b.id.uuidString
    }
}
