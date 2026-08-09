import CarPlay
import UIKit
import VerodromeKit

@available(iOS 14.0, *)
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private weak var interfaceController: CPInterfaceController?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        Task { @MainActor in
            _ = try? await VerodromeKit.shared.ensureActiveLibrarySyncer()
            do {
                try await interfaceController.setRootTemplate(makeRootTemplate(), animated: true)
            } catch {
                // CarPlay connection can race; ignore template set failures.
            }
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
    }

    @MainActor
    private func makeRootTemplate() -> CPListTemplate {
        let playlists = CPListItem(text: "Playlists", detailText: "Your playlists")
        playlists.handler = { [weak self] _, completion in
            Task { @MainActor in
                self?.pushPlaylists()
                completion()
            }
        }

        let albums = CPListItem(text: "Albums", detailText: "Browse albums")
        albums.handler = { [weak self] _, completion in
            Task { @MainActor in
                self?.pushAlbums()
                completion()
            }
        }

        let artists = CPListItem(text: "Artists", detailText: "Browse artists")
        artists.handler = { [weak self] _, completion in
            Task { @MainActor in
                self?.pushArtists()
                completion()
            }
        }

        let downloads = CPListItem(text: "Downloads", detailText: "Offline songs")
        downloads.handler = { [weak self] _, completion in
            Task { @MainActor in
                self?.pushDownloads()
                completion()
            }
        }

        let section = CPListSection(items: [playlists, albums, artists, downloads])
        return CPListTemplate(title: "Verodrome", sections: [section])
    }

    @MainActor
    private func pushPlaylists() {
        guard let account = try? VerodromeKit.shared.activeAccount(),
              let playlists = try? VerodromeKit.shared.repository()?.fetchPlaylists(account: account) else {
            pushEmpty(title: "Playlists")
            return
        }
        let items: [CPListItem] = playlists.map { playlist in
            let item = CPListItem(text: playlist.name, detailText: "\(playlist.songCount) songs")
            let playlistID = playlist.compoundRemoteId
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    self?.playPlaylist(compoundRemoteId: playlistID)
                    completion()
                }
            }
            return item
        }
        pushList(title: "Playlists", items: items)
    }

    @MainActor
    private func pushAlbums() {
        guard let account = try? VerodromeKit.shared.activeAccount(),
              let albums = try? VerodromeKit.shared.repository()?.fetchAlbums(account: account) else {
            pushEmpty(title: "Albums")
            return
        }
        let items: [CPListItem] = albums.prefix(200).map { album in
            let item = CPListItem(text: album.title, detailText: album.artist?.name)
            let albumID = album.compoundRemoteId
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    self?.playAlbum(compoundRemoteId: albumID)
                    completion()
                }
            }
            return item
        }
        pushList(title: "Albums", items: Array(items))
    }

    @MainActor
    private func pushArtists() {
        guard let account = try? VerodromeKit.shared.activeAccount(),
              let artists = try? VerodromeKit.shared.repository()?.fetchArtists(account: account) else {
            pushEmpty(title: "Artists")
            return
        }
        let items: [CPListItem] = artists.prefix(200).map { artist in
            let item = CPListItem(text: artist.name, detailText: "\(artist.albumCount) albums")
            let artistID = artist.compoundRemoteId
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    self?.playArtist(compoundRemoteId: artistID)
                    completion()
                }
            }
            return item
        }
        pushList(title: "Artists", items: Array(items))
    }

    @MainActor
    private func pushDownloads() {
        guard let account = try? VerodromeKit.shared.activeAccount(),
              let songs = try? VerodromeKit.shared.repository()?.fetchSongs(account: account, cachedOnly: false) else {
            pushEmpty(title: "Downloads")
            return
        }
        let downloads = songs.filter(\.isDownloadedLocally)
        let items: [CPListItem] = downloads.prefix(200).map { song in
            let item = CPListItem(text: song.title, detailText: song.artistName ?? song.artist?.name)
            let songID = song.compoundRemoteId
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    self?.playSong(compoundRemoteId: songID, among: downloads)
                    completion()
                }
            }
            return item
        }
        pushList(title: "Downloads", items: Array(items))
    }

    @MainActor
    private func playPlaylist(compoundRemoteId: String) {
        guard let playlist = try? VerodromeKit.shared.repository()?.fetchPlaylist(compoundRemoteId: compoundRemoteId) else { return }
        let songs = playlist.items.sorted { $0.order < $1.order }.compactMap(\.song)
        play(songs.map(QueueItem.from))
    }

    @MainActor
    private func playAlbum(compoundRemoteId: String) {
        guard let album = try? VerodromeKit.shared.repository()?.fetchAlbum(compoundRemoteId: compoundRemoteId) else { return }
        let songs = album.songs.sorted { ($0.track ?? 0) < ($1.track ?? 0) }
        play(songs.map { QueueItem.from($0, albumArtworkId: album.artworkToken) })
    }

    @MainActor
    private func playArtist(compoundRemoteId: String) {
        guard let account = try? VerodromeKit.shared.activeAccount(),
              let songs = try? VerodromeKit.shared.repository()?.fetchSongs(account: account) else { return }
        let artistSongs = songs.filter {
            $0.artist?.compoundRemoteId == compoundRemoteId
                || $0.album?.artist?.compoundRemoteId == compoundRemoteId
        }
        play(artistSongs.map(QueueItem.from))
    }

    @MainActor
    private func playSong(compoundRemoteId: String, among songs: [Song]) {
        let items = songs.map(QueueItem.from)
        let index = songs.firstIndex(where: { $0.compoundRemoteId == compoundRemoteId }) ?? 0
        play(items, startAt: index)
    }

    @MainActor
    private func play(_ items: [QueueItem], startAt index: Int = 0) {
        guard !items.isEmpty else { return }
        Task {
            await VerodromeKit.shared.player?.play(items: items, startAt: index)
        }
    }

    @MainActor
    private func pushList(title: String, items: [CPListItem]) {
        let template = CPListTemplate(title: title, sections: [CPListSection(items: items)])
        Task {
            try? await interfaceController?.pushTemplate(template, animated: true)
        }
    }

    @MainActor
    private func pushEmpty(title: String) {
        let item = CPListItem(text: "Nothing here yet", detailText: nil)
        item.handler = { _, completion in completion() }
        pushList(title: title, items: [item])
    }
}
