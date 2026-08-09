import SwiftUI
import VerodromeKit

/// Scrollable lyrics. When the lyrics carry timestamps the active line is
/// highlighted and kept centered, and tapping a line seeks to it.
struct SyncedLyricsView: View {
    /// Observed here rather than in the player so the 0.25s clock only redraws
    /// the lyrics, not the whole player screen.
    @EnvironmentObject private var progress: PlayerProgressModel
    @EnvironmentObject private var player: PlayerViewModel

    var horizontalPadding: CGFloat = VerodromeTheme.playerContentHorizontalPadding
    var alignment: TextAlignment = .leading
    /// Double-tap anywhere in the list (including on a line) toggles lyrics in the
    /// popup player. Optional so the inspector lyrics pane stays tap-to-seek only.
    var onDoubleTap: (() -> Void)? = nil

    /// Auto-scroll stays out of the way for this long after the user drags.
    private let manualScrollGracePeriod: TimeInterval = 4
    private let scrollSpace = "lyrics.scroll"

    @State private var lastManualScroll: Date?
    /// Lines currently on screen. Auto-scroll only recenters a line that is already
    /// visible, so a reader who has scrolled ahead is never yanked back.
    @State private var visibleLines: Set<Int> = []

    private var lines: [LyricLine] { player.lyricLines }
    private var isSynced: Bool { LyricsParser.isSynced(lines) }

    private var activeIndex: Int? {
        guard isSynced else { return nil }
        return LyricsParser.activeIndex(in: lines, at: progress.currentTime)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: horizontalAlignment, spacing: 18) {
                        // Padding as spacers so the first and last lines can still
                        // settle in the middle of the viewport.
                        Color.clear.frame(height: isSynced ? geometry.size.height * 0.38 : 12)

                        ForEach(lines) { line in
                            lineView(line)
                                .id(line.id)
                                .background(visibilityReader(for: line, viewportHeight: geometry.size.height))
                        }

                        Color.clear.frame(height: isSynced ? geometry.size.height * 0.5 : 24)
                    }
                    .frame(maxWidth: .infinity, alignment: frameAlignment)
                    .padding(.horizontal, horizontalPadding)
                }
                .coordinateSpace(name: scrollSpace)
                // iOS 17 has no scroll-phase callback, so a passive drag gesture is
                // what tells us the user took over.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 4).onChanged { _ in lastManualScroll = Date() }
                )
                // simultaneous so line seek buttons still receive their single tap.
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded { onDoubleTap?() }
                )
                .onPreferenceChange(VisibleLyricLinesKey.self) { visibleLines = $0 }
                .onChange(of: activeIndex) { _, index in
                    scroll(to: index, using: proxy)
                }
                .onChange(of: player.lyrics) { _, _ in
                    // New track: drop the manual-scroll hold and start from the top.
                    lastManualScroll = nil
                    visibleLines = []
                    if let first = lines.first?.id {
                        proxy.scrollTo(first, anchor: .top)
                    }
                    scroll(to: activeIndex, using: proxy, animated: false, force: true)
                }
                .onAppear { scroll(to: activeIndex, using: proxy, animated: false, force: true) }
            }
        }
        // Dissolve rather than clip at the edges of the panel.
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.08),
                    .init(color: .black, location: 0.9),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var horizontalAlignment: HorizontalAlignment {
        alignment == .center ? .center : .leading
    }

    private var frameAlignment: Alignment {
        alignment == .center ? .center : .leading
    }

    @ViewBuilder
    private func lineView(_ line: LyricLine) -> some View {
        let isActive = activeIndex == line.id
        let text = Text(line.text.isEmpty ? " " : line.text)
            .font(.title3.weight(isActive ? .bold : .semibold))
            .multilineTextAlignment(alignment)
            .foregroundStyle(.primary)
            .opacity(isSynced ? (isActive ? 1 : 0.35) : 1)
            .scaleEffect(isActive ? 1.04 : 1, anchor: anchor)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
            .animation(.easeInOut(duration: 0.25), value: isActive)

        if let start = line.start {
            Button {
                lastManualScroll = nil
                player.seek(to: start)
            } label: {
                text
            }
            .buttonStyle(.plain)
            .accessibilityHint("Plays from this line")
        } else {
            text
        }
    }

    private var anchor: UnitPoint {
        alignment == .center ? .center : .leading
    }

    /// Reports whether `line` currently overlaps the visible part of the scroll view.
    private func visibilityReader(for line: LyricLine, viewportHeight: CGFloat) -> some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named(scrollSpace))
            let isVisible = frame.maxY > 0 && frame.minY < viewportHeight
            Color.clear.preference(
                key: VisibleLyricLinesKey.self,
                value: isVisible ? [line.id] : []
            )
        }
    }

    /// - Parameter force: Skips the "already on screen" test, for positioning the list
    ///   when it first appears or when a new track's lyrics arrive.
    private func scroll(
        to index: Int?,
        using proxy: ScrollViewProxy,
        animated: Bool = true,
        force: Bool = false
    ) {
        guard isSynced, let index else { return }
        // Once the reader has scrolled the active line off screen they are reading
        // ahead (or behind) deliberately, so leave the list where they put it until
        // playback catches back up to what they are looking at.
        if !force, !visibleLines.isEmpty, !visibleLines.contains(index) { return }
        if let lastManualScroll, Date().timeIntervalSince(lastManualScroll) < manualScrollGracePeriod {
            return
        }
        guard animated else {
            proxy.scrollTo(index, anchor: .center)
            return
        }
        withAnimation(.easeInOut(duration: 0.35)) {
            proxy.scrollTo(index, anchor: .center)
        }
    }
}

private struct VisibleLyricLinesKey: PreferenceKey {
    static var defaultValue: Set<Int> = []

    static func reduce(value: inout Set<Int>, nextValue: () -> Set<Int>) {
        value.formUnion(nextValue())
    }
}
