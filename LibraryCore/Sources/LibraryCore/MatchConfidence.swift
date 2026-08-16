// MatchConfidence.swift
// How much to trust a fingerprint hit.
//
// 🚨 EVERY FINGERPRINT HIT IS CURRENTLY TREATED AS EQUALLY EXACT. A perceptual
// hash goes out, a match comes back, and it is recorded with no measure of how
// much the source's own data supports it. On the drive library that is 773
// matches — more than any other method — each presented with the same
// confidence as an operator's own deliberate choice.
//
// ⚠️ This is the failure shape this project keeps finding: not a wrong answer,
// a CONFIDENTLY-PRESENTED one. A single-submission fingerprint wearing the same
// face as a heavily-corroborated one is exactly that.
//
// 🔴 D4 — IT MUST NEVER AUTO-REJECT. A low-confidence match is still very often
// right. Everything here surfaces doubt so a person can look; nothing in this
// file un-matches anything, and no caller is given the means to.

import Foundation

/// What the source said about the fingerprint behind a match.
///
/// ⚠️ Every field is optional and `nil` means THE SOURCE DID NOT SAY, never
/// zero and never "no". A source supplying none of this must leave the match
/// exactly as it is today (C5), which is only possible if absence is a state
/// rather than a value.
public struct MatchConfidence: Codable, Equatable, Sendable {

    /// How many people independently submitted this fingerprint for this scene.
    ///
    /// ⭐ D1 — a crowd of one is not a crowd. Forty submissions is a different
    /// claim from one person who may have mis-tagged their own file.
    public var submissions: Int?

    /// The runtime, in seconds, that the fingerprint was taken from.
    public var fingerprintDuration: Double?

    /// Which algorithm produced the hit.
    ///
    /// ⚠️ D5 — groundwork, not a feature. Storing it costs nothing and is what
    /// makes multi-algorithm matching possible later; nothing reads it yet, and
    /// that is fine.
    public var algorithm: String?

    /// 🚨 D3 — when this was recorded, not when it is read.
    ///
    /// The submission count moves as other people contribute, so a number
    /// fetched later describes a different moment. Without an as-of, a stored
    /// confidence silently becomes a claim about the wrong day.
    public var asOf: Date?

    public var isEmpty: Bool {
        submissions == nil && fingerprintDuration == nil && algorithm == nil
    }

    public init(submissions: Int? = nil, fingerprintDuration: Double? = nil,
                algorithm: String? = nil, asOf: Date? = nil) {
        self.submissions = submissions
        self.fingerprintDuration = fingerprintDuration
        self.algorithm = algorithm
        self.asOf = asOf
    }
}

/// A reason to look again. Never a reason to act automatically.
public enum MatchDoubt: String, Equatable, Sendable, CaseIterable, Codable {

    /// 🔴 D2 — the cheapest lie-detector available, and the single
    /// highest-value line in this feature.
    ///
    /// We know the local file's runtime and the source tells us the runtime its
    /// fingerprint came from. A hash collision or a mis-submitted fingerprint
    /// usually shows up here first, and it costs no extra request to ask.
    case durationDisagrees

    /// D1 — submitted by one person, who may have mis-tagged their own file.
    case singleSubmission

    public var reason: String {
        switch self {
        case .durationDisagrees:
            return "The source's runtime for this scene disagrees with the file's."
        case .singleSubmission:
            return "One person submitted this fingerprint. Nobody has corroborated it."
        }
    }
}

public enum MatchConfidenceRules {

    /// 🚨 DECIDED by the operator: more than thirty seconds apart is a
    /// disagreement.
    ///
    /// ⚠️ Absolute, not proportional, and that was the decision. A percentage
    /// tolerates minutes on a long scene — which is a different cut, the exact
    /// thing this is meant to catch — while being far too tight on a short one.
    /// Encodings differ by a second or two; nobody's re-encode moves a runtime
    /// by half a minute.
    public static let durationTolerance: TimeInterval = 30

    /// What is doubtful about this match, if anything.
    ///
    /// - Parameters:
    ///   - localDuration: the file's own runtime, from the catalogue. `nil`
    ///     when it has not been measured — see the note below.
    ///
    /// ⚠️ An UNMEASURED file raises no duration doubt. Absence of a measurement
    /// is not evidence of disagreement, and reporting one would fill the queue
    /// with videos whose only fault is that Measure Videos has not run.
    ///
    /// 🔴 C6 — fingerprints only. A match made by title, cast or the operator's
    /// own hand has no fingerprint behind it, so there is nothing here to
    /// doubt and this returns nothing for them.
    public static func doubts(method: MatchMethod,
                              localDuration: Double?,
                              confidence: MatchConfidence) -> [MatchDoubt] {
        guard method == .fingerprint else { return [] }

        var found: [MatchDoubt] = []

        if let local = localDuration, let claimed = confidence.fingerprintDuration,
           abs(local - claimed) > durationTolerance {
            found.append(.durationDisagrees)
        }

        // ⚠️ `== 1`, not `<= 1`. Zero would mean the source reported a count of
        // none, which is a different and stranger claim than one — and `nil`,
        // meaning it said nothing at all, must not be read as either.
        if confidence.submissions == 1 {
            found.append(.singleSubmission)
        }

        return found
    }

    /// Whether this match belongs in the review queue.
    ///
    /// 🔴 D4/C3 — this is the ONLY thing doubt does. It puts a row on a screen
    /// for a person to look at. Nothing anywhere un-matches, re-matches, hides
    /// or re-queues a video on the strength of it.
    public static func needsReview(method: MatchMethod,
                                   localDuration: Double?,
                                   confidence: MatchConfidence) -> Bool {
        !doubts(method: method, localDuration: localDuration, confidence: confidence).isEmpty
    }
}
