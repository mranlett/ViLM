// StudioOverlapTests.swift
// Telling two performers of one name apart by the studios they work for.
//
// ⭐ The properties worth reading twice are S8–S10: this must never claim more
// than it knows. It annotates a row a person is already reading; it does not
// choose. A test suite that only checked "finds the overlap" would be happy
// with something far more confident than the data supports.

import XCTest
@testable import LibraryCore

final class StudioOverlapTests: XCTestCase {

    private func asset(actors: [String], studios: [String]) -> Asset {
        Asset(relativePath: "\(UUID()).mp4", fileName: "a.mp4",
              tags: actors.map { "actor:\($0)" } + studios.map { "studio:\($0)" })
    }

    private func scene(studio: String?) -> PluginCandidate {
        PluginCandidate(id: UUID().uuidString, title: "A Scene", studioName: studio)
    }

    private func index(_ profiles: [EntityProfile] = []) -> EntityProfileIndex {
        EntityProfileIndex(profiles)
    }

    // MARK: - The local side

    func testAnActorsStudiosComeFromTheirVideos() {
        let assets = [asset(actors: ["Alice Example"], studios: ["Silver River"]),
                      asset(actors: ["Alice Example"], studios: ["Coast Line"]),
                      asset(actors: ["Bob Example"], studios: ["Harbour Lane"])]

        XCTAssertEqual(StudioOverlap.localStudios(for: "Alice Example",
                                                  assets: assets, profiles: index()),
                       ["Silver River", "Coast Line"])
    }

    /// S2 — ⚠️ credits through AKAs, matching `ActorVideoCounts`. A card
    /// reading "12 videos" beside an overlap drawn from a different set of
    /// videos is a contradiction the operator cannot resolve.
    func testAnAliasCreditsTheSamePerformer() {
        var profile = EntityProfile(id: UUID().uuidString, entityType: "actor",
                                    displayName: "Alice Example")
        profile.akas = ["Ali E"]
        let assets = [asset(actors: ["Ali E"], studios: ["Silver River"])]

        XCTAssertEqual(StudioOverlap.localStudios(for: "Alice Example",
                                                  assets: assets, profiles: index([profile])),
                       ["Silver River"])
    }

    func testAnActorWithNoVideosHasNoStudios() {
        XCTAssertTrue(StudioOverlap.localStudios(for: "Nobody",
                                                 assets: [asset(actors: ["Alice Example"],
                                                                studios: ["Silver River"])],
                                                 profiles: index()).isEmpty)
    }

    /// S4 — an empty name must not match every untagged video.
    func testAnEmptyNameMatchesNothing() {
        XCTAssertTrue(StudioOverlap.localStudios(for: "", assets: [asset(actors: [""],
                                                                        studios: ["X"])],
                                                 profiles: index()).isEmpty)
    }

    // MARK: - The comparison

    func testASharedStudioIsFound() {
        let shared = StudioOverlap.shared(local: ["Silver River", "Coast Line"],
                                          works: [scene(studio: "Coast Line"),
                                                  scene(studio: "Elsewhere")])
        XCTAssertEqual(shared, ["Coast Line"])
    }

    /// S6 — ⚠️ folded the way the rest of the studio code folds. `Silver River`
    /// and `silver-river` are one company; a comparison saying otherwise
    /// reports no overlap for a pair that plainly matches.
    func testSpellingDifferencesStillMatch() {
        XCTAssertEqual(StudioOverlap.shared(local: ["Silver River"],
                                            works: [scene(studio: "silver-river")]),
                       ["Silver River"],
                       "and reported in the operator's own spelling")
    }

    func testNoSharedStudioIsAnEmptyResult() {
        XCTAssertTrue(StudioOverlap.shared(local: ["Silver River"],
                                           works: [scene(studio: "Coast Line")]).isEmpty)
    }

    // MARK: - 🚨 Claiming no more than it knows

    /// S8 — a candidate whose scenes carry no studio produces NO annotation,
    /// not a negative one. The source not publishing a studio is at least as
    /// likely as the person being wrong, and a row saying "no shared studios"
    /// would read as evidence the data does not support.
    func testACandidateWithNoStudioDataSaysNothing() {
        XCTAssertNil(StudioOverlap.annotation(local: ["Silver River"],
                                              works: [scene(studio: nil),
                                                      scene(studio: "")]))
    }

    /// S9 — and neither does a library that knows no studios for this actor.
    func testNoLocalStudiosSaysNothing() {
        XCTAssertNil(StudioOverlap.annotation(local: [],
                                              works: [scene(studio: "Silver River")]))
    }

    /// S10 — ⚠️ the note names the studio. "Shares a studio" would be a claim
    /// the operator cannot check; naming it lets them disagree.
    func testTheNoteNamesTheStudio() {
        let note = StudioOverlap.annotation(local: ["Silver River"],
                                            works: [scene(studio: "Silver River")])
        XCTAssertEqual(note, "Also in your library: Silver River")
    }

    func testManySharedStudiosAreSummarised() {
        let names = ["Alpha", "Beta", "Delta", "Gamma", "Omega"]
        let note = StudioOverlap.annotation(local: Set(names),
                                            works: names.map { scene(studio: $0) })
        XCTAssertEqual(note, "Also in your library: Alpha, Beta, Delta +2")
    }

    /// S12 — deterministic. The local set is a `Set`, whose iteration order
    /// varies between runs; a note that reordered itself on every open would
    /// look like the data had changed.
    func testTheNoteIsStableAcrossRuns() {
        let local: Set<String> = ["Gamma", "Alpha", "Beta"]
        let works = [scene(studio: "Alpha"), scene(studio: "Beta"), scene(studio: "Gamma")]
        let first = StudioOverlap.annotation(local: local, works: works)
        for _ in 0..<20 {
            XCTAssertEqual(StudioOverlap.annotation(local: local, works: works), first)
        }
        XCTAssertEqual(first, "Also in your library: Alpha, Beta, Gamma")
    }

    /// S13 — a studio listed twice in the works is one shared studio, not two.
    func testARepeatedStudioIsCountedOnce() {
        XCTAssertEqual(StudioOverlap.shared(local: ["Silver River"],
                                            works: [scene(studio: "Silver River"),
                                                    scene(studio: "silver river")]),
                       ["Silver River"])
    }

    // MARK: - 🚨 The discriminating case this exists for

    /// S14 — the whole point, end to end. Two candidates of one name; only one
    /// has worked with a studio this library knows. The annotation appears on
    /// exactly one of them, which is what lets a person choose.
    func testOnlyTheCandidateSharingAStudioIsAnnotated() {
        let assets = [asset(actors: ["Vera Example"], studios: ["Silver River"]),
                      asset(actors: ["Vera Example"], studios: ["Coast Line"])]
        let local = StudioOverlap.localStudios(for: "Vera Example", assets: assets,
                                               profiles: index())

        let right = [scene(studio: "Silver River"), scene(studio: "Somewhere Else")]
        let wrong = [scene(studio: "Harbour Lane"), scene(studio: "Another Place")]

        XCTAssertNotNil(StudioOverlap.annotation(local: local, works: right))
        XCTAssertNil(StudioOverlap.annotation(local: local, works: wrong))
    }

    /// S15 — ⚠️ and when BOTH share a studio it annotates both, rather than
    /// picking. That is the 7.1% of same-name pairs whose studio sets overlap,
    /// and it is precisely the case where an automatic tie-break would guess.
    /// Showing both says "this does not separate them", which is true.
    func testWhenBothCandidatesShareAStudioBothAreAnnotated() {
        let local: Set<String> = ["Silver River"]
        let a = [scene(studio: "Silver River")]
        let b = [scene(studio: "Silver River"), scene(studio: "Elsewhere")]

        XCTAssertNotNil(StudioOverlap.annotation(local: local, works: a))
        XCTAssertNotNil(StudioOverlap.annotation(local: local, works: b))
    }
}
