// LibraryQuery.swift
// The reusable, pure "ordered pool" queries behind Smart Shelves — and shared
// with the Quick Actions picker (Rediscover / Never Watched are the same pools).
// Each case maps a library (`[Asset]`) to an ordered result: Smart Shelves take
// a `prefix` for the preview strip and the full array for "See All", while the
// Quick Actions picker draws a random element. Pure + deterministic (inject
// `now`) so it's unit-testable and identical everywhere it's surfaced.

import Foundation

public enum LibraryQuery: String, Hashable, Sendable, CaseIterable, Codable {
    case recentlyAdded
    case topRated
    case neverWatched
    case rediscover
    case mostWatched
}

public extension LibraryQuery {
    /// Minimum star rating counted as "top rated" / eligible for Rediscover.
    static let topRatingThreshold = 4
    /// How long since last play — or since being added, if never played —
    /// before a highly-rated video counts as "rediscoverable" (~3 months).
    static let rediscoverRecency: TimeInterval = 90 * 24 * 60 * 60

    var title: String {
        switch self {
        case .recentlyAdded: return "Recently Added"
        case .topRated:      return "Top Rated"
        case .neverWatched:  return "Never Watched"
        case .rediscover:    return "Rediscover"
        case .mostWatched:   return "Most Watched"
        }
    }

    /// The full, ordered result of this query over `assets`. Pure and
    /// deterministic — inject `now` for the recency-based queries.
    func run(assets: [Asset], now: Date = Date()) -> [Asset] {
        switch self {
        case .recentlyAdded:
            return assets.sorted(by: Self.byCreatedAtDesc)

        case .topRated:
            return assets
                .filter { ($0.rating ?? 0) >= Self.topRatingThreshold }
                .sorted { a, b in
                    let ra = a.rating ?? 0, rb = b.rating ?? 0
                    if ra != rb { return ra > rb }
                    return Self.byCreatedAtDesc(a, b)
                }

        case .neverWatched:
            return assets
                .filter { $0.playCount == 0 }
                .sorted(by: Self.byCreatedAtDesc)

        case .rediscover:
            let cutoff = now.addingTimeInterval(-Self.rediscoverRecency)
            return assets
                .filter { asset in
                    guard (asset.rating ?? 0) >= Self.topRatingThreshold else { return false }
                    if let played = asset.lastPlayedAt {
                        return played <= cutoff          // played, but long ago
                    } else {
                        return asset.createdAt <= cutoff // never played, and old enough to be forgotten
                    }
                }
                .sorted { a, b in
                    // Most-forgotten first: a never-played video (nil) sorts as
                    // oldest, ahead of ones merely played long ago.
                    let la = a.lastPlayedAt ?? .distantPast
                    let lb = b.lastPlayedAt ?? .distantPast
                    if la != lb { return la < lb }
                    return Self.byCreatedAtDesc(a, b)
                }

        case .mostWatched:
            return assets
                .filter { $0.playCount >= 1 }
                .sorted { a, b in
                    if a.playCount != b.playCount { return a.playCount > b.playCount }
                    let la = a.lastPlayedAt ?? .distantPast
                    let lb = b.lastPlayedAt ?? .distantPast
                    if la != lb { return la > lb }
                    return Self.byCreatedAtDesc(a, b)
                }
        }
    }

    // Newest-first, with a UUID tiebreak so equal timestamps produce a stable,
    // deterministic order (matters for tests and for jitter-free UI).
    private static func byCreatedAtDesc(_ a: Asset, _ b: Asset) -> Bool {
        if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
        return a.id.uuidString > b.id.uuidString
    }
}
