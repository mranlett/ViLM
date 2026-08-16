// MetadataSidecar.swift
// The `.nfo` written beside a video, so a file that leaves ViLM still means
// something (Metadata Sidecars, D1–D8).
//
// 🚨 PORTABILITY, NOT RECOVERY. `LibraryBackupService` already snapshots the
// catalogue and owns recovery. This exists so a video copied onto another
// machine, or handed to a media centre, arrives with its title, cast and studio
// attached. That distinction decides everything below: a recovery format would
// have to be lossless, a portability format only has to carry what the
// receiving system can use — which is why dropping most of what ViLM knows
// about a performer is acceptable rather than lossy.
//
// ⭐ A scene is a `<movie>` and the filename does not have to scrape (D7).
// Kodi's local-information-only mode reads this document directly and ignores
// the name of the file entirely, which is what makes the ViLM scene grammar
// free: the filename carries the operator's data, the sidecar carries Kodi's.
//
// ⚠️ Standard elements only (D2). Kodi tolerates unknown elements rather than
// reading them, so a custom field would travel and never be used — the
// appearance of portability without the substance. If something has to survive
// that Kodi cannot express, that is an argument for a different format, not for
// smuggling it into this one.

import Foundation

/// One credited performer, as the sidecar needs them.
///
/// ⚠️ Name and thumb only. Kodi's `actor` element supports name, role, order and
/// thumb and nothing else — biography, gender, birth date, aliases, career span
/// and the rest have no standard home (D6). ViLM stays the source of truth for
/// people; Kodi is a player.
public struct SidecarPerformer: Equatable, Sendable {
    public let name: String
    public let thumbURL: String?

    public init(name: String, thumbURL: String?) {
        self.name = name
        self.thumbURL = thumbURL
    }
}

public enum MetadataSidecar {

    /// The document for one video, or nil when none may be written.
    ///
    /// 🚨 D4 — personal content writes NO sidecar, and neither does undeclared.
    /// A plaintext file beside a home video puts names, places and dates on
    /// removable media in clear text, and `nil` is refused for the same reason
    /// it reaches no provider: undeclared is not the same as safe.
    ///
    /// ⭐ The decision is `ProviderBoundary`, deliberately reused rather than
    /// restated. The question is identical — may this content's metadata leave
    /// the device — and two expressions of one rule is how the two drift apart
    /// with only one of them audited.
    public static func document(for asset: Asset,
                                cast: [SidecarPerformer],
                                studio: String?,
                                fallbackTitle: String) -> String? {
        guard ProviderBoundary.allows(asset.contentKind) else { return nil }

        var body: [String] = []

        // Title: episode, else series, else the filename stem — matching what
        // the generated filename is built from.
        let title = firstNonEmpty(asset.episode, asset.videoName, fallbackTitle)
        body += element("title", title)

        // A real grouping becomes a Kodi set. ⚠️ Only when there IS an episode
        // title as well: a series value standing alone is the video's own name,
        // and calling that a set would invent a collection of one.
        if let series = asset.videoName?.trimmed, !series.isEmpty,
           let episode = asset.episode?.trimmed, !episode.isEmpty {
            _ = episode
            body.append("  <set>")
            body += element("name", series, indent: "    ")
            body.append("  </set>")
        }

        // An episode number orders a set. A movie layout has nowhere else to
        // put it, so it rides in sorttitle as `Series NNN`.
        if let number = asset.episodeNumber {
            let base = asset.videoName?.trimmed ?? title ?? ""
            body += element("sorttitle", "\(base) \(String(format: "%03d", number))".trimmed)
        }

        // The full date is preserved in `premiered`; `year` is the coarse form
        // Kodi sorts by, not a replacement for it.
        if let released = asset.releaseDate?.trimmed, !released.isEmpty {
            body += element("premiered", released)
            if released.count >= 4 { body += element("year", String(released.prefix(4))) }
        }

        // ⚠️ Source description only. Operator Notes are deliberately NOT
        // exported (D3 of the parent) — private notes stay private.
        body += element("plot", asset.sourceDescription)

        // Kodi's scale is 0–10 and ViLM's is 1–5.
        if let rating = asset.rating { body += element("userrating", String(rating * 2)) }

        body += element("studio", studio)

        // ⚠️ `tag`, never `genre`. Genre is a browse axis with a small
        // controlled vocabulary; these are free labels, and filing them as
        // genre would corrupt the receiving library's own axis.
        for tag in asset.actions { body += element("tag", tag) }

        // ⭐ EVERY performer, not the filename's three. The scene grammar caps
        // a path because a path has a length limit; an XML document does not,
        // and letting a naming constraint leak in here would silently drop cast
        // from the only artefact that was supposed to carry it.
        for (index, performer) in cast.enumerated() {
            body.append("  <actor>")
            body += element("name", performer.name, indent: "    ")
            body += element("order", String(index), indent: "    ")
            body += element("thumb", performer.thumbURL, indent: "    ")
            body.append("  </actor>")
        }

        if asset.playCount > 0 { body += element("playcount", String(asset.playCount)) }
        if let played = asset.lastPlayedAt { body += element("lastplayed", isoDay(played)) }

        // Provenance, in Kodi's own shape.
        if let sourceId = asset.enrichmentSourceId?.trimmed, !sourceId.isEmpty {
            let type = asset.enrichmentSource?.trimmed ?? "source"
            body.append("  <uniqueid type=\"\(escape(type))\">\(escape(sourceId))</uniqueid>")
        }

        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <movie>
        \(body.joined(separator: "\n"))
        </movie>
        """
    }

    /// The show-level document for a series folder (D8).
    ///
    /// ⚠️ An episode sidecar carries no studio and no tags — Kodi keeps those on
    /// the show, not the episode — so without this the Episodic grammar drops
    /// the two fields the library is best at: studio on 88% of videos, and tags
    /// widely used. Decided: written once per series.
    public static func showDocument(series: String, studios: [String],
                                    tags: [String]) -> String {
        var body = element("title", series)
        for studio in studios { body += element("studio", studio) }
        for tag in tags { body += element("tag", tag) }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <tvshow>
        \(body.joined(separator: "\n"))
        </tvshow>
        """
    }

    /// The sidecar's path for a video, beside it and named for it (D3, S6).
    ///
    /// 🚨 Named for the file it accompanies, so it travels with a copy. A
    /// sidecar left behind under an old name is worse than none: stale metadata
    /// that still looks authoritative.
    public static func path(forVideo relativePath: String) -> String {
        (relativePath as NSString).deletingPathExtension + ".nfo"
    }

    // MARK: - Emitting

    /// 🚨 S5 — a blank field is OMITTED, never emitted empty. `<plot/>` reads to
    /// a consumer as "this has no description", which is a claim; saying
    /// nothing says nothing, which is true.
    private static func element(_ name: String, _ value: String?,
                                indent: String = "  ") -> [String] {
        guard let value = value?.trimmed, !value.isEmpty else { return [] }
        return ["\(indent)<\(name)>\(escape(value))</\(name)>"]
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            if let v = value?.trimmed, !v.isEmpty { return v }
        }
        return nil
    }

    /// ⚠️ Escaped in one place. A title containing `&` or `<` is ordinary — the
    /// library holds plenty — and an unescaped one produces a document no
    /// consumer can read at all, which fails silently on the receiving side
    /// where nobody is watching.
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func isoDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

/// ⚠️ Local rather than shared. `ContentNaming` keeps its own `fileprivate`
/// copy of this, and widening that one to internal would make a one-line
/// convenience part of the module's surface for no reason beyond saving these
/// three lines.
private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
