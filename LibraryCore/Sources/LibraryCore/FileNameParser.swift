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

/// What the series/episode block turned out to be.
///
/// 🚨 Four fields, not one. The parser used to hand the whole block to the
/// series field and nothing else, which is how 188 of 310 series values became
/// titles filed under a series of their own (#51). The block is genuinely
/// ambiguous — `ParsedFileName.seriesBlock` is even documented as "the
/// series/episode block" — so calling all of it a series was a guess dressed as
/// a reading.
public struct SeriesEpisodeFields: Equatable, Sendable {
    public var series: String?
    public var seasonNumber: Int?
    public var episodeNumber: Int?
    public var episodeTitle: String?

    public var isEmpty: Bool {
        series == nil && seasonNumber == nil && episodeNumber == nil && episodeTitle == nil
    }

    public init(series: String? = nil, seasonNumber: Int? = nil,
                episodeNumber: Int? = nil, episodeTitle: String? = nil) {
        self.series = series
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.episodeTitle = episodeTitle
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

    /// Lowercased name → the library's own spelling of it.
    ///
    /// 🚨 A match is found in a FILENAME, and a filename's casing is not
    /// evidence. Writing back whatever the file happened to say would put a
    /// second spelling of a person into the library beside the confirmed one —
    /// which is the shape of the casing damage this project has already had to
    /// repair. The library's own display name wins.
    ///
    /// ⚠️ Built from the WHOLE vocabulary, not only the validated part (#76).
    /// Every branch that matches lowercased has to be able to answer in the
    /// library's spelling, and three of them match against `actors`, `studios`
    /// and `tags` — so a map covering only the validated names left those
    /// branches with nothing to look up. Validated names are applied last so
    /// they win a collision: a confirmed spelling outranks a remembered one.
    public let canonical: [String: String]

    public init(actors: Set<String> = [], studios: Set<String> = [], tags: Set<String> = [],
                validatedActors: Set<String> = [], validatedStudios: Set<String> = []) {
        var canonical: [String: String] = [:]
        for name in tags { canonical[name.lowercased()] = name }
        for name in studios { canonical[name.lowercased()] = name }
        for name in actors { canonical[name.lowercased()] = name }
        for name in validatedActors.union(validatedStudios) {
            canonical[name.lowercased()] = name
        }
        self.canonical = canonical
        self.actors = Set(actors.map { $0.lowercased() })
        self.studios = Set(studios.map { $0.lowercased() })
        self.tags = Set(tags.map { $0.lowercased() })
        self.validatedActors = Set(validatedActors.map { $0.lowercased() })
        self.validatedStudios = Set(validatedStudios.map { $0.lowercased() })
    }

    /// The library's own spelling of each name, where the library has one.
    ///
    /// 🚨 Call this on EVERY path that emits a name read out of a filename.
    /// Not doing so is the whole of #76: every branch here matches
    /// case-insensitively, so a branch that then returns the filename's text
    /// silently files a second spelling of a person beside the first — a split
    /// that no later count, filmography or leaderboard can see through. A name
    /// the library does not know is returned unchanged; it is the caller's job
    /// to have decided the name belongs.
    public func canonicalised(_ names: [String]) -> [String] {
        names.map { canonical[$0.lowercased()] ?? $0 }
    }

    /// Built from the library AND from what has been confirmed about it.
    ///
    /// A profile counts as validated when a lookup matched it. `matched` rather
    /// than "has a source id" deliberately: the id column is recent and
    /// populates only as records are re-matched, so requiring it would leave
    /// the validated set empty and the lexicon useless for a year. The id is
    /// the stronger signal and supersedes this as it fills in.
    public init(assets: [Asset], profiles: EntityProfileIndex) {
        var actors = Set<String>(), studios = Set<String>(), tags = Set<String>()
        for asset in assets {
            actors.formUnion(asset.actors)
            studios.formUnion(asset.studios)
            tags.formUnion(asset.actions)
        }

        // ⭐ Grouped by type and named by the column, rather than by testing
        // the id's prefix and slicing the name back out of it. Both of those
        // stop working the moment an id is a uid — the prefix matches nothing,
        // so the vocabulary would come out empty and every parsed name would
        // read as unvalidated.
        //
        // The empty-name guard stays: a malformed row would otherwise
        // contribute an empty string, which matches an empty entry and
        // validates nothing.
        var validatedActors = Set<String>(), validatedStudios = Set<String>()
        for profile in profiles.actors where profile.enrichmentState == .matched {
            if !profile.name.isEmpty { validatedActors.insert(profile.name) }
        }
        for profile in profiles.studios where profile.enrichmentState == .matched {
            if !profile.name.isEmpty { validatedStudios.insert(profile.name) }
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

    /// Names the vocabulary can find INSIDE a segment that matched nothing whole.
    ///
    /// 🚨 The filenames written before any renaming utility existed do not
    /// separate names with commas, so `splitList` hands back one entry that is
    /// not a name and the whole segment is discarded — with the vocabulary
    /// sitting right there, unconsulted. Measured on the drive library: 241
    /// videos carry no cast, and 119 of them name a known performer in the
    /// filename.
    ///
    /// ## 🚨 Validated, and at least two tokens. Both, and neither is optional.
    ///
    /// Scanning inside a segment invites false positives, and a wrongly
    /// credited performer is corruption rather than an absence.
    ///
    /// - **Two tokens** means a match is a full name rather than a word. Of
    ///   1,366 names in that library only 45 are a single token, and a single
    ///   token is also ordinary English.
    /// - **Validated** means the library has CONFIRMED that person exists,
    ///   rather than having seen the string once — possibly because an earlier
    ///   parse guessed it, which would then let one guess justify the next.
    ///
    /// Measured, the two rules together cost seven videos out of 119 and remove
    /// essentially all of the exposure. ⚠️ Loosening either without re-measuring
    /// throws away the only reason this is safe.
    ///
    /// ⭐ Matching runs over WORD WINDOWS of the original text rather than over
    /// a normalised copy, so the remainder keeps the operator's own spelling
    /// and punctuation — it is shown to them, and a mangled remainder is worse
    /// than none.
    ///
    /// - Returns: the canonical names found, longest-first, and what was left.
    static func embeddedNames(in segment: String,
                              from names: Set<String>,
                              canonical: [String: String]) -> (found: [String], remainder: String) {
        let words = segment.split(separator: " ").map(String.init)
        guard words.count >= 2 else { return ([], segment) }

        /// Comparable form: lowercased, letters and digits only.
        func fold(_ text: String) -> String {
            text.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "",
                                                   options: .regularExpression)
        }
        let folded = words.map(fold)

        // Multi-token only, longest-first so a longer name wins the tokens a
        // shorter one would have taken.
        //
        // ⚠️ Built in steps with explicit types. As one chained expression this
        // exceeded the type-checker's budget outright — the same reason
        // `AssetsGridView` lifts its own pipelines apart.
        var candidates: [(raw: String, parts: [String])] = []
        for name in names {
            var parts: [String] = []
            for word in name.split(separator: " ") {
                let piece = fold(String(word))
                if !piece.isEmpty { parts.append(piece) }
            }
            if parts.count >= 2 { candidates.append((raw: name, parts: parts)) }
        }
        candidates.sort { a, b in
            if a.parts.count != b.parts.count { return a.parts.count > b.parts.count }
            return a.parts.joined().count > b.parts.joined().count
        }

        var consumed = Array(repeating: false, count: words.count)
        var found: [String] = []

        for candidate in candidates {
            let width = candidate.parts.count
            guard width <= words.count else { continue }
            for start in 0...(words.count - width) {
                let range = start..<(start + width)
                // ⚠️ Never reuse a word. One token cannot serve two people, and
                // without this a name overlapping another would credit both.
                guard !range.contains(where: { consumed[$0] }) else { continue }
                guard Array(folded[range]) == candidate.parts else { continue }
                found.append(canonical[candidate.raw.lowercased()] ?? candidate.raw)
                range.forEach { consumed[$0] = true }
                break
            }
        }

        guard !found.isEmpty else { return ([], segment) }
        let remainder = words.enumerated()
            .filter { !consumed[$0.offset] }
            .map(\.element)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (found, remainder)
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
            // ⚠️ Every one of these five emits a name lifted out of a FILENAME
            // after matching it case-insensitively, so every one of them has to
            // answer in the library's spelling (#76). They did not: only the
            // embedded path below canonicalised, and these — older, and never
            // revisited when it was added — wrote the filename's casing
            // straight through.
            if validActor {
                result.actors.append(contentsOf: vocabulary.canonicalised(entries))
                continue
            }
            if validStudio {
                result.studios.append(contentsOf: vocabulary.canonicalised(entries))
                continue
            }

            if entries.allSatisfy({ vocabulary.actors.contains($0.lowercased()) }) {
                result.actors.append(contentsOf: vocabulary.canonicalised(entries))
            } else if entries.allSatisfy({ vocabulary.studios.contains($0.lowercased()) }) {
                result.studios.append(contentsOf: vocabulary.canonicalised(entries))
            } else if entries.allSatisfy({ vocabulary.tags.contains($0.lowercased()) }) {
                result.tags.append(contentsOf: vocabulary.canonicalised(entries))
            } else {
                // ⭐ Only reached when nothing placed the segment WHOLE, so a
                // comma-separated list that already parses is untouched — this
                // widens what can be read without changing what already works.
                let (people, afterPeople) = embeddedNames(
                    in: segment, from: vocabulary.validatedActors,
                    canonical: vocabulary.canonical)
                let (houses, remainder) = embeddedNames(
                    in: afterPeople, from: vocabulary.validatedStudios,
                    canonical: vocabulary.canonical)

                if people.isEmpty && houses.isEmpty {
                    unplaced.append((index, segment))
                } else {
                    result.actors.append(contentsOf: people)
                    result.studios.append(contentsOf: houses)
                    // ⚠️ What is left is REPORTED, not dropped. It is probably
                    // tags, and applying the tag vocabulary to it would compound
                    // one guess on another — measure the remainder before
                    // deciding that, rather than deciding it here by default.
                    if !remainder.isEmpty { unplaced.append((index, remainder)) }
                }
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
    /// - Parameter groupings: normalised names already behaving like a real
    ///   grouping — shared by more than one video, or carrying an episode
    ///   number. Empty is the safe default and the conservative reading: with
    ///   no evidence of a grouping, an unstructured block is one video's title.
    public static func additions(for asset: Asset, parsed: ParsedFileName,
                                 groupings: Set<String> = []) -> (tags: [String],
                                                                  block: SeriesEpisodeFields) {
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

        // ⚠️ Gated FIELD BY FIELD, not block by block. The old rule dropped the
        // whole block whenever a series was already recorded, so a video with a
        // series but no title never got its title — the very field the block
        // most often actually holds.
        var block = readBlock(parsed.seriesBlock, groupings: groupings)
        if !(asset.videoName?.isEmpty ?? true) { block.series = nil }
        if !(asset.episode?.isEmpty ?? true) { block.episodeTitle = nil }
        if asset.seasonNumber != nil { block.seasonNumber = nil }
        if asset.episodeNumber != nil { block.episodeNumber = nil }
        return (additions, block)
    }

    /// Reads the series/episode block into its parts.
    ///
    /// ⭐ Two rules, and they are deliberately the SAME two `SeriesTitleRepair`
    /// uses — otherwise the parser writes rows the repair tool immediately
    /// offers to undo, and the operator is caught between two tools that
    /// disagree:
    ///
    ///   • a number marker splits the block, because it says where the boundary
    ///     is — "Some Series Episode 3" is a series and an episode
    ///   • otherwise, a name shared by more than one video is a grouping, and a
    ///     name held by one video with nothing sequencing it is that video's
    ///     TITLE
    ///
    /// ⚠️ The fallback is title, not series. That is the whole fix: an
    /// unexplained block was previously assumed to be a series, and it usually
    /// is not.
    public static func readBlock(_ raw: String?,
                                 groupings: Set<String> = []) -> SeriesEpisodeFields {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return SeriesEpisodeFields()
        }
        let read = MediaTitleParser.parse(raw)
        if read.isStructured {
            return SeriesEpisodeFields(series: read.seriesName,
                                       seasonNumber: read.seasonNumber,
                                       episodeNumber: read.episodeNumber,
                                       episodeTitle: read.title)
        }
        return groupings.contains(groupingKey(raw))
            ? SeriesEpisodeFields(series: raw)
            : SeriesEpisodeFields(episodeTitle: raw)
    }

    static func groupingKey(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}


/// One file's reading, ready to review.
public struct FileNameProposal: Equatable, Sendable, Identifiable {
    public let assetId: UUID
    public let fileName: String
    public let parsed: ParsedFileName
    /// Prefixed tags this would add, none of which the record already holds.
    public let additions: [String]
    /// The series/episode block, already read into fields. Only the parts the
    /// record does not already hold.
    public let block: SeriesEpisodeFields

    public var id: UUID { assetId }
    public var hasSomethingToAdd: Bool { !additions.isEmpty || !block.isEmpty }

    /// Every segment was placed AND something new came of it. These are the
    /// ones safe to accept without reading each in turn.
    public var isClean: Bool { parsed.unrecognised.isEmpty && hasSomethingToAdd }

    public init(assetId: UUID, fileName: String, parsed: ParsedFileName,
                additions: [String], block: SeriesEpisodeFields) {
        self.assetId = assetId
        self.fileName = fileName
        self.parsed = parsed
        self.additions = additions
        self.block = block
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
        // 🚨 TWO passes. "Is this a series?" is a question about the whole
        // library, not about one filename — a name is a grouping precisely
        // because other videos share it, and a single file can never show that.
        // Deciding per-file is what filed 188 one-off titles as series.
        let readings = assets.map {
            (asset: $0, parsed: parse(fileName: $0.fileName, vocabulary: vocabulary))
        }
        let groupings = groupings(in: readings)

        return readings.compactMap { reading in
            let (additions, block) = additions(for: reading.asset, parsed: reading.parsed,
                                               groupings: groupings)
            let proposal = FileNameProposal(assetId: reading.asset.id,
                                            fileName: reading.asset.fileName,
                                            parsed: reading.parsed, additions: additions,
                                            block: block)
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

    /// Names that already behave like a real grouping, normalised for lookup.
    ///
    /// ⭐ Evidence from BOTH sides. What the library already records answers it
    /// for videos that have been curated; what the filenames themselves propose
    /// answers it for a fresh import, where a set of files sharing a block is a
    /// grouping on the FIRST pass rather than only after somebody has hand-
    /// accepted one of them.
    static func groupings(in readings: [(asset: Asset, parsed: ParsedFileName)]) -> Set<String> {
        var members: [String: Int] = [:]
        var numbered: Set<String> = []

        for reading in readings {
            // ⚠️ At most ONE key per video. Counting the recorded series AND the
            // filename block would let a single video whose filename repeats its
            // own series name reach a count of two and pass as a grouping — a
            // one-video "grouping", which is exactly the thing being fixed.
            var key: String?
            if let series = reading.asset.videoName, !series.isEmpty {
                key = groupingKey(series)
            } else if let block = reading.parsed.seriesBlock {
                let read = MediaTitleParser.parse(block)
                if read.isStructured {
                    // A number marker already settles it: whatever sits in front
                    // is a series however few videos currently share it.
                    if let name = read.seriesName { numbered.insert(groupingKey(name)) }
                } else {
                    key = groupingKey(block)
                }
            }
            guard let key else { continue }
            members[key, default: 0] += 1
            // A recorded episode number sequences it, which is the operator's
            // other reason for a series to exist.
            if reading.asset.episodeNumber != nil { numbered.insert(key) }
        }

        return Set(members.filter { $0.value > 1 }.keys).union(numbered)
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

        // Still additive: each field is written only where the record holds
        // nothing, so a filename never overwrites what a person or a source put
        // there. `additions` has already gated these; the checks are repeated
        // because `applying` is public and a caller can hand it any proposal.
        let block = proposal.block
        if let series = block.series, (updated.videoName?.isEmpty ?? true) {
            updated.videoName = series
        }
        if let title = block.episodeTitle, (updated.episode?.isEmpty ?? true) {
            updated.episode = title
        }
        if let season = block.seasonNumber, updated.seasonNumber == nil {
            updated.seasonNumber = season
        }
        if let number = block.episodeNumber, updated.episodeNumber == nil {
            updated.episodeNumber = number
        }
        return updated
    }
}
