import SwiftUI
import SwiftData
import VerodromeKit

@main
struct VerodromeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var kit = VerodromeKit.shared
    @StateObject private var player = PlayerViewModel()
    @StateObject private var themeManager: ThemeManager

    init() {
        _themeManager = StateObject(wrappedValue: ThemeManager(settings: VerodromeKit.shared.settings))
    }

    var body: some Scene {
        WindowGroup {
            RootLaunchView()
                .environmentObject(kit.settings)
                .environmentObject(kit.accountStore)
                .environmentObject(kit.librarySync)
                .environmentObject(player)
                .environmentObject(player.progress)
                .environmentObject(player.nowPlaying)
                .environmentObject(themeManager)
                .preferredColorScheme(colorScheme)
                .tint(themeManager.accentColor)
                .task {
                    PersistentStorage.shared.configureMainContext()
                    await kit.initialize()
                    player.attach(facade: kit.player)
                    themeManager.applyTheme()
                }
                .onOpenURL { url in
                    Task {
                        // Router is owned by RootLaunchView; post for handling when main is active.
                        NotificationCenter.default.post(name: .verodromeOpenURL, object: url)
                    }
                }
                .onChange(of: kit.accountStore.isLoggedIn) { _, _ in
                    themeManager.applyTheme()
                }
        }
        .modelContainer(PersistentStorage.shared.container)
    }

    private var colorScheme: ColorScheme? {
        switch kit.settings.themePreference {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
