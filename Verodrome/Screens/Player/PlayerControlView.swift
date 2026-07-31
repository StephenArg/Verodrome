import SwiftUI
import VerodromeKit

struct PlayerControlView: View {
    @EnvironmentObject private var player: PlayerViewModel
    @EnvironmentObject private var progress: PlayerProgressModel

    /// Match Spotify-style control row proportions from the reference.
    private let playDiameter: CGFloat = 72
    private let skipIconSize: CGFloat = 28
    private let sideIconSize: CGFloat = 22
    private let controlSpacing: CGFloat = 36

    var body: some View {
        VStack(spacing: 24) {
            if player.currentItem?.isLiveStream == true {
                Text("LIVE")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, VerodromeTheme.playerContentHorizontalPadding)
            } else {
                SeekableTimeSlider(
                    currentTime: progress.currentTime,
                    duration: progress.duration,
                    onSeek: { player.seek(to: $0) }
                )
                .padding(.horizontal, VerodromeTheme.playerContentHorizontalPadding)

                HStack {
                    Text(formatTime(progress.currentTime))
                    Spacer()
                    Text("-\(formatTime(max(0, progress.duration - progress.currentTime)))")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, VerodromeTheme.playerContentHorizontalPadding)
            }

            HStack(spacing: controlSpacing) {
                shuffleButton
                skipButton(direction: .backward, action: player.skipBackward)
                playButton
                skipButton(direction: .forward, action: player.skipForward)
                repeatButton
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Controls

    /// White circle with play/pause cut out so the dark background shows through.
    private var playButton: some View {
        Button { player.playPause() } label: {
            ZStack {
                Circle()
                    .fill(Color.white)
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: playDiameter * 0.38, weight: .bold))
                    .offset(x: player.isPlaying ? 0 : 2)
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
            .frame(width: playDiameter, height: playDiameter)
            .contentTransition(.symbolEffect(.replace))
        }
        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
    }

    private func skipButton(direction: SkipControlIcon.Direction, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            SkipControlIcon(direction: direction)
                .frame(width: skipIconSize + 4, height: skipIconSize)
                .frame(width: skipIconSize + 12, height: playDiameter)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(direction == .backward ? "Previous" : "Next")
        .disabled(player.currentItem?.isLiveStream == true)
        .opacity(player.currentItem?.isLiveStream == true ? 0.35 : 1)
    }

    private var shuffleButton: some View {
        let isOn = player.shuffleMode == .on
        return Button { player.toggleShuffle() } label: {
            VStack(spacing: 5) {
                ShuffleControlIcon()
                    .frame(width: sideIconSize + 8, height: sideIconSize)
                    .foregroundStyle(isOn ? Color.accentColor : Color.white)
                // Active-state green dot (Spotify-style).
                Circle()
                    .fill(isOn ? Color.accentColor : Color.clear)
                    .frame(width: 4, height: 4)
            }
            .frame(width: sideIconSize + 16, height: playDiameter)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Shuffle")
        .disabled(player.currentItem?.isLiveStream == true)
        .opacity(player.currentItem?.isLiveStream == true ? 0.35 : 1)
    }

    private var repeatButton: some View {
        let isOn = player.repeatMode != .off
        return Button { player.toggleRepeat() } label: {
            VStack(spacing: 5) {
                RepeatControlIcon(mode: player.repeatMode)
                    .frame(width: sideIconSize + 6, height: sideIconSize - 2)
                    .foregroundStyle(isOn ? Color.accentColor : Color.white)
                // Keep height aligned with shuffle's optional dot.
                Circle()
                    .fill(isOn ? Color.accentColor : Color.clear)
                    .frame(width: 4, height: 4)
            }
            .frame(width: sideIconSize + 16, height: playDiameter)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(repeatAccessibilityLabel)
        .disabled(player.currentItem?.isLiveStream == true)
        .opacity(player.currentItem?.isLiveStream == true ? 0.35 : 1)
    }

    private var repeatAccessibilityLabel: String {
        switch player.repeatMode {
        case .off: "Repeat Off"
        case .all: "Repeat All"
        case .one: "Repeat One"
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let clamped = max(0, time)
        return String(format: "%d:%02d", Int(clamped) / 60, Int(clamped) % 60)
    }
}

// MARK: - Repeat icon (rounded loop + arrow)

/// Spotify-style repeat loop. Off = white; on (.all) = accent; .one = accent with
/// a top-edge cutout containing a small "1".
struct RepeatControlIcon: View {
    var mode: RepeatMode
    var lineWidthFraction: CGFloat = 0.12

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let lineWidth = max(1.6, min(w, h) * lineWidthFraction)
            let inset = lineWidth / 2
            let corner = min(w, h) * 0.42
            let rect = CGRect(
                x: inset,
                y: inset,
                width: w - lineWidth,
                height: h - lineWidth
            )
            let showOne = mode == .one
            let topGapHalf = w * 0.13
            let stroke = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            let tipX = rect.minX + corner * 0.35
            let arrowDepth = w * 0.16

            ZStack {
                loopPath(
                    rect: rect,
                    corner: corner,
                    topGapHalf: showOne ? topGapHalf : 0,
                    bottomEndX: tipX + arrowDepth
                )
                .stroke(style: stroke)

                arrowhead(
                    tip: CGPoint(x: tipX, y: rect.maxY),
                    halfH: lineWidth * 1.15,
                    depth: arrowDepth
                )

                if showOne {
                    Text("1")
                        .font(.system(size: h * 0.40, weight: .bold, design: .rounded))
                        .offset(y: -h * 0.02)
                }
            }
        }
        .aspectRatio(1.35, contentMode: .fit)
    }

    /// Clockwise rounded-rect loop. Bottom edge stops at `bottomEndX` (arrow base).
    /// When `topGapHalf > 0`, the top edge has a center cutout for the "1".
    private func loopPath(rect: CGRect, corner: CGFloat, topGapHalf: CGFloat, bottomEndX: CGFloat) -> Path {
        var p = Path()
        let r = min(corner, min(rect.width, rect.height) / 2)

        p.move(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.minY + r),
            radius: r,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )

        if topGapHalf > 0 {
            let midX = rect.midX
            p.addLine(to: CGPoint(x: midX - topGapHalf, y: rect.minY))
            p.move(to: CGPoint(x: midX + topGapHalf, y: rect.minY))
        }
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.minY + r),
            radius: r,
            startAngle: .degrees(270),
            endAngle: .degrees(0),
            clockwise: false
        )

        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
            radius: r,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )

        p.addLine(to: CGPoint(x: bottomEndX, y: rect.maxY))
        return p
    }

    private func arrowhead(tip: CGPoint, halfH: CGFloat, depth: CGFloat) -> some View {
        Path { p in
            p.move(to: tip)
            p.addLine(to: CGPoint(x: tip.x + depth, y: tip.y - halfH))
            p.addLine(to: CGPoint(x: tip.x + depth, y: tip.y + halfH))
            p.closeSubpath()
        }
        .fill()
    }
}

// MARK: - Shuffle icon (tall crossing arrows)

/// Spotify-style shuffle: two smooth crossing S-curves with horizontal stubs and
/// arrowheads. The under path uses trimmed segments of one continuous curve so the
/// weave gap doesn't break into disconnected hooks.
struct ShuffleControlIcon: View {
    var lineWidthFraction: CGFloat = 0.11

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let lineWidth = max(1.5, h * lineWidthFraction)
            let stroke = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)

            let yTop = h * 0.18
            let yBot = h * 0.82

            // Left horizontal stubs → S-curve → right horizontal stubs → arrow.
            let xLeft0 = w * 0.01
            let xLeft1 = w * 0.26
            let xRight0 = w * 0.74
            let xRight1 = w * 0.84
            let xTip = w * 0.99

            let under = makePath(
                from: CGPoint(x: xLeft0, y: yTop),
                stubEnd: CGPoint(x: xLeft1, y: yTop),
                curveEnd: CGPoint(x: xRight0, y: yBot),
                stemEnd: CGPoint(x: xRight1, y: yBot)
            )
            let over = makePath(
                from: CGPoint(x: xLeft0, y: yBot),
                stubEnd: CGPoint(x: xLeft1, y: yBot),
                curveEnd: CGPoint(x: xRight0, y: yTop),
                stemEnd: CGPoint(x: xRight1, y: yTop)
            )

            // Gap around the midpoint of the under curve (keeps both halves on the
            // same bezier so they read as one interrupted stroke, not two shapes).
            let gap: CGFloat = 0.07

            ZStack {
                under.trimmedPath(from: 0, to: 0.5 - gap)
                    .stroke(style: stroke)
                under.trimmedPath(from: 0.5 + gap, to: 1)
                    .stroke(style: stroke)
                over
                    .stroke(style: stroke)

                arrowhead(
                    tip: CGPoint(x: xTip, y: yBot),
                    halfH: lineWidth * 1.25,
                    depth: w * 0.12
                )
                arrowhead(
                    tip: CGPoint(x: xTip, y: yTop),
                    halfH: lineWidth * 1.25,
                    depth: w * 0.12
                )
            }
        }
        .aspectRatio(1.3, contentMode: .fit)
    }

    /// Horizontal stub → cubic with horizontal end tangents → horizontal stem.
    private func makePath(
        from: CGPoint,
        stubEnd: CGPoint,
        curveEnd: CGPoint,
        stemEnd: CGPoint
    ) -> Path {
        let dx = curveEnd.x - stubEnd.x
        var p = Path()
        p.move(to: from)
        p.addLine(to: stubEnd)
        p.addCurve(
            to: curveEnd,
            control1: CGPoint(x: stubEnd.x + dx * 0.45, y: stubEnd.y),
            control2: CGPoint(x: curveEnd.x - dx * 0.45, y: curveEnd.y)
        )
        p.addLine(to: stemEnd)
        return p
    }

    private func arrowhead(tip: CGPoint, halfH: CGFloat, depth: CGFloat) -> some View {
        Path { p in
            p.move(to: tip)
            p.addLine(to: CGPoint(x: tip.x - depth, y: tip.y - halfH))
            p.addLine(to: CGPoint(x: tip.x - depth, y: tip.y + halfH))
            p.closeSubpath()
        }
        .fill()
    }
}

// MARK: - Skip icons (rounded triangle + capsule bar)

/// Custom skip glyph matching the reference: soft-rounded triangle tip with a
/// matching-height capsule bar and a small gap between them.
struct SkipControlIcon: View {
    enum Direction {
        case backward // bar | ◀
        case forward  // ▶ | bar
    }

    var direction: Direction
    /// Relative bar thickness as a fraction of icon height.
    var barWidthFraction: CGFloat = 0.18
    /// Gap between triangle tip and bar, as a fraction of icon height.
    var gapFraction: CGFloat = 0.12
    /// Corner radius of the triangle vertices, as a fraction of icon height.
    var triangleCornerFraction: CGFloat = 0.18

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let barW = max(2, h * barWidthFraction)
            let gap = max(1.5, h * gapFraction)
            let triangleW = max(4, geo.size.width - barW - gap)
            let corner = h * triangleCornerFraction

            HStack(spacing: gap) {
                if direction == .backward {
                    Capsule()
                        .frame(width: barW, height: h)
                    RoundedSkipTriangle(pointsTrailing: false, cornerRadius: corner)
                        .frame(width: triangleW, height: h)
                } else {
                    RoundedSkipTriangle(pointsTrailing: true, cornerRadius: corner)
                        .frame(width: triangleW, height: h)
                    Capsule()
                        .frame(width: barW, height: h)
                }
            }
            .frame(width: geo.size.width, height: h, alignment: .center)
        }
        .aspectRatio(1.15, contentMode: .fit)
    }
}

/// Isosceles triangle with rounded vertices (soft Spotify-style tip).
private struct RoundedSkipTriangle: Shape {
    var pointsTrailing: Bool
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let tip: CGPoint
        let top: CGPoint
        let bottom: CGPoint
        if pointsTrailing {
            tip = CGPoint(x: rect.maxX, y: rect.midY)
            top = CGPoint(x: rect.minX, y: rect.minY)
            bottom = CGPoint(x: rect.minX, y: rect.maxY)
        } else {
            tip = CGPoint(x: rect.minX, y: rect.midY)
            top = CGPoint(x: rect.maxX, y: rect.minY)
            bottom = CGPoint(x: rect.maxX, y: rect.maxY)
        }
        return Self.roundedPolygon(points: [top, tip, bottom], radius: cornerRadius)
    }

    /// Builds a closed path through `points` with circular arcs at each vertex.
    private static func roundedPolygon(points: [CGPoint], radius: CGFloat) -> Path {
        guard points.count >= 3 else { return Path() }
        var path = Path()
        let count = points.count

        for i in 0..<count {
            let prev = points[(i - 1 + count) % count]
            let curr = points[i]
            let next = points[(i + 1) % count]

            let toPrev = CGPoint(x: prev.x - curr.x, y: prev.y - curr.y)
            let toNext = CGPoint(x: next.x - curr.x, y: next.y - curr.y)
            let lenPrev = hypot(toPrev.x, toPrev.y)
            let lenNext = hypot(toNext.x, toNext.y)
            guard lenPrev > 0, lenNext > 0 else { continue }

            // Cap radius so it doesn't overrun either adjacent edge.
            let maxR = min(lenPrev, lenNext) / 2
            let r = min(radius, maxR)

            let p1 = CGPoint(
                x: curr.x + toPrev.x / lenPrev * r,
                y: curr.y + toPrev.y / lenPrev * r
            )
            let p2 = CGPoint(
                x: curr.x + toNext.x / lenNext * r,
                y: curr.y + toNext.y / lenNext * r
            )

            if i == 0 {
                path.move(to: p1)
            } else {
                path.addLine(to: p1)
            }
            path.addQuadCurve(to: p2, control: curr)
        }
        path.closeSubpath()
        return path
    }
}
