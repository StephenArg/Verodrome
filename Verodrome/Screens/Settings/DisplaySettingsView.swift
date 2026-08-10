import SwiftUI
import VerodromeKit

struct DisplaySettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section("Navigation") {
                NavigationLink {
                    TabBarEditorView()
                } label: {
                    HStack {
                        Text("Tab Bar")
                        Spacer()
                        Text(tabBarSummary)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                NavigationLink {
                    LibraryEditorView()
                } label: {
                    HStack {
                        Text("Library Categories")
                        Spacer()
                        Text(libraryCategoriesSummary)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
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

            Section("Player") {
                Picker("Player Style", selection: $settings.playerDisplayStyle) {
                    ForEach(PlayerDisplayStyle.allCases, id: \.self) { style in
                        Text(style.rawValue.capitalized).tag(style)
                    }
                }
                Toggle("Show Mini Lyrics", isOn: $settings.showMiniLyrics)
            }
        }
        .navigationTitle("Display")
    }

    private var tabBarSummary: String {
        settings.enabledRootTabs.map(\.title).joined(separator: ", ")
    }

    private var libraryCategoriesSummary: String {
        settings.enabledLibraryCategories.map(\.title).joined(separator: ", ")
    }
}
