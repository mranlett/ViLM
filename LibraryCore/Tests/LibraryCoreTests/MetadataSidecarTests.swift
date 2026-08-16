// MetadataSidecarTests.swift
// Metadata Sidecars — S2 to S6.
//
// ⚠️ All names invented. This repository is public.

import XCTest
@testable import LibraryCore

final class MetadataSidecarTests: XCTestCase {

    private func asset(kind: ContentKind? = .scene,
                       file: String = "clip.mp4",
                       tags: [String] = [],
                       series: String? = nil, episode: String? = nil,
                       episodeNumber: Int? = nil, released: String? = nil,
                       description: String? = nil, notes: String? = nil,
                       rating: Int? = nil, playCount: Int = 0,
                       sourceId: String? = nil, source: String? = nil) -> Asset {
        Asset(relativePath: file, fileName: file, tags: tags, notes: notes,
              sourceDescription: description, rating: rating,
              videoName: series, episodeNumber: episodeNumber, episode: episode,
              contentKind: kind, releaseDate: released,
              enrichmentSource: source, enrichmentSourceId: sourceId,
              playCount: playCount)
    }

    private func document(_ a: Asset, cast: [SidecarPerformer] = [],
                          studio: String? = nil) -> String? {
        MetadataSidecar.document(for: a, cast: cast, studio: studio, fallbackTitle: "clip")
    }

    // MARK: - 🚨 S2 — personal content writes no sidecar

    /// Asserted for `personal` and `nil` SEPARATELY, because they are different
    /// states that must produce the same silence. A plaintext file beside a home
    /// video puts names and places on removable media in clear text, and
    /// undeclared is not the same as safe.
    func testS2PersonalAndUndeclaredContentWriteNothing() {
        XCTAssertNil(document(asset(kind: .personal, episode: "Beach Trip")))
        XCTAssertNil(document(asset(kind: nil, episode: "Something")))
    }

    func testS2DeclaredCommercialContentDoesWriteOne() {
        for kind in [ContentKind.scene, .film, .episodic] {
            XCTAssertNotNil(document(asset(kind: kind, episode: "A Title")),
                            "\(kind) should produce a sidecar")
        }
    }

    // MARK: - 🚨 S3 — standard elements only

    /// Kodi tolerates unknown elements rather than reading them, so a custom
    /// field would travel and never be used. Asserted as a WHITELIST so the
    /// rule cannot erode one convenient field at a time.
    func testS3OnlyStandardKodiElementsAreEmitted() {
        let doc = document(asset(tags: ["tag:Example", "actor:Alice Example"],
                                 series: "Harbour Nights", episode: "Late Checkout",
                                 episodeNumber: 2, released: "2019-04-12",
                                 description: "A description.", notes: "private",
                                 rating: 4, playCount: 3,
                                 sourceId: "abc", source: "Example Source"),
                           cast: [SidecarPerformer(name: "Alice Example", thumbURL: "u")],
                           studio: "Example Pictures")!

        let allowed: Set<String> = ["movie", "title", "set", "name", "sorttitle",
                                    "premiered", "year", "plot", "userrating",
                                    "studio", "tag", "actor", "order", "thumb",
                                    "playcount", "lastplayed", "uniqueid"]
        let found = Set(doc.matches(of: /<([a-z]+)[ >]/).map { String($0.output.1) })
        XCTAssertTrue(found.isSubset(of: allowed),
                      "non-standard elements emitted: \(found.subtracting(allowed))")
    }

    /// ⚠️ Operator Notes are private and must never reach a file that travels.
    func testS3OperatorNotesAreNeverExported() {
        let doc = document(asset(description: "public blurb", notes: "PRIVATE NOTE"))!
        XCTAssertTrue(doc.contains("public blurb"))
        XCTAssertFalse(doc.contains("PRIVATE NOTE"))
    }

    // MARK: - 🚨 S4 — every performer reaches the sidecar

    /// The filename caps at three because a PATH has a length limit. An XML
    /// document does not, and letting a naming constraint leak in here would
    /// drop cast from the one artefact meant to carry it.
    func testS4EveryPerformerIsIncludedNotJustTheFilenamesThree() {
        let cast = (1...6).map { SidecarPerformer(name: "Performer \($0) Example",
                                                  thumbURL: nil) }
        let doc = document(asset(), cast: cast)!
        XCTAssertEqual(doc.components(separatedBy: "<actor>").count - 1, 6)
        XCTAssertTrue(doc.contains("Performer 6 Example"),
                      "the cap is a path constraint and must not reach the sidecar")
    }

    // MARK: - 🚨 S5 — a blank field is omitted, not emitted empty

    /// `<plot/>` reads to a consumer as "this has no description", which is a
    /// claim. Saying nothing says nothing, which is true.
    func testS5BlankFieldsAreOmittedRatherThanEmitted() {
        let doc = document(asset(released: nil, description: nil, rating: nil))!
        XCTAssertFalse(doc.contains("<plot>"))
        XCTAssertFalse(doc.contains("<premiered>"))
        XCTAssertFalse(doc.contains("<userrating>"))
        XCTAssertFalse(doc.contains("<year>"))
    }

    func testS5WhitespaceOnlyCountsAsBlank() {
        let doc = document(asset(description: "   "))!
        XCTAssertFalse(doc.contains("<plot>"))
    }

    // MARK: - 🚨 S6 — named for the file it accompanies

    func testS6TheSidecarIsNamedForItsVideo() {
        XCTAssertEqual(MetadataSidecar.path(forVideo: "Studio/Studio - Alice - 2019.mp4"),
                       "Studio/Studio - Alice - 2019.nfo")
        XCTAssertEqual(MetadataSidecar.path(forVideo: "top level.mkv"), "top level.nfo")
    }

    // MARK: - The mapping

    func testTheRatingIsDoubledOntoKodisScale() {
        XCTAssertTrue(document(asset(rating: 4))!.contains("<userrating>8</userrating>"))
    }

    /// The full date is preserved; the year is the coarse form beside it, not a
    /// replacement for it.
    func testTheFullDateSurvivesBesideTheYear() {
        let doc = document(asset(released: "2019-04-12"))!
        XCTAssertTrue(doc.contains("<premiered>2019-04-12</premiered>"))
        XCTAssertTrue(doc.contains("<year>2019</year>"))
    }

    /// ⚠️ A series standing alone is the video's own name. Calling that a set
    /// would invent a collection of one.
    func testASeriesWithNoEpisodeTitleIsNotClaimedAsASet() {
        XCTAssertFalse(document(asset(series: "Harbour Nights"))!.contains("<set>"))
        XCTAssertTrue(document(asset(series: "Harbour Nights",
                                     episode: "Late Checkout"))!.contains("<set>"))
    }

    /// 🚨 A title containing `&` or `<` is ordinary, and an unescaped one
    /// produces a document no consumer can read — failing on the receiving side
    /// where nobody is watching.
    func testMarkupInAValueIsEscaped() {
        let doc = document(asset(episode: "Tom & Jerry <the sequel>"))!
        XCTAssertTrue(doc.contains("Tom &amp; Jerry &lt;the sequel&gt;"))
        XCTAssertFalse(doc.contains("Jerry <the"))
    }

    /// D8 — the show-level document carries the two fields an episode sidecar
    /// cannot: studio, at 88% coverage, and tags.
    func testTheShowDocumentCarriesStudioAndTags() {
        let doc = MetadataSidecar.showDocument(series: "Harbour Nights",
                                               studios: ["Example Pictures"],
                                               tags: ["Example"])
        XCTAssertTrue(doc.contains("<tvshow>"))
        XCTAssertTrue(doc.contains("<title>Harbour Nights</title>"))
        XCTAssertTrue(doc.contains("<studio>Example Pictures</studio>"))
        XCTAssertTrue(doc.contains("<tag>Example</tag>"))
    }
}
