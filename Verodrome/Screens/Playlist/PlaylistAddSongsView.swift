import SwiftUI
import SwiftData
import VerodromeKit

struct PlaylistAddSongsView: View {
    let playlistID: String
    @Query private var playlists: [Playlist]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var songRows: [AddSongRow] = []
    @State private var selectedIDs: Set<String> = []
    @State private var isSaving = false
    @State private var searchText = ""
    @State private var debouncedSearch = ""

    init(playlistID: String) {
        self.playlistID = playlistID
        _playlists = Query(filter: #Predicate<Playlist> { $0.compoundRemoteId == playlistID })
    }

    var body: some View {
        List {
            ForEach(filteredRows) { row in
                Button {
                    toggle(row.id)
                } label: {
                    HStack {
                        EntityRow(
                            title: row.title,
                            subtitle: row.subtitle,
                            artworkURL: row.artworkToken
                        )
                        Spacer()
                        if selectedIDs.contains(row.id) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("Add Songs")
        .searchable(text: $searchText, prompt: "Filter songs")
        .debouncedSearch(text: $searchText) { newValue in
            debouncedSearch = newValue
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Add (\(selectedIDs.count))") {
                    Task { await addSelected() }
                }
                .disabled(selectedIDs.isEmpty || isSaving)
            }
        }
        .task {
            await reload()
        }
        .task(id: debouncedSearch) {
            await reload()
        }
    }

    private var filteredRows: [AddSongRow] {
        let search = debouncedSearch
        guard !search.isEmpty else { return songRows }
        return songRows.filter {
            $0.title.localizedCaseInsensitiveContains(search)
                || $0.subtitle.localizedCaseInsensitiveContains(search)
        }
    }

    private func toggle(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func reload() async {
        let rows = await Self.fetchSongs()
        songRows = rows
    }

    private static func fetchSongs() async -> [AddSongRow] {
        do {
            return try await PersistentStorage.shared.backgroundActor.perform { context in
                try context.fetch(FetchDescriptor<Song>(sortBy: [SortDescriptor(\Song.title)]))
                    .map(AddSongRow.init)
            }
        } catch {
            return []
        }
    }

    @MainActor
    private func addSelected() async {
        guard let playlist = playlists.first else { return }
        let selectedCompoundIds = selectedIDs
        var descriptor = FetchDescriptor<Song>(
            predicate: #Predicate<Song> { selectedCompoundIds.contains($0.compoundRemoteId) }
        )
        descriptor.fetchLimit = selectedCompoundIds.count
        let selected = (try? modelContext.fetch(descriptor)) ?? []
        isSaving = true
        defer { isSaving = false }
        try? await LibraryActions.shared.addSongs(selected, to: playlist)
        dismiss()
    }
}

struct AddSongRow: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let artworkToken: String?

    init(song: Song) {
        id = song.compoundRemoteId
        title = song.title
        subtitle = song.artistName ?? "Unknown"
        artworkToken = song.displayArtworkToken
    }
}
