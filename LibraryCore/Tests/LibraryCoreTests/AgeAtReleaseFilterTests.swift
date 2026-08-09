import XCTest
@testable import LibraryCore

/// Filtering videos by how old a credited performer was at release.
///
/// The whole point of this filter is a fact no single record holds — it needs
/// the video's date and the performer's birth date together. The rules that
/// matter are about what an APPROXIMATE age is allowed to claim.
final class AgeAtReleaseFilterTests: XCTestCase {

    private func asset(_ released: String?, actors: [String] = ["Someone"]) -> Asset {
        Asset(relativePath: "\(UUID()).mp4", fileName: "a.mp4",
              tags: actors.map { "actor:\($0)" }, releaseDate: released)
    }

    private func profiles(_ entries: [(String, String?, Int?)]) -> EntityProfileIndex {
        EntityProfileIndex(entries.map { name, birthDate, birthYear in
            var p = EntityProfile(id: "actor:\(name)")
            p.birthDate = birthDate
            p.birthYear = birthYear
            return p
        })
    }

    private func criteria(min: Int? = nil, max: Int? = nil) -> AssetFilterCriteria {
        var c = AssetFilterCriteria()
        c.minAgeAtRelease = min
        c.maxAgeAtRelease = max
        return c
    }

    private func matches(_ c: AssetFilterCriteria, _ a: Asset,
                         _ p: EntityProfileIndex) -> Bool {
        c.matches(a, mappedActors: Set(a.actors), entityProfiles: p)
    }

    // MARK: - The exact case

    func testAnExactAgeInsideTheBoundsMatches() {
        XCTAssertTrue(matches(criteria(min: 20, max: 30),
                              asset("2020-06-01"),
                              profiles([("Someone", "1995-01-01", nil)])))  // exactly 25
    }

    func testAnExactAgeOutsideTheBoundsDoesNot() {
        XCTAssertFalse(matches(criteria(min: 30),
                               asset("2020-06-01"),
                               profiles([("Someone", "1995-01-01", nil)])))
    }

    func testBoundsAreInclusive() {
        let p = profiles([("Someone", "1995-01-01", nil)])   // 25 at release
        XCTAssertTrue(matches(criteria(min: 25), asset("2020-06-01"), p))
        XCTAssertTrue(matches(criteria(max: 25), asset("2020-06-01"), p))
    }

    // MARK: - 🚨 The approximate case

    /// An age from a birth YEAR is either that number or one less. Filtering on
    /// the headline number would report it as certain and include a record that
    /// might not qualify.
    func testAnApproximateAgeAtTheBoundaryIsExcluded() {
        // Birth year 2002, released 2020 → "18", but really 17 or 18.
        let p = profiles([("Someone", nil, 2002)])
        XCTAssertFalse(matches(criteria(min: 18), asset("2020-06-01"), p),
                       "17 is possible, so this cannot be reported as certainly 18")
    }

    /// The same record DOES match once the bound is low enough that every
    /// possible age satisfies it.
    func testAnApproximateAgeMatchesWhenTheWholeRangeQualifies() {
        let p = profiles([("Someone", nil, 2002)])
        XCTAssertTrue(matches(criteria(min: 17), asset("2020-06-01"), p))
    }

    /// Symmetric at the top: an approximate 25 could be 25, so a max of 24
    /// must exclude it.
    func testAnApproximateAgeIsExcludedAtTheUpperBoundToo() {
        let p = profiles([("Someone", nil, 1995)])   // "25", really 24 or 25
        XCTAssertFalse(matches(criteria(max: 24), asset("2020-06-01"), p))
        XCTAssertTrue(matches(criteria(max: 25), asset("2020-06-01"), p))
    }

    /// ⚠️ The exclusion is deliberate and asymmetric: a full birth date makes
    /// the identical headline age match where the approximate one did not.
    func testAFullBirthDateMatchesWhereABirthYearAloneDoesNot() {
        let asset = asset("2020-06-01")
        XCTAssertFalse(matches(criteria(min: 18), asset, profiles([("Someone", nil, 2002)])))
        XCTAssertTrue(matches(criteria(min: 18), asset,
                              profiles([("Someone", "2002-01-01", nil)])))
    }

    // MARK: - What cannot be answered

    /// The filter asks a question about age; a record that cannot answer it has
    /// not answered yes.
    func testAVideoWithNoReleaseDateDoesNotMatch() {
        XCTAssertFalse(matches(criteria(min: 18), asset(nil),
                               profiles([("Someone", "1995-01-01", nil)])))
    }

    func testAPerformerWithNoBirthInfoDoesNotMatch() {
        XCTAssertFalse(matches(criteria(min: 18), asset("2020-06-01"),
                               profiles([("Someone", nil, nil)])))
    }

    func testAVideoWithNoCreditedPerformersDoesNotMatch() {
        XCTAssertFalse(matches(criteria(min: 18), asset("2020-06-01", actors: []), .empty))
    }

    // MARK: - Several performers

    /// "Videos featuring someone of this age" — one qualifying performer is
    /// enough, which is how every other actor-metadata filter here behaves.
    func testOneQualifyingPerformerIsEnough() {
        let a = asset("2020-06-01", actors: ["Older", "Younger"])
        let p = profiles([("Older", "1980-01-01", nil),      // 40
                          ("Younger", "1998-01-01", nil)])   // 22
        XCTAssertTrue(matches(criteria(min: 35), a, p))
        XCTAssertTrue(matches(criteria(max: 25), a, p))
        XCTAssertFalse(matches(criteria(min: 50), a, p))
    }

    // MARK: - Housekeeping

    func testAnUnsetAgeFilterIsEmptyAndMatchesEverything() {
        XCTAssertTrue(AssetFilterCriteria().isEmpty)
        XCTAssertTrue(matches(AssetFilterCriteria(), asset(nil), .empty))
    }

    func testAnAgeFilterMakesTheCriteriaNonEmpty() {
        XCTAssertFalse(criteria(min: 18).isEmpty)
        XCTAssertFalse(criteria(max: 30).isEmpty)
    }

    /// Filters saved before these fields existed must still decode.
    func testOlderSavedFiltersStillDecode() throws {
        let legacy = #"{"reviewStatus":"All","enrichment":"any","actorsLogic":"AND","selectedActors":[],"tagsLogic":"AND","selectedTags":[],"studiosLogic":"AND","selectedStudios":[],"actorTagsLogic":"AND","selectedActorTags":[],"actorHairColorsLogic":"OR","selectedActorHairColors":[],"actorGendersLogic":"OR","selectedActorGenders":[],"actorCountriesLogic":"OR","selectedActorCountries":[]}"#
        let decoded = try JSONDecoder().decode(AssetFilterCriteria.self,
                                               from: Data(legacy.utf8))
        XCTAssertNil(decoded.minAgeAtRelease)
        XCTAssertNil(decoded.maxAgeAtRelease)
        XCTAssertTrue(decoded.isEmpty)
    }
}
