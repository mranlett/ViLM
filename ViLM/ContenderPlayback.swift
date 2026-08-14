// ContenderPlayback.swift
// What one Head to Head card is currently showing, and what it must let go of.
//
// 🚨 THIS EXISTS BECAUSE THE VIEW COULD NOT BE TESTED. On 2026-08-14 the game
// shipped a defect where playing video A and then choosing B left A still
// playing under B's name. The state lived in `@State` inside the card, the
// reset hung off `.onDisappear`, and the card never disappears — both cards
// keep their slot in the board for the whole session, so SwiftUI reuses them.
//
// No test could reach that. A build cannot run SwiftUI's update cycle, and a
// source scan can only assert that some line exists, not that the behaviour is
// right. So the state moved OUT of the view into this object, where the rule
// that failed — **a new contender inherits nothing from the previous one** — is
// one method with tests against it.
//
// ⭐ The general lesson, worth more than the fix: when a view is REUSED rather
// than replaced, every piece of its state outlives its input. Either ask what
// resets each one, or move the state somewhere that can be asked in a test.

import Foundation
import AVFoundation
import CoreGraphics
import Combine

@MainActor
final class ContenderPlayback: ObservableObject {

    /// Non-nil only while this contender is actually playing.
    @Published private(set) var player: AVPlayer?
    /// The contender's stills, sliced from its contact sheet.
    @Published private(set) var frames: [CGImage] = []
    /// Why playback could not start, in the operator's terms.
    @Published private(set) var failure: String?

    /// Which contender this card is currently about.
    private(set) var subject: UUID?

    // MARK: - Changing contender

    /// Points this card at a contender, releasing everything the previous one
    /// owned.
    ///
    /// 🚨 The one rule this type exists to hold: **a new contender inherits
    /// nothing.** Not the player, not the stills, not a failure message.
    ///
    /// ⚠️ Idempotent for the SAME id, and that half matters just as much. This
    /// is called from the view's update path, which runs many times per second
    /// for reasons that have nothing to do with the contender changing — a
    /// version that reset unconditionally would tear the player down constantly
    /// and playback would never survive a single redraw.
    ///
    /// - Returns: whether the subject actually changed.
    @discardableResult
    func retarget(to id: UUID) -> Bool {
        guard subject != id else { return false }
        subject = id
        stop()
        frames = []
        return true
    }

    /// Adopts freshly-sliced stills, but only if they belong to the contender
    /// currently on screen.
    ///
    /// ⚠️ Slicing a contact sheet is asynchronous and the pair advances in the
    /// middle of it. Without this guard a slow load for the OUTGOING contender
    /// lands after the swap and paints its frames onto the incoming one — the
    /// same wrong-contender bug in a quieter form, and one that would look like
    /// a rendering glitch rather than a lifecycle error.
    func adopt(frames loaded: [CGImage], for id: UUID) {
        guard subject == id else { return }
        frames = loaded
    }

    // MARK: - Playing

    /// Starts deliberate, silent playback.
    ///
    /// 🚨 Silent by construction, per D1a: muted AND zero volume. Two
    /// contenders can play at once and two soundtracks compare nothing, so a
    /// later change that clears one of the two still cannot make this screen
    /// audible by accident.
    ///
    /// 🚨 A raw `AVPlayer`, deliberately NOT `VideoPlaybackController`. That
    /// controller mirrors every `isMuted` change into `UserDefaults` so the real
    /// player remembers the operator's preference — muting a preview through it
    /// would reach out and silence the actual player the next time a video was
    /// opened, a setting changed by a screen that never asked about it.
    func play(url: URL?) {
        guard let url else {
            failure = "This video's library is not available."
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            failure = "The file is missing from the library."
            return
        }
        let player = AVPlayer(url: url)
        player.isMuted = true
        player.volume = 0
        self.failure = nil
        self.player = player
        player.play()
    }

    /// Back to stills, and back to decoding nothing.
    ///
    /// ⚠️ Releasing the player is the point, not merely pausing it. The pair
    /// advances every few seconds in this game, and a player kept alive behind
    /// a card nobody is looking at is the battery cost the iOS epic exists to
    /// prevent.
    func stop() {
        player?.pause()
        player = nil
        failure = nil
    }
}
