// ContenderPlaybackTests.swift
// The tests that would have caught the wrong-video-still-playing defect.
//
// 🚨 On 2026-08-14 the game shipped a card that, on advancing to the next pair,
// took the incoming contender's name and stills while the OUTGOING contender's
// video carried on playing underneath. It passed 62 tests, both platform builds
// and a hand review, and was found within minutes of somebody playing it.
//
// ⚠️ The reason no test caught it is worth stating plainly, because it is the
// reason this file exists: **the state lived in `@State` inside a SwiftUI view,
// and a unit test cannot drive SwiftUI's update cycle.** The bug was not
// missed for want of diligence — it was unreachable. Moving the state into
// `ContenderPlayback` is what made the rule testable, and these are the tests.
//
// Everything below asserts BEHAVIOUR, not the presence of a line of code.

import XCTest
import AVFoundation
import CoreGraphics
@testable import ViLM

@MainActor
final class ContenderPlaybackTests: XCTestCase {

    private var file: URL!

    override func setUpWithError() throws {
        // A real file on disk: `play` refuses a path that does not exist, which
        // is itself one of the behaviours under test. It never has to decode —
        // what is asserted is which player object exists, not what it renders.
        file = FileManager.default.temporaryDirectory
            .appendingPathComponent("contender-\(UUID().uuidString).mp4")
        try Data([0x00]).write(to: file)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: file)
    }

    private func playing(_ id: UUID = UUID()) -> ContenderPlayback {
        let playback = ContenderPlayback()
        playback.retarget(to: id)
        playback.play(url: file)
        return playback
    }

    // MARK: - 🚨 The defect

    /// The reported bug, as an assertion: choose the other contender, and the
    /// one that was playing must stop.
    func testANewContenderStopsThePreviousContendersVideo() {
        let playback = playing()
        XCTAssertNotNil(playback.player, "precondition: it is playing")

        playback.retarget(to: UUID())

        XCTAssertNil(playback.player,
                     "a new contender inherits nothing — least of all a playing video")
    }

    /// ⭐ The other half, and just as important. `retarget` runs from the view's
    /// update path, which fires for reasons that have nothing to do with the
    /// pair changing. A version that reset unconditionally would pass the test
    /// above and make playback impossible — the player would be torn down on
    /// every redraw.
    func testRedrawingTheSameContenderDoesNotInterruptPlayback() {
        let id = UUID()
        let playback = playing(id)

        for _ in 0..<5 { playback.retarget(to: id) }

        XCTAssertNotNil(playback.player, "the same contender keeps playing across redraws")
    }

    /// The quieter form of the same bug: the previous contender's stills must
    /// not be shown under the new one's name either.
    func testANewContenderDoesNotInheritTheStills() {
        let id = UUID()
        let playback = ContenderPlayback()
        playback.retarget(to: id)
        playback.adopt(frames: [Self.pixel()], for: id)
        XCTAssertEqual(playback.frames.count, 1)

        playback.retarget(to: UUID())

        XCTAssertTrue(playback.frames.isEmpty,
                      "stale frames would paint the wrong video under the right name")
    }

    /// 🚨 Slicing a contact sheet is asynchronous and the pair advances in the
    /// middle of it. Stills that arrive late, for a contender who has already
    /// left, must be dropped rather than shown.
    func testStillsArrivingAfterTheContenderChangedAreIgnored() {
        let outgoing = UUID()
        let playback = ContenderPlayback()
        playback.retarget(to: outgoing)
        playback.retarget(to: UUID())            // the pair advances mid-slice

        playback.adopt(frames: [Self.pixel()], for: outgoing)   // the slice lands late

        XCTAssertTrue(playback.frames.isEmpty,
                      "frames belong to the contender they were loaded for, not to whoever is on screen")
    }

    // MARK: - 🚨 D1a — silent, always

    /// The spec promise that nothing on this screen is ever audible. Asserted
    /// because it is a negative property: nothing on screen looks different if
    /// it breaks, and the operator would find out through the speakers.
    func testPlaybackIsSilentByConstruction() {
        let playback = playing()

        XCTAssertEqual(playback.player?.isMuted, true)
        XCTAssertEqual(playback.player?.volume, 0,
                       "muted AND zero volume, so clearing one flag cannot make it audible")
    }

    // MARK: - Refusals

    func testAMissingFileIsReportedAndStartsNothing() {
        let playback = ContenderPlayback()
        playback.retarget(to: UUID())

        playback.play(url: file.appendingPathExtension("gone"))

        XCTAssertNil(playback.player)
        XCTAssertNotNil(playback.failure, "and it says why, rather than showing black")
    }

    func testAnUnavailableLibraryIsReportedAndStartsNothing() {
        let playback = ContenderPlayback()
        playback.retarget(to: UUID())

        playback.play(url: nil)

        XCTAssertNil(playback.player)
        XCTAssertNotNil(playback.failure)
    }

    /// A failure from the previous contender must not follow the next one.
    func testANewContenderClearsThePreviousFailure() {
        let playback = ContenderPlayback()
        playback.retarget(to: UUID())
        playback.play(url: nil)
        XCTAssertNotNil(playback.failure)

        playback.retarget(to: UUID())

        XCTAssertNil(playback.failure)
    }

    private static func pixel() -> CGImage {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }
}
