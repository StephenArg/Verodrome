import SwiftUI
import VerodromeKit

struct NowPlayingSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("Show Rating Stars", isOn: $settings.showRatingStars)
                    .onChange(of: settings.showRatingStars) { _, _ in settings.save() }
                Toggle("Show Song Info", isOn: $settings.showSongInfo)
                    .onChange(of: settings.showSongInfo) { _, _ in settings.save() }
            } header: {
                Text("Under the Artwork")
            } footer: {
                Text("Both are also on the full-screen player's long-press menu.")
            }

            Section {
                Toggle("Show Lyrics Instead of Artwork", isOn: $settings.showLyricsInPlayer)
                    .onChange(of: settings.showLyricsInPlayer) { _, _ in settings.save() }
                Toggle("Load Lyrics When Available", isOn: $settings.showMiniLyrics)
                    .onChange(of: settings.showMiniLyrics) { _, _ in settings.save() }
            } header: {
                Text("Lyrics")
            } footer: {
                Text("Turning off Load Lyrics When Available stops Verodrome from asking the server for lyrics at all.")
            }

            Section {
                Toggle("Match Background to Artwork", isOn: $settings.changingColorsInPlayer)
                    .onChange(of: settings.changingColorsInPlayer) { _, _ in settings.save() }
            } header: {
                Text("Background")
            } footer: {
                Text("Tints the full-screen player with the current cover's colors.")
            }
        }
        .verodromePlainList()
        .navigationTitle("Now Playing")
    }
}
