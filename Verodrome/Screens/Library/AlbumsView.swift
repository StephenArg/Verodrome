import SwiftUI
import SwiftData
import VerodromeKit

struct AlbumsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @Query(sort: \Album.sortTitle) private var albums: [Album]
    @State private var searchText = ""
    @State private var rowItems: [AlbumRowItem] = []

    private var rowsFingerprint: String {
        guard let first = albums.first, let last = albums.last else {
            return "0|\(searchText)"
        }
        return "\(albums.count)|\(first.compoundRemoteId)|\(last.compoundRemoteId)|\(searchText)"
    }

    var body: some View {
        Group {
            switch settings.libraryDisplayType {
            case .grid:
                AlbumsGridView(albums: filteredAlbums)
            case .list, .table:
                AlphabetIndexedList(
                    items: rowItems,
                    sectionTitle: \.sortTitle,
                    perfLabel: "Albums"
                ) { item in
                    NavigationLink {
                        AlbumDetailView(albumID: item.id)
                    } label: {
                        EntityRow(title: item.title, subtitle: item.artist, artworkURL: item.artworkToken)
                    }
                }
            }
        }
        .navigationTitle("Albums")
        .searchable(text: $searchText, prompt: "Filter albums")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Picker("Display", selection: $settings.libraryDisplayType) {
                    ForEach(LibraryDisplayType.allCases, id: \.self) { type in
                        Text(type.rawValue.capitalized).tag(type)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .task(id: rowsFingerprint) {
            rowItems = PerfTrace.measure(
                "Albums.makeRows",
                details: "query=\(albums.count) search=\(searchText.isEmpty ? "off" : "on") display=\(settings.libraryDisplayType.rawValue)"
            ) {
                Self.makeRows(from: albums, searchText: searchText)
            }
        }
        .perfAppear("Albums", details: "queryCount=\(albums.count) rows=\(rowItems.count) display=\(settings.libraryDisplayType.rawValue)")
    }

    private var filteredAlbums: [Album] {
        guard !searchText.isEmpty else { return albums }
        return albums.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.displayArtist.localizedCaseInsensitiveContains(searchText)
        }
    }

    private static func makeRows(from albums: [Album], searchText: String) -> [AlbumRowItem] {
        let source: [Album]
        if searchText.isEmpty {
            source = albums
        } else {
            source = albums.filter {
                $0.title.localizedCaseInsensitiveContains(searchText) ||
                $0.displayArtist.localizedCaseInsensitiveContains(searchText)
            }
        }
        return source.map(AlbumRowItem.init)
    }
}

private struct AlbumRowItem: Identifiable {
    let id: String
    let title: String
    let sortTitle: String
    let artist: String
    let artworkToken: String?

    init(_ album: Album) {
        id = album.compoundRemoteId
        title = album.title
        sortTitle = album.sortTitle.isEmpty ? album.title : album.sortTitle
        artist = album.displayArtist
        artworkToken = album.artworkToken
    }
}
