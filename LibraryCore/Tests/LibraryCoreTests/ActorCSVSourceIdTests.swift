import XCTest
@testable import LibraryCore

/// The source's own id, across the CSV round trip.
///
/// 🚨 The format carried the enrichment state, the source name and a timestamp
/// and NOT the identifier — so every actor enriched through the batch path came
/// back marked "matched by X" with no way to ask X about them again. Measured
/// on the real library: 1,236 of 1,250 matched actors carry no id.
///
/// ⚠️ Worse than absent, because `ActorBatchPolicy.skipReason` skips anything
/// already `.matched`: the tool that would have supplied the id refuses to look
/// at them. Nothing decays here — the door closes.
final class ActorCSVSourceIdTests: XCTestCase {

    func testTheStampRecordsTheSourceId() {
        let out = ActorCSV.settingEnrichment(in: ["Jane Doe"], state: .matched,
                                             source: "A Source", checkedAt: Date(),
                                             sourceId: "abc-123")

        XCTAssertEqual(out[ActorCSV.EnrichmentColumn.sourceId], "abc-123")
        XCTAssertEqual(out[ActorCSV.EnrichmentColumn.state], "matched")
    }

    /// ⚠️ Never cleared. A later run reaching no conclusion about identity must
    /// not erase an id an earlier one established.
    func testAStampWithoutAnIdLeavesAnExistingOneAlone() {
        let first = ActorCSV.settingEnrichment(in: ["Jane Doe"], state: .matched,
                                               source: "A Source", checkedAt: Date(),
                                               sourceId: "abc-123")

        let second = ActorCSV.settingEnrichment(in: first, state: .noMatch,
                                                source: "A Source", checkedAt: Date())

        XCTAssertEqual(second[ActorCSV.EnrichmentColumn.sourceId], "abc-123")
    }

    func testTheIdSurvivesAFullRowRoundTrip() throws {
        var profile = EntityProfile(id: "actor:Jane Doe")
        profile.enrichmentState = .matched
        profile.enrichmentSource = "A Source"
        profile.enrichmentSourceId = "abc-123"

        let text = ActorCSV.row(name: "Jane Doe", profile: profile, stripCountry: { $0 })
        let columns = try XCTUnwrap(ActorCSV.parse(text).first)
        let back = try XCTUnwrap(ActorCSV.merge(columns: columns, existing: nil,
                                                decorateCountry: { $0 }))

        XCTAssertEqual(back.enrichmentSourceId, "abc-123")
    }

    /// A file written before this column existed must still import — and must
    /// not blank an id the library already holds.
    func testAnOlderRowDoesNotClearAnIdTheLibraryHolds() throws {
        var existing = EntityProfile(id: "actor:Jane Doe")
        existing.enrichmentSourceId = "abc-123"
        var short = Array(repeating: "", count: 19)
        short[0] = "Jane Doe"

        let merged = try XCTUnwrap(ActorCSV.merge(columns: short, existing: existing,
                                                  decorateCountry: { $0 }))

        XCTAssertEqual(merged.enrichmentSourceId, "abc-123")
    }
}

/// External reference links across the CSV round trip.
///
/// 🚨 `ActorCSV.merge` omitted `links` from the `EntityProfile` initializer, so
/// it defaulted to `[]` — importing a CSV over an existing profile DESTROYED
/// every external reference the library held. The batch enrichment path
/// round-trips through this format on every run.
///
/// Issue #29 warned about exactly this class of defect, listing four
/// "field-by-field reconstruction sites" to check. `ActorCSV` was a fifth.
final class ActorCSVLinkPreservationTests: XCTestCase {

    private func profile(links: [EntityLink]) -> EntityProfile {
        var p = EntityProfile(id: "actor:Jane Doe")
        p.links = links
        return p
    }

    func testLinksSurviveARoundTrip() throws {
        let held = profile(links: [EntityLink(url: "https://example.com/jane", label: "A Directory")])

        let text = ActorCSV.row(name: "Jane Doe", profile: held, stripCountry: { $0 })
        let columns = try XCTUnwrap(ActorCSV.parse(text).first)
        let back = try XCTUnwrap(ActorCSV.merge(columns: columns, existing: held,
                                                decorateCountry: { $0 }))

        XCTAssertEqual(back.links, held.links)
    }

    /// ⚠️ The format does not represent links at all, so "carried over" is the
    /// only correct behaviour — the same rule `galleryUrls` already follows.
    func testAnImportOverAProfileWithLinksKeepsThem() throws {
        let held = profile(links: [EntityLink(url: "https://example.com/a", label: "A Directory"),
                                   EntityLink(url: "https://example.com/b", label: "An Encyclopedia")])
        var columns = Array(repeating: "", count: 20)
        columns[0] = "Jane Doe"
        columns[1] = "a new bio from the file"

        let merged = try XCTUnwrap(ActorCSV.merge(columns: columns, existing: held,
                                                  decorateCountry: { $0 }))

        XCTAssertEqual(merged.links.count, 2, "the file said nothing about links")
        XCTAssertEqual(merged.bio, "a new bio from the file")
    }

    /// A profile that never had links still has none.
    func testAProfileWithNoLinksGainsNone() throws {
        var columns = Array(repeating: "", count: 20)
        columns[0] = "Jane Doe"

        let merged = try XCTUnwrap(ActorCSV.merge(columns: columns, existing: nil,
                                                  decorateCountry: { $0 }))

        XCTAssertTrue(merged.links.isEmpty)
    }
}
