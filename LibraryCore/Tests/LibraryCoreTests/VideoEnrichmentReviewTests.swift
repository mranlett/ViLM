import XCTest
@testable import LibraryCore

/// Reviewing a matched video's metadata.
///
/// The rules that matter are about restraint: a match must never overwrite a
/// value the operator already set, and must never remove anything. A source
/// that knows two of three performers must not be able to delete the third.
final class VideoEnrichmentReviewTests: XCTestCase {

    private func asset(tags: [String] = [],
                       series: String? = nil,
                       episodeTitle: String? = nil,
                       releaseDate: String? = nil) -> Asset {
        Asset(relativePath: "a.mp4", fileName: "a.mp4", tags: tags,
              videoName: series, episode: episodeTitle, releaseDate: releaseDate)
    }

    private func proposal(series: String? = nil, season: Int? = nil, episode: Int? = nil,
                          episodeTitle: String? = nil, releaseDate: String? = nil,
                          studio: String? = nil, performers: [String]? = nil,
                          tags: [String]? = nil) -> VideoMetadataProposal {
        var p = VideoMetadataProposal()
        p.seriesTitle = .init(series, sourceNote: "TestSource")
        p.seasonNumber = .init(season)
        p.episodeNumber = .init(episode)
        p.episodeTitle = .init(episodeTitle)
        p.releaseDate = .init(releaseDate)
        p.studio = .init(studio)
        p.actors = .init(performers)
        p.tags = .init(tags)
        return p
    }

    // MARK: - Classification

    func testEmptyFieldsAreOfferedAsFills() {
        let rows = VideoEnrichmentReview.changes(
            for: asset(),
            proposal: proposal(series: "Star Wars", episode: 4, episodeTitle: "A New Hope",
                               releaseDate: "1977-05-25"))
        XCTAssertEqual(rows.count, 4)
        XCTAssertTrue(rows.allSatisfy { $0.kind == .fill })
    }

    func testDisagreementIsAConflictNotAFill() {
        let rows = VideoEnrichmentReview.changes(
            for: asset(series: "Star Trek"),
            proposal: proposal(series: "Star Wars"))
        XCTAssertEqual(rows.first?.kind, .conflict)
        XCTAssertEqual(rows.first?.current, "Star Trek")
        XCTAssertEqual(rows.first?.proposed, "Star Wars")
    }

    /// Agreement is not news. A sheet full of "no change" rows hides the few
    /// that matter.
    func testAgreementIsNotShownAtAll() {
        let rows = VideoEnrichmentReview.changes(
            for: asset(series: "Star Wars"),
            proposal: proposal(series: "star wars"))
        XCTAssertTrue(rows.isEmpty, "case-insensitive agreement is still agreement")
    }

    func testFillsAreListedBeforeConflicts() {
        let rows = VideoEnrichmentReview.changes(
            for: asset(series: "Wrong Series"),
            proposal: proposal(series: "Star Wars", episodeTitle: "A New Hope"))
        XCTAssertEqual(rows.first?.kind, .fill)
        XCTAssertEqual(rows.last?.kind, .conflict)
    }

    /// Only the performers not already recorded are offered, so the row states
    /// what would actually change.
    func testOnlyNewPerformersAreOffered() throws {
        let rows = VideoEnrichmentReview.changes(
            for: asset(tags: ["actor:Alice Example"]),
            proposal: proposal(performers: ["Alice Example", "Bob Example"]))
        let row = try XCTUnwrap(rows.first { $0.field == VideoEnrichmentReview.Field.performers })
        XCTAssertEqual(row.proposed, "Bob Example")
    }

    func testNoRowWhenEveryPerformerIsAlreadyKnown() {
        let rows = VideoEnrichmentReview.changes(
            for: asset(tags: ["actor:Alice Example", "actor:Bob Example"]),
            proposal: proposal(performers: ["Bob Example", "Alice Example"]))
        XCTAssertTrue(rows.isEmpty)
    }

    // MARK: - Applying

    func testAcceptedFieldsAreApplied() {
        let merged = VideoEnrichmentReview.merged(
            asset: asset(),
            proposal: proposal(series: "Star Wars", season: 1, episode: 4,
                               episodeTitle: "A New Hope", releaseDate: "1977-05-25"),
            accepting: [VideoEnrichmentReview.Field.seriesTitle,
                        VideoEnrichmentReview.Field.seasonNumber,
                        VideoEnrichmentReview.Field.episodeNumber,
                        VideoEnrichmentReview.Field.episodeTitle,
                        VideoEnrichmentReview.Field.releaseDate])
        XCTAssertEqual(merged.videoName, "Star Wars")
        XCTAssertEqual(merged.seasonNumber, 1)
        XCTAssertEqual(merged.episodeNumber, 4)
        XCTAssertEqual(merged.episode, "A New Hope")
        XCTAssertEqual(merged.releaseDate, "1977-05-25")
    }

    /// The property the whole review exists for.
    func testUnacceptedFieldsAreLeftAlone() {
        let original = asset(series: "Mine", episodeTitle: "My Title")
        let merged = VideoEnrichmentReview.merged(
            asset: original,
            proposal: proposal(series: "Theirs", episodeTitle: "Their Title"),
            accepting: [])
        XCTAssertEqual(merged.videoName, "Mine")
        XCTAssertEqual(merged.episode, "My Title")
    }

    func testStudioBecomesAPrefixedTag() {
        let merged = VideoEnrichmentReview.merged(
            asset: asset(), proposal: proposal(studio: "Example Pictures"),
            accepting: [VideoEnrichmentReview.Field.studio])
        XCTAssertTrue(merged.tags.contains { $0.caseInsensitiveCompare("studio:Example Pictures") == .orderedSame })
        XCTAssertEqual(merged.studios, ["Example Pictures"])
    }


    /// Additive, never destructive: a source knowing two of three people must
    /// not be able to drop the third.
    func testAcceptingPerformersAddsWithoutRemoving() {
        let merged = VideoEnrichmentReview.merged(
            asset: asset(tags: ["actor:Carol Example"]),
            proposal: proposal(performers: ["Alice Example", "Bob Example"]),
            accepting: [VideoEnrichmentReview.Field.performers])
        XCTAssertEqual(merged.actors.sorted(), ["Alice Example", "Bob Example", "Carol Example"])
    }

    func testAcceptingAPerformerAlreadyPresentDoesNotDuplicate() {
        let merged = VideoEnrichmentReview.merged(
            asset: asset(tags: ["actor:Alice Example"]),
            proposal: proposal(performers: ["Alice Example"]),
            accepting: [VideoEnrichmentReview.Field.performers])
        XCTAssertEqual(merged.actors, ["Alice Example"])
    }

    /// A provider that supplies only a plain title populates the episode title.
    func testPlainTitleFallsBackToTheEpisodeTitle() {
        var p = VideoMetadataProposal()
        p.title = .init("Just Rivals")
        let rows = VideoEnrichmentReview.changes(for: asset(), proposal: p)
        XCTAssertEqual(rows.first?.field, VideoEnrichmentReview.Field.episodeTitle)
        XCTAssertEqual(rows.first?.proposed, "Just Rivals")
    }
}

/// Tag vocabulary control.
///
/// Sources tag far more finely than a personal library does — one real record
/// carried seventy on a single video. Accepting that wholesale destroys the
/// vocabulary the operator built and makes the tag list useless for filtering.

/// Tag selection.
///
/// A source tags far more finely than a person does — one real record carried
/// seventy on a single video. Every one is offered, but only the ones already
/// in use are ticked, so a first accept cannot bury a hand-built vocabulary.
extension VideoEnrichmentReviewTests {

    private func taggedProposal(_ tags: [String]) -> VideoMetadataProposal {
        var p = VideoMetadataProposal()
        p.tags = .init(tags)
        return p
    }

    private var blank: Asset { Asset(relativePath: "a.mp4", fileName: "a.mp4") }

    func testEveryUnheldTagIsOffered() {
        let options = VideoEnrichmentReview.tagOptions(
            for: blank,
            proposal: taggedProposal(["Outdoors", "Night", "Obscure Term"]),
            knownTags: ["outdoors"])
        XCTAssertEqual(options.count, 3, "nothing is hidden")
    }

    func testOnlyKnownTagsAreTickedByDefault() {
        let options = VideoEnrichmentReview.tagOptions(
            for: blank,
            proposal: taggedProposal(["Outdoors", "Night", "Obscure Term"]),
            knownTags: ["outdoors", "night"])
        XCTAssertEqual(VideoEnrichmentReview.defaultSelection(options), ["Outdoors", "Night"])
    }

    func testKnownTagsSortFirst() {
        let options = VideoEnrichmentReview.tagOptions(
            for: blank,
            proposal: taggedProposal(["Alpha Unknown", "Zulu Known"]),
            knownTags: ["zulu known"])
        XCTAssertEqual(options.first?.name, "Zulu Known")
        XCTAssertTrue(options.first?.isKnown == true)
    }

    func testTagsAlreadyOnTheVideoAreNotOffered() {
        let options = VideoEnrichmentReview.tagOptions(
            for: Asset(relativePath: "a.mp4", fileName: "a.mp4", tags: ["tag:Outdoors"]),
            proposal: taggedProposal(["Outdoors", "Night"]),
            knownTags: ["outdoors", "night"])
        XCTAssertEqual(options.map(\.name), ["Night"])
    }

    func testWithNoVocabularyNothingIsTicked() {
        let options = VideoEnrichmentReview.tagOptions(
            for: blank, proposal: taggedProposal(["Anything", "Goes"]), knownTags: [])
        XCTAssertEqual(options.count, 2)
        XCTAssertTrue(VideoEnrichmentReview.defaultSelection(options).isEmpty,
                      "an empty vocabulary means nothing is known, so nothing is presumed")
    }

    /// Only what was ticked is applied — a tag cannot arrive by another route.
    func testExactlyTheSelectedTagsAreApplied() {
        let merged = VideoEnrichmentReview.merged(
            asset: blank,
            proposal: taggedProposal(["Outdoors", "Night", "Obscure Term"]),
            accepting: [],
            acceptedTags: ["Outdoors", "Obscure Term"])
        XCTAssertEqual(merged.actions.sorted(), ["Obscure Term", "Outdoors"])
    }

    func testSelectedTagsAcquireTheStoredPrefix() {
        let merged = VideoEnrichmentReview.merged(
            asset: blank, proposal: taggedProposal(["Night"]),
            accepting: [], acceptedTags: ["Night"])
        XCTAssertTrue(merged.tags.contains { $0.caseInsensitiveCompare("tag:Night") == .orderedSame })
    }

    func testSelectingNoTagsChangesNothing() {
        let merged = VideoEnrichmentReview.merged(
            asset: blank, proposal: taggedProposal(["Night"]),
            accepting: [], acceptedTags: [])
        XCTAssertTrue(merged.actions.isEmpty)
    }
}
