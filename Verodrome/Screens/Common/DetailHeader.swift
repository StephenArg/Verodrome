import SwiftUI
import UIKit

struct DetailHeader<Accessory: View>: View {
    let title: String
    let subtitle: String
    /// Artwork the buttons take their color from. Defaults to the hero art, but
    /// screens whose background falls back to another cover (an artist with no
    /// image, say) should pass the same token they tint the background with.
    let artworkURL: String?
    let tintToken: String?
    /// Entity the button color is stored against, so it matches the background and
    /// is cleared by the same refresh.
    let tintKey: ArtworkTintKey?
    let symbol: String
    let onPlay: () -> Void
    let onShuffle: () -> Void
    /// Optional row between the title and the action buttons — the album's rating,
    /// download, and favorite controls. Most screens leave it empty.
    @ViewBuilder let accessory: () -> Accessory

    init(
        title: String,
        subtitle: String,
        artworkURL: String? = nil,
        tintToken: String? = nil,
        tintKey: ArtworkTintKey? = nil,
        symbol: String = "music.note",
        onPlay: @escaping () -> Void,
        onShuffle: @escaping () -> Void,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.tintToken = tintToken
        self.tintKey = tintKey
        self.symbol = symbol
        self.onPlay = onPlay
        self.onShuffle = onShuffle
        self.accessory = accessory
    }

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var router: AppRouter
    @ObservedObject private var resolver = ArtworkTintResolver.shared
    @State private var tint: ArtworkTint?
    /// Signed list offset relative to rest: negative = rubber-band pull, positive = scrolled down.
    @State private var scrollY: CGFloat = 0

    private var resolvedTint: ArtworkTint {
        tint ?? ArtworkTint(hue: 0, saturation: 0)
    }

    private var pullDistance: CGFloat { max(0, -scrollY) }
    private var collapseDistance: CGFloat { max(0, scrollY) }

    /// Grows point for point with the pull, so the cover fills the rubber-band gap
    /// and its bottom edge stays against the title.
    private var growth: CGFloat {
        min(pullDistance, DetailHeaderMetrics.maxGrowth)
    }

    /// Scale bottoms out partway through the collapse; opacity keeps falling after that.
    private var collapseScale: CGFloat {
        let t = min(1, collapseDistance / DetailHeaderMetrics.shrinkDistance)
        return 1 - t * (1 - DetailHeaderMetrics.minShrinkScale)
    }

    private var collapseOpacity: CGFloat {
        let t = min(1, collapseDistance / DetailHeaderMetrics.fadeDistance)
        // Square the remaining opacity so it clears sooner while still hitting 0
        // at the same scroll distance as the shrink.
        let remaining = 1 - t
        return remaining * remaining
    }

    var body: some View {
        VStack(spacing: 20) {
            stretchyArtwork
                // Stay behind the title / controls so they can scroll up over the cover.
                .zIndex(0)

            VStack(spacing: 6) {
                Text(title)
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .zIndex(1)

            accessory()
                .zIndex(1)

            HStack(spacing: 16) {
                Button(action: onPlay) {
                    // Explicit Image+Text: Label inside a custom style can drop the icon.
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        Text("Play")
                    }
                }
                .buttonStyle(
                    DetailActionButtonStyle(
                        fill: playFill,
                        label: playFill.contrastingLabel,
                        stroke: .clear
                    )
                )

                // Shuffle raises the player; Play doesn't. Shuffling is a "surprise me"
                // tap, and the answer is the track that comes up — worth showing. Play
                // starts at the top of a tracklist the user is already looking at.
                Button {
                    onShuffle()
                    router.openPlayer()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "shuffle")
                        Text("Shuffle")
                    }
                }
                .buttonStyle(
                    DetailActionButtonStyle(
                        fill: resolvedTint.secondaryButtonFill(for: colorScheme),
                        label: resolvedTint.secondaryButtonLabel(for: colorScheme),
                        stroke: resolvedTint.secondaryButtonStroke(for: colorScheme)
                    )
                )
            }
            .zIndex(1)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background {
            ScrollOffsetReader { y in
                guard abs(y - scrollY) > 0.5 else { return }
                // Offset already carries the scroll view's curve; animating on top would lag.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { scrollY = y }
            }
        }
        .animation(.easeOut(duration: 0.4), value: tint)
        .task(
            id: ArtworkTintRequest(
                key: tintKey,
                token: tintToken ?? artworkURL,
                revision: resolver.revision
            )
        ) {
            tint = await resolver.tint(for: tintKey, token: tintToken ?? artworkURL)
        }
    }

    /// Layout size of the art slot never changes with scroll — only the painted cover
    /// does. Changing row height from `contentOffset` feeds back into that same offset
    /// and cancels the gesture (same failure mode as growing into a rubber-band).
    ///
    /// Pull-to-grow paints larger and lifts by the growth amount. Collapse-on-scroll
    /// paints smaller and fades, and counters the list's scroll with a matching offset
    /// so the cover stays sticky while the title and controls slide up over it.
    private var stretchyArtwork: some View {
        let base = DetailHeaderMetrics.artworkSize
        let drawn = (base + growth) * collapseScale
        return Color.clear
            .frame(width: base, height: base)
            .overlay {
                ArtworkView.hero(artworkURL, symbol: symbol)
                    .frame(width: drawn, height: drawn)
                    .shadow(
                        color: .black.opacity(0.35 * collapseOpacity),
                        radius: 14,
                        y: 8
                    )
                    .opacity(collapseOpacity)
                    // -growth: expand into the rubber-band. +collapse: cancel scroll so
                    // the cover stays put while content below moves up over it.
                    .offset(y: -growth + collapseDistance)
            }
            .frame(maxWidth: .infinity)
            .allowsHitTesting(collapseOpacity > 0.2)
            .accessibilityHidden(collapseOpacity < 0.05)
    }

    private var playFill: Color {
        resolvedTint.primaryButtonFill(for: colorScheme)
    }
}

/// Constants for the stretchy / collapsing hero — kept outside `DetailHeader` because
/// generic types can't hold static stored properties.
enum DetailHeaderMetrics {
    static let artworkSize: CGFloat = 280
    /// Caps growth just under the width of the narrowest phone.
    static let maxGrowth: CGFloat = 110
    /// Scroll distance over which scale falls from 1 → `minShrinkScale` and opacity
    /// falls from 1 → 0 — same range so they finish together.
    static let shrinkDistance: CGFloat = 280
    static let minShrinkScale: CGFloat = 0.55
    static let fadeDistance: CGFloat = shrinkDistance
    /// Top padding (8) + art + spacing (20) + title/subtitle block. Past this the
    /// in-header title is fully under the nav and the principal title can appear.
    static let navTitleRevealDistance: CGFloat = 8 + artworkSize + 20 + 64
    /// Scroll distance over which the principal title fades 0 → 1.
    static let navTitleFadeInDistance: CGFloat = 40
    /// Top of the accessory row (filter / download). Past this the in-header control
    /// has reached the top of the list and a sticky copy can take over.
    static let accessoryTopDistance: CGFloat = navTitleRevealDistance + 20

    static func navTitleOpacity(forScrollY scrollY: CGFloat) -> CGFloat {
        let t = (scrollY - navTitleRevealDistance) / navTitleFadeInDistance
        return min(1, max(0, t))
    }
}

extension View {
    /// Keeps a truncated principal title on the navigation bar while the detail list
    /// is scrolled. Owned by the list (not `DetailHeader`) so the title survives when
    /// the header row is recycled near the bottom of a long list.
    func detailCollapsingNavTitle(_ title: String) -> some View {
        modifier(DetailCollapsingNavTitleModifier(title: title))
    }

    /// Signed list offset relative to rest — same sensor `DetailHeader` uses for the
    /// stretchy cover. Negative while rubber-banding; positive once content has scrolled up.
    func onDetailListScrollOffset(_ handler: @escaping (CGFloat) -> Void) -> some View {
        background {
            ScrollOffsetReader(onOffset: handler)
        }
    }
}

private struct DetailCollapsingNavTitleModifier: ViewModifier {
    let title: String
    @State private var scrollY: CGFloat = 0

    private var opacity: CGFloat {
        DetailHeaderMetrics.navTitleOpacity(forScrollY: scrollY)
    }

    func body(content: Content) -> some View {
        content
            .background {
                ScrollOffsetReader { y in
                    guard abs(y - scrollY) > 0.5 else { return }
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { scrollY = y }
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .opacity(opacity)
                        .accessibilityHidden(opacity < 0.05)
                }
            }
    }
}

/// Reports signed list offset relative to rest (`contentOffset.y + adjustedContentInset.top`).
/// Negative while rubber-banding past the top; positive once content has scrolled up.
///
/// Read from the scroll view rather than a `GeometryReader`: geometry inside a `List`
/// row is measured against the scrolling content, which doesn't move relative to the
/// row during a rubber-band, so it can't see overscroll at all.
private struct ScrollOffsetReader: UIViewRepresentable {
    var onOffset: (CGFloat) -> Void

    func makeUIView(context: Context) -> ScrollOffsetSensor {
        let sensor = ScrollOffsetSensor()
        sensor.onOffset = onOffset
        return sensor
    }

    func updateUIView(_ uiView: ScrollOffsetSensor, context: Context) {
        uiView.onOffset = onOffset
    }

    static func dismantleUIView(_ uiView: ScrollOffsetSensor, coordinator: ()) {
        uiView.stopObserving()
    }
}

private final class ScrollOffsetSensor: UIView {
    var onOffset: ((CGFloat) -> Void)?

    private var observation: NSKeyValueObservation?
    private weak var observedScrollView: UIScrollView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopObserving()
        } else {
            startObservingIfNeeded()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Rows are recycled into new hierarchies, so re-check which list we're in.
        startObservingIfNeeded()
        unclipAncestors()
    }

    func stopObserving() {
        observation?.invalidate()
        observation = nil
        observedScrollView = nil
    }

    private func startObservingIfNeeded() {
        guard window != nil, let scrollView = enclosingScrollView() else { return }
        guard observedScrollView !== scrollView else { return }

        observation?.invalidate()
        observedScrollView = scrollView
        observation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
            guard let self else { return }
            // Art paints outside its layout slot while sticky or stretched.
            self.unclipAncestors()
            self.onOffset?(Self.offset(of: scrollView))
        }
    }

    /// The row clips its content by default, which would cut the top off the enlarged
    /// cover. The scroll view itself keeps clipping, so nothing spills over the
    /// navigation bar or past the bottom of the list.
    private func unclipAncestors() {
        var view: UIView? = self
        while let current = view, !(current is UIScrollView) {
            if current.clipsToBounds { current.clipsToBounds = false }
            view = current.superview
        }
    }

    private static func offset(of scrollView: UIScrollView) -> CGFloat {
        scrollView.contentOffset.y + scrollView.adjustedContentInset.top
    }

    private func enclosingScrollView() -> UIScrollView? {
        var view: UIView? = self
        while let current = view {
            if let scrollView = current as? UIScrollView { return scrollView }
            view = current.superview
        }
        // List `.background` can host this beside the collection view, not under it.
        return findNearbyScrollView()
    }

    private func findNearbyScrollView() -> UIScrollView? {
        guard let window else { return nil }
        let anchor = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: window)
        var best: UIScrollView?
        var bestArea = CGFloat.greatestFiniteMagnitude
        func visit(_ view: UIView) {
            if let scrollView = view as? UIScrollView {
                let frame = scrollView.convert(scrollView.bounds, to: window)
                if frame.contains(anchor) {
                    let area = frame.width * frame.height
                    if area < bestArea {
                        bestArea = area
                        best = scrollView
                    }
                }
            }
            for sub in view.subviews { visit(sub) }
        }
        visit(window)
        return best
    }

    deinit {
        observation?.invalidate()
    }
}

extension DetailHeader where Accessory == EmptyView {
    init(
        title: String,
        subtitle: String,
        artworkURL: String? = nil,
        tintToken: String? = nil,
        tintKey: ArtworkTintKey? = nil,
        symbol: String = "music.note",
        onPlay: @escaping () -> Void,
        onShuffle: @escaping () -> Void
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            artworkURL: artworkURL,
            tintToken: tintToken,
            tintKey: tintKey,
            symbol: symbol,
            onPlay: onPlay,
            onShuffle: onShuffle,
            accessory: { EmptyView() }
        )
    }
}

/// Flat capsule-free action button with fully explicit fill and label colors, so
/// the pair can follow the artwork instead of the app accent.
private struct DetailActionButtonStyle: ButtonStyle {
    let fill: Color
    let label: Color
    let stroke: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(label)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(
                RoundedRectangle(cornerRadius: VerodromeTheme.cornerRadius, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: VerodromeTheme.cornerRadius, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
