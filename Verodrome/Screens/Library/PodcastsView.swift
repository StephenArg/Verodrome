import SwiftUI
import SwiftData
import VerodromeKit

struct PodcastsView: View {
    @Query(sort: \Podcast.title) private var podcasts: [Podcast]

    var body: some View {
        List(podcasts, id: \.compoundRemoteId) { podcast in
            NavigationLink {
                PodcastDetailView(podcastID: podcast.compoundRemoteId)
            } label: {
                EntityRow(
                    title: podcast.title,
                    subtitle: "\(podcast.author ?? "") · \(podcast.episodeCount) episodes",
                    artworkURL: podcast.artworkToken,
                    symbol: "mic.fill"
                )
            }
            .listRowBackground(Color(.systemBackground))
        }
        .listStyle(.plain)
        .navigationTitle("Podcasts")
    }
}
