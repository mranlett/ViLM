// ActorCSV.swift
// Parse and serialise for the Actor Gallery's CSV export/import.
//
// Extracted from ActorGridView so the format has unit coverage — it previously
// lived inside a SwiftUI view and could not be tested. This extraction is
// behaviour-preserving: the column set, the quoting rules, the positional read
// and the "blank cell leaves the existing value alone" merge are all unchanged.
//
// The two country transforms are injected rather than imported: CountryFlagHelper
// lives in the app target, and LibraryCore must not depend on it. Callers pass the
// real implementations; tests pass stubs.

import Foundation

public enum ActorCSV {

    // MARK: - Format

    /// Column order is a CONTRACT, not a convenience. `merge` reads by INDEX and
    /// ignores the header row entirely, so inserting or reordering a column would
    /// silently misfile every value after it — a bio would land in `homePage`.
    /// New columns append at the end only.
    /// ```
    /// 0 Name          3 HomePage    6 BirthYear         9  AKAs
    /// 1 Bio           4 Gender      7 CountryOfOrigin   10 Tags
    /// 2 PhotoURL      5 HairColor   8 Rating
    /// ```
    public static let header = "Name,Bio,PhotoURL,HomePage,Gender,HairColor,BirthYear,CountryOfOrigin,Rating,AKAs,Tags,BirthDate,CareerSpan,CareerStart,CareerEnd,AgeAtCareerStart,EnrichmentState,EnrichmentSource,EnrichmentCheckedAt"

    /// Rows with fewer cells than this are skipped. Historic guard: a row must at
    /// least carry Name/Bio/PhotoURL/HomePage to be worth merging.
    ///
    /// Deliberately NOT raised when AKAs/Tags were added: a nine-column file written
    /// before those columns existed must still import, and `cell(_:)` already bounds-
    /// checks every index, so a short row simply falls back to the existing value.
    public static let minimumColumnCount = 4

    /// Separator for multi-value cells (AKAs, Tags). A pipe is used rather than a
    /// comma so these cells never need quoting and survive hand-editing in a
    /// spreadsheet — and because a stage name may contain a comma ("Smith, Jr.")
    /// but never a pipe.
    public static let listSeparator: Character = "|"

    // MARK: - Multi-value cells

    /// Joins a list into one cell. A literal `|` or `\` inside a value is
    /// backslash-escaped so it round-trips rather than being silently split.
    public static func joinList(_ items: [String]) -> String {
        items
            .map { $0.replacingOccurrences(of: "\\", with: "\\\\")
                     .replacingOccurrences(of: "|", with: "\\|") }
            .joined(separator: String(listSeparator))
    }

    /// Splits a multi-value cell on unescaped separators, unescaping as it goes.
    /// Surrounding whitespace is trimmed so `A|B` and `A | B` are equivalent, and
    /// empty entries are dropped.
    public static func splitList(_ cell: String) -> [String] {
        var out: [String] = []
        var current = ""
        var escaping = false
        for ch in cell {
            if escaping {
                current.append(ch)
                escaping = false
            } else if ch == "\\" {
                escaping = true
            } else if ch == listSeparator {
                out.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        if escaping { current.append("\\") }   // trailing lone backslash stays literal
        out.append(current)
        return out
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Union of an existing list with an incoming one, de-duplicated case-insensitively
    /// (first occurrence wins, so existing casing is preserved), dropping any entry
    /// equal to the actor's primary name.
    ///
    /// Union rather than replace is deliberate: a truncated or accidentally cleared
    /// cell must never destroy curated data. The cost is that removal is not possible
    /// through the CSV — that stays an in-app action.
    static func union(_ existing: [String], _ incoming: [String], excludingName name: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for value in existing + incoming {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard trimmed.caseInsensitiveCompare(name) != .orderedSame else { continue }
            if seen.insert(trimmed.lowercased()).inserted { out.append(trimmed) }
        }
        return out
    }

    // MARK: - Serialisation

    public static func escape(_ text: String) -> String {
        var escaped = text.replacingOccurrences(of: "\"", with: "\"\"")
        if escaped.contains(",") || escaped.contains("\"") || escaped.contains("\n") {
            escaped = "\"\(escaped)\""
        }
        return escaped
    }

    /// One export row, newline-terminated.
    ///
    /// - Parameter stripCountry: removes the flag emoji from the stored country —
    ///   CSV can't carry it reliably, and `merge` re-attaches it on the way back in.
    public static func row(
        name: String,
        profile: EntityProfile?,
        stripCountry: (String) -> String
    ) -> String {
        let cells = [
            escape(name),
            escape(profile?.bio ?? ""),
            escape(profile?.photoUrl ?? ""),
            escape(profile?.homePage ?? ""),
            escape(profile?.gender ?? ""),
            escape(profile?.hairColor ?? ""),
            escape(profile?.birthYear.map { String($0) } ?? ""),
            escape(stripCountry(profile?.countryOfOrigin ?? "")),
            escape(profile?.rating.map { String($0) } ?? ""),
            // An entry equal to the primary name is redundant and is filtered on the
            // way out as well as the way in, so a no-edit round trip is stable.
            escape(joinList(union([], profile?.akas ?? [], excludingName: name))),
            escape(joinList(union([], profile?.tags ?? [], excludingName: name))),
            // Career span (schema v17). Appended at indices 11+ so every earlier
            // column keeps its position — the importer reads by index, not by
            // header, so inserting anywhere else would import silently wrong.
            escape(profile?.birthDate ?? ""),
            escape(profile?.careerSpanRaw ?? ""),
            escape(profile?.careerStartYear.map { String($0) } ?? ""),
            escape(profile?.careerEndYear.map { String($0) } ?? ""),
            // The STORED value only. `careerStartAge` derives one when this is
            // empty, and exporting a derived number would turn it into a stored
            // fact on the next import.
            escape(profile?.ageAtCareerStart.map { String($0) } ?? ""),
            // Enrichment state (schema v18), indices 16-18. The batch path is
            // the only thing that produces these at scale, and the CSV is its
            // only channel into the app — without these columns a run's results
            // stay in a log file.
            escape(profile?.enrichmentState?.rawValue ?? ""),
            escape(profile?.enrichmentSource ?? ""),
            escape(profile?.enrichmentCheckedAt.map(timestamp) ?? ""),
        ]
        return cells.joined(separator: ",") + "\n"
    }

    /// A complete CSV document: header plus one row per actor, in the order given.
    public static func document(
        actors: [String],
        profileFor: (String) -> EntityProfile?,
        stripCountry: (String) -> String
    ) -> String {
        var out = header + "\n"
        for actor in actors {
            out += row(name: actor, profile: profileFor(actor), stripCountry: stripCountry)
        }
        return out
    }

    // MARK: - Parsing

    /// Splits CSV text into rows of cells, honouring quoted cells, doubled quotes
    /// as a literal quote, and CR / LF / CRLF line endings.
    ///
    /// Row separation tests `Character.isNewline` rather than comparing against
    /// `"\n"` and `"\r"` literally. **Swift treats "\r\n" as a SINGLE Character**
    /// (grapheme cluster U+D U+A) which equals neither literal, so the literal form
    /// silently failed to split Windows-authored files: the whole document became
    /// one row, the header-skipping `dropFirst()` discarded it, and the import did
    /// nothing at all without reporting an error.
    ///
    /// `isNewline` is also true for the Unicode line separators (U+000B, U+000C,
    /// U+0085, U+2028, U+2029). Treating those as row breaks is intentional — they
    /// are line terminators, and none is plausible inside an actor field.
    public static func parse(_ content: String) -> [[String]] {
        var results: [[String]] = []
        var currentRow: [String] = []
        var currentCell = ""
        var insideQuotes = false

        let characters = Array(content)
        var i = 0
        while i < characters.count {
            let char = characters[i]

            if char == "\"" {
                if insideQuotes && i + 1 < characters.count && characters[i + 1] == "\"" {
                    currentCell.append("\"")
                    i += 1
                } else {
                    insideQuotes.toggle()
                }
            } else if char == "," && !insideQuotes {
                currentRow.append(currentCell)
                currentCell = ""
            } else if char.isNewline && !insideQuotes {
                // No CR/LF lookahead is needed: a CRLF pair is already one Character,
                // so consuming a following "\n" separately could never happen.
                currentRow.append(currentCell)
                results.append(currentRow)
                currentRow = []
                currentCell = ""
            } else {
                currentCell.append(char)
            }
            i += 1
        }
        if !currentCell.isEmpty || !currentRow.isEmpty {
            currentRow.append(currentCell)
            results.append(currentRow)
        }
        return results
    }

    /// The entity id a row maps to. Column 0 is the identity key — changing it
    /// creates a NEW actor rather than updating the existing one.
    public static func entityId(forName name: String) -> String { "actor:\(name)" }

    // MARK: - Enrichment cells

    /// Column positions for the v18 enrichment cells. Kept here, beside the
    /// `merge` that reads them, so a producer and the reader cannot drift.
    public enum EnrichmentColumn {
        public static let state = 16
        public static let source = 17
        public static let checkedAt = 18
        static let width = 19
    }

    /// Returns `columns` with the enrichment cells set.
    ///
    /// Pads a short row first: a file exported before v18 is 16 cells wide, and
    /// writing past the end would otherwise be impossible without silently
    /// changing every other row's shape.
    ///
    /// Passing a `nil` state leaves the row untouched — a request that FAILED is
    /// not a verdict, and must not be recorded as one.
    public static func settingEnrichment(in columns: [String],
                                         state: EnrichmentState?,
                                         source: String,
                                         checkedAt: Date) -> [String] {
        guard let state else { return columns }
        var out = columns
        if out.count < EnrichmentColumn.width {
            out += Array(repeating: "", count: EnrichmentColumn.width - out.count)
        }
        out[EnrichmentColumn.state] = state.rawValue
        out[EnrichmentColumn.source] = source
        out[EnrichmentColumn.checkedAt] = timestamp(checkedAt)
        return out
    }

    // MARK: - Timestamps

    /// ISO 8601 with a UTC offset, so a value means the same thing wherever the
    /// file is opened. Fixed format rather than a locale-aware one: this is an
    /// interchange format, not something shown to anyone.
    /// `nonisolated(unsafe)` because ISO8601DateFormatter is not marked
    /// Sendable, but Foundation's formatters are documented thread-safe for
    /// formatting and parsing once configured — and this one is configured once
    /// and never mutated. Same treatment ThumbnailLoader gives its NSCache.
    ///
    /// Shared rather than per-call: this runs once per row, and a 1,335-actor
    /// export would otherwise build the formatter 1,335 times.
    nonisolated(unsafe) private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    public static func timestamp(_ date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    public static func parseTimestamp(_ text: String) -> Date? {
        timestampFormatter.date(from: text)
    }

    // MARK: - Header validation

    /// The canonical column names, in contractual order.
    public static var columnNames: [String] {
        header.split(separator: ",").map(String.init)
    }

    /// Why a header row was rejected.
    public enum HeaderProblem: Equatable, Sendable {
        /// The file had no usable first row.
        case empty
        /// A column is not the one the importer expects at that position.
        case unexpectedColumn(index: Int, found: String, expected: String)

        /// Message suitable for showing to the user, naming the offending column.
        public var message: String {
            switch self {
            case .empty:
                return "the file is empty or has no header row."
            case let .unexpectedColumn(index, found, expected):
                let shown = found.isEmpty ? "an empty cell" : "\"\(found)\""
                return "column \(index + 1) is \(shown) but should be \"\(expected)\". "
                     + "Columns must stay in their original order — reordering or renaming them "
                     + "would file values under the wrong fields."
            }
        }
    }

    /// Checks a parsed header row against the contract.
    ///
    /// The importer reads by INDEX and never consults column names, so a reordered
    /// or renamed header would import silently wrong — a bio landing in `homePage`.
    /// This is the only thing standing between that and the user.
    ///
    /// Accepted deliberately:
    /// - **Fewer columns than the contract.** A nine-column file written before AKAs
    ///   and Tags existed is a valid prefix and must keep importing.
    /// - **Extra trailing columns.** Indices beyond the contract are ignored anyway.
    /// - **Case, surrounding whitespace, and a leading byte-order mark.** Spreadsheet
    ///   editors introduce all three; none changes which field a column denotes.
    ///
    /// - Returns: `nil` when the header is acceptable, otherwise the problem.
    public static func validateHeader(_ columns: [String]) -> HeaderProblem? {
        let cleaned = columns.map {
            $0.replacingOccurrences(of: "\u{FEFF}", with: "")
              .trimmingCharacters(in: .whitespaces)
        }
        guard cleaned.contains(where: { !$0.isEmpty }) else { return .empty }

        let expected = columnNames
        for (i, name) in expected.enumerated() where i < cleaned.count {
            if cleaned[i].caseInsensitiveCompare(name) != .orderedSame {
                return .unexpectedColumn(index: i, found: cleaned[i], expected: name)
            }
        }
        return nil
    }

    // MARK: - Merge

    /// Merges one parsed row over whatever profile already exists.
    ///
    /// A CSV row is usually a partial edit — a handful of fields filled in across
    /// many actors — so a BLANK cell must leave the existing value untouched.
    /// Collection fields the format cannot represent (tags, gallery URLs, AKAs)
    /// are carried over from `existing` and never cleared.
    ///
    /// - Returns: the merged profile, or `nil` when the row is too short or has no
    ///   name — both of which are skipped rather than treated as errors.
    public static func merge(
        columns: [String],
        existing: EntityProfile?,
        decorateCountry: (String) -> String,
        now: Date = Date()
    ) -> EntityProfile? {
        guard columns.count >= minimumColumnCount else { return nil }
        let name = columns[0]
        guard !name.isEmpty else { return nil }

        func cell(_ index: Int) -> String? {
            guard index < columns.count, !columns[index].isEmpty else { return nil }
            return columns[index]
        }

        return EntityProfile(
            id: entityId(forName: name),
            bio: cell(1) ?? existing?.bio,
            photoUrl: cell(2) ?? existing?.photoUrl,
            homePage: cell(3) ?? existing?.homePage,
            gender: cell(4) ?? existing?.gender,
            hairColor: cell(5) ?? existing?.hairColor,
            birthYear: cell(6).flatMap(Int.init) ?? existing?.birthYear,
            // Re-attach the flag emoji the export stripped out.
            countryOfOrigin: cell(7).map { decorateCountry($0) } ?? existing?.countryOfOrigin,
            rating: cell(8).flatMap(Int.init) ?? existing?.rating,
            // A blank cell leaves the existing list untouched; a populated one is
            // UNIONED with it, never substituted. galleryUrls stays carried-over:
            // it is not represented in this format at all.
            tags: cell(10).map { union(existing?.tags ?? [], splitList($0), excludingName: name) }
                ?? existing?.tags ?? [],
            galleryUrls: existing?.galleryUrls ?? [],
            akas: cell(9).map { union(existing?.akas ?? [], splitList($0), excludingName: name) }
                ?? existing?.akas ?? [],
            createdAt: existing?.createdAt ?? now,
            birthDate: cell(11) ?? existing?.birthDate,
            careerSpanRaw: cell(12) ?? existing?.careerSpanRaw,
            careerStartYear: cell(13).flatMap(Int.init) ?? existing?.careerStartYear,
            // A blank end cell means "unchanged", NOT "clear the end year" —
            // consistent with every other column here. An open span is expressed
            // by never having had an end, not by blanking one out.
            careerEndYear: cell(14).flatMap(Int.init) ?? existing?.careerEndYear,
            ageAtCareerStart: cell(15).flatMap(Int.init) ?? existing?.ageAtCareerStart,
            // An unrecognised state decodes as nil rather than failing the row:
            // a value written by a newer build must not make an actor
            // unimportable. A blank cell leaves the existing value alone, like
            // every other column here.
            enrichmentState: cell(16).flatMap(EnrichmentState.init(rawValue:)) ?? existing?.enrichmentState,
            enrichmentSource: cell(17) ?? existing?.enrichmentSource,
            enrichmentCheckedAt: cell(18).flatMap(parseTimestamp) ?? existing?.enrichmentCheckedAt
        )
    }
}
