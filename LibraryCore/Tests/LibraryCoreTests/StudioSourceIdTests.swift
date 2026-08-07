import XCTest
@testable import LibraryCore

/// Recording the source's own id when a studio is confirmed.
///
/// 🚨 `confirmStudio` wrote state, source and a timestamp — and not the one
/// thing that makes a LATER lookup possible. The value was available the whole
/// time: the proposal carries `studioSourceId` and the review already resolves
/// it; it was dropped at the store boundary.
///
/// 🚨 Worse than a missing field, because `StudioBatchPolicy.skipReason` skips
/// anything already `.matched` — so the one tool that would have supplied the
/// id refused to look at those studios. The door closed behind them. Measured
/// on the real library: 51 of 62 matched studios had no id, and none of them
/// could ever get one.
final class StudioSourceIdTests: XCTestCase {

    private var directory: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        store = try LibraryStore(at: directory)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func profile(_ name: String) throws -> EntityProfile? {
        try store.fetchEntityProfile(for: "studio:\(name)")
    }

    // MARK: - Recording it

    func testConfirmingAStudioRecordsTheSourceId() throws {
        try store.confirmStudio("Example Network", source: "A Source", sourceId: "abc-123")

        XCTAssertEqual(try profile("Example Network")?.enrichmentSourceId, "abc-123")
        XCTAssertEqual(try profile("Example Network")?.enrichmentState, .matched)
    }

    /// A source that supplies no id still confirms the studio — the id is an
    /// improvement, not a precondition.
    func testAStudioIsStillConfirmedWithoutAnId() throws {
        try store.confirmStudio("Example Network", source: "A Source")

        XCTAssertEqual(try profile("Example Network")?.enrichmentState, .matched)
        XCTAssertNil(try profile("Example Network")?.enrichmentSourceId)
    }

    func testAnEmptyIdIsTreatedAsNoId() throws {
        try store.confirmStudio("Example Network", source: "A Source", sourceId: "")

        XCTAssertNil(try profile("Example Network")?.enrichmentSourceId)
    }

    // MARK: - 🚨 The closed door, reopened

    /// The specific repair: a studio matched WITHOUT an id may still learn one.
    /// Without this, every one of the 51 was permanently stranded.
    func testAnAlreadyMatchedStudioWithNoIdCanStillLearnOne() throws {
        try store.confirmStudio("Example Network", source: "A Source")
        XCTAssertNil(try profile("Example Network")?.enrichmentSourceId)

        try store.confirmStudio("Example Network", source: "A Source", sourceId: "abc-123")

        XCTAssertEqual(try profile("Example Network")?.enrichmentSourceId, "abc-123")
    }

    /// ⚠️ But never a DIFFERENT one. Replacing an id this library holds would
    /// silently re-point a confirmed match at another studio.
    func testAnExistingIdIsNeverReplaced() throws {
        try store.confirmStudio("Example Network", source: "A Source", sourceId: "abc-123")

        try store.confirmStudio("Example Network", source: "Another", sourceId: "xyz-789")

        XCTAssertEqual(try profile("Example Network")?.enrichmentSourceId, "abc-123")
    }

    /// Re-confirming must not disturb anything else about a settled studio.
    func testReconfirmingDoesNotRewriteTheRecordedSource() throws {
        try store.confirmStudio("Example Network", source: "A Source", sourceId: "abc-123")
        let before = try profile("Example Network")?.enrichmentCheckedAt

        try store.confirmStudio("Example Network", source: "Another Source")

        XCTAssertEqual(try profile("Example Network")?.enrichmentSource, "A Source")
        XCTAssertEqual(try profile("Example Network")?.enrichmentCheckedAt, before)
    }

    // MARK: - The parent carries its own id

    /// A network created as a side effect of matching an imprint gets an id
    /// too — it is confirmed by the same run, and skipped by the same rule.
    func testTheParentDispositionCarriesTheParentsSourceId() {
        var proposal = StudioMetadataProposal()
        proposal.parentName = .init("Example Network")
        proposal.parentSourceId = .init("parent-42")

        let disposition = StudioBatchPolicy.parentDisposition(existing: nil, proposal: proposal)

        guard case let .recorded(name, sourceId) = disposition else {
            return XCTFail("expected the parent to be recorded, got \(disposition)")
        }
        XCTAssertEqual(name, "Example Network")
        XCTAssertEqual(sourceId, "parent-42")
    }

    /// A source naming a network but no id still records the network.
    func testAParentWithNoIdIsStillRecorded() {
        var proposal = StudioMetadataProposal()
        proposal.parentName = .init("Example Network")

        guard case let .recorded(_, sourceId) = StudioBatchPolicy.parentDisposition(
            existing: nil, proposal: proposal) else {
            return XCTFail("expected the parent to be recorded")
        }
        XCTAssertNil(sourceId)
    }
}
