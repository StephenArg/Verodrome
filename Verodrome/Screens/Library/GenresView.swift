import SwiftUI
import SwiftData
import VerodromeKit

struct GenresView: View {
    @Query(sort: \Genre.name) private var genres: [Genre]
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        AlphabetIndexedList(
            items: genres.map(GenreRowItem.init),
            sectionTitle: \.name,
            perfLabel: "Genres"
        ) { item in
            NavigationLink {
                GenreDetailView(genreID: item.id)
            } label: {
                EntityRow(
                    title: item.name,
                    subtitle: "\(item.albumCount) albums · \(item.songCount) songs",
                    artworkURL: item.artworkToken,
                    symbol: "guitars.fill"
                )
            }
        }
        .navigationTitle("Genres")
        .perfAppear("Genres", details: "count=\(genres.count)")
        .task {
            backfillMissingGenreArtwork()
        }
    }

    /// One-shot fill for genres synced before artwork was denormalized onto the model.
    private func backfillMissingGenreArtwork() {
        var didChange = false
        for genre in genres where genre.artworkToken == nil || genre.artworkToken?.isEmpty == true {
            let name = genre.name
            var descriptor = FetchDescriptor<Album>(
                predicate: #Predicate<Album> { album in
                    album.genreName == name
                }
            )
            descriptor.fetchLimit = 24
            let albums = (try? modelContext.fetch(descriptor)) ?? []
            if let token = albums.compactMap(\.artworkToken).first(where: { !$0.isEmpty }) {
                genre.artworkToken = token
                didChange = true
            }
        }
        if didChange {
            try? modelContext.save()
        }
    }
}

private struct GenreRowItem: Identifiable {
    let id: String
    let name: String
    let albumCount: Int
    let songCount: Int
    let artworkToken: String?

    init(_ genre: Genre) {
        id = genre.compoundRemoteId
        name = genre.name
        albumCount = genre.albumCount
        songCount = genre.songCount
        artworkToken = genre.artworkToken
    }
}
