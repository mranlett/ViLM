// VideoBatchPolicy.swift
// What a batch match may do on its own, and what it must ask about.
//
// The distinction is how the match was found, not how good it looks:
//
//   FINGERPRINT  the file was identified by what it looks like. Not an
//                inference — a perceptual hash either matches a recorded one or
//                it does not. Safe to apply unattended.
//
//   CAST / TITLE a search that returned something plausible. Plausible is not
//                identified: two scenes by the same performers at the same
//                studio are told apart by watching them, and no amount of
//                metadata agreement changes that. Always queued.
//
// Even an auto-applied match only fills EMPTY fields. A conflict is a
// disagreement with something the operator recorded, and a batch run resolving
// those unattended would silently overwrite deliberate work across a whole
// library — the failure mode that is invisible until long after it happened.

import Foundation

/// How a candidate was found.
public enum VideoMatchRoute: String, Equatable, Sendable, Codable {
    case fingerprint
    case cast
    case title

    /// Whether a match found this way may be applied without being seen.
    public var isAutoApplicable: Bool { self == .fingerprint }

    public var displayName: String {
        switch self {
        case .fingerprint: return "Visual fingerprint"
        case .cast: return "Cast search"
        case .title: return "Title search"
        }
    }
}

/// What a batch run decided about one video.
public enum VideoBatchOutcome: Equatable, Sendable {
    /// Applied unattended. Carries what was written, so the run is auditable.
    case applied(route: VideoMatchRoute, fields: [String], tags: [String])
    /// Found something, but a person has to confirm it.
    case queued(route: VideoMatchRoute, candidateCount: Int)
    /// Looked, found nothing.
    case noMatch
    /// Skipped — already matched, or ruled out by hand.
    case skipped(reason: String)
    case failed(String)

    public var recordedState: EnrichmentState? {
        switch self {
        case .applied: return .matched
        // Queued is genuinely unresolved, and `ambiguous` is what the actor
        // side calls that. Recording `matched` here would take it out of the
        // queue it was just put into.
        case .queued: return .ambiguous
        case .noMatch: return .noMatch
        // A failure is not a verdict. Leaving the state alone means the next
        // run tries again rather than treating a network blip as an answer.
        case .skipped, .failed: return nil
        }
    }
}

public struct VideoBatchReport: Equatable, Sendable {
    public var applied = 0
    public var queued = 0
    public var noMatch = 0
    public var skipped = 0
    public var failed = 0
    /// Fields written without anyone looking. The number worth reporting most
    /// prominently, because it is the part nobody reviewed.
    public var fieldsWritten = 0

    public var examined: Int { applied + queued + noMatch + skipped + failed }

    public init() {}

    public mutating func record(_ outcome: VideoBatchOutcome) {
        switch outcome {
        case .applied(_, let fields, let tags):
            applied += 1
            fieldsWritten += fields.count + tags.count
        case .queued: queued += 1
        case .noMatch: noMatch += 1
        case .skipped: skipped += 1
        case .failed: failed += 1
        }
    }
}

public enum VideoBatchPolicy {

    /// Whether a video should be examined at all.
    ///
    /// Already-matched and ruled-out videos are skipped so a re-run costs only
    /// what it has to. A previous `noMatch` IS retried: the source gains
    /// records constantly, and a verdict from last month is not evidence about
    /// today.
    public static func skipReason(for asset: Asset) -> String? {
        switch asset.enrichmentState {
        case .matched: return "already matched"
        case .unmatchable: return "you ruled this one out"
        default: return nil
        }
    }

    /// The fields a batch run may write unattended: fills from a fingerprint
    /// match, and nothing else.
    ///
    /// Tags are excluded entirely. A source tags far more finely than a person
    /// does — one real record carried seventy — and applying those across a
    /// library without review would bury a hand-built vocabulary under someone
    /// else's taxonomy, one video at a time.
    public static func autoApplicableFields(route: VideoMatchRoute,
                                            changes: [VideoFieldChange]) -> Set<String> {
        guard route.isAutoApplicable else { return [] }
        return Set(changes.filter { $0.kind == .fill }.map(\.field))
    }
}
