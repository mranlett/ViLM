// CareerArc.swift
// A performer's filmography split by how old they were when each video came out.
//
// The first thing built from the graph analysis, and the clearest example of
// what it argued: the pieces already existed and were not connected.
// `AgeAtRelease` has always computed this, carefully, and nothing ever filtered,
// sorted or grouped by it — so the app could say how old someone was in one
// video and could not show a career.
//
// ⚠️ Every edge that touches a VIDEO inherits that video's release date for
// free. That is the whole mechanism here: `video_performer` plus a release date
// plus a birth date is a career arc, with no new schema and no new edge.
//
// Pure, and here rather than in the view, because the honesty rules below are
// decisions rather than layout.

import Foundation

public enum CareerArc {

    /// One age, and what was released at it.
    public struct Section: Equatable, Sendable, Identifiable {
        /// `nil` when the age could not be established — no release date, no
        /// birth date, or a release before the birth.
        public let age: Int?
        public let assets: [Asset]
        /// ⚠️ True when ANY member's age came from a birth YEAR rather than a
        /// full date. Those are right to within a year and no better, and a
        /// section header stating a bare number would present them as exact.
        public let isApproximate: Bool

        /// `Int.min` groups the unknowns under one stable id.
        public var id: Int { age ?? Int.min }

        public var title: String {
            guard let age else { return "Age not known" }
            return isApproximate ? "Around \(age)" : "Age \(age)"
        }

        public init(age: Int?, assets: [Asset], isApproximate: Bool) {
            self.age = age
            self.assets = assets
            self.isApproximate = isApproximate
        }
    }

    /// Splits a performer's videos by their age at each release.
    ///
    /// - Parameters:
    ///   - assets: the performer's videos, already filtered to them.
    ///   - profile: the performer, for their birth date.
    ///
    /// Ascending, because a career is read forwards. Unknown ages sort **last**
    /// rather than first: they say nothing about the arc, and opening on them
    /// would bury the part that does.
    public static func sections(assets: [Asset], profile: EntityProfile?) -> [Section] {
        var buckets: [Int: [Asset]] = [:]
        var approximate: Set<Int> = []
        var unknown: [Asset] = []

        for asset in assets {
            guard let profile,
                  let age = AgeAtReleaseCalculator.age(of: profile, at: asset.releaseDate) else {
                unknown.append(asset)
                continue
            }
            buckets[age.years, default: []].append(asset)
            if !age.isExact { approximate.insert(age.years) }
        }

        var sections = buckets.keys.sorted().map { age in
            Section(age: age,
                    assets: buckets[age] ?? [],
                    isApproximate: approximate.contains(age))
        }
        if !unknown.isEmpty {
            sections.append(Section(age: nil, assets: unknown, isApproximate: false))
        }
        return sections
    }

    /// Whether splitting by age tells the operator anything.
    ///
    /// ⚠️ Requires more than one KNOWN age. A filmography where every age is
    /// unknown produces exactly one section titled "Age not known", which is a
    /// header over the whole page saying nothing — and one age means a single
    /// section with a number on it, which is not an arc either.
    public static func isWorthShowing(_ sections: [Section]) -> Bool {
        sections.filter { $0.age != nil }.count > 1
    }

    /// The span a performer's library actually evidences.
    ///
    /// Useful in its own right, and the input to a check the analysis called
    /// for: where this disagrees with the recorded `careerStartYear`, either the
    /// recorded span is wrong or a match is. Neither is visible from any single
    /// record.
    public static func evidencedAgeRange(_ sections: [Section]) -> ClosedRange<Int>? {
        let ages = sections.compactMap(\.age)
        guard let low = ages.min(), let high = ages.max() else { return nil }
        return low...high
    }
}
