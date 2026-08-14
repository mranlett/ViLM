// PreferenceStandings.swift
// Head to Head — reading standings back out, across every open library.
//
// 🚨 One implementation, used by the game and the leaderboard. They ask the
// same question and must get the same answer: a contender the game is about to
// offer and the same contender on the leaderboard cannot disagree about how
// many comparisons they have had, or D8's "provisional" badge would appear in
// one place and not the other.
//
// ⚠️ Standings live in the library that OWNS each contender, and a merged
// session folds one performer across several libraries by identity. Reading
// only the primary would silently show every attachment's contender as never
// played.

import Foundation
import LibraryCore

enum PreferenceStandings {

    /// Standings for these contenders, each read from its owning library.
    ///
    /// ⭐ Grouped by owner so each library is opened and read once rather than
    /// once per contender — on a 1,300-actor pool the difference is a thousand
    /// store constructions.
    ///
    /// ⚠️ A library that cannot be opened costs its contenders their history,
    /// not the caller its answer. They come back unscored, which is the same
    /// state as never having played and is the honest thing to show.
    ///
    /// ⭐ Takes ids and a way to resolve their owner rather than profiles,
    /// because D1 ranks videos too and they are owned by a different resolver.
    /// The grouping, the one-read-per-library rule and the failure behaviour
    /// are the part worth sharing, and none of it depends on what a contender
    /// is.
    static func load(ids: [String],
                     subject: PreferenceSubject,
                     owner resolveOwner: (String) -> URL?,
                     fallback: URL?) -> [String: PreferenceRecord] {
        var byOwner: [URL: [String]] = [:]
        for id in ids {
            guard let owner = resolveOwner(id) ?? fallback else { continue }
            byOwner[owner, default: []].append(id)
        }

        var out: [String: PreferenceRecord] = [:]
        for (library, contenderIds) in byOwner {
            guard let records = try? LibraryStore(at: library).preferenceRecords(subject: subject)
            else { continue }
            for id in contenderIds {
                if let record = records[id] { out[id] = record }
            }
        }
        return out
    }

    /// Standings for performers, whose owner is resolved by IDENTITY.
    ///
    /// ⚠️ Not merely a convenience. A performer is folded across libraries by
    /// identity while a video is owned by the asset map, and stating that once
    /// here is what stops a caller reaching for the wrong resolver.
    static func load(for profiles: [EntityProfile],
                     subject: PreferenceSubject,
                     fallback: URL?) -> [String: PreferenceRecord] {
        load(ids: profiles.map(\.id), subject: subject,
             owner: { LibrarySession.shared.url(forProfile: $0) }, fallback: fallback)
    }
}
