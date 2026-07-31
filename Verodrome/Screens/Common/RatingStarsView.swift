import SwiftUI
import VerodromeKit

/// Interactive 5-star rating control (0 = clear).
struct RatingStarsView: View {
    let rating: Int
    /// Glyph point size. Small values keep the row from adding much height.
    var starSize: CGFloat = 17
    var spacing: CGFloat = 4
    var onRate: (Int) -> Void

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    onRate(rating == star ? 0 : star)
                } label: {
                    Image(systemName: star <= rating ? "star.fill" : "star")
                        .font(.system(size: starSize))
                        .foregroundStyle(star <= rating ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityLabel("Rating \(rating) of 5")
    }
}
