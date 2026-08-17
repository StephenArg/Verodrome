import SwiftUI
import VerodromeKit

/// Identity for a cover that artwork swipe can peek beside the playing track.
struct ArtworkPeek: Equatable {
    var trackID: String?
    var urlString: String?
    var symbol: String
}

struct LargeArtworkView: View {
    var urlString: String?
    var symbol: String = "music.note"
    /// Playing track identity. Drives the slide, so covers shared across an album still
    /// move on every skip.
    var trackID: String? = nil
    var slideDirection: ArtworkSlideDirection = .forward
    var previousCover: ArtworkPeek? = nil
    var nextCover: ArtworkPeek? = nil
    /// Live streams keep swipe-down dismiss but do not skip.
    var allowsSkipSwipe: Bool = true
    var onSkipNext: (() -> Void)? = nil
    var onSkipPrevious: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    /// Floor for the cover, so an extremely short layout still shows recognizable
    /// art rather than a sliver.
    private let minimumSide: CGFloat = 140

    /// Short enough that a run of skips doesn't stack a backlog of half-finished slides.
    private static let slideDuration: TimeInterval = 0.16
    private static let axisLockSlop: CGFloat = 14
    /// High enough that a double-tap for lyrics is not stolen by the skip drag.
    private static let dragMinimumDistance: CGFloat = 16
    private static let dismissTranslation: CGFloat = 80

    /// The cover currently parked in the hero slot.
    @State private var shownTrackID: String?
    @State private var shownURL: String?
    @State private var shownSymbol: String = "music.note"
    @State private var shownOffset: CGFloat = 0

    /// The cover that just left (or is leaving). Kept only for the duration of a slide.
    @State private var leavingTrackID: String?
    @State private var leavingURL: String?
    @State private var leavingSymbol: String = "music.note"
    @State private var leavingOffset: CGFloat = 0

    /// Neighbor being dragged in. Separate from `leaving*` so an automatic skip-slide
    /// and an in-progress swipe don't share a layer.
    @State private var peekingTrackID: String?
    @State private var peekingURL: String?
    @State private var peekingSymbol: String = "music.note"
    @State private var peekingOffset: CGFloat = 0

    /// Bumped on every skip so a completion from an interrupted slide can't clear the
    /// cover that replaced it.
    @State private var slideGeneration = 0
    @State private var dragAxis: ArtworkSwipeAxis?
    @State private var isInteractiveDrag = false
    /// Added to the live translation so a new flick can pick up a cover that is
    /// still settling from the last skip, instead of jumping or waiting.
    @State private var dragOriginOffset: CGFloat = 0

    var body: some View {
        // Explicit offsets rather than `.transition(.move)`: SwiftUI latches the removal
        // edge onto the outgoing view when it was inserted, so a forward skip left the
        // cover exiting left even on the next backward skip. Driving both layers here
        // means the direction of *this* skip controls both edges.
        //
        // `ArtworkView` is already an aspect-fit square, so offering it a flexible box
        // yields the largest square that fits *both* the content width and the height the
        // player has left over. Pinning the side to the width instead would push the
        // transport controls off the bottom on shorter screens.
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .top) {
                if leavingTrackID != nil {
                    cover(url: leavingURL, symbol: leavingSymbol)
                        .offset(x: leavingOffset)
                        .allowsHitTesting(false)
                }

                if peekingTrackID != nil {
                    cover(url: peekingURL, symbol: peekingSymbol)
                        .offset(x: peekingOffset)
                        .allowsHitTesting(false)
                }

                cover(url: shownURL, symbol: shownSymbol)
                    .offset(x: shownOffset)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .clipped()
            .onAppear {
                guard shownTrackID == nil else { return }
                shownTrackID = trackID
                shownURL = urlString
                shownSymbol = symbol
            }
            .onChange(of: trackID) { _, newID in
                beginSlide(to: newID, width: width)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: Self.dragMinimumDistance)
                    .onChanged { value in
                        handleDragChanged(value, width: width)
                    }
                    .onEnded { value in
                        handleDragEnded(value, width: width)
                    }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .frame(minHeight: minimumSide)
    }

    private func beginSlide(to newID: String?, width: CGFloat) {
        if isInteractiveDrag || peekingTrackID != nil {
            clearPeek()
            isInteractiveDrag = false
            dragAxis = nil
            dragOriginOffset = 0
        }
        guard newID != shownTrackID else {
            shownURL = urlString
            shownSymbol = symbol
            return
        }
        // First paint after appear with a nil → value change: no slide.
        guard shownTrackID != nil else {
            shownTrackID = newID
            shownURL = urlString
            shownSymbol = symbol
            return
        }

        let outgoingEnd: CGFloat = slideDirection == .forward ? -width : width
        let incomingStart: CGFloat = slideDirection == .forward ? width : -width

        // Promote whatever is on screen *at its current offset* — resetting to 0 mid-slide
        // is what made rapid skips jump. Drop the previous leaving cover; one exit lane.
        leavingTrackID = shownTrackID
        leavingURL = shownURL
        leavingSymbol = shownSymbol
        leavingOffset = shownOffset

        shownTrackID = newID
        shownURL = urlString
        shownSymbol = symbol

        // Park the incoming cover off-screen without animating from the old offset.
        var prep = Transaction()
        prep.disablesAnimations = true
        withTransaction(prep) {
            shownOffset = incomingStart
        }

        animateSlide(shownTo: 0, leavingTo: outgoingEnd)
    }

    private func handleDragChanged(_ value: DragGesture.Value, width: CGFloat) {
        if dragAxis == nil {
            let dx = abs(value.translation.width)
            let dy = abs(value.translation.height)
            if dx > dy + 2, dx >= Self.axisLockSlop {
                dragAxis = .horizontal
            } else if dy > dx + 2, dy >= Self.axisLockSlop {
                dragAxis = .vertical
            } else {
                return
            }
        }

        guard dragAxis == .horizontal, allowsSkipSwipe else { return }
        if !isInteractiveDrag {
            beginInteractiveDrag(from: value)
        }

        let offset = ArtworkSwipeCommit.dragOffset(
            translation: value.translation.width,
            canGoPrevious: previousCover != nil,
            canGoNext: nextCover != nil
        )
        applyDragOffsets(translation: offset, width: width)
    }

    /// Steal an in-flight settle so the next flick is not queued behind the ease-out.
    private func beginInteractiveDrag(from value: DragGesture.Value) {
        slideGeneration += 1
        leavingTrackID = nil
        leavingURL = nil
        leavingOffset = 0
        // At rest, track the finger 1:1 (including the minimum-distance slop).
        // Mid-slide, hold the current visual and add only further movement.
        dragOriginOffset = abs(shownOffset) > 0.5
            ? shownOffset - value.translation.width
            : 0
        isInteractiveDrag = true
    }

    private func applyDragOffsets(translation: CGFloat, width: CGFloat) {
        let offset = dragOriginOffset + translation
        var prep = Transaction()
        prep.disablesAnimations = true
        withTransaction(prep) {
            shownOffset = offset
            if offset < 0, let next = nextCover {
                peekingTrackID = next.trackID
                peekingURL = next.urlString
                peekingSymbol = next.symbol
                peekingOffset = width + offset
            } else if offset > 0, let previous = previousCover {
                peekingTrackID = previous.trackID
                peekingURL = previous.urlString
                peekingSymbol = previous.symbol
                peekingOffset = -width + offset
            } else {
                clearPeek()
            }
        }
    }

    private func handleDragEnded(_ value: DragGesture.Value, width: CGFloat) {
        let axis = dragAxis
        dragAxis = nil

        if axis == .vertical {
            isInteractiveDrag = false
            if value.translation.height > Self.dismissTranslation {
                onDismiss?()
            }
            return
        }

        guard axis == .horizontal, isInteractiveDrag else {
            isInteractiveDrag = false
            return
        }

        let decision = ArtworkSwipeCommit.decision(
            translation: shownOffset,
            velocity: value.velocity.width,
            width: width,
            canGoPrevious: previousCover != nil,
            canGoNext: nextCover != nil
        )
        switch decision {
        case .commitNext:
            commitSwipe(to: nextCover, width: width, direction: .forward, skip: onSkipNext)
        case .commitPrevious:
            commitSwipe(to: previousCover, width: width, direction: .backward, skip: onSkipPrevious)
        case .cancel:
            cancelSwipe()
        }
    }

    private func commitSwipe(
        to incoming: ArtworkPeek?,
        width: CGFloat,
        direction: ArtworkSlideDirection,
        skip: (() -> Void)?
    ) {
        guard let incoming else {
            cancelSwipe()
            return
        }

        leavingTrackID = shownTrackID
        leavingURL = shownURL
        leavingSymbol = shownSymbol
        leavingOffset = shownOffset

        let incomingOffset = peekingOffset
        shownTrackID = incoming.trackID
        shownURL = incoming.urlString
        shownSymbol = incoming.symbol
        clearPeek()
        isInteractiveDrag = false
        dragOriginOffset = 0

        var prep = Transaction()
        prep.disablesAnimations = true
        withTransaction(prep) {
            shownOffset = incomingOffset
        }

        let outgoingEnd: CGFloat = direction == .forward ? -width : width
        animateSlide(shownTo: 0, leavingTo: outgoingEnd)
        skip?()
    }

    private func cancelSwipe() {
        let peekRest = peekingTrackID == nil ? 0 : peekingOffset - shownOffset
        isInteractiveDrag = false
        dragOriginOffset = 0
        slideGeneration += 1
        let generation = slideGeneration
        withAnimation(.easeOut(duration: Self.slideDuration)) {
            shownOffset = 0
            if peekingTrackID != nil {
                peekingOffset = peekRest
            }
        } completion: {
            guard generation == slideGeneration else { return }
            clearPeek()
        }
    }

    private func animateSlide(shownTo: CGFloat, leavingTo: CGFloat) {
        slideGeneration += 1
        let generation = slideGeneration
        withAnimation(.easeOut(duration: Self.slideDuration)) {
            shownOffset = shownTo
            leavingOffset = leavingTo
        } completion: {
            guard generation == slideGeneration else { return }
            leavingTrackID = nil
            leavingURL = nil
            leavingOffset = 0
        }
    }

    private func clearPeek() {
        peekingTrackID = nil
        peekingURL = nil
        peekingSymbol = "music.note"
        peekingOffset = 0
    }

    private func cover(url: String?, symbol: String) -> some View {
        ArtworkView.hero(url, symbol: symbol)
            .shadow(color: .black.opacity(0.25), radius: 24, y: 12)
            .padding(.horizontal, VerodromeTheme.playerContentHorizontalPadding)
    }
}

private enum ArtworkSwipeAxis {
    case horizontal
    case vertical
}
