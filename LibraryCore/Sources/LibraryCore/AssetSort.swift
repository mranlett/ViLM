// AssetSort.swift
// Ordering rules for the asset grid.
//
// Extracted from AssetGridView so the sort CONTRACT can be pinned by unit tests.
// This exists so the F5 optimisation — persisting file size and modified date to
// SQLite instead of re-stat-ing every file on each sort — can be shown to produce
// byte-identical ordering to today's filesystem-driven behaviour.
//
// Pure: ordering depends only on the assets and the supplied size lookup.

import Foundation

public enum AssetSort {

    public enum Option: String, CaseIterable, Sendable {
        case seriesOrder = "Series Order"
        case name        = "Name"
        case date        = "Date Added"
        case size        = "File Size"
        /// When the video was PUBLISHED, as against when it was added here.
        ///
        /// The library's own chronology rather than the operator's: it is what
        /// makes a performer's filmography read as a career and a studio's
        /// catalogue read as a history. `Date Added` says only what order a
        /// collection was assembled in, which is a fact about the collector.
        case releaseDate = "Release Date"
    }

    /// Ordering within a series: season, then episode, then date added, then filename.
    ///
    /// A missing season is treated as Season 1 — an unnumbered entry is the original.
    /// A missing episode sorts LAST within its season, so numbered episodes lead.
    public static func seriesOrderPrecedes(_ a: Asset, _ b: Asset) -> Bool {
        let sa = a.seasonNumber ?? 1
        let sb = b.seasonNumber ?? 1
        if sa != sb { return sa < sb }
        let ea = a.episodeNumber ?? Int.max
        let eb = b.episodeNumber ?? Int.max
        if ea != eb { return ea < eb }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.fileName.localizedStandardCompare(b.fileName) == .orderedAscending
    }

    /// The ascending comparison for a given option.
    ///
    /// - Parameter fileSizes: sizes by asset id. A missing entry counts as 0, which
    ///   is why a size sort performed before sizes have loaded groups everything
    ///   together rather than failing.
    public static func precedes(
        _ a: Asset,
        _ b: Asset,
        by option: Option,
        fileSizes: [Asset.ID: Int64]
    ) -> Bool {
        switch option {
        case .seriesOrder:
            return seriesOrderPrecedes(a, b)
        case .name:
            return a.fileName.localizedStandardCompare(b.fileName) == .orderedAscending
        case .date:
            return a.createdAt < b.createdAt
        case .size:
            return (fileSizes[a.id] ?? 0) < (fileSizes[b.id] ?? 0)
        case .releaseDate:
            return releaseDatePrecedes(a, b)
        }
    }

    /// ⚠️ Videos with no release date sort LAST in ascending order, whichever
    /// direction is asked for — they are not "very old", they are unknown, and
    /// letting them lead a career view would open it on the records that say
    /// nothing about it. Ties fall back to the series order so an episode
    /// sequence released on one day still reads in order.
    static func releaseDatePrecedes(_ a: Asset, _ b: Asset) -> Bool {
        switch (normalizedReleaseDate(a), normalizedReleaseDate(b)) {
        case let (da?, db?):
            return da == db ? seriesOrderPrecedes(a, b) : da < db
        case (nil, _?): return false
        case (_?, nil): return true
        case (nil, nil): return seriesOrderPrecedes(a, b)
        }
    }

    /// ISO-8601 dates compare correctly as strings, so this only has to reject
    /// what is empty. Anything else is left to sort as the source wrote it
    /// rather than being silently reinterpreted.
    private static func normalizedReleaseDate(_ asset: Asset) -> String? {
        guard let raw = asset.releaseDate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return raw
    }

    /// Sorts assets for display.
    ///
    /// Descending negates the ascending comparison. Note that for EQUAL elements this
    /// makes the predicate non-strict (it reports both `a < b` and `b < a`), so the
    /// relative order of equal elements is not defined — in practice they come back
    /// reversed. Preserved as-is because it is the shipped behaviour; ordering among
    /// equal elements was never contractual, and Swift's sort is not stable anyway.
    public static func sorted(
        _ assets: [Asset],
        by option: Option,
        ascending: Bool,
        fileSizes: [Asset.ID: Int64] = [:]
    ) -> [Asset] {
        assets.sorted { a, b in
            let compare = precedes(a, b, by: option, fileSizes: fileSizes)
            return ascending ? compare : !compare
        }
    }
}
