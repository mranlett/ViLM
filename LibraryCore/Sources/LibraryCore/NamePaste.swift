// NamePaste.swift
// A cast list, read off a page and pasted in one go.
//
// 🚨 WHY THIS RATHER THAN A SCRAPER. The operator reads a listing somewhere the
// app has no plugin for and types what it says. Entering five performers meant
// five round trips through one text field, so a feature meant to rescue
// hundreds of videos was usable on a handful. Scraping would need a parser per
// site, break without notice, and cost the guarantee that this path makes no
// request at all — this needs none of that and does not care which site the
// list came from.
//
// ⭐ It reuses the vocabulary machinery built for filename parsing rather than
// inventing a second idea of what a name is. That is the whole value: a pasted
// list is canonicalised to the LIBRARY's spelling, so a source that writes a
// name differently cannot split one performer into two records — which is
// exactly the defect #76 was.
//
// 🚨 IT CREATES NOTHING. A name the library does not know is REPORTED. Minting
// a profile from a paste is how a typo becomes a permanent record, and the
// operator is right there to look at the list.

import Foundation

/// What a pasted list turned out to contain.
public struct PastedNames: Equatable, Sendable {
    /// Names the library knows, in the library's own spelling, in the order
    /// they were pasted and without repeats.
    public let known: [String]

    /// 🚨 Names it does not know. Reported so the operator can see them, never
    /// created. Most are a spelling the library writes differently, and the
    /// rest are the ones actually worth adding by hand.
    public let unknown: [String]

    public var isEmpty: Bool { known.isEmpty && unknown.isEmpty }

    public init(known: [String], unknown: [String]) {
        self.known = known
        self.unknown = unknown
    }
}

public enum NamePaste {

    public enum Kind: Equatable, Sendable {
        case actor, studio, tag
    }

    /// Reads a pasted list.
    ///
    /// ⚠️ Separators are the UNAMBIGUOUS ones — comma, semicolon, newline and
    /// `&`. The word "and" is NOT one of them at the top level, because it
    /// occurs inside real names and splitting on it fails silently. It is tried
    /// only on a segment the library does not recognise whole, which is the
    /// longest-match-first rule the filename parser already uses: a known name
    /// containing "and" survives, and an unrecognised run gets one more chance
    /// to be two people.
    public static func read(_ text: String, as kind: Kind,
                            vocabulary: NameVocabulary) -> PastedNames {
        var known: [String] = []
        var unknown: [String] = []
        var seen: Set<String> = []

        func consider(_ raw: String, allowSplittingOnAnd: Bool) {
            let candidate = tidied(raw)
            guard !candidate.isEmpty else { return }

            if let canonical = match(candidate, as: kind, vocabulary: vocabulary) {
                if seen.insert(canonical.lowercased()).inserted { known.append(canonical) }
                return
            }

            // Not recognised whole. NOW try "and" — a second chance at being
            // two people, taken only where being one has already failed.
            if allowSplittingOnAnd, let parts = splitOnAnd(candidate) {
                for part in parts { consider(part, allowSplittingOnAnd: false) }
                return
            }

            if seen.insert(candidate.lowercased()).inserted { unknown.append(candidate) }
        }

        for segment in text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "&"
            || $0.isNewline }) {
            consider(String(segment), allowSplittingOnAnd: true)
        }

        return PastedNames(known: known, unknown: unknown)
    }

    /// The library's own spelling, or nil when it does not know the name.
    private static func match(_ candidate: String, as kind: Kind,
                              vocabulary: NameVocabulary) -> String? {
        let folded = candidate.lowercased()
        let holds: Bool
        switch kind {
        case .actor:  holds = vocabulary.actors.contains(folded)
        case .studio: holds = vocabulary.studios.contains(folded)
        case .tag:    holds = vocabulary.tags.contains(folded)
        }
        guard holds else { return nil }
        // ⭐ Canonicalised, so the source's casing never reaches the library.
        return vocabulary.canonicalised([candidate]).first ?? candidate
    }

    /// Strips what a pasted line carries around a name.
    ///
    /// ⚠️ A trailing parenthetical is dropped because these listings routinely
    /// write "Name (as Something Else)", and the credited-as spelling belongs
    /// to the appearance rather than to the person — it is not part of the name
    /// being looked up.
    static func tidied(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Leading list markers: "-", "*", "•", "1.", "2)".
        while let first = value.first, first == "-" || first == "*" || first == "•" {
            value = String(value.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if let dot = value.firstIndex(where: { $0 == "." || $0 == ")" }),
           value[value.startIndex..<dot].allSatisfy(\.isNumber),
           dot != value.startIndex {
            value = String(value[value.index(after: dot)...])
                .trimmingCharacters(in: .whitespaces)
        }

        // A trailing parenthetical.
        if value.hasSuffix(")"), let open = value.lastIndex(of: "(") {
            value = String(value[value.startIndex..<open])
                .trimmingCharacters(in: .whitespaces)
        }

        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Two names joined by the word "and", or nil.
    private static func splitOnAnd(_ candidate: String) -> [String]? {
        // ⚠️ Space-delimited, so "Alexander" and "Sandy" are untouched.
        let marker = " and "
        guard let range = candidate.range(of: marker, options: .caseInsensitive) else {
            return nil
        }
        let left = String(candidate[candidate.startIndex..<range.lowerBound])
        let right = String(candidate[range.upperBound...])
        guard !left.trimmingCharacters(in: .whitespaces).isEmpty,
              !right.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return [left, right]
    }

    /// The prefixed tag strings these names become, ready to add to an asset.
    ///
    /// ⚠️ Only the KNOWN ones. The unknown list is for the operator to read,
    /// not for the library to absorb.
    public static func tags(for names: PastedNames, as kind: Kind) -> [String] {
        let prefix: String
        switch kind {
        case .actor:  prefix = "actor:"
        case .studio: prefix = "studio:"
        case .tag:    prefix = "tag:"
        }
        return names.known.map { prefix + $0 }
    }
}
