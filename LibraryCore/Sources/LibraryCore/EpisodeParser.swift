// EpisodeParser.swift
// Parses legacy freeform episode text ("12", "Episode 12", "S2E3", "2x12",
// "2 Episode 12", ...) into structured season/episode numbers with a
// confidence flag for the migration tool's review step.

import Foundation

/// Parses freeform legacy "Episode Info" text into structured season/episode
/// numbers plus a leftover title. Used by the one-time migration tool; it is
/// deliberately conservative and reports low confidence when unsure so the
/// user can confirm or correct rather than having data silently rewritten.
public enum EpisodeParser {

    public struct Result: Equatable, Sendable {
        public var season: Int?
        public var episode: Int?
        public var title: String?
        /// True when the text mapped cleanly to numbers with nothing ambiguous
        /// left over. False cases should be surfaced for manual review.
        public var isConfident: Bool

        public init(season: Int? = nil, episode: Int? = nil, title: String? = nil, isConfident: Bool = false) {
            self.season = season
            self.episode = episode
            self.title = title
            self.isConfident = isConfident
        }
    }

    public static func parse(_ raw: String) -> Result {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return Result(isConfident: true) }

        // 1. "S2E3" / "s02e03"
        if let m = firstMatch(#"^s\s*(\d{1,3})\s*e\s*(\d{1,4})$"#, in: text) {
            return Result(season: Int(m[1]), episode: Int(m[2]), isConfident: true)
        }

        // 2. "2x12"
        if let m = firstMatch(#"^(\d{1,3})\s*x\s*(\d{1,4})$"#, in: text) {
            return Result(season: Int(m[1]), episode: Int(m[2]), isConfident: true)
        }

        // 3. "Season 2 Episode 3" (with optional "Ep"/"Episode" and separators)
        if let m = firstMatch(#"^season\s*(\d{1,3})\s*[,\-–]?\s*(?:ep|episode|e)\s*(\d{1,4})$"#, in: text) {
            return Result(season: Int(m[1]), episode: Int(m[2]), isConfident: true)
        }

        // 4. Overloaded "2 Episode 12" — leading number is the season, the
        //    number after Ep/Episode is the episode.
        if let m = firstMatch(#"^(\d{1,3})\s+(?:ep|episode|e)\s*(\d{1,4})$"#, in: text) {
            return Result(season: Int(m[1]), episode: Int(m[2]), isConfident: true)
        }

        // 5. "Episode 12" / "Ep 12" / "E12" — episode only.
        if let m = firstMatch(#"^(?:ep|episode|e)\s*(\d{1,4})$"#, in: text) {
            return Result(episode: Int(m[1]), isConfident: true)
        }

        // 6. "Season 4" — season only.
        if let m = firstMatch(#"^season\s*(\d{1,3})$"#, in: text) {
            return Result(season: Int(m[1]), isConfident: true)
        }

        // 7. A bare number — episode number by convention.
        if let m = firstMatch(#"^(\d{1,4})$"#, in: text) {
            return Result(episode: Int(m[1]), isConfident: true)
        }

        // 8. Two bare numbers "2 12" — season then episode, but ambiguous.
        if let m = firstMatch(#"^(\d{1,3})\s+(\d{1,4})$"#, in: text) {
            return Result(season: Int(m[1]), episode: Int(m[2]), isConfident: false)
        }

        // Anything else: keep the whole thing as the title, flagged for review.
        return Result(title: text, isConfident: false)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        var groups: [String] = []
        for i in 0..<match.numberOfRanges {
            if let r = Range(match.range(at: i), in: text) {
                groups.append(String(text[r]))
            } else {
                groups.append("")
            }
        }
        return groups
    }
}
