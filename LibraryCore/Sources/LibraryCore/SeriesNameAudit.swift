// SeriesNameAudit.swift
// Every series name in use, with enough evidence to decide whether to keep it.
//
// ⚠️ Series is the one entity that is NOT a node — `Asset.videoName` is a
// free-text column, by a decision the Library Graph Epic took deliberately
// (roughly 5% of the library carries one). So a series name has no profile, no
// provenance and no identity: nothing records where it came from, and there is
// no confirmed/unconfirmed state as there is for a studio.
//
// That is exactly why this audit is needed and why it can only offer HINTS.
// Two very different things share the column:
//
//   OPERATOR'S     a name set by hand to group a collection, so episode
//                  numbering sorts — one name across many videos.
//   SOURCE'S       a title that arrived with a match, frequently unique to the
//                  video it came with, and frequently wrong.
//
// Nothing distinguishes them in the data. What CAN be measured is how many
// videos share the name and how many of those were matched by a source, and
// those two figures separate the cases well in practice.

import Foundation

public struct SeriesNameUsage: Equatable, Sendable, Identifiable {
    public let name: String
    /// Videos carrying this series name.
    public let videoCount: Int
    /// How many of those were matched against an external source.
    ///
    /// ⚠️ A HINT, not provenance. A video the operator named by hand and later
    /// matched counts here too — the column does not record who wrote it. High
    /// counts mean "worth looking at", never "this came from the source".
    public let matchedCount: Int

    public var id: String { name }

    /// A name only ever used once.
    ///
    /// The strongest available signal for a title that leaked in from a match:
    /// a series exists to group videos, so one that groups nothing is usually
    /// not a series at all.
    public var isSingleUse: Bool { videoCount == 1 }

    public init(name: String, videoCount: Int, matchedCount: Int) {
        self.name = name
        self.videoCount = videoCount
        self.matchedCount = matchedCount
    }
}

public enum SeriesNameAudit {

    /// Every series name in use, most-used first.
    ///
    /// Most-used first because the names worth KEEPING are the ones grouping a
    /// real run of videos, and they should be visible without scrolling — this
    /// screen deletes things, so the safe entries leading is the right default.
    /// Ties fall to alphabetical so the list is stable between runs.
    public static func usage(in assets: [Asset]) -> [SeriesNameUsage] {
        var counts: [String: Int] = [:]
        var matched: [String: Int] = [:]

        for asset in assets {
            guard let name = asset.videoName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { continue }
            counts[name, default: 0] += 1
            if asset.enrichmentState == .matched { matched[name, default: 0] += 1 }
        }

        return counts.map {
            SeriesNameUsage(name: $0.key, videoCount: $0.value, matchedCount: matched[$0.key] ?? 0)
        }
        .sorted {
            $0.videoCount != $1.videoCount
                ? $0.videoCount > $1.videoCount
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// The videos that would be changed by clearing these names.
    ///
    /// Returned rather than counted so the screen can state the real figure
    /// before acting. Clearing a series is not reversible from inside the app.
    public static func affectedAssets(in assets: [Asset],
                                      clearing names: Set<String>) -> [Asset] {
        assets.filter { asset in
            guard let name = asset.videoName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return false }
            return names.contains(name)
        }
    }

    /// One asset with its series block removed.
    ///
    /// - Parameter includingEpisodeInfo: also clears season, episode number and
    ///   episode title.
    ///
    /// ⚠️ Off by default at every call site. A wrong series name does usually
    /// arrive with wrong episode data from the same match — but the operator's
    /// own case is the opposite: they set a series name precisely SO the
    /// episode numbers would sort, and those numbers are theirs. Taking them
    /// out as a side effect of removing a name would destroy the more valuable
    /// half of the record.
    public static func cleared(_ asset: Asset, includingEpisodeInfo: Bool) -> Asset {
        var updated = asset
        updated.videoName = nil
        if includingEpisodeInfo {
            updated.seasonNumber = nil
            updated.episodeNumber = nil
            updated.episode = nil
        }
        return updated
    }
}
