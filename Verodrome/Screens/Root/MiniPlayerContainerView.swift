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
                            font: .subheadline.weight(.semibold),
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
                        } else {
                            Label(player.statusMessage, systemImage: "wifi.exclamationmark")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: item.id)

                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            AirPlayRoutePicker()
                .frame(width: 28, height: 28)
                .accessibilityLabel("Audio output")

            Button {
                player.playPause()
            } label: {
                Image(systemName: nowPlaying.isPlaying ? "pause.fill" : "play.fill")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, drawsChrome ? 14 : 12)
        .padding(.vertical, drawsChrome ? 10 : 6)
        .overlay(alignment: .bottom) {
            if !item.isLiveStream, progress.duration > 0 {
                GeometryReader { geo in
                    let fraction = min(max(progress.currentTime / progress.duration, 0), 1)
                    Capsule()
                        .fill(Color.accentColor.opacity(0.85))
                        .frame(width: max(geo.size.width * fraction, 2), height: 2)
                        .animation(nil, value: fraction)
                }
                .frame(height: 2)
                .padding(.horizontal, drawsChrome ? 14 : 4)
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

    private func artwork(for item: QueueItem) -> some View {
        ArtworkView.thumbnail(
            item.artworkId,
            symbol: item.kind == .radio ? "dot.radiowaves.left.and.right" : "music.note"
        )
            .frame(width: 40, height: 40)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func openPlayer() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            router.showFullPlayer = true
        }
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
