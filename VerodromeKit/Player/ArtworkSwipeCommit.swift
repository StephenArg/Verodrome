import CoreGraphics

/// Whether a horizontal artwork drag should skip or snap back.
public enum ArtworkSwipeDecision: Equatable, Sendable {
    case commitNext
    case commitPrevious
    case cancel
}

/// Artwork swipe-to-skip. A slow drag commits at 45% of the hero width; a flick
/// projects a short way along the release velocity so a quick swipe can commit
/// earlier and a flick back can cancel. Rubber-banding when that side has no
/// neighbor is applied by the view.
public enum ArtworkSwipeCommit {
    public static let threshold: CGFloat = 0.45
    public static let rubberBand: CGFloat = 0.2
    /// How long the finger is treated as still travelling after lift. Short
    /// enough that a slow drag is still mostly distance, long enough that a
    /// Spotify-like flick crosses the threshold from well behind it.
    public static let projectionSeconds: CGFloat = 0.20

    public static func decision(
        translation: CGFloat,
        velocity: CGFloat = 0,
        width: CGFloat,
        canGoPrevious: Bool,
        canGoNext: Bool
    ) -> ArtworkSwipeDecision {
        guard width > 0 else { return .cancel }
        let projected = translation + velocity * projectionSeconds
        let progress = projected / width
        // Stay on the side the finger actually travelled. A flick the other way
        // can pull a past-threshold drag back under `threshold` and cancel.
        if translation < 0, progress <= -threshold, canGoNext { return .commitNext }
        if translation > 0, progress >= threshold, canGoPrevious { return .commitPrevious }
        return .cancel
    }

    /// 1:1 follow when that side has a neighbor; otherwise a short rubber-band.
    public static func dragOffset(
        translation: CGFloat,
        canGoPrevious: Bool,
        canGoNext: Bool
    ) -> CGFloat {
        if translation < 0, !canGoNext { return translation * rubberBand }
        if translation > 0, !canGoPrevious { return translation * rubberBand }
        return translation
    }
}
