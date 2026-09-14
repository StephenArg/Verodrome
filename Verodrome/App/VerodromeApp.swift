import SwiftUI
import SwiftData
import UIKit
import VerodromeKit

@main
struct VerodromeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var kit = VerodromeKit.shared
    @StateObject private var player = PlayerViewModel()
    @StateObject private var shuffleAll = ShuffleAllCoordinator()
    @StateObject private var radioContinuation = RadioContinuationCoordinator()
    @StateObject private var themeManager: ThemeManager
    @Environment(\.scenePhase) private var scenePhase

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
                .environmentObject(player.queueList)
                .environmentObject(shuffleAll)
                .environmentObject(radioContinuation)
                .environmentObject(themeManager)
                .preferredColorScheme(colorScheme)
                .tint(themeManager.accentColor)
                .task {
                    PersistentStorage.shared.configureMainContext()
                    await kit.initialize()
                    player.attach(facade: kit.player)
                    shuffleAll.attach(player: player)
                    radioContinuation.attach(player: player, shuffleAll: shuffleAll)
                    themeManager.applyTheme()
                }
                .overlay {
                    if kit.isRemappingCanonicalIds {
                        CanonicalIdMigrationOverlay(message: kit.idMigrationStatusText)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: kit.isRemappingCanonicalIds)
                .onOpenURL { url in
                    Task {
                        // Router is owned by RootLaunchView; post for handling when main is active.
                        NotificationCenter.default.post(name: .verodromeOpenURL, object: url)
                    }
                }
                .onChange(of: kit.accountStore.isLoggedIn) { _, _ in
                    themeManager.applyTheme()
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .inactive:
                        // App Switcher / Control Center — persist early so a swipe-away
                        // still has a recent scrub position if `.background` is skipped.
                        kit.player?.persistPlaybackPosition()
                    case .background:
                        // Being killed while backgrounded is the normal way this app ends.
                        // Hold a background task long enough for the queue file to land.
                        var taskId = UIBackgroundTaskIdentifier.invalid
                        taskId = UIApplication.shared.beginBackgroundTask(withName: "PersistPlayback") {
                            if taskId != .invalid {
                                UIApplication.shared.endBackgroundTask(taskId)
                                taskId = .invalid
                            }
                        }
                        Task {
                            await kit.persistForBackground()
                            if taskId != .invalid {
                                UIApplication.shared.endBackgroundTask(taskId)
                                taskId = .invalid
                            }
                        }
                    default:
                        break
                    }
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

/// Blocks the UI while Navidrome IDs are rewritten. Shown before the main-actor
/// SwiftData pass so the freeze has a visible explanation instead of a stuck screen.
private struct CanonicalIdMigrationOverlay: View {
    let message: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .contentShape(Rectangle())
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.primary)
                Text(message)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("Downloads stay on this device. This can take a moment on a large library.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: 320)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
        .accessibilityAddTraits(.updatesFrequently)
    }
}
