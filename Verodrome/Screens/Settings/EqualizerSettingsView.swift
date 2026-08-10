import SwiftUI

struct EqualizerSettingsView: View {
    @EnvironmentObject private var player: PlayerViewModel

    var body: some View {
        Form {
            Section { EqualizerView().listRowInsets(EdgeInsets()) }
            Section {
                Button("Reset Bands") {
                    player.equalizerBands = Array(repeating: 0, count: player.equalizerBands.count)
                }
            }
        }
        .verodromePlainList()
        .navigationTitle("Equalizer")
    }
}
