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

    /// Names confirmed against an external source.
    ///
    /// Everything above is merely *present* in the library — including whatever
    /// a previous parse guessed, which makes an unvalidated name evidence of
    /// nothing more than that someone typed it once. A validated name has been
    /// checked, so it DECIDES a token's reading where an unvalidated one only
    /// informs it.
    ///
    /// Empty is the normal state for a new library, and the parser falls back
    /// to exactly the behaviour it had before — which is what keeps it working
    /// on a library that has confirmed nothing yet.
    public let validatedActors: Set<String>
    public let validatedStudios: Set<String>

    public init(actors: Set<String> = [], studios: Set<String> = [], tags: Set<String> = [],
                validatedActors: Set<String> = [], validatedStudios: Set<String> = []) {
        self.actors = Set(actors.map { $0.lowercased() })
        self.studios = Set(studios.map { $0.lowercased() })
        self.tags = Set(tags.map { $0.lowercased() })
        self.validatedActors = Set(validatedActors.map { $0.lowercased() })
        self.validatedStudios = Set(validatedStudios.map { $0.lowercased() })
    }

    /// Built from the library AND from what has been confirmed about it.
    ///
    /// A profile counts as validated when a lookup matched it. `matched` rather
    /// than "has a source id" deliberately: the id column is recent and
    /// populates only as records are re-matched, so requiring it would leave
    /// the validated set empty and the lexicon useless for a year. The id is
    /// the stronger signal and supersedes this as it fills in.
    public init(assets: [Asset], profiles: [String: EntityProfile]) {
        var actors = Set<String>(), studios = Set<String>(), tags = Set<String>()
        for asset in assets {
            actors.formUnion(asset.actors)
            studios.formUnion(asset.studios)
            tags.formUnion(asset.actions)
        }

        var validatedActors = Set<String>(), validatedStudios = Set<String>()
        for (id, profile) in profiles where profile.enrichmentState == .matched {
            // A malformed id like "actor:" would otherwise contribute an empty
            // string, which matches an empty entry and validates nothing.
            if id.hasPrefix("actor:") {
                let name = String(id.dropFirst(6))
                if !name.isEmpty { validatedActors.insert(name) }
            }
            if id.hasPrefix("studio:") {
                let name = String(id.dropFirst(7))
                if !name.isEmpty { validatedStudios.insert(name) }
            }
        }

        self.init(actors: actors, studios: studios, tags: tags,
                  validatedActors: validatedActors, validatedStudios: validatedStudios)
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
            //
            // ⭐ VALIDATED readings are tried first, because a confirmed name
            // outranks one that is merely present. Without this, a token that
            // is a known studio AND a name some earlier parse guessed into the
            // actor list resolves as an actor purely because actors are checked
            // first — order deciding what confidence should.
            // ⚠️ `allSatisfy` is true for an empty array, so a segment that
            // splits to nothing (all separators, e.g. ", ,") would read as
            // "confirmed as both" and be reported as ambiguous rather than as
            // the unreadable text it is.
            let validActor = !entries.isEmpty
                && entries.allSatisfy { vocabulary.validatedActors.contains($0.lowercased()) }
            let validStudio = !entries.isEmpty
                && entries.allSatisfy { vocabulary.validatedStudios.contains($0.lowercased()) }

            if validActor && validStudio {
                // Confirmed as both. Nothing here can settle it, and guessing
                // would credit a video to the wrong kind of thing entirely.
                unplaced.append((index, segment))
                continue
            }
            if validActor {
                result.actors.append(contentsOf: entries)
                continue
            }
            if validStudio {
                result.studios.append(contentsOf: entries)
                continue
            }

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
        // Cast and tags accumulate: a video genuinely has several, and a
        // filename naming one the record lacks is new information.
        for actor in parsed.actors { add("actor:\(actor)") }
        for tag in parsed.tags { add("tag:\(tag)") }

        // Studio does NOT. A scene has one releasing studio, and anything
        // already recorded came from a download or from the operator — both of
        // which outrank a filename. Adding to it produced the two-studio state
        // this project spent a day unpicking, arriving from the other side.
        if asset.studios.isEmpty {
            for studio in parsed.studios { add("studio:\(studio)") }
        }

        // Only offered when the record has no series at all — a filename must
        // not overwrite one that was entered deliberately.
        let series = (asset.videoName?.isEmpty ?? true) ? parsed.seriesBlock : nil
        return (additions, series)
    }
}


/// One file's reading, ready to review.
public struct FileNameProposal: Equatable, Sendable, Identifiable {
    public let assetId: UUID
    public let fileName: String
    public let parsed: ParsedFileName
    /// Prefixed tags this would add, none of which the record already holds.
    public let additions: [String]
    public let seriesBlock: String?

    public var id: UUID { assetId }
    public var hasSomethingToAdd: Bool { !additions.isEmpty || seriesBlock != nil }

    /// Every segment was placed AND something new came of it. These are the
    /// ones safe to accept without reading each in turn.
    public var isClean: Bool { parsed.unrecognised.isEmpty && hasSomethingToAdd }

    public init(assetId: UUID, fileName: String, parsed: ParsedFileName,
                additions: [String], seriesBlock: String?) {
        self.assetId = assetId
        self.fileName = fileName
        self.parsed = parsed
        self.additions = additions
        self.seriesBlock = seriesBlock
    }
}

public extension FileNameParser {

    /// Reads every filename and reports what each would contribute.
    ///
    /// Files whose name yields nothing NEW are dropped: a review listing
    /// hundreds of rows that change nothing buries the ones that do. Files
    /// nothing could be read from are kept though — see `unreadable`, because
    /// "we could not read this" is a finding, not an absence.
    static func plan(assets: [Asset], vocabulary: NameVocabulary) -> [FileNameProposal] {
        assets.compactMap { asset in
            let parsed = parse(fileName: asset.fileName, vocabulary: vocabulary)
            let (additions, series) = additions(for: asset, parsed: parsed)
            let proposal = FileNameProposal(assetId: asset.id, fileName: asset.fileName,
                                            parsed: parsed, additions: additions,
                                            seriesBlock: series)
            return proposal.hasSomethingToAdd ? proposal : nil
        }
        // Cleanest first: a reviewer who stops halfway has still banked the
        // safe ones, and the doubtful rows are never hidden below them.
        .sorted {
            $0.parsed.confidence != $1.parsed.confidence
                ? $0.parsed.confidence > $1.parsed.confidence
                : $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
        }
    }

    /// Files whose names yielded nothing at all.
    ///
    /// Surfaced rather than silently skipped: these are the names the
    /// vocabulary cannot yet explain, and they are the list worth working
    /// through to make the NEXT pass read more.
    static func unreadable(assets: [Asset], vocabulary: NameVocabulary) -> [Asset] {
        assets.filter { parse(fileName: $0.fileName, vocabulary: vocabulary).isEmpty }
    }

    /// Applies a proposal, adding only what is missing.
    static func applying(_ proposal: FileNameProposal, to asset: Asset) -> Asset {
        var updated = asset
        var tags = updated.tags
        for addition in proposal.additions {
            let normalized = TagNormalizer.normalize(fullTag: addition)
            if !tags.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) {
                tags.append(normalized)
            }
        }
        updated.tags = tags
        if let series = proposal.seriesBlock, (updated.videoName?.isEmpty ?? true) {
            updated.videoName = series
        }
        return updated
    }
}
