import SwiftUI

struct DetailHeader: View {
    let title: String
    let subtitle: String
    var artworkURL: String? = nil
    var symbol: String = "music.note"
    var onPlay: () -> Void
    var onShuffle: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            ArtworkView.hero(artworkURL, symbol: symbol)
                .frame(width: 280, height: 280)
                .frame(maxWidth: .infinity)
                .shadow(color: .black.opacity(0.2), radius: 24, y: 12)

            VStack(spacing: 6) {
                Text(title)
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 16) {
                Button(action: onPlay) {
                    // Explicit Image+Text: Label inside .borderedProminent can drop the icon.
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        Text("Play")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(action: onShuffle) {
                    HStack(spacing: 8) {
                        Image(systemName: "shuffle")
                        Text("Shuffle")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}
