import SwiftUI

struct PlaceholderArtwork: View {
    var symbol: String = "music.note"

    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.18))
            .overlay {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
