import XCTest
@testable import LibraryCore

/// The store-level gatherers behind the two audit screens.
///
/// The pure logic is covered by `StudioAuditTests` and `GraphAuditTests`; what
/// was untested is the wiring — that `auditStudios()` and `auditGraph()` feed
/// them the right inputs. A gatherer that passed empty sets would make both
/// screens report a permanently healthy library, which is the worst possible
/// failure for an audit: silence that looks like good news.
final class StoreAuditGatheringTests: XCTestCase {

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
    private func video(_ tags: [String], released: String? = nil) throws -> Asset {
        var asset = Asset(relativePath: "\(UUID()).mp4", fileName: "a.mp4", tags: tags)
        asset.releaseDate = released
        try store.saveAsset(asset)
        try store.updateAsset(asset)
        return asset
    }

    // MARK: - auditStudios

    func testAuditStudiosFindsATwoStudioVideo() throws {
        _ = try video(["studio:Coast Line", "studio:Harbour Lane"])

        let checks = try store.auditStudios()
        XCTAssertTrue(checks.contains { $0.kind == .multiStudioVideo })
    }

    func testAuditStudiosFindsASpellingCollision() throws {
        _ = try video(["studio:Coast Line"])
        _ = try video(["studio:Coastline"])

        let checks = try store.auditStudios()
        let collision = checks.first { $0.kind == .spellingCollision }
        XCTAssertNotNil(collision, "the gatherer must reach the spelling audit")
        XCTAssertEqual(collision?.count, 1)
    }

    /// A clean library must report nothing — an audit that always finds
    /// something is one nobody reads.
    func testAuditStudiosIsSilentOnACleanLibrary() throws {
        try store.saveEntityProfile({
            var p = EntityProfile(id: "studio:Coast Line")
            p.enrichmentState = .matched
            return p
        }())
        _ = try video(["studio:Coast Line"])
        _ = try store.connectStudioEdges()

        XCTAssertTrue(try store.auditStudios().isEmpty)
    }

    // MARK: - auditGraph

    func testAuditGraphFindsAVideoDatedBeforeAPerformerWasBorn() throws {
        var performer = EntityProfile(id: "actor:Someone")
        performer.birthDate = "1995-01-01"
        try store.saveEntityProfile(performer)
        _ = try video(["actor:Someone"], released: "1990-06-01")

        let checks = try store.auditGraph()
        XCTAssertEqual(checks.first?.kind, .releasedBeforeBirth)
        XCTAssertTrue(checks.first?.isCertain ?? false)
    }

    func testAuditGraphIsSilentWhenTheDatesAgree() throws {
        var performer = EntityProfile(id: "actor:Someone")
        performer.birthDate = "1995-01-01"
        performer.careerStartYear = 2015
        try store.saveEntityProfile(performer)
        _ = try video(["actor:Someone"], released: "2020-06-01")

        XCTAssertTrue(try store.auditGraph().isEmpty)
    }

    /// The gatherer keys profiles by id; getting that wrong would silently
    /// match nobody and report a clean library forever.
    func testAuditGraphActuallyResolvesTheProfile() throws {
        var performer = EntityProfile(id: "actor:Someone")
        performer.birthYear = 2005
        try store.saveEntityProfile(performer)
        _ = try video(["actor:Someone"], released: "2015-06-01")   // age ~10

        let checks = try store.auditGraph()
        XCTAssertEqual(checks.first?.kind, .implausibleAge,
                       "a profile that did not resolve would produce no finding at all")
        XCTAssertEqual(checks.first?.findings.first?.performer, "Someone")
    }
}
