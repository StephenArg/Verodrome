import Foundation
import VerodromeKit

@MainActor
enum DeepLinkHandler {
    static func handle(_ url: URL, router: AppRouter, player: PlayerViewModel) async {
        switch DeepLinkRouter.parse(url) {
        case .play(let query):
            await playMatching(query: query, player: player)
        case .search(let query):
            router.push(.search)
            NotificationCenter.default.post(
                name: .verodromePerformSearch,
                object: nil,
                userInfo: ["query": query]
            )
        case .navigate(let destination):
            switch destination {
            case "settings":
                router.push(.settings)
            case "home", "library", "downloads", "radios":
                router.popToRoot()
            default:
                break
            }
        case .unknown:
            break
        }
    }

    private static func playMatching(query: String, player: PlayerViewModel) async {
        guard let account = try? VerodromeKit.shared.activeAccount(),
              let repo = VerodromeKit.shared.repository() else { return }
        let songs = (try? repo.fetchSongs(account: account)) ?? []
        let lowered = query.lowercased()
        let matches = songs.filter {
            $0.remoteId == query
                || $0.title.lowercased().contains(lowered)
                || ($0.artistName?.lowercased().contains(lowered) ?? false)
        }
        guard !matches.isEmpty else { return }
        let items = matches.map(QueueItem.from)
        player.play(items: items, startAt: 0, origin: .song(items[0].title))
    }
}

extension Notification.Name {
    static let verodromeOpenURL = Notification.Name("verodromeOpenURL")
    static let verodromePerformSearch = Notification.Name("verodromePerformSearch")
}
