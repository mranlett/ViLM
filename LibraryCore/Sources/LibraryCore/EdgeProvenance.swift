// EdgeProvenance.swift
// Where an edge came from.
//
// D7 of the Library Graph Epic says every value carries its source, and until
// now edges did not — an edge asserted by a confirmed match and one inferred
// from a filename were indistinguishable once written. That is why `Match
// Again` cannot tell a confirmed relationship from a guessed one, and why a
// re-match has to redo work it has already done well.
//
// ⚠️ These describe how THIS edge was created, not how good it is. A download
// is not automatically right and an inference is not automatically wrong; the
// value is that the two can be told apart at all.

import Foundation

public enum EdgeProvenance: String, Equatable, Sendable, CaseIterable {
    /// Asserted by an external source during a match.
    case download
    /// Entered or confirmed by the operator.
    case `operator`
    /// Read out of the file name by the parser.
    case filename
    /// Derived from strings the library already held, whose own origin is not
    /// recorded.
    ///
    /// ⚠️ The honest value for the bulk connect. It walks `asset.tags`, and
    /// those tags came from every route there is — so claiming any of the
    /// three above would be inventing provenance rather than recording it.
    case inferred

    /// Which origin wins where two disagree, per D7: download > operator >
    /// filename. `inferred` ranks last — it is the absence of a known origin.
    ///
    /// ⚠️ Ordering only. Nothing currently resolves edge conflicts by
    /// precedence, and adding that is a decision, not a consequence of this
    /// type existing.
    public var precedence: Int {
        switch self {
        case .download: return 3
        case .operator: return 2
        case .filename: return 1
        case .inferred: return 0
        }
    }

    public var displayName: String {
        switch self {
        case .download: return "From a source"
        case .operator: return "Entered by you"
        case .filename: return "Read from the file name"
        case .inferred: return "Derived from existing tags"
        }
    }
}

/// A performer's appearance in one video.
///
/// ⭐ The credited name is the reason this type exists. A performer frequently
/// appears under a different name in a specific scene, the source supplies it
/// on every match, and it is a property of the APPEARANCE — not of the person,
/// and not of the video — so before edge attributes there was nowhere to put
/// it and it was discarded every time.
public struct PerformerCredit: Equatable, Sendable, Identifiable {
    public let performerId: String
    /// The name used in this video, when it differs from the performer's own.
    ///
    /// `nil` means "credited under their usual name", which is the common case
    /// and is deliberately not stored as a copy of it — a duplicated name is a
    /// second place for it to go stale.
    public let creditedAs: String?
    /// Billing order where the source states it. Never derived from the order
    /// a list happened to arrive in.
    public let billing: Int?
    public let source: EdgeProvenance?

    public var id: String { performerId }

    public init(performerId: String, creditedAs: String? = nil,
                billing: Int? = nil, source: EdgeProvenance? = nil) {
        self.performerId = performerId
        self.creditedAs = creditedAs
        self.billing = billing
        self.source = source
    }

    /// What to show for this credit, given the performer's canonical name.
    public func displayName(canonical: String) -> String {
        guard let creditedAs, !creditedAs.isEmpty,
              creditedAs.caseInsensitiveCompare(canonical) != .orderedSame else {
            return canonical
        }
        return "\(canonical) (as \(creditedAs))"
    }
}
