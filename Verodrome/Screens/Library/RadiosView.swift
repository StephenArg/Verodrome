import SwiftUI
import SwiftData
import VerodromeKit

struct RadiosView: View {
    @Query(sort: \Radio.title) private var radios: [Radio]
    @EnvironmentObject private var player: PlayerViewModel

    var body: some View {
        Group {
            if radios.isEmpty {
                ContentUnavailableView(
                    "No Radios",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text("Internet radio stations from your server appear here.")
                )
            } else {
                List(radios, id: \.compoundRemoteId) { radio in
                    Button {
                        play(radio)
                    } label: {
                        EntityRow(
                            title: radio.title,
                            subtitle: radio.streamURL ?? "",
                            artworkURL: radio.artworkToken,
                            symbol: "dot.radiowaves.left.and.right",
                            isPlaying: player.currentItem?.playableId == radio.remoteId
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color(.systemBackground))
                    .disabled(radio.streamURL == nil)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Radios")
    }

    private func play(_ radio: Radio) {
        guard let item = QueueItem.from(radio) else { return }
        player.play(items: [item], startAt: 0)
    }
}
