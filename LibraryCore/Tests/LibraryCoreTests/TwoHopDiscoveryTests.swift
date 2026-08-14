// TwoHopDiscoveryTests.swift
// Connected by a studio, never by a video.
//
// ⚠️ All names invented — this repository is public.

import XCTest
@testable import LibraryCore

final class TwoHopDiscoveryTests: XCTestCase {

    /// `("v1", cast: ["a","b"], studio: "S")`
    private struct Video {
        let id: String
        let cast: [String]
        let studio: String?
    }

    private func analyse(_ videos: [Video],
                         minimumShared: Int = 3) -> TwoHopReport {
        TwoHopDiscovery.analyse(
            videoPerformer: videos.flatMap { v in v.cast.map { GraphEdgePair(from: v.id, to: $0) } },
            videoStudio: videos.compactMap { v in
                v.studio.map { GraphEdgePair(from: v.id, to: $0) }
            },
            thresholds: .init(minimumSharedStudios: minimumShared))
    }

    /// Two performers, three studios in common, never on screen together.
    private func threeSharedStudios(extraFor ann: [String] = [],
                                    extraFor bea: [String] = []) -> [Video] {
        var videos: [Video] = []
        for (i, studio) in ["Northwind", "Lantern", "Meridian"].enumerated() {
            videos.append(Video(id: "a\(i)", cast: ["Ann"], studio: studio))
            videos.append(Video(id: "b\(i)", cast: ["Bea"], studio: studio))
        }
        for (i, studio) in ann.enumerated() {
            videos.append(Video(id: "ax\(i)", cast: ["Ann"], studio: studio))
        }
        for (i, studio) in bea.enumerated() {
            videos.append(Video(id: "bx\(i)", cast: ["Bea"], studio: studio))
        }
        return videos
    }

    // MARK: - The finding

    func testTwoPerformersSharingThreeStudiosAndNoVideoAreFound() {
        let report = analyse(threeSharedStudios())

        XCTAssertEqual(report.neighbours.count, 1)
        XCTAssertEqual(report.neighbours.first?.sharedStudios, 3)
        XCTAssertEqual(report.neighbours.first?.overlap, 1.0,
                       "neither has worked anywhere the other has not")
    }

    /// 🚨 The whole point of the feature: a pair who HAVE appeared together are
    /// already connected, and offering them as a discovery is noise.
    func testAPairThatHasAppearedTogetherIsExcludedAndCounted() {
        var videos = threeSharedStudios()
        videos.append(Video(id: "together", cast: ["Ann", "Bea"], studio: "Northwind"))

        let report = analyse(videos)

        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(report.alreadyCoStarred, 1)
    }

    /// ⚠️ Co-starring counts even when the shared video has no studio at all.
    /// Standing next to someone is standing next to them, attributed or not —
    /// and a version that read co-stars only from studio-bearing videos would
    /// offer a pair the operator has plainly seen together.
    func testAppearingTogetherCountsEvenWithNoStudioOnThatVideo() {
        var videos = threeSharedStudios()
        videos.append(Video(id: "unattributed", cast: ["Ann", "Bea"], studio: nil))

        XCTAssertTrue(analyse(videos).isEmpty)
    }

    // MARK: - 🚨 The threshold, which is the feature

    /// One shared studio is close to universal in a real library — 35,458 such
    /// pairs on the measured drive — so it must not clear the floor.
    func testASingleSharedStudioIsNotAFinding() {
        let videos = [Video(id: "a", cast: ["Ann"], studio: "Northwind"),
                      Video(id: "b", cast: ["Bea"], studio: "Northwind")]

        XCTAssertTrue(analyse(videos).isEmpty)
        XCTAssertEqual(analyse(videos).pairsSharingAStudio, 1,
                       "still counted, so the screen can say what it filtered")
    }

    func testTheFloorIsAdjustable() {
        let videos = [Video(id: "a", cast: ["Ann"], studio: "Northwind"),
                      Video(id: "b", cast: ["Bea"], studio: "Northwind")]

        XCTAssertEqual(analyse(videos, minimumShared: 1).neighbours.count, 1)
    }

    // MARK: - Ranking by exclusivity

    /// ⭐ Three studios out of three is a strong connection; three out of many
    /// is a weak one. The overlap is what tells them apart, and it decides the
    /// order.
    func testAnExclusivePairOutranksAPairWhoWorkEverywhere() {
        var videos = threeSharedStudios()                       // Ann & Bea: exclusive
        // Cal and Dee share the same three, but each works at four more.
        for (i, studio) in ["Northwind", "Lantern", "Meridian"].enumerated() {
            videos.append(Video(id: "c\(i)", cast: ["Cal"], studio: studio))
            videos.append(Video(id: "d\(i)", cast: ["Dee"], studio: studio))
        }
        // ⚠️ DIFFERENT extra studios for each. The first version of this test
        // gave them the same four, which made Cal and Dee share seven studios
        // exclusively — a stronger pair than Ann and Bea, so the assertion
        // failed for a reason that had nothing to do with the ranking rule.
        for (i, studio) in ["W", "X", "Y", "Z"].enumerated() {
            videos.append(Video(id: "cx\(i)", cast: ["Cal"], studio: studio))
        }
        for (i, studio) in ["P", "Q", "R", "S"].enumerated() {
            videos.append(Video(id: "dx\(i)", cast: ["Dee"], studio: studio))
        }

        let found = analyse(videos).neighbours
        let ranked = found.map { [$0.performer, $0.other].sorted().joined(separator: "+") }
        XCTAssertEqual(ranked.first, "Ann+Bea", "the exclusive pair leads")
        XCTAssertTrue(ranked.contains("Cal+Dee"))
        XCTAssertGreaterThan(found.first!.overlap, found.last!.overlap)
    }

    /// The overlap is over the UNION, so a pair sharing three where one works
    /// at six is not reported as fully overlapping.
    func testOverlapIsMeasuredAgainstEverywhereEitherHasWorked() {
        let report = analyse(threeSharedStudios(extraFor: ["Extra1", "Extra2", "Extra3"]))

        let found = try? XCTUnwrap(report.neighbours.first)
        XCTAssertEqual(found?.sharedStudios, 3)
        XCTAssertEqual(found?.overlap ?? 0, 3.0 / 6.0, accuracy: 0.0001)
    }

    // MARK: - Shape

    func testAPerformerIsNeverPairedWithThemselves() {
        let videos = [Video(id: "a1", cast: ["Ann"], studio: "Northwind"),
                      Video(id: "a2", cast: ["Ann"], studio: "Lantern"),
                      Video(id: "a3", cast: ["Ann"], studio: "Meridian")]

        XCTAssertTrue(analyse(videos, minimumShared: 1).isEmpty)
    }

    /// Each pair once, not once per direction.
    func testAPairIsReportedOnce() {
        let report = analyse(threeSharedStudios())

        XCTAssertEqual(report.neighbours.count, 1)
        XCTAssertEqual(report.pairsSharingAStudio, 1)
    }

    func testALibraryWithNoStudioEdgesFindsNothing() {
        let report = analyse([Video(id: "a", cast: ["Ann", "Bea"], studio: nil)],
                             minimumShared: 1)

        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(report.pairsSharingAStudio, 0)
    }
}
