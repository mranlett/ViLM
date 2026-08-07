// StudioSpellingAudit.swift
// One studio stored under two spellings.
//
// ⚠️ This exists because *Repair Tag Spelling* cannot do it. That tool reads
// `Asset.actions`, which filters to `tag:` values — a `studio:` value is never
// in the set it examines. Studio Health used to route these findings there,
// which sent the operator to a screen structurally incapable of the job.
//
// The collisions are real and common: a source that runs the spaces out of a
// name produces "Coast Line" and "Coastline" as separate studios, and the
// filters already fold both to one — so the split is invisible everywhere
// except the places that list studios, where it shows as two cards.

import Foundation

public struct StudioSpellingCollision: Equatable, Sendable, Identifiable {
    /// The folded identity the spellings share.
    public let key: String
    /// Every spelling found, most-used first.
    public let spellings: [(spelling: String, uses: Int)]

    public var id: String { key }
    public var totalUses: Int { spellings.reduce(0) { $0 + $1.uses } }

    /// The spelling to keep by default.
    ///
    /// Most-used wins. A tie goes to the spelling with **more word
    /// separation** — "Coast Line" over "Coastline" — because a run-together
    /// name is what a source produces when it drops the spaces, and the spaced
    /// form is the one a person wrote. Then more capitals, then alphabetical so
    /// a plan is reproducible rather than dependent on dictionary ordering.
    public var suggestedKeeper: String {
        let best = spellings.max { a, b in
            if a.uses != b.uses { return a.uses < b.uses }
            let sa = separators(a.spelling), sb = separators(b.spelling)
            if sa != sb { return sa < sb }
            let ca = capitals(a.spelling), cb = capitals(b.spelling)
            if ca != cb { return ca < cb }
            return a.spelling > b.spelling
        }
        return best?.spelling ?? spellings.first?.spelling ?? key
    }

    public var losers: [String] {
        spellings.map(\.spelling).filter { $0 != suggestedKeeper }
    }

    private func separators(_ value: String) -> Int {
        value.filter { $0 == " " || $0 == "-" || $0 == "." }.count
    }
    private func capitals(_ value: String) -> Int { value.filter(\.isUppercase).count }

    public init(key: String, spellings: [(spelling: String, uses: Int)]) {
        self.key = key
        self.spellings = spellings
    }

    public static func == (a: StudioSpellingCollision, b: StudioSpellingCollision) -> Bool {
        a.key == b.key
            && a.spellings.map(\.spelling) == b.spellings.map(\.spelling)
            && a.spellings.map(\.uses) == b.spellings.map(\.uses)
    }
}

public enum StudioSpellingAudit {

    /// Studios whose spellings differ only by case or spacing.
    ///
    /// ⚠️ Folded with `StudioResolution.identity`, the same function the
    /// matcher uses to decide two studios are the same — not `lowercased()`.
    /// A case-only fold would miss the run-together spellings, which are the
    /// majority of real collisions.
    public static func collisions(in assets: [Asset]) -> [StudioSpellingCollision] {
        var counts: [String: Int] = [:]
        for asset in assets {
            // Per ASSET: a video naming the same studio twice counts once.
            for studio in Set(asset.studios) where !studio.isEmpty {
                counts[studio, default: 0] += 1
            }
        }

        var grouped: [String: [(String, Int)]] = [:]
        for (name, uses) in counts {
            grouped[StudioResolution.identity(name), default: []].append((name, uses))
        }

        return grouped
            .filter { $0.value.count > 1 }
            .map { key, values in
                StudioSpellingCollision(
                    key: key,
                    spellings: values
                        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
                        .map { (spelling: $0.0, uses: $0.1) })
            }
            // Biggest first: one decision there fixes the most records.
            .sorted { $0.totalUses != $1.totalUses ? $0.totalUses > $1.totalUses : $0.key < $1.key }
    }
}
