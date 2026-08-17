// VerifiedElsewhere.swift
// Recording that a person resolved a video against a source ViLM does not plug
// into (#79).
//
// 🚨 THE APP MODELLED TWO STATES AND THE COMMON CASE IS THE THIRD. Matched by a
// provider, or unmatched — so a video the operator has personally verified
// against a real listing in their own browser was indistinguishable from one
// nobody had looked at. It stayed in the lookup queue, reappeared in every
// audit, and the next batch run asked the question that had already failed.
//
// 🚨 INBOUND ONLY, and that is a decision rather than a description. The
// operator reads a page themselves and types what they found; NOTHING here
// makes a request. `ProviderBoundary` is not involved because there is nothing
// to refuse. Acquiring the ability to fetch would be a new decision with a
// privacy boundary attached — not an enhancement to this.
//
// ⚠️ This file names no source, and must not learn how. Core treats the source
// as free text the operator supplies (D7/D9): the public repository never names
// a metadata source, and an enum here would be exactly that.

import Foundation

/// What the operator found, and where.
public struct ExternalVerification: Equatable, Sendable {
    /// Whatever the operator calls the place they looked. Free text on purpose.
    public let source: String
    /// That source's own reference, when it has one worth keeping.
    public let reference: String?
    /// The page, so the claim can be checked by a person later.
    public let link: URL?

    public init(source: String, reference: String? = nil, link: URL? = nil) {
        self.source = source
        self.reference = reference
        self.link = link
    }
}

public enum VerifiedElsewhere {

    /// Why a verification cannot be recorded as given.
    public enum Refusal: Error, Equatable, Sendable {
        case noSource
        /// 🚨 V7 — a reference the operator cannot open is worth nothing. Stored
        /// as an unusable string it surfaces months later as a dead row nobody
        /// can check, which is worse than refusing now.
        case linkIsNotAURL(String)

        public var reason: String {
            switch self {
            case .noSource:
                return "Say where you found it — the name is what makes this checkable later."
            case let .linkIsNotAURL(text):
                return "\"\(text)\" is not a link. Paste the page's address, or leave it empty."
            }
        }
    }

    /// Reads what the operator typed, refusing rather than storing nonsense.
    ///
    /// ⚠️ An EMPTY link is fine; an unusable one is not. Those are different
    /// answers — "I did not keep the address" against "here is something that
    /// looks like one and is not".
    public static func read(source: String, reference: String?,
                            link: String?) -> Result<ExternalVerification, Refusal> {
        let name = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(.noSource) }

        let ref = reference?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawLink = link?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var parsed: URL?
        if !rawLink.isEmpty {
            guard let url = URL(string: rawLink), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", url.host != nil else {
                return .failure(.linkIsNotAURL(rawLink))
            }
            parsed = url
        }

        return .success(ExternalVerification(source: name,
                                             reference: ref?.isEmpty == true ? nil : ref,
                                             link: parsed))
    }

    /// Records the verification on a video.
    ///
    /// ⭐ V1 — it becomes `.matched`, which is what takes it out of the lookup
    /// queue: `VideoBatchPolicy.skipReason` already reads that state as
    /// "already matched". Nothing new had to be invented for that, and nothing
    /// new should be — a second notion of "resolved" would have to be taught to
    /// every screen that already understands this one.
    ///
    /// ⚠️ V2 falls out of the source NAME. `matchesToRecheck(source:)` filters
    /// on it, so a video verified against something the app cannot query is
    /// never re-checked by the source it can.
    public static func applying(_ verification: ExternalVerification,
                                to asset: Asset, at moment: Date = Date()) -> Asset {
        var updated = asset
        updated.enrichmentState = .matched
        updated.enrichmentSource = verification.source
        updated.enrichmentSourceId = verification.reference
        updated.enrichmentUrl = verification.link?.absoluteString
        updated.enrichmentCheckedAt = moment
        // ⚠️ `lookupRoute` says how the last attempt REACHED this video, and a
        // person reading a page is a route like any other. Left as a plain
        // string for the same reason the source is: core does not enumerate.
        updated.lookupRoute = "verified by hand"
        return updated
    }

    /// 🚨 V6 — undoing it leaves NOTHING behind.
    ///
    /// A half-cleared record — no state but a lingering reference — is exactly
    /// what a later run reads as evidence of a match, and it is the shape the
    /// inspector's own "not findable" toggle was already careful about. Every
    /// field the recording set is cleared, and no other.
    public static func clearing(from asset: Asset) -> Asset {
        var updated = asset
        updated.enrichmentState = nil
        updated.enrichmentSource = nil
        updated.enrichmentSourceId = nil
        updated.enrichmentUrl = nil
        updated.enrichmentCheckedAt = nil
        updated.lookupRoute = nil
        return updated
    }

    /// Whether this video's identity came from a person rather than a provider.
    ///
    /// ⭐ Answered from the RECORD, not from a stored flag. A flag would be a
    /// second source of truth about the same fact, and the two would disagree
    /// the first time anything else wrote the source.
    public static func wasVerifiedByHand(_ asset: Asset,
                                         knownProviders: Set<String>) -> Bool {
        guard let source = asset.enrichmentSource?.trimmingCharacters(
            in: .whitespacesAndNewlines), !source.isEmpty else { return false }
        guard asset.enrichmentState == .matched else { return false }
        // Anything not named by an installed provider was named by a person.
        return !knownProviders.contains(source)
    }

    /// 🔴 D3/V3 — a statement outranks evidence.
    ///
    /// A later automated run must not overwrite what the operator entered. Same
    /// rule as the hand-set studio parent and the hand-set content kind, and it
    /// is expressed the same way: the question is asked BEFORE the write, not
    /// repaired afterwards.
    public static func mayOverwrite(_ asset: Asset, withSource incoming: String,
                                    knownProviders: Set<String>) -> Bool {
        guard wasVerifiedByHand(asset, knownProviders: knownProviders) else { return true }
        // Re-verifying against the same place the operator named is a
        // correction of their own record, not an overwrite of it.
        return asset.enrichmentSource?.caseInsensitiveCompare(incoming) == .orderedSame
    }
}
