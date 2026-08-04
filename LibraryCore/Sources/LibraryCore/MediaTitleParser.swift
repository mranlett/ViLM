// MediaTitleParser.swift
// Splits a single title string into series / season / episode number / episode
// title, where the string actually says so.
//
// The vocabulary is the one the library already uses, and it is the ordinary
// one for episodic media of any kind:
//
//   Series          "Star Wars"          the collection
//   Season / movie  3                    the volume within it
//   Episode number  4                    the index within that
//   Episode title   "A New Hope"         the individual work
//
// Deliberately conservative. A title is split ONLY where a number marker says
// where the boundary is — "Scene 2", "S03:E07", "#12", "Part 4". A bare dash is
// never treated as a separator, because titles contain dashes as punctuation far
// more often than as structure, and a wrong split silently rewrites two fields
// on records that were previously correct. Anything unrecognised comes back as
// a plain title, which is a true statement about a string nobody can parse.

import Foundation

public struct ParsedMediaTitle: Equatable, Sendable {
    public var seriesName: String?
    public var seasonNumber: Int?
    public var episodeNumber: Int?
    /// The individual work's title. Nil when the source gave only structure.
    public var title: String?

    /// Whether anything beyond a plain title was recognised. Callers use this
    /// to decide whether to propose the extra fields at all rather than
    /// offering a row that says "no change".
    public var isStructured: Bool { seriesName != nil || seasonNumber != nil || episodeNumber != nil }

    public init(seriesName: String? = nil, seasonNumber: Int? = nil,
                episodeNumber: Int? = nil, title: String? = nil) {
        self.seriesName = seriesName
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.title = title
    }
}

public enum MediaTitleParser {

    /// Numbers this large are not episode numbers — they are dates, resolutions
    /// or catalogue ids that happen to sit next to a keyword.
    static let maximumIndex = 999

    public static func parse(_ raw: String) -> ParsedMediaTitle {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return ParsedMediaTitle() }

        // S03:E07 / S03E07 / s3 e7 — season and episode together.
        if let m = firstMatch(#"(?i)\bS\s*(\d{1,3})\s*[:xE\-\s]\s*E?\s*(\d{1,3})\b"#, in: text),
           let season = intAt(1, m, text), let episode = intAt(2, m, text) {
            let (before, after) = split(text, around: m.range)
            return ParsedMediaTitle(seriesName: cleaned(before),
                                    seasonNumber: season,
                                    episodeNumber: episode,
                                    title: cleaned(after))
        }

        // "Scene 2", "Episode 4", "Part 3", "Vol 2" — a single index, with the
        // series ahead of it and the title behind.
        if let m = firstMatch(#"(?i)\b(?:scene|episode|ep|part|vol|volume|chapter)\s*[.#]?\s*(\d{1,3})\b"#, in: text),
           let index = intAt(1, m, text) {
            let (before, after) = split(text, around: m.range)
            // A numbered volume can sit in front of the scene marker — a line's
            // twelfth release, second scene. Both numbers are real and mean
            // different things, so the volume is lifted off the series name
            // rather than left glued to it.
            let (series, volume) = splitTrailingVolume(from: cleaned(before))
            return ParsedMediaTitle(seriesName: series,
                                    seasonNumber: volume,
                                    episodeNumber: index,
                                    title: cleaned(after))
        }

        // "Series #12" — a bare number sign. Read as the volume rather than the
        // episode: it is how numbered releases in a line are labelled, and the
        // scene within one is usually numbered separately.
        if let m = firstMatch(#"#\s*(\d{1,3})\b"#, in: text), let number = intAt(1, m, text) {
            let (before, after) = split(text, around: m.range)
            // A leading number sign is a title like "#1 Fan", not structure.
            if let series = cleaned(before) {
                return ParsedMediaTitle(seriesName: series,
                                        seasonNumber: number,
                                        title: cleaned(after))
            }
        }

        return ParsedMediaTitle(title: text)
    }

    /// True when the string carries no human-readable title at all — a bare
    /// catalogue code such as `ABCD-123`. Worth knowing because proposing it as
    /// an episode title replaces a real name with a serial number.
    public static func isBareCatalogueCode(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        return firstMatch(#"^(?i)[A-Z]{2,6}[\-_ ]?\d{2,6}[A-Za-z]?$"#, in: text) != nil
            || firstMatch(#"^\d{4,10}$"#, in: text) != nil
    }

    // MARK: - Helpers

    /// Peels a trailing volume number off a series name: "Road Trip #02" is the
    /// second volume of "Road Trip". Only a number SIGN counts — a series whose
    /// name simply ends in a digit ("Catch 22") must not be renumbered.
    private static func splitTrailingVolume(from series: String?) -> (String?, Int?) {
        guard let series else { return (nil, nil) }
        guard let m = firstMatch(#"#\s*(\d{1,3})\s*$"#, in: series),
              let number = intAt(1, m, series) else { return (series, nil) }
        let (head, _) = split(series, around: m.range)
        guard let name = cleaned(head) else { return (series, nil) }
        return (name, number)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func intAt(_ group: Int, _ match: NSTextCheckingResult, _ text: String) -> Int? {
        guard let range = Range(match.range(at: group), in: text) else { return nil }
        guard let value = Int(text[range]), value >= 0, value <= maximumIndex else { return nil }
        return value
    }

    private static func split(_ text: String, around range: NSRange) -> (String, String) {
        guard let r = Range(range, in: text) else { return (text, "") }
        return (String(text[text.startIndex..<r.lowerBound]), String(text[r.upperBound...]))
    }

    /// Trims the separator punctuation left behind by removing the marker, and
    /// returns nil rather than an empty string so callers can treat "absent"
    /// and "blank" the same way.
    private static func cleaned(_ part: String) -> String? {
        let trimmed = part.trimmingCharacters(in: CharacterSet(charactersIn: " -–—:,.#|/\t"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
