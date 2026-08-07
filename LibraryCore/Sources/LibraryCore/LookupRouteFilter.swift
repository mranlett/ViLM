// LookupRouteFilter.swift
// Filtering videos by HOW their last lookup reached them.
//
// 🚨 `enrichmentState` says a video needs attention and never says why. The
// reason lived only in the batch run's in-memory queue, so the moment that
// screen closed it was gone — an operator could see "ambiguous" on two hundred
// videos with no way to separate the one-candidate fingerprint hits from the
// twelve-candidate title guesses, which are entirely different amounts of work.
//
// ⭐ Deliberately a SEPARATE dimension from `EnrichmentFilter`, because the two
// compose. "Ambiguous" AND "found by fingerprint" is the quick pile; folding
// them into one enum would need a case per combination.

import Foundation

public enum LookupRouteFilter: String, CaseIterable, Equatable, Codable, Sendable {
    case any
    case fingerprint
    case cast
    case title
    /// ⚠️ No route recorded — either never looked up, or looked up before the
    /// app started keeping this. Both mean "unknown", and claiming otherwise
    /// would put a video in a pile it was never sorted into.
    case unrecorded

    public var displayName: String {
        switch self {
        case .any:         return "Any"
        case .fingerprint: return "Visual fingerprint"
        case .cast:        return "Cast search"
        case .title:       return "Title search"
        case .unrecorded:  return "Not recorded"
        }
    }

    public func accepts(_ route: String?) -> Bool {
        let recorded = route.flatMap { $0.isEmpty ? nil : $0 }
        switch self {
        case .any:        return true
        case .unrecorded: return recorded == nil
        default:          return recorded == rawValue
        }
    }
}
