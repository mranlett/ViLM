import Foundation
import Combine
import AVFoundation

@MainActor
final class PlaybackCoordinator: ObservableObject {
    @Published var isShowingPlayer: Bool = false
    @Published var title: String = ""

    let playback = VideoPlaybackController()

    func play(url: URL, at seconds: Double, title: String) {
        self.title = title
        self.isShowingPlayer = true
        playback.load(url: url, startSeconds: seconds, autoplay: true)
    }

    func stop() {
        playback.player.pause()
        isShowingPlayer = false
    }
}
