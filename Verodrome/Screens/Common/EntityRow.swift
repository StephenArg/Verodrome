import SwiftUI
import VerodromeKit

struct PlayIndicator: View {
    let isPlaying: Bool
    var size: CGFloat = 14

    @EnvironmentObject private var themeManager: ThemeManager

    var body: some View {
        Image(systemName: isPlaying ? "waveform" : "play.fill")
            .font(.system(size: size, weight: .semibold))
            // Theme accent — not `.tint`, which album/playlist screens rebind to artwork.
            .foregroundStyle(themeManager.accentColor)
            .symbolEffect(.variableColor.iterative, isActive: isPlaying)
            .accessibilityLabel("Now playing")
    }
}

struct ExplicitBadge: View {
    var body: some View {
        Text("E")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(.secondary, lineWidth: 1)
            )
            .accessibilityLabel("Explicit")
    }
}

struct EntityRow: View {
    let title: String
    let subtitle: String
    var artworkURL: String? = nil
    var symbol: String = "music.note"
    var isPlaying: Bool = false
    var trailing: String? = nil
    /// Drawn as five stars in place of `trailing`, the way the Songs list shows the key
    /// when it's sorted by rating.
    var trailingRating: Int? = nil
    /// When set, shows this track position instead of artwork (e.g. album track lists).
    /// Combined with `showsArtworkBesideNumber`, the rank sits to the left of the cover.
    var trackNumber: Int? = nil
    /// Ranked lists (Popular) keep both the number and the album cover.
    var showsArtworkBesideNumber: Bool = false
    /// When true (default), uses lightweight 80px artwork suitable for scrolling lists.
    var compactArtwork: Bool = true
    /// Per-track download state, drawn to the left of the subtitle (artist / album).
    /// `.none` (and nil) leave the subtitle flush with the leading edge.
    var downloadStatus: DownloadStatus? = nil
    var isExplicit: Bool = false
    /// A heart before the subtitle, as the Playlists list draws favorites.
    var isFavorite: Bool = false

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
                    if isExplicit {
                        ExplicitBadge()
                    }
                    if isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 12, weight: .semibold))
                            // Theme accent, not `.tint`, for the same reason as the
                            // download glyph above.
                            .foregroundStyle(themeManager.accentColor)
                            .accessibilityLabel("Favorite")
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

            if let trailingRating {
                ratingStars(trailingRating)
            } else if let trailing {
                Text(trailing)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private func ratingStars(_ rating: Int) -> some View {
        let filled = max(0, min(5, rating))
        return (Text(String(repeating: "★", count: filled))
            .foregroundStyle(themeManager.accentColor)
            + Text(String(repeating: "☆", count: 5 - filled))
            .foregroundStyle(Color(uiColor: .tertiaryLabel)))
            .font(.subheadline)
            .accessibilityLabel(filled == 1 ? "1 star" : "\(filled) stars")
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
        if let trackNumber, showsArtworkBesideNumber {
            HStack(spacing: 8) {
                rankLabel(trackNumber, width: 16, alignment: .leading)
                artwork
            }
        } else if let trackNumber {
            rankLabel(trackNumber, width: 28, alignment: .trailing)
        } else {
            artwork
        }
    }

    private func rankLabel(_ number: Int, width: CGFloat, alignment: Alignment) -> some View {
        Text("\(number)")
            .font(.body.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: alignment)
    }

    /// ArtworkView already clipShapes; don't add another clipped()/clipShape pass
    /// per scrolling cell.
    private var artwork: some View {
        Group {
            if compactArtwork {
                ArtworkView.thumbnail(artworkURL, symbol: symbol)
            } else {
                ArtworkView.grid(artworkURL, symbol: symbol)
            }
        }
        .frame(width: 48, height: 48)
    }
}
