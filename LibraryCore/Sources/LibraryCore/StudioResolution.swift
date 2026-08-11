// StudioResolution.swift
// Decides WHICH of the two studio names a source offers should land on a video.
//
// A crowdsourced scene names two studios: the imprint that released it and the
// network that owns the imprint. Both are true, so neither is a "correct
// answer" that can be derived — the library has to have a policy, and this is
// it, stated once and tested rather than re-decided per screen.
//
// ⚠️ The tie-break is VERIFICATION, not level. A verified studio is one a
// person has already confirmed exists and is spelled right, so preferring it
// keeps the lexicon converging on names already in use instead of scattering
// new spellings across the library. Where verification cannot break the tie —
// neither confirmed, or both — nothing is guessed and the operator picks.
//
// Deliberately NOT a preference for parents. An imprint is the more specific
// truth, and the network is recoverable from it through `studio_parent`, so
// defaulting to the network would discard the finer fact to keep the coarser
// one.

import Foundation

public enum StudioResolution {

    /// One of the two names a source offered.
    public struct Candidate: Equatable, Sendable {
        public let name: String
        public let sourceId: String?
        public let level: Level
        public let isVerified: Bool

        public init(name: String, sourceId: String?, level: Level, isVerified: Bool) {
            self.name = name
            self.sourceId = sourceId
            self.level = level
            self.isVerified = isVerified
        }
    }

    public enum Level: String, Equatable, Sendable, Codable {
        /// The label that released the scene.
        case imprint
        /// The network that owns the imprint.
        case parent
    }

    public enum Outcome: Equatable, Sendable {
        /// Settled without asking.
        case use(Candidate)
        /// ⚠️ Genuinely undecidable from the data. Both are offered so the
        /// operator chooses; picking one here would silently commit the library
        /// to a studio nobody checked.
        case ask(imprint: Candidate, parent: Candidate)
        /// The source named no studio at all.
        case none
    }

    /// Applies the policy.
    ///
    /// - only an imprint offered → use it, verified or not. There is nothing to
    ///   disambiguate against, and refusing an unverified lone studio would
    ///   leave the video with no studio at all rather than an unconfirmed one.
    /// - both offered, exactly one verified → the verified one.
    /// - both offered, neither or both verified → ask.
    /// - Parameter held: the studio names the video ALREADY carries.
    ///
    /// 🚨 A settled decision is evidence, and outranks verification.
    ///
    /// Without this the choice is made purely from whether each name is a
    /// verified studio somewhere in the library — so the operator was asked the
    /// same imprint-versus-network question about the same video every time it
    /// was re-matched. Worse, it got MORE frequent with use: accepting a studio
    /// is what verifies it, so settling one of these put both names in the
    /// verified set and pushed the next pairing into the `(true, true)` branch,
    /// which asks.
    ///
    /// ⭐ Re-matching is a REFRESH. It exists to pick up new data, not to
    /// re-open a question the operator already answered for this video. To
    /// change that answer, edit the video's studio.
    ///
    /// ⚠️ Only when the held studio is one of the two ON OFFER. If the source
    /// has started naming two genuinely different studios, the old answer is
    /// not an answer to the new question, and it still asks.
    public static func resolve(imprint: Candidate?, parent: Candidate?,
                               held: [String] = []) -> Outcome {
        switch (imprint, parent) {
        case (nil, nil):
            return .none

        case let (some?, nil):
            return .use(some)

        // A parent with no imprint: unusual, but the network is still a real
        // studio and dropping it would lose the only one on offer.
        case let (nil, some?):
            return .use(some)

        case let (i?, p?):
            // A source that names the same studio at both levels has not
            // actually offered a choice.
            guard !isSameStudio(i.name, p.name) else { return .use(i) }

            // 🚨 The settled decision wins, before verification is consulted.
            // The video already carries one of these two, which means this
            // exact question was already answered for this exact video.
            //
            // ⚠️ Imprint is tested first only to be deterministic. A video
            // carrying BOTH is malformed — a scene has one releasing studio —
            // and either answer is harmless there: the review compares the
            // result against what is held, so a studio already present
            // produces no row and changes nothing.
            if let settled = [i, p].first(where: { candidate in
                held.contains { isSameStudio($0, candidate.name) }
            }) {
                return .use(settled)
            }

            switch (i.isVerified, p.isVerified) {
            case (true, false): return .use(i)
            case (false, true): return .use(p)
            // Both confirmed, or neither: verification cannot separate them.
            case (true, true), (false, false): return .ask(imprint: i, parent: p)
            }
        }
    }

    /// Whether two studio names are the same studio written differently.
    ///
    /// ⚠️ Folds spacing as well as case, because the spellings that actually
    /// collide in a library are the ones a source ran together — "Silver River"
    /// and "SilverRiver" are not two studios to choose between.
    public static func isSameStudio(_ a: String, _ b: String) -> Bool {
        identity(a) == identity(b)
    }

    static func identity(_ name: String) -> String {
        name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: ".", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Accepting a respelling without asking

    /// Whether a proposed studio may replace the one already on a video with no
    /// question asked.
    ///
    /// True only when the two are the SAME studio written differently and the
    /// proposal is one a person has already verified — the "Coastline" →
    /// "Coast Line" case, where asking would be busywork because nothing is
    /// actually being changed except the spelling.
    ///
    /// ⚠️ Two DIFFERENT verified studios are never auto-accepted. That is the
    /// original-production versus redistribution case, and which one the
    /// library should carry is a judgement about the release, not the text.
    public static func canAutoAccept(current: String, proposed: Candidate) -> Bool {
        guard proposed.isVerified else { return false }
        guard isSameStudio(current, proposed.name) else { return false }
        return current != proposed.name
    }
}
