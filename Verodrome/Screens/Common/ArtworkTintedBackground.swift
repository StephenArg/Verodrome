import SwiftUI
import UIKit
import VerodromeKit
import DominantColors

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

    private func color(for scheme: ColorScheme, saturationScale: CGFloat, brightness: CGFloat) -> Color {
        // Below this saturation the hue carries no usable color, and tinting only
        // adds a random cast to what should read as a neutral gray.
        guard saturation >= 0.06 else {
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
                  let components = await Self.dominantComponents(of: image)
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

    private static func dominantComponents(of image: UIImage) async -> ArtworkTintComponents? {
        await Task.detached(priority: .userInitiated) {
            let colors = try? DominantColors.dominantColors(
                uiImage: image,
                quality: .fair,
                maxCount: 1,
                options: [.excludeBlack, .excludeWhite, .excludeGray],
                sorting: .frequency
            )
            guard let dominant = colors?.first else { return nil }
            return ArtworkTintComponents(dominant)
        }.value
    }
}

/// Hue/saturation crossing back from the quantizer, so no `UIColor` has to.
private struct ArtworkTintComponents: Sendable {
    let hue: CGFloat
    let saturation: CGFloat

    init?(_ color: UIColor) {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0

        if !color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) {
            // Quantized colors can land in a non-RGB space, where HSB is unavailable.
            guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
                  let converted = color.cgColor.converted(to: sRGB, intent: .defaultIntent, options: nil),
                  UIColor(cgColor: converted)
                    .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            else { return nil }
        }

        self.hue = hue
        self.saturation = saturation
    }
}
