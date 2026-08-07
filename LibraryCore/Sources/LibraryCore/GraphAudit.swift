// GraphAudit.swift
// The graph checking itself.
//
// ⭐ The most valuable class of question the graph can answer, because these
// find data that is WRONG rather than presenting data that is already right.
// Every check here needs two records joined — a video's release date against a
// performer's birth date or recorded career — and **no single record can be
// checked against itself**. That is the argument for the edges, demonstrated
// rather than asserted.
//
// ⚠️ Reports; never repairs. A finding here means one of two or three records
// is wrong and the audit cannot know which — a video dated before a performer
// was born is certainly an error, but it could be the release date, the birth
// date, or the credit. Guessing would corrupt the record it "fixed".
//
// Pure, like `StudioAudit` and `CareerArc`. `LibraryStore` gathers.

import Foundation

public struct GraphFinding: Equatable, Sendable, Identifiable {

    public enum Kind: String, Equatable, Sendable, CaseIterable {
        /// 🚨 The video came out before a credited performer was born.
        ///
        /// Certainly wrong, and currently INVISIBLE: `AgeAtReleaseCalculator`
        /// guards `born <= released` and returns nil, which is right for
        /// display — it refuses to show a negative age — but means the app
        /// silently renders this as "age unknown" and nothing ever says so.
        case releasedBeforeBirth
        /// An age at release outside any plausible working range.
        case implausibleAge
        /// Released before the performer's recorded career began.
        case beforeCareerStart
        /// Released after the performer's recorded career ended.
        case afterCareerEnd
    }

    public let kind: Kind
    public let assetId: UUID
    /// For display — the file name, which is what the operator will recognise.
    public let videoLabel: String
    public let performer: String
    /// The specific numbers, so the row can be judged without opening anything.
    public let detail: String

    public var id: String { "\(kind.rawValue)|\(assetId.uuidString)|\(performer)" }

    public init(kind: Kind, assetId: UUID, videoLabel: String,
                performer: String, detail: String) {
        self.kind = kind
        self.assetId = assetId
        self.videoLabel = videoLabel
        self.performer = performer
        self.detail = detail
    }
}

/// Findings of one kind, for the screen.
public struct GraphCheck: Equatable, Sendable, Identifiable {
    public let kind: GraphFinding.Kind
    public let findings: [GraphFinding]

    public var id: String { kind.rawValue }
    public var count: Int { findings.count }

    /// Whether the data is definitely wrong, or merely suspect.
    ///
    /// ⚠️ Only the first is certain. The others compare a video against a
    /// **recorded** career span, and a career span from a source is frequently
    /// incomplete — an early or late credit is often the record being wrong
    /// about the career rather than the video being wrong.
    public var isCertain: Bool { kind == .releasedBeforeBirth }

    public var title: String {
        switch kind {
        case .releasedBeforeBirth: return "Released before the actor was born"
        case .implausibleAge:      return "Implausible age at release"
        case .beforeCareerStart:   return "Released before the recorded career started"
        case .afterCareerEnd:      return "Released after the recorded career ended"
        }
    }

    public var detail: String {
        switch kind {
        case .releasedBeforeBirth:
            return "One of three things is wrong: the release date, the birth date, or the cast. Nothing else can produce this. The app shows these as \"age unknown\", so they are invisible until listed here."
        case .implausibleAge:
            return "The age works out to something no working career plausibly contains. Usually a mistyped birth year or a video matched to the wrong work."
        case .beforeCareerStart:
            return "The video predates the career start on record. Often the recorded span is simply incomplete — sources rarely know the earliest work — so treat this as a prompt to check, not a verdict."
        case .afterCareerEnd:
            return "The video postdates the recorded career end. A missing end means \"still working\" and is never flagged; these have an end recorded and a release after it."
        }
    }

    public init(kind: GraphFinding.Kind, findings: [GraphFinding]) {
        self.kind = kind
        self.findings = findings
    }
}

public enum GraphAudit {

    /// The band outside which an age at release is treated as a data error.
    ///
    /// ⚠️ These are **plausibility** bounds, not a policy: they mark where the
    /// data is essentially certainly wrong rather than merely unusual. Set
    /// wide on purpose — a check that cries wolf gets switched off, and this
    /// one is worth reading.
    public static let plausibleAges = 15...85

    /// Everything the audit needs, gathered by the caller.
    public struct Input: Sendable {
        public let assets: [Asset]
        /// Performer profiles keyed by `"actor:<name>"`.
        public let profiles: [String: EntityProfile]

        public init(assets: [Asset], profiles: [String: EntityProfile]) {
            self.assets = assets
            self.profiles = profiles
        }
    }

    public static func run(_ input: Input) -> [GraphCheck] {
        var byKind: [GraphFinding.Kind: [GraphFinding]] = [:]
        for finding in findings(input) {
            byKind[finding.kind, default: []].append(finding)
        }
        return GraphFinding.Kind.allCases
            .compactMap { kind in
                guard let found = byKind[kind], !found.isEmpty else { return nil }
                return GraphCheck(kind: kind, findings: found)
            }
            // Certain first, then by size — the same ordering rule Studio
            // Health uses, so the two screens read the same way.
            .sorted {
                $0.isCertain != $1.isCertain ? $0.isCertain : $0.count > $1.count
            }
    }

    static func findings(_ input: Input) -> [GraphFinding] {
        var out: [GraphFinding] = []

        for asset in input.assets {
            guard let released = asset.releaseDate?
                .trimmingCharacters(in: .whitespacesAndNewlines), !released.isEmpty,
                  let releaseYear = year(of: released) else { continue }

            for name in Set(asset.actors) {
                guard let profile = input.profiles["actor:\(name)"] else { continue }

                // 🚨 Certain. Checked FIRST and independently of the age
                // calculator, which deliberately returns nil here — so this is
                // the only place the condition can be seen at all.
                if let born = birthYear(of: profile), releaseYear < born {
                    out.append(GraphFinding(
                        kind: .releasedBeforeBirth, assetId: asset.id,
                        videoLabel: asset.fileName, performer: name,
                        detail: "released \(releaseYear), born \(born)"))
                    // No further age reasoning about this pair: every other
                    // check would be derived from the same impossible numbers
                    // and would just repeat the finding in other words.
                    continue
                }

                if let age = AgeAtReleaseCalculator.age(of: profile, at: released),
                   isImplausible(age) {
                    out.append(GraphFinding(
                        kind: .implausibleAge, assetId: asset.id,
                        videoLabel: asset.fileName, performer: name,
                        detail: "age \(age.displayText) at release in \(releaseYear)"))
                }

                if let start = profile.careerStartYear, releaseYear < start {
                    out.append(GraphFinding(
                        kind: .beforeCareerStart, assetId: asset.id,
                        videoLabel: asset.fileName, performer: name,
                        detail: "released \(releaseYear), career recorded from \(start)"))
                }

                // ⚠️ Only when an end is RECORDED. `careerEndYear == nil` means
                // the span is open — "still performing" — not "unknown", so a
                // recent release against a nil end is correct, not a finding.
                if let end = profile.careerEndYear, releaseYear > end {
                    out.append(GraphFinding(
                        kind: .afterCareerEnd, assetId: asset.id,
                        videoLabel: asset.fileName, performer: name,
                        detail: "released \(releaseYear), career recorded to \(end)"))
                }
            }
        }
        return out
    }

    /// ⚠️ Flags only when EVERY possible age is outside the band.
    ///
    /// Same conservatism as the age filter, for the same reason: an age from a
    /// birth year alone spans two values, and reporting a borderline one as a
    /// defect would send the operator to check a record that is fine.
    static func isImplausible(_ age: AgeAtRelease) -> Bool {
        let possible = age.possibleAges
        return possible.upperBound < plausibleAges.lowerBound
            || possible.lowerBound > plausibleAges.upperBound
    }

    /// The birth year, from a full date where there is one.
    static func birthYear(of profile: EntityProfile) -> Int? {
        if let date = profile.birthDate, let parsed = EntityProfile.isoDate(date) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
            return calendar.component(.year, from: parsed)
        }
        return profile.birthYear
    }

    static func year(of isoDate: String) -> Int? {
        guard let parsed = EntityProfile.isoDate(isoDate) else {
            // A bare year is a legitimate stored form; take it as written
            // rather than discarding the record.
            return Int(isoDate.prefix(4))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar.component(.year, from: parsed)
    }
}
