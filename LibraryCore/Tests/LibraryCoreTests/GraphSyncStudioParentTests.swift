import XCTest
@testable import LibraryCore

/// What a sync may do to the studio hierarchy.
///
/// 🚨 The merge's one rule is that it is **additive** — it fills gaps and never
/// overrules a decision the receiving library made. The studio-parent branch
/// broke that rule: an imprint this library had placed under one network was
/// silently re-parented to the sender's.
///
/// ⚠️ The defect predates the temporal migration; the old write was an
/// `ON CONFLICT DO UPDATE` and overwrote just as quietly. v30 made it worse
/// rather than causing it — the overruled parent is now demoted into dated
/// history, so a sync leaves a trail indistinguishable from a real acquisition.
final class GraphSyncStudioParentTests: XCTestCase {

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
    private func studio(_ name: String) throws -> String {
        let id = "studio:\(name)"
        try store.saveEntityProfile(EntityProfile(id: id))
        return id
    }

    /// An export carrying only a studio hierarchy, undated — what an
    /// un-upgraded library sends.
    private func export(_ pairs: [(String, String)]) -> ActorLibraryExport {
        dated(pairs.map { ($0.0, $0.1, nil, nil) })
    }

    /// An export carrying dated ownership periods.
    private func dated(_ periods: [(String, String, String?, String?)]) -> ActorLibraryExport {
        var e = ActorLibraryExport(formatVersion: ActorLibraryExport.currentFormatVersion,
                                   exportedAt: Date(), profiles: [], photos: [])
        e.studioParents = periods.map {
            StudioParentEdge(from: "studio:\($0.0)", to: "studio:\($0.1)",
                             validFrom: $0.2, validTo: $0.3)
        }
        return e
    }

    // MARK: - 🚨 The rule that was broken

    func testASyncNeverReparentsAStudioThisLibraryHasAlreadyPlaced() throws {
        let imprint = try studio("Coast Line")
        let mine = try studio("Old Network")
        _ = try studio("Example Network")
        try store.setStudioParent(mine, forStudio: imprint)

        let result = try store.applyGraphMerge(export([("Coast Line", "Example Network")]))

        XCTAssertEqual(try store.parentStudioId(of: imprint), mine,
                       "my answer stands")
        XCTAssertEqual(result.newStudioParents, 0)
        XCTAssertEqual(result.disagreements.count, 1)
        XCTAssertEqual(result.disagreements.first?.subject, .studioParent)
    }

    /// ⚠️ And it leaves no history either. A demoted period would read as a
    /// real acquisition on the studio's profile page.
    func testAnOverruledParentLeavesNoFalseHistory() throws {
        let imprint = try studio("Coast Line")
        let mine = try studio("Old Network")
        _ = try studio("Example Network")
        try store.setStudioParent(mine, forStudio: imprint)

        _ = try store.applyGraphMerge(export([("Coast Line", "Example Network")]))

        XCTAssertEqual(try store.studioParentHistory(of: imprint).count, 1,
                       "one period, not a fabricated succession")
    }

    /// The disagreement names both sides, so the operator can settle it.
    func testTheDisagreementCarriesBothAnswers() throws {
        let imprint = try studio("Coast Line")
        let mine = try studio("Old Network")
        _ = try studio("Example Network")
        try store.setStudioParent(mine, forStudio: imprint)

        let d = try XCTUnwrap(try store.applyGraphMerge(
            export([("Coast Line", "Example Network")])).disagreements.first)

        XCTAssertEqual(d.name, imprint)
        XCTAssertEqual(d.mine, mine)
        XCTAssertEqual(d.theirs, "studio:Example Network")
    }

    // MARK: - What it still does

    /// Genuinely additive: a gap gets filled.
    func testAStudioWithNoParentHereAcceptsTheSendersHierarchy() throws {
        let imprint = try studio("Coast Line")
        let network = try studio("Example Network")

        let result = try store.applyGraphMerge(export([("Coast Line", "Example Network")]))

        XCTAssertEqual(try store.parentStudioId(of: imprint), network)
        XCTAssertEqual(result.newStudioParents, 1)
        XCTAssertTrue(result.disagreements.isEmpty)
    }

    /// Agreement is not a conflict, and not a second write.
    func testAgreeingOnTheParentIsSilent() throws {
        let imprint = try studio("Coast Line")
        let network = try studio("Example Network")
        try store.setStudioParent(network, forStudio: imprint)

        let result = try store.applyGraphMerge(export([("Coast Line", "Example Network")]))

        XCTAssertEqual(result.newStudioParents, 0)
        XCTAssertTrue(result.disagreements.isEmpty)
        XCTAssertEqual(try store.studioParentHistory(of: imprint).count, 1)
    }

    /// An edge naming a studio this library has never heard of is skipped
    /// rather than conjuring the node.
    func testAnEdgeNamingAnUnknownStudioIsSkipped() throws {
        _ = try studio("Coast Line")

        let result = try store.applyGraphMerge(export([("Coast Line", "Never Heard Of")]))

        XCTAssertEqual(result.newStudioParents, 0)
        XCTAssertTrue(result.disagreements.isEmpty, "absence is not disagreement")
    }

    // MARK: - D4 — the dates travel

    /// 🚨 The gap this closes. `GraphEdgePair` carried two ids and nothing else,
    /// so a hand-recorded acquisition date could never leave the library that
    /// recorded it. D4's first rule — *"receiver has the same parent, no dates;
    /// sender has dates → accept the dates"* — was unimplementable.
    func testAnAgreedParentGainsTheSendersStartDate() throws {
        let imprint = try studio("Coast Line")
        let network = try studio("Example Network")
        try store.setStudioParent(network, forStudio: imprint)   // undated

        let result = try store.applyGraphMerge(
            dated([("Coast Line", "Example Network", "2015-06-01", nil)]))

        XCTAssertEqual(try store.studioParentHistory(of: imprint).first?.from, "2015-06-01")
        XCTAssertEqual(result.datedStudioParents, 1)
        XCTAssertEqual(result.newStudioParents, 0, "no new ownership was learned")
        XCTAssertTrue(result.disagreements.isEmpty)
    }

    /// A date this library holds is an answer, not a gap.
    func testASenderNeverRewritesAStartDateWeAlreadyHold() throws {
        let imprint = try studio("Coast Line")
        let network = try studio("Example Network")
        try store.setStudioParent(network, forStudio: imprint, since: "2015-06-01")

        let result = try store.applyGraphMerge(
            dated([("Coast Line", "Example Network", "2011-01-01", nil)]))

        XCTAssertEqual(try store.studioParentHistory(of: imprint).first?.from, "2015-06-01")
        XCTAssertEqual(result.datedStudioParents, 0)
        XCTAssertEqual(result.disagreements.first?.subject, .studioParentDate,
                       "same network, two acquisition dates — reported, not resolved")
    }

    /// ⚠️ An un-upgraded sender means UNKNOWN, never "always". Its undated edge
    /// must not stamp a date onto a period this library dated.
    func testAnUndatedSenderDoesNotEraseADateWeHold() throws {
        let imprint = try studio("Coast Line")
        let network = try studio("Example Network")
        try store.setStudioParent(network, forStudio: imprint, since: "2015-06-01")

        let result = try store.applyGraphMerge(export([("Coast Line", "Example Network")]))

        XCTAssertEqual(try store.studioParentHistory(of: imprint).first?.from, "2015-06-01")
        XCTAssertTrue(result.disagreements.isEmpty, "silence is not disagreement")
    }

    /// A gap filled from scratch takes the date with it.
    func testANewlyLearnedParentArrivesWithItsStartDate() throws {
        let imprint = try studio("Coast Line")
        _ = try studio("Example Network")

        let result = try store.applyGraphMerge(
            dated([("Coast Line", "Example Network", "2015-06-01", nil)]))

        XCTAssertEqual(try store.studioParentHistory(of: imprint).first?.from, "2015-06-01")
        XCTAssertEqual(result.newStudioParents, 1)
    }

    // MARK: - D4 — former ownerships travel

    /// ⭐ The scarcest fact in the graph. Nothing supplies acquisition dates
    /// automatically, so a recorded succession exists only because the operator
    /// typed it — and before this it could never reach the other library.
    func testAFormerOwnershipTheSenderKnowsAboutIsLearned() throws {
        let imprint = try studio("Coast Line")
        let network = try studio("Example Network")
        _ = try studio("Old Network")
        try store.setStudioParent(network, forStudio: imprint, since: "2015-06-01")

        let result = try store.applyGraphMerge(dated([
            ("Coast Line", "Old Network", "2009-01-01", "2015-06-01"),
            ("Coast Line", "Example Network", "2015-06-01", nil),
        ]))

        XCTAssertEqual(result.newStudioParentPeriods, 1)
        XCTAssertEqual(try store.studioParentHistory(of: imprint).count, 2)
        XCTAssertEqual(try store.studioParentPairs(asOf: "2012-01-01").first?.to,
                       "studio:Old Network", "a 2012 release resolves to the former owner")
    }

    /// 🚨 The invariant the whole temporal shape exists to hold. Two ownerships
    /// covering the same day would make an as-of query return two parents.
    func testAnOverlappingFormerOwnershipIsReportedAndNotWritten() throws {
        let imprint = try studio("Coast Line")
        let network = try studio("Example Network")
        _ = try studio("Old Network")
        _ = try studio("Third Network")
        try store.setStudioParent(network, forStudio: imprint, since: "2015-06-01")
        try store.addStudioParentPeriod("studio:Old Network", forStudio: imprint,
                                        from: "2009-01-01", to: "2015-06-01")

        let result = try store.applyGraphMerge(dated([
            ("Coast Line", "Third Network", "2010-01-01", "2013-01-01"),
        ]))

        XCTAssertEqual(result.newStudioParentPeriods, 0)
        XCTAssertEqual(result.disagreements.first?.subject, .studioParentDate)
        XCTAssertEqual(try store.studioParentHistory(of: imprint).count, 2)
        XCTAssertEqual(try store.studioParentPairs(asOf: "2012-01-01").count, 1,
                       "still exactly one parent on any given day")
    }

    /// ⚠️ The migrated case, and the common one: every row v30 created has a nil
    /// start, which reaches back forever. An arriving history must not slot in
    /// underneath it as though the open period began yesterday.
    func testAFormerOwnershipIsRefusedAgainstAnUndatedOpenPeriod() throws {
        let imprint = try studio("Coast Line")
        let network = try studio("Example Network")
        _ = try studio("Old Network")
        try store.setStudioParent(network, forStudio: imprint)   // valid_from NULL

        let result = try store.applyGraphMerge(dated([
            ("Coast Line", "Old Network", "2009-01-01", "2015-06-01"),
        ]))

        XCTAssertEqual(result.newStudioParentPeriods, 0)
        XCTAssertEqual(result.disagreements.first?.subject, .studioParentDate)
    }

    /// ⭐ …but the same export carrying BOTH periods works, because the open
    /// row is dated first and stops reaching back. Order matters, and this is
    /// the assertion that proves it.
    func testDatingTheOpenPeriodFirstMakesRoomForTheHistory() throws {
        let imprint = try studio("Coast Line")
        let network = try studio("Example Network")
        _ = try studio("Old Network")
        try store.setStudioParent(network, forStudio: imprint)   // valid_from NULL

        let result = try store.applyGraphMerge(dated([
            ("Coast Line", "Old Network", "2009-01-01", "2015-06-01"),
            ("Coast Line", "Example Network", "2015-06-01", nil),
        ]))

        XCTAssertEqual(result.datedStudioParents, 1)
        XCTAssertEqual(result.newStudioParentPeriods, 1)
        XCTAssertTrue(result.disagreements.isEmpty)
        XCTAssertEqual(try store.studioParentHistory(of: imprint).count, 2)
    }

    /// A handover is not an overlap: one period ends the day the next begins.
    func testPeriodsMeetingAtABoundaryDoNotOverlap() {
        XCTAssertFalse(LibraryStore.periodsOverlap(("2009-01-01", "2015-06-01"),
                                                   ("2015-06-01", nil)))
        XCTAssertTrue(LibraryStore.periodsOverlap(("2009-01-01", "2015-06-02"),
                                                  ("2015-06-01", nil)))
        XCTAssertTrue(LibraryStore.periodsOverlap((nil, nil), ("2015-06-01", "2016-01-01")),
                      "a nil start reaches back forever")
    }

    /// Re-running a dated sync must change nothing the second time.
    func testADatedMergeIsIdempotent() throws {
        let imprint = try studio("Coast Line")
        _ = try studio("Example Network")
        _ = try studio("Old Network")
        let incoming = dated([
            ("Coast Line", "Old Network", "2009-01-01", "2015-06-01"),
            ("Coast Line", "Example Network", "2015-06-01", nil),
        ])

        _ = try store.applyGraphMerge(incoming)
        let second = try store.applyGraphMerge(incoming)

        XCTAssertEqual(second.newStudioParents, 0)
        XCTAssertEqual(second.datedStudioParents, 0)
        XCTAssertEqual(second.newStudioParentPeriods, 0)
        XCTAssertTrue(second.disagreements.isEmpty)
        XCTAssertEqual(try store.studioParentHistory(of: imprint).count, 2)
    }

    /// The dates survive a round trip through the export format.
    func testDatesSurviveEncodingAndDecoding() throws {
        let imprint = try studio("Coast Line")
        _ = try studio("Example Network")
        _ = try studio("Old Network")
        try store.setStudioParent("studio:Example Network", forStudio: imprint,
                                  since: "2015-06-01")
        try store.addStudioParentPeriod("studio:Old Network", forStudio: imprint,
                                        from: "2009-01-01", to: "2015-06-01")

        let data = try JSONEncoder().encode(try store.exportGraph(includingPhotoData: false))
        let decoded = try JSONDecoder().decode(ActorLibraryExport.self, from: data)

        XCTAssertEqual(Set(decoded.studioParents), [
            StudioParentEdge(from: imprint, to: "studio:Example Network",
                             validFrom: "2015-06-01", validTo: nil),
            StudioParentEdge(from: imprint, to: "studio:Old Network",
                             validFrom: "2009-01-01", validTo: "2015-06-01"),
        ])
    }

    /// 🚨 The whole graph survives a file round trip — not just the hierarchy.
    ///
    /// `ActorLibraryExport`'s decoder is hand-written and stopped at
    /// `tombstones`, so studios, tags, performer traits and the hierarchy were
    /// **encoded and then discarded on read**. Every `.vilmactors` import
    /// reported zeroes while holding the data in the file it had just parsed.
    /// The live attached-library sync never round-trips through JSON, which is
    /// why this went unnoticed.
    func testAFileRoundTripKeepsTheWholeGraphAndNotJustTheActors() throws {
        let imprint = try studio("Coast Line")
        _ = try studio("Example Network")
        try store.setStudioParent("studio:Example Network", forStudio: imprint)

        let data = try JSONEncoder().encode(try store.exportGraph(includingPhotoData: false))
        let decoded = try JSONDecoder().decode(ActorLibraryExport.self, from: data)

        XCTAssertEqual(decoded.studios.count, 2, "studio profiles survive")
        XCTAssertEqual(decoded.studioParents.count, 1, "the hierarchy survives")
    }

    /// ⚠️ An export written before this change has no date keys at all. It must
    /// still decode — as unknown, not as a failure.
    func testAnOlderUndatedExportStillDecodes() throws {
        let json = #"{"from":"studio:Coast Line","to":"studio:Example Network"}"#
        let edge = try JSONDecoder().decode(StudioParentEdge.self, from: Data(json.utf8))

        XCTAssertNil(edge.validFrom)
        XCTAssertNil(edge.validTo)
        XCTAssertTrue(edge.isCurrent)
    }

    /// Re-running a sync must change nothing the second time.
    func testTheMergeIsIdempotent() throws {
        _ = try studio("Coast Line")
        _ = try studio("Example Network")

        _ = try store.applyGraphMerge(export([("Coast Line", "Example Network")]))
        let second = try store.applyGraphMerge(export([("Coast Line", "Example Network")]))

        XCTAssertEqual(second.newStudioParents, 0)
        XCTAssertTrue(second.disagreements.isEmpty)
        XCTAssertEqual(try store.studioParentHistory(of: "studio:Coast Line").count, 1)
    }
}
