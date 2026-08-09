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
    static func load(for profiles: [EntityProfile],
                     subject: PreferenceSubject,
                     fallback: URL?) -> [String: PreferenceRecord] {
        var byOwner: [URL: [String]] = [:]
        for profile in profiles {
            guard let owner = LibrarySession.shared.url(forProfile: profile.id) ?? fallback
            else { continue }
            byOwner[owner, default: []].append(profile.id)
        }

        var out: [String: PreferenceRecord] = [:]
        for (owner, ids) in byOwner {
            guard let records = try? LibraryStore(at: owner).preferenceRecords(subject: subject)
            else { continue }
            for id in ids {
                if let record = records[id] { out[id] = record }
            }
        }
        return out
    }
}
