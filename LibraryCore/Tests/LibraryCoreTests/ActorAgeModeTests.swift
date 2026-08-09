// ActorAgeModeTests.swift
// R2's age control: one range, and the filter says which age it means.
//
// ⭐ The operator's reasoning: "A person may have been 20 when they started,
// 22 at the time of filming the video in question, and 47 today. All three
// data points may be interesting." They answer different questions, so the
// range has to say which one it is asking.

import XCTest
@testable import LibraryCore

final class ActorAgeModeTests: XCTestCase {

    // MARK: - The mode travels with a saved filter

    /// 🚨 A filter saved before the mode existed meant CURRENT age — that was
    /// the only thing it could mean. Decoding it as anything else would
    /// silently change what every existing smart collection returns.
    func testAFilterSavedBeforeTheModeExistedStillMeansCurrentAge() throws {
        let legacy = """
        {"minAge":18,"maxAge":30,"sortBy":"Name","sortDescending":false,\
        "tagsLogic":"AND","selectedTags":[],"selectedGenders":[],\
        "hairColor":"","country":"","enrichment":"any",\
        "showMissingPhotosOnly":false,"showMissingGenderOnly":false,\
        "showNeedingAttentionOnly":false,"matchEmptyHairColor":false,\
        "matchEmptyCountry":false,"matchEmptyBirthYear":false}
        """
        let decoded = try JSONDecoder().decode(ActorFilterCriteria.self,
                                               from: Data(legacy.utf8))

        XCTAssertEqual(decoded.ageMode, .current)
        XCTAssertEqual(decoded.minAge, 18)
        XCTAssertEqual(decoded.maxAge, 30)
    }

    /// ⭐ And the mode survives a round trip, which is what "the mode is stored
    /// with the filter, so meaning travels with it" actually requires.
    func testTheModeSurvivesEncodingAndDecoding() throws {
        var criteria = ActorFilterCriteria()
        criteria.ageMode = .atCareerStart
        criteria.minAge = 18
        criteria.maxAge = 22

        let round = try JSONDecoder().decode(
            ActorFilterCriteria.self,
            from: try JSONEncoder().encode(criteria))

        XCTAssertEqual(round.ageMode, .atCareerStart)
        XCTAssertEqual(round.minAge, 18)
        XCTAssertEqual(round.maxAge, 22)
    }

    /// ⚠️ The mode alone is not a filter. Selecting a measure without a range
    /// must not make an empty filter look active — that would hide videos with
    /// no visible cause.
    func testChoosingAModeWithoutARangeIsStillAnEmptyFilter() {
        var criteria = ActorFilterCriteria()
        criteria.ageMode = .atCareerStart

        XCTAssertTrue(criteria.isEmpty)
    }

    // MARK: - The two ages are genuinely different questions

    /// The case the whole control exists for: someone who started at 20 and is
    /// 47 today is matched by one mode and not the other.
    func testTheSamePersonAnswersDifferentlyUnderEachMode() {
        var profile = EntityProfile(id: "actor:Marta Venlowe")
        profile.birthYear = 1979
        profile.careerStartYear = 1999

        XCTAssertEqual(profile.careerStartAge, 20, "started at 20")
        let now = Calendar(identifier: .gregorian).component(.year, from: Date())
        XCTAssertEqual(profile.age, now - 1979, "and is much older today")
        XCTAssertNotEqual(profile.age, profile.careerStartAge,
                          "if these were equal the fixture would prove nothing")
    }

    /// ⚠️ An actor the chosen mode cannot answer for has NO age under it —
    /// not zero. The old filter read `(age ?? 0) >= minAge`, which admitted
    /// every actor with no birth year into an "18 and over" filter.
    func testAnActorWithNoCareerStartHasNoAgeUnderThatMode() {
        var profile = EntityProfile(id: "actor:Unknown Start")
        profile.birthYear = 1990

        XCTAssertNotNil(profile.age, "current age is known")
        XCTAssertNil(profile.careerStartAge, "career start is not")
    }

    /// A correction to the birth year corrects the derived age too, which is
    /// why `careerStartAge` derives on read rather than being stored.
    func testCorrectingTheBirthYearCorrectsTheDerivedCareerAge() {
        var profile = EntityProfile(id: "actor:Marta Venlowe")
        profile.careerStartYear = 2000
        profile.birthYear = 1980
        XCTAssertEqual(profile.careerStartAge, 20)

        profile.birthYear = 1978
        XCTAssertEqual(profile.careerStartAge, 22, "the derived value follows the fix")
    }

    /// ⭐ A source-stated age wins over the derived one — it is evidence
    /// rather than arithmetic.
    func testAStatedCareerStartAgeWinsOverTheDerivedOne() {
        var profile = EntityProfile(id: "actor:Marta Venlowe")
        profile.careerStartYear = 2000
        profile.birthYear = 1980
        profile.ageAtCareerStart = 19

        XCTAssertEqual(profile.careerStartAge, 19)
    }
}
