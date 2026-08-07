// VideoRefreshPolicy.swift
// Re-reading a video the library has ALREADY matched, to pick up data the app
// could not store when the match was made.
//
// 🚨 Why this exists. `VideoBatchPolicy` skips anything `.matched` — correctly,
// since re-identifying a settled video costs a full disk read and a search to
// reach the same answer. But the library has since learned to store things it
// could not before: the name a performer was credited under in a scene, the
// network above an imprint, a studio's own identifier. A video matched before
// those existed keeps its match and will never gain them.
//
// ⭐ This is cheap because the video's own id was stored. `fetch(videoId:)` is a
// direct lookup — no fingerprint, no disk read, no search, and no ambiguity to
// re-settle, which is the expensive part of matching and the part that needs a
// person. Measured on the drive library: 139 of 139 matched videos carry an id.
//
// ⚠️ It is a REFRESH, not a re-match. It never changes which record a video is
// matched to, and it never overwrites a value the library holds — a library
// refined by hand must not be undone by a source that has since changed its
// mind. Disagreements are queued for a person, exactly as everywhere else.

import Foundation

public enum VideoRefreshPolicy {

    /// Whether a video can be refreshed, and why not when it cannot.
    public enum Eligibility: Equatable, Sendable {
        /// Refreshable, by this identifier.
        case refresh(sourceId: String)
        /// ⚠️ Matched, but before the app recorded WHICH record it matched.
        /// Not refreshable — there is nothing to look up. `Match Again` is the
        /// only route, and it costs a full re-identification.
        case noSourceId
        /// Never matched, so `Match All Videos` is the tool, not this one.
        case notMatched
        /// The operator ruled it out; re-reading it would overrule them.
        case ruledOut
        /// Waiting on a decision a batch run cannot make.
        case ambiguous

        public var isRefreshable: Bool {
            if case .refresh = self { return true }
            return false
        }

        /// Said in the operator's terms, for the report.
        public var reason: String? {
            switch self {
            case .refresh:     return nil
            case .noSourceId:  return "matched before the app recorded which record"
            case .notMatched:  return "never matched"
            case .ruledOut:    return "you ruled this one out"
            case .ambiguous:   return "waiting on your decision"
            }
        }
    }

    public static func eligibility(for asset: Asset) -> Eligibility {
        switch asset.enrichmentState {
        case .matched:
            guard let id = asset.enrichmentSourceId?
                .trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
                return .noSourceId
            }
            return .refresh(sourceId: id)
        case .unmatchable: return .ruledOut
        case .ambiguous:   return .ambiguous
        default:           return .notMatched
        }
    }

    /// The fields a refresh may write without asking.
    ///
    /// ⚠️ Fills only — a slot the library has nothing in. A `.conflict` means
    /// both sides hold a real value and they differ, and that is precisely the
    /// case a hand-refined library must not lose silently.
    public static func autoApplicable(_ changes: [VideoFieldChange]) -> Set<String> {
        Set(changes.filter { $0.kind == .fill }.map(\.field))
    }

    /// Disagreements, for the operator to settle.
    public static func conflicts(_ changes: [VideoFieldChange]) -> [VideoFieldChange] {
        changes.filter { $0.kind == .conflict }
    }

    /// ⚠️ Tags are deliberately NOT refreshed.
    ///
    /// A source tags far more finely than a person does — one real scene record
    /// carried seventy — so an unattended pass adding them would bury a
    /// hand-built vocabulary across the whole library at once, which is the
    /// exact outcome `VideoEnrichmentReview.defaultSelection` exists to prevent
    /// for a single video. Tags remain a per-video decision.
    public static let refreshesTags = false

    /// What one video's refresh concluded.
    public enum Outcome: Equatable, Sendable {
        /// Fields were written.
        case filled(fields: [String])
        /// Nothing was missing.
        case alreadyComplete
        /// ⚠️ Nothing was written; the source disagrees about these.
        case queued(fields: [String])
        /// Both: some gaps filled, and some disagreements left for a person.
        case filledAndQueued(filled: [String], queued: [String])
        case skipped(reason: String)
        /// ⚠️ Not a verdict about the video — a request that did not complete.
        /// Recorded as a failure so a re-run retries it.
        case failed(String)

        public var wroteAnything: Bool {
            switch self {
            case .filled, .filledAndQueued: return true
            default: return false
            }
        }

        public var needsAPerson: Bool {
            switch self {
            case .queued, .filledAndQueued: return true
            default: return false
            }
        }
    }

    /// What a refresh concluded, from what it found and what it wrote.
    public static func outcome(filled: [String], conflicted: [String]) -> Outcome {
        switch (filled.isEmpty, conflicted.isEmpty) {
        case (true, true):   return .alreadyComplete
        case (false, true):  return .filled(fields: filled.sorted())
        case (true, false):  return .queued(fields: conflicted.sorted())
        case (false, false): return .filledAndQueued(filled: filled.sorted(),
                                                     queued: conflicted.sorted())
        }
    }
}
