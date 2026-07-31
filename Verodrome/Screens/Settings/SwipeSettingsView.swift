import SwiftUI
import VerodromeKit

struct SwipeSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    private let actions = ["queue", "download", "favorite", "none"]

    var body: some View {
        Form {
            Section("Song Row Swipes") {
                Picker("Swipe Left", selection: $settings.swipeLeftAction) {
                    ForEach(actions, id: \.self) { action in
                        Text(action.capitalized).tag(action)
                    }
                }
                Picker("Swipe Right", selection: $settings.swipeRightAction) {
                    ForEach(actions, id: \.self) { action in
                        Text(action.capitalized).tag(action)
                    }
                }
            }
        }
        .navigationTitle("Swipe Actions")
    }
}
