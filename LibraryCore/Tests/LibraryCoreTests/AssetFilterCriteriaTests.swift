import XCTest
@testable import LibraryCore

/// Characterizes the shared asset-filter matching that the All Assets grid and
/// the Move-Between-Libraries page both rely on. Pins the exact review/rating,
/// AND/OR set semantics, AKA resolution, and actor-metadata behavior so the two
/// screens can share one implementation without drift.
final class AssetFilterCriteriaTests: XCTestCase {

    // MARK: - Fixtures

    private func asset(
        status: Asset.ReviewStatus = .unreviewed,
        tags: [String] = [],
        rating: Int? = nil
    ) -> Asset {
        Asset(relativePath: "v.mp4", fileName: "v.mp4", status: status, tags: tags, rating: rating)
    }

    /// Convenience: resolve actors with no AKA aliases, then match.
    private func matches(
        _ criteria: AssetFilterCriteria,
        _ asset: Asset,
        akaMap: [String: String] = [:],
        profiles: [String: EntityProfile] = [:]
    ) -> Bool {
        let mapped = AssetFilterCriteria.mappedActors(for: asset, akaMap: akaMap)
        return criteria.matches(asset, mappedActors: mapped, entityProfiles: profiles)
    }

    // MARK: - Empty criteria

    func testEmptyCriteriaMatchesEverything() {
        let criteria = AssetFilterCriteria()
        XCTAssertTrue(criteria.isEmpty)
        XCTAssertTrue(matches(criteria, asset()))
        XCTAssertTrue(matches(criteria, asset(status: .reviewed, tags: ["actor:Jane"], rating: 1)))
    }

    // MARK: - Review status

    func testReviewStatusReviewedOnlyMatchesReviewed() {
        var criteria = AssetFilterCriteria()
        criteria.reviewStatus = .reviewed
        XCTAssertTrue(matches(criteria, asset(status: .reviewed)))
        XCTAssertFalse(matches(criteria, asset(status: .unreviewed)))
    }

    func testReviewStatusUnreviewedOnlyMatchesUnreviewed() {
        var criteria = AssetFilterCriteria()
        criteria.reviewStatus = .unreviewed
        XCTAssertTrue(matches(criteria, asset(status: .unreviewed)))
        XCTAssertFalse(matches(criteria, asset(status: .reviewed)))
    }

    // MARK: - Minimum rating

    func testMinRatingIncludesEqualAndHigherExcludesLower() {
        var criteria = AssetFilterCriteria()
        criteria.minRating = 4
        XCTAssertTrue(matches(criteria, asset(rating: 4)))
        XCTAssertTrue(matches(criteria, asset(rating: 5)))
        XCTAssertFalse(matches(criteria, asset(rating: 3)))
    }

    func testMinRatingTreatsUnratedAsZero() {
        var criteria = AssetFilterCriteria()
        criteria.minRating = 1
        XCTAssertFalse(matches(criteria, asset(rating: nil)), "an unrated video counts as rating 0")
    }

    // MARK: - Actors (AND / OR)

    func testSelectedActorsAndRequiresAllPresent() {
        var criteria = AssetFilterCriteria()
        criteria.actorsLogic = .and
        criteria.selectedActors = ["Jane", "John"]
        XCTAssertTrue(matches(criteria, asset(tags: ["actor:Jane", "actor:John"])))
        XCTAssertFalse(matches(criteria, asset(tags: ["actor:Jane"])), "AND requires every selected actor")
    }

    func testSelectedActorsOrRequiresAnyPresent() {
        var criteria = AssetFilterCriteria()
        criteria.actorsLogic = .or
        criteria.selectedActors = ["Jane", "John"]
        XCTAssertTrue(matches(criteria, asset(tags: ["actor:Jane"])), "OR needs only one")
        XCTAssertFalse(matches(criteria, asset(tags: ["actor:Nobody"])))
    }

    func testAkaAliasResolvesToCanonicalActorForMatching() {
        var criteria = AssetFilterCriteria()
        criteria.selectedActors = ["Jane Doe"]
        // The video is tagged with the alias "Janie"; the akaMap resolves it to
        // the canonical "Jane Doe". (Note: Asset.actors title-cases the tag, so
        // the alias key must be in its normalized form — mirroring how the real
        // grid resolves AKAs against `asset.actors`.)
        let tagged = asset(tags: ["actor:Janie"])
        XCTAssertFalse(matches(criteria, tagged), "without resolution the alias shouldn't match")
        XCTAssertTrue(matches(criteria, tagged, akaMap: ["Janie": "Jane Doe"]), "alias must resolve to the canonical name")
    }

    // MARK: - Tags & Studios

    func testSelectedTagsAndOr() {
        var criteria = AssetFilterCriteria()
        criteria.tagsLogic = .and
        criteria.selectedTags = ["Action", "Drama"]
        XCTAssertTrue(matches(criteria, asset(tags: ["tag:Action", "tag:Drama"])))
        XCTAssertFalse(matches(criteria, asset(tags: ["tag:Action"])))

        criteria.tagsLogic = .or
        XCTAssertTrue(matches(criteria, asset(tags: ["tag:Action"])))
        XCTAssertFalse(matches(criteria, asset(tags: ["tag:Comedy"])))
    }

    func testSelectedStudiosAndOr() {
        var criteria = AssetFilterCriteria()
        criteria.studiosLogic = .or
        criteria.selectedStudios = ["Acme", "Globex"]
        XCTAssertTrue(matches(criteria, asset(tags: ["studio:Acme"])))
        XCTAssertFalse(matches(criteria, asset(tags: ["studio:Initech"])))
    }

    // MARK: - Actor metadata (matched through the video's actors' profiles)

    func testActorHairColorOrMatchesThroughAnyActor() {
        var criteria = AssetFilterCriteria()
        criteria.actorHairColorsLogic = .or
        criteria.selectedActorHairColors = ["Blonde"]
        let profiles = ["actor:Jane": EntityProfile(id: "actor:Jane", hairColor: "Blonde")]
        XCTAssertTrue(matches(criteria, asset(tags: ["actor:Jane"]), profiles: profiles))
        XCTAssertFalse(matches(criteria, asset(tags: ["actor:Jane"]),
                               profiles: ["actor:Jane": EntityProfile(id: "actor:Jane", hairColor: "Brown")]))
    }

    func testActorMetadataCommaSeparatedValuesAreSplit() {
        var criteria = AssetFilterCriteria()
        criteria.selectedActorGenders = ["Female"]
        // One profile lists two genders comma-separated; the "Female" token must match.
        let profiles = ["actor:Jamie": EntityProfile(id: "actor:Jamie", gender: "Male, Female")]
        XCTAssertTrue(matches(criteria, asset(tags: ["actor:Jamie"]), profiles: profiles))
    }

    func testActorMetadataAndLogicSpansAllActorsInVideo() {
        var criteria = AssetFilterCriteria()
        criteria.actorHairColorsLogic = .and
        criteria.selectedActorHairColors = ["Blonde", "Brown"]
        // Two actors between them cover both colors → AND is satisfied at the
        // video level (not required per-actor).
        let profiles = [
            "actor:Jane": EntityProfile(id: "actor:Jane", hairColor: "Blonde"),
            "actor:John": EntityProfile(id: "actor:John", hairColor: "Brown")
        ]
        XCTAssertTrue(matches(criteria, asset(tags: ["actor:Jane", "actor:John"]), profiles: profiles))
        XCTAssertFalse(matches(criteria, asset(tags: ["actor:Jane"]), profiles: profiles),
                       "one Blonde actor can't satisfy an AND that also requires Brown")
    }

    func testActorTagsFilterMatchesThroughProfileTags() {
        var criteria = AssetFilterCriteria()
        criteria.selectedActorTags = ["tag:Lead"]
        let profiles = ["actor:Jane": EntityProfile(id: "actor:Jane", tags: ["tag:Lead"])]
        XCTAssertTrue(matches(criteria, asset(tags: ["actor:Jane"]), profiles: profiles))
        XCTAssertFalse(matches(criteria, asset(tags: ["actor:Jane"]),
                               profiles: ["actor:Jane": EntityProfile(id: "actor:Jane", tags: ["tag:Extra"])]))
    }

    // MARK: - Minimum actor rating (matched through featured actors' profiles)

    func testMinActorRatingMatchesWhenAnyFeaturedActorQualifies() {
        var criteria = AssetFilterCriteria()
        criteria.minActorRating = 4
        let profiles = [
            "actor:Jane": EntityProfile(id: "actor:Jane", rating: 5),
            "actor:John": EntityProfile(id: "actor:John", rating: 2)
        ]
        // One qualifying actor is enough, even alongside a low-rated one.
        XCTAssertTrue(matches(criteria, asset(tags: ["actor:Jane", "actor:John"]), profiles: profiles))
        // Exactly at the bar counts.
        XCTAssertTrue(matches(criteria, asset(tags: ["actor:Jane"]),
                              profiles: ["actor:Jane": EntityProfile(id: "actor:Jane", rating: 4)]))
    }

    func testMinActorRatingRejectsLowRatedUnratedAndUnprofiled() {
        var criteria = AssetFilterCriteria()
        criteria.minActorRating = 4
        XCTAssertFalse(matches(criteria, asset(tags: ["actor:John"]),
                               profiles: ["actor:John": EntityProfile(id: "actor:John", rating: 3)]))
        XCTAssertFalse(matches(criteria, asset(tags: ["actor:John"]),
                               profiles: ["actor:John": EntityProfile(id: "actor:John")]), "unrated actor doesn't qualify")
        XCTAssertFalse(matches(criteria, asset(tags: ["actor:Nobody"]), profiles: [:]), "no profile at all doesn't qualify")
        XCTAssertFalse(criteria.isEmpty, "an active actor-rating bar counts as a filter")
    }

    func testFilterSavedBeforeActorRatingFieldStillDecodes() throws {
        // A default filter persisted by an older build has no minActorRating
        // key — decoding must succeed with the field nil (saved default
        // filters and Smart Collections must survive the upgrade).
        var old = AssetFilterCriteria()
        old.minRating = 3
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        json.removeValue(forKey: "minActorRating")
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(AssetFilterCriteria.self, from: data)
        XCTAssertNil(decoded.minActorRating)
        XCTAssertEqual(decoded.minRating, 3)
    }

    // MARK: - Combined criteria

    func testAllSpecifiedCriteriaMustPassTogether() {
        var criteria = AssetFilterCriteria()
        criteria.reviewStatus = .reviewed
        criteria.minRating = 4
        criteria.selectedActors = ["Jane"]

        let good = asset(status: .reviewed, tags: ["actor:Jane"], rating: 5)
        XCTAssertTrue(matches(criteria, good))

        // Each single violation flips the result to false.
        XCTAssertFalse(matches(criteria, asset(status: .unreviewed, tags: ["actor:Jane"], rating: 5)))
        XCTAssertFalse(matches(criteria, asset(status: .reviewed, tags: ["actor:Jane"], rating: 2)))
        XCTAssertFalse(matches(criteria, asset(status: .reviewed, tags: ["actor:Nobody"], rating: 5)))
    }
}
