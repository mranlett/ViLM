// TagNormalizer.swift
// Canonicalizes tag values and full prefixed tags (trimming, capitalization)
// so the same tag typed differently converges to one spelling.
//
// The governing rule is that capitalization the writer TYPED is deliberate and
// is left alone. Only a word with no capital past its first letter is treated
// as unstyled and given one.
//
// The previous behaviour — first letter up, everything else down — quietly
// destroyed every acronym and every name with a capital inside it: POV became
// Pov, SCUBA became Scuba, O'Brien became O'brien, MacLeod became Macleod.
// There is no way to tell an acronym from a shouted ordinary word without a
// dictionary, so the choice is which failure to accept. Preserving what was
// typed is recoverable — the writer can retype it — while flattening it loses
// information nobody can get back.

import Foundation

public struct TagNormalizer {

    /// Capitalizes a single word only where no preference was expressed.
    ///
    /// A capital anywhere past the first character means the writer chose it:
    /// `POV`, `MacLeod`, `O'Brien`, `iPhone`. Those are returned untouched.
    /// Everything else gets its first letter raised and the rest left exactly as
    /// typed — lowercasing the remainder is what caused the damage.
    static func cased(_ word: Substring) -> String {
        guard let first = word.first else { return "" }
        if word.dropFirst().contains(where: { $0.isUppercase }) { return String(word) }
        return first.uppercased() + word.dropFirst()
    }

    /// Normalizes just the value of a tag (e.g. "running fast" -> "Running Fast").
    ///
    /// Words are delimited by whitespace and hyphens; an apostrophe is NOT a
    /// boundary, so "valentine's" becomes "Valentine's" rather than the
    /// incorrect "Valentine'S" that `String.capitalized` produces.
    public static func normalize(tagValue: String) -> String {
        titleCased(tagValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Title-cases a free-text value, preserving deliberate capitalization.
    ///
    /// Runs of whitespace collapse to a single space and leading/trailing
    /// whitespace is dropped. Hyphens are word boundaries and survive, so
    /// "spider-man" becomes "Spider-Man" and "x--men" stays "X--Men".
    public static func titleCased(_ value: String) -> String {
        value
            .split(whereSeparator: { $0.isWhitespace })
            .map { word in
                // Empty segments are preserved (omittingEmptySubsequences:
                // false) so runs of hyphens survive intact.
                word
                    .split(separator: "-", omittingEmptySubsequences: false)
                    .map(cased)
                    .joined(separator: "-")
            }
            .joined(separator: " ")
    }

    /// Normalizes a full tag string preserving its category prefix if present
    /// (e.g. "actor:luna" -> "actor:Luna").
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

    /// Whether two spellings are the same tag.
    ///
    /// Exists because the capitalization rule changed: entries stored under the
    /// old rule read `Pov` and `Scuba`, and a writer typing `POV` today would
    /// otherwise create a second, separate tag beside the first. Comparison is
    /// case-insensitive so the two are recognized as one wherever it matters.
    public static func isSameTag(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}
