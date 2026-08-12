// PerformerDetailTests.swift
// Performer Detail's first cut: a definitive career end, and the strongest
// disambiguator on the list.
//
// ⭐ D1 — identification is the criterion, not completeness. A field earns its
// place if it helps tell two performers of one name apart, or fixes something
// that is actually wrong. `scene_count` does the first ("400 scenes" against
// "3" separates two of a name faster than a birth year); `death_date` does the
// second.
//
// 🔴 Two corrections to the spec, from introspecting the live schema:
//
//   • `measurements` DOES NOT EXIST. D3 argues at length that it is "its own
//     type upstream, not a string" and that flattening it would throw away
//     what makes it comparable. There is no such field — the source has
//     `cup_size`, `breast_type` and `height` separately.
//   • `eye_color` and `breast_type` are ENUMS, not free text.
//
// Neither is in this first cut, but the spec should not be trusted on them.

import XCTest
@testable import LibraryCore

final class PerformerDetailTests: XCTestCase {

    private func profile(deathDate: String? = nil, careerEnd: Int? = nil,
                         sceneCount: Int? = nil) -> EntityProfile {
        var p = EntityProfile(id: UUID().uuidString, entityType: "actor",
                              displayName: "Vera Example")
        p.deathDate = deathDate
        p.careerEndYear = careerEnd
        p.sceneCount = sceneCount
        p.careerStartYear = 2005
        return p
    }

    // MARK: - 🚨 D5 — a death date ends the career

    /// The wrongness this fixes. A nil career end means "still performing",
    /// which for someone who has died is not absent, it is false — and nothing
    /// in the app would ever have said so.
    func testADeathDateEndsAnOtherwiseOpenCareer() {
        XCTAssertEqual(profile(deathDate: "2018-04-02").effectiveCareerEndYear, 2018)
    }

    /// ⭐ P4 — a RECORDED end always wins. Someone may have retired years
    /// before they died, and that is the truer end of a career.
    func testARecordedEndBeatsTheDeathDate() {
        let p = profile(deathDate: "2018-04-02", careerEnd: 2012)
        XCTAssertEqual(p.effectiveCareerEndYear, 2012)
    }

    /// ⚠️ Still open when neither is known. Inferring an end from silence is
    /// what would turn every living performer into a finding.
    func testACareerWithNeitherStaysOpen() {
        XCTAssertNil(profile().effectiveCareerEndYear)
    }

    func testAYearOnlyDeathDateStillEndsTheCareer() {
        XCTAssertEqual(profile(deathDate: "2018").effectiveCareerEndYear, 2018)
    }

    /// ⚠️ Garbage in the field must not silently become a career end — that
    /// would retire a living performer on the strength of a typo.
    func testAnUnparseableDeathDateIsIgnored() {
        XCTAssertNil(profile(deathDate: "unknown").effectiveCareerEndYear)
        XCTAssertNil(profile(deathDate: "").effectiveCareerEndYear)
    }

    // MARK: - 🚨 P3 — and Impossible Data acts on it

    func testAVideoDatedAfterADeathIsReportedAsImpossible() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PD-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer {
            LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
            try? FileManager.default.removeItem(at: url)
        }
        let store = try LibraryStore(at: url)

        var vera = try store.newEntityProfile(named: "Vera Example", type: "actor")
        vera.careerStartYear = 2005
        vera.deathDate = "2018-04-02"
        try store.saveEntityProfile(vera)

        var asset = Asset(relativePath: "\(UUID()).mp4", fileName: "later.mp4",
                          tags: ["actor:Vera Example"])
        asset.releaseDate = "2021-06-01"
        try store.insertAsset(asset)

        let findings = try store.auditGraph().flatMap(\.findings)
        XCTAssertTrue(findings.contains { $0.performer == "Vera Example" },
                      "a release after a performer died is impossible, and was silent before")
    }

    /// ⭐ The control: a living performer's recent release is not a finding.
    func testALivingPerformersRecentReleaseIsNotAFinding() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PD2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer {
            LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
            try? FileManager.default.removeItem(at: url)
        }
        let store = try LibraryStore(at: url)

        var vera = try store.newEntityProfile(named: "Vera Example", type: "actor")
        vera.careerStartYear = 2005
        try store.saveEntityProfile(vera)

        var asset = Asset(relativePath: "\(UUID()).mp4", fileName: "recent.mp4",
                          tags: ["actor:Vera Example"])
        asset.releaseDate = "2024-06-01"
        try store.insertAsset(asset)

        XCTAssertTrue(try store.auditGraph().flatMap(\.findings).isEmpty)
    }

    // MARK: - P2 / P4 — a lookup fills gaps, it does not overwrite

    /// A source that says nothing about a field leaves it alone.
    func testASourceThatOmitsAFieldLeavesTheExistingValue() {
        let existing = profile(deathDate: "2018-04-02", sceneCount: 412)

        let merged = ActorEnrichment.apply(ActorMetadataProposal(), to: existing,
                                           entityId: existing.id,
                                           accepting: [ActorEnrichment.Field.deathDate,
                                                       ActorEnrichment.Field.sceneCount])

        XCTAssertEqual(merged.deathDate, "2018-04-02")
        XCTAssertEqual(merged.sceneCount, 412)
    }

    /// ⚠️ And a value the operator did not tick is not written, even when the
    /// source offers one.
    func testAnUntickedProposalIsNotApplied() {
        var proposal = ActorMetadataProposal()
        proposal.deathDate = .init("2020-01-01", sourceNote: "TheSource")
        proposal.sceneCount = .init(999, sourceNote: "TheSource")

        let merged = ActorEnrichment.apply(proposal, to: profile(deathDate: "2018-04-02"),
                                           entityId: "x", accepting: [])

        XCTAssertEqual(merged.deathDate, "2018-04-02", "the operator's value stands")
        XCTAssertNil(merged.sceneCount)
    }

    func testATickedProposalIsApplied() {
        var proposal = ActorMetadataProposal()
        proposal.sceneCount = .init(412, sourceNote: "TheSource")

        let merged = ActorEnrichment.apply(proposal, to: profile(), entityId: "x",
                                           accepting: [ActorEnrichment.Field.sceneCount])

        XCTAssertEqual(merged.sceneCount, 412)
    }

    // MARK: - D2 — the count is a snapshot

    /// ⚠️ `sceneCount` grows over time, so it is only meaningful beside the
    /// date it was read. It is paired with `enrichmentCheckedAt` — the same
    /// pattern `marksAsOf` uses — rather than presented as a current fact.
    func testTheCountIsOfferedForReviewSoItsAgeIsVisible() {
        var proposal = ActorMetadataProposal()
        proposal.sceneCount = .init(412, sourceNote: "TheSource")

        let review = ActorEnrichment.review(profile: profile(), proposal: proposal,
                                            sourceName: "TheSource")

        let row = review.changes.first { $0.id == ActorEnrichment.Field.sceneCount }
        XCTAssertNotNil(row, "shown as a reviewable row, with its source noted")
        XCTAssertEqual(row?.sourceNote, "TheSource")
    }

    // MARK: - 🚨 #58 — the derivation has to reach what the operator SEES

    // The defect these exist for: `effectiveCareerEndYear` was correct and only
    // `GraphAudit` consumed it. Every member the profile page renders still read
    // the raw `careerEndYear`, so the wrongness D5 describes was fixed where
    // nothing could see it and left intact everywhere it was displayed.
    //
    // ⚠️ Testing the derivation alone is what let that through. These test the
    // CONSUMERS.

    /// A performer who has died is not still working.
    func testADeceasedPerformerIsNotOngoing() {
        XCTAssertFalse(profile(deathDate: "2018-04-02").isCareerOngoing)
        XCTAssertTrue(profile().isCareerOngoing, "no death date, no recorded end — still open")
    }

    /// 🚨 The literal word the bug printed.
    func testTheCareerSpanDoesNotSayPresentForSomeoneWhoHasDied() {
        let shown = profile(deathDate: "2018-04-02").careerDisplay(asOf: date(2026))
        XCTAssertNotNil(shown)
        XCTAssertFalse(shown!.contains("present"), "still advertising them as active: \(shown!)")
        XCTAssertTrue(shown!.contains("2005-2018"), "span should close at the death year: \(shown!)")
    }

    /// ⚠️ Otherwise the number grows every January for someone who has died.
    func testYearsActiveStopsAtDeathRatherThanTheCurrentYear() {
        XCTAssertEqual(profile(deathDate: "2018-04-02").yearsActive(asOf: date(2026)), 13)
        XCTAssertEqual(profile().yearsActive(asOf: date(2026)), 21, "still active, still counting")
    }

    /// ⭐ P4, restated at the consumer level: a recorded end always wins, because
    /// someone may have retired years before they died and that is the truer end.
    func testARecordedEndStillOutranksTheDeathDateEverywhere() {
        let p = profile(deathDate: "2018-04-02", careerEnd: 2012)
        XCTAssertEqual(p.effectiveCareerEndYear, 2012)
        XCTAssertFalse(p.isCareerOngoing)
        XCTAssertEqual(p.yearsActive(asOf: date(2026)), 7)
        XCTAssertTrue(p.careerDisplay(asOf: date(2026))!.contains("2005-2012"))
    }

    /// An unparseable death date changes nothing — it must not silently close a
    /// career on a value nobody can read.
    func testAnUnreadableDeathDateLeavesTheCareerOpen() {
        for bad in ["unknown", "", "n/a"] {
            let p = profile(deathDate: bad)
            XCTAssertTrue(p.isCareerOngoing, "\(bad) should not end a career")
            XCTAssertTrue(p.careerDisplay(asOf: date(2026))!.contains("present"))
        }
    }

    private func date(_ year: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: 6, day: 1))!
    }
}
