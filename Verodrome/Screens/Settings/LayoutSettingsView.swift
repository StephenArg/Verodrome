import SwiftUI
import VerodromeKit

struct LayoutSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var account: AccountStore

    private let swipeActions = ["queue", "download", "favorite", "none"]
    private let playlistSwipeActions = ["queue", "download", "favorite", "remove", "none"]

    var body: some View {
        Form {
            Section("Navigation") {
                NavigationLink { TabBarEditorView() } label: {
                    summaryRow("Tab Bar", summary: tabBarSummary)
                }
                NavigationLink { LibraryEditorView() } label: {
                    summaryRow("Library Categories", summary: libraryCategoriesSummary)
                }
                NavigationLink { HomeEditorView() } label: {
                    summaryRow("Home Sections", summary: homeSectionsSummary)
                }
            }

            Section("Library") {
                Picker("Default Layout", selection: $settings.libraryDisplayType) {
                    ForEach(LibraryDisplayType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .onChange(of: settings.libraryDisplayType) { _, _ in settings.save() }
            }

            if isPopularSupported {
                Section {
                    Toggle("Popular", isOn: $settings.showArtistTopSongs)
                        .onChange(of: settings.showArtistTopSongs) { _, _ in settings.save() }
                } header: {
                    Text("Artist")
                } footer: {
                    Text("Show Last.fm popular tracks at the top of artist pages when the library has enough of them.")
                }
            }

            Section("Song Row Swipes") {
                Picker("Swipe Left", selection: $settings.swipeLeftAction) {
                    ForEach(swipeActions, id: \.self) { action in
                        Text(action.capitalized).tag(action)
                    }
                }
                .onChange(of: settings.swipeLeftAction) { _, _ in settings.save() }

                Picker("Swipe Right", selection: $settings.swipeRightAction) {
                    ForEach(swipeActions, id: \.self) { action in
                        Text(action.capitalized).tag(action)
                    }
                }
                .onChange(of: settings.swipeRightAction) { _, _ in settings.save() }
            }

            Section {
                Picker("Swipe Left", selection: $settings.playlistSwipeLeftAction) {
                    ForEach(playlistSwipeActions, id: \.self) { action in
                        Text(action.capitalized).tag(action)
                    }
                }
                .onChange(of: settings.playlistSwipeLeftAction) { _, _ in settings.save() }

                Picker("Swipe Right", selection: $settings.playlistSwipeRightAction) {
                    ForEach(playlistSwipeActions, id: \.self) { action in
                        Text(action.capitalized).tag(action)
                    }
                }
                .onChange(of: settings.playlistSwipeRightAction) { _, _ in settings.save() }
            } header: {
                Text("Playlist Row Swipes")
            } footer: {
                Text("Used on songs inside a playlist. Remove takes the song out of that playlist, and only appears on playlists you can edit.")
            }

            Section {
                Toggle("Haptics", isOn: $settings.hapticsEnabled)
                    .onChange(of: settings.hapticsEnabled) { _, _ in settings.save() }
            } header: {
                Text("Feedback")
            } footer: {
                Text("Play a short tap when you like a song, add one to the queue, or add one to a playlist.")
            }
        }
        .verodromePlainList()
        .navigationTitle("Layout & Gestures")
    }

    private func summaryRow(_ title: String, summary: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(summary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var tabBarSummary: String {
        settings.enabledRootTabs.map(\.title).joined(separator: ", ")
    }

    private var libraryCategoriesSummary: String {
        settings.enabledLibraryCategories.map(\.title).joined(separator: ", ")
    }

    private var homeSectionsSummary: String {
        settings.enabledHomeSections.map(\.title).joined(separator: ", ")
    }

    private var isPopularSupported: Bool {
        ArtistTopSongs.isSupported(on: activeApiType)
    }

    private var activeApiType: ApiType? {
        if let key = account.activeAccountKey() {
            let stored = settings.loadAccountSettings(for: key).apiType
            if stored != .notDetected { return stored }
        }
        return account.detectedApiType
    }
}
