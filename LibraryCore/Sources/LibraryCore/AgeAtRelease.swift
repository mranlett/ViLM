// AgeAtRelease.swift
// How old someone was when a video was published.
//
// Derived, never stored: both inputs can change — a birth date gets corrected,
// a release date arrives from a later match — and a cached answer would quietly
// disagree with the record it came from.
//
// The distinction this type exists to preserve is EXACT versus APPROXIMATE. A
// full birth date against a full release date gives a real answer. A birth YEAR
// gives a number that is right to within a year and no better, because whether
// the birthday had happened yet is simply unknown. Both are useful; presenting
// the second as though it were the first would be stating something the data
// does not support, so they are different values and they display differently.

import Foundation

public struct AgeAtRelease: Equatable, Sendable {
    /// Completed years at the release date.
    public let years: Int
    /// True when both dates were full calendar days.
    ///
    /// When false, `years` is derived from years alone and the true figure is
    /// either this or one less — the birthday may not have come round yet.
    public let isExact: Bool

    public init(years: Int, isExact: Bool) {
        self.years = years
        self.isExact = isExact
    }

    /// The narrowest honest statement of the age.
    ///
    /// An approximate value is rendered as a range rather than a number so it
    /// cannot be read as precise, and so a filter's boundary case is visible
    /// rather than silently decided.
    public var displayText: String {
        isExact ? "\(years)" : "\(years - 1)–\(years)"
    }

    /// Every age this could be. One value when exact, two when not.
    ///
    /// This is what a filter must test against: an approximate 18 covers 17 as
    /// well, and treating it as certainly 18 would include records that might
    /// not qualify.
    public var possibleAges: ClosedRange<Int> {
        isExact ? years...years : (years - 1)...years
    }
}

public enum AgeAtReleaseCalculator {

    /// Age at a release, or nil when it cannot be established.
    ///
    /// Returns nil rather than guessing when either date is missing. Nil means
    /// "not known", and callers must not render it as zero or filter on it as
    /// though it were a low number.
    public static func age(birthDate: String?,
                           birthYear: Int?,
                           releaseDate: String?) -> AgeAtRelease? {
        guard let releaseDate, let released = EntityProfile.isoDate(releaseDate) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current

        if let birthDate, let born = EntityProfile.isoDate(birthDate) {
            guard born <= released else { return nil }
            guard let years = calendar.dateComponents([.year], from: born, to: released).year else {
                return nil
            }
            return AgeAtRelease(years: years, isExact: true)
        }

        guard let birthYear else { return nil }
        let releaseYear = calendar.component(.year, from: released)
        let difference = releaseYear - birthYear
        // A release before the birth year is a data error somewhere, not a
        // negative age. Saying nothing is better than saying something wrong.
        guard difference >= 0 else { return nil }
        return AgeAtRelease(years: difference, isExact: false)
    }

    public static func age(of profile: EntityProfile, at releaseDate: String?) -> AgeAtRelease? {
        age(birthDate: profile.birthDate, birthYear: profile.birthYear, releaseDate: releaseDate)
    }

    /// Ages for everyone credited on a video, keyed by actor name.
    ///
    /// Actors whose age cannot be established are absent from the result rather
    /// than present with a nil — a caller iterating this should see only what
    /// is actually known.
    public static func ages(for asset: Asset,
                            profiles: EntityProfileIndex) -> [String: AgeAtRelease] {
        guard let releaseDate = asset.releaseDate else { return [:] }
        var result: [String: AgeAtRelease] = [:]
        for name in asset.actors {
            // ⭐ One lookup where there were two. The old `?? profiles[name]`
            // fallback existed because some callers passed a name-keyed
            // dictionary and some an id-keyed one; the index takes a name and
            // is the only shape, so the ambiguity is gone rather than handled.
            guard let profile = profiles[actor: name] else { continue }
            guard let age = age(of: profile, at: releaseDate) else { continue }
            result[name] = age
        }
        return result
    }

    /// Whether any credited actor's age at release falls inside `range`.
    ///
    /// An APPROXIMATE age matches when any year it could be falls in range.
    /// The alternative — treating the derived number as certain — would filter
    /// a record in or out on a fact nobody knows, and the whole point of
    /// carrying `isExact` is to avoid exactly that.
    public static func anyActorAge(for asset: Asset,
                                   profiles: EntityProfileIndex,
                                   within range: ClosedRange<Int>) -> Bool {
        ages(for: asset, profiles: profiles).values.contains { age in
            age.possibleAges.overlaps(range)
        }
    }

    /// Videos where an age at release could not be worked out at all.
    ///
    /// Worth surfacing separately: "no release date recorded" and "nobody in it
    /// has a birth date" are both reasons a video is missing from an age
    /// filter, and neither is the same as the actor being outside the range.
    public static func isAgeKnown(for asset: Asset,
                                  profiles: EntityProfileIndex) -> Bool {
        !ages(for: asset, profiles: profiles).isEmpty
    }
}
