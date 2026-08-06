import XCTest
@testable import LibraryCore

/// The studio-level policy: verified name wins, at either level; ask when
/// verification cannot separate the two.
final class StudioResolutionTests: XCTestCase {

    private func candidate(_ name: String,
                           _ level: StudioResolution.Level,
                           verified: Bool) -> StudioResolution.Candidate {
        StudioResolution.Candidate(name: name, sourceId: "id-\(name)",
                                   level: level, isVerified: verified)
    }

    // MARK: - Nothing to choose between

    func testOnlyAnImprintIsUsedEvenUnverified() throws {
        let i = candidate("Example Studio", .imprint, verified: false)

        // ⚠️ Refusing it would leave the video with NO studio rather than an
        // unconfirmed one, which is strictly worse.
        XCTAssertEqual(StudioResolution.resolve(imprint: i, parent: nil), .use(i))
    }

    func testAParentAloneIsStillUsed() throws {
        let p = candidate("Example Network", .parent, verified: true)

        XCTAssertEqual(StudioResolution.resolve(imprint: nil, parent: p), .use(p))
    }

    func testNoStudioAtAll() throws {
        XCTAssertEqual(StudioResolution.resolve(imprint: nil, parent: nil), .none)
    }

    /// A source naming the same studio at both levels has not offered a choice.
    func testTheSameStudioAtBothLevelsIsNotAChoice() throws {
        let i = candidate("Example Studio", .imprint, verified: false)
        let p = candidate("example studio", .parent, verified: false)

        XCTAssertEqual(StudioResolution.resolve(imprint: i, parent: p), .use(i))
    }

    // MARK: - Verification decides

    func testTheVerifiedImprintWins() throws {
        let i = candidate("Example Studio", .imprint, verified: true)
        let p = candidate("Example Network", .parent, verified: false)

        XCTAssertEqual(StudioResolution.resolve(imprint: i, parent: p), .use(i))
    }

    /// ⚠️ The policy is verification, NOT level. A verified parent beats an
    /// unverified imprint even though the imprint is the more specific fact.
    func testTheVerifiedParentWinsOverAnUnverifiedImprint() throws {
        let i = candidate("Example Studio", .imprint, verified: false)
        let p = candidate("Example Network", .parent, verified: true)

        XCTAssertEqual(StudioResolution.resolve(imprint: i, parent: p), .use(p))
    }

    // MARK: - ⚠️ Where nothing is guessed

    func testNeitherVerifiedAsks() throws {
        let i = candidate("Example Studio", .imprint, verified: false)
        let p = candidate("Example Network", .parent, verified: false)

        XCTAssertEqual(StudioResolution.resolve(imprint: i, parent: p),
                       .ask(imprint: i, parent: p))
    }

    /// Both confirmed means both are real and correctly spelled — which is
    /// exactly when the data cannot say which the library should carry.
    func testBothVerifiedAsks() throws {
        let i = candidate("Example Studio", .imprint, verified: true)
        let p = candidate("Example Network", .parent, verified: true)

        XCTAssertEqual(StudioResolution.resolve(imprint: i, parent: p),
                       .ask(imprint: i, parent: p))
    }

    // MARK: - Same studio, different spelling

    func testRunTogetherSpellingsAreOneStudio() throws {
        XCTAssertTrue(StudioResolution.isSameStudio("Silver River", "SilverRiver"))
        XCTAssertTrue(StudioResolution.isSameStudio("Blue Harbor", "BlueHarbor"))
        XCTAssertTrue(StudioResolution.isSameStudio("Coast Line", "Coastline"))
    }

    func testDifferentStudiosAreNotFoldedTogether() throws {
        XCTAssertFalse(StudioResolution.isSameStudio("Example Studio", "Example Network"))
    }

    // MARK: - Auto-accepting a respelling

    /// The case from the operator's screenshot: same studio, better spelling,
    /// already verified. Asking would be busywork.
    func testAVerifiedRespellingIsAutoAccepted() throws {
        let proposed = candidate("Coast Line", .imprint, verified: true)

        XCTAssertTrue(StudioResolution.canAutoAccept(current: "Coastline",
                                                     proposed: proposed))
    }

    func testAnUnverifiedRespellingIsNotAutoAccepted() throws {
        let proposed = candidate("Coast Line", .imprint, verified: false)

        XCTAssertFalse(StudioResolution.canAutoAccept(current: "Coastline",
                                                      proposed: proposed))
    }

    /// ⚠️ The production-versus-redistribution case. Two different verified
    /// studios are both real, so replacing one with the other silently would
    /// overwrite a fact with an equally valid one nobody chose between.
    func testADifferentVerifiedStudioIsNeverAutoAccepted() throws {
        let proposed = candidate("Other Studio", .imprint, verified: true)

        XCTAssertFalse(StudioResolution.canAutoAccept(current: "Example Studio",
                                                      proposed: proposed))
    }

    func testAnIdenticalNameIsNotAChange() throws {
        let proposed = candidate("Example Studio", .imprint, verified: true)

        XCTAssertFalse(StudioResolution.canAutoAccept(current: "Example Studio",
                                                      proposed: proposed),
                       "nothing to accept")
    }
}
