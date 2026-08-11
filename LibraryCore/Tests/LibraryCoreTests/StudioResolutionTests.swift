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

    // MARK: - 🚨 A settled decision is not re-opened

    /// The operator already answered this question for this video. Re-matching
    /// is a refresh — it picks up new data, it does not re-litigate.
    ///
    /// ⚠️ This outranks verification deliberately. Both names being verified is
    /// the COMMON case on a curated library — accepting a studio is what
    /// verifies it — so without this rule the question came back more often the
    /// more of the library the operator had settled.
    func testTheStudioTheVideoAlreadyCarriesIsKeptWithoutAsking() {
        let i = StudioResolution.Candidate(name: "Example Studio", sourceId: "i",
                                           level: .imprint, isVerified: true)
        let p = StudioResolution.Candidate(name: "Example Network", sourceId: "p",
                                           level: .parent, isVerified: true)

        XCTAssertEqual(
            StudioResolution.resolve(imprint: i, parent: p, held: ["Example Network"]),
            .use(p), "both verified would otherwise ask")
        XCTAssertEqual(
            StudioResolution.resolve(imprint: i, parent: p, held: ["Example Studio"]),
            .use(i))
    }

    /// And it beats verification pointing the other way — the stored answer is
    /// about THIS video, which the verified set is not.
    func testTheHeldStudioBeatsAVerifiedAlternative() {
        let i = StudioResolution.Candidate(name: "Example Studio", sourceId: "i",
                                           level: .imprint, isVerified: false)
        let p = StudioResolution.Candidate(name: "Example Network", sourceId: "p",
                                           level: .parent, isVerified: true)

        XCTAssertEqual(
            StudioResolution.resolve(imprint: i, parent: p, held: ["Example Studio"]),
            .use(i), "the network is verified, but this video already answered")
    }

    /// ⭐ Spelling differences do not defeat it, using the same folding the rest
    /// of this type uses — otherwise "SilverRiver" on the video and
    /// "Silver River" from the source would read as an unanswered question.
    func testAHeldStudioMatchesOnTheSameFoldingAsEverythingElse() {
        let i = StudioResolution.Candidate(name: "Silver River", sourceId: "i",
                                           level: .imprint, isVerified: false)
        let p = StudioResolution.Candidate(name: "Example Network", sourceId: "p",
                                           level: .parent, isVerified: false)

        XCTAssertEqual(StudioResolution.resolve(imprint: i, parent: p, held: ["silverriver"]),
                       .use(i))
    }

    /// 🚨 The limit. If the source has started naming two DIFFERENT studios,
    /// the old answer is not an answer to the new question, and it still asks.
    /// A rule that always kept the held value would silently freeze the studio
    /// against genuinely new upstream data.
    func testAHeldStudioThatIsNeitherCandidateStillAsks() {
        let i = StudioResolution.Candidate(name: "Example Studio", sourceId: "i",
                                           level: .imprint, isVerified: false)
        let p = StudioResolution.Candidate(name: "Example Network", sourceId: "p",
                                           level: .parent, isVerified: false)

        guard case .ask = StudioResolution.resolve(imprint: i, parent: p,
                                                   held: ["Something Else Entirely"])
        else { return XCTFail("a stale answer to a different question is not an answer") }
    }

    /// ⚠️ An empty held list changes nothing — the pre-existing behaviour is
    /// intact for a video that has no studio yet.
    func testAVideoWithNoStudioIsUnaffected() {
        let i = StudioResolution.Candidate(name: "Example Studio", sourceId: "i",
                                           level: .imprint, isVerified: false)
        let p = StudioResolution.Candidate(name: "Example Network", sourceId: "p",
                                           level: .parent, isVerified: false)

        guard case .ask = StudioResolution.resolve(imprint: i, parent: p, held: [])
        else { return XCTFail("expected the unchanged behaviour") }
    }
}
