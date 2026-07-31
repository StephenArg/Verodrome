import SwiftUI
import UIKit
import VerodromeKit

struct LargeArtworkView: View {
    var urlString: String?
    var symbol: String = "music.note"
    @EnvironmentObject private var themeManager: ThemeManager
    /// Width-driven side length so the square matches the seek bar and cannot be
    /// compressed by the player VStack's flexible controls.
    @State private var side: CGFloat = 0

    var body: some View {
        ArtworkView.hero(urlString, symbol: symbol)
            .frame(width: side, height: side)
            .shadow(color: .black.opacity(0.25), radius: 24, y: 12)
            .frame(maxWidth: .infinity)
            .frame(height: side)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                if abs(width - side) > 0.5 {
                    side = width
                }
            }
            .padding(.horizontal, VerodromeTheme.playerContentHorizontalPadding)
            .task(id: urlString) {
                let image = await ArtworkResolver.shared.loadImage(
                    for: urlString,
                    size: ArtworkPixelSize.player
                )
                themeManager.updatePlayerTint(from: image)
            }
    }
}
