import SwiftUI
import AVKit

struct PlayerPopoutView: View {
    let title: String
    let player: AVPlayer

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.headline)
                .lineLimit(1)

            PlayerView(player: player)
                .frame(minWidth: 640, minHeight: 360)
        }
        .padding()
    }
}
