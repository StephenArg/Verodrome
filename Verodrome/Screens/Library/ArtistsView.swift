import SwiftUI
import SwiftData
import VerodromeKit

struct ArtistsView: View {
    @Query(sort: \Artist.sortName) private var artists: [Artist]
    @State private var searchText = ""
    @State private var rowItems: [ArtistRowItem] = []

    private var rowsFingerprint: String {
        guard let first = artists.first, let last = artists.last else {
            return "0|\(searchText)"
        }
        return "\(artists.count)|\(first.compoundRemoteId)|\(last.compoundRemoteId)|\(searchText)"
    }

    var body: some View {
        AlphabetIndexedList(
            items: rowItems,
            sectionTitle: \.sortName,
            perfLabel: "Artists"
        ) { item in
            NavigationLink {
                ArtistDetailView(artistID: item.id)
            } label: {
                EntityRow(
                    title: item.name,
                    subtitle: item.subtitle,
                    artworkURL: item.artworkToken,
                    symbol: "person.fill"
                )
            }
        }
        .navigationTitle("Artists")
        .searchable(text: $searchText, prompt: "Filter artists")
        .perfAppear("Artists", details: "queryCount=\(artists.count) rows=\(rowItems.count)")
        .task(id: rowsFingerprint) {
            rowItems = PerfTrace.measure(
                "Artists.makeRows",
                details: "query=\(artists.count) search=\(searchText.isEmpty ? "off" : "on")"
            ) {
                Self.makeRows(from: artists, searchText: searchText)
            }
        }
    }

    private static func makeRows(from artists: [Artist], searchText: String) -> [ArtistRowItem] {
        let source: [Artist]
        if searchText.isEmpty {
            source = artists
        } else {
            source = artists.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        return source.map(ArtistRowItem.init)
    }
}

/// Lightweight row model so list identity is stable without SwiftData faulting during section rebuilds.
private struct ArtistRowItem: Identifiable {
    let id: String
    let name: String
    let sortName: String
    let subtitle: String
    let artworkToken: String?

    init(_ artist: Artist) {
        id = artist.compoundRemoteId
        name = artist.name
        sortName = artist.sortName.isEmpty ? artist.name : artist.sortName
        subtitle = "\(artist.albumCount) albums · \(artist.songCount) songs"
        artworkToken = artist.artworkToken
    }
}
