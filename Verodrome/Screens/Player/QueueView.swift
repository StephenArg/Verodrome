import SwiftUI

struct QueueView: View {
    @EnvironmentObject private var player: PlayerViewModel

    var body: some View {
        List {
            ForEach(player.queue) { item in
                EntityRow(
                    title: item.title,
                    subtitle: item.artist ?? "",
                    artworkURL: item.artworkId,
                    symbol: item.kind == .radio ? "dot.radiowaves.left.and.right" : "music.note",
                    isPlaying: player.currentItem?.id == item.id
                )
            }
            .onMove(perform: player.moveQueue)
            .onDelete(perform: player.removeFromQueue)
        }
        .listStyle(.plain)
        .toolbar { EditButton() }
    }
}
