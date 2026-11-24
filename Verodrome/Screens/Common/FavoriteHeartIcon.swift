import SwiftUI

/// The heart on a favorite toggle. Favoriting squashes it, springs it up large with a
/// wobble, and throws a glow, a ring and a spray of hearts and dots out around it;
/// unfavoriting gives it a quick shrink. Only a change on the same item animates, so a
/// player moving on to a song with a different favorite state just swaps the glyph.
struct FavoriteHeartIcon: View {
    let isFavorite: Bool
    /// What the heart belongs to. When this changes it's a different item, not a toggle.
    let itemID: String
    var font: Font
    var onColor: Color
    var offColor: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var likePulse = 0
    @State private var unlikePulse = 0

    private struct Snapshot: Equatable {
        var itemID: String
        var isFavorite: Bool
    }

    private struct Pose {
        var scale: CGFloat = 1
        var tilt: Double = 0
    }

    var body: some View {
        Image(systemName: isFavorite ? "heart.fill" : "heart")
            .font(font)
            .foregroundStyle(isFavorite ? onColor : offColor)
            // The colour changes outright: the glyph swap and the pop carry the change,
            // and fading from the off colour to the accent passes through a muddy dark.
            .contentTransition(.symbolEffect(.replace))
            .keyframeAnimator(initialValue: Pose(), trigger: likePulse) { content, pose in
                content
                    .scaleEffect(pose.scale)
                    .rotationEffect(.degrees(pose.tilt))
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    // Squash first, so the jump up reads as a spring.
                    CubicKeyframe(0.8, duration: 0.07)
                    SpringKeyframe(1.55, duration: 0.16, spring: .snappy)
                    SpringKeyframe(0.88, duration: 0.14, spring: .snappy)
                    SpringKeyframe(1.1, duration: 0.14, spring: .snappy)
                    SpringKeyframe(1.0, duration: 0.35, spring: .bouncy)
                }
                KeyframeTrack(\.tilt) {
                    LinearKeyframe(0, duration: 0.07)
                    CubicKeyframe(-14, duration: 0.12)
                    CubicKeyframe(10, duration: 0.12)
                    CubicKeyframe(-5, duration: 0.1)
                    SpringKeyframe(0, duration: 0.3, spring: .bouncy)
                }
            }
            .keyframeAnimator(initialValue: 1.0, trigger: unlikePulse) { content, scale in
                content.scaleEffect(scale)
            } keyframes: { _ in
                SpringKeyframe(0.78, duration: 0.1, spring: .snappy)
                SpringKeyframe(1.0, duration: 0.28, spring: .bouncy)
            }
            .background {
                HeartBurst(pulse: likePulse, color: onColor)
            }
            .onChange(of: Snapshot(itemID: itemID, isFavorite: isFavorite)) { old, new in
                guard old.itemID == new.itemID, old.isFavorite != new.isFavorite, !reduceMotion else { return }
                if new.isFavorite {
                    likePulse += 1
                } else {
                    unlikePulse += 1
                }
            }
    }
}

/// A glow, a ring, and ten particles — small hearts between dots — thrown out from behind
/// the heart, fading as they go. Invisible at rest, before and after a run.
private struct HeartBurst: View {
    let pulse: Int
    let color: Color

    private static let particleCount = 10

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            Color.clear
                .keyframeAnimator(initialValue: 0.0, trigger: pulse) { content, progress in
                    content.overlay {
                        burst(size: size, progress: progress)
                    }
                } keyframes: { _ in
                    // Held back until the heart is on its way up out of the squash.
                    LinearKeyframe(0.0, duration: 0.09)
                    LinearKeyframe(1.0, duration: 0.65)
                }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func burst(size: CGFloat, progress: CGFloat) -> some View {
        let isRunning = progress > 0 && progress < 1
        let fade = 1 - progress
        // Fast out, settling at the edge.
        let travel = 1 - (1 - progress) * (1 - progress)
        ZStack {
            Circle()
                .fill(color)
                .frame(width: size * (0.4 + 1.3 * travel), height: size * (0.4 + 1.3 * travel))
                .opacity(0.3 * fade * fade)
                .blur(radius: size * 0.12)
            Circle()
                .stroke(color, lineWidth: max(0.5, size * 0.12 * fade))
                .frame(width: size * (0.5 + 1.6 * travel), height: size * (0.5 + 1.6 * travel))
                .opacity(0.7 * fade)
            ForEach(0..<Self.particleCount, id: \.self) { index in
                let isHeart = index.isMultiple(of: 2)
                let angle = Angle.degrees(Double(index) * 360 / Double(Self.particleCount) - 90)
                // Hearts fly further than the dots between them, so the spray isn't a
                // single flat circle.
                let reach: CGFloat = isHeart ? 1.25 : 0.95
                let distance = size * (0.5 + (reach - 0.5) * travel)
                // Small while still over the heart, full size once clear of it, then
                // shrinking as it fades.
                let scale = min(1, 0.3 + progress * 5) * (1 - 0.55 * progress)
                particle(isHeart: isHeart, size: size, scale: scale, tilt: angle + .degrees(90))
                    .offset(x: cos(angle.radians) * distance, y: sin(angle.radians) * distance)
                    .opacity(min(1, fade * 1.6))
            }
        }
        .opacity(isRunning ? 1 : 0)
    }

    @ViewBuilder
    private func particle(isHeart: Bool, size: CGFloat, scale: CGFloat, tilt: Angle) -> some View {
        if isHeart {
            Image(systemName: "heart.fill")
                .font(.system(size: size * 0.32 * scale))
                .foregroundStyle(color)
                // Leaning outward, the way it was thrown.
                .rotationEffect(tilt * 0.25)
        } else {
            Circle()
                .fill(color)
                .frame(width: size * 0.15 * scale, height: size * 0.15 * scale)
        }
    }
}
