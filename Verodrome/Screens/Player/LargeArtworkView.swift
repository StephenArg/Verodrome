import SwiftUI
import UIKit
import VerodromeKit

struct LargeArtworkView: View {
    var urlString: String?
    var symbol: String = "music.note"
    @EnvironmentObject private var themeManager: ThemeManager

    /// Floor for the cover, so an extremely short layout still shows recognizable
    /// art rather than a sliver.
    private let minimumSide: CGFloat = 140

    var body: some View {
        // `ArtworkView` is already an aspect-fit square, so offering it a flexible
        // box yields the largest square that fits *both* the content width and the
        // height the player has left over. Pinning the side to the width instead
        // would push the transport controls off the bottom on shorter screens.
        ArtworkView.hero(urlString, symbol: symbol)
            .shadow(color: .black.opacity(0.25), radius: 24, y: 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .frame(minHeight: minimumSide)
            .padding(.horizontal, VerodromeTheme.playerContentHorizontalPadding)
            .task(id: urlString) {
                let image = await ArtworkResolver.shared.loadImage(
                    for: urlString,
                    size: ArtworkPixelSize.player
                )
                // The track can change while the cover is still loading; without this the
                // previous album's tint wins the race and stays behind the new one.
                guard !Task.isCancelled else { return }
                await themeManager.updatePlayerTint(from: image, token: urlString)
            }
    }
}
