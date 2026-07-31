import SwiftUI

struct PlaceholderArtwork: View {
    var symbol: String = "music.note"

    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [Color.secondary.opacity(0.35), Color.secondary.opacity(0.15)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
