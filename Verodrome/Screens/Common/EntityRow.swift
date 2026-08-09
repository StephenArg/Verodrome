import SwiftUI
import VerodromeKit

struct PlayIndicator: View {
    let isPlaying: Bool
    var size: CGFloat = 14

    var body: some View {
        Image(systemName: isPlaying ? "waveform" : "play.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.tint)
            .symbolEffect(.variableColor.iterative, isActive: isPlaying)
            .accessibilityLabel("Now playing")
    }
}

struct EntityRow: View {
    let title: String
    let subtitle: String
    var artworkURL: String? = nil
    var symbol: String = "music.note"
    var isPlaying: Bool = false
    var trailing: String? = nil
    /// When set, shows this track position instead of artwork (e.g. album track lists).
    var trackNumber: Int? = nil
    /// When true (default), uses lightweight 80px artwork suitable for scrolling lists.
    var compactArtwork: Bool = true
    /// Per-track download state, drawn to the left of the subtitle (artist / album).
    /// `.none` (and nil) leave the subtitle flush with the leading edge.
    var downloadStatus: DownloadStatus? = nil

    @EnvironmentObject private var themeManager: ThemeManager

    var body: some View {
        HStack(spacing: 12) {
            leadingAccessory

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if isPlaying {
                        PlayIndicator(isPlaying: true, size: 13)
                    }
                    Text(title)
                        .font(.body)
                        .lineLimit(1)
                }
                HStack(spacing: 5) {
                    if let downloadStatus, downloadStatus != .none {
                        // Theme accent, not environment tint — album/playlist screens rebind
                        // `.tint` to the artwork fill for the back chevron.
                        DownloadStatusIcon(
                            status: downloadStatus,
                            size: 12,
                            tint: themeManager.accentColor
                        )
                        .accessibilityLabel(downloadAccessibilityLabel(for: downloadStatus))
                    }
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            // Claim the middle of the row. A trailing `Spacer` left the text stack at its
            // ideal width, so a long title could compress the column and truncate a short
            // subtitle ("12 songs") while empty space still showed past the ellipsis.
            .frame(maxWidth: .infinity, alignment: .leading)

            if let trailing {
                Text(trailing)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private func downloadAccessibilityLabel(for status: DownloadStatus) -> String {
        switch status {
        case .pending: return "Waiting to download"
        case .waiting: return "Waiting for Wi-Fi"
        case .downloading: return "Downloading"
        case .partial: return "Partially downloaded"
        case .cached: return "Cached"
        case .downloaded: return "Downloaded"
        case .failed: return "Download failed"
        case .none: return ""
        }
    }

    @ViewBuilder
    private var leadingAccessory: some View {
        if let trackNumber {
            Text("\(trackNumber)")
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
        } else {
            Group {
                if compactArtwork {
                    ArtworkView.thumbnail(artworkURL, symbol: symbol)
                } else {
                    ArtworkView.grid(artworkURL, symbol: symbol)
                }
            }
            .frame(width: 48, height: 48)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: VerodromeTheme.artworkCornerRadius, style: .continuous))
        }
    }
}
