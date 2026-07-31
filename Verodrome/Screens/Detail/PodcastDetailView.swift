import SwiftUI
import SwiftData
import VerodromeKit

struct PodcastDetailView: View {
    let podcastID: String
    @Query private var podcasts: [Podcast]
    @EnvironmentObject private var nowPlaying: NowPlayingModel
    @EnvironmentObject private var player: PlayerViewModel

    @State private var episodes: [PodcastEpisode] = []

    init(podcastID: String) {
        self.podcastID = podcastID
        _podcasts = Query(filter: #Predicate<Podcast> { $0.compoundRemoteId == podcastID })
    }

    var body: some View {
        List {
            if let podcast = podcasts.first {
                Section {
                    DetailHeader(
                        title: podcast.title,
                        subtitle: "\(podcast.author ?? "") · \(episodes.count) episodes",
                        artworkURL: podcast.artworkToken,
                        symbol: "mic.fill",
                        onPlay: { play(from: 0) },
                        onShuffle: { play(shuffle: true) }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                Section("Episodes") {
                    ForEach(episodes, id: \.compoundRemoteId) { episode in
                        Button {
                            playEpisode(episode)
                        } label: {
                            EntityRow(
                                title: episode.title,
                                subtitle: podcast.title,
                                symbol: "mic.fill",
                                isPlaying: nowPlaying.currentItem?.playableId == episode.remoteId,
                                trailing: formatDuration(episode.playDuration)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task(id: podcasts.first?.remoteId) {
            guard let podcast = podcasts.first else { return }
            loadEpisodes(for: podcast)
            guard let remoteId = podcasts.first?.remoteId else { return }
            try? await VerodromeKit.shared.ensureActiveLibrarySyncer()?.sync(podcastId: remoteId)
            if let podcast = podcasts.first {
                loadEpisodes(for: podcast)
            }
        }
    }

    private func loadEpisodes(for podcast: Podcast) {
        episodes = podcast.episodes.sorted { ($0.track ?? 0) > ($1.track ?? 0) }
    }

    private func play(from index: Int? = nil, shuffle: Bool = false) {
        player.play(items: episodes.map(QueueItem.from), startAt: index, shuffle: shuffle)
    }

    private func playEpisode(_ episode: PodcastEpisode) {
        let items = episodes.map(QueueItem.from)
        let index = episodes.firstIndex(where: { $0.compoundRemoteId == episode.compoundRemoteId }) ?? 0
        player.play(items: items, startAt: index)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        guard duration > 0 else { return "" }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
