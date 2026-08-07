import XCTest
@testable import LibraryCore

/// The graph checking itself.
///
/// Every check here needs two records joined, so the tests are mostly about
/// what the audit is entitled to CLAIM when the two disagree — and about not
/// crying wolf, because an audit nobody trusts gets switched off.
final class GraphAuditTests: XCTestCase {

    private func asset(_ released: String?, actors: [String] = ["Someone"],
                       named: String = "a.mp4") -> Asset {
        Asset(relativePath: "\(UUID()).mp4", fileName: named,
              tags: actors.map { "actor:\($0)" }, releaseDate: released)
    }

    private func profile(_ name: String = "Someone", birthDate: String? = nil,
                         birthYear: Int? = nil, start: Int? = nil,
                         end: Int? = nil) -> [String: EntityProfile] {
        var p = EntityProfile(id: "actor:\(name)")
        p.birthDate = birthDate
        p.birthYear = birthYear
        p.careerStartYear = start
        p.careerEndYear = end
        return ["actor:\(name)": p]
    }

    private func run(_ a: [Asset], _ p: [String: EntityProfile]) -> [GraphCheck] {
        GraphAudit.run(GraphAudit.Input(assets: a, profiles: p))
    }

    // MARK: - Silence

    func testACleanLibraryReportsNothing() {
        XCTAssertTrue(run([asset("2020-06-01")],
                          profile(birthDate: "1995-01-01", start: 2015)).isEmpty)
    }

    func testAVideoWithNoReleaseDateIsNotChecked() {
        XCTAssertTrue(run([asset(nil)], profile(birthDate: "1995-01-01")).isEmpty)
    }

    func testAPerformerWithNoProfileIsNotChecked() {
        XCTAssertTrue(run([asset("2020-06-01")], [:]).isEmpty)
    }

    // MARK: - 🚨 Released before birth

    /// Certainly wrong — and currently invisible everywhere else, because the
    /// age calculator returns nil rather than a negative number.
    func testAReleaseBeforeTheBirthIsReported() {
        let checks = run([asset("1990-06-01")], profile(birthDate: "1995-01-01"))

        XCTAssertEqual(checks.count, 1)
        XCTAssertEqual(checks.first?.kind, .releasedBeforeBirth)
        XCTAssertTrue(checks.first?.isCertain ?? false)
    }

    /// The age calculator's silence is what makes this check necessary; this
    /// pins that it really is silent, so the audit is the only surface.
    func testTheAgeCalculatorSaysNothingAboutThatCase() {
        XCTAssertNil(AgeAtReleaseCalculator.age(birthDate: "1995-01-01", birthYear: nil,
                                                releaseDate: "1990-06-01"))
    }

    /// ⚠️ One finding, not four. Every other check would be derived from the
    /// same impossible numbers and would only repeat it in other words.
    func testAnImpossibleDateProducesOneFindingNotSeveral() {
        let checks = run([asset("1990-06-01")],
                         profile(birthDate: "1995-01-01", start: 2015, end: 2020))

        XCTAssertEqual(checks.count, 1)
        XCTAssertEqual(checks.first?.count, 1)
    }

    // MARK: - Implausible age

    func testAnAgeFarOutsideThePlausibleBandIsReported() {
        let checks = run([asset("2020-06-01")], profile(birthDate: "1910-01-01"))

        XCTAssertEqual(checks.first?.kind, .implausibleAge)
        XCTAssertFalse(checks.first?.isCertain ?? true)
    }

    func testAnOrdinaryAgeIsNotReported() {
        XCTAssertTrue(run([asset("2020-06-01")], profile(birthDate: "1995-01-01")).isEmpty)
    }

    /// ⚠️ Only when EVERY possible age is outside the band. An age from a birth
    /// year alone spans two values, and flagging a borderline one would send
    /// the operator to check a record that is fine.
    func testABorderlineApproximateAgeIsNotFlagged() {
        // Birth year 2005, released 2020 → 15 or 14; 15 is inside the band.
        XCTAssertFalse(GraphAudit.isImplausible(AgeAtRelease(years: 15, isExact: false)))
        // Exact 14 is wholly outside.
        XCTAssertTrue(GraphAudit.isImplausible(AgeAtRelease(years: 14, isExact: true)))
    }

    // MARK: - Career span

    func testAReleaseBeforeTheRecordedCareerStartIsReported() {
        let checks = run([asset("2010-06-01")],
                         profile(birthDate: "1990-01-01", start: 2015))

        XCTAssertEqual(checks.first?.kind, .beforeCareerStart)
    }

    func testAReleaseAfterTheRecordedCareerEndIsReported() {
        let checks = run([asset("2024-06-01")],
                         profile(birthDate: "1990-01-01", start: 2010, end: 2020))

        XCTAssertEqual(checks.first?.kind, .afterCareerEnd)
    }

    /// 🚨 A missing end means the span is OPEN — "still performing" — not
    /// unknown. Flagging recent work against it would report every active
    /// performer in the library.
    func testAnOpenCareerSpanIsNeverAViolation() {
        XCTAssertTrue(run([asset("2024-06-01")],
                          profile(birthDate: "1990-01-01", start: 2010, end: nil)).isEmpty)
    }

    func testAReleaseInsideTheRecordedSpanIsFine() {
        XCTAssertTrue(run([asset("2015-06-01")],
                          profile(birthDate: "1990-01-01", start: 2010, end: 2020)).isEmpty)
    }

    // MARK: - Shape of the report

    /// Certain findings lead, then by size — the same rule Studio Health uses,
    /// so the two screens read the same way.
    func testCertainFindingsLeadEvenWhenSmaller() {
        var assets = [Asset]()
        for _ in 0..<5 { assets.append(asset("2010-06-01", actors: ["Late"])) }
        assets.append(asset("1980-06-01", actors: ["Impossible"]))

        var profiles = profile("Late", birthDate: "1990-01-01", start: 2015)
        profiles.merge(profile("Impossible", birthDate: "1995-01-01")) { a, _ in a }

        let checks = run(assets, profiles)
        XCTAssertEqual(checks.first?.kind, .releasedBeforeBirth)
        XCTAssertEqual(checks.first?.count, 1)
        XCTAssertEqual(checks.last?.count, 5)
    }

    /// A finding names the performer as well as the video: the video is fine
    /// for everyone else in its cast, and a row that only named the file would
    /// not say what to look at.
    func testAFindingNamesThePerformerAndTheVideo() {
        let a = asset("1990-06-01", actors: ["Someone"], named: "clip.mp4")
        let checks = run([a], profile(birthDate: "1995-01-01"))
        let finding = checks.first?.findings.first

        XCTAssertEqual(finding?.performer, "Someone")
        XCTAssertEqual(finding?.videoLabel, "clip.mp4")
        XCTAssertEqual(finding?.assetId, a.id)
        XCTAssertEqual(finding?.detail, "released 1990, born 1995")
    }

    /// Only the credited performer is judged, not the whole cast.
    func testOnlyTheOffendingPerformerIsReported() {
        let a = asset("2020-06-01", actors: ["Fine", "Impossible"])
        var profiles = profile("Fine", birthDate: "1990-01-01")
        profiles.merge(profile("Impossible", birthDate: "2025-01-01")) { x, _ in x }

        let checks = run([a], profiles)
        XCTAssertEqual(checks.first?.findings.map(\.performer), ["Impossible"])
    }
}
