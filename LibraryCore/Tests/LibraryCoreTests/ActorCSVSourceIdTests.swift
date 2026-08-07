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
