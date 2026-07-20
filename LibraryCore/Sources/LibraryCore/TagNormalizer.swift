// TagNormalizer.swift
// Canonicalizes tag values and full prefixed tags (trimming, capitalization)
// so the same tag typed differently converges to one spelling.

import Foundation

public struct TagNormalizer {
    /// Normalizes just the value of a tag (e.g. "running fast" -> "Running Fast")
    public static func normalize(tagValue: String) -> String {
        return tagValue.trimmingCharacters(in: .whitespacesAndNewlines).capitalized
    }
    
    /// Title-cases a free-text value: the first letter of each word
    /// uppercased, every other letter lowercased. Words are delimited by
    /// whitespace or hyphens, so "spider-man" becomes "Spider-Man" (the
    /// hyphen is preserved). Runs of whitespace collapse to a single space and
    /// leading/trailing whitespace is dropped. Used for Series Names and
    /// Episode Titles.
    ///
    /// Unlike `String.capitalized`, an apostrophe is NOT treated as a word
    /// boundary, so "valentine's day" becomes "Valentine's Day" rather than
    /// the incorrect "Valentine'S Day".
    public static func titleCased(_ value: String) -> String {
        value
            .split(whereSeparator: { $0.isWhitespace })
            .map { word in
                // Preserve empty segments (omittingEmptySubsequences: false)
                // so hyphens survive: "x--men" stays "X--Men", "man-" stays
                // "Man-".
                word
                    .split(separator: "-", omittingEmptySubsequences: false)
                    .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
                    .joined(separator: "-")
            }
            .joined(separator: " ")
    }

    /// Normalizes a full tag string preserving its category prefix if present (e.g. "actor:luna" -> "actor:Luna")
    public static func normalize(fullTag: String) -> String {
        let parts = fullTag.split(separator: ":", maxSplits: 1)
        if parts.count == 2 {
            let category = String(parts[0])
            let value = String(parts[1])
            return "\(category):\(normalize(tagValue: value))"
        } else {
            return normalize(tagValue: fullTag)
        }
    }
}
