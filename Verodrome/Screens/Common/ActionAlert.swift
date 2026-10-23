import UIKit
import VerodromeKit

/// Warns that an action didn't go through, after the fact.
///
/// Optimistic actions report failure late — a playlist toggle shows its result at once,
/// and the sheet it came from is often closed before the server answers. Like
/// `ActionToast` this is hosted in its own window, so it reaches the user wherever they
/// are by then; presenting on the topmost controller instead could land on a sheet that
/// is in the middle of being dismissed, and the alert would never appear.
@MainActor
enum ActionAlert {
    static func show(title: String, message: String) {
        ActionAlertCenter.shared.show(title: title, message: message)
    }
}

@MainActor
private final class ActionAlertCenter {
    static let shared = ActionAlertCenter()

    private struct Warning {
        let title: String
        var lines: [String]
        /// A blank line between entries, since each one usually wraps.
        var message: String { lines.joined(separator: "\n\n") }
    }

    private var window: UIWindow?
    private weak var previousKeyWindow: UIWindow?
    private var alert: UIAlertController?
    private var showing: Warning?
    private var waiting: [Warning] = []

    func show(title: String, message: String) {
        // Failures tend to arrive together — several rows tapped while the server was
        // unreachable — so one sharing a title with an alert that is up or waiting joins
        // it rather than queueing another alert behind it.
        if showing?.title == title {
            guard showing?.lines.contains(message) == false else { return }
            showing?.lines.append(message)
            alert?.message = showing?.message
        } else if let index = waiting.firstIndex(where: { $0.title == title }) {
            guard !waiting[index].lines.contains(message) else { return }
            waiting[index].lines.append(message)
        } else if showing != nil {
            waiting.append(Warning(title: title, lines: [message]))
        } else {
            present(Warning(title: title, lines: [message]))
        }
    }

    private func present(_ warning: Warning) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }

        let window = UIWindow(windowScene: scene)
        // Under the toast's window, so confirmations for other actions still show.
        window.windowLevel = .alert
        // The app's own window gets both from SwiftUI; a new one would start on the
        // system appearance and UIKit's blue.
        window.overrideUserInterfaceStyle = Self.interfaceStyle
        window.tintColor = ThemeManager.shared?.accentUIColor
        let host = UIViewController()
        window.rootViewController = host
        previousKeyWindow = scene.keyWindow
        window.makeKeyAndVisible()

        let alert = UIAlertController(title: warning.title, message: warning.message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.dismissed()
        })
        host.present(alert, animated: true)

        self.window = window
        self.alert = alert
        showing = warning
    }

    private func dismissed() {
        window?.isHidden = true
        window = nil
        alert = nil
        showing = nil
        previousKeyWindow?.makeKey()
        if !waiting.isEmpty {
            present(waiting.removeFirst())
        }
    }

    private static var interfaceStyle: UIUserInterfaceStyle {
        switch SettingsStore.shared.themePreference {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }
}
