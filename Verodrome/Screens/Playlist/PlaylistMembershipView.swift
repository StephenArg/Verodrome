import SwiftData
import SwiftUI
import VerodromeKit

/// Shows every playlist alongside whether the song is in it, and lets each one be toggled.
///
/// Distinct from `PlaylistSelectorView`, which adds a batch of songs to one playlist and
/// has no notion of membership.
struct PlaylistMembershipView: View {
    let song: Song

    @Query(sort: \Playlist.sortName) private var allPlaylists: [Playlist]
    @ObservedObject private var membership = PlaylistMembershipIndex.shared
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    /// Playlists with a toggle in flight, so a slow server can't be double-tapped.
    @State private var pending: Set<String> = []
    @State private var isCreating = false
    @State private var newPlaylistName = ""
    /// Count / art shown after a tap, before SwiftData merges the write back onto the
    /// `@Query` models. Keyed by playlist remote id.
    @State private var presentation: [String: RowPresentation] = [:]

    /// When each account's playlist catalog was last pulled for this sheet. Adding a run
    /// of songs means reopening it once per track, and every pull re-ingests the catalog.
    private static var lastCatalogRefresh: [String: Date] = [:]
    private static let catalogRefreshInterval: TimeInterval = 30

    /// Only what this user can actually change. Smart playlists are rebuilt from rules by
    /// the server and other people's playlists are refused outright, so listing either one
    /// would offer an add that can't happen. In the Playlists list's order.
    private var editablePlaylists: [Playlist] {
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

    private var songArtworkToken: String? { song.displayArtworkToken }

    var body: some View {
        let playlists = editablePlaylists
        NavigationStack {
            List {
                Section {
                    Button {
                        newPlaylistName = ""
                        isCreating = true
                    } label: {
                        Label("New Playlist", systemImage: "plus")
                            .font(.body)
                    }
                }

                Section {
                    if playlists.isEmpty {
                        Text("No playlists you can edit.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(playlists) { playlist in
                        row(for: playlist)
                    }
                }
            }
            .tint(themeManager.accentColor)
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("New Playlist", isPresented: $isCreating) {
                TextField("Name", text: $newPlaylistName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { Task { await createAndAdd() } }
            } message: {
                Text("\(song.title) will be added to it.")
            }
            .task { await refreshMembership() }
            .onReceive(NotificationCenter.default.publisher(for: .playlistItemsChanged)) { _ in
                VerodromeKit.shared.storage?.mainContext.processPendingChanges()
                dropSettledPresentation()
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for playlist: Playlist) -> some View {
        let isMember = membership.isMember(songId: song.remoteId, playlistId: playlist.remoteId)
        let isPending = pending.contains(playlist.remoteId)
        let shown = presentation[playlist.remoteId]
        // `presentation` already carries the count through a toggle, so this doesn't walk
        // `playlist.items` per row per redraw — that faulted every entry of every visible
        // playlist on the main thread and made the list stutter while scrolling.
        let songCount = shown?.songCount ?? playlist.songCount
        let artwork = shown?.artworkToken
            ?? playlist.displayArtworkToken
            ?? (isMember ? songArtworkToken : nil)

        Button {
            Task { await toggle(playlist, isMember: isMember) }
        } label: {
            HStack(spacing: 12) {
                EntityRow(
                    title: playlist.name,
                    subtitle: "\(songCount) songs",
                    artworkURL: artwork,
                    symbol: "music.note.house.fill",
                    isFavorite: playlist.isFavorite
                )

                if isPending {
                    ProgressView()
                        .frame(width: 24, height: 24)
                } else {
                    Image(systemName: isMember ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(isMember ? themeManager.accentColor : Color.secondary)
                        .symbolRenderingMode(.monochrome)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 24, height: 24)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isPending)
        .accessibilityLabel(playlist.name)
        .accessibilityValue(isMember ? "In playlist" : "Not in playlist")
    }

    // MARK: - Actions

    private func toggle(_ playlist: Playlist, isMember: Bool) async {
        let playlistId = playlist.remoteId
        guard !pending.contains(playlistId) else { return }
        pending.insert(playlistId)
        defer { pending.remove(playlistId) }

        let previous = presentation[playlistId]
        let nextCount = isMember
            ? max(0, (previous?.songCount ?? playlist.songCount) - 1)
            : (previous?.songCount ?? playlist.songCount) + 1
        let nextArt: String? = {
            if isMember {
                return nextCount == 0 ? nil : (previous?.artworkToken ?? playlist.displayArtworkToken)
            }
            return previous?.artworkToken
                ?? playlist.displayArtworkToken
                ?? songArtworkToken
        }()
        presentation[playlistId] = RowPresentation(songCount: nextCount, artworkToken: nextArt)

        do {
            // Flipped first so the row answers the tap immediately; the server round trip
            // can take a while, and a failure puts it back.
            try await membership.setMembership(songId: song.remoteId, playlistId: playlistId, isMember: !isMember) {
                if isMember {
                    try await LibraryActions.shared.removeSong(song, from: playlist)
                } else {
                    try await LibraryActions.shared.addSongs([song], to: playlist)
                }
            }
            if isMember {
                ActionToast.show("Removed from \(playlist.name)")
            } else {
                ActionToast.addedToPlaylist(playlist.name)
            }
            // Prefer whatever the write just persisted on this model instance.
            presentation[playlistId] = RowPresentation(
                songCount: playlist.songCount,
                artworkToken: playlist.displayArtworkToken ?? nextArt
            )
        } catch {
            presentation[playlistId] = previous
            // A rejection is the only way to learn this on a server that reports neither
            // `readonly` nor an owner, and recording it drops the row from the list.
            if LibraryActions.shared.notePlaylistEditRejected(playlist, error: error) {
                ActionToast.show("\(playlist.name) can't be edited")
            } else {
                ActionToast.show(isMember ? "Couldn't remove from \(playlist.name)" : "Couldn't add to \(playlist.name)")
            }
        }
    }

    private func createAndAdd() async {
        let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let playlist: Playlist
        do {
            playlist = try await LibraryActions.shared.createPlaylist(name: name)
        } catch {
            ActionToast.show("Couldn't create \(name)")
            return
        }
        presentation[playlist.remoteId] = RowPresentation(
            songCount: 1,
            artworkToken: songArtworkToken
        )
        do {
            try await membership.setMembership(songId: song.remoteId, playlistId: playlist.remoteId, isMember: true) {
                try await LibraryActions.shared.addSongs([song], to: playlist)
            }
            presentation[playlist.remoteId] = RowPresentation(
                songCount: playlist.songCount,
                artworkToken: playlist.displayArtworkToken ?? songArtworkToken
            )
            ActionToast.addedToPlaylist(playlist.name)
        } catch {
            presentation[playlist.remoteId] = nil
            ActionToast.show("Couldn't add to \(name)")
        }
    }

    /// Drops the stand-in count / art for rows the store has caught up with, so `@Query`
    /// owns them again.
    private func dropSettledPresentation() {
        guard !presentation.isEmpty else { return }
        let byId = Dictionary(editablePlaylists.map { ($0.remoteId, $0) }, uniquingKeysWith: { first, _ in first })
        presentation = presentation.filter { id, value in
            guard let playlist = byId[id] else { return false }
            let storeArt = playlist.displayArtworkToken
            let artMatches = value.artworkToken == storeArt
                || (value.artworkToken == nil && storeArt == nil)
            return playlist.songCount != value.songCount || !artMatches
        }
    }

    /// Refreshes the catalog, then fills in the track lists of playlists that have never
    /// been opened.
    ///
    /// No backend can be asked which playlists hold a given song, so the answer has to be
    /// assembled from each playlist's contents — and `getPlaylists` returns metadata only.
    /// Limiting the pass to playlists with no local items keeps this to roughly the first
    /// time the sheet is opened rather than a fan-out on every appearance.
    private func refreshMembership() async {
        guard let syncer = try? await VerodromeKit.shared.ensureActiveLibrarySyncer(),
              let account = try? VerodromeKit.shared.activeAccount(),
              let storage = VerodromeKit.shared.storage else { return }
        let accountKey = account.compoundKey

        let lastRefresh = Self.lastCatalogRefresh[accountKey]
        if lastRefresh.map({ Date().timeIntervalSince($0) >= Self.catalogRefreshInterval }) ?? true,
           let remoteIds = try? await syncer.syncPlaylistCatalog() {
            Self.lastCatalogRefresh[accountKey] = Date()
            _ = try? LibraryPruner.prunePlaylists(
                account: account,
                keepingRemoteIds: Set(remoteIds),
                context: storage.mainContext
            )
        }

        // Read on a fresh background context rather than through the query: the sync above
        // may have added playlists the view's snapshot hasn't picked up yet, and those are
        // precisely the ones with nothing cached. Off the main thread because asking a
        // playlist whether it has items loads its whole track list.
        let container = storage.container
        let unsynced = await Task.detached(priority: .utility) {
            Self.playlistsWithoutLocalItems(container: container, accountKey: accountKey)
        }.value
        guard !unsynced.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            var next = unsynced.makeIterator()
            var running = 0
            let maxConcurrent = 4

            while running < maxConcurrent, let id = next.next() {
                group.addTask { try? await syncer.syncPlaylistDown(id: id) }
                running += 1
            }
            while await group.next() != nil {
                guard !Task.isCancelled, let id = next.next() else { continue }
                group.addTask { try? await syncer.syncPlaylistDown(id: id) }
            }
        }
        membership.invalidate()
    }

    private nonisolated static func playlistsWithoutLocalItems(
        container: ModelContainer,
        accountKey: String
    ) -> [String] {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Playlist>(
            predicate: #Predicate { $0.isEditable && !$0.isSmart && $0.songCount > 0 }
        )
        let playlists = (try? context.fetch(descriptor)) ?? []
        return playlists
            .filter { $0.account?.compoundKey == accountKey && $0.items.isEmpty }
            .map(\.remoteId)
    }
}

private struct RowPresentation: Equatable {
    var songCount: Int
    var artworkToken: String?
}
