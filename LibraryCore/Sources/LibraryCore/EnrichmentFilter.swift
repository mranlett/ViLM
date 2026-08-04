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

    public var displayName: String {
        switch self {
        case .any: return "Any"
        case .needsAttention: return "Needs attention"
        case .noMatch: return "No match"
        case .ambiguous: return "Ambiguous"
        case .needsReview: return "Needs review"
        case .matched: return "Matched"
        case .unmatchable: return "Not findable (you decided)"
        case .neverChecked: return "Not yet checked"
        }
    }

    /// Does a profile's recorded state satisfy this filter?
    public func accepts(_ state: EnrichmentState?) -> Bool {
        switch self {
        case .any:            return true
        case .neverChecked:   return state == nil
        case .needsAttention: return state?.needsAttention ?? false
        case .noMatch:        return state == .noMatch
        case .ambiguous:      return state == .ambiguous
        case .needsReview:    return state == .needsReview
        case .matched:        return state == .matched
        case .unmatchable:    return state == .unmatchable
        }
    }
}
