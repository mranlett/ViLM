// ActorBatchPolicy.swift
// What an unattended actor run is allowed to do.
//
// Deliberately the same shape as `VideoBatchPolicy`, decision for decision.
// The two ran on different rules before this — the actor side lived outside the
// app as a spreadsheet tool with its own overwrite policy — and a library where
// "match everything" means one thing for videos and another for people is a
// library nobody can reason about.
//
// The rules, all three of which exist to keep an unattended run from doing
// something a person would have refused:
//
//   1. Exactly one candidate, or nothing is written. Two people share a name
//      often enough that picking one is how the wrong bio ends up on someone.
//   2. FILLS only. A conflict means the library already holds a value, and
//      replacing it unattended discards work nobody agreed to discard.
//   3. Ambiguity is recorded and handed back, never resolved.

import Foundation

public enum ActorBatchOutcome: Equatable, Sendable {
    /// Applied unattended. Carries what was written, so the run is auditable.
    case applied(fields: [String])
    /// Found something, but a person has to choose.
    case queued(candidateCount: Int)
    /// Looked, found nothing.
    case noMatch
    /// Skipped — already matched, ruled out, or already waiting on a decision.
    case skipped(reason: String)
    case failed(String)

    public var recordedState: EnrichmentState? {
        switch self {
        case .applied: return .matched
        case .queued: return .ambiguous
        case .noMatch: return .noMatch
        // ⚠️ A failure is not a verdict. Leaving the state alone means the next
        // run tries again rather than treating a network blip as an answer.
        case .failed, .skipped: return nil
        }
    }
}

public enum ActorBatchPolicy {

    /// Why this profile is not worth examining.
    ///
    /// ⚠️ Identical to the video rule, including `ambiguous`. Ambiguity means a
    /// PERSON has to choose, and a re-run cannot choose — examining it again
    /// spends a rate-limited request to reach the same dead end. Left out, a
    /// library accumulating ambiguities gets slower every run while doing no
    /// more work.
    /// - Parameter identityNeedsEnrichment: this actor was IDENTIFIED without
    ///   ever being fetched — their id was handed down by a matched video's
    ///   cast links rather than looked up.
    ///
    ///   🚨 Such an actor is marked `matched` and has nothing else: no bio, no
    ///   links, no photos, no career span. Skipping them as "already matched"
    ///   is how 394 identified actors in a real library ended up permanently
    ///   un-enriched — the identity arrived, the state said done, and the tool
    ///   that would have filled the rest refused to look.
    ///
    ///   ⭐ Examining them is cheap and decision-free: the id is already known,
    ///   so it is one direct fetch with no search and no disambiguation.
    public static func skipReason(for profile: EntityProfile,
                                  identityNeedsEnrichment: Bool = false) -> String? {
        // ⚠️ Checked BEFORE the state switch. The state genuinely is `matched`
        // — that is not wrong, it is incomplete — so the exception has to
        // precede it rather than being folded into it.
        if identityNeedsEnrichment, profile.enrichmentState == .matched { return nil }
        switch profile.enrichmentState {
        case .matched: return "already matched"
        case .unmatchable: return "you ruled this one out"
        case .ambiguous: return "waiting on your decision"
        default: return nil
        }
    }

    /// The fields an unattended run may write: fills, and nothing else.
    ///
    /// ⚠️ Photos are excluded even when the slot is empty. A photo is the one
    /// field where being wrong is immediately, visibly wrong on every screen
    /// the person appears on, and an unattended run has nobody to notice.
    public static let neverUnattended: Set<String> = [ActorEnrichment.Field.photoUrl]

    public static func autoApplicableFields(_ changes: [ProposedChange]) -> Set<String> {
        Set(changes.filter { $0.kind == .fill }.map(\.id))
            .subtracting(neverUnattended)
    }

    /// Whether a search result may be applied without asking.
    ///
    /// One candidate only. Two people sharing a name is common enough that a
    /// run picking the first is how a bio lands on the wrong person — and
    /// because the match is then recorded, nothing brings it back for review.
    public static func isDecisive(candidateCount: Int) -> Bool {
        candidateCount == 1
    }

    /// The same NAME, allowing for how it is written.
    ///
    /// ⭐ Folds case, accents, spaces, hyphens, periods — so `Aj Thornbury`,
    /// `AJ Thornbury` and `A.J. Thornbury` are one person. Deliberately the
    /// same fold `StudioResolution.identity` already uses, because this is the
    /// same problem: the operator's spelling and the source's differ in ways
    /// that carry no meaning.
    public static func isSameName(_ a: String, _ b: String) -> Bool {
        func fold(_ value: String) -> String {
            value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: ".", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let (x, y) = (fold(a), fold(b))
        return !x.isEmpty && x == y
    }

    /// 🚨 The candidate to take when a search returns SEVERAL but exactly one
    /// carries this actor's name.
    ///
    /// Measured need: re-running the batch over 150 actors that were enriched
    /// before ids were recorded sent essentially every one to `ambiguous`,
    /// because a name search returns neighbours as well as the person. Nothing
    /// was repaired — the worklist simply moved. 2026-08-08.
    ///
    /// ⭐ A unique exact-name match among the results is not a guess. The others
    /// are near-misses the search threw in; this one IS the name asked for.
    ///
    /// ⚠️ Returns nil when TWO candidates carry the name, which is the genuine
    /// same-name collision this policy exists to protect against — exactly the
    /// case where picking one lands a bio on the wrong person.
    public static func decisiveCandidate(
        forName name: String, candidates: [PluginCandidate]) -> PluginCandidate? {
        if candidates.count == 1 { return candidates.first }
        let exact = candidates.filter { isSameName($0.title, name) }
        return exact.count == 1 ? exact.first : nil
    }
}

/// What a whole run did.
public struct ActorBatchReport: Sendable, Equatable {
    public private(set) var applied = 0
    public private(set) var queued = 0
    public private(set) var noMatch = 0
    public private(set) var skipped = 0
    public private(set) var failed = 0
    public private(set) var fieldsWritten = 0

    public init() {}

    public mutating func record(_ outcome: ActorBatchOutcome) {
        switch outcome {
        case let .applied(fields):
            applied += 1
            fieldsWritten += fields.count
        case .queued: queued += 1
        case .noMatch: noMatch += 1
        case .skipped: skipped += 1
        case .failed: failed += 1
        }
    }

    public var examined: Int { applied + queued + noMatch + failed }
}
