import XCTest
@testable import LibraryCore

/// Actors that were IDENTIFIED without ever being fetched.
///
/// 🚨 Measured on the real library: 502 actors had their identity handed down
/// by a matched video's cast links, all marked `matched`, and 394 of them held
/// nothing else — no bio, no links, no photos, no career span. `Match All
/// Actors` skipped every one as "already matched", so the identity arrived, the
/// state said done, and the tool that would have filled the rest refused to
/// look.
///
/// ⚠️ The identity/enrichment separation shipped to PREVENT this, and does. It
/// could not repair a library already in the state, which is what this closes.
final class AwaitingEnrichmentTests: XCTestCase {

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

    @discardableResult
    private func actor(_ name: String, matched: Bool = true) throws -> EntityProfile {
        var p = EntityProfile(id: "actor:\(name)")
        if matched { p.enrichmentState = .matched }
        try store.saveEntityProfile(p)
        return p
    }

    // MARK: - Detection

    /// ⭐ `.linked` is precise, not a heuristic: any lookup through the actor
    /// path records `.name` over it, so a row still reading `.linked` has never
    /// been fetched.
    func testAnIdentityHandedDownByAVideoIsFlaggedForEnrichment() throws {
        try actor("Alice")
        try store.recordMatch(.init(nodeId: "actor:Alice", source: "A", sourceId: "p-1",
                                    method: .linked), isVideo: false)

        XCTAssertEqual(try store.entityIdsAwaitingEnrichment(), ["actor:Alice"])
    }

    /// An actor the matcher itself looked up is NOT awaiting anything.
    func testAnActorFetchedByTheMatcherIsNotFlagged() throws {
        try actor("Bob")
        try store.recordMatch(.init(nodeId: "actor:Bob", source: "A", sourceId: "p-2",
                                    method: .name), isVideo: false)

        XCTAssertTrue(try store.entityIdsAwaitingEnrichment().isEmpty)
    }

    /// ⚠️ Nor is a backfilled one — its id came from a column the old CSV run
    /// wrote, and that run DID fetch the record.
    func testABackfilledIdentityIsNotFlagged() throws {
        try actor("Carol")
        try store.recordMatch(.init(nodeId: "actor:Carol", source: "A", sourceId: "p-3",
                                    method: .backfill), isVideo: false)

        XCTAssertTrue(try store.entityIdsAwaitingEnrichment().isEmpty)
    }

    // MARK: - The skip rule

    /// 🚨 The defect itself: `matched` plus an unfetched identity was skipped.
    func testAMatchedActorAwaitingEnrichmentIsNoLongerSkipped() throws {
        let profile = try actor("Alice")

        XCTAssertEqual(ActorBatchPolicy.skipReason(for: profile), "already matched",
                       "unchanged when nothing says otherwise")
        XCTAssertNil(ActorBatchPolicy.skipReason(for: profile, identityNeedsEnrichment: true),
                     "an identity with no enrichment behind it must be examined")
    }

    /// ⚠️ The exception is narrow. It does not reopen decisions a PERSON made.
    func testTheExceptionDoesNotReopenOperatorDecisions() throws {
        var ruledOut = EntityProfile(id: "actor:Bob")
        ruledOut.enrichmentState = .unmatchable
        var waiting = EntityProfile(id: "actor:Carol")
        waiting.enrichmentState = .ambiguous

        XCTAssertEqual(ActorBatchPolicy.skipReason(for: ruledOut, identityNeedsEnrichment: true),
                       "you ruled this one out")
        XCTAssertEqual(ActorBatchPolicy.skipReason(for: waiting, identityNeedsEnrichment: true),
                       "waiting on your decision")
    }

    /// An unchecked actor was never skipped and still is not.
    func testAnUncheckedActorIsUnaffected() throws {
        let fresh = EntityProfile(id: "actor:Dana")

        XCTAssertNil(ActorBatchPolicy.skipReason(for: fresh))
        XCTAssertNil(ActorBatchPolicy.skipReason(for: fresh, identityNeedsEnrichment: true))
    }

    // MARK: - 🚨 It must not loop forever

    /// Once the matcher fetches them it records `.name`, which clears the flag.
    /// Without that these would be re-examined on every run, for ever.
    func testEnrichingThemClearsTheFlag() throws {
        try actor("Alice")
        try store.recordMatch(.init(nodeId: "actor:Alice", source: "A", sourceId: "p-1",
                                    method: .linked), isVideo: false)
        XCTAssertFalse(try store.entityIdsAwaitingEnrichment().isEmpty)

        // What the batch run does after a successful fetch.
        try store.recordMatch(.init(nodeId: "actor:Alice", source: "A", sourceId: "p-1",
                                    method: .name), isVideo: false)

        XCTAssertTrue(try store.entityIdsAwaitingEnrichment().isEmpty,
                      "otherwise every run re-fetches the same actors")
    }

    /// ⚠️ A DIFFERENT source recording `.linked` still counts. The actor is
    /// unfetched as far as that source goes, which is what matters.
    func testASecondSourcesLinkedIdentityStillCounts() throws {
        try actor("Alice")
        try store.recordMatch(.init(nodeId: "actor:Alice", source: "A", sourceId: "p-1",
                                    method: .name), isVideo: false)
        try store.recordMatch(.init(nodeId: "actor:Alice", source: "B", sourceId: "b-9",
                                    method: .linked), isVideo: false)

        XCTAssertEqual(try store.entityIdsAwaitingEnrichment(), ["actor:Alice"])
    }
}
