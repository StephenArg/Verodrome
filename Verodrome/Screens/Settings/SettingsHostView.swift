import SwiftUI
import VerodromeKit

struct SettingsHostView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var player: PlayerViewModel

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(
                    get: { player.isOfflineMode },
                    set: { _ in player.toggleOfflineMode() }
                )) {
                    settingsLabel("Offline Mode", systemImage: "airplane")
                }
            } footer: {
                Text("Plays only what is already downloaded and stops all network requests.")
            }

            Section("Appearance") {
                NavigationLink { AppearanceSettingsView() } label: {
                    settingsLabel("Appearance", systemImage: "paintbrush")
                }
                NavigationLink { LayoutSettingsView() } label: {
                    settingsLabel("Layout & Gestures", systemImage: "square.grid.2x2")
                }
                NavigationLink { NowPlayingSettingsView() } label: {
                    settingsLabel("Now Playing", systemImage: "music.note")
                }
            }

            Section("Playback") {
                NavigationLink { PlaybackSettingsView() } label: {
                    settingsLabel("Playback", systemImage: "play.circle")
                }
                NavigationLink { EqualizerSettingsView() } label: {
                    settingsLabel("Equalizer", systemImage: "slider.vertical.3")
                }
            }

            Section("Library") {
                NavigationLink { LibrarySettingsView() } label: {
                    settingsLabel("Library", systemImage: "books.vertical")
                }
                NavigationLink { DownloadsSettingsView() } label: {
                    settingsLabel("Downloads", systemImage: "arrow.down.circle")
                }
                NavigationLink { StorageSettingsView() } label: {
                    settingsLabel("Storage", systemImage: "internaldrive")
                }
            }

            Section("Advanced") {
                NavigationLink { EventLogView() } label: {
                    settingsLabel("Event Log", systemImage: "doc.text.magnifyingglass")
                }
                NavigationLink { DeveloperSettingsView() } label: {
                    settingsLabel("Developer", systemImage: "hammer")
                }
            }

            Section {
                NavigationLink { AboutSettingsView() } label: {
                    settingsLabel("About", systemImage: "questionmark.circle")
                }
            }
        }
        .verodromePlainList()
        .navigationTitle("Settings")
    }

    private func settingsLabel(_ title: String, systemImage: String) -> some View {
        Label {
            Text(title)
        } icon: {
            // Explicit accent rather than the inherited tint: popping back from
            // a screen that retints (album/playlist artwork) leaves these icons
            // resolving against UIKit's default blue.
            Image(systemName: systemImage)
                .foregroundStyle(themeManager.accentColor)
        }
        .font(.body)
    }
}
