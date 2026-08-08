import SwiftUI
import SwiftData
import VerodromeKit

/// Shared song row menus, swipe actions, and playlist sheet wiring.
struct SongActionsModifier: ViewModifier {
    let song: Song
    @EnvironmentObject private var player: PlayerViewModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var themeManager: ThemeManager
    @ObservedObject private var downloadCenter = DownloadCenter.shared
    @State private var showPlaylistSelector = false

    private var downloadStatus: DownloadStatus {
        downloadCenter.status(for: song.remoteId, isDownloaded: song.isDownloadedLocally)
    }

    private var isDownloadWorking: Bool {
        switch downloadStatus {
        case .pending, .downloading: return true
        default: return false
        }
    }

    private var downloadActionTitle: String {
        switch downloadStatus {
        case .pending, .downloading: return "Cancel Download"
        case .downloaded: return "Remove Download"
        case .failed: return "Retry Download"
        // Cached is still free to promote to a keep-forever download.
        case .none, .partial, .cached: return "Download"
        }
    }

    private var downloadActionSymbol: String {
        switch downloadStatus {
        case .pending, .downloading: return "stop.circle"
        case .downloaded: return "arrow.down.circle.fill"
        case .failed: return "exclamationmark.circle"
        case .none, .partial, .cached: return "arrow.down.circle"
        }
    }

    func body(content: Content) -> some View {
        content
            .contextMenu { menuButtons }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                swipeButtons(for: settings.swipeLeftAction)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                swipeButtons(for: settings.swipeRightAction)
            }
            .sheet(isPresented: $showPlaylistSelector) {
                PlaylistSelectorView { playlist in
                    Task {
                        try? await LibraryActions.shared.addSongs([song], to: playlist)
                        ActionToast.addedToPlaylist(playlist.name)
                    }
                }
            }
    }

    @ViewBuilder
    private var menuButtons: some View {
        Button {
            player.addToQueueTemporarily([QueueItem.from(song)])
        } label: {
            Label("Add to Queue", systemImage: "text.append")
        }

        Button {
            Task { await ActionToast.toggleFavorite(song: song) }
        } label: {
            Label(
                song.isFavorite ? "Unfavorite" : "Favorite",
                systemImage: song.isFavorite ? "heart.slash" : "heart"
            )
        }

        Menu {
            ForEach(0...5, id: \.self) { stars in
                Button {
                    Task { try? await LibraryActions.shared.setRating(song: song, rating: stars) }
                } label: {
                    if stars == 0 {
                        Label("Clear Rating", systemImage: "star.slash")
                    } else {
                        Label(
                            String(repeating: "★", count: stars),
                            systemImage: song.rating == stars ? "checkmark" : "star"
                        )
                    }
                }
            }
        } label: {
            Label(
                song.rating > 0 ? "Rated \(song.rating)/5" : "Rate",
                systemImage: song.rating > 0 ? "star.fill" : "star"
            )
        }

        Button {
            Task { await LibraryActions.shared.downloadOrCancel(song: song) }
        } label: {
            Label(downloadActionTitle, systemImage: downloadActionSymbol)
        }

        Button {
            showPlaylistSelector = true
        } label: {
            Label("Add to Playlist", systemImage: "text.badge.plus")
        }
    }

    @ViewBuilder
    private func swipeButtons(for action: String) -> some View {
        switch action {
        case "queue":
            Button {
                player.addToQueueTemporarily([QueueItem.from(song)])
            } label: {
                Label("Queue", systemImage: "text.append")
            }
            .tint(.indigo)
        case "download":
            Button {
                Task { await LibraryActions.shared.downloadOrCancel(song: song) }
            } label: {
                Label(
                    downloadStatus == .none ? "Download" : (isDownloadWorking ? "Cancel" : "Remove"),
                    systemImage: "arrow.down.circle"
                )
            }
            .tint(.blue)
        case "favorite":
            Button {
                Task { await ActionToast.toggleFavorite(song: song) }
            } label: {
                Label("Favorite", systemImage: "heart")
            }
            .tint(themeManager.accentColor)
        default:
            EmptyView()
        }
    }
}

extension View {
    func songActions(_ song: Song) -> some View {
        modifier(SongActionsModifier(song: song))
    }
}
