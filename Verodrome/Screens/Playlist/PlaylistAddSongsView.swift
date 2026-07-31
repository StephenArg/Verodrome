import SwiftUI
import SwiftData
import VerodromeKit

struct PlaylistAddSongsView: View {
    let playlistID: String
    @Query(sort: \Song.title) private var songs: [Song]
    @Query private var playlists: [Playlist]
    @State private var selectedIDs: Set<String> = []
    @State private var isSaving = false
    @Environment(\.dismiss) private var dismiss

    init(playlistID: String) {
        self.playlistID = playlistID
        _playlists = Query(filter: #Predicate<Playlist> { $0.compoundRemoteId == playlistID })
    }

    var body: some View {
        List {
            ForEach(songs, id: \.compoundRemoteId) { song in
                Button {
                    toggle(song.compoundRemoteId)
                } label: {
                    HStack {
                        EntityRow(
                            title: song.title,
                            subtitle: song.artistName ?? "Unknown",
                            artworkURL: song.album?.artworkToken
                        )
                        Spacer()
                        if selectedIDs.contains(song.compoundRemoteId) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("Add Songs")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Add (\(selectedIDs.count))") {
                    Task { await addSelected() }
                }
                .disabled(selectedIDs.isEmpty || isSaving)
            }
        }
    }

    private func toggle(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    @MainActor
    private func addSelected() async {
        guard let playlist = playlists.first else { return }
        let selected = songs.filter { selectedIDs.contains($0.compoundRemoteId) }
        isSaving = true
        defer { isSaving = false }
        try? await LibraryActions.shared.addSongs(selected, to: playlist)
        dismiss()
    }
}
