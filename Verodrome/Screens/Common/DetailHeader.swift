import SwiftUI

struct DetailHeader<Accessory: View>: View {
    let title: String
    let subtitle: String
    /// Artwork the buttons take their color from. Defaults to the hero art, but
    /// screens whose background falls back to another cover (an artist with no
    /// image, say) should pass the same token they tint the background with.
    let artworkURL: String?
    let tintToken: String?
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
        symbol: String = "music.note",
        onPlay: @escaping () -> Void,
        onShuffle: @escaping () -> Void,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.tintToken = tintToken
        self.symbol = symbol
        self.onPlay = onPlay
        self.onShuffle = onShuffle
        self.accessory = accessory
    }

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var router: AppRouter
    @State private var tint: ArtworkTint?

    private var resolvedTint: ArtworkTint {
        tint ?? ArtworkTint(hue: 0, saturation: 0)
    }

    var body: some View {
        VStack(spacing: 20) {
            ArtworkView.hero(artworkURL, symbol: symbol)
                .frame(width: 280, height: 280)
                .frame(maxWidth: .infinity)
                .shadow(color: .black.opacity(0.2), radius: 24, y: 12)

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
        .animation(.easeOut(duration: 0.4), value: tint)
        .task(id: tintToken ?? artworkURL) {
            tint = await ArtworkTintResolver.shared.tint(for: tintToken ?? artworkURL)
        }
    }

    private var playFill: Color {
        resolvedTint.primaryButtonFill(for: colorScheme)
    }
}

extension DetailHeader where Accessory == EmptyView {
    init(
        title: String,
        subtitle: String,
        artworkURL: String? = nil,
        tintToken: String? = nil,
        symbol: String = "music.note",
        onPlay: @escaping () -> Void,
        onShuffle: @escaping () -> Void
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            artworkURL: artworkURL,
            tintToken: tintToken,
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
