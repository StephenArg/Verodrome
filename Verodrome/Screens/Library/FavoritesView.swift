import SwiftUI
import SwiftData
import VerodromeKit

struct FavoritesView: View {
    @EnvironmentObject private var nowPlaying: NowPlayingModel
    @EnvironmentObject private var librarySync: LibrarySyncCoordinator

    @State private var albumRows: [LibraryRowSnapshot] = []
    @State private var songRows: [LibraryRowSnapshot] = []
    @State private var selectedAlbumId: String?

    var body: some View {
        List {
            if !albumRows.isEmpty {
                Section("Albums") {
                    ForEach(albumRows) { row in
                        Button { selectedAlbumId = row.id } label: {
                            EntityRow(title: row.title, subtitle: row.subtitle, artworkURL: row.artworkToken)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section("Songs") {
                if songRows.isEmpty && albumRows.isEmpty {
                    Text("Mark items as favorites to see them here.").foregroundStyle(.secondary)
                } else {
                    ForEach(songRows) { row in
                        EntityRow(
                            title: row.title,
                            subtitle: row.subtitle,
                            artworkURL: row.artworkToken,
                            isPlaying: nowPlaying.isCurrent(row.playableId)
                        )
                    }
                }
            }
        }
        .navigationTitle("Favorites")
        .navigationDestination(item: $selectedAlbumId) { AlbumDetailView(albumID: $0) }
        .task {
            await reload()
        }
        .task(id: librarySync.isSyncing) {
            if !librarySync.isSyncing {
                await reload()
            }
        }
    }

    private func reload() async {
        let built = await Self.fetch()
        albumRows = built.albums
        songRows = built.songs
    }

    private static func fetch() async -> (albums: [LibraryRowSnapshot], songs: [LibraryRowSnapshot]) {
        do {
            return try await PersistentStorage.shared.backgroundActor.perform { context in
                let albums = try context.fetch(
                    FetchDescriptor<Album>(
                        predicate: #Predicate<Album> { $0.isFavorite == true },
                        sortBy: [SortDescriptor(\Album.title)]
                    )
                )
                let albumRows = albums.map { album in
                    LibraryRowSnapshot(
                        id: album.compoundRemoteId,
                        sectionKey: album.title.sectionInitial,
                        title: album.title,
                        subtitle: album.displayArtist,
                        artworkToken: album.artworkToken
                    )
                }

                let songs = try context.fetch(
                    FetchDescriptor<Song>(
                        predicate: #Predicate<Song> { $0.isFavorite == true },
                        sortBy: [SortDescriptor(\Song.title)]
                    )
                )
                let songRows = songs.map { song in
                    LibraryRowSnapshot(
                        id: song.compoundRemoteId,
                        sectionKey: song.title.sectionInitial,
                        title: song.title,
                        subtitle: song.displayArtist,
                        artworkToken: song.artworkToken,
                        playableId: song.remoteId
                    )
                }

                return (albumRows, songRows)
            }
        } catch {
            return ([], [])
        }
    }
}
