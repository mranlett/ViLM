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
        /// Worked after their recorded career ended.
        ///
        /// ⭐ NOT an error, and deliberately not presented as one. A performer
        /// can come out of retirement, footage shot earlier can be released
        /// later, and a recorded end year is a source's summary rather than a
        /// fact about the world. Every explanation is ordinary — this is an
        /// interesting datapoint about a career, not a contradiction.
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

    /// How much of a problem a finding is.
    ///
    /// ⚠️ Three levels, not two. A binary "certain or suspect" forced every
    /// non-certain check under a heading reading *Impossible Data*, which is
    /// simply wrong for some of them — a performer working after a recorded
    /// retirement is an ordinary thing that happens, not a contradiction, and
    /// filing it beside "released before they were born" trains the operator to
    /// distrust the whole screen.
    public enum Severity: Equatable, Sendable {
        /// Something is definitely wrong. Only one check can say this.
        case certain
        /// Probably wrong, worth opening. Compares a video against a
        /// **recorded** career span, and such spans are frequently incomplete.
        case suspect
        /// ⭐ Not wrong at all. Worth knowing, and nothing needs fixing.
        case notable
    }

    public var severity: Severity {
        switch kind {
        case .releasedBeforeBirth: return .certain
        case .implausibleAge, .beforeCareerStart: return .suspect
        case .afterCareerEnd: return .notable
        }
    }

    public var isCertain: Bool { severity == .certain }

    public var title: String {
        switch kind {
        case .releasedBeforeBirth: return "Released before the actor was born"
        case .implausibleAge:      return "Implausible age at release"
        case .beforeCareerStart:   return "Released before the recorded career started"
        case .afterCareerEnd:      return "Worked after their recorded career ended"
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
            return "Nothing here needs fixing. A performer can return from retirement, and footage shot earlier is often released later — a recorded end year is a source's summary, not a fact about the world. Listed because it is interesting: these are the late credits in a career. A missing end means \"still working\" and is never flagged."
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
        /// The library's profiles, reached by name through the index.
        public let profiles: EntityProfileIndex

        public init(assets: [Asset], profiles: EntityProfileIndex) {
            self.assets = assets
            self.profiles = profiles
        }
    }

    public static func run(_ input: Input) -> [GraphCheck] {
        var byKind: [GraphFinding.Kind: [GraphFinding]] = [:]
        for finding in findings(input) {
            byKind[finding.kind, default: []].append(finding)
        }
        return ordered(GraphFinding.Kind.allCases.compactMap { kind in
            guard let found = byKind[kind], !found.isEmpty else { return nil }
            return GraphCheck(kind: kind, findings: found)
        })
    }

    /// Worst first, then by size — the same ordering rule Studio Health uses,
    /// so the two screens read the same way.
    ///
    /// ⭐ `.notable` always sorts LAST regardless of size. It is not a problem,
    /// and a large pile of interesting-but-fine findings must never push a
    /// genuine contradiction below the fold.
    ///
    /// Extracted so it can be asserted: the app target has no test target, so a
    /// presentation rule left inside a `View` is a rule nothing checks.
    public static func ordered(_ checks: [GraphCheck]) -> [GraphCheck] {
        func rank(_ check: GraphCheck) -> Int {
            switch check.severity {
            case .certain: return 0
            case .suspect: return 1
            case .notable: return 2
            }
        }
        return checks.sorted {
            rank($0) != rank($1) ? rank($0) < rank($1) : $0.count > $1.count
        }
    }

    static func findings(_ input: Input) -> [GraphFinding] {
        var out: [GraphFinding] = []

        for asset in input.assets {
            guard let released = asset.releaseDate?
                .trimmingCharacters(in: .whitespacesAndNewlines), !released.isEmpty,
                  let releaseYear = year(of: released) else { continue }

            for name in Set(asset.actors) {
                guard let profile = input.profiles[actor: name] else { continue }

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
