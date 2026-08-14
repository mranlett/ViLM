// StudioSignature.swift
// What a studio's catalogue says about WHEN in a career it works.
//
// ⭐ The operator's own question, recorded in *What the Graph Could Answer*:
// "studios feature different actors at different times — beginning of career,
// end of a career." Computable with no new schema: every `video_studio` edge
// reaches a release date through the video, and every `video_performer` edge
// reaches a career start through the profile. The difference between them is
// how far into a career that appearance was.
//
// ⭐ Why this is worth having: it is a claim no single record supports. A studio
// acquires a character that is MEASURED rather than asserted — one that
// consistently appears in the first two years of careers is a discovery house;
// one that appears a decade in is a late-career or redistribution label.
//
// 🚨 THE MEDIAN, NEVER THE MEAN. A performer credited on a video released
// forty-one years before their recorded career start exists in this library
// (35 such observations of 3,052, measured 2026-08-14). One of those drags a
// mean into nonsense while barely moving a median — and the impossible ones are
// excluded and COUNTED anyway, because a signature quietly computed from
// contradictory records is worse than no signature.

import Foundation
import GRDB

/// One appearance, placed in the performer's career.
public struct CareerStageObservation: Equatable, Sendable {
    public let studioId: String
    public let performerId: String
    /// Years between the performer's recorded career start and this release.
    /// Negative means the records contradict each other.
    public let yearsIntoCareer: Int

    public init(studioId: String, performerId: String, yearsIntoCareer: Int) {
        self.studioId = studioId
        self.performerId = performerId
        self.yearsIntoCareer = yearsIntoCareer
    }
}

public struct StudioSignature: Equatable, Sendable, Identifiable {
    public let studioId: String
    public let observations: Int
    /// ⚠️ Distinct performers, reported beside the observation count. Twenty
    /// observations of one performer is not twenty pieces of evidence, and the
    /// two numbers together are the only way to see the difference.
    public let performers: Int
    public let medianYearsIntoCareer: Double
    /// The share of appearances made in a performer's first two years.
    public let shareInFirstTwoYears: Double
    public let character: Character

    public var id: String { studioId }

    public enum Character: String, Equatable, Sendable {
        /// Half or more of its appearances are somebody's first two years.
        case discovery
        /// A median of a decade or more into a career.
        case lateCareer
        /// Everything in between, which is most studios and is not a finding.
        case established
    }
}

public struct StudioSignatureReport: Equatable, Sendable {
    public let signatures: [StudioSignature]
    /// Studios seen, but with too little evidence to characterise.
    public let studiosBelowEvidenceFloor: Int
    /// 🚨 Observations discarded because the video predates the recorded
    /// career start. Surfaced, never silently dropped: each one is either a bad
    /// match or a bad career record, and both are worth knowing about.
    public let impossibleObservations: Int

    public var isEmpty: Bool { signatures.isEmpty }
}

public enum StudioSignatureAnalysis {

    /// ⚠️ Measured defaults, not invented ones. On the drive library
    /// (2026-08-14): 3,052 observations across 328 studios, of which 121 clear
    /// a floor of five. Below that a "signature" is one or two videos and the
    /// word is a lie.
    public struct Thresholds: Equatable, Sendable {
        public var minimumObservations: Int
        /// Being in the first two years means years 0 and 1.
        public var earlyCareerYears: Int
        /// Half or more early appearances makes a discovery house.
        public var discoveryShare: Double
        /// A median at or past this is a late-career label.
        public var lateCareerMedian: Double

        public init(minimumObservations: Int = 5, earlyCareerYears: Int = 2,
                    discoveryShare: Double = 0.5, lateCareerMedian: Double = 10) {
            self.minimumObservations = minimumObservations
            self.earlyCareerYears = earlyCareerYears
            self.discoveryShare = discoveryShare
            self.lateCareerMedian = lateCareerMedian
        }
    }

    public static func analyse(_ observations: [CareerStageObservation],
                               thresholds: Thresholds = .init()) -> StudioSignatureReport {
        let impossible = observations.filter { $0.yearsIntoCareer < 0 }
        let usable = observations.filter { $0.yearsIntoCareer >= 0 }

        var byStudio: [String: [CareerStageObservation]] = [:]
        for observation in usable { byStudio[observation.studioId, default: []].append(observation) }

        var signatures: [StudioSignature] = []
        var belowFloor = 0

        for (studioId, rows) in byStudio {
            guard rows.count >= thresholds.minimumObservations else {
                belowFloor += 1
                continue
            }
            let stages = rows.map(\.yearsIntoCareer).sorted()
            let median = Self.median(of: stages)
            let early = Double(stages.filter { $0 < thresholds.earlyCareerYears }.count)
                / Double(stages.count)

            // ⚠️ Discovery is tested first. A studio can be both mostly-early
            // AND have a long tail that pushes its median past ten; the early
            // share is the more specific claim and the more useful one.
            let character: StudioSignature.Character
            if early >= thresholds.discoveryShare {
                character = .discovery
            } else if median >= thresholds.lateCareerMedian {
                character = .lateCareer
            } else {
                character = .established
            }

            signatures.append(StudioSignature(
                studioId: studioId,
                observations: rows.count,
                performers: Set(rows.map(\.performerId)).count,
                medianYearsIntoCareer: median,
                shareInFirstTwoYears: early,
                character: character))
        }

        return StudioSignatureReport(
            // Most evidence first within a character, so the strongest claims
            // lead; id last so a redraw never reorders what is being read.
            signatures: signatures.sorted {
                $0.observations != $1.observations
                    ? $0.observations > $1.observations
                    : $0.studioId < $1.studioId
            },
            studiosBelowEvidenceFloor: belowFloor,
            impossibleObservations: impossible.count)
    }

    /// 🚨 A true median, including the even case. Taking the lower middle would
    /// bias every even-sized studio one year earlier, which is exactly the
    /// direction that manufactures discovery houses.
    static func median(of sorted: [Int]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return Double(sorted[middle]) }
        return Double(sorted[middle - 1] + sorted[middle]) / 2
    }
}

public extension LibraryStore {

    /// Every appearance that can be placed in a career.
    ///
    /// ⚠️ Requires all four facts to line up — a studio edge, a performer edge,
    /// a release date on the video and a career start on the performer. A video
    /// missing any of them contributes nothing rather than a guess.
    func careerStageObservations() throws -> [CareerStageObservation] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT vs.studio_id AS studio, vp.performer_id AS performer,
                       CAST(substr(a.release_date, 1, 4) AS INTEGER) - p.career_start_year AS stage
                FROM video_performer vp
                JOIN video_studio vs ON vs.video_id = vp.video_id
                JOIN assets a ON a.id = vp.video_id
                JOIN entity_profiles p ON p.id = vp.performer_id
                WHERE a.release_date IS NOT NULL AND a.release_date <> ''
                  AND p.career_start_year IS NOT NULL
                  AND CAST(substr(a.release_date, 1, 4) AS INTEGER) > 1900
                """)
                .map { CareerStageObservation(studioId: $0["studio"],
                                              performerId: $0["performer"],
                                              yearsIntoCareer: $0["stage"]) }
        }
    }

    func studioSignatures(thresholds: StudioSignatureAnalysis.Thresholds = .init())
    throws -> StudioSignatureReport {
        StudioSignatureAnalysis.analyse(try careerStageObservations(), thresholds: thresholds)
    }
}
