import UIKit
import VerodromeKit

/// Tactile feedback for confirmed actions.
///
/// Every entry point checks `SettingsStore.hapticsEnabled` here rather than at the call
/// sites, so the Haptics toggle silences all of them from one place.
@MainActor
enum Haptics {
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        guard SettingsStore.shared.hapticsEnabled else { return }
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }
}
