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

    /// The performer becomes properly matched, so no later tool asks again.
    func testAnIdentifiedPerformerIsNoLongerMissingAnEdge() throws {
        try actor("Alice"); try actor("Bob")

        try store.propagateIdentities(cast, source: "A Source", videoMethod: .fingerprint)

        XCTAssertTrue(try store.nodesMatchedWithoutAnEdge().entities.isEmpty)
        XCTAssertEqual(try store.fetchEntityProfile(for: "actor:Alice")?.enrichmentState,
                       .matched)
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
