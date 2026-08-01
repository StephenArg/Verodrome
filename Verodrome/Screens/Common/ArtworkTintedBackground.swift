import SwiftUI
import UIKit
import VerodromeKit

/// Full-screen background tinted with the dominant color of a piece of artwork.
///
/// Only the artwork's hue and saturation are kept; lightness comes from the
/// current appearance, so the same album yields a pale tint in light mode and a
/// deep shade in dark mode and system label colors stay legible either way.
struct ArtworkTintedBackground: View {
    let token: String?

    @Environment(\.colorScheme) private var colorScheme
    @State private var tint: ArtworkTint?

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)

            if let tint {
                LinearGradient(
                    colors: [tint.top(for: colorScheme), tint.bottom(for: colorScheme)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.4), value: tint)
        .task(id: token) {
            tint = await ArtworkTintResolver.shared.tint(for: token)
        }
    }
}

extension View {
    /// Replaces the scrollable content background of a detail screen with a tint
    /// derived from `token`'s artwork.
    func artworkTintedBackground(token: String?) -> some View {
        scrollContentBackground(.hidden)
            .background(ArtworkTintedBackground(token: token))
    }
}

// MARK: - Tint

/// One artwork hue, rendered as a light tint or a dark shade on demand.
struct ArtworkTint: Equatable {
    let hue: CGFloat
    let saturation: CGFloat

    /// The strongest reading of the hue, used at the top of the screen behind the cover.
    func top(for scheme: ColorScheme) -> Color {
        color(for: scheme, saturationScale: 1, brightness: scheme == .dark ? 0.26 : 0.96)
    }

    /// The foot of the gradient, close enough to the plain system background that
    /// a long track list doesn't sit on a flat wash of color.
    func bottom(for scheme: ColorScheme) -> Color {
        color(
            for: scheme,
            saturationScale: scheme == .dark ? 0.5 : 0.3,
            brightness: scheme == .dark ? 0.09 : 0.99
        )
    }

    /// True when the artwork has no hue worth carrying into the UI.
    var isNeutral: Bool { saturation < Self.neutralSaturation }

    private func color(for scheme: ColorScheme, saturationScale: CGFloat, brightness: CGFloat) -> Color {
        // Below this saturation the hue carries no usable color, and tinting only
        // adds a random cast to what should read as a neutral gray.
        guard !isNeutral else {
            return Color(hue: 0, saturation: 0, brightness: brightness)
        }
        // Clamped so washed-out covers still tint visibly and vivid ones don't
        // overpower the labels drawn on top.
        let range: ClosedRange<CGFloat> = scheme == .dark ? 0.22...0.65 : 0.16...0.42
        let clamped = min(max(saturation, range.lowerBound), range.upperBound)
        return Color(
            hue: hue,
            saturation: clamped * saturationScale,
            brightness: brightness
        )
    }

    private static let neutralSaturation: CGFloat = 0.06
}

// MARK: - Action buttons

/// Fills and labels for the Play/Shuffle pair on a detail screen, kept in the
/// artwork's hue but pushed far enough from `ArtworkTint.top(for:)` in lightness
/// that the buttons never sink into the background they sit on.
extension ArtworkTint {
    /// Solid fill for the primary action, saturated and well clear of the
    /// background's lightness in either appearance.
    func primaryButtonFill(for scheme: ColorScheme) -> Color {
        guard !isNeutral else {
            return Color(hue: 0, saturation: 0, brightness: scheme == .dark ? 0.92 : 0.16)
        }
        let range: ClosedRange<CGFloat> = scheme == .dark ? 0.40...0.80 : 0.55...0.95
        let clamped = min(max(saturation, range.lowerBound), range.upperBound)
        return Color(hue: hue, saturation: clamped, brightness: scheme == .dark ? 0.92 : 0.52)
    }

    /// Muted companion fill for the secondary action: readable as a surface of
    /// its own, but never competing with the primary button.
    func secondaryButtonFill(for scheme: ColorScheme) -> Color {
        guard !isNeutral else {
            return Color(hue: 0, saturation: 0, brightness: scheme == .dark ? 0.30 : 1)
        }
        let range: ClosedRange<CGFloat> = scheme == .dark ? 0.18...0.40 : 0.05...0.14
        let clamped = min(max(saturation, range.lowerBound), range.upperBound)
        return Color(hue: hue, saturation: clamped, brightness: scheme == .dark ? 0.42 : 1)
    }

    /// Label for the secondary action, tinted just enough to belong to the
    /// artwork while staying high contrast on `secondaryButtonFill(for:)`.
    func secondaryButtonLabel(for scheme: ColorScheme) -> Color {
        guard !isNeutral else {
            return Color(hue: 0, saturation: 0, brightness: scheme == .dark ? 0.97 : 0.12)
        }
        return scheme == .dark
            ? Color(hue: hue, saturation: min(saturation, 0.14), brightness: 0.98)
            : Color(hue: hue, saturation: min(max(saturation, 0.55), 0.95), brightness: 0.30)
    }

    /// Hairline edge that keeps the near-white light-mode secondary button from
    /// blending into a pale background gradient.
    func secondaryButtonStroke(for scheme: ColorScheme) -> Color {
        secondaryButtonLabel(for: scheme).opacity(scheme == .dark ? 0.16 : 0.14)
    }
}

extension Color {
    /// Black or white, whichever has the higher WCAG contrast ratio against the
    /// receiver. Artwork hues range from near-black navies to bright yellows, so
    /// a fixed label color is unreadable on one end or the other.
    var contrastingLabel: Color {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return .white
        }

        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.03928 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }

        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        let contrastOnWhite = 1.05 / (luminance + 0.05)
        let contrastOnBlack = (luminance + 0.05) / 0.05
        return contrastOnWhite >= contrastOnBlack ? .white : Color(white: 0.08)
    }
}

// MARK: - Resolver

/// Extracts and caches artwork tints. Color quantization runs off the main
/// thread, and each token is only ever quantized once per launch.
@MainActor
final class ArtworkTintResolver {
    static let shared = ArtworkTintResolver()

    private var cache: [String: ArtworkTint] = [:]
    private var inFlight: [String: Task<ArtworkTint?, Never>] = [:]

    func tint(for token: String?) async -> ArtworkTint? {
        guard let token, !token.isEmpty else { return nil }
        if let cached = cache[token] { return cached }
        if let running = inFlight[token] { return await running.value }

        let task = Task<ArtworkTint?, Never> {
            guard let image = await Self.artwork(for: token),
                  let components = await DominantColorExtractor.dominantComponents(of: image)
            else { return nil }
            return ArtworkTint(hue: components.hue, saturation: components.saturation)
        }
        inFlight[token] = task
        let tint = await task.value
        inFlight[token] = nil
        if let tint { cache[token] = tint }
        return tint
    }

    /// Prefers any already-decoded size — the detail header's hero art is
    /// normally in the cache — so opening an album costs no extra download.
    private static func artwork(for token: String) async -> UIImage? {
        let cachedSizes = [
            ArtworkPixelSize.player,
            ArtworkPixelSize.detail,
            ArtworkPixelSize.grid,
            ArtworkPixelSize.homeTile,
            ArtworkPixelSize.thumbnail
        ]
        for size in cachedSizes {
            if let cached = ArtworkImageCache.shared.image(for: token, size: size) {
                return cached
            }
        }
        return await ArtworkResolver.shared.loadImage(for: token, size: ArtworkPixelSize.homeTile)
    }
}
