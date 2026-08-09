import XCTest
@testable import LibraryCore

/// A node's identity in an external source, as an edge.
///
/// 🚨 The Epic's D4 said "a match is an edge to an external identity, and must
/// be as durable as any other." It was four columns on the node, and every
/// identity defect found on 2026-08-07 traced back to that: 1,236 of 1,250
/// matched actors and 51 of 62 matched studios carried no source id, and none
/// could ever acquire one.
///
/// ⭐ The decisive property a column lacks: it can record that something is
/// MISSING. `matched` beside a null id is indistinguishable from never looked
/// up; no row is a fact you can query.
final class NodeMatchTests: XCTestCase {

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
    private func video(matched: Bool = false, sourceId: String? = nil) throws -> Asset {
        let name = "\(UUID().uuidString).mp4"
        let asset = Asset(relativePath: name, fileName: name,
                          enrichmentState: matched ? .matched : nil,
                          enrichmentSource: matched ? "A Source" : nil,
                          enrichmentSourceId: sourceId)
        try store.insertAsset(asset)
        return asset
    }

    @discardableResult
    private func actor(_ name: String, matched: Bool = false,
                       sourceId: String? = nil) throws -> EntityProfile {
        var p = EntityProfile(id: "actor:\(name)")
        if matched {
            p.enrichmentState = .matched
            p.enrichmentSource = "A Source"
        }
        p.enrichmentSourceId = sourceId
        try store.saveEntityProfile(p)
        return p
    }

    // MARK: - Several sources at once

    /// ⭐ The point of the primary key being (node, source). One node matched
    /// in two places is the supported case, not a conflict.
    func testANodeCanBeMatchedInSeveralSourcesAtOnce() throws {
        try actor("Alice")
        try store.recordMatch(.init(nodeId: "actor:Alice", source: "A", sourceId: "a-1",
                                    method: .operator), isVideo: false)
        try store.recordMatch(.init(nodeId: "actor:Alice", source: "B", sourceId: "b-9",
                                    method: .cast), isVideo: false)

        let found = try store.matches(forEntity: "actor:Alice")
        XCTAssertEqual(Set(found.map(\.source)), ["A", "B"])
        XCTAssertEqual(Set(found.map(\.sourceId)), ["a-1", "b-9"])
    }

    /// ⚠️ The same source twice is a CORRECTION, not a second identity.
    func testRematchingInTheSameSourceReplacesThatAnswer() throws {
        try actor("Alice")
        try store.recordMatch(.init(nodeId: "actor:Alice", source: "A", sourceId: "old",
                                    method: .title), isVideo: false)
        try store.recordMatch(.init(nodeId: "actor:Alice", source: "A", sourceId: "new",
                                    method: .operator), isVideo: false)

        let found = try store.matches(forEntity: "actor:Alice")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.sourceId, "new")
        XCTAssertEqual(found.first?.method, .operator)
    }

    func testForgettingOneSourceLeavesTheOthers() throws {
        try actor("Alice")
        try store.recordMatch(.init(nodeId: "actor:Alice", source: "A", sourceId: "a",
                                    method: .cast), isVideo: false)
        try store.recordMatch(.init(nodeId: "actor:Alice", source: "B", sourceId: "b",
                                    method: .cast), isVideo: false)

        try store.removeMatch(nodeId: "actor:Alice", source: "A", isVideo: false)

        XCTAssertEqual(try store.matches(forEntity: "actor:Alice").map(\.source), ["B"])
    }

    // MARK: - Which one to act on

    /// ⭐ Ranked by METHOD, not recency. A fingerprint from a year ago
    /// identifies a file better than a title guess made today — recency
    /// measures when someone last looked, not how well they saw.
    func testTheBestMatchPrefersAFingerprintOverAMoreRecentTitleGuess() {
        let old = NodeMatch(nodeId: "v", source: "A", sourceId: "1", method: .fingerprint,
                            matchedAt: Date(timeIntervalSince1970: 0))
        let recent = NodeMatch(nodeId: "v", source: "B", sourceId: "2", method: .title,
                               matchedAt: Date(timeIntervalSince1970: 1_000_000))

        XCTAssertEqual(NodeMatchRanking.best([recent, old])?.method, .fingerprint)
    }

    /// Recency breaks ties, so re-checking the same way does supersede.
    func testTheMoreRecentOfTwoEqualMethodsWins() {
        let older = NodeMatch(nodeId: "v", source: "A", sourceId: "1", method: .cast,
                              matchedAt: Date(timeIntervalSince1970: 0))
        let newer = NodeMatch(nodeId: "v", source: "B", sourceId: "2", method: .cast,
                              matchedAt: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(NodeMatchRanking.best([older, newer])?.sourceId, "2")
    }

    /// ⚠️ A backfilled row ranks above a title match but below everything a
    /// person or a fingerprint produced — its method is unknown, not absent.
    func testBackfillOutranksATitleGuessAndNothingElse() {
        XCTAssertGreaterThan(MatchMethod.backfill.trust, MatchMethod.title.trust)
        XCTAssertLessThan(MatchMethod.backfill.trust, MatchMethod.cast.trust)
    }

    // MARK: - 🚨 The 1,287

    /// The query a column could not answer.
    func testANodeMatchedWithNoEdgeIsFindable() throws {
        try actor("Ghost", matched: true)                  // no source id
        try actor("Known", matched: true, sourceId: "k-1")
        try store.backfillMatchEdges()

        let (entities, _) = try store.nodesMatchedWithoutAnEdge()

        XCTAssertEqual(entities, ["actor:Ghost"])
    }

    func testVideosMatchedWithoutAnEdgeAreReportedSeparately() throws {
        let ghost = try video(matched: true)
        try video(matched: true, sourceId: "v-1")
        try store.backfillMatchEdges()

        let (_, videos) = try store.nodesMatchedWithoutAnEdge()

        XCTAssertEqual(videos, [ghost.id])
    }

    // MARK: - Backfill

    /// ⚠️ Exactly one row per node WITH an id, and none for those without.
    /// Counted, not sampled.
    func testBackfillCreatesOneRowPerIdentifiedNodeAndNoneForTheRest() throws {
        try actor("A", matched: true, sourceId: "a-1")
        try actor("B", matched: true, sourceId: "b-2")
        try actor("C", matched: true)
        try video(matched: true, sourceId: "v-1")

        let counts = try store.backfillMatchEdges()

        XCTAssertEqual(counts.entities, 2)
        XCTAssertEqual(counts.videos, 1)
        XCTAssertTrue(try store.matches(forEntity: "actor:C").isEmpty)
    }

    /// ⚠️ `backfill`, never `operator` — the method was not recorded and
    /// claiming a person chose it would invent evidence.
    func testABackfilledRowSaysItsMethodIsUnknown() throws {
        try actor("A", matched: true, sourceId: "a-1")

        try store.backfillMatchEdges()

        XCTAssertEqual(try store.matches(forEntity: "actor:A").first?.method, .backfill)
    }

    func testBackfillIsIdempotent() throws {
        try actor("A", matched: true, sourceId: "a-1")

        try store.backfillMatchEdges()
        let second = try store.backfillMatchEdges()

        XCTAssertEqual(second.entities, 0)
        XCTAssertEqual(try store.matches(forEntity: "actor:A").count, 1)
    }

    /// A backfill must not overwrite a real match recorded since.
    func testBackfillDoesNotDisturbAnExistingEdge() throws {
        try actor("A", matched: true, sourceId: "stale-column")
        try store.recordMatch(.init(nodeId: "actor:A", source: "A Source",
                                    sourceId: "chosen", method: .operator), isVideo: false)

        try store.backfillMatchEdges()

        let found = try store.matches(forEntity: "actor:A")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.sourceId, "chosen")
        XCTAssertEqual(found.first?.method, .operator)
    }

    // MARK: - Durability

    /// 🚨 T5. A rename DELETES the old profile, and the cascade would take the
    /// match with it — the defect found on 2026-08-07, asserted here for a
    /// table added after that fix so it cannot recur on the new one.
    func testMergingTwoProfilesKeepsTheMatchEdge() throws {
        try actor("Venlowe")
        try actor("Marta Venlowe")
        try store.recordMatch(.init(nodeId: "actor:Venlowe", source: "A", sourceId: "h-1",
                                    method: .operator), isVideo: false)

        try store.renameTagGlobally(oldTag: "actor:Venlowe", newTag: "actor:Marta Venlowe")

        XCTAssertEqual(try store.matches(forEntity: "actor:Marta Venlowe").map(\.sourceId),
                       ["h-1"])
    }

    /// Deleting a node removes its matches — an edge to nothing is not a fact.
    func testDeletingANodeRemovesItsMatches() throws {
        let asset = try video(matched: true)
        try store.recordMatch(.init(nodeId: asset.id.uuidString, source: "A",
                                    sourceId: "v-1", method: .fingerprint), isVideo: true)

        try store.deleteAsset(asset)

        XCTAssertTrue(try store.matches(forVideo: asset.id).isEmpty)
    }
}

/// Writing the edge at MATCH time rather than only in a migration.
///
/// ⚠️ The single entry point exists because the two representations must not
/// drift: every call site that set `enrichmentSourceId` by hand was a site that
/// could forget the edge, and "forgot" is exactly how 1,287 nodes came to claim
/// they were matched with nothing to look up.
final class MatchAtWriteTimeTests: XCTestCase {

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

    func testConfirmingAnEntityWritesBothTheColumnsAndTheEdge() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Alice"))

        try store.confirmEntityMatch("actor:Alice", source: "A Source",
                                     sourceId: "a-1", method: .name)

        let profile = try XCTUnwrap(try store.fetchEntityProfile(for: "actor:Alice"))
        XCTAssertEqual(profile.enrichmentState, .matched)
        XCTAssertEqual(profile.enrichmentSourceId, "a-1")
        XCTAssertEqual(try store.matches(forEntity: "actor:Alice").first?.method, .name)
    }

    /// ⚠️ An id the library already holds is never replaced — the same rule
    /// `confirmStudio` follows, because replacing one silently re-points a
    /// confirmed match at something else.
    func testConfirmingDoesNotReplaceAnIdAlreadyHeld() throws {
        var p = EntityProfile(id: "actor:Alice")
        p.enrichmentSourceId = "original"
        try store.saveEntityProfile(p)

        try store.confirmEntityMatch("actor:Alice", source: "A Source",
                                     sourceId: "different", method: .name)

        XCTAssertEqual(try store.fetchEntityProfile(for: "actor:Alice")?.enrichmentSourceId,
                       "original")
    }

    /// 🚨 The regression this whole spec exists to prevent: a confirm that
    /// writes the column and not the edge.
    func testAConfirmedEntityNeverAppearsInTheMissingList() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Alice"))

        try store.confirmEntityMatch("actor:Alice", source: "A Source",
                                     sourceId: "a-1", method: .name)

        XCTAssertTrue(try store.nodesMatchedWithoutAnEdge().entities.isEmpty)
    }

    /// Confirming a studio — the path that runs as a side effect of matching a
    /// video, and the one that left 51 of 62 studios without an id.
    func testConfirmingAStudioWritesAMatchEdge() throws {
        try store.confirmStudio("Example Network", source: "A Source", sourceId: "s-1")

        XCTAssertEqual(try store.matches(forEntity: "studio:Example Network").first?.sourceId,
                       "s-1")
    }

    /// ⚠️ No id means no edge — the absence stays visible rather than being
    /// papered over with an empty row.
    func testConfirmingAStudioWithNoIdWritesNoEdge() throws {
        try store.confirmStudio("Example Network", source: "A Source")

        XCTAssertTrue(try store.matches(forEntity: "studio:Example Network").isEmpty)
        XCTAssertEqual(try store.nodesMatchedWithoutAnEdge().entities,
                       ["studio:Example Network"])
    }

    func testConfirmingAVideoWritesTheEdgeWithItsMethod() throws {
        let name = "\(UUID().uuidString).mp4"
        let asset = Asset(relativePath: name, fileName: name)
        try store.insertAsset(asset)

        try store.confirmVideoMatch(asset.id, source: "A Source",
                                    sourceId: "v-1", method: .fingerprint)

        XCTAssertEqual(try store.matches(forVideo: asset.id).first?.method, .fingerprint)
    }

    /// ⭐ An actor is matched by an exact name plus a disambiguation, which is
    /// neither a title guess nor a cast search — and ranks between them.
    func testAnExactNameMatchOutranksATitleGuessButNotAPersonsChoice() {
        XCTAssertGreaterThan(MatchMethod.name.trust, MatchMethod.cast.trust)
        XCTAssertLessThan(MatchMethod.name.trust, MatchMethod.operator.trust)
    }
}

// MARK: - 🚨 Both halves of "look this up again"

extension NodeMatchTests {

    /// Identity known, details missing — learned by propagation.
    func testANodeWithOnlyALinkedIdentityIsOfferedAgain() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Linked"))
        try store.recordMatch(
            NodeMatch(nodeId: "actor:Linked", source: "A Source",
                      sourceId: "x", method: .linked), isVideo: false)

        XCTAssertTrue(try store.entityIdsAwaitingEnrichment().contains("actor:Linked"))
    }

    /// 🚨 The mirror case: details fetched, identity never recorded.
    ///
    /// 151 actors on the drive library — fully enriched with photos and birth
    /// dates, matched before the app recorded WHICH record it matched. They
    /// have no edge at all, so a query looking for a `.linked` edge could not
    /// see them, and `Match All Actors` skipped every one as "already matched".
    func testAnEnrichedNodeWithNoIdentityIsAlsoOfferedAgain() throws {
        var profile = EntityProfile(id: "actor:Enriched")
        profile.enrichmentState = .matched
        profile.enrichmentSource = "A Source"
        profile.photoUrl = "https://example.com/p.jpg"
        try store.saveEntityProfile(profile)

        XCTAssertTrue(try store.entityIdsAwaitingEnrichment().contains("actor:Enriched"),
                      "enriched but unidentified must be offered, or it can only be fixed by hand")
    }

    /// ⚠️ And a node that is genuinely done is NOT offered. Without this the
    /// batch would re-look-up the whole library on every run.
    func testAFullyMatchedNodeIsNotOfferedAgain() throws {
        var profile = EntityProfile(id: "actor:Done")
        profile.enrichmentState = .matched
        try store.saveEntityProfile(profile)
        try store.recordMatch(
            NodeMatch(nodeId: "actor:Done", source: "A Source",
                      sourceId: "abc", method: .name), isVideo: false)

        XCTAssertFalse(try store.entityIdsAwaitingEnrichment().contains("actor:Done"))
    }
}

// MARK: - 🚨 The one entry point for a reviewed match

extension NodeMatchTests {

    /// Saves AND records the edge, which three separate screens each failed to
    /// do by hand — leaving records that satisfy every column-reading check and
    /// stay on the missing-identity worklist forever.
    func testApplyingAReviewedMatchWritesBothTheRowAndTheEdge() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Jane"))
        var profile = try XCTUnwrap(try store.fetchEntityProfile(for: "actor:Jane"))
        profile.enrichmentSourceId = "abc"
        profile.bio = "reviewed"

        let outcome = try store.applyReviewedMatch(profile, source: "A Source")

        XCTAssertEqual(outcome, .recorded)
        XCTAssertEqual(try store.fetchEntityProfile(for: "actor:Jane")?.bio, "reviewed")
        XCTAssertEqual(try store.allEntityMatches().first?.sourceId, "abc")
    }

    /// ⚠️ No id from the source means no edge is possible — reported rather
    /// than silently succeeding, so the screen can say why the row stays.
    func testAReviewedMatchWithNoSourceIdIsReportedNotSilent() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Jane"))
        let profile = try XCTUnwrap(try store.fetchEntityProfile(for: "actor:Jane"))

        XCTAssertEqual(try store.applyReviewedMatch(profile, source: "A Source"),
                       .noSourceId)
        XCTAssertTrue(try store.allEntityMatches().isEmpty)
    }

    /// 🚨 After a rename the edge must name the row that EXISTS. Attaching it to
    /// the pre-rename id points it at something that has just moved.
    func testAfterARenameTheEdgeNamesTheNewId() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Old"))
        var profile = try XCTUnwrap(try store.fetchEntityProfile(for: "actor:Old"))
        profile.enrichmentSourceId = "abc"
        try store.saveEntityProfile(profile)
        _ = try store.renameTagGlobally(oldTag: "actor:Old", newTag: "actor:New")

        let renamed = try XCTUnwrap(try store.fetchEntityProfile(for: "actor:New"))
        let outcome = try store.applyReviewedMatch(
            renamed, source: "A Source", recordingUnder: "actor:New")

        XCTAssertEqual(outcome, .recorded)
        XCTAssertEqual(try store.allEntityMatches().first?.nodeId, "actor:New")
    }
}
