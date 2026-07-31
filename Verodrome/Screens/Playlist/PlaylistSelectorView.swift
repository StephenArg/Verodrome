import SwiftUI
import SwiftData
import VerodromeKit

struct PlaylistSelectorView: View {
    @Query(sort: \Playlist.name) private var playlists: [Playlist]
    var onSelect: (Playlist) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(playlists) { playlist in
                Button {
                    onSelect(playlist)
                    dismiss()
                } label: {
                    EntityRow(
                        title: playlist.name,
                        subtitle: "\(playlist.songCount) songs",
                        artworkURL: playlist.displayArtworkToken,
                        symbol: "music.note.house.fill"
                    )
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Add to Playlist")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
