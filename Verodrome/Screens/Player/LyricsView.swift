import SwiftUI

struct LyricsView: View {
    @EnvironmentObject private var player: PlayerViewModel

    var body: some View {
        ScrollView {
            Text(player.lyrics.isEmpty ? "No synced lyrics available.\n\nEnjoy the music." : player.lyrics)
                .font(.body)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding()
        }
    }
}
