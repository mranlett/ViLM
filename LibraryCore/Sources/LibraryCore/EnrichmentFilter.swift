// EnrichmentFilter.swift
// Filtering any record by how an external lookup went.

import Foundation

/// The enrichment outcomes worth filtering on.
///
/// Shared by actors and by videos.
///
/// `neverChecked` is not an `EnrichmentState` — it is the ABSENCE of one,
/// and conflating it with `noMatch` would make every un-enriched actor look
/// like a failure. It gets a filter case but no stored value.
public enum EnrichmentFilter: String, CaseIterable, Equatable, Codable, Sendable {
    case any
    case needsAttention
    case noMatch
    case ambiguous
    case needsReview
    case matched
    case unmatchable
    case neverChecked

    /// 🚨 Identified by a PERSON against a source the app cannot query.
    ///
    /// ⭐ Distinct from `matched`, and the distinction is the operator's whole
    /// question: both say "we know what this is", but one is a fingerprint and
    /// the other is their own judgement from a page. Folding them together
    /// makes their own work unreviewable.
    ///
    /// ⚠️ Answerable for a VIDEO only. A profile carries no lookup route, so
    /// the actor filter omits this case rather than offering one that can never
    /// match — see `ActorFilterBuilderView`.
    case verifiedByHand

    /// 🚨 Anything not settled: looked at and unresolved, OR never looked at.
    ///
    /// ⭐ The filter an operator reaches for when they ask "what still needs
    /// me". Neither existing case answers it — `needsAttention` deliberately
    /// excludes never-checked, and `neverChecked` excludes everything that
    /// failed — so the honest answer was two filters and a mental union.
    ///
    /// ⚠️ Additive rather than a redefinition of `needsAttention`. That
    /// distinction is load-bearing for actors and is asserted; widening it
    /// would have reported every un-enriched actor as a failure.
    case notResolved

    /// 🚨 An unknown value decodes to `.any` rather than throwing.
    ///
    /// A saved smart collection holds this enum by raw value, and the
    /// synthesized decoder throws on a case it does not know — so a collection
    /// written by a newer build, or one naming a case since renamed, would fail
    /// to decode and take the WHOLE filter down with it. The failure would look
    /// like a corrupted collection rather than an unfamiliar word.
    ///
    /// ⚠️ `ActorFilterCriteria` already worked around this at its own call
    /// site, with a comment saying why; `AssetFilterCriteria` had no custom
    /// decoder at all and was unprotected. Fixing it HERE covers both, and
    /// covers every future container without either having to remember.
    ///
    /// ⭐ Falling back to `.any` is the safe direction: the filter shows more
    /// than intended rather than hiding a library behind a filter nobody can
    /// see or clear.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = EnrichmentFilter(rawValue: raw) ?? .any
    }

    public var displayName: String {
        switch self {
        case .any: return "Any"
        case .needsAttention: return "Needs attention (anything unresolved)"
        case .noMatch: return "No match"
        case .ambiguous: return "Ambiguous"
        case .needsReview: return "Needs review"
        case .matched: return "Matched"
        case .unmatchable: return "Not findable (you decided)"
        // ⚠️ Now a SUBSET of "needs attention" rather than a sibling of it.
        // Named so the overlap reads as deliberate.
        case .neverChecked: return "Never looked at"
        case .verifiedByHand: return "Verified by you"
        case .notResolved: return "Not resolved (including never looked at)"
        }
    }

    /// Does a record's state satisfy this filter?
    ///
    /// - Parameter route: how the last attempt reached it. Videos have one;
    ///   profiles do not, which is why `verifiedByHand` is a video-only case.
    public func accepts(_ state: EnrichmentState?, route: String? = nil) -> Bool {
        switch self {
        case .any:            return true
        case .neverChecked:   return state == nil
        // ⚠️ `?? false`, DELIBERATELY. "Never checked" is unknown, not failed —
        // conflating them reports every un-enriched record as a failure, which
        // is the distinction `neverChecked` exists for and which
        // `EnrichmentStateTests` asserts. Changing it here would also change
        // the ACTOR filter, which is the same type by typealias.
        //
        // ⭐ What an operator actually wants — "anything I have not resolved" —
        // is `notResolved` below, which spans both without destroying either.
        case .needsAttention: return state?.needsAttention ?? false
        case .noMatch:        return state == .noMatch
        case .ambiguous:      return state == .ambiguous
        case .needsReview:    return state == .needsReview
        case .matched:        return state == .matched
        case .unmatchable:    return state == .unmatchable
        case .verifiedByHand: return state == .matched
            && route == VerifiedElsewhere.handVerifiedRoute
        // Unknown OR unresolved. `unmatchable` is settled — the operator said
        // so — and `matched` is settled by definition.
        case .notResolved:    return state == nil || (state?.needsAttention ?? false)
        }
    }
}
