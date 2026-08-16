// ContentNamingTests.swift
// The four grammars, and every way they refuse (#17, F1/F6/F7/F7b).
//
// ⚠️ All names invented. This repository is public — see the note in
// `AliasSplitAudit`.

import XCTest
@testable import LibraryCore

final class ContentNamingTests: XCTestCase {

    private func asset(kind: ContentKind?, file: String = "clip.mp4",
                       series: String? = nil, season: Int? = nil,
                       episodeNumber: Int? = nil, episode: String? = nil,
                       released: String? = nil) -> Asset {
        Asset(relativePath: file, fileName: file,
              videoName: series, seasonNumber: season, episodeNumber: episodeNumber,
              episode: episode, contentKind: kind, releaseDate: released)
    }

    private func context(_ studio: StudioPlacement = .unprocessed,
                         _ cast: [(String, String?)] = []) -> NamingContext {
        NamingContext(studio: studio,
                      performers: cast.map { PerformerRef(name: $0.0, gender: $0.1) })
    }

    private func path(_ outcome: NamingOutcome) -> String? {
        if case let .path(p) = outcome { return p }
        return nil
    }

    // MARK: - F7 — undeclared selects no grammar

    /// The file stays in the root and stays usable. "Skipped" must never quietly
    /// become "broken".
    func testUndeclaredContentIsSkippedRatherThanGuessedAt() {
        let outcome = ContentNaming.path(for: asset(kind: nil, episode: "A Title"),
                                         in: context())
        XCTAssertEqual(outcome, .skipped(.undeclared))
    }

    // MARK: - Film

    func testAFilmGetsItsOwnFolderNamedWithTheYear() {
        let outcome = ContentNaming.path(
            for: asset(kind: .film, file: "x.mkv", episode: "The Long Weekend",
                       released: "2019-04-12"),
            in: context())
        XCTAssertEqual(path(outcome), "The Long Weekend (2019)/The Long Weekend (2019).mkv")
    }

    /// ⚠️ The year is the trailing segment, so its absence truncates the name
    /// rather than leaving `Title ()` behind.
    func testAFilmWithNoReleaseDateDropsTheYearAndItsBrackets() {
        let outcome = ContentNaming.path(
            for: asset(kind: .film, file: "x.mkv", episode: "The Long Weekend"),
            in: context())
        XCTAssertEqual(path(outcome), "The Long Weekend/The Long Weekend.mkv")
    }

    // MARK: - Episodic, and 🚨 F7b

    func testAnEpisodeIsFiledUnderItsSeriesAndSeason() {
        let outcome = ContentNaming.path(
            for: asset(kind: .episodic, file: "x.mkv", series: "Harbour Nights",
                       season: 1, episodeNumber: 2, episode: "Late Checkout"),
            in: context())
        XCTAssertEqual(path(outcome),
                       "Harbour Nights/Season 01/Harbour Nights - S01E02 - Late Checkout.mkv")
    }

    /// 🚨 F7b, and the reason it exists. Measured on the phone library: of 288
    /// videos declared episodic, 71 lack an episode number and 19 a series
    /// name. Not a hypothetical branch.
    ///
    /// ⚠️ The season is deliberately NOT in this list any more — see the test
    /// below. These two are what the F7b argument actually protects: neither
    /// has a convention to fall back on, and half a guess still produces a
    /// wrong path.
    func testAnEpisodeMissingItsNumbersIsReportedNotInvented() {
        let noEpisode = ContentNaming.path(
            for: asset(kind: .episodic, series: "Harbour Nights", season: 1),
            in: context())
        XCTAssertEqual(noEpisode, .skipped(.episodicNeeds("episode number")))

        let noSeries = ContentNaming.path(
            for: asset(kind: .episodic, season: 1, episodeNumber: 2),
            in: context())
        XCTAssertEqual(noSeries, .skipped(.episodicNeeds("series name")))
    }

    /// ⭐ The season default — decided 2026-08-15, reversing F7b's original
    /// call. 204 of 288 declared-episodic videos were missing ONLY a season,
    /// so the rule that bundled season with episode was rejecting two hundred
    /// files over the one field that has a real convention.
    func testAMissingSeasonIsFiledAsSeasonOneRatherThanRejected() {
        let outcome = ContentNaming.path(
            for: asset(kind: .episodic, file: "x.mkv", series: "Harbour Nights",
                       episodeNumber: 2, episode: "Late Checkout"),
            in: context())
        XCTAssertEqual(path(outcome),
                       "Harbour Nights/Season 01/Harbour Nights - S01E02 - Late Checkout.mkv")
    }

    /// 🚨 The half of the decision that is easy to lose. The default fills the
    /// PATH; it must never be written back to the asset, because the library
    /// has not been told what season this is and storing 1 would turn a filing
    /// convention into a claim about the work.
    func testAssumingASeasonDoesNotChangeTheAsset() {
        let subject = asset(kind: .episodic, file: "x.mkv", series: "Harbour Nights",
                            episodeNumber: 2)
        _ = ContentNaming.path(for: subject, in: context())
        XCTAssertNil(subject.seasonNumber,
                     "the assumed season must not leak into the record")
        XCTAssertTrue(ContentNaming.assumesSeason(for: subject),
                      "and the assumption must be reportable, so the dry run can state it")
    }

    /// ⚠️ A stated season still wins. The default is a fallback, not a rewrite.
    func testAStatedSeasonIsNotOverwrittenByTheDefault() {
        let subject = asset(kind: .episodic, file: "x.mkv", series: "Harbour Nights",
                            season: 3, episodeNumber: 2)
        XCTAssertEqual(path(ContentNaming.path(for: subject, in: context())),
                       "Harbour Nights/Season 03/Harbour Nights - S03E02.mkv")
        XCTAssertFalse(ContentNaming.assumesSeason(for: subject))
    }

    /// The episode title is the one droppable segment; series and marker are not.
    func testAnEpisodeWithNoTitleKeepsTheSeriesAndMarker() {
        let outcome = ContentNaming.path(
            for: asset(kind: .episodic, file: "x.mkv", series: "Harbour Nights",
                       season: 2, episodeNumber: 11),
            in: context())
        XCTAssertEqual(path(outcome), "Harbour Nights/Season 02/Harbour Nights - S02E11.mkv")
    }

    // MARK: - Scene

    func testASceneIsFiledUnderItsStudioWithCastAndDate() {
        let outcome = ContentNaming.path(
            for: asset(kind: .scene, released: "2019-04-12"),
            in: context(.filed("Example Pictures"),
                        [("Bea Example", "Female"), ("Alice Example", "Female")]))
        XCTAssertEqual(path(outcome),
                       "Example Pictures/Example Pictures - Alice Example, Bea Example - 2019-04-12.mp4")
    }

    // MARK: - 🚨 The title in a scene name (2026-08-15)

    /// The gap that produced a real collision: two scenes sharing a studio, a
    /// cast and a date got one name however different their titles were,
    /// because the title was not in the grammar at all. D2 lists the episode
    /// title under Identity with "in a filename? Yes", so the grammar was the
    /// half that disagreed with the spec.
    func testASceneNameCarriesItsTitleAfterTheCast() {
        let outcome = ContentNaming.path(
            for: asset(kind: .scene, episode: "Late Checkout", released: "2019-04-12"),
            in: context(.filed("Example Pictures"), [("Alice Example", "Female")]))
        XCTAssertEqual(path(outcome),
                       "Example Pictures/Example Pictures - Alice Example - Late Checkout - 2019-04-12.mp4")
    }

    /// 🚨 The case this was built for, asserted as a difference rather than as
    /// two separate expected strings — the property is that they do not collide.
    func testTwoScenesSharingStudioCastAndDateNoLongerCollide() {
        func name(_ title: String) -> String? {
            path(ContentNaming.path(
                for: asset(kind: .scene, episode: title, released: "2019-04-12"),
                in: context(.filed("Example Pictures"), [("Alice Example", "Female")])))
        }
        let first = name("Late Checkout")
        let second = name("Early Departure")
        XCTAssertNotNil(first)
        XCTAssertNotEqual(first, second,
                          "same studio, same cast, same date — the title is the only thing "
                          + "that can tell these apart")
    }

    /// ⚠️ D3's separator collapse, which the spec named as the reason titles
    /// were kept out of filenames. Folding it keeps the FIELD COUNT fixed, so
    /// the name still parses back into the same number of segments (F1).
    func testATitleContainingTheDelimiterDoesNotAddAField() {
        let outcome = ContentNaming.path(
            for: asset(kind: .scene, episode: "Room 12 - The Long Way Back",
                       released: "2019-04-12"),
            in: context(.filed("Example Pictures"), [("Alice Example", "Female")]))
        guard let name = path(outcome) else { return XCTFail("no path") }

        let stem = (name as NSString).lastPathComponent
        XCTAssertEqual(stem.components(separatedBy: " - ").count, 4,
                       "studio, cast, title, date — and the title must not split into two")
        XCTAssertTrue(name.contains("Room 12 – The Long Way Back"),
                      "the title still reads the same to a person")
    }

    /// 🚨 A scene with no recorded title must NOT inherit its old filename.
    /// `usableTitle` falls back to the stem, which is right for a record with
    /// nothing else (decision 6) and wrong here — it would bake the junk name
    /// the rename exists to remove into the new name permanently.
    func testASceneWithNoTitleDoesNotInheritItsOldFilename() {
        let outcome = ContentNaming.path(
            for: asset(kind: .scene, file: "Alice - tags - studio junk.mp4",
                       released: "2019-04-12"),
            in: context(.filed("Example Pictures"), [("Alice Example", "Female")]))
        XCTAssertEqual(path(outcome),
                       "Example Pictures/Example Pictures - Alice Example - 2019-04-12.mp4",
                       "the old stem must not survive into the generated name")
        XCTAssertNil(ContentNaming.recordedTitle(
            asset(kind: .scene, file: "Alice - tags - studio junk.mp4")))
    }

    /// The series is used when there is no episode title — a scene may still
    /// belong to a named grouping.
    func testASceneFallsBackToItsSeriesWhenThereIsNoEpisodeTitle() {
        XCTAssertEqual(ContentNaming.recordedTitle(
            asset(kind: .scene, series: "Harbour Nights")), "Harbour Nights")
    }

    /// ⚠️ Over the ceiling the title is SHORTENED, not dropped. Dropping it
    /// whole would reintroduce the collision it was added to resolve.
    func testAnOverlongSceneNameShortensTheTitleRatherThanLosingIt() {
        let longTitle = String(repeating: "Verylongword ", count: 30).trimmingCharacters(in: .whitespaces)
        let outcome = ContentNaming.path(
            for: asset(kind: .scene, episode: longTitle, released: "2019-04-12"),
            in: context(.filed("Example Pictures"), [("Alice Example", "Female")]))
        guard let name = path(outcome) else { return XCTFail("no path") }
        let stem = (name as NSString).lastPathComponent

        XCTAssertLessThanOrEqual(stem.utf8.count, PathComponentName.maximumBytes)
        XCTAssertTrue(stem.contains("Verylongword"),
                      "some of the title must survive — it is what disambiguates")
        XCTAssertTrue(stem.contains("Alice Example"), "the cast is dropped after the title")
        XCTAssertTrue(stem.contains("2019-04-12"), "the date is never dropped")
    }

    /// ⭐ Female and non-binary first, male last; alphabetical within a rank.
    ///
    /// 🚨 The male performer is named so he sorts FIRST alphabetically. An
    /// earlier version of this test used Ash/Bea/Zed, where the two orderings
    /// agree — so it passed with the gender rule deleted, which is no test at
    /// all. Mutation testing is what found that.
    func testFemaleAndNonBinaryPerformersComeBeforeMale() {
        let ordered = ContentNaming.orderedPerformers([
            PerformerRef(name: "Adam Example", gender: "Male"),
            PerformerRef(name: "Zara Example", gender: "Female"),
            PerformerRef(name: "Nova Example", gender: "Non-binary"),
        ])
        XCTAssertEqual(ordered, ["Nova Example", "Zara Example", "Adam Example"])
    }

    /// Three — and the one dropped is the male, even though he sorts first by
    /// name. The cap applies AFTER the rank, not before it.
    func testTheCastIsCappedAtThreeAfterRanking() {
        let ordered = ContentNaming.orderedPerformers([
            PerformerRef(name: "Adam Example", gender: "Male"),
            PerformerRef(name: "Vera Example", gender: "Female"),
            PerformerRef(name: "Wren Example", gender: "Female"),
            PerformerRef(name: "Zara Example", gender: "Female"),
        ])
        XCTAssertEqual(ordered, ["Vera Example", "Wren Example", "Zara Example"])
    }

    /// ⚠️ An unrecognised gender sorts with female rather than being dropped.
    /// The ordering has to be total or the name is not deterministic.
    func testAnUnknownGenderRanksWithFemaleRatherThanBeingDropped() {
        let ordered = ContentNaming.orderedPerformers([
            PerformerRef(name: "Adam Example", gender: "Male"),
            PerformerRef(name: "Zara Example", gender: nil),
        ])
        XCTAssertEqual(ordered, ["Zara Example", "Adam Example"])
    }

    /// 🚨 A missing field takes its separator with it. The naive join produces
    /// `" -  - "`, which then fails to parse back — the round trip F1 exists to
    /// catch.
    func testMissingFieldsTakeTheirSeparatorsWithThem() {
        let noDate = ContentNaming.path(
            for: asset(kind: .scene),
            in: context(.filed("Example Pictures"), [("Alice Example", "Female")]))
        XCTAssertEqual(path(noDate),
                       "Example Pictures/Example Pictures - Alice Example.mp4")

        let noCast = ContentNaming.path(
            for: asset(kind: .scene, released: "2019-04-12"),
            in: context(.filed("Example Pictures")))
        XCTAssertEqual(path(noCast), "Example Pictures/Example Pictures - 2019-04-12.mp4")

        for p in [path(noDate), path(noCast)] {
            XCTAssertFalse(p?.contains(" -  - ") ?? true, "empty segment left its separator")
            XCTAssertFalse(p?.contains("- .") ?? true, "dangling separator before the extension")
        }
    }

    // MARK: - N1 — a file's location states its processing status

    func testARuledOutStudioGoesToTheUnfiledFolderNotAFolderOfItsOwn() {
        let outcome = ContentNaming.path(
            for: asset(kind: .scene, released: "2019-04-12"),
            in: context(.unfiled, [("Alice Example", "Female")]))
        XCTAssertEqual(path(outcome), "Unfiled/Alice Example - 2019-04-12.mp4")
    }

    func testAnUnprocessedStudioLeavesTheFileInTheRoot() {
        let outcome = ContentNaming.path(
            for: asset(kind: .scene, released: "2019-04-12"),
            in: context(.unprocessed, [("Alice Example", "Female")]))
        XCTAssertEqual(path(outcome), "Alice Example - 2019-04-12.mp4")
    }

    /// 🚨 Kind is evaluated before placement. A personal video may carry a
    /// studio — mis-tagged, inherited from a filename, or matched in error —
    /// and none of that may file it beside commercial content.
    func testPersonalContentNeverReachesAStudioFolder() {
        for placement in [StudioPlacement.filed("Example Pictures"), .unfiled, .unprocessed] {
            let outcome = ContentNaming.path(
                for: asset(kind: .personal, file: "x.mov", episode: "Beach Trip",
                           released: "2019-07-01"),
                in: context(placement, [("Alice Example", "Female")]))
            XCTAssertEqual(path(outcome), "Personal/Beach Trip (2019).mov",
                           "placement \(placement) leaked into a personal path")
        }
    }

    // MARK: - The 549 with no series and no title

    /// Decision 6: named from the existing filename stem. Not inventing — it
    /// carries the evidence forward as the title.
    func testAVideoWithNoTitleIsNamedFromItsFilenameStem() {
        let outcome = ContentNaming.path(
            for: asset(kind: .film, file: "some original name.mkv"),
            in: context())
        XCTAssertEqual(path(outcome), "some original name/some original name.mkv")
    }

    /// ⚠️ A filename that is only whitespace before its extension. Not
    /// `".mp4"` — a leading dot makes that a hidden file, which the scanner
    /// never indexes (`.skipsHiddenFiles`), so testing it would exercise an
    /// input that cannot occur.
    func testAVideoWithNothingUsableAtAllIsReported() {
        let outcome = ContentNaming.path(
            for: Asset(relativePath: "blank.mp4", fileName: "   .mp4", contentKind: .film),
            in: context())
        XCTAssertEqual(outcome, .skipped(.noUsableName))
    }

    // MARK: - F6 — the ceiling

    /// ⚠️ Performers are dropped WHOLE. Half a name is a different person, and
    /// the parser would read it as one.
    func testAnOverlongSceneDropsWholePerformersFromTheEnd() {
        let long = String(repeating: "a", count: 90)
        let outcome = ContentNaming.path(
            for: asset(kind: .scene, released: "2019-04-12"),
            in: context(.filed("Example Pictures"),
                        [("\(long)1", "Female"), ("\(long)2", "Female"), ("\(long)3", "Female")]))
        let p = try! XCTUnwrap(path(outcome))
        let component = p.split(separator: "/").last.map(String.init) ?? p
        XCTAssertLessThanOrEqual(component.utf8.count, PathComponentName.maximumBytes)
        XCTAssertTrue(component.contains("2019-04-12"), "the date is never dropped")
        // No name may appear cut in half. ⚠️ The date is glued to the last
        // name by " - ", so strip it before comparing — an earlier version of
        // this check split on "," alone and flagged a name it had not truncated.
        let castPart = component.components(separatedBy: " - ").first ?? component
        let whole = Set(["\(long)1", "\(long)2", "\(long)3"])
        for fragment in castPart.split(separator: ",") {
            let name = fragment.trimmingCharacters(in: .whitespaces)
            XCTAssertTrue(whole.contains(name),
                          "a performer name was truncated mid-name: \(name.prefix(12))…")
        }
    }

    /// A single name over the ceiling cannot be shortened into something true.
    func testASinglePerformerNameOverTheCeilingIsReported() {
        let outcome = ContentNaming.path(
            for: asset(kind: .scene),
            in: context(.filed("Example Pictures"),
                        [(String(repeating: "b", count: 300), "Female")]))
        guard case let .skipped(.performerNameTooLong(name)) = outcome else {
            return XCTFail("expected a refusal, got \(outcome)")
        }
        XCTAssertEqual(name.count, 300)
    }

    // MARK: - Every generated component is legal

    /// 🚨 T18b. `/` and `:` occur in real titles and are illegal on macOS;
    /// the volume is ExFAT so Windows' set applies too.
    func testGeneratedPathsNeverContainIllegalCharactersInAComponent() {
        let nasty = "A/B: C*D?E\"F<G>H|I"
        let outcome = ContentNaming.path(
            for: asset(kind: .film, file: "x.mkv", episode: nasty, released: "2019-01-01"),
            in: context())
        let p = try! XCTUnwrap(path(outcome))
        for component in p.split(separator: "/") {
            for bad in [":", "*", "?", "\"", "<", ">", "|", "\\"] {
                XCTAssertFalse(component.contains(bad),
                               "\(bad) survived into a path component: \(component)")
            }
        }
    }
}
