import SwiftUI
import SwiftData
import VerodromeKit

struct PlaylistEditView: View {
    let playlistID: String?
    @Environment(\.dismiss) private var dismiss
    @Query private var playlists: [Playlist]
    @State private var name = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(playlistID: String?) {
        self.playlistID = playlistID
        if let playlistID {
            _playlists = Query(filter: #Predicate<Playlist> { $0.compoundRemoteId == playlistID })
        } else {
            _playlists = Query(filter: #Predicate<Playlist> { $0.remoteId == "" })
        }
    }

    var body: some View {
        Form {
            Section("Details") {
                TextField("Playlist Name", text: $name)
            }
            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(playlistID == nil ? "New Playlist" : "Edit Playlist")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task { await save() }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
            }
        }
        .onAppear { name = playlists.first?.name ?? "" }
    }

    @MainActor
    private func save() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            if let existing = playlists.first {
                try await LibraryActions.shared.renamePlaylist(existing, name: trimmed)
            } else {
                _ = try await LibraryActions.shared.createPlaylist(name: trimmed)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
