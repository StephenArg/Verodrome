import SwiftUI
import UIKit
import VerodromeKit

@MainActor
final class ThemeManager: ObservableObject {
    /// Set from `VerodromeApp` so UIKit cells can resolve the same accent without
    /// threading an environment object through every table.
    static private(set) weak var shared: ThemeManager?

    @Published var accentColor: Color = .accentColor

    private let settings: SettingsStore

    /// UIKit counterpart of `accentColor` (falls back to the system tint).
    var accentUIColor: UIColor { UIColor(accentColor) }

    init(settings: SettingsStore) {
        self.settings = settings
        Self.shared = self
        applyTheme()
    }

    func applyTheme() {
        if let hex = activeThemeHex(), let color = Color(hex: hex) {
            accentColor = color
            return
        }
        switch settings.themePreference {
        case .system:
            accentColor = Color("AccentColor", bundle: .main)
        case .light:
            accentColor = Color(red: 0.18, green: 0.44, blue: 0.96)
        case .dark:
            accentColor = Color(red: 0.42, green: 0.62, blue: 1.0)
        }
    }

    func setAccountThemeColor(_ color: Color?) {
        guard let key = AccountStore.shared.activeAccountKey() else { return }
        var accountSettings = settings.loadAccountSettings(for: key)
        accountSettings.themeColorHex = color?.hexString
        settings.saveAccountSettings(accountSettings, for: key)
        applyTheme()
    }

    private func activeThemeHex() -> String? {
        guard let key = AccountStore.shared.activeAccountKey() else { return nil }
        return settings.loadAccountSettings(for: key).themeColorHex
    }
}

extension Color {
    init?(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    var hexString: String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

enum VerodromeTheme {
    static let cornerRadius: CGFloat = 14
    static let gridSpacing: CGFloat = 16
    static let miniPlayerHeight: CGFloat = 64
    static let artworkCornerRadius: CGFloat = 8
    /// Shared inset for player artwork, title, and seek bar so their widths match.
    static let playerContentHorizontalPadding: CGFloat = 20

    static var glassBackground: some ShapeStyle {
        .ultraThinMaterial
    }
}

// MARK: - Marquee text

/// Single-line label that slowly scrolls when the text is wider than its container.
/// Always occupies exactly one line of height — long titles never wrap.
/// Pauses at the start, scrolls to reveal the end, pauses briefly, then loops.
struct MarqueeText: View {
    let text: String
    var font: Font = .body
    /// Points scrolled per second.
    var speed: CGFloat = 28
    var startPauseNanoseconds: UInt64 = 2_000_000_000
    var endPauseNanoseconds: UInt64 = 1_200_000_000
    /// Alignment used when the text fits without scrolling.
    var fitAlignment: Alignment = .leading

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private var needsScroll: Bool {
        textWidth > containerWidth + 1 && containerWidth > 0
    }

    var body: some View {
        // Invisible one-line spacer defines height + consumes only the offered width.
        // The real title is overlaid with fixedSize so it never wraps or expands the parent.
        Text(text.isEmpty ? " " : "Ag")
            .font(font)
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity)
            .overlay(alignment: needsScroll ? .leading : fitAlignment) {
                Text(text)
                    .font(font)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .offset(x: offset)
                    .background(widthReader(isContainer: false))
            }
            .clipped()
            .background(widthReader(isContainer: true))
            .onPreferenceChange(MarqueeWidthKey.self) { values in
                if let t = values.text { textWidth = t }
                if let c = values.container { containerWidth = c }
            }
            .task(id: "\(text)|\(textWidth)|\(containerWidth)") {
                await runMarquee()
            }
            .accessibilityLabel(text)
            .accessibilityAddTraits(.isStaticText)
    }

    private func widthReader(isContainer: Bool) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: MarqueeWidthKey.self,
                value: isContainer
                    ? MarqueeWidths(container: geo.size.width)
                    : MarqueeWidths(text: geo.size.width)
            )
        }
    }

    @MainActor
    private func runMarquee() async {
        offset = 0
        guard needsScroll else { return }

        let travel = textWidth - containerWidth
        guard travel > 0 else { return }

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: startPauseNanoseconds)
            if Task.isCancelled { return }

            let duration = Double(travel / max(speed, 1))
            withAnimation(.linear(duration: duration)) {
                offset = -travel
            }
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            if Task.isCancelled { return }

            try? await Task.sleep(nanoseconds: endPauseNanoseconds)
            if Task.isCancelled { return }

            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                offset = 0
            }
        }
    }
}

private struct MarqueeWidths: Equatable {
    var text: CGFloat? = nil
    var container: CGFloat? = nil
}

private struct MarqueeWidthKey: PreferenceKey {
    static var defaultValue = MarqueeWidths()

    static func reduce(value: inout MarqueeWidths, nextValue: () -> MarqueeWidths) {
        let next = nextValue()
        if let t = next.text { value.text = t }
        if let c = next.container { value.container = c }
    }
}
