import SwiftUI
import VerodromeKit

/// Interactive 5-star rating control (0 = clear).
/// Supports tap-to-rate and drag-across-stars selection with animated preview.
struct RatingStarsView: View {
    let rating: Int
    /// Glyph point size. Small values keep the row from adding much height.
    var starSize: CGFloat = 17
    var spacing: CGFloat = 4
    var onRate: (Int) -> Void

    @State private var dragRating: Int?
    @State private var dragOriginRating: Int?
    /// True once the finger moves onto a star different from the press origin.
    @State private var didSlideAcrossStars = false
    @State private var rowWidth: CGFloat = 0

    private var displayedRating: Int {
        dragRating ?? rating
    }

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(1...5, id: \.self) { star in
                let filled = star <= displayedRating
                let isHot = dragRating == star
                Image(systemName: filled ? "star.fill" : "star")
                    .font(.system(size: starSize))
                    .foregroundStyle(filled ? Color.yellow : Color.secondary)
                    .scaleEffect(isHot ? 1.22 : 1.0)
                    .shadow(color: isHot ? Color.yellow.opacity(0.45) : .clear, radius: isHot ? 4 : 0)
                    .animation(.spring(response: 0.28, dampingFraction: 0.55), value: displayedRating)
                    .animation(.spring(response: 0.28, dampingFraction: 0.55), value: isHot)
            }
        }
        .padding(.vertical, starSize * 0.15)
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { rowWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, width in
                        rowWidth = width
                    }
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragOriginRating == nil {
                        dragOriginRating = rating
                    }
                    let next = star(at: value.location.x)
                    if next != dragOriginRating {
                        didSlideAcrossStars = true
                    }
                    if dragRating != next {
                        dragRating = next
                    }
                }
                .onEnded { value in
                    let selected = star(at: value.location.x)
                    let origin = dragOriginRating ?? rating
                    // Tap on the current rating clears it. Sliding across stars
                    // always commits the star under the finger.
                    let next = (!didSlideAcrossStars && selected == origin) ? 0 : selected
                    dragRating = nil
                    dragOriginRating = nil
                    didSlideAcrossStars = false
                    if next != rating {
                        onRate(next)
                    }
                }
        )
        .sensoryFeedback(.selection, trigger: displayedRating)
        .accessibilityLabel("Rating \(rating) of 5")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                onRate(min(5, rating + 1))
            case .decrement:
                onRate(max(0, rating - 1))
            @unknown default:
                break
            }
        }
    }

    private func star(at x: CGFloat) -> Int {
        let width = max(rowWidth, CGFloat(5) * starSize + CGFloat(4) * spacing)
        let unit = width / 5
        let index = Int(floor(max(0, min(width - 0.001, x)) / unit)) + 1
        return min(5, max(1, index))
    }
}
