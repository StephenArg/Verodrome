import SwiftUI
import VerodromeKit

/// Compact now-playing bar. On iOS 26+ this is hosted in `tabViewBottomAccessory`
/// so the system provides Liquid Glass and the Amperfy/Music-style morph animation.
struct MiniPlayerBar: View {
    @EnvironmentObject private var nowPlaying: NowPlayingModel
    @EnvironmentObject private var progress: PlayerProgressModel
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var player: PlayerViewModel

    /// When true, draw our own glass chrome (overlay / iPad). When false, the
    /// system tab accessory supplies Liquid Glass — only content is rendered.
    var drawsChrome: Bool = false

    var body: some View {
        Group {
            if let item = nowPlaying.currentItem {
                content(for: item)
            }
        }
    }

    @ViewBuilder
    private func content(for item: QueueItem) -> some View {
        let bar = HStack(spacing: 12) {
            Button(action: openPlayer) {
                HStack(spacing: 12) {
                    artwork(for: item)
                        .animation(.easeInOut(duration: 0.25), value: item.id)

                    VStack(alignment: .leading, spacing: 2) {
                        MarqueeText(
                            text: item.title,
                            font: .footnote.weight(.semibold),
                            speed: 26,
                            fitAlignment: .leading
                        )
                        .foregroundStyle(.primary)

                        // Only one subtitle line fits, so a stall takes precedence
                        // over the artist name while it lasts.
                        if player.statusMessage.isEmpty {
                            Text(item.artist ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        } else {
                            Label(player.statusMessage, systemImage: "wifi.exclamationmark")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    // minWidth 0 lets the column shrink so MarqueeText gets a real
                    // bounded width instead of expanding past the trailing controls.
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .animation(.easeInOut(duration: 0.2), value: item.id)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .layoutPriority(0)

            AirPlayRoutePicker()
                .frame(width: 28, height: 28)
                .accessibilityLabel("Audio output")
                .layoutPriority(1)

            Button {
                player.playPause()
            } label: {
                Image(systemName: nowPlaying.isPlaying ? "pause.fill" : "play.fill")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
        }
        .padding(.horizontal, drawsChrome ? 14 : 12)
        .padding(.vertical, drawsChrome ? 6 : 2)
        .overlay(alignment: .bottom) {
            if !item.isLiveStream, progress.duration > 0 {
                progressBar
                    .padding(.horizontal, drawsChrome ? 14 : 12)
                    .padding(.bottom, 3)
            }
        }

        if drawsChrome {
            bar
                .background {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .shadow(color: .black.opacity(0.12), radius: 16, y: 4)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: .bottom)),
                        removal: .move(edge: .bottom).combined(with: .opacity)
                    )
                )
        } else {
            bar
        }
    }

    /// Thin, full-width playback progress indicator pinned to the bottom edge.
    private var progressBar: some View {
        GeometryReader { geo in
            let fraction = min(max(progress.currentTime / progress.duration, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.15))

                Capsule()
                    .fill(Color.accentColor.opacity(0.85))
                    .frame(width: max(geo.size.width * fraction, 2))
            }
            .animation(nil, value: fraction)
        }
        .frame(height: 2)
    }

    private func artwork(for item: QueueItem) -> some View {
        ArtworkView.thumbnail(
            item.artworkId,
            symbol: item.kind == .radio ? "dot.radiowaves.left.and.right" : "music.note"
        )
            .frame(width: 40, height: 40)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.vertical, 4)
    }

    private func openPlayer() {
        router.openPlayer()
    }
}

/// Overlay host used on iPad / pre-iOS 26 fallback. Animates appear/disappear smoothly.
struct MiniPlayerContainerView: View {
    @EnvironmentObject private var nowPlaying: NowPlayingModel

    var body: some View {
        MiniPlayerBar(drawsChrome: true)
            .animation(
                .spring(response: 0.42, dampingFraction: 0.84),
                value: nowPlaying.currentItem?.id
            )
    }
}
