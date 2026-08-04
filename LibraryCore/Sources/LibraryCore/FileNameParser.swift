// FileNameParser.swift
// Reads a filename back into the fields it was built from.
//
// The inverse of `Asset.suggestedFileNameFromTags`, which joins four sections
// with " - " in a fixed priority:
//
//     Actors - Series/Episode - Tags - Studio.ext
//
// Any section may be absent, which is what makes this hard: three segments
// could be actors/series/tags or actors/tags/studio, and position alone cannot
// tell them apart. Guessing by position is how a parser silently files a studio
// as a tag across a thousand records.
//
// So position is only a tie-breaker. The real evidence is the library's own
// VOCABULARY — the actors, studios and tags it already knows. A segment that
// matches known studios is a studio wherever it sits, and a segment matching
// nothing is reported as unrecognised rather than forced into whichever slot
// happens to be free.
//
// Nothing here writes. It produces a reading, with the parts it could not place
// listed, so a person can see what would be recorded before anything is.

import Foundation

public struct ParsedFileName: Equatable, Sendable {
    public var actors: [String] = []
    public var tags: [String] = []
    public var studios: [String] = []
    /// The series/episode block, unparsed — `MediaTitleParser` splits it.
    public var seriesBlock: String?
    /// Segments no vocabulary recognised, in the order they appeared.
    public var unrecognised: [String] = []

    /// Nothing was recognised at all.
    public var isEmpty: Bool {
        actors.isEmpty && tags.isEmpty && studios.isEmpty && seriesBlock == nil
    }

    /// How much of the name was placed, 0...1. A caller can use this to sort a
    /// review list so the doubtful ones are seen first.
    public var confidence: Double {
        let placed = actors.count + tags.count + studios.count + (seriesBlock == nil ? 0 : 1)
        let total = placed + unrecognised.count
        return total == 0 ? 0 : Double(placed) / Double(total)
    }
}

/// What the library already knows, used to recognise segments.
public struct NameVocabulary: Sendable {
    public let actors: Set<String>
    public let studios: Set<String>
    public let tags: Set<String>

    public init(actors: Set<String> = [], studios: Set<String> = [], tags: Set<String> = []) {
        self.actors = Set(actors.map { $0.lowercased() })
        self.studios = Set(studios.map { $0.lowercased() })
        self.tags = Set(tags.map { $0.lowercased() })
    }

    /// Built from what the library holds today. The vocabulary grows as records
    /// are corrected, so a second pass recognises more than the first.
    public init(assets: [Asset]) {
        var actors = Set<String>(), studios = Set<String>(), tags = Set<String>()
        for asset in assets {
            actors.formUnion(asset.actors)
            studios.formUnion(asset.studios)
            tags.formUnion(asset.actions)
        }
        self.init(actors: actors, studios: studios, tags: tags)
    }
}

public enum FileNameParser {

    public static let separator = " - "

    /// Splits a person/tag list the generator joined with ", ".
    ///
    /// " and " is accepted too because hand-typed names use it, and a name
    /// containing " and " is far rarer than a pair joined by it.
    static func splitList(_ value: String) -> [String] {
        value
            .replacingOccurrences(of: " and ", with: ", ",
                                  options: [.caseInsensitive])
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Reads a filename into fields, using the vocabulary to place segments.
    public static func parse(fileName: String, vocabulary: NameVocabulary) -> ParsedFileName {
        let stem = (fileName as NSString).deletingPathExtension
        let segments = stem
            .components(separatedBy: separator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !segments.isEmpty else { return ParsedFileName() }

        var result = ParsedFileName()
        var unplaced: [(index: Int, value: String)] = []

        for (index, segment) in segments.enumerated() {
            let entries = splitList(segment)

            // Every entry recognised as one kind places the whole segment.
            // A segment is a list of ONE kind of thing — mixing them would mean
            // the generator produced it, and it never does.
            if entries.allSatisfy({ vocabulary.actors.contains($0.lowercased()) }) {
                result.actors.append(contentsOf: entries)
            } else if entries.allSatisfy({ vocabulary.studios.contains($0.lowercased()) }) {
                result.studios.append(contentsOf: entries)
            } else if entries.allSatisfy({ vocabulary.tags.contains($0.lowercased()) }) {
                result.tags.append(contentsOf: entries)
            } else {
                unplaced.append((index, segment))
            }
        }

        // Position is only a tie-breaker, applied to what vocabulary could not
        // place. The generator's order is Actors, Series, Tags, Studio, so the
        // FIRST unplaced segment is most likely the actors and the LAST is most
        // likely the studio — but neither is asserted here. Only the series
        // block is claimed, because it is the one section that is free text and
        // therefore cannot be in any vocabulary.
        if unplaced.count == 1, let only = unplaced.first,
           only.index > 0, result.actors.isEmpty == false {
            // Sits after a recognised actor list: the series/episode block.
            result.seriesBlock = only.value
        } else {
            result.unrecognised = unplaced.map(\.value)
        }

        return result
    }

    /// The fields this parse would ADD to an asset, leaving everything the
    /// record already holds untouched.
    ///
    /// Additive by construction: parsing is evidence about a file, not a
    /// correction of the operator's work, and a filename is often staler than
    /// the record. Nothing is removed and nothing already set is overwritten.
    public static func additions(for asset: Asset,
                                 parsed: ParsedFileName) -> (tags: [String], seriesBlock: String?) {
        var additions: [String] = []
        let held = Set(asset.tags.map { $0.lowercased() })

        func add(_ prefixed: String) {
            if !held.contains(prefixed.lowercased()) { additions.append(prefixed) }
        }
        for actor in parsed.actors { add("actor:\(actor)") }
        for studio in parsed.studios { add("studio:\(studio)") }
        for tag in parsed.tags { add("tag:\(tag)") }

        // Only offered when the record has no series at all — a filename must
        // not overwrite one that was entered deliberately.
        let series = (asset.videoName?.isEmpty ?? true) ? parsed.seriesBlock : nil
        return (additions, series)
    }
}
