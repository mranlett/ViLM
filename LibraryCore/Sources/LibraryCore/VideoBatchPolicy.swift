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

    /// Which route the lookup actually took (v32).
    ///
    /// ⭐ Read from the outcome rather than tracked alongside it, so the route
    /// recorded on the video and the route reported in the run cannot disagree.
    ///
    /// ⚠️ nil for `noMatch`: several routes were tried and all of them failed,
    /// so naming one would be arbitrary. A skip or a failure never looked at
    /// all, and must not overwrite what an earlier run established.
    public var attemptedRoute: VideoMatchRoute? {
        switch self {
        case let .applied(route, _, _): return route
        case let .queued(route, _):     return route
        case .noMatch, .skipped, .failed: return nil
        }
    }

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
    /// ⭐ Performers this run identified WITHOUT a separate lookup, because the
    /// source's scene record links to their confirmed records. Counted apart
    /// from `fieldsWritten` because nothing on the video changed — an actor
    /// somewhere else gained an identity.
    public var identitiesLearned = 0

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
        // 🚨 The privacy boundary first, before any other reason (#59). Not
        // because the order changes what runs — both skip — but because it
        // changes what the operator is TOLD. "already matched" would hide the
        // fact that a video is undeclared, which is the thing they need to act
        // on, and would make the count of undeclared videos unreadable.
        //
        // ⚠️ This is the REPORTING half. It is not the boundary: a loop that
        // declines to select something is a property of that loop. The refusal
        // itself is `PluginRegistry.videoProviders(for:)`, which hands back no
        // provider at all — see `ProviderBoundary`.
        if let refusal = ProviderBoundary.refusal(for: asset.contentKind) {
            switch refusal {
            case .personalContent: return "your own video — never sent"
            case .undeclared: return "not declared yet"
            }
        }
        switch asset.enrichmentState {
        case .matched: return "already matched"
        case .unmatchable: return "you ruled this one out"
        // ⚠️ Ambiguous means a PERSON has to choose — between two scenes with
        // one fingerprint, or between an imprint and its network. A batch run
        // cannot make either choice, so examining it again reaches the same
        // dead end having spent a fingerprint and a request to get there.
        //
        // Left out of this list, a library accumulating ambiguities gets slower
        // every run while doing no more work, and looks like it has forgotten
        // where it got to. `Match Again` clears these when the answer that was
        // missing — usually a confirmed studio — finally exists.
        case .ambiguous: return "waiting on your decision"
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
    /// ⭐ CONFLICTS ARE OVERWRITTEN TOO, on a fingerprint match only.
    ///
    /// Operator's rule, and it is the OPPOSITE of the actor policy: *"if the
    /// online data is different, simply accept it and overwrite what I have
    /// locally."* The asymmetry is deliberate and it is about provenance —
    ///
    ///   • An actor profile is CURATED. The photo, the spelling, the links are
    ///     choices someone made, and a source must not overrule them.
    ///   • A video's local metadata was READ OFF ITS FILENAME. Title, season,
    ///     release date, studio and cast are guesses by a parser, and the
    ///     source's record of the same scene is simply better.
    ///
    /// 🚨 Only on a fingerprint route, which `isAutoApplicable` already
    /// enforces. A fingerprint identifies the file exactly; a title or cast
    /// search returns what is plausible. Overwriting good local data on the
    /// strength of a guess is the one version of this that would be indefensible.
    ///
    /// ⚠️ Nothing the operator authored is reachable from here. The proposal
    /// carries series, season, episode, release date, studio, link and cast —
    /// and no notes, rating, play count or reviewed flag, which is why
    /// overwriting is safe rather than merely permitted. `notes` in particular
    /// is local-only by the operator's standing instruction.
    ///
    /// ⚠️ Tags remain excluded entirely — they are not in the change list at
    /// all. A source tags far more finely than a person does, and applying that
    /// across a library would bury a hand-built vocabulary one video at a time.
    public static func autoApplicableFields(route: VideoMatchRoute,
                                            changes: [VideoFieldChange]) -> Set<String> {
        guard route.isAutoApplicable else { return [] }
        return Set(changes.map(\.field))
    }
}
