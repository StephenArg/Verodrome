import SwiftUI

/// Lyrics tab of the regular-width inspector. Shares the player's renderer, so
/// timestamped lyrics follow playback and can be tapped to seek here too.
struct LyricsView: View {
    @EnvironmentObject private var player: PlayerViewModel

    var body: some View {
        Group {
            if player.lyricLines.isEmpty {
                VStack(spacing: 8) {
                    Text(player.lyricsLoaded ? "No lyrics available." : "Searching for lyrics…")
                        .font(.body)
                    Text("Enjoy the music.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                SyncedLyricsView(horizontalPadding: 20, alignment: .center)
            }
        }
        .task(id: player.currentItem?.playableId) {
            player.requestLyrics()
        }
    }
}
