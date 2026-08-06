import XCTest
@testable import LibraryCore

/// Phase D, step 1 — turning the `actor:` strings into real edges.
///
/// The strings stay authoritative throughout. What matters most here is what
/// this step must NOT do.
final class ConnectPerformerEdgesTests: XCTestCase {

    private var libraryURL: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        libraryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConnectEdges-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        store = try LibraryStore(at: libraryURL)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: libraryURL)
    }

    @discardableResult
    private func video(_ tags: [String]) throws -> UUID {
        let asset = Asset(relativePath: "\(UUID()).mp4", fileName: "a.mp4", tags: tags)
        try store.insertAsset(asset)
        return asset.id
    }

    private func profile(_ name: String) throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:\(name)"))
    }

    // MARK: - What it builds

    func testCreditsBecomeEdges() throws {
        try profile("Alice Example"); try profile("Bob Example")
        let a = try video(["actor:Alice Example", "actor:Bob Example", "tag:Outdoors"])
        let b = try video(["actor:Alice Example"])

        try store.connectPerformerEdges()

        XCTAssertEqual(try store.performerIds(forVideo: a),
                       ["actor:Alice Example", "actor:Bob Example"])
        XCTAssertEqual(try store.performerIds(forVideo: b), ["actor:Alice Example"])
        XCTAssertEqual(Set(try store.videoIds(forPerformer: "actor:Alice Example")), [a, b])
    }

    func testStudiosAndTagsAreNotPerformers() throws {
        try profile("Alice Example")
        let v = try video(["actor:Alice Example", "studio:Example Studio", "tag:Outdoors"])

        try store.connectPerformerEdges()

        XCTAssertEqual(try store.performerIds(forVideo: v), ["actor:Alice Example"])
        XCTAssertEqual(try store.edgeCount(.videoPerformer), 1)
    }

    // MARK: - ⚠️ What it must not do

    /// The strings remain the source of truth until a separate, gated step
    /// retires them. A connect run that edited them could not be re-run, and
    /// could not be checked against anything.
    func testTheLegacyStringsAreUntouched() throws {
        try profile("Alice Example")
        let v = try video(["actor:Alice Example", "studio:Example Studio"])

        try store.connectPerformerEdges()

        let asset = try XCTUnwrap(try store.fetchAllAssets().first { $0.id == v })
        XCTAssertEqual(asset.actors, ["Alice Example"])
        XCTAssertEqual(asset.studios, ["Example Studio"])
    }

    /// ⚠️ A credit naming someone with no profile is skipped and REPORTED.
    /// Creating the profile here would mint a person from a string a filename
    /// parse may have guessed — the one thing the parser is forbidden to do,
    /// and it must not happen by a side door.
    func testAnUnknownPerformerIsReportedNotInvented() throws {
        try profile("Alice Example")
        let v = try video(["actor:Alice Example", "actor:Nobody Known"])

        let plan = try store.connectPerformerEdges()

        XCTAssertEqual(plan.missingProfiles, ["Nobody Known"])
        XCTAssertEqual(try store.performerIds(forVideo: v), ["actor:Alice Example"])
        XCTAssertNil(try store.fetchEntityProfile(for: "actor:Nobody Known"),
                     "no person was created")
    }

    // MARK: - Safe to run more than once

    func testADryRunWritesNothing() throws {
        try profile("Alice Example")
        try video(["actor:Alice Example"])

        let plan = try store.connectPerformerEdges(dryRun: true)

        XCTAssertEqual(plan.associations, 1)
        XCTAssertEqual(try store.edgeCount(.videoPerformer), 0, "a plan is not a write")
    }

    func testRunningTwiceAddsNothing() throws {
        try profile("Alice Example")
        try video(["actor:Alice Example"])

        try store.connectPerformerEdges()
        let second = try store.connectPerformerEdges()

        XCTAssertEqual(try store.edgeCount(.videoPerformer), 1)
        XCTAssertEqual(second.connectable, 0, "nothing left to do")
    }

    func testARerunPicksUpOnlyWhatIsNew() throws {
        try profile("Alice Example"); try profile("Bob Example")
        try video(["actor:Alice Example"])
        try store.connectPerformerEdges()

        try video(["actor:Bob Example"])
        try store.connectPerformerEdges()

        XCTAssertEqual(try store.edgeCount(.videoPerformer), 2)
    }

    // MARK: - The gate on retiring the strings

    /// ⚠️ Counting alone would pass a migration that connected the right NUMBER
    /// of things to the wrong videos, so the check is per video.
    func testVerificationPassesWhenEveryVideoAgrees() throws {
        try profile("Alice Example"); try profile("Bob Example")
        try video(["actor:Alice Example", "actor:Bob Example"])
        try video(["actor:Bob Example"])

        try store.connectPerformerEdges()

        XCTAssertEqual(try store.performerEdgeDisagreements(), [])
    }

    func testVerificationNamesTheVideoThatDisagrees() throws {
        try profile("Alice Example"); try profile("Bob Example")
        let v = try video(["actor:Alice Example", "actor:Bob Example"])
        // Only one of the two credits connected — the shape a partial or
        // interrupted migration leaves behind.
        try store.linkPerformer("actor:Alice Example", toVideo: v)

        XCTAssertEqual(try store.performerEdgeDisagreements(), [v])
    }

    /// A credit that could never become an edge is a reported gap, not a
    /// disagreement — otherwise verification could never pass while one
    /// unknown name existed anywhere in the library.
    func testAnUnknownPerformerIsNotCountedAsADisagreement() throws {
        try profile("Alice Example")
        try video(["actor:Alice Example", "actor:Nobody Known"])

        try store.connectPerformerEdges()

        XCTAssertEqual(try store.performerEdgeDisagreements(), [])
    }
}
