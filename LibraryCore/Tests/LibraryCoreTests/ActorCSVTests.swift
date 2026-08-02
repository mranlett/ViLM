import XCTest
@testable import LibraryCore

/// Characterization tests for the actor CSV format.
///
/// These pin the behaviour that existed BEFORE the AKA/tag round-trip work, so the
/// extraction out of ActorGridView and the later column additions can both be shown
/// not to have changed anything they shouldn't. Per the project's standards:
/// characterization tests come first, and a refactor commit carries no behaviour change.
final class ActorCSVTests: XCTestCase {

    // Stand-ins for CountryFlagHelper, which lives in the app target.
    private let strip: (String) -> String = { $0.replacingOccurrences(of: "🇺🇸", with: "").trimmingCharacters(in: .whitespaces) }
    private let decorate: (String) -> String = { $0 == "US" ? "🇺🇸US" : $0 }
    private let identity: (String) -> String = { $0 }

    private func profile(
        id: String = "actor:Jane Doe",
        bio: String? = nil, photoUrl: String? = nil, homePage: String? = nil,
        gender: String? = nil, hairColor: String? = nil, birthYear: Int? = nil,
        country: String? = nil, rating: Int? = nil,
        tags: [String] = [], galleryUrls: [String] = [], akas: [String] = []
    ) -> EntityProfile {
        EntityProfile(id: id, bio: bio, photoUrl: photoUrl, homePage: homePage,
                      gender: gender, hairColor: hairColor, birthYear: birthYear,
                      countryOfOrigin: country, rating: rating,
                      tags: tags, galleryUrls: galleryUrls, akas: akas,
                      createdAt: Date(timeIntervalSince1970: 0))
    }

    // MARK: - Escaping

    func testEscapeLeavesPlainTextAlone() {
        XCTAssertEqual(ActorCSV.escape("Jane Doe"), "Jane Doe")
    }

    func testEscapeQuotesCellsContainingCommas() {
        XCTAssertEqual(ActorCSV.escape("Smith, Jr."), "\"Smith, Jr.\"")
    }

    func testEscapeDoublesInternalQuotesAndWraps() {
        XCTAssertEqual(ActorCSV.escape("She said \"hi\""), "\"She said \"\"hi\"\"\"")
    }

    func testEscapeWrapsEmbeddedNewlines() {
        XCTAssertEqual(ActorCSV.escape("line1\nline2"), "\"line1\nline2\"")
    }

    // MARK: - Parsing

    func testParseSplitsSimpleRows() {
        XCTAssertEqual(ActorCSV.parse("a,b,c\nd,e,f\n"), [["a", "b", "c"], ["d", "e", "f"]])
    }

    func testParseHonoursQuotedCommas() {
        XCTAssertEqual(ActorCSV.parse("\"Smith, Jr.\",b\n"), [["Smith, Jr.", "b"]])
    }

    func testParseUnescapesDoubledQuotes() {
        XCTAssertEqual(ActorCSV.parse("\"She said \"\"hi\"\"\",b\n"), [["She said \"hi\"", "b"]])
    }

    func testParseHandlesBareCR() {
        XCTAssertEqual(ActorCSV.parse("a,b\rc,d\r"), [["a", "b"], ["c", "d"]])
    }

    /// Regression test for the CRLF defect (#12).
    ///
    /// Swift treats "\r\n" as a SINGLE Character (grapheme cluster U+D U+A) which
    /// equals neither "\n" nor "\r", so the original literal comparison never split
    /// Windows-authored files: the document became one row, `dropFirst()` discarded
    /// it, and the import silently did nothing. This previously asserted the broken
    /// behaviour; it now asserts the fix.
    func testCRLFLineEndingsSplitRows() {
        XCTAssertEqual(ActorCSV.parse("a,b\r\nc,d"), [["a", "b"], ["c", "d"]])
    }

    func testAllThreeLineEndingsProduceIdenticalRows() {
        let expected = [["Name", "Bio"], ["Jane", "a bio"], ["John", "another"]]
        for (label, sep) in [("LF", "\n"), ("CRLF", "\r\n"), ("CR", "\r")] {
            let doc = "Name,Bio\(sep)Jane,a bio\(sep)John,another"
            XCTAssertEqual(ActorCSV.parse(doc), expected, "\(label) must parse like the others")
        }
    }

    func testMixedLineEndingsInOneFileParseCorrectly() {
        XCTAssertEqual(ActorCSV.parse("a,b\r\nc,d\ne,f\rg,h"),
                       [["a", "b"], ["c", "d"], ["e", "f"], ["g", "h"]])
    }

    func testACRLFFileWithQuotedEmbeddedNewlinesStillParses() {
        // The embedded newline is inside quotes and must stay part of the value,
        // while the CRLF outside the quotes still ends the row.
        let parsed = ActorCSV.parse("\"line1\nline2\",b\r\nc,d")
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0], ["line1\nline2", "b"])
        XCTAssertEqual(parsed[1], ["c", "d"])
    }

    func testAFullCRLFDocumentImportsTheSameProfilesAsLF() {
        let body = "Jane Doe,a bio,,,,Brown,1990,US,4,Janet,Redhead"
        let lf   = ActorCSV.header + "\n"   + body
        let crlf = ActorCSV.header + "\r\n" + body
        let lfRows   = Array(ActorCSV.parse(lf).dropFirst())
        let crlfRows = Array(ActorCSV.parse(crlf).dropFirst())
        XCTAssertEqual(lfRows.count, 1, "LF: one data row after skipping the header")
        XCTAssertEqual(crlfRows.count, 1, "CRLF: the bug made this ZERO, so nothing imported")
        XCTAssertEqual(lfRows, crlfRows)

        let a = ActorCSV.merge(columns: lfRows[0], existing: nil, decorateCountry: identity)
        let b = ActorCSV.merge(columns: crlfRows[0], existing: nil, decorateCountry: identity)
        XCTAssertEqual(a?.akas, b?.akas)
        XCTAssertEqual(a?.tags, b?.tags)
        XCTAssertEqual(a?.bio, b?.bio)
    }

    /// `isNewline` also covers the Unicode line separators. Deliberate: they are
    /// line terminators, and none is plausible inside an actor field.
    func testUnicodeLineSeparatorsAlsoSplitRows() {
        for sep in ["\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"] {
            XCTAssertEqual(ActorCSV.parse("a,b\(sep)c,d"), [["a", "b"], ["c", "d"]],
                           "U+\(String(sep.unicodeScalars.first!.value, radix: 16, uppercase: true)) is a line terminator")
        }
    }

    func testParseKeepsEmbeddedNewlineInsideQuotes() {
        XCTAssertEqual(ActorCSV.parse("\"line1\nline2\",b\n"), [["line1\nline2", "b"]])
    }

    func testParseHandlesFinalRowWithoutTrailingNewline() {
        XCTAssertEqual(ActorCSV.parse("a,b"), [["a", "b"]])
    }

    // MARK: - Export shape (the contract the importer depends on)

    func testHeaderCarriesAKAsAtNineAndTagsAtTen() {
        XCTAssertEqual(
            ActorCSV.header,
            "Name,Bio,PhotoURL,HomePage,Gender,HairColor,BirthYear,CountryOfOrigin,Rating,AKAs,Tags"
        )
        let names = ActorCSV.header.split(separator: ",").map(String.init)
        XCTAssertEqual(names[9], "AKAs", "index 9 is a contract — the importer reads positionally")
        XCTAssertEqual(names[10], "Tags", "index 10 is a contract")
        XCTAssertEqual(Array(names.prefix(9)),
                       ["Name", "Bio", "PhotoURL", "HomePage", "Gender", "HairColor",
                        "BirthYear", "CountryOfOrigin", "Rating"],
                       "the original nine columns must not move")
    }

    // MARK: - Multi-value cells

    func testListJoinsAndSplitsOnPipes() {
        XCTAssertEqual(ActorCSV.joinList(["Jane", "Janet"]), "Jane|Janet")
        XCTAssertEqual(ActorCSV.splitList("Jane|Janet"), ["Jane", "Janet"])
    }

    func testListTolerantOfSpacesAroundSeparators() {
        XCTAssertEqual(ActorCSV.splitList("John | Jon | Jonathan"), ["John", "Jon", "Jonathan"])
    }

    func testListDropsEmptyEntries() {
        XCTAssertEqual(ActorCSV.splitList("A||B|"), ["A", "B"])
        XCTAssertEqual(ActorCSV.splitList(""), [])
    }

    func testAValueContainingALiteralPipeRoundTripsRatherThanSplitting() {
        let awkward = ["A|B", "plain"]
        let cell = ActorCSV.joinList(awkward)
        XCTAssertEqual(cell, "A\\|B|plain", "the literal pipe is escaped, the separator is not")
        XCTAssertEqual(ActorCSV.splitList(cell), awkward, "and it comes back intact")
    }

    func testABackslashInAValueSurvivesTheRoundTrip() {
        let awkward = ["back\\slash", "trailing\\"]
        XCTAssertEqual(ActorCSV.splitList(ActorCSV.joinList(awkward)), awkward)
    }

    // MARK: - AKA and tag round-trip

    func testExportWritesAKAsAndTags() {
        let p = profile(tags: ["Redhead", "Favourite"], akas: ["Janet", "J.D."])
        let cells = ActorCSV.parse(ActorCSV.row(name: "Jane Doe", profile: p, stripCountry: identity))[0]
        XCTAssertEqual(cells[9], "Janet|J.D.")
        XCTAssertEqual(cells[10], "Redhead|Favourite")
    }

    func testImportUnionsAKAsWithExisting() {
        // The Human Operator's worked example: {John, Jon} + {John, Jonathan}
        let existing = profile(akas: ["John", "Jon"])
        var cols = Array(repeating: "", count: 11)
        cols[0] = "Jane Doe"
        cols[9] = "John|Jonathan"
        let merged = ActorCSV.merge(columns: cols, existing: existing, decorateCountry: identity)
        XCTAssertEqual(merged?.akas, ["John", "Jon", "Jonathan"])
    }

    func testImportUnionsTagsWithExisting() {
        let existing = profile(tags: ["Blonde"])
        var cols = Array(repeating: "", count: 11)
        cols[0] = "Jane Doe"
        cols[10] = "Blonde|Redhead"
        let merged = ActorCSV.merge(columns: cols, existing: existing, decorateCountry: identity)
        XCTAssertEqual(merged?.tags, ["Blonde", "Redhead"])
    }

    func testUnionDeduplicatesCaseInsensitivelyKeepingExistingCasing() {
        let existing = profile(akas: ["John"])
        var cols = Array(repeating: "", count: 11)
        cols[0] = "Jane Doe"
        cols[9] = "JOHN|Jonathan"
        let merged = ActorCSV.merge(columns: cols, existing: existing, decorateCountry: identity)
        XCTAssertEqual(merged?.akas, ["John", "Jonathan"], "existing casing wins; no duplicate")
    }

    func testAnEntryEqualToThePrimaryNameIsDropped() {
        var cols = Array(repeating: "", count: 11)
        cols[0] = "Jane Doe"
        cols[9] = "Jane Doe|Janet"
        cols[10] = "jane doe|Redhead"
        let merged = ActorCSV.merge(columns: cols, existing: nil, decorateCountry: identity)
        XCTAssertEqual(merged?.akas, ["Janet"])
        XCTAssertEqual(merged?.tags, ["Redhead"], "match is case-insensitive")
    }

    func testABlankAKACellNeverClearsAnExistingList() {
        let existing = profile(tags: ["keep-tag"], akas: ["keep-aka"])
        var cols = Array(repeating: "", count: 11)
        cols[0] = "Jane Doe"
        let merged = ActorCSV.merge(columns: cols, existing: existing, decorateCountry: identity)
        XCTAssertEqual(merged?.akas, ["keep-aka"])
        XCTAssertEqual(merged?.tags, ["keep-tag"])
    }

    func testGalleryUrlsAreStillCarriedOverAndNotRepresented() {
        let existing = profile(galleryUrls: ["g1", "g2"], akas: ["a"])
        var cols = Array(repeating: "", count: 11)
        cols[0] = "Jane Doe"
        cols[9] = "b"
        let merged = ActorCSV.merge(columns: cols, existing: existing, decorateCountry: identity)
        XCTAssertEqual(merged?.galleryUrls, ["g1", "g2"], "not in the format, never cleared")
        XCTAssertEqual(ActorCSV.header.split(separator: ",").count, 11, "and no column for it")
    }

    func testFullRoundTripOfAKAsAndTagsIsStable() {
        for akas in [[], ["One"], ["One", "Two", "Three"]] as [[String]] {
            let p = profile(tags: ["T1"], akas: akas)
            let doc = ActorCSV.document(actors: ["Jane Doe"], profileFor: { _ in p }, stripCountry: identity)
            let merged = ActorCSV.merge(columns: ActorCSV.parse(doc)[1], existing: p, decorateCountry: identity)
            XCTAssertEqual(merged?.akas, akas, "no-edit round trip must be byte-identical")
            XCTAssertEqual(merged?.tags, ["T1"])
        }
    }

    // MARK: - Header validation

    func testTheCanonicalHeaderIsAccepted() {
        XCTAssertNil(ActorCSV.validateHeader(ActorCSV.columnNames))
    }

    func testANineColumnLegacyHeaderIsAcceptedAsAValidPrefix() {
        let legacy = Array(ActorCSV.columnNames.prefix(9))
        XCTAssertNil(ActorCSV.validateHeader(legacy),
                     "files written before AKAs and Tags existed must keep importing")
    }

    func testExtraTrailingColumnsAreAccepted() {
        XCTAssertNil(ActorCSV.validateHeader(ActorCSV.columnNames + ["SomethingNew", "AndAnother"]),
                     "indices beyond the contract are ignored anyway")
    }

    func testCaseWhitespaceAndAByteOrderMarkAreTolerated() {
        var messy = ActorCSV.columnNames.map { $0.uppercased() }
        messy[0] = "\u{FEFF}  name  "
        XCTAssertNil(ActorCSV.validateHeader(messy),
                     "editors introduce all three; none changes which field a column denotes")
    }

    func testAReorderedHeaderIsRejectedAndNamesTheOffendingColumn() {
        var swapped = ActorCSV.columnNames
        swapped.swapAt(1, 3)                       // Bio <-> HomePage
        let problem = ActorCSV.validateHeader(swapped)
        XCTAssertEqual(problem, .unexpectedColumn(index: 1, found: "HomePage", expected: "Bio"))
        XCTAssertTrue(problem!.message.contains("column 2"), "1-based for the user")
        XCTAssertTrue(problem!.message.contains("HomePage"))
        XCTAssertTrue(problem!.message.contains("Bio"))
    }

    func testARenamedColumnIsRejected() {
        var renamed = ActorCSV.columnNames
        renamed[9] = "Aliases"                     // AKAs renamed
        XCTAssertEqual(ActorCSV.validateHeader(renamed),
                       .unexpectedColumn(index: 9, found: "Aliases", expected: "AKAs"))
    }

    func testAnInsertedColumnIsRejectedRatherThanShiftingEveryValue() {
        var inserted = ActorCSV.columnNames
        inserted.insert("Notes", at: 2)
        let problem = ActorCSV.validateHeader(inserted)
        XCTAssertEqual(problem, .unexpectedColumn(index: 2, found: "Notes", expected: "PhotoURL"),
                       "this is the case that would silently file every later value wrongly")
    }

    func testAHeaderlessFileIsRejectedRatherThanLosingItsFirstActor() {
        // Today the first row is discarded unread; without validation a headerless
        // file silently loses one actor.
        let dataRow = ["Jane Doe", "a bio", "", "", "", "Brown", "1990", "US", "4", "", ""]
        XCTAssertEqual(ActorCSV.validateHeader(dataRow),
                       .unexpectedColumn(index: 0, found: "Jane Doe", expected: "Name"))
    }

    func testAnEmptyOrBlankHeaderIsRejected() {
        XCTAssertEqual(ActorCSV.validateHeader([]), .empty)
        XCTAssertEqual(ActorCSV.validateHeader(["", "  ", ""]), .empty)
    }

    func testAValidatedDocumentRoundTripsThroughItsOwnHeader() {
        let doc = ActorCSV.document(actors: ["Jane Doe"], profileFor: { _ in nil }, stripCountry: identity)
        XCTAssertNil(ActorCSV.validateHeader(ActorCSV.parse(doc)[0]),
                     "what export writes must be what import accepts")
    }

    // MARK: - Backward compatibility

    func testNineColumnFilesFromBeforeThisChangeStillImport() {
        let legacy = "Name,Bio,PhotoURL,HomePage,Gender,HairColor,BirthYear,CountryOfOrigin,Rating\n"
                   + "Jane Doe,a bio,,,,Brown,1990,US,4\n"
        let rows = ActorCSV.parse(legacy)
        let existing = profile(tags: ["kept-tag"], akas: ["kept-aka"])
        let merged = ActorCSV.merge(columns: rows[1], existing: existing, decorateCountry: identity)
        XCTAssertNotNil(merged, "a nine-column row is not an error")
        XCTAssertEqual(merged?.bio, "a bio")
        XCTAssertEqual(merged?.birthYear, 1990)
        XCTAssertEqual(merged?.akas, ["kept-aka"], "absent columns leave the lists untouched")
        XCTAssertEqual(merged?.tags, ["kept-tag"])
    }

    func testRowPlacesEveryFieldAtItsContractualIndex() {
        let p = profile(bio: "b", photoUrl: "p", homePage: "h", gender: "Female",
                        hairColor: "Brown", birthYear: 1990, country: "🇺🇸US", rating: 4)
        let cells = ActorCSV.parse(ActorCSV.row(name: "Jane Doe", profile: p, stripCountry: strip))[0]
        XCTAssertEqual(cells[0], "Jane Doe")
        XCTAssertEqual(cells[1], "b")
        XCTAssertEqual(cells[2], "p")
        XCTAssertEqual(cells[3], "h")
        XCTAssertEqual(cells[4], "Female")
        XCTAssertEqual(cells[5], "Brown")
        XCTAssertEqual(cells[6], "1990")
        XCTAssertEqual(cells[7], "US", "the flag emoji must be stripped on export")
        XCTAssertEqual(cells[8], "4")
    }

    func testRowEmitsEmptyCellsForAMissingProfile() {
        let cells = ActorCSV.parse(ActorCSV.row(name: "Nobody", profile: nil, stripCountry: strip))[0]
        XCTAssertEqual(cells[0], "Nobody")
        XCTAssertEqual(cells.dropFirst().filter { !$0.isEmpty }, [], "no profile means every other cell is blank")
    }

    func testDocumentStartsWithTheHeaderAndOneRowPerActor() {
        let doc = ActorCSV.document(
            actors: ["A", "B"],
            profileFor: { _ in nil },
            stripCountry: strip
        )
        let rows = ActorCSV.parse(doc)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].first, "Name")
        XCTAssertEqual(rows[1].first, "A")
        XCTAssertEqual(rows[2].first, "B")
    }

    // MARK: - Merge

    func testMergeAppliesEveryPopulatedCell() {
        let cols = ["Jane Doe", "bio", "photo", "home", "Female", "Brown", "1990", "US", "5"]
        let merged = ActorCSV.merge(columns: cols, existing: nil, decorateCountry: decorate)
        XCTAssertEqual(merged?.id, "actor:Jane Doe")
        XCTAssertEqual(merged?.bio, "bio")
        XCTAssertEqual(merged?.birthYear, 1990)
        XCTAssertEqual(merged?.rating, 5)
        XCTAssertEqual(merged?.countryOfOrigin, "🇺🇸US", "the flag must be re-attached on import")
    }

    func testBlankCellsLeaveExistingValuesAlone() {
        let existing = profile(bio: "kept", photoUrl: "kept-photo", birthYear: 1985, rating: 3)
        let cols = ["Jane Doe", "", "", "", "", "", "", "", ""]
        let merged = ActorCSV.merge(columns: cols, existing: existing, decorateCountry: decorate)
        XCTAssertEqual(merged?.bio, "kept")
        XCTAssertEqual(merged?.photoUrl, "kept-photo")
        XCTAssertEqual(merged?.birthYear, 1985)
        XCTAssertEqual(merged?.rating, 3)
    }

    func testCollectionFieldsSurviveAMergeTheFormatCannotCarry() {
        let existing = profile(tags: ["t1", "t2"], galleryUrls: ["g1"], akas: ["Janet"])
        let merged = ActorCSV.merge(columns: ["Jane Doe", "new bio", "", ""], existing: existing, decorateCountry: decorate)
        XCTAssertEqual(merged?.tags, ["t1", "t2"])
        XCTAssertEqual(merged?.galleryUrls, ["g1"])
        XCTAssertEqual(merged?.akas, ["Janet"])
    }

    func testCreatedAtIsPreservedFromTheExistingProfile() {
        let existing = profile()
        let merged = ActorCSV.merge(columns: ["Jane Doe", "x", "", ""], existing: existing,
                                    decorateCountry: decorate, now: Date(timeIntervalSince1970: 999))
        XCTAssertEqual(merged?.createdAt, Date(timeIntervalSince1970: 0))
    }

    func testCreatedAtUsesNowForABrandNewProfile() {
        let merged = ActorCSV.merge(columns: ["Jane Doe", "x", "", ""], existing: nil,
                                    decorateCountry: decorate, now: Date(timeIntervalSince1970: 999))
        XCTAssertEqual(merged?.createdAt, Date(timeIntervalSince1970: 999))
    }

    // MARK: - Merge, failure states

    func testRowsBelowTheColumnGuardAreSkipped() {
        XCTAssertNil(ActorCSV.merge(columns: ["Jane", "a", "b"], existing: nil, decorateCountry: identity))
    }

    func testRowsWithAnEmptyNameAreSkipped() {
        XCTAssertNil(ActorCSV.merge(columns: ["", "a", "b", "c"], existing: nil, decorateCountry: identity))
    }

    func testNonNumericBirthYearAndRatingFallBackToExisting() {
        let existing = profile(birthYear: 1985, rating: 3)
        let cols = ["Jane Doe", "", "", "", "", "", "not-a-year", "", "not-a-rating"]
        let merged = ActorCSV.merge(columns: cols, existing: existing, decorateCountry: identity)
        XCTAssertEqual(merged?.birthYear, 1985)
        XCTAssertEqual(merged?.rating, 3)
    }

    func testShortRowStillMergesTheCellsItHas() {
        let existing = profile(bio: "old", photoUrl: "old-photo")
        let merged = ActorCSV.merge(columns: ["Jane Doe", "new", "", ""], existing: existing, decorateCountry: identity)
        XCTAssertEqual(merged?.bio, "new")
        XCTAssertEqual(merged?.photoUrl, "old-photo", "cells beyond the row length fall back to existing")
    }

    // MARK: - Round trip

    func testExportThenImportIsLosslessForRepresentableFields() {
        let p = profile(bio: "Bio, with comma", photoUrl: "https://x/a.jpg", homePage: "https://x",
                        gender: "Female", hairColor: "Brown", birthYear: 1992, country: "US", rating: 4)
        let doc = ActorCSV.document(actors: ["Jane Doe"], profileFor: { _ in p }, stripCountry: identity)
        let rows = ActorCSV.parse(doc)
        let merged = ActorCSV.merge(columns: rows[1], existing: p, decorateCountry: identity)
        XCTAssertEqual(merged?.bio, p.bio)
        XCTAssertEqual(merged?.photoUrl, p.photoUrl)
        XCTAssertEqual(merged?.homePage, p.homePage)
        XCTAssertEqual(merged?.gender, p.gender)
        XCTAssertEqual(merged?.hairColor, p.hairColor)
        XCTAssertEqual(merged?.birthYear, p.birthYear)
        XCTAssertEqual(merged?.countryOfOrigin, p.countryOfOrigin)
        XCTAssertEqual(merged?.rating, p.rating)
    }
}
