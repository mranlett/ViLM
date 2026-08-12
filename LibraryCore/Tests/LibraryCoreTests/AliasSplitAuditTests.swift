import XCTest
@testable import LibraryCore

/// One performer recorded as two profiles.
///
/// 🚨 The damage from the credited-name inversion: the plugin preferred the
/// name a performer was CREDITED under in a scene over their canonical name, so
/// someone who worked under three aliases became three profiles with a split
/// filmography and nothing recording they were one person.
///
/// ⭐ The evidence is already in the data — the surviving profile lists the
/// other one's name in its own `akas`. 43 such pairs on the real library.
final class AliasSplitAuditTests: XCTestCase {

    private func input(_ profiles: [(String, [String])],
                       videos: [String: Int] = [:],
                       matched: Set<String> = [],
                       birthYears: [String: Int] = [:]) -> AliasSplitAudit.Input {
        .init(profiles: profiles.map { (id: "actor:\($0.0)", name: $0.0, akas: $0.1,
                                        isMatched: matched.contains("actor:\($0.0)"),
                                        birthYear: birthYears["actor:\($0.0)"]) },
              videoCounts: Dictionary(uniqueKeysWithValues:
                videos.map { ("actor:\($0.key)", $0.value) }))
    }

    /// 🚨 The claimant's display name is CARRIED, not sliced off the id.
    ///
    /// It used to be derived as `String(id.dropFirst(6))`, which answers a raw
    /// UUID once ids are opaque — and this string is what the merge screen puts
    /// on its "Keep …" buttons, so the operator would be asked to choose
    /// between two uids.
    func testAClaimantKeepsItsNameWhenTheIdIsAUid() {
        let keeperUid = UUID().uuidString
        let aliasUid = UUID().uuidString
        let input = AliasSplitAudit.Input(
            profiles: [
                (id: keeperUid, name: "Marta Venlowe", akas: ["Marti V"],
                 isMatched: true, birthYear: 1990),
                (id: aliasUid, name: "Marti V", akas: [],
                 isMatched: false, birthYear: nil),
            ],
            videoCounts: [keeperUid: 12, aliasUid: 1])

        let found = AliasSplitAudit.findings(input)

        guard let candidate = found.first else {
            return XCTFail("expected the alias split to be detected")
        }
        XCTAssertEqual(candidate.alias.displayName, "Marti V")
        XCTAssertEqual(candidate.claimants.first?.displayName, "Marta Venlowe")
        XCTAssertNotEqual(candidate.alias.displayName, aliasUid,
                          "a uid must never reach the screen as a name")
    }

    // MARK: - Detection

    func testAProfileNamedInAnotherProfilesAliasesIsACandidate() {
        let found = AliasSplitAudit.findings(input([
            ("Venlowe", []),
            ("Marta Venlowe", ["Venlowe"]),
        ]))

        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.alias.displayName, "Venlowe")
        XCTAssertEqual(found.first?.claimants.map(\.displayName), ["Marta Venlowe"])
        XCTAssertFalse(try XCTUnwrap(found.first).isAmbiguous)
    }

    /// An alias naming nobody in the library is not a split — most aliases are
    /// simply extra names, which is the normal case and must stay quiet.
    func testAnAliasWithNoMatchingProfileIsNotACandidate() {
        let found = AliasSplitAudit.findings(input([
            ("Marta Venlowe", ["Venlowe", "Some Other Name"]),
        ]))

        XCTAssertTrue(found.isEmpty)
    }

    /// A profile listing its own name is not a duplicate of itself.
    func testAProfileListingItsOwnNameIsIgnored() {
        let found = AliasSplitAudit.findings(input([("Venlowe", ["Venlowe"])]))

        XCTAssertTrue(found.isEmpty)
    }

    /// Case must not create a second person.
    func testMatchingIsCaseInsensitive() {
        let found = AliasSplitAudit.findings(input([
            ("venlowe", []),
            ("Marta Venlowe", ["VENLOWE"]),
        ]))

        XCTAssertEqual(found.count, 1)
    }

    /// ⚠️ One claimant listing the same alias twice is one claim, not two.
    func testARepeatedAliasCountsOnce() {
        let found = AliasSplitAudit.findings(input([
            ("Venlowe", []),
            ("Marta Venlowe", ["Venlowe", "venlowe", "Venlowe"]),
        ]))

        XCTAssertEqual(found.first?.claimants.count, 1)
        XCTAssertFalse(try! XCTUnwrap(found.first).isAmbiguous)
    }

    // MARK: - ⚠️ Ambiguity, which is real

    /// A real shape from the library under invented names: one alias claimed
    /// by BOTH `Halloway Pike` and `Sable Quintero`. Nothing may be suggested
    /// here — see the note in `AliasSplitAudit` about keeping these invented.
    func testAnAliasClaimedByTwoPerformersIsAmbiguous() {
        let found = AliasSplitAudit.findings(input([
            ("Corvyn", []),
            ("Halloway Pike", ["Corvyn"]),
            ("Sable Quintero", ["Corvyn"]),
        ]))

        let candidate = try! XCTUnwrap(found.first)
        XCTAssertTrue(candidate.isAmbiguous)
        XCTAssertNil(candidate.unambiguousClaimant, "no merge may be proposed")
        XCTAssertEqual(candidate.claimants.count, 2)
    }

    /// Unambiguous ones come first — those are settleable at a glance.
    func testUnambiguousCandidatesSortBeforeAmbiguousOnes() {
        let found = AliasSplitAudit.findings(input([
            ("Corvyn", []), ("Halloway Pike", ["Corvyn"]), ("Sable Quintero", ["Corvyn"]),
            ("Venlowe", []), ("Marta Venlowe", ["Venlowe"]),
        ]))

        XCTAssertEqual(found.map(\.isAmbiguous), [false, true])
    }

    // MARK: - Evidence for the operator

    /// The likeliest home first: confirmed, then the bigger filmography.
    func testAConfirmedClaimantIsRankedAboveAnUnconfirmedOne() {
        let found = AliasSplitAudit.findings(
            input([("Corvyn", []), ("Sable Quintero", ["Corvyn"]), ("Halloway Pike", ["Corvyn"])],
                  videos: ["Sable Quintero": 40],
                  matched: ["actor:Halloway Pike"]))

        XCTAssertEqual(found.first?.claimants.first?.displayName, "Halloway Pike",
                       "confirmed outranks a larger unconfirmed filmography")
    }

    func testMergeValueCountsVideosFromBothHalves() {
        let found = AliasSplitAudit.findings(
            input([("Venlowe", []), ("Marta Venlowe", ["Venlowe"])],
                  videos: ["Venlowe": 3, "Marta Venlowe": 11]))

        XCTAssertEqual(found.first?.combinedVideos, 14)
    }

    /// The ones reuniting the most work come first among equals.
    func testCandidatesSortByHowMuchAMergeWouldReunite() {
        let found = AliasSplitAudit.findings(
            input([("A", []), ("Big A", ["A"]), ("B", []), ("Big B", ["B"])],
                  videos: ["A": 1, "Big A": 2, "B": 20, "Big B": 30]))

        XCTAssertEqual(found.map(\.alias.displayName), ["B", "A"])
    }

    /// Nothing here merges anything — it reports.
    func testAnEmptyLibraryProducesNothing() {
        XCTAssertTrue(AliasSplitAudit.findings(input([])).isEmpty)
    }
}
