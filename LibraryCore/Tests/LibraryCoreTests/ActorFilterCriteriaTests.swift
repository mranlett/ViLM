import XCTest
@testable import LibraryCore

/// Characterization tests for the Actor Gallery filter/sort pipeline (#14, F7).
///
/// The pipeline was extracted from `ActorGridView.filteredActors`, where it ran
/// inside `body`. These pin its behaviour so a caching change can be proven to
/// produce identical output — the acceptance criterion that matters most, since
/// a faster grid showing different actors is a regression, not an optimisation.
final class ActorFilterCriteriaTests: XCTestCase {

    private func profile(
        _ name: String,
        bio: String? = nil, photoUrl: String? = nil, gender: String? = nil,
        hairColor: String? = nil, birthYear: Int? = nil, country: String? = nil,
        rating: Int? = nil, tags: [String] = [], created: TimeInterval = 0
    ) -> EntityProfile {
        EntityProfile(id: "actor:\(name)", bio: bio, photoUrl: photoUrl,
                      gender: gender, hairColor: hairColor, birthYear: birthYear,
                      countryOfOrigin: country, rating: rating, tags: tags,
                      createdAt: Date(timeIntervalSince1970: created))
    }

    private func ctx(_ p: EntityProfile?, videos: Int = 0, localPhoto: Bool = false)
        -> ActorFilterCriteria.ActorContext {
        .init(profile: p, videoCount: videos, hasLocalPhoto: localPhoto)
    }

    private var empty: ActorFilterCriteria { ActorFilterCriteria() }

    // MARK: - Default state

    func testAnEmptyFilterMatchesEverything() {
        XCTAssertTrue(empty.isEmpty)
        XCTAssertTrue(empty.matches(actor: "Jane", context: ctx(nil)))
        XCTAssertTrue(empty.matches(actor: "Jane", context: ctx(profile("Jane"))))
    }

    // MARK: - Maintenance filters

    func testMissingPhotosOnlyExcludesBothRemoteAndLocalPhotos() {
        var f = empty; f.showMissingPhotosOnly = true
        XCTAssertTrue(f.matches(actor: "A", context: ctx(profile("A"))), "no photo at all")
        XCTAssertFalse(f.matches(actor: "B", context: ctx(profile("B", photoUrl: "http://x/p.jpg"))),
                       "a remote URL counts as having a photo")
        XCTAssertFalse(f.matches(actor: "C", context: ctx(profile("C"), localPhoto: true)),
                       "a file on disk counts as having a photo")
    }

    func testMissingGenderOnlyTreatsWhitespaceAsMissing() {
        var f = empty; f.showMissingGenderOnly = true
        XCTAssertTrue(f.matches(actor: "A", context: ctx(profile("A", gender: "   "))))
        XCTAssertTrue(f.matches(actor: "B", context: ctx(nil)), "no profile at all is missing gender")
        XCTAssertFalse(f.matches(actor: "C", context: ctx(profile("C", gender: "Female"))))
    }

    func testNeedingAttentionMatchesIfANYOfPhotoBioOrTagsIsMissing() {
        var f = empty; f.showNeedingAttentionOnly = true
        let complete = profile("A", bio: "b", photoUrl: "u", tags: ["t"])
        XCTAssertFalse(f.matches(actor: "A", context: ctx(complete)), "nothing missing")
        XCTAssertTrue(f.matches(actor: "B", context: ctx(profile("B", photoUrl: "u", tags: ["t"]))), "no bio")
        XCTAssertTrue(f.matches(actor: "C", context: ctx(profile("C", bio: "b", tags: ["t"]))), "no photo")
        XCTAssertTrue(f.matches(actor: "D", context: ctx(profile("D", bio: "b", photoUrl: "u"))), "no tags")
    }

    // MARK: - Multi-value fields

    func testCommaSeparatedFieldsMatchAnyOfTheirValues() {
        var f = empty; f.hairColor = "Red"
        // Dyed hair is stored as "Brown, Red".
        XCTAssertTrue(f.matches(actor: "A", context: ctx(profile("A", hairColor: "Brown, Red"))))
        XCTAssertFalse(f.matches(actor: "B", context: ctx(profile("B", hairColor: "Blonde"))))
    }

    func testValueMatchingIsCaseInsensitiveOnBothSides() {
        var f = empty; f.hairColor = "BROWN"
        XCTAssertTrue(f.matches(actor: "A", context: ctx(profile("A", hairColor: "brown"))))
        var g = empty; g.selectedGenders = ["FEMALE"]
        XCTAssertTrue(g.matches(actor: "B", context: ctx(profile("B", gender: "female"))))
    }

    func testEmptyValueFiltersOverrideTheirPairedValueFilter() {
        var f = empty
        f.matchEmptyHairColor = true
        f.hairColor = "Brown"          // ignored while the empty flag is on
        XCTAssertTrue(f.matches(actor: "A", context: ctx(profile("A"))), "no hair colour set")
        XCTAssertFalse(f.matches(actor: "B", context: ctx(profile("B", hairColor: "Brown"))))
    }

    func testMatchEmptyBirthYearIncludesActorsWithNoProfile() {
        var f = empty; f.matchEmptyBirthYear = true
        XCTAssertTrue(f.matches(actor: "A", context: ctx(nil)))
        XCTAssertTrue(f.matches(actor: "B", context: ctx(profile("B"))))
        XCTAssertFalse(f.matches(actor: "C", context: ctx(profile("C", birthYear: 1990))))
    }

    // MARK: - Rating, tags, counts

    func testAnUnratedActorCountsAsZero() {
        var f = empty; f.minRating = 1
        XCTAssertFalse(f.matches(actor: "A", context: ctx(profile("A"))))
        XCTAssertTrue(f.matches(actor: "B", context: ctx(profile("B", rating: 3))))
    }

    func testTagLogicAndRequiresEveryTagWhileOrRequiresOne() {
        var and = empty; and.selectedTags = ["X", "Y"]; and.tagsLogic = .and
        var or = empty;  or.selectedTags  = ["X", "Y"]; or.tagsLogic  = .or
        let onlyX = ctx(profile("A", tags: ["X"]))
        let both  = ctx(profile("B", tags: ["X", "Y", "Z"]))
        XCTAssertFalse(and.matches(actor: "A", context: onlyX))
        XCTAssertTrue(and.matches(actor: "B", context: both))
        XCTAssertTrue(or.matches(actor: "A", context: onlyX))
        XCTAssertTrue(or.matches(actor: "B", context: both))
    }

    func testVideoCountBoundsAreInclusive() {
        var f = empty; f.minVideos = 2; f.maxVideos = 4
        XCTAssertFalse(f.matches(actor: "A", context: ctx(nil, videos: 1)))
        XCTAssertTrue(f.matches(actor: "B", context: ctx(nil, videos: 2)))
        XCTAssertTrue(f.matches(actor: "C", context: ctx(nil, videos: 4)))
        XCTAssertFalse(f.matches(actor: "D", context: ctx(nil, videos: 5)))
    }

    /// Deliberately asymmetric, preserved from the original: a missing age counts
    /// as 0 for the minimum but is EXCLUDED by a maximum.
    func testAgeBoundsTreatAMissingBirthYearAsymmetrically() {
        var lower = empty; lower.minAge = 1
        XCTAssertFalse(lower.matches(actor: "A", context: ctx(profile("A"))), "missing age is 0, below the minimum")
        var upper = empty; upper.maxAge = 200
        XCTAssertFalse(upper.matches(actor: "B", context: ctx(profile("B"))),
                       "missing age is excluded by a maximum rather than treated as 0")
    }

    // MARK: - Search and alpha

    func testSearchIsCaseInsensitiveAndSubstring() {
        let out = empty.apply(to: ["Jane Doe", "Janet", "Bob"], searchText: "jan") { _ in self.ctx(nil) }
        XCTAssertEqual(out, ["Jane Doe", "Janet"])
    }

    func testAlphaFilterMatchesTheFirstLetterCaseInsensitively() {
        let out = empty.apply(to: ["apple", "Avocado", "Banana"], alphaFilter: "A") { _ in self.ctx(nil) }
        XCTAssertEqual(out, ["Avocado", "apple"], "both match; default sort is by name, uppercase first")
    }

    // MARK: - Sorting

    func testDefaultSortIsByNameAscending() {
        let out = empty.apply(to: ["Charlie", "alice", "Bob"]) { _ in self.ctx(nil) }
        XCTAssertEqual(out, ["Bob", "Charlie", "alice"], "plain < on String, so uppercase sorts first")
    }

    func testDescendingReversesEveryMode() {
        var asc = empty; asc.sortBy = .rating
        var desc = empty; desc.sortBy = .rating; desc.sortDescending = true
        let profiles = ["A": profile("A", rating: 1), "B": profile("B", rating: 5), "C": profile("C", rating: 3)]
        func c(_ n: String) -> ActorFilterCriteria.ActorContext { self.ctx(profiles[n]) }
        XCTAssertEqual(asc.apply(to: ["A","B","C"], contextFor: c), ["A","C","B"])
        XCTAssertEqual(desc.apply(to: ["A","B","C"], contextFor: c), ["B","C","A"])
    }

    func testEverySortModeFallsBackToNameOnATie() {
        for mode in ActorFilterCriteria.SortOption.allCases {
            var f = empty; f.sortBy = mode
            // Identical profiles, so the primary key always ties.
            let out = f.apply(to: ["Charlie", "Alice", "Bob"]) { self.ctx(self.profile($0)) }
            XCTAssertEqual(out, ["Alice", "Bob", "Charlie"], "\(mode.rawValue) must tie-break by name")
        }
    }

    func testSortByVideoCountUsesTheSuppliedCounts() {
        var f = empty; f.sortBy = .videoCount
        let counts = ["A": 9, "B": 1, "C": 5]
        let out = f.apply(to: ["A","B","C"]) { self.ctx(nil, videos: counts[$0] ?? 0) }
        XCTAssertEqual(out, ["B","C","A"])
    }

    // MARK: - Whole-pipeline invariants

    func testApplyNeverInventsOrDuplicatesActors() {
        var f = empty; f.minRating = 2
        let profiles = ["A": profile("A", rating: 5), "B": profile("B", rating: 1), "C": profile("C", rating: 3)]
        let out = f.apply(to: ["A","B","C"]) { self.ctx(profiles[$0]) }
        XCTAssertEqual(Set(out).count, out.count, "no duplicates")
        XCTAssertTrue(Set(out).isSubset(of: ["A","B","C"]), "no invented actors")
        XCTAssertEqual(out, ["A","C"])
    }

    func testAnEmptyInputStaysEmptyForEveryMode() {
        for mode in ActorFilterCriteria.SortOption.allCases {
            var f = empty; f.sortBy = mode
            XCTAssertEqual(f.apply(to: []) { _ in self.ctx(nil) }, [])
        }
    }

    // MARK: - Codable (the saved default filter)

    func testDecodingToleratesMissingKeysFromOlderBuilds() throws {
        // A filter saved before the "empty" flags existed must still decode.
        let legacy = #"{"hairColor":"Brown","sortBy":"Name"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ActorFilterCriteria.self, from: legacy)
        XCTAssertEqual(decoded.hairColor, "Brown")
        XCTAssertFalse(decoded.matchEmptyHairColor, "absent key falls back to its default")
        XCTAssertEqual(decoded.sortBy, .name)
    }

    func testRoundTripThroughJSONPreservesEveryField() throws {
        var f = empty
        f.showNeedingAttentionOnly = true
        f.selectedGenders = ["Female"]
        f.selectedTags = ["Redhead"]
        f.tagsLogic = .or
        f.minRating = 4
        f.minAge = 20; f.maxAge = 40
        f.sortBy = .rating; f.sortDescending = true
        let back = try JSONDecoder().decode(ActorFilterCriteria.self, from: JSONEncoder().encode(f))
        XCTAssertEqual(back, f)
    }
}
