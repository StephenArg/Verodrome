import SwiftUI
import VerodromeKit

/// Interactive 5-star rating control (0 = clear).
struct RatingStarsView: View {
    let rating: Int
    var onRate: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    onRate(rating == star ? 0 : star)
                } label: {
                    Image(systemName: star <= rating ? "star.fill" : "star")
                        .foregroundStyle(star <= rating ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityLabel("Rating \(rating) of 5")
    }
}
