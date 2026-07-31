import SwiftUI
import SwiftData
import VerodromeKit

/// Shared song row menus, swipe actions, and playlist sheet wiring.
struct SongActionsModifier: ViewModifier {
    let song: Song
    @EnvironmentObject private var player: PlayerViewModel
    @EnvironmentObject private var settings: SettingsStore
    @State private var showPlaylistSelector = false

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
                    Task { try? await LibraryActions.shared.addSongs([song], to: playlist) }
                }
            }
    }

    @ViewBuilder
    private var menuButtons: some View {
        Button {
            player.playNext([QueueItem.from(song)])
        } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }

        Button {
            Task { try? await LibraryActions.shared.toggleFavorite(song: song) }
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
            Label(
                song.isDownloadedLocally ? "Remove Download" : "Download",
                systemImage: song.isDownloadedLocally ? "arrow.down.circle.fill" : "arrow.down.circle"
            )
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
                player.playNext([QueueItem.from(song)])
            } label: {
                Label("Queue", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            .tint(.indigo)
        case "download":
            Button {
                Task { await LibraryActions.shared.downloadOrCancel(song: song) }
            } label: {
                Label(
                    song.isDownloadedLocally ? "Remove" : "Download",
                    systemImage: "arrow.down.circle"
                )
            }
            .tint(.blue)
        case "favorite":
            Button {
                Task { try? await LibraryActions.shared.toggleFavorite(song: song) }
            } label: {
                Label("Favorite", systemImage: "heart")
            }
            .tint(.pink)
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
