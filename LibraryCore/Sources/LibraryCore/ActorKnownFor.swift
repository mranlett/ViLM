// ActorKnownFor.swift
// What the library already knows this performer for.
//
// ⭐ Added at the operator's direction after playing Head to Head: the photo
// should be a REMINDER of who this is, not the thing being judged. A couple of
// titles turns "which of these faces" into "which of these performers", which
// is the judgement the ranking is supposed to elicit and what the downstream
// recommendation work needs.
//
// ⚠️ The count is shown too, knowingly. It is a popularity signal leaking into
// a preference judgement — a performer in fourteen of your videos will tend to
// beat one in two, whatever you think of either. The operator was told and
// chose to have it, so this is a DELIBERATE trade and not an oversight to be
// tidied away later.

import Foundation

public enum ActorKnownFor {

    /// What to show beside a performer.
    public struct Summary: Equatable, Sendable {
        /// A few titles, best-first. Empty when nothing has a usable name.
        public let titles: [String]
        /// Every video crediting them — NOT just the ones listed above.
        public let videoCount: Int

        public init(titles: [String], videoCount: Int) {
            self.titles = titles
            self.videoCount = videoCount
        }
    }

    /// Every performer's summary, in ONE pass over the assets.
    ///
    /// ⚠️ Credits through AKAs exactly as `ActorVideoCounts.build` does, and
    /// there is a test asserting the two agree. They are displayed together —
    /// a card reading "14 videos" beside a game showing "in 9 of your videos"
    /// is a contradiction the operator has no way to resolve, and the rule is
    /// subtle enough (an asset crediting both a canonical name and one of its
    /// aliases counts ONCE) that a second expression of it would drift.
    public static func build(assets: [Asset],
                             profiles: EntityProfileIndex,
                             limit: Int = 3) -> [String: Summary] {

        var akaOwners: [String: Set<String>] = [:]
        for profile in profiles.actors {
            let canonical = profile.name
            for aka in profile.akas where !aka.isEmpty {
                akaOwners[aka, default: []].insert(canonical)
            }
        }

        var byActor: [String: [Asset]] = [:]
        for asset in assets {
            var credited = Set<String>()
            for name in asset.actors {
                credited.insert(name)
                if let owners = akaOwners[name] { credited.formUnion(owners) }
            }
            for actor in credited { byActor[actor, default: []].append(asset) }
        }

        return byActor.mapValues { videos in
            Summary(titles: bestTitles(from: videos, limit: limit),
                    videoCount: videos.count)
        }
    }

    /// The titles most likely to jog a memory.
    ///
    /// ⚠️ Deterministic, and that matters more than it sounds. The same
    /// performer appears in many pairs over a session, and a list that
    /// reordered itself between appearances would read as different
    /// information about the same person.
    ///
    /// Newest first by release date, because a recent one is the likelier
    /// memory; nils last, because "no date" is not "oldest". Ties and undated
    /// videos fall back to the title, so the order never depends on how the
    /// assets happened to be loaded.
    static func bestTitles(from videos: [Asset], limit: Int) -> [String] {
        let named = videos.compactMap { asset -> (title: String, date: String?)? in
            let title = displayTitle(asset)
            return title.isEmpty ? nil : (title, asset.releaseDate)
        }
        let ordered = named.sorted {
            switch ($0.date, $1.date) {
            case let (a?, b?) where a != b: return a > b
            case (nil, _?): return false
            case (_?, nil): return true
            default: return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }

        // ⚠️ Deduped by title. Two files of one scene are one thing to be
        // reminded of, and showing it twice wastes a line the game cannot
        // spare.
        var seen = Set<String>()
        return ordered.compactMap { seen.insert($0.title).inserted ? $0.title : nil }
            .prefix(limit)
            .map { $0 }
    }

    /// ⭐ The series/episode block where there is one, the file name otherwise.
    /// A file name is a poor title but a perfectly good reminder, and dropping
    /// those videos would leave the least-catalogued performers with nothing
    /// shown — which is the opposite of helpful.
    static func displayTitle(_ asset: Asset) -> String {
        let block = asset.seriesTitleBlock.trimmingCharacters(in: .whitespaces)
        if !block.isEmpty { return block }
        return (asset.fileName as NSString).deletingPathExtension
    }
}
