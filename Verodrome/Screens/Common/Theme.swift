import SwiftUI
import UIKit
import VerodromeKit

@MainActor
final class ThemeManager: ObservableObject {
    /// Retained for the app lifetime so UIKit cells can always resolve a concrete accent.
    /// (A weak ref was falling back to system blue and made library glyphs flicker.)
    static private(set) var shared: ThemeManager?

    @Published private(set) var accentColor: Color
    /// Concrete sRGB color for UIKit — never `Color.accentColor` / a dynamic provider.
    private(set) var accentUIColor: UIColor
    /// Monotonic revision for UIKit tables; only bumps when RGB actually changes.
    private(set) var accentGeneration: Int = 0

    private let settings: SettingsStore
    private var observers: [NSObjectProtocol] = []

    /// Matches the catalog AccentColor closely enough for the no-asset fallback path.
    private static let fallbackUIColor = UIColor(red: 0.25, green: 0.42, blue: 0.98, alpha: 1)

    init(settings: SettingsStore) {
        self.settings = settings
        // Never seed with `Color.accentColor` — that tracks environment tint and will
        // fight a custom account color inside UIKit cells.
        let initial = Self.fallbackUIColor
        self.accentUIColor = initial
        self.accentColor = Color(initial)
        Self.shared = self
        applyTheme()
        // Switching accounts swaps which stored color is active, and it doesn't always
        // flip `isLoggedIn` — the only other trigger the app had.
        observers.append(NotificationCenter.default.addObserver(
            forName: .accountChanged,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in ThemeManager.shared?.applyTheme() }
        })
        // Windows that appear after launch (and the toast window) start on UIKit's tint.
        observers.append(NotificationCenter.default.addObserver(
            forName: UIScene.didActivateNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in ThemeManager.shared?.syncWindowTint() }
        })
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// SwiftUI's root `.tint` only covers views that resolve color through the SwiftUI
    /// environment. Anything that falls back to UIKit — including a navigation container
    /// left behind by a screen that overrode the tint with artwork colors — lands on
    /// UIKit's default system blue. Owning the window tint makes the accent the fallback.
    func syncWindowTint() {
        UIWindow.appearance().tintColor = accentUIColor
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                window.tintColor = accentUIColor
            }
        }
    }

    func applyTheme() {
        // No account resolved yet (cold launch, mid-switch). Keep the accent already on
        // screen: recomputing here would land on the default blue and snap back a moment
        // later, which is exactly the flicker the library rows were showing.
        guard let key = AccountStore.shared.activeAccountKey() else { return }

        if let hex = settings.loadAccountSettings(for: key).themeColorHex,
           let color = UIColor(verodromeHex: hex) {
            setAccent(color)
            return
        }
        setAccent(defaultAccent())
    }

    func setAccountThemeColor(_ color: Color?) {
        guard let key = AccountStore.shared.activeAccountKey() else { return }
        var accountSettings = settings.loadAccountSettings(for: key)
        if let color {
            accountSettings.themeColorHex = ThemeColor.concrete(UIColor(color)).verodromeHexString
        } else {
            accountSettings.themeColorHex = nil
        }
        settings.saveAccountSettings(accountSettings, for: key)
        // Keep the in-memory settings copy in step with the store, so a later
        // `updateAccount` elsewhere can't write a snapshot that predates this color.
        VerodromeKit.shared.observableSettings.reload(accountKey: key)
        applyTheme()
    }

    private func defaultAccent() -> UIColor {
        switch settings.themePreference {
        case .system:
            let named = UIColor(named: "AccentColor", in: .main, compatibleWith: .current)
            return ThemeColor.concrete(named ?? Self.fallbackUIColor)
        case .light:
            return UIColor(red: 0.18, green: 0.44, blue: 0.96, alpha: 1)
        case .dark:
            return UIColor(red: 0.42, green: 0.62, blue: 1.0, alpha: 1)
        }
    }

    private func setAccent(_ ui: UIColor) {
        let concrete = ThemeColor.concrete(ui)
        guard !ThemeColor.sameRGB(concrete, accentUIColor) else { return }
        accentUIColor = concrete
        accentColor = Color(concrete)
        accentGeneration &+= 1
        syncWindowTint()
    }
}

/// Color-space helpers kept off the main actor so UIColor extensions can call them.
enum ThemeColor {
    static let fallback = UIColor(red: 0.25, green: 0.42, blue: 0.98, alpha: 1)

    /// Flatten dynamic / Display P3 colors into a fixed sRGB UIColor so UILabel
    /// attributed text and UIImageView tints can't resolve differently later.
    static func concrete(_ color: UIColor) -> UIColor {
        let resolved = color.resolvedColor(with: .current)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if resolved.getRed(&r, green: &g, blue: &b, alpha: &a) {
            return UIColor(red: r, green: g, blue: b, alpha: a)
        }
        guard
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let srgb = resolved.cgColor.converted(to: space, intent: .defaultIntent, options: nil),
            let components = srgb.components,
            components.count >= 3
        else {
            return fallback
        }
        let alpha = components.count > 3 ? components[3] : 1
        return UIColor(red: components[0], green: components[1], blue: components[2], alpha: alpha)
    }

    static func sameRGB(_ lhs: UIColor, _ rhs: UIColor) -> Bool {
        var lr: CGFloat = 0, lg: CGFloat = 0, lb: CGFloat = 0, la: CGFloat = 0
        var rr: CGFloat = 0, rg: CGFloat = 0, rb: CGFloat = 0, ra: CGFloat = 0
        guard lhs.getRed(&lr, green: &lg, blue: &lb, alpha: &la),
              rhs.getRed(&rr, green: &rg, blue: &rb, alpha: &ra) else { return false }
        let eps: CGFloat = 0.5 / 255
        return abs(lr - rr) < eps && abs(lg - rg) < eps && abs(lb - rb) < eps && abs(la - ra) < eps
    }
}

extension Color {
    init?(hex: String) {
        guard let ui = UIColor(verodromeHex: hex) else { return nil }
        self.init(ui)
    }

    var hexString: String {
        UIColor(self).verodromeHexString
    }
}

extension UIColor {
    convenience init?(verodromeHex hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }

    var verodromeHexString: String {
        let concrete = ThemeColor.concrete(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard concrete.getRed(&r, green: &g, blue: &b, alpha: &a) else { return "000000" }
        return String(
            format: "%02X%02X%02X",
            Int((r * 255).rounded()),
            Int((g * 255).rounded()),
            Int((b * 255).rounded())
        )
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
