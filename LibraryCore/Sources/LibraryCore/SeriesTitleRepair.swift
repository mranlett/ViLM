// SeriesTitleRepair.swift
// Titles that were written into the series field.
//
// 🚨 Measured on the device 2026-08-12: 310 distinct series values, of which
// 188 are used by exactly one video and carry no episode number. A series with
// one member and no sequence is not a series — it is a title in the wrong box.
//
// ⭐ THE RULE THE OPERATOR STATED, and the second half is what makes this safe:
//
//   • the series field is legitimate when the SOURCE supplied a series, or when
//     the operator is using it to group a studio's videos with episode numbers
//     for sequencing — the source may not consider those a series, and there is
//     no other way for the app to render them in order
//   • it is wrong when it merely repeats, or stands in for, the title
//
// ⚠️ So a grouping is preserved whenever it looks like one, and the burden of
// proof is on the repair, not on the operator's data. Where the evidence is
// ambiguous this reports and does nothing.

import Foundation
import GRDB

/// One video whose series value is really its title.
public struct SeriesTitleFinding: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        /// Series and episode hold the same text. Clear the series.
        case duplicated
        /// The series holds the title and the episode is empty. Move it.
        case titleInSeriesField
    }

    public let assetId: UUID
    public let series: String
    public let kind: Kind

    public var id: UUID { assetId }
}

/// A video the repair deliberately will not touch, and why.
public struct SeriesTitleAmbiguity: Equatable, Sendable, Identifiable {
    public let assetId: UUID
    public let series: String
    public let episode: String

    public var id: UUID { assetId }
}

public enum SeriesTitleRepair {

    public struct Report: Equatable, Sendable {
        public let repairable: [SeriesTitleFinding]
        /// 🚨 Counted and reported, never silently skipped. Both fields hold
        /// different text, so which one is the title is a judgement.
        public let needsAPerson: [SeriesTitleAmbiguity]
        /// Series values kept because they look like a real grouping.
        public let preservedGroupings: Int
    }

    /// - Parameter assets: the whole library. The decision needs the WHOLE set,
    ///   because "is this a grouping?" is a question about how many videos
    ///   share the value — not about any one video.
    public static func report(assets: [Asset]) -> Report {
        var membersBySeries: [String: Int] = [:]
        var numberedBySeries: [String: Int] = [:]
        for asset in assets {
            guard let series = asset.videoName, !series.isEmpty else { continue }
            membersBySeries[series, default: 0] += 1
            if asset.episodeNumber != nil { numberedBySeries[series, default: 0] += 1 }
        }

        // ⭐ A grouping, by the operator's own definition: more than one video
        // under the name, or an episode number sequencing it. Either is enough,
        // and a value that qualifies is never touched.
        let groupings = Set(membersBySeries.keys.filter { series in
            (membersBySeries[series] ?? 0) > 1 || (numberedBySeries[series] ?? 0) > 0
        })

        var repairable: [SeriesTitleFinding] = []
        var ambiguous: [SeriesTitleAmbiguity] = []

        for asset in assets {
            guard let series = asset.videoName, !series.isEmpty else { continue }
            guard !groupings.contains(series) else { continue }

            let episode = asset.episode ?? ""
            if episode.isEmpty {
                repairable.append(.init(assetId: asset.id, series: series,
                                        kind: .titleInSeriesField))
            } else if episode.caseInsensitiveCompare(series) == .orderedSame {
                // The operator's first rule, stated outright: if they match,
                // the series is redundant and the title is the real value.
                repairable.append(.init(assetId: asset.id, series: series,
                                        kind: .duplicated))
            } else {
                // ⚠️ Two different values. The series could be a genuine
                // one-off, and overwriting a real title with it — or discarding
                // it — is a guess either way.
                ambiguous.append(.init(assetId: asset.id, series: series,
                                       episode: episode))
            }
        }

        return Report(repairable: repairable.sorted { $0.assetId.uuidString < $1.assetId.uuidString },
                      needsAPerson: ambiguous.sorted { $0.assetId.uuidString < $1.assetId.uuidString },
                      preservedGroupings: groupings.count)
    }

    /// What to say at the top.
    public static func headline(_ report: Report) -> String {
        guard !report.repairable.isEmpty || !report.needsAPerson.isEmpty else {
            return "Every series value names a real grouping."
        }
        var parts: [String] = []
        if !report.repairable.isEmpty {
            parts.append("\(report.repairable.count) title\(report.repairable.count == 1 ? "" : "s") "
                         + "filed under a series of their own")
        }
        if !report.needsAPerson.isEmpty {
            parts.append("\(report.needsAPerson.count) where both fields differ and only you can say which is which")
        }
        return parts.joined(separator: "; ") + ". "
            + "\(report.preservedGroupings) real grouping\(report.preservedGroupings == 1 ? "" : "s") left alone."
    }

    /// The asset as it should be, or nil when nothing changes.
    ///
    /// ⭐ Pure: deciding is separable from writing, and only the deciding needs
    /// testing hard.
    public static func repaired(_ asset: Asset, _ finding: SeriesTitleFinding) -> Asset? {
        guard asset.id == finding.assetId else { return nil }
        var out = asset
        switch finding.kind {
        case .duplicated:
            // The title is already right; the series merely repeats it.
            out.videoName = nil
        case .titleInSeriesField:
            out.episode = finding.series
            out.videoName = nil
        }
        return out
    }
}

public extension LibraryStore {

    func seriesTitleReport() throws -> SeriesTitleRepair.Report {
        SeriesTitleRepair.report(assets: try fetchAllAssets())
    }

    /// Applies every repairable finding. Returns how many videos changed.
    ///
    /// ⚠️ Only the unambiguous ones. `needsAPerson` is deliberately not acted
    /// on — see `SeriesTitleRepair`.
    @discardableResult
    func repairSeriesTitles() throws -> Int {
        let report = try seriesTitleReport()
        guard !report.repairable.isEmpty else { return 0 }
        var byId: [UUID: Asset] = [:]
        for asset in try fetchAllAssets() { byId[asset.id] = asset }

        var changed = 0
        for finding in report.repairable {
            guard let asset = byId[finding.assetId],
                  let fixed = SeriesTitleRepair.repaired(asset, finding) else { continue }
            try updateAsset(fixed)
            changed += 1
        }
        return changed
    }
}
