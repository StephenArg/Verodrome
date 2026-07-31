import SwiftUI
import UIKit
import VerodromeKit

struct LargeArtworkView: View {
    var urlString: String?
    var symbol: String = "music.note"
    @EnvironmentObject private var themeManager: ThemeManager

    /// Shared with the player title so marquee width matches artwork.
    static let side: CGFloat = 320

    var body: some View {
        ArtworkView.hero(urlString, symbol: symbol)
            .frame(width: Self.side, height: Self.side)
            .frame(maxWidth: .infinity)
            .shadow(color: .black.opacity(0.25), radius: 24, y: 12)
            .padding(.horizontal)
            .task(id: urlString) {
                let image = await ArtworkResolver.shared.loadImage(
                    for: urlString,
                    size: ArtworkPixelSize.player
                )
                themeManager.updatePlayerTint(from: image)
            }
    }
}
