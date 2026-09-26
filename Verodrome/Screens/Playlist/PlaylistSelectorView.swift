import SwiftUI
import SwiftData
import VerodromeKit

struct PlaylistSelectorView: View {
    @Query(sort: \Playlist.sortName) private var allPlaylists: [Playlist]
    @EnvironmentObject private var settings: SettingsStore
    var onSelect: (Playlist) -> Void
    @Environment(\.dismiss) private var dismiss

    /// Same filter and order as `PlaylistMembershipView`: smart / read-only playlists
    /// can't accept adds, so offering them here only sets up a server rejection.
    private var playlists: [Playlist] {
        let accountKey = AccountStore.shared.activeAccountKey()?.storageKey
        let rejected = LibraryActions.shared.playlistsRejectedByServer
        let editable = allPlaylists.filter {
            $0.account?.compoundKey == accountKey
                && $0.isEditable
                && !$0.isSmart
                && !rejected.contains($0.remoteId)
        }
        return PlaylistListOrder.ordered(editable, by: settings.librarySort.playlists)
    }

    var body: some View {
        NavigationStack {
            List {
                if playlists.isEmpty {
                    Text("No playlists you can edit.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(playlists) { playlist in
                    Button {
                        onSelect(playlist)
                        dismiss()
                    } label: {
                        EntityRow(
                            title: playlist.name,
                            subtitle: "\(playlist.songCount) songs",
                            artworkURL: playlist.displayArtworkToken,
                            symbol: "music.note.house.fill",
                            isFavorite: playlist.isFavorite
                        )
                    }
                    .buttonStyle(.plain)
                }
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
