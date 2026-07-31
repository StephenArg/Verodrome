import SwiftUI
import VerodromeKit

struct DirectoriesView: View {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var player: PlayerViewModel

    var body: some View {
        if account.detectedApiType == .ampache {
            ContentUnavailableView(
                "Not Supported",
                systemImage: "folder.badge.questionmark",
                description: Text("Directory browsing is available on Subsonic servers only.")
            )
            .navigationTitle("Directories")
        } else {
            DirectoryBrowserView(folderId: nil, title: "Directories")
        }
    }
}

struct DirectoryBrowserView: View {
    let folderId: String?
    let title: String

    @EnvironmentObject private var player: PlayerViewModel
    @State private var entries: [DirectoryEntry] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading…")
            } else if let errorMessage {
                ContentUnavailableView(
                    "Unable to Load",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if entries.isEmpty {
                ContentUnavailableView(
                    "Empty Folder",
                    systemImage: "folder",
                    description: Text("No items in this directory.")
                )
            } else {
                List {
                    ForEach(entries) { entry in
                        switch entry.kind {
                        case .folder, .artist, .album:
                            NavigationLink {
                                DirectoryBrowserView(folderId: entry.id, title: entry.name)
                            } label: {
                                EntityRow(
                                    title: entry.name,
                                    subtitle: entry.kind.rawValue.capitalized,
                                    artworkURL: entry.coverArtId,
                                    symbol: entry.kind == .folder ? "folder.fill" : "square.stack.fill"
                                )
                            }
                        case .song:
                            Button {
                                play(from: entry)
                            } label: {
                                EntityRow(
                                    title: entry.name,
                                    subtitle: entry.artistName ?? entry.albumName ?? "Song",
                                    artworkURL: entry.coverArtId,
                                    isPlaying: player.currentItem?.playableId == entry.id,
                                    trailing: entry.duration.map(formatDuration)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .task(id: folderId) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            guard let syncer = VerodromeKit.shared.activeLibrarySyncer else {
                errorMessage = "Not connected to a server."
                return
            }
            entries = try await syncer.listMusicDirectory(folderId: folderId)
        } catch let error as BackendApiError {
            if case .unsupportedOperation(let detail) = error {
                errorMessage = detail
            } else {
                errorMessage = error.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func play(from entry: DirectoryEntry) {
        let songs = entries.compactMap { $0.asQueueItem() }
        guard let item = entry.asQueueItem(),
              let index = songs.firstIndex(where: { $0.playableId == item.playableId }) else { return }
        player.play(items: songs, startAt: index)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60)
    }
}
