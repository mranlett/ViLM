// SidecarImport.swift
// S1 — authority is directional (#74).
//
//   Reconciling an EXISTING record: the database wins, and the difference is
//   reported. On FIRST import of a file with a sidecar and no catalogue
//   record: the sidecar is the only data, and is accepted.
//
// 🚨 Those are two rules, and the second is the one with teeth. Accepting means
// taking values from a file this app did not write. The first rule is a refusal
// dressed as a comparison and is nearly free; the second is the whole risk.

import Foundation

public enum SidecarImport {

    /// One field where the document and the record disagree.
    ///
    /// ⚠️ Both sides are carried. "They differ" is not usable — the operator
    /// has to see which is which to decide whether the record is the stale one.
    public struct Difference: Equatable, Sendable {
        public let field: String
        public let database: String
        public let sidecar: String
    }

    public enum Decision: Equatable, Sendable {
        /// No catalogue record. The sidecar is the only data there is.
        case accepted(Asset)
        /// A record exists, so it wins. Nothing is written; this is what the
        /// document said that the catalogue does not.
        case reported([Difference])
    }

    /// 🚨 UNREACHABLE BY DESIGN — NOTHING CALLS THIS, AND THAT IS THE DECISION
    /// (#78, closed 2026-08-21).
    ///
    /// `LibraryScanner` deliberately bypasses it: for a file with no record it
    /// calls `applying` directly, and for a KNOWN file it does not read the
    /// sidecar at all. So `.reported` is never produced, and `differences` is
    /// reached only from tests.
    ///
    /// ⚠️ That is the safe subset, and it is also silent. Reconciling an
    /// existing record means answering two questions nobody has answered:
    /// **where would a difference be reported** — a scan ending "312
    /// differences" is not actionable — and **is a difference ever ACTED on**,
    /// which reopens the authority question #74 settled in the database's
    /// favour. Neither is worth guessing at while nothing but this app writes
    /// sidecars.
    ///
    /// ⭐ Kept rather than deleted because it carries the reasoning below about
    /// which fields a document may be trusted for, which is the expensive part
    /// and would have to be re-derived. It becomes live the moment a SECOND
    /// thing writes sidecars — then wire it, and answer the two questions
    /// first.
    ///
    /// 🔴 Do not read the tests on this as evidence the behaviour is in force.
    /// A rule that is complete, tested and called by nothing is not a rule the
    /// app obeys — see the mistakes log, pattern 16.
    ///
    /// 🚨 THE FIELDS A SIDECAR IS TRUSTED FOR, and the one it is not.
    ///
    /// Title, series, plot, date, studio, cast, tags and rating are all
    /// *description*: cheap to accept, visible when wrong, and undone by
    /// editing a field.
    ///
    /// `uniqueid` is *identity*, and it is excluded deliberately. Accepting it
    /// would attach this video to an external source record on the say-so of a
    /// file that may have been copied from an unrelated video — and every later
    /// refresh would then compound the error against the wrong upstream
    /// record, which no amount of editing here undoes. It is parsed and can be
    /// reported; applying it is a separate decision that has not been taken.
    ///
    /// ⚠️ And `contentKind` is NEVER set from a sidecar. Declaration is a human
    /// act (N4) — a guessed `personal` is a privacy failure, and a guessed
    /// anything-else silently opts a video into being filed and having its
    /// metadata sent to providers. An imported video stays undeclared.
    public static func decide(_ contents: SidecarContents, existing: Asset?,
                              importingInto blank: Asset) -> Decision {
        guard let existing else { return .accepted(applying(contents, to: blank)) }
        return .reported(differences(contents, against: existing))
    }

    /// Fills a fresh record from a document.
    ///
    /// ⭐ Additive only — a field the document does not carry is left alone
    /// rather than blanked. The record is new so in practice everything is
    /// empty, but the caller decides what "new" means and this must not punch
    /// holes in a record that turns out to have had something.
    public static func applying(_ contents: SidecarContents, to asset: Asset) -> Asset {
        var result = asset

        // ⚠️ The document's `title` is the episode title, matching what the
        // writer put there. `set/name` is the series. A document carrying only
        // a title gives a video a name, not a series of one.
        if result.episode?.isEmpty ?? true { result.episode = contents.title }
        if result.videoName?.isEmpty ?? true { result.videoName = contents.series }
        if result.sourceDescription?.isEmpty ?? true { result.sourceDescription = contents.plot }
        if result.releaseDate?.isEmpty ?? true { result.releaseDate = contents.premiered }
        if result.rating == nil { result.rating = vilmRating(from: contents.userRating) }

        // Names become the library's own tag strings, which is how every other
        // route records them.
        var tags = result.tags
        func add(_ tag: String) { if !tags.contains(tag) { tags.append(tag) } }
        for actor in contents.actors { add("actor:\(actor)") }
        if let studio = contents.studio { add("studio:\(studio)") }
        for tag in contents.tags { add("tag:\(tag)") }
        result.tags = tags

        return result
    }

    /// What the document claims that the record does not say.
    ///
    /// ⭐ Only a real disagreement is a difference. A field the document omits
    /// is silence, not a claim that the record is wrong — reporting every
    /// absent field would bury the handful that actually conflict.
    public static func differences(_ contents: SidecarContents,
                                   against asset: Asset) -> [Difference] {
        var found: [Difference] = []

        func compare(_ field: String, _ database: String?, _ sidecar: String?) {
            guard let sidecar, !sidecar.isEmpty else { return }
            let db = database ?? ""
            guard db != sidecar else { return }
            found.append(Difference(field: field, database: db, sidecar: sidecar))
        }

        compare("Title", asset.episode, contents.title)
        compare("Series", asset.videoName, contents.series)
        compare("Description", asset.sourceDescription, contents.plot)
        compare("Release date", asset.releaseDate, contents.premiered)
        compare("Studio", asset.studios.first, contents.studio)
        if let rating = vilmRating(from: contents.userRating), rating != asset.rating {
            found.append(Difference(field: "Rating",
                                    database: asset.rating.map(String.init) ?? "",
                                    sidecar: String(rating)))
        }

        // 🚨 Reported, never applied. See `decide`.
        if let unique = contents.uniqueId, unique.value != asset.enrichmentSourceId {
            found.append(Difference(field: "Source record",
                                    database: asset.enrichmentSourceId ?? "",
                                    sidecar: "\(unique.type): \(unique.value)"))
        }

        // Cast the document names and the record does not hold.
        let known = Set(asset.actors)
        let extra = contents.actors.filter { !known.contains($0) }
        if !extra.isEmpty {
            found.append(Difference(field: "Cast", database: asset.actors.joined(separator: ", "),
                                    sidecar: extra.joined(separator: ", ")))
        }

        return found
    }

    /// Kodi's 0–10 onto ViLM's 1–5.
    ///
    /// ⚠️ Halving is lossy, so the rounding is stated rather than left to
    /// integer division: 9 and 10 are both 5, and the writer's `rating * 2`
    /// round-trips exactly. 0 is Kodi's "unrated", not a rating of zero, and
    /// becomes nil rather than 1 — ViLM has no zero.
    static func vilmRating(from userRating: Int?) -> Int? {
        guard let userRating, userRating > 0 else { return nil }
        return min(5, (userRating + 1) / 2)
    }
}
