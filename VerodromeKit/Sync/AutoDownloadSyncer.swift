import Foundation

@MainActor
public final class AutoDownloadSyncer {
    private let downloader: DownloadManager

    public init(downloader: DownloadManager) {
        self.downloader = downloader
    }

    public func download(playableIds: [String], kind: PlayableRef.Kind = .song) async {
        for id in playableIds {
            await downloader.enqueue(playableId: id, kind: kind, reason: .autoNewest)
        }
    }
}
