import SwiftUI
import SwiftData
import VerodromeKit

struct PodcastDetailView: View {
    let podcastID: String
    @Query private var podcasts: [Podcast]
    @Query(sort: \PodcastEpisode.title) private var allEpisodes: [PodcastEpisode]
    @EnvironmentObject private var player: PlayerViewModel

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
                        subtitle: "\(podcast.author ?? "") · \(episodes(for: podcast).count) episodes",
                        artworkURL: podcast.artworkToken,
                        symbol: "mic.fill",
                        onPlay: { play(from: 0, podcast: podcast) },
                        onShuffle: { play(shuffle: true, podcast: podcast) }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                Section("Episodes") {
                    ForEach(episodes(for: podcast), id: \.compoundRemoteId) { episode in
                        Button {
                            playEpisode(episode, podcast: podcast)
                        } label: {
                            EntityRow(
                                title: episode.title,
                                subtitle: podcast.title,
                                symbol: "mic.fill",
                                isPlaying: player.currentItem?.playableId == episode.remoteId,
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
            guard let remoteId = podcasts.first?.remoteId else { return }
            try? await VerodromeKit.shared.ensureActiveLibrarySyncer()?.sync(podcastId: remoteId)
        }
    }

    private func episodes(for podcast: Podcast) -> [PodcastEpisode] {
        let linked = allEpisodes.filter { $0.podcast?.compoundRemoteId == podcast.compoundRemoteId }
        if !linked.isEmpty { return linked.sorted { ($0.track ?? 0) > ($1.track ?? 0) } }
        return podcast.episodes.sorted { ($0.track ?? 0) > ($1.track ?? 0) }
    }

    private func play(from index: Int = 0, shuffle: Bool = false, podcast: Podcast) {
        var items = episodes(for: podcast).map(QueueItem.from)
        if shuffle { items.shuffle() }
        player.play(items: items, startAt: shuffle ? 0 : index)
    }

    private func playEpisode(_ episode: PodcastEpisode, podcast: Podcast) {
        let podcastEpisodes = episodes(for: podcast)
        let items = podcastEpisodes.map(QueueItem.from)
        let index = podcastEpisodes.firstIndex(where: { $0.compoundRemoteId == episode.compoundRemoteId }) ?? 0
        player.play(items: items, startAt: index)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        guard duration > 0 else { return "" }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
