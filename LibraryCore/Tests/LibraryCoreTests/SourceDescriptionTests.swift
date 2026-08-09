// SourceDescriptionTests.swift
// Keeping the description we already fetch (#45, #46, #47 — S1–S9).
//
// 🚨 S1 is the one that matters. `Asset.notes` is the operator's own writing
// and is never submitted anywhere; a source description landing in it would be
// the one irreversible interaction with text they wrote by hand.
//
// ⭐ S8 and S9 exist because the obvious design is wrong. Reusing the record's
// `enrichmentSource` for attribution mis-credits silently: source A supplies
// text, a later match against B supplies none, the text stays and the record
// now says B. Provenance travels with the value.

import XCTest
@testable import LibraryCore

final class SourceDescriptionTests: XCTestCase {

    private func asset(notes: String? = nil, description: String? = nil,
                       from: String? = nil, releaseDate: String? = nil) -> Asset {
        var a = Asset(relativePath: "\(UUID()).mp4", fileName: "v.mp4", tags: [])
        a.notes = notes
        a.sourceDescription = description
        a.sourceDescriptionFrom = from
        a.releaseDate = releaseDate
        return a
    }

    private func proposal(description: String? = nil, from: String = "A Source",
                          releaseDate: String? = nil, releaseYear: Int? = nil)
    -> VideoMetadataProposal {
        var p = VideoMetadataProposal()
        if let description { p.notes = .init(description, sourceNote: from) }
        if let releaseDate { p.releaseDate = .init(releaseDate, sourceNote: from) }
        if let releaseYear { p.releaseYear = .init(releaseYear, sourceNote: from) }
        return p
    }

    private func rows(_ a: Asset, _ p: VideoMetadataProposal) -> [VideoFieldChange] {
        VideoEnrichmentReview.changes(for: a, proposal: p)
    }

    // MARK: - 🚨 S1 — the operator's notes are untouchable

    func testS1AFetchedDescriptionNeverLandsInNotes() {
        let a = asset(notes: "my own note")
        let merged = VideoEnrichmentReview.merged(asset: a, proposal: proposal(description: "the source's blurb"), accepting: [VideoEnrichmentReview.Field.sourceDescription])

        XCTAssertEqual(merged.notes, "my own note")
        XCTAssertEqual(merged.sourceDescription, "the source's blurb")
    }

    /// S2 — and a note survives repeated matching, which is when it would be
    /// eroded if anything were going to erode it.
    func testS2AnOperatorNoteSurvivesRepeatedMatching() {
        var a = asset(notes: "keep me")
        for i in 0..<3 {
            a = VideoEnrichmentReview.merged(
                asset: a, proposal: proposal(description: "blurb \(i)"),
                accepting: [VideoEnrichmentReview.Field.sourceDescription])
        }
        XCTAssertEqual(a.notes, "keep me")
        XCTAssertEqual(a.sourceDescription, "blurb 2")
    }

    /// ⚠️ The description is compared against `sourceDescription`, NOT against
    /// notes. Comparing against notes would show a conflict between the
    /// operator's writing and the source's, inviting one to replace the other.
    func testTheDescriptionIsNeverOfferedAsAConflictWithNotes() {
        let changed = rows(asset(notes: "my own note"), proposal(description: "a blurb"))
        let row = changed.first { $0.field == VideoEnrichmentReview.Field.sourceDescription }

        XCTAssertEqual(row?.kind, .fill, "a fill against an empty description, not a conflict with notes")
        XCTAssertEqual(row?.current, "")
    }

    // MARK: - S3/S4 — offered, not assigned

    func testS3ADescriptionNotAcceptedIsNotWritten() {
        let merged = VideoEnrichmentReview.merged(asset: asset(), proposal: proposal(description: "a blurb"), accepting: [])
        XCTAssertNil(merged.sourceDescription)
    }

    func testS4TheStoredDescriptionRecordsItsSource() {
        let merged = VideoEnrichmentReview.merged(asset: asset(), proposal: proposal(description: "a blurb", from: "A Source"), accepting: [VideoEnrichmentReview.Field.sourceDescription])

        XCTAssertEqual(merged.sourceDescriptionFrom, "A Source")
        XCTAssertNotNil(merged.sourceDescriptionAt)
    }

    // MARK: - 🚨 S5/S8/S9 — attribution cannot drift

    func testS5ASourceWithNoDescriptionLeavesTheFieldAlone() {
        let a = asset(description: "held", from: "A Source")
        let merged = VideoEnrichmentReview.merged(asset: a, proposal: proposal(), accepting: [VideoEnrichmentReview.Field.sourceDescription])

        XCTAssertEqual(merged.sourceDescription, "held")
    }

    /// The defect the audit found. A later match from a DIFFERENT source that
    /// supplies no description must not end up credited with the old text.
    func testS8AttributionSurvivesAMatchFromADifferentSourceWithNoDescription() {
        var a = asset(description: "written by A", from: "A Source")
        a.enrichmentSource = "A Source"

        // Source B matches, offers no description, and becomes the record's
        // enrichmentSource.
        a.enrichmentSource = "B Source"
        let merged = VideoEnrichmentReview.merged(
            asset: a, proposal: proposal(from: "B Source"),
            accepting: [VideoEnrichmentReview.Field.sourceDescription])

        XCTAssertEqual(merged.sourceDescription, "written by A")
        XCTAssertEqual(merged.sourceDescriptionFrom, "A Source",
                       "the text keeps ITS source, not the record's latest")
        XCTAssertNotEqual(merged.sourceDescriptionFrom, merged.enrichmentSource)
    }

    func testS9ANewDescriptionBringsItsOwnAttribution() {
        let a = asset(description: "written by A", from: "A Source")
        let merged = VideoEnrichmentReview.merged(asset: a, proposal: proposal(description: "written by B", from: "B Source"), accepting: [VideoEnrichmentReview.Field.sourceDescription])

        XCTAssertEqual(merged.sourceDescription, "written by B")
        XCTAssertEqual(merged.sourceDescriptionFrom, "B Source")
    }

    func testS6ASecondMatchFromTheSameSourceReplacesItsOwnText() {
        let a = asset(notes: "mine", description: "first", from: "A Source")
        let merged = VideoEnrichmentReview.merged(asset: a, proposal: proposal(description: "second", from: "A Source"), accepting: [VideoEnrichmentReview.Field.sourceDescription])

        XCTAssertEqual(merged.sourceDescription, "second")
        XCTAssertEqual(merged.notes, "mine")
    }

    // MARK: - 🔴 S7 — a year is not a date

    func testS7aAYearOnlyValueIsOfferedAsUnusable() {
        let row = rows(asset(), proposal(releaseYear: 2019))
            .first { $0.field == VideoEnrichmentReview.Field.releaseYearOnly }

        XCTAssertEqual(row?.kind, .unusable)
        XCTAssertEqual(row?.proposed, "2019", "it names the year rather than hiding it")
    }

    /// 🚨 Accepting it does nothing. There is no path from that row to a stored
    /// date, even for a caller that ticks it.
    func testS7bItCannotBeAccepted() {
        let merged = VideoEnrichmentReview.merged(asset: asset(), proposal: proposal(releaseYear: 2019), accepting: [VideoEnrichmentReview.Field.releaseYearOnly,
                        VideoEnrichmentReview.Field.releaseDate])

        XCTAssertNil(merged.releaseDate, "no fabricated 2019-01-01")
    }

    func testS7cNothingElseIsDisturbed() {
        let a = asset(notes: "mine", description: "held", from: "A Source",
                      releaseDate: "2015-06-01")
        let merged = VideoEnrichmentReview.merged(asset: a, proposal: proposal(releaseYear: 2019), accepting: [VideoEnrichmentReview.Field.releaseYearOnly])

        XCTAssertEqual(merged.releaseDate, "2015-06-01", "a known date is not replaced by a year")
        XCTAssertEqual(merged.notes, "mine")
        XCTAssertEqual(merged.sourceDescription, "held")
    }

    /// ⚠️ And a full date suppresses the year row entirely — the gap only
    /// exists when there is nothing better.
    func testAFullDateMeansNoUnusableRow() {
        let changed = rows(asset(), proposal(releaseDate: "2019-04-02", releaseYear: 2019))

        XCTAssertNil(changed.first { $0.field == VideoEnrichmentReview.Field.releaseYearOnly })
        XCTAssertNotNil(changed.first { $0.field == VideoEnrichmentReview.Field.releaseDate })
    }
}
