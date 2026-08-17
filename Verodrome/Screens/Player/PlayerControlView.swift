import SwiftUI
import VerodromeKit

struct PlayerControlView: View {
    @EnvironmentObject private var player: PlayerViewModel
    @EnvironmentObject private var progress: PlayerProgressModel
    @EnvironmentObject private var shuffleAll: ShuffleAllCoordinator
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var settings: SettingsStore

    /// Thumb position while the user drags, so the time labels follow the scrub
    /// instead of the (still advancing) playback clock.
    @State private var scrubTime: TimeInterval?

    /// Locked reshuffle feedback: 0→1 first dot lap, 1→2 line lap, 2→3 second dot lap.
    @State private var shuffleOrbitProgress: CGFloat = 0
    @State private var isShuffleOrbiting = false

    /// Match Spotify-style control row proportions from the reference.
    private let playDiameter: CGFloat = 72
    private let skipIconSize: CGFloat = 28
    private let sideIconSize: CGFloat = 22
    private let controlSpacing: CGFloat = 36
    private let statusDotSize: CGFloat = 4
    private let statusDotSpacing: CGFloat = 5
    /// One lap each for dot → line → dot.
    private let shuffleOrbitLapDuration: TimeInterval = 0.42
    private var shuffleOrbitDuration: TimeInterval { shuffleOrbitLapDuration * 3 }

    var body: some View {
        VStack(spacing: 12) {
            if player.currentItem?.isLiveStream == true {
                Text("LIVE")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, VerodromeTheme.playerContentHorizontalPadding)
            } else {
                VStack(spacing: 2) {
                    SeekableTimeSlider(
                        currentTime: progress.currentTime,
                        duration: progress.duration,
                        accentTint: usesAccentProgressBar ? themeManager.accentColor : nil,
                        onScrub: { scrubTime = $0 },
                        onSeek: { time in
                            scrubTime = nil
                            player.seek(to: time)
                        }
                    )

                    HStack {
                        Text(formatTime(displayedTime))
                        Spacer()
                        Text("-\(formatTime(max(0, progress.duration - displayedTime)))")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, VerodromeTheme.playerContentHorizontalPadding)
            }

            HStack(spacing: controlSpacing) {
                shuffleButton
                skipButton(
                    direction: .backward,
                    onTap: player.skipBackward,
                    holdRate: 0.5
                )
                playButton
                skipButton(
                    direction: .forward,
                    onTap: player.skipForward,
                    holdRate: 2
                )
                repeatButton
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
        }
    }

    private var displayedTime: TimeInterval {
        scrubTime ?? progress.currentTime
    }

    /// Accent while hold-to-speed is active, or whenever sticky speed is Random / non-1×.
    private var usesAccentProgressBar: Bool {
        if player.holdSpeedRate != nil { return true }
        if player.isRandomPlaybackSpeed { return true }
        return !PlaybackSpeed.isEqual(player.playbackSpeed, 1)
    }

    // MARK: - Controls

    /// Solid label-colored circle with the play/pause glyph cut out, so the player
    /// background shows through it in either appearance.
    private var playButton: some View {
        Button { player.playPause() } label: {
            ZStack {
                Circle()
                    .fill(Color.primary)
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

    private func skipButton(
        direction: SkipControlIcon.Direction,
        onTap: @escaping () -> Void,
        holdRate: Float
    ) -> some View {
        let isLive = player.currentItem?.isLiveStream == true
        let seconds = settings.miniSkipInterval.rawValue
        let delta = settings.miniSkipInterval.timeInterval
        let intervalDelta = direction == .forward ? delta : -delta
        return HoldableButton(
            isEnabled: !isLive,
            onTap: {
                if settings.miniSkipEnabled {
                    player.seekByInterval(intervalDelta)
                } else {
                    onTap()
                }
            },
            onHoldStart: {
                if settings.miniSkipEnabled {
                    player.beginIntervalHold(intervalDelta)
                } else {
                    player.beginHoldSpeed(holdRate)
                }
            },
            onHoldEnd: {
                if settings.miniSkipEnabled {
                    player.endIntervalHold()
                } else {
                    player.endHoldSpeed()
                }
            }
        ) {
            SkipControlIcon(direction: direction)
                .frame(width: skipIconSize + 4, height: skipIconSize)
                .frame(width: skipIconSize + 12, height: playDiameter)
        }
        .opacity(isLive ? 0.35 : 1)
        .accessibilityLabel(skipAccessibilityLabel(direction: direction, seconds: seconds))
        .accessibilityHint(skipAccessibilityHint(direction: direction, seconds: seconds))
    }

    private func skipAccessibilityLabel(
        direction: SkipControlIcon.Direction,
        seconds: Int
    ) -> String {
        if settings.miniSkipEnabled {
            return direction == .backward
                ? "Skip back \(seconds) seconds"
                : "Skip forward \(seconds) seconds"
        }
        return direction == .backward ? "Previous" : "Next"
    }

    private func skipAccessibilityHint(direction: SkipControlIcon.Direction, seconds: Int) -> String {
        if settings.miniSkipEnabled {
            return "Hold to keep skipping \(seconds) seconds"
        }
        return direction == .backward
            ? "Hold to play at half speed"
            : "Hold to fast forward at double speed"
    }

    private var shuffleButton: some View {
        // A Shuffle All queue arrives in an order the server chose and keeps growing as
        // it plays, so there is nothing to turn shuffle off and go back to. The control
        // stays on; a tap reshuffles the whole pool (current track included) and plays
        // the dot → line → dot orbit. Full opacity, unlike the live-stream case: this
        // state is accurate, not unavailable.
        let isLocked = shuffleAll.isShuffleLocked
        let isLiveStream = player.currentItem?.isLiveStream == true
        let isOn = isLocked || player.shuffleMode == .on
        // Spinner only for the first Shuffle All kickoff — a locked reshuffle keeps the
        // accent icon so the orbit can play over it.
        let showSpinner = shuffleAll.isStarting && !isLocked && !isShuffleOrbiting
        return Button(action: shuffleTapped) {
            ZStack {
                VStack(spacing: statusDotSpacing) {
                    Group {
                        if showSpinner {
                            ProgressView().controlSize(.small)
                        } else {
                            ShuffleControlIcon()
                                .foregroundStyle(isOn ? Color.accentColor : Color.primary)
                        }
                    }
                    .frame(width: sideIconSize + 8, height: sideIconSize)
                    // Resting accent dot. Hidden while the orbit overlay is traveling.
                    Circle()
                        .fill(isOn && !isShuffleOrbiting ? Color.accentColor : Color.clear)
                        .frame(width: statusDotSize, height: statusDotSize)
                }

                if isShuffleOrbiting {
                    ShuffleOrbitingIndicator(
                        progress: shuffleOrbitProgress,
                        dotSize: statusDotSize,
                        iconSize: sideIconSize,
                        spacing: statusDotSpacing
                    )
                }
            }
            .frame(width: sideIconSize + 16, height: playDiameter)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Shuffle")
        .accessibilityHint(
            isLocked
                ? "Shuffling all songs; tap to reshuffle and replace the current track"
                : ""
        )
        .disabled(isLiveStream || shuffleAll.isStarting)
        .opacity(isLiveStream ? 0.35 : 1)
    }

    /// Playing from the songs list queues only the rows around the track that was tapped,
    /// so shuffling those would be a much smaller answer than the user is asking for.
    /// Turning shuffle on there draws a fresh batch from the whole library and swaps the
    /// queue for it — the playing track included.
    private func shuffleTapped() {
        if shuffleAll.isShuffleLocked {
            playShuffleLockedOrbit()
            Task { await shuffleAll.reshuffle() }
            return
        }
        guard shuffleAll.shufflePlaysWholeLibrary, player.shuffleMode == .off else {
            player.toggleShuffle()
            return
        }
        Task {
            // Backends with no random endpoint fall back to reordering what's queued.
            if await shuffleAll.shuffleAll() == false {
                player.toggleShuffle()
            }
        }
    }

    private func playShuffleLockedOrbit() {
        guard !isShuffleOrbiting else { return }
        isShuffleOrbiting = true
        Haptics.impact(.light)
        shuffleOrbitProgress = 0
        withAnimation(.linear(duration: shuffleOrbitDuration)) {
            shuffleOrbitProgress = 3
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(shuffleOrbitDuration))
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                shuffleOrbitProgress = 0
            }
            isShuffleOrbiting = false
        }
    }

    private var repeatButton: some View {
        let isOn = player.repeatMode != .off
        return Button { player.toggleRepeat() } label: {
            VStack(spacing: 5) {
                RepeatControlIcon(mode: player.repeatMode)
                    .frame(width: sideIconSize + 6, height: sideIconSize - 2)
                    .foregroundStyle(isOn ? Color.accentColor : Color.primary)
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

/// Spotify-style repeat loop. Off = label color; on (.all) = accent; .one = accent with
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

// MARK: - Shuffle-all locked orbit

/// Locked-reshuffle feedback around the shuffle glyph: a dot lap, then a short
/// tangent line lap, then another dot lap. `progress` runs 0…3 (one unit per lap).
/// `Animatable` so SwiftUI interpolates the angle on the circle rather than
/// lerping the offset as a straight chord.
private struct ShuffleOrbitingIndicator: View, Animatable {
    var progress: CGFloat
    var dotSize: CGFloat
    var iconSize: CGFloat
    var spacing: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let iconCenterY = -(spacing + dotSize) / 2
        let radius = iconSize / 2 + spacing + dotSize / 2
        let total = min(max(progress, 0), 3)
        let lapIndex = total >= 3 ? 2 : Int(total)
        let lapT = total >= 3 ? 1 : total - CGFloat(lapIndex)
        // Start under the icon; increasing angle is clockwise with y-down.
        let angle = (.pi / 2) + (lapT * 2 * .pi)
        let x = radius * cos(angle)
        let y = iconCenterY + radius * sin(angle)
        let showsLine = lapIndex == 1

        ZStack {
            Circle()
                .fill(Color.accentColor)
                .frame(width: dotSize, height: dotSize)
                .opacity(showsLine ? 0 : 1)

            // Tangential dash — reads as a rotating line segment on the orbit.
            Capsule()
                .fill(Color.accentColor)
                .frame(width: dotSize * 3.2, height: dotSize)
                .rotationEffect(.radians(angle + .pi / 2))
                .opacity(showsLine ? 1 : 0)
        }
        .offset(x: x, y: y)
    }
}

// MARK: - Shuffle icon (crossing arrows glyph)

/// Shuffle glyph rendered from SVG path data (16×16 viewBox): an unbroken
/// diagonal with a top-right arrow, and a broken under-line whose right half
/// hooks into a second arrow. The active-state dot is drawn by the caller.
struct ShuffleControlIcon: View {
    /// Main diagonal (bottom-left → top-right arrow) + top-left stub of the under-line.
    private static let glyphMain = "M13.151.922a.75.75 0 1 0-1.06 1.06L13.109 3H11.16a3.75 3.75 0 0 0-2.873 1.34l-6.173 7.356A2.25 2.25 0 0 1 .39 12.5H0V14h.391a3.75 3.75 0 0 0 2.873-1.34l6.173-7.356a2.25 2.25 0 0 1 1.724-.804h1.947l-1.017 1.018a.75.75 0 0 0 1.06 1.06L15.98 3.75 13.15.922z"
    /// Right half of the under-line hooking into the lower-right arrow.
    private static let glyphHook = "m7.5 10.723.98-1.167.957 1.14a2.25 2.25 0 0 0 1.724.804h1.947l-1.017-1.018a.75.75 0 1 1 1.06-1.06l2.829 2.828-2.829 2.828a.75.75 0 1 1-1.06-1.06L13.109 13H11.16a3.75 3.75 0 0 1-2.873-1.34l-.787-.937z"
    /// Top-left tail stub of the under-line (before the weave gap).
    private static let glyphStub = "M.391 3.5H0V2h.391c1.109 0 2.16.49 2.873 1.34L4.89 5.277l-.979 1.167-1.796-2.14A2.25 2.25 0 0 0 .39 3.5z"

    var body: some View {
        SVGGlyphShape(
            pathData: [Self.glyphMain, Self.glyphHook, Self.glyphStub],
            viewBox: CGRect(x: 0, y: 0, width: 16, height: 16)
        )
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Fills SVG path-data strings, scaled to fit the view preserving aspect ratio.
struct SVGGlyphShape: Shape {
    var pathData: [String]
    var viewBox: CGRect

    func path(in rect: CGRect) -> Path {
        var combined = Path()
        for data in pathData {
            combined.addPath(SVGPathParser.parse(data))
        }
        let scale = min(rect.width / viewBox.width, rect.height / viewBox.height)
        let offsetX = rect.midX - (viewBox.midX * scale)
        let offsetY = rect.midY - (viewBox.midY * scale)
        return combined.applying(
            CGAffineTransform(translationX: offsetX, y: offsetY).scaledBy(x: scale, y: scale)
        )
    }
}

/// Minimal SVG path-data parser (M/L/H/V/C/S/Q/T/A/Z, absolute and relative),
/// enough for embedded icon glyphs.
enum SVGPathParser {
    static func parse(_ data: String) -> Path {
        var path = Path()
        var scanner = Tokenizer(data)
        var command: Character = " "
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastControl: CGPoint?
        var lastCommandWasCurve = false
        var lastCommandWasQuad = false

        while let token = scanner.nextCommandOrNumber() {
            if case .command(let c) = token {
                command = c
            } else if case .number(let n) = token {
                // Implicit command repetition: push the number back.
                scanner.pushBack(n)
            }

            let isRelative = command.isLowercase
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                isRelative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }

            switch Character(command.uppercased()) {
            case "M":
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = point(x, y)
                subpathStart = current
                path.move(to: current)
                // Subsequent pairs are implicit LineTos.
                command = isRelative ? "l" : "L"
            case "L":
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = point(x, y)
                path.addLine(to: current)
            case "H":
                guard let x = scanner.number() else { return path }
                current = CGPoint(x: isRelative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
            case "V":
                guard let y = scanner.number() else { return path }
                current = CGPoint(x: current.x, y: isRelative ? current.y + y : y)
                path.addLine(to: current)
            case "C":
                guard let x1 = scanner.number(), let y1 = scanner.number(),
                      let x2 = scanner.number(), let y2 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() else { return path }
                let c1 = point(x1, y1), c2 = point(x2, y2), end = point(x, y)
                path.addCurve(to: end, control1: c1, control2: c2)
                lastControl = c2
                current = end
            case "S":
                guard let x2 = scanner.number(), let y2 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() else { return path }
                let c1 = lastCommandWasCurve && lastControl != nil
                    ? CGPoint(x: 2 * current.x - lastControl!.x, y: 2 * current.y - lastControl!.y)
                    : current
                let c2 = point(x2, y2), end = point(x, y)
                path.addCurve(to: end, control1: c1, control2: c2)
                lastControl = c2
                current = end
            case "Q":
                guard let x1 = scanner.number(), let y1 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() else { return path }
                let c = point(x1, y1), end = point(x, y)
                path.addQuadCurve(to: end, control: c)
                lastControl = c
                current = end
            case "T":
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                let c = lastCommandWasQuad && lastControl != nil
                    ? CGPoint(x: 2 * current.x - lastControl!.x, y: 2 * current.y - lastControl!.y)
                    : current
                let end = point(x, y)
                path.addQuadCurve(to: end, control: c)
                lastControl = c
                current = end
            case "A":
                guard let rx = scanner.number(), let ry = scanner.number(),
                      let rotation = scanner.number(),
                      let largeArc = scanner.number(), let sweep = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() else { return path }
                let end = point(x, y)
                addArc(
                    to: &path, from: current, to: end,
                    rx: rx, ry: ry, rotationDegrees: rotation,
                    largeArc: largeArc != 0, sweep: sweep != 0
                )
                current = end
            case "Z":
                path.closeSubpath()
                current = subpathStart
            default:
                return path
            }

            lastCommandWasCurve = "CcSs".contains(command)
            lastCommandWasQuad = "QqTt".contains(command)
            if !lastCommandWasCurve && !lastCommandWasQuad { lastControl = nil }
        }
        return path
    }

    /// SVG endpoint arc → cubic bezier segments (W3C implementation notes B.2.4).
    private static func addArc(
        to path: inout Path, from start: CGPoint, to end: CGPoint,
        rx: CGFloat, ry: CGFloat, rotationDegrees: CGFloat,
        largeArc: Bool, sweep: Bool
    ) {
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0, start != end else {
            path.addLine(to: end)
            return
        }
        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)

        let dx2 = (start.x - end.x) / 2, dy2 = (start.y - end.y) / 2
        let x1p = cosPhi * dx2 + sinPhi * dy2
        let y1p = -sinPhi * dx2 + cosPhi * dy2

        // Scale radii up if the endpoints cannot be reached.
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let s = sqrt(lambda)
            rx *= s
            ry *= s
        }

        let rxSq = rx * rx, rySq = ry * ry
        let numerator = max(0, rxSq * rySq - rxSq * y1p * y1p - rySq * x1p * x1p)
        let denominator = rxSq * y1p * y1p + rySq * x1p * x1p
        var coefficient = sqrt(numerator / denominator)
        if largeArc == sweep { coefficient = -coefficient }

        let cxp = coefficient * rx * y1p / ry
        let cyp = -coefficient * ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (start.x + end.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (start.y + end.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
            var a = acos(min(max(dot / len, -1), 1))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }

        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var deltaTheta = angle(
            (x1p - cxp) / rx, (y1p - cyp) / ry,
            (-x1p - cxp) / rx, (-y1p - cyp) / ry
        )
        if !sweep, deltaTheta > 0 { deltaTheta -= 2 * .pi }
        if sweep, deltaTheta < 0 { deltaTheta += 2 * .pi }

        // Split into segments of at most 90°.
        let segments = max(1, Int(ceil(abs(deltaTheta) / (.pi / 2))))
        let delta = deltaTheta / CGFloat(segments)
        let t = 4 / 3 * tan(delta / 4)

        var theta = theta1
        var from = start
        for _ in 0..<segments {
            let thetaNext = theta + delta
            let cosT = cos(theta), sinT = sin(theta)
            let cosN = cos(thetaNext), sinN = sin(thetaNext)

            func onEllipse(_ c: CGFloat, _ s: CGFloat) -> CGPoint {
                CGPoint(
                    x: cx + rx * cosPhi * c - ry * sinPhi * s,
                    y: cy + rx * sinPhi * c + ry * cosPhi * s
                )
            }
            // Derivative direction at angle for control points.
            func derivative(_ c: CGFloat, _ s: CGFloat) -> CGPoint {
                CGPoint(
                    x: -rx * cosPhi * s - ry * sinPhi * c,
                    y: -rx * sinPhi * s + ry * cosPhi * c
                )
            }

            let to = onEllipse(cosN, sinN)
            let d1 = derivative(cosT, sinT)
            let d2 = derivative(cosN, sinN)
            path.addCurve(
                to: to,
                control1: CGPoint(x: from.x + t * d1.x, y: from.y + t * d1.y),
                control2: CGPoint(x: to.x - t * d2.x, y: to.y - t * d2.y)
            )
            from = to
            theta = thetaNext
        }
    }

    /// Lexer for SVG path data: commands are single letters; numbers may be
    /// separated by spaces/commas, run together with '-', or share decimals (".75.75").
    private struct Tokenizer {
        enum Token {
            case command(Character)
            case number(CGFloat)
        }

        private let chars: [Character]
        private var index = 0
        private var pushedBack: CGFloat?

        init(_ data: String) {
            chars = Array(data)
        }

        mutating func pushBack(_ n: CGFloat) {
            pushedBack = n
        }

        mutating func nextCommandOrNumber() -> Token? {
            if let n = pushedBack {
                pushedBack = nil
                return .number(n)
            }
            skipSeparators()
            guard index < chars.count else { return nil }
            let c = chars[index]
            if c.isLetter {
                index += 1
                return .command(c)
            }
            return number().map { .number($0) }
        }

        mutating func number() -> CGFloat? {
            if let n = pushedBack {
                pushedBack = nil
                return n
            }
            skipSeparators()
            guard index < chars.count else { return nil }

            var text = ""
            var seenDot = false
            var seenExponent = false
            while index < chars.count {
                let c = chars[index]
                if c == "-" || c == "+" {
                    // Sign is only part of the number at the start or right after 'e'.
                    let prev = text.last
                    guard text.isEmpty || prev == "e" || prev == "E" else { break }
                } else if c == "." {
                    // Second dot starts a new number (".75.75").
                    if seenDot { break }
                    seenDot = true
                } else if c == "e" || c == "E" {
                    if seenExponent { break }
                    seenExponent = true
                } else if !c.isNumber {
                    break
                }
                text.append(c)
                index += 1
            }
            guard let value = Double(text) else { return nil }
            return CGFloat(value)
        }

        private mutating func skipSeparators() {
            while index < chars.count, chars[index] == " " || chars[index] == "," || chars[index] == "\n" || chars[index] == "\t" {
                index += 1
            }
        }
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
