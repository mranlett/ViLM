// StudioOverlap.swift
// Telling two performers of one name apart by the studios they work for.
//
// 🚨 The measured case. A name search returns several people; alias overlap
// fails because these actors have few AKAs, and birth-year cross-check fails
// because the library holds no birth year. Studio is the one signal the library
// already has and has never used.
//
// ⭐ Why it is worth using, measured on the drive library 2026-08-09:
//
//   1,321 of 1,353 actors (97.6%) have at least one local studio, 814 of them
//   exactly one. Grouping actors by first name gives 993 same-first-name pairs,
//   and of the 960 where both sides have studio data, 892 — **92.9%** — have
//   DISJOINT studio sets. Two performers sharing a first name almost never
//   share a studio.
//
// ⚠️ An earlier analysis concluded the opposite, that 25 of 33 ambiguous actors
// had no local studio at all. It had asked the wrong library: 11 of those 12
// names do not exist in the catalog it measured, so "no studio" meant "not
// here". The number to remember is 97.6%, not 24%.
//
// 🚨 THIS DOES NOT DECIDE ANYTHING. It annotates, and a person decides.
//
// `ActorBatchPolicy.decisiveCandidate` deliberately returns nil when two
// candidates carry the name, because a wrong auto-match is recorded and
// "nothing brings it back for review". The 92.9% above says how often two
// same-named performers have different studios; it does NOT say how often the
// RIGHT candidate's studio data is complete. Where the correct person's scenes
// are sparsely covered and a wrong one happens to overlap, an automatic
// tie-break would confidently write a bio onto the wrong person — the exact
// failure that policy exists to prevent. That error rate cannot be measured
// from local data, only by watching whether this agrees with the operator's own
// choices. Until then it is a hint on a row.

import Foundation

/// Studios shared between the library's own record of a performer and a
/// candidate's known works.
public enum StudioOverlap {

    /// The studios the library already associates with this performer.
    ///
    /// ⚠️ Credits through AKAs as well as the literal name, matching
    /// `ActorVideoCounts.build`. The two must agree: a card reading "12 videos"
    /// beside an overlap computed from a different set of videos is a
    /// contradiction the operator has no way to resolve.
    ///
    /// Reads `asset.studios`, which is the tag-string representation — and that
    /// is correct rather than a leftover. Tag strings keep their `studio:Name`
    /// shape permanently; it is the PROFILE ids that stopped encoding names at
    /// the re-key.
    public static func localStudios(for actor: String,
                                    assets: [Asset],
                                    profiles: EntityProfileIndex) -> Set<String> {
        guard !actor.isEmpty else { return [] }

        // The names that credit this performer: their own, plus every alias
        // they list.
        var credits: Set<String> = [actor]
        if let profile = profiles[actor: actor] {
            for aka in profile.akas where !aka.isEmpty { credits.insert(aka) }
        }

        var studios: Set<String> = []
        for asset in assets where asset.actors.contains(where: { credits.contains($0) }) {
            studios.formUnion(asset.studios)
        }
        return studios
    }

    /// The studios a candidate's known works have in common with the library.
    ///
    /// Returns the LOCAL spelling of each shared studio — the operator's own
    /// vocabulary is what they will recognise on the row, not the source's.
    ///
    /// ⚠️ Folded with `StudioResolution.identity`, the same fold the rest of
    /// the studio code uses. `Silver River` and `silver-river` are one company,
    /// and a comparison that says otherwise reports no overlap for a pair that
    /// plainly matches.
    public static func shared(local: Set<String>,
                              works: [PluginCandidate]) -> [String] {
        guard !local.isEmpty, !works.isEmpty else { return [] }

        var candidateKeys: Set<String> = []
        for work in works {
            guard let name = work.studioName, !name.isEmpty else { continue }
            candidateKeys.insert(StudioResolution.identity(name))
        }
        guard !candidateKeys.isEmpty else { return [] }

        var out: [String] = []
        var seen: Set<String> = []
        for name in local.sorted() {
            let key = StudioResolution.identity(name)
            guard candidateKeys.contains(key), !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(name)
        }
        return out
    }

    /// What to put on the row, or nil when there is nothing to say.
    ///
    /// ⚠️ Nil rather than "no shared studios". An absence here means the
    /// source has not published studios for this candidate's scenes as often as
    /// it means the person is wrong, and a row asserting the latter would be
    /// evidence the data does not support.
    public static func annotation(local: Set<String>,
                                  works: [PluginCandidate]) -> String? {
        let shared = shared(local: local, works: works)
        guard !shared.isEmpty else { return nil }
        if shared.count == 1 { return "Also in your library: \(shared[0])" }
        return "Also in your library: \(shared.prefix(3).joined(separator: ", "))"
            + (shared.count > 3 ? " +\(shared.count - 3)" : "")
    }
}

public extension LibraryStore {

    /// The studios this library associates with a performer.
    ///
    /// ⚠️ Delegates to the pure function rather than asking SQL the same
    /// question. A query would have to re-express the AKA crediting rule, and a
    /// second expression of that rule is a second thing to keep in step with
    /// `ActorVideoCounts` — the drift would show up as an overlap computed over
    /// a different set of videos than the count displayed beside it.
    func studios(forActor actor: String) throws -> Set<String> {
        StudioOverlap.localStudios(for: actor,
                                   assets: try fetchAllAssets(),
                                   profiles: EntityProfileIndex(try fetchAllEntityProfiles()))
    }
}
