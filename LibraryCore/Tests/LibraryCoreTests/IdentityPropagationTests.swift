import XCTest
@testable import LibraryCore

/// A matched video identifying its own cast.
///
/// 🚨 The operator's question: *"if I match a video and the video has confirmed
/// performers within the source's own graph, why do I have to independently
/// match the new or renamed performers?"* You should not — and the reason you
/// did is that the client asked for `performer { name }` and not
/// `performer { id }`, so the identity was never even requested.
///
/// That is most of why 1,236 of 1,250 matched actors carried no identifier:
/// every one of them had been named by a matched video whose source record
/// linked straight to their confirmed profile.
final class IdentityPropagationTests: XCTestCase {

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

    private func actor(_ name: String) throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:\(name)"))
    }

    private let cast = [ProposedCredit(name: "Alice", sourceId: "p-1"),
                        ProposedCredit(name: "Bob", sourceId: "p-2")]

    // MARK: - The point

    func testAFingerprintMatchIdentifiesItsWholeCast() throws {
        try actor("Alice"); try actor("Bob")

        let written = try store.propagateIdentities(cast, source: "A Source",
                                                    videoMethod: .fingerprint)

        XCTAssertEqual(written, 2)
        XCTAssertEqual(try store.matches(forEntity: "actor:Alice").first?.sourceId, "p-1")
        XCTAssertEqual(try store.matches(forEntity: "actor:Bob").first?.sourceId, "p-2")
    }

    /// ⭐ `linked`, not `name` — no matching happened here at all. The source
    /// asserted the relationship in its own record.
    func testThePropagatedMethodSaysTheSourceLinkedThem() throws {
        try actor("Alice")

        try store.propagateIdentities(cast, source: "A Source", videoMethod: .operator)

        XCTAssertEqual(try store.matches(forEntity: "actor:Alice").first?.method, .linked)
    }

    /// The performer gains a usable identity — and stays on the enrichment
    /// worklist, because nothing has fetched their bio or photos yet.
    ///
    /// ⚠️ This test originally asserted `enrichmentState == .matched`, which
    /// was wrong: `skipReason` skips that state, so the actor matcher would
    /// have passed over every performer a video identified, leaving them
    /// permanently without details. Identity and enrichment are different
    /// questions — see `IdentityIsNotEnrichmentTests`.
    func testAnIdentifiedPerformerGainsAUsableIdentity() throws {
        try actor("Alice"); try actor("Bob")

        try store.propagateIdentities(cast, source: "A Source", videoMethod: .fingerprint)

        let profile = try XCTUnwrap(try store.fetchEntityProfile(for: "actor:Alice"))
        XCTAssertEqual(profile.enrichmentSourceId, "p-1",
                       "the next lookup is a fetch, not a search")
        XCTAssertNil(profile.enrichmentState, "no lookup has run for the ACTOR")
        XCTAssertFalse(try store.matches(forEntity: "actor:Alice").isEmpty)
    }

    // MARK: - 🚨 Only from a strong match

    /// A title match is "plausible, not identified". Treating its cast links as
    /// confirmed would launder ONE guess into a dozen confidently wrong
    /// identities — across actors who then look verified and get skipped by
    /// every later tool.
    func testATitleMatchNeverHandsDownIdentities() throws {
        try actor("Alice"); try actor("Bob")

        let written = try store.propagateIdentities(cast, source: "A Source",
                                                    videoMethod: .title)

        XCTAssertEqual(written, 0)
        XCTAssertTrue(try store.matches(forEntity: "actor:Alice").isEmpty)
    }

    func testACastMatchAlsoDoesNotPropagate() throws {
        try actor("Alice")

        XCTAssertEqual(try store.propagateIdentities(cast, source: "A Source",
                                                     videoMethod: .cast), 0)
    }

    func testOnlyFingerprintAndOperatorPropagate() {
        XCTAssertTrue(MatchMethod.fingerprint.propagatesIdentity)
        XCTAssertTrue(MatchMethod.operator.propagatesIdentity)
        for weak in [MatchMethod.title, .cast, .backfill, .name, .linked] {
            XCTAssertFalse(weak.propagatesIdentity, "\(weak) must not propagate")
        }
    }

    // MARK: - Never overrules

    /// ⚠️ A performer already identified in this source keeps their answer.
    func testAnExistingIdentityIsNeverReplaced() throws {
        try actor("Alice")
        try store.recordMatch(.init(nodeId: "actor:Alice", source: "A Source",
                                    sourceId: "chosen-by-hand", method: .operator),
                              isVideo: false)

        try store.propagateIdentities(cast, source: "A Source", videoMethod: .fingerprint)

        let found = try store.matches(forEntity: "actor:Alice")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.sourceId, "chosen-by-hand")
        XCTAssertEqual(found.first?.method, .operator)
    }

    /// A performer with no profile is skipped rather than conjured — the same
    /// rule every other edge follows.
    func testAPerformerWithNoProfileIsSkipped() throws {
        let written = try store.propagateIdentities(cast, source: "A Source",
                                                    videoMethod: .fingerprint)

        XCTAssertEqual(written, 0)
    }

    /// A source that supplied no id for a performer contributes nothing.
    func testACreditWithNoSourceIdIsSkipped() throws {
        try actor("Carol")

        let written = try store.propagateIdentities([ProposedCredit(name: "Carol")],
                                                    source: "A Source",
                                                    videoMethod: .fingerprint)

        XCTAssertEqual(written, 0)
        XCTAssertTrue(try store.matches(forEntity: "actor:Carol").isEmpty)
    }
}

/// Recovering identities from videos matched BEFORE the app asked for them.
///
/// 🚨 The operator's situation: a full match run completed before the client
/// requested performer ids. Every video is now `.matched`, so `Match All
/// Videos` skips them forever, and `Match Again` — re-reading every file from
/// disk and re-opening every settled ambiguity — is a disproportionate price
/// for data the source hands over on one lookup.
final class SettledMatchIdentityTests: XCTestCase {

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

    private func actor(_ name: String) throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:\(name)"))
    }

    /// ⭐ The point: no re-match required.
    func testASettledMatchStillIdentifiesItsCast() throws {
        try actor("Alice")

        let written = try store.propagateIdentitiesFromSettledMatch(
            [ProposedCredit(name: "Alice", sourceId: "p-1")], source: "A Source")

        XCTAssertEqual(written, 1)
        XCTAssertEqual(try store.matches(forEntity: "actor:Alice").first?.sourceId, "p-1")
        XCTAssertEqual(try store.matches(forEntity: "actor:Alice").first?.method, .linked)
    }

    /// ⚠️ Still never overrules an identity the library holds.
    func testItDoesNotReplaceAnIdentityAlreadyHeld() throws {
        try actor("Alice")
        try store.recordMatch(.init(nodeId: "actor:Alice", source: "A Source",
                                    sourceId: "chosen", method: .operator), isVideo: false)

        let written = try store.propagateIdentitiesFromSettledMatch(
            [ProposedCredit(name: "Alice", sourceId: "p-1")], source: "A Source")

        XCTAssertEqual(written, 0)
        XCTAssertEqual(try store.matches(forEntity: "actor:Alice").first?.sourceId, "chosen")
    }

    func testAPerformerWithNoProfileIsStillSkipped() throws {
        XCTAssertEqual(try store.propagateIdentitiesFromSettledMatch(
            [ProposedCredit(name: "Ghost", sourceId: "p-9")], source: "A Source"), 0)
    }

    /// ⚠️ The strict LIVE rule is untouched — this is a separate entry point,
    /// not a relaxation of `propagatesIdentity`, so a title match in front of a
    /// person still hands nothing down.
    func testTheLiveRuleIsUnchanged() throws {
        try actor("Alice")

        XCTAssertEqual(try store.propagateIdentities(
            [ProposedCredit(name: "Alice", sourceId: "p-1")],
            source: "A Source", videoMethod: .title), 0)
        XCTAssertFalse(MatchMethod.title.propagatesIdentity)
        XCTAssertFalse(MatchMethod.backfill.propagatesIdentity)
    }
}

/// 🚨 Identity is not enrichment.
///
/// The operator's expectation: a video match hands down the performer's unique
/// id, so the bulk actor match can fetch them directly with no disambiguation.
/// Correct — but the first implementation broke the second half of it.
///
/// `confirmEntityMatch` sets `enrichmentState = .matched`, which means "a
/// lookup ran and concluded", and `ActorBatchPolicy.skipReason` skips anything
/// in that state. So a performer identified by a video would have been SKIPPED
/// by Match All Actors: identified, and permanently without a bio, photos,
/// birth date or career span.
final class IdentityIsNotEnrichmentTests: XCTestCase {

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

    private func actor(_ name: String) throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:\(name)"))
    }

    /// ⭐ The identity lands, and the actor stays on the enrichment worklist.
    func testAPropagatedIdentityDoesNotMarkThePerformerEnriched() throws {
        try actor("Alice")

        try store.propagateIdentities([ProposedCredit(name: "Alice", sourceId: "p-1")],
                                      source: "A Source", videoMethod: .fingerprint)

        let profile = try XCTUnwrap(try store.fetchEntityProfile(for: "actor:Alice"))
        XCTAssertEqual(profile.enrichmentSourceId, "p-1", "the identity is recorded")
        XCTAssertNil(profile.enrichmentState,
                     "but no lookup has run, so nothing may claim one did")
        XCTAssertNil(ActorBatchPolicy.skipReason(for: profile),
                     "so the actor matcher still processes them")
    }

    /// The same for the settled-match recovery path.
    func testRecoveredIdentitiesAlsoLeaveTheStateAlone() throws {
        try actor("Alice")

        try store.propagateIdentitiesFromSettledMatch(
            [ProposedCredit(name: "Alice", sourceId: "p-1")], source: "A Source")

        let profile = try XCTUnwrap(try store.fetchEntityProfile(for: "actor:Alice"))
        XCTAssertEqual(profile.enrichmentSourceId, "p-1")
        XCTAssertNil(profile.enrichmentState)
    }

    /// The match edge is still written — the identity is a real graph fact.
    func testTheIdentityEdgeIsStillRecorded() throws {
        try actor("Alice")

        try store.propagateIdentities([ProposedCredit(name: "Alice", sourceId: "p-1")],
                                      source: "A Source", videoMethod: .fingerprint)

        XCTAssertEqual(try store.matches(forEntity: "actor:Alice").first?.method, .linked)
    }

    /// ⚠️ A performer the operator has genuinely matched keeps that state — the
    /// identity path must not downgrade a real enrichment.
    func testAnAlreadyEnrichedPerformerKeepsTheirState() throws {
        var p = EntityProfile(id: "actor:Alice")
        p.enrichmentState = .matched
        p.enrichmentSourceId = "chosen"
        try store.saveEntityProfile(p)

        try store.propagateIdentities([ProposedCredit(name: "Alice", sourceId: "p-1")],
                                      source: "A Source", videoMethod: .fingerprint)

        let profile = try XCTUnwrap(try store.fetchEntityProfile(for: "actor:Alice"))
        XCTAssertEqual(profile.enrichmentState, .matched)
        XCTAssertEqual(profile.enrichmentSourceId, "chosen")
    }

    /// A studio confirmed BY a video match is different: that IS a conclusion
    /// about the studio, so it keeps setting the state.
    func testConfirmingAStudioStillMarksItMatched() throws {
        try store.confirmStudio("Example Network", source: "A Source", sourceId: "s-1")

        XCTAssertEqual(try store.fetchEntityProfile(for: "studio:Example Network")?
                        .enrichmentState, .matched)
    }
}
