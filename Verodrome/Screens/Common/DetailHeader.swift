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
    /// How far the list is rubber-banded past its top, in points. Zero at rest.
    @State private var pullDistance: CGFloat = 0

    private var resolvedTint: ArtworkTint {
        tint ?? ArtworkTint(hue: 0, saturation: 0)
    }

    /// Grows point for point with the pull, so the cover exactly fills the space the
    /// drag opens up and its bottom edge always meets the title.
    private var growth: CGFloat {
        min(pullDistance, DetailHeaderMetrics.maxGrowth)
    }

    var body: some View {
        VStack(spacing: 20) {
            stretchyArtwork

            VStack(spacing: 6) {
                Text(title)
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            accessory()

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
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background {
            ScrollPullReader { pull in
                guard abs(pull - pullDistance) > 0.5 else { return }
                // The value already carries the scroll view's rubber-band curve, so an
                // animation on top of it would only lag behind the finger.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { pullDistance = pull }
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

    /// The cover keeps a fixed layout slot and is only drawn larger. Giving it real
    /// height instead would grow the row into the overscroll that caused it, and the
    /// list would immediately clamp back — the art would flicker rather than stretch.
    ///
    /// The slot travels down with the pull, so lifting the art by the same amount pins
    /// its top where it sits at rest and grows it downward into the space that opened,
    /// landing its bottom edge exactly where the title now starts.
    private var stretchyArtwork: some View {
        let base = DetailHeaderMetrics.artworkSize
        return Color.clear
            .frame(width: base, height: base)
            .overlay(alignment: .top) {
                ArtworkView.hero(artworkURL, symbol: symbol)
                    .frame(width: base + growth, height: base + growth)
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
                    .offset(y: -growth)
            }
            .frame(maxWidth: .infinity)
    }

    private var playFill: Color {
        resolvedTint.primaryButtonFill(for: colorScheme)
    }
}

/// Constants for the stretchy hero — kept outside `DetailHeader` because generic
/// types can't hold static stored properties.
private enum DetailHeaderMetrics {
    static let artworkSize: CGFloat = 280
    /// Caps growth just under the width of the narrowest phone.
    static let maxGrowth: CGFloat = 110
}

/// Reports how far the enclosing list is pulled past its top.
///
/// Read from the scroll view rather than a `GeometryReader`: geometry inside a `List`
/// row is measured against the scrolling content, which doesn't move relative to the
/// row during a rubber-band, so it can't see overscroll at all.
private struct ScrollPullReader: UIViewRepresentable {
    var onPull: (CGFloat) -> Void

    func makeUIView(context: Context) -> ScrollPullSensor {
        let sensor = ScrollPullSensor()
        sensor.onPull = onPull
        return sensor
    }

    func updateUIView(_ uiView: ScrollPullSensor, context: Context) {
        uiView.onPull = onPull
    }

    static func dismantleUIView(_ uiView: ScrollPullSensor, coordinator: ()) {
        uiView.stopObserving()
    }
}

private final class ScrollPullSensor: UIView {
    var onPull: ((CGFloat) -> Void)?

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
            self.unclipAncestors()
            self.onPull?(Self.pull(of: scrollView))
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

    private static func pull(of scrollView: UIScrollView) -> CGFloat {
        max(0, -(scrollView.contentOffset.y + scrollView.adjustedContentInset.top))
    }

    private func enclosingScrollView() -> UIScrollView? {
        var view: UIView? = superview
        while let current = view {
            if let scrollView = current as? UIScrollView { return scrollView }
            view = current.superview
        }
        return nil
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
