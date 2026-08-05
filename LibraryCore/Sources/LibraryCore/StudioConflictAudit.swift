// StudioConflictAudit.swift
// Finds videos carrying more than one studio.
//
// A scene has one releasing studio, so two is not a preference or a judgement
// call — it is a record in a state that cannot be right. Detection therefore
// needs no vocabulary, no source lookup and no threshold, which makes this the
// rare cleanup that is exactly correct rather than merely likely.
//
// They are grouped by the SET of studios rather than listed per video, because
// the same wrong pairing repeats: one mis-taken match, or one enrichment run
// that added rather than replaced, produces the identical pair across every
// video it touched. Resolving the group resolves all of them at once.

import Foundation

public struct StudioConflict: Equatable, Sendable, Identifiable {
    /// The studios found together, sorted so the group is stable.
    public let studios: [String]
    public let assetIds: [UUID]
    /// How often each of these appears as the ONLY studio elsewhere in the
    /// library — the best evidence available about which is the real one.
    public let soloUseElsewhere: [String: Int]

    public var id: String { studios.joined(separator: "|") }
    public var videoCount: Int { assetIds.count }

    /// The studio to keep by default.
    ///
    /// The one used most often on its own elsewhere. A studio that stands alone
    /// across hundreds of videos is established; one that only ever appears
    /// beside another arrived by accident. Ties fall to alphabetical order so a
    /// plan is reproducible rather than dependent on dictionary ordering.
    public var suggestedKeeper: String {
        studios.max { a, b in
            let ua = soloUseElsewhere[a] ?? 0, ub = soloUseElsewhere[b] ?? 0
            return ua != ub ? ua < ub : a > b
        } ?? studios[0]
    }

    public init(studios: [String], assetIds: [UUID], soloUseElsewhere: [String: Int]) {
        self.studios = studios
        self.assetIds = assetIds
        self.soloUseElsewhere = soloUseElsewhere
    }
}

public enum StudioConflictAudit {

    public static func conflicts(in assets: [Asset]) -> [StudioConflict] {
        // Counted from videos with exactly ONE studio: a video already in the
        // broken state cannot be evidence about which of its studios is right.
        var solo: [String: Int] = [:]
        for asset in assets where asset.studios.count == 1 {
            solo[asset.studios[0], default: 0] += 1
        }

        var grouped: [String: [UUID]] = [:]
        var names: [String: [String]] = [:]
        for asset in assets where asset.studios.count > 1 {
            let sorted = asset.studios.sorted()
            let key = sorted.joined(separator: "|")
            grouped[key, default: []].append(asset.id)
            names[key] = sorted
        }

        return grouped.map { key, ids in
            let studios = names[key] ?? []
            return StudioConflict(
                studios: studios,
                assetIds: ids,
                soloUseElsewhere: Dictionary(uniqueKeysWithValues:
                    studios.map { ($0, solo[$0] ?? 0) }))
        }
        // Biggest first: one decision there fixes the most records.
        .sorted { $0.videoCount != $1.videoCount
                    ? $0.videoCount > $1.videoCount
                    : $0.id < $1.id }
    }

    /// The asset with every studio but `keeper` removed.
    ///
    /// Touches only `studio:` tags — cast and descriptive tags are stored in the
    /// same array and must survive untouched.
    public static func resolving(_ asset: Asset, keeping keeper: String) -> Asset {
        var updated = asset
        updated.tags = asset.tags.filter { tag in
            guard tag.hasPrefix("studio:") else { return true }
            return String(tag.dropFirst(7)).caseInsensitiveCompare(keeper) == .orderedSame
        }
        return updated
    }
}
