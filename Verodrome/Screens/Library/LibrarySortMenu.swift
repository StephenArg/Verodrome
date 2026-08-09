import SwiftUI
import UIKit
import VerodromeKit

/// Trailing toolbar control for picking a library list's ordering.
///
/// Backed by a UIKit `UIMenu` rather than SwiftUI `Menu`. The library screens rebuild
/// their toolbars whenever the list model refreshes (head page → full page, sync, …);
/// SwiftUI recreates an open menu on every pass and the labels pulse. UIKit only
/// replaces the menu when the selection or filter actually changes.
struct LibrarySortMenu: View {
    @EnvironmentObject private var settings: SettingsStore

    @Binding var selection: LibrarySortOption
    let options: [LibrarySortOption]
    /// Songs-only. When set, a second section toggles a downloaded-only filter.
    var downloadedOnly: Binding<Bool>? = nil

    var body: some View {
        LibrarySortMenuButton(
            selection: selection,
            options: options,
            downloadedOnly: downloadedOnly?.wrappedValue,
            onSelect: { option in
                selection = option
                settings.save()
            },
            onToggleDownloaded: downloadedOnly.map { binding in
                {
                    binding.wrappedValue.toggle()
                    settings.save()
                }
            }
        )
        .frame(width: 44, height: 44)
        .accessibilityLabel("Sort")
    }
}

private struct LibrarySortMenuButton: UIViewRepresentable {
    let selection: LibrarySortOption
    let options: [LibrarySortOption]
    let downloadedOnly: Bool?
    let onSelect: (LibrarySortOption) -> Void
    let onToggleDownloaded: (() -> Void)?

    final class Coordinator {
        var selection: LibrarySortOption
        var options: [LibrarySortOption]
        var downloadedOnly: Bool?
        var onSelect: (LibrarySortOption) -> Void
        var onToggleDownloaded: (() -> Void)?
        /// Avoid rebuilding `button.menu` when the representable is refreshed for an
        /// unrelated parent render — replacing a presented menu is what pulses the text.
        var menuIdentity: String = ""

        init(
            selection: LibrarySortOption,
            options: [LibrarySortOption],
            downloadedOnly: Bool?,
            onSelect: @escaping (LibrarySortOption) -> Void,
            onToggleDownloaded: (() -> Void)?
        ) {
            self.selection = selection
            self.options = options
            self.downloadedOnly = downloadedOnly
            self.onSelect = onSelect
            self.onToggleDownloaded = onToggleDownloaded
        }

        func identity() -> String {
            "\(selection.rawValue)|\(options.map(\.rawValue).joined(separator: ","))|\(downloadedOnly.map(String.init(describing:)) ?? "-")"
        }

        func makeMenu() -> UIMenu {
            var children: [UIMenuElement] = options.map { option in
                UIAction(
                    title: option.displayName,
                    state: option == selection ? .on : .off
                ) { [weak self] _ in
                    self?.onSelect(option)
                }
            }
            if let onToggleDownloaded, let downloadedOnly {
                let downloaded = UIAction(
                    title: "Downloaded",
                    state: downloadedOnly ? .on : .off
                ) { [weak self] _ in
                    self?.onToggleDownloaded?()
                }
                children.append(UIMenu(options: .displayInline, children: [downloaded]))
            }
            return UIMenu(children: children)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            selection: selection,
            options: options,
            downloadedOnly: downloadedOnly,
            onSelect: onSelect,
            onToggleDownloaded: onToggleDownloaded
        )
    }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        button.setImage(UIImage(systemName: "arrow.up.arrow.down", withConfiguration: config), for: .normal)
        button.showsMenuAsPrimaryAction = true
        context.coordinator.menuIdentity = context.coordinator.identity()
        button.menu = context.coordinator.makeMenu()
        button.accessibilityLabel = "Sort"
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.selection = selection
        coordinator.options = options
        coordinator.downloadedOnly = downloadedOnly
        coordinator.onSelect = onSelect
        coordinator.onToggleDownloaded = onToggleDownloaded

        let identity = coordinator.identity()
        guard identity != coordinator.menuIdentity else { return }
        coordinator.menuIdentity = identity
        button.menu = coordinator.makeMenu()
    }
}
