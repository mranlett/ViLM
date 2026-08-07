import XCTest
@testable import LibraryCore

/// The studio hierarchy with a lifetime — Edge Attributes phase 2.
///
/// An imprint owned by one network until 2015 and another after it is two
/// facts, and the old key held one. The tests that matter are about what
/// happens to the rows the migration created (start unknown, still current)
/// and about the database refusing what application code should not police.
final class TemporalStudioParentTests: XCTestCase {

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

    // MARK: - T1 / T2 — rows and their defaults

    func testASetParentIsCurrentWithAnUnknownStart() throws {
        let imprint = try studio("Coast Line")
        let network = try studio("Example Network")
        try store.setStudioParent(network, forStudio: imprint)

        XCTAssertEqual(try store.parentStudioId(of: imprint), network)
        let history = try store.studioParentHistory(of: imprint)
        XCTAssertEqual(history.count, 1)
        XCTAssertNil(history[0].from, "no source supplies an acquisition date")
        XCTAssertTrue(history[0].isCurrent)
    }

    /// ⚠️ A CHANGE closes the previous row rather than overwriting it. The old
    /// ownership was true; it stopped being true.
    func testChangingTheParentClosesTheOldPeriodRatherThanErasingIt() throws {
        let imprint = try studio("Coast Line")
        let first = try studio("Old Network")
        let second = try studio("Example Network")

        try store.setStudioParent(first, forStudio: imprint)
        try store.setStudioParent(second, forStudio: imprint, since: "2015-01-01")

        let history = try store.studioParentHistory(of: imprint)
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.map(\.parentId), [first, second])
        XCTAssertEqual(history[0].to, "2015-01-01", "the periods meet")
        XCTAssertEqual(history[1].from, "2015-01-01")
        XCTAssertTrue(history[1].isCurrent)
        XCTAssertEqual(try store.parentStudioId(of: imprint), second)
    }

    /// Match runs re-assert constantly; each one opening a period would fill
    /// the table with adjacent identical rows.
    func testReassertingTheSameParentIsANoOp() throws {
        let imprint = try studio("Coast Line")
        let network = try studio("Example Network")

        try store.setStudioParent(network, forStudio: imprint)
        try store.setStudioParent(network, forStudio: imprint)
        try store.setStudioParent(network, forStudio: imprint)

        XCTAssertEqual(try store.studioParentHistory(of: imprint).count, 1)
    }

    /// 🚨 With no `since`, the boundary is still ONE date used twice.
    ///
    /// Closing the old row at today while opening the new one at NULL made the
    /// new period cover all of history, so an as-of query returned BOTH
    /// parents. The earlier tests missed it by always passing `since`.
    func testReplacingAParentWithNoDateStillLeavesOnePeriodPerDay() throws {
        let imprint = try studio("Coast Line")
        let old = try studio("Old Network")
        let new = try studio("Example Network")

        try store.setStudioParent(old, forStudio: imprint)
        try store.setStudioParent(new, forStudio: imprint)   // no `since`

        for day in ["1999-01-01", "2012-06-01", "2099-01-01"] {
            let owners = try store.studioParentPairs(asOf: day).filter { $0.from == imprint }
            XCTAssertEqual(owners.count, 1, "one parent on \(day)")
        }
    }

    // MARK: - T3 — the database, not the application, enforces it

    /// ⭐ "At most one OPEN parent per studio" is a partial unique index. The
    /// only form of that rule which survives a second writer.
    func testTwoOpenPeriodsAreRefusedByTheDatabase() throws {
        let imprint = try studio("Coast Line")
        let first = try studio("Old Network")
        let second = try studio("Example Network")

        try store.setStudioParent(first, forStudio: imprint)
        // Bypasses the closing logic, the way a second writer would.
        XCTAssertThrowsError(try store.insertOpenStudioParentForTesting(second,
                                                                       forStudio: imprint))
    }

    // MARK: - T4 / T5 — resolving as of a date

    func testAsOfResolvesToTheOwnerAtThatTime() throws {
        let imprint = try studio("Coast Line")
        let first = try studio("Old Network")
        let second = try studio("Example Network")

        try store.setStudioParent(first, forStudio: imprint)
        try store.setStudioParent(second, forStudio: imprint, since: "2015-01-01")

        let before = try store.studioParentPairs(asOf: "2012-06-01")
        XCTAssertEqual(before.first(where: { $0.from == imprint })?.to, first)

        let after = try store.studioParentPairs(asOf: "2020-06-01")
        XCTAssertEqual(after.first(where: { $0.from == imprint })?.to, second)
    }

    /// 🚨 The assertion that catches every migrated hierarchy disappearing.
    /// NULL means "as far back as we know", not "never".
    func testARowWithNoStartMatchesAnyDate() throws {
        let imprint = try studio("Coast Line")
        let network = try studio("Example Network")
        try store.setStudioParent(network, forStudio: imprint)

        XCTAssertEqual(try store.studioParentPairs(asOf: "1999-01-01").count, 1)
        XCTAssertEqual(try store.studioParentPairs(asOf: "2099-01-01").count, 1)
    }

    /// Descendants resolve as of a date too — this is what stops a family view
    /// filing a 2012 release under a network that bought the imprint in 2018.
    func testDescendantsResolveAsOfADate() throws {
        let imprint = try studio("Coast Line")
        let old = try studio("Old Network")
        let new = try studio("Example Network")

        try store.setStudioParent(old, forStudio: imprint)
        try store.setStudioParent(new, forStudio: imprint, since: "2018-01-01")

        XCTAssertEqual(Set(try store.studioIdWithDescendants(old, asOf: "2012-06-01")),
                       [old, imprint])
        XCTAssertEqual(Set(try store.studioIdWithDescendants(new, asOf: "2012-06-01")),
                       [new], "it did not own the imprint yet")
        XCTAssertEqual(Set(try store.studioIdWithDescendants(new)), [new, imprint],
                       "but it does now")
    }

    // MARK: - Current-only defaults

    /// Every existing caller means "now", so a retired hierarchy must not leak
    /// into the default reads — a 2009 parent reported forever would show as a
    /// dangling network in Studio Health.
    func testDefaultReadsSeeOnlyCurrentRows() throws {
        let imprint = try studio("Coast Line")
        let old = try studio("Old Network")
        let new = try studio("Example Network")

        try store.setStudioParent(old, forStudio: imprint)
        try store.setStudioParent(new, forStudio: imprint, since: "2018-01-01")

        XCTAssertEqual(try store.studioParentPairs().count, 1)
        XCTAssertEqual(try store.childStudioIds(of: old), [])
        XCTAssertEqual(try store.childStudioIds(of: new), [imprint])
    }

    // MARK: - Cycles

    /// A closed historical row must not make a hierarchy look cyclic when it is
    /// only a former owner.
    func testAFormerOwnerDoesNotCountAsACycle() throws {
        let a = try studio("A Label")
        let b = try studio("B Label")

        try store.setStudioParent(b, forStudio: a)          // A under B
        try store.setStudioParent(try studio("C Label"), forStudio: a, since: "2020-01-01")

        // B is now free to sit under A: the A→B row is closed.
        XCTAssertNoThrow(try store.setStudioParent(a, forStudio: b))
    }

    func testAGenuineCycleIsStillRefused() throws {
        let a = try studio("A Label")
        let b = try studio("B Label")
        try store.setStudioParent(b, forStudio: a)
        XCTAssertThrowsError(try store.setStudioParent(a, forStudio: b))
    }

    // MARK: - Display

    func testPeriodsPhraseOnlyWhatTheyKnow() {
        XCTAssertEqual(StudioParentPeriod(parentId: "studio:Example Network",
                                          from: nil, to: nil).displayText,
                       "Example Network")
        XCTAssertEqual(StudioParentPeriod(parentId: "studio:Example Network",
                                          from: "2015", to: nil).displayText,
                       "Example Network since 2015")
        XCTAssertEqual(StudioParentPeriod(parentId: "studio:Example Network",
                                          from: "2010", to: "2015").displayText,
                       "Example Network 2010–2015")
        XCTAssertEqual(StudioParentPeriod(parentId: "studio:Example Network",
                                          from: nil, to: "2015").displayText,
                       "Example Network until 2015")
    }
}
