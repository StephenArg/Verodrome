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
            .frame(width: size + 6)
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

    var body: some View {
        HStack(spacing: 12) {
            leadingAccessory

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isPlaying, trackNumber == nil {
                PlayIndicator(isPlaying: true)
            } else if let trailing {
                Text(trailing)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var leadingAccessory: some View {
        if let trackNumber {
            Group {
                if isPlaying {
                    PlayIndicator(isPlaying: true, size: 16)
                } else {
                    Text("\(trackNumber)")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
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
