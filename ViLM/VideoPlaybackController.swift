// VideoPlaybackController.swift
// Observable AVPlayer wrapper: loads an item, defers seeks until the item is
// ready (early seeks get ignored by AVFoundation), clamps to duration, and
// persists the mute preference.

import Foundation
import AVFoundation
import AVKit
import Observation

@MainActor
@Observable
final class VideoPlaybackController {
    let player = AVPlayer()

    private var statusObservation: NSKeyValueObservation?
    private var muteObservation: NSKeyValueObservation?
    private var pendingSeekSeconds: Double?
    private var pendingAutoplay: Bool = true

    init() {
        player.isMuted = UserDefaults.standard.bool(forKey: "playerIsMuted")
        muteObservation = player.observe(\.isMuted, options: [.new]) { player, _ in
            UserDefaults.standard.set(player.isMuted, forKey: "playerIsMuted")
        }
    }

    func load(url: URL, startSeconds: Double, autoplay: Bool = true) {
        pendingSeekSeconds = startSeconds
        pendingAutoplay = autoplay

        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)

        // Wait until ready before seeking, otherwise seeks often get ignored
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard let self else { return }
            Task { @MainActor in
                switch item.status {
                case .readyToPlay:
                    await self.applyPendingSeekIfNeeded()
                case .failed:
                    print("AVPlayerItem failed: \(item.error?.localizedDescription ?? "unknown error")")
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }
    }

    func seek(to seconds: Double, autoplay: Bool? = nil) async {
        pendingSeekSeconds = seconds
        if let autoplay { pendingAutoplay = autoplay }
        await applyPendingSeekIfNeeded()
    }

    private func applyPendingSeekIfNeeded() async {
        guard let item = player.currentItem else { return }
        guard item.status == .readyToPlay else { return }
        guard let seconds = pendingSeekSeconds else { return }

        // Clamp to duration if known
        let dur = item.duration
        let durSeconds = dur.isNumeric ? dur.seconds : .infinity
        let safeSeconds = max(0, min(seconds, durSeconds.isFinite ? (durSeconds - 0.25) : seconds))

        player.pause()

        let target = CMTime(seconds: safeSeconds, preferredTimescale: 600)

        await withCheckedContinuation { cont in
            player.seek(
                to: target,
                toleranceBefore: CMTime(seconds: 0.03, preferredTimescale: 600),
                toleranceAfter:  CMTime(seconds: 0.03, preferredTimescale: 600)
            ) { _ in
                cont.resume()
            }
        }

        if pendingAutoplay {
            player.play()
        }

        // Clear the one-shot seek request — but only if it's still OURS. A
        // second seek can land while this one awaits AVPlayer (both run on
        // the MainActor, but they interleave across the suspension), and an
        // unconditional clear would silently drop it (DEFECT_INVENTORY L1).
        if pendingSeekSeconds == seconds {
            pendingSeekSeconds = nil
        }
    }
}

private extension CMTime {
    var isNumeric: Bool {
        flags.contains(.valid)
        && !flags.contains(.indefinite)
        && !flags.contains(.positiveInfinity)
        && !flags.contains(.negativeInfinity)
    }
}
