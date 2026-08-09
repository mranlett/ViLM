// SourceGapAuditTests.swift
// What else is this performer in? (#39, #40 — W1–W6)
//
// 🚨 W3 is the one that would be invisible in production. Comparing scene ids
// across two sources marks a scene as "already held" because an unrelated
// provider happens to use the same id — a FALSE NEGATIVE, so the list simply
// comes back shorter and nothing looks wrong.
//
// ⚠️ And W6 is its twin: a truncated source answer under-reports, which reads
// as good news. Both failure modes make the feature look like it is working.

import XCTest
@testable import LibraryCore

final class SourceGapAuditTests: XCTestCase {

    private func scene(_ id: String, _ title: String = "A Scene") -> SourceGap {
        SourceGap(sourceId: id, title: title)
    }

    private func match(_ sourceId: String, source: String = "TheSource") -> NodeMatch {
        NodeMatch(nodeId: UUID().uuidString, source: source, sourceId: sourceId,
                  method: .title, matchedAt: Date())
    }

    private func report(scenes: [SourceGap], matches: [NodeMatch],
                        local: Int = 3, identified: Int = 3,
                        truncated: Bool = false) -> SourceGapReport {
        SourceGapAudit.report(sourceScenes: scenes, source: "TheSource",
                              localMatches: matches, localVideos: local,
                              identifiedLocalVideos: identified, truncated: truncated)
    }

    // MARK: - W1/W2 — the diff itself

    func testW1ASceneAlreadyHeldIsNotReported() {
        let r = report(scenes: [scene("s1"), scene("s2")], matches: [match("s1")])
        XCTAssertEqual(r.gaps.map(\.sourceId), ["s2"])
    }

    func testW2ASceneNotHeldIsReported() {
        let r = report(scenes: [scene("s1")], matches: [])
        XCTAssertEqual(r.gaps.map(\.sourceId), ["s1"])
    }

    func testTheSourcesOrderIsPreserved() {
        let r = report(scenes: [scene("c"), scene("a"), scene("b")], matches: [])
        XCTAssertEqual(r.gaps.map(\.sourceId), ["c", "a", "b"],
                       "the source ordered them; re-sorting would discard that")
    }

    /// ⚠️ A source listing one scene twice must not produce two gaps.
    func testARepeatedSceneIsReportedOnce() {
        let r = report(scenes: [scene("s1"), scene("s1")], matches: [])
        XCTAssertEqual(r.gaps.count, 1)
    }

    // MARK: - 🚨 W3 — never across sources

    /// The invisible failure. An id from a different provider marks a scene as
    /// held, so the gap silently disappears and the list looks fine.
    func testW3AMatchFromADifferentSourceIsNeverTreatedAsHeld() {
        let r = report(scenes: [scene("s1")],
                       matches: [match("s1", source: "SomeOtherProvider")])

        XCTAssertEqual(r.gaps.map(\.sourceId), ["s1"],
                       "another provider's id namespace says nothing about this one")
    }

    func testOnlyTheMatchingSourceSuppresses() {
        let r = report(scenes: [scene("s1"), scene("s2")],
                       matches: [match("s1"), match("s2", source: "Elsewhere")])
        XCTAssertEqual(r.gaps.map(\.sourceId), ["s2"])
    }

    // MARK: - 🔴 W4 — per-actor confidence

    func testW4AFullyIdentifiedFilmographyGivesAnExactList() {
        let r = report(scenes: [scene("s1")], matches: [], local: 9, identified: 9)

        XCTAssertTrue(r.isExact)
        XCTAssertEqual(r.possiblyAlreadyHeld, 0)
        XCTAssertTrue(r.confidence.contains("exact"), r.confidence)
        XCTAssertTrue(r.confidence.contains("All 9"), r.confidence)
    }

    func testW4APartlyIdentifiedFilmographyBoundsTheDoubt() {
        let r = report(scenes: [scene("s1"), scene("s2"), scene("s3"), scene("s4")],
                       matches: [], local: 9, identified: 6)

        XCTAssertFalse(r.isExact)
        XCTAssertEqual(r.possiblyAlreadyHeld, 3)
        XCTAssertTrue(r.confidence.contains("up to 3"), r.confidence)
        XCTAssertTrue(r.confidence.contains("4 scenes"), r.confidence)
    }

    /// ⚠️ The doubt cannot exceed the number of gaps. Six unidentified videos
    /// against two gaps is still at most two that might be wrong — claiming six
    /// would be its own kind of false.
    func testTheDoubtIsBoundedByTheNumberOfGaps() {
        let r = report(scenes: [scene("s1"), scene("s2")],
                       matches: [], local: 10, identified: 4)

        XCTAssertEqual(r.possiblyAlreadyHeld, 2)
        XCTAssertTrue(r.confidence.contains("up to 2"), r.confidence)
    }

    // MARK: - 🚨 W5 — no basis is not an answer

    /// The source's whole filmography coming back as "missing" is the question
    /// restated, not an answer to it.
    func testW5AnActorWithNoIdentifiedVideosIsToldThereIsNoBasis() {
        let r = report(scenes: [scene("s1"), scene("s2")],
                       matches: [], local: 7, identified: 0)

        XCTAssertTrue(r.hasNoBasis)
        XCTAssertTrue(r.confidence.contains("nothing to compare against"), r.confidence)
        XCTAssertTrue(r.confidence.contains("Match some of them first"), r.confidence)
    }

    /// ⚠️ A performer with no local videos at all is NOT the same case. There
    /// is nothing to be uncertain about — everything the source lists is
    /// genuinely absent.
    func testAPerformerWithNoLocalVideosIsExactRatherThanBaseless() {
        let r = report(scenes: [scene("s1")], matches: [], local: 0, identified: 0)

        XCTAssertFalse(r.hasNoBasis)
        XCTAssertTrue(r.isExact)
    }

    // MARK: - ⚠️ W6 — truncation is a distinct outcome

    func testW6ATruncatedAnswerIsCarriedThrough() {
        let r = report(scenes: [scene("s1")], matches: [], truncated: true)
        XCTAssertTrue(r.sourceTruncated,
                      "a capped list under-reports, and fewer results looks like good news")
    }

    func testAnUntruncatedEmptyResultSaysNothingIsMissing() {
        let r = report(scenes: [scene("s1")], matches: [match("s1")])
        XCTAssertTrue(r.gaps.isEmpty)
        XCTAssertFalse(r.sourceTruncated)
        XCTAssertTrue(r.confidence.contains("Nothing the source lists is missing"), r.confidence)
    }

    // MARK: - Defensive

    /// ⚠️ Identified cannot exceed total. A caller with a stale count would
    /// otherwise produce a negative doubt and a nonsense sentence.
    func testAnIdentifiedCountAboveTheTotalIsClamped() {
        let r = report(scenes: [scene("s1")], matches: [], local: 2, identified: 99)
        XCTAssertEqual(r.possiblyAlreadyHeld, 0)
        XCTAssertTrue(r.isExact)
    }

    func testNoSourceScenesIsNotAnError() {
        let r = report(scenes: [], matches: [])
        XCTAssertTrue(r.gaps.isEmpty)
    }
}
