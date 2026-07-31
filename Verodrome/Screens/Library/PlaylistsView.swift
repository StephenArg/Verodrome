import SwiftUI
import SwiftData
import VerodromeKit

struct PlaylistsView: View {
    @Query(sort: \Playlist.name) private var playlists: [Playlist]

    var body: some View {
        AlphabetIndexedList(
            items: playlists.map(PlaylistRowItem.init),
            sectionTitle: \.name,
            perfLabel: "Playlists"
        ) { item in
            NavigationLink {
                PlaylistDetailView(playlistID: item.id)
            } label: {
                EntityRow(
                    title: item.name,
                    subtitle: item.subtitle,
                    artworkURL: item.artworkToken,
                    symbol: "music.note.house.fill"
                )
            }
        }
        .navigationTitle("Playlists")
        .perfAppear("Playlists", details: "count=\(playlists.count)")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { PlaylistEditView(playlistID: nil) } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .task {
            // Refresh coverArt tokens without a full library sync.
            _ = try? await VerodromeKit.shared.ensureActiveLibrarySyncer()?.syncPlaylistCatalog()
        }
        .refreshable {
            _ = try? await VerodromeKit.shared.ensureActiveLibrarySyncer()?.syncPlaylistCatalog()
        }
    }
}

private struct PlaylistRowItem: Identifiable {
    let id: String
    let name: String
    let subtitle: String
    let artworkToken: String?

    init(_ playlist: Playlist) {
        id = playlist.compoundRemoteId
        name = playlist.name
        subtitle = playlist.isSmart
            ? "Smart · \(playlist.songCount) songs"
            : "\(playlist.songCount) songs"
        // Prefer stored token — walking entries for displayArtworkToken is too costly in large lists.
        artworkToken = playlist.artworkToken
    }
}
