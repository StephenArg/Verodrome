import SwiftUI
import VerodromeKit

/// Queue + lyrics inspector shown beside content on regular-width / Catalyst layouts.
struct PlayerInspectorView: View {
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $tab) {
                Text("Queue").tag(0)
                Text("Lyrics").tag(1)
            }
            .pickerStyle(.segmented)
            .padding()

            if tab == 0 {
                QueueView()
            } else {
                LyricsView()
            }
        }
        .navigationTitle("Now Playing")
        .navigationBarTitleDisplayMode(.inline)
    }
}
