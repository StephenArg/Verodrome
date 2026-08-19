import CarPlay
import UIKit
import VerodromeKit

@MainActor
final class CarPlayCatalog {
    weak var interfaceController: CPInterfaceController?
    var onDidStartPlayback: (() -> Void)?
    var onOpenSearch: (() -> Void)?
    var onSearchQuery: ((String) -> Void)?
    var onOpenNowPlaying: (() -> Void)?
    private weak var queueTemplate: CPListTemplate?
    private weak var playlistMembershipTemplate: CPListTemplate?
    private var playlistToggleInFlight: Set<String> = []

    private var itemCap: Int { min(200, CPListTemplate.maximumItemCount) }
    private var imageRowCap: Int { max(1, Int(CPMaximumNumberOfGridImages)) }
    /// Recently Played is a 2-column condensed grid, so 6 tiles is 3 visible rows.
    /// Filling all `imageRowCap` slots pushes the sections below it off-screen.
    private var homeGridCap: Int { min(6, imageRowCap) }
    /// Single-line strips cost a fixed height no matter how many tiles they hold, so
    /// supply extras for wide screens — CarPlay trims to whatever fits the width.
    private var homeStripCap: Int { min(8, imageRowCap) }

    // MARK: - Tabs

    /// Same columns as the finished Home, with placeholder art so the tab never
    /// flashes Library-style shortcut rows while covers load.
    func makeHomeTemplateSync() -> CPListTemplate {
        homeTemplate(sections: makeHomeSections { _, _ in CarPlayArtwork.tilePlaceholder() })
    }

    func makeHomeTemplate() async -> CPListTemplate {
        homeTemplate(sections: await makeHomeSectionsLoaded())
    }

    func makeHomeSectionsLoaded() async -> [CPListSection] {
        let recents = recentsHomeTiles()
        var recentsArt: [UIImage] = []
        recentsArt.reserveCapacity(recents.count)
        for tile in recents {
            recentsArt.append(
                await CarPlayArtwork.loadOrPlaceholder(
                    token: tile.artworkToken,
                    kind: tile.artworkKind,
                    size: 450
                )
            )
        }
        let added = Array(newestAlbums().prefix(homeStripCap))
        var addedArt: [UIImage] = []
        addedArt.reserveCapacity(added.count)
        for album in added {
            addedArt.append(
                await CarPlayArtwork.loadOrPlaceholder(token: album.artworkToken, kind: .album, size: 450)
            )
        }
        let playlists = homePlaylists()
        var playlistArt: [UIImage] = []
        playlistArt.reserveCapacity(playlists.count)
        for playlist in playlists {
            playlistArt.append(
                await CarPlayArtwork.loadOrPlaceholder(
                    token: playlist.displayArtworkToken,
                    kind: .playlist,
                    size: 450
                )
            )
        }
        return makeHomeSections(
            recents: recents,
            recentsArt: recentsArt,
            added: added,
            addedArt: addedArt,
            playlists: playlists,
            playlistArt: playlistArt
        )
    }

    /// Tab roots take no page title and no Now Playing button: the tab strip replaces
    /// the navigation bar, and CarPlay draws its own Now Playing button in the strip's
    /// top-right while audio plays (only for tab bars of 4 tabs or fewer).
    private func homeTemplate(sections: [CPListSection]) -> CPListTemplate {
        let template = CPListTemplate(title: nil, sections: sections)
        template.tabTitle = "Home"
        template.tabImage = CarPlayArtwork.symbol("house.fill")
        return template
    }

    private func makeHomeSections(cover: (String?, ArtworkKind) -> UIImage) -> [CPListSection] {
        let recents = recentsHomeTiles()
        let added = Array(newestAlbums().prefix(homeStripCap))
        let playlists = homePlaylists()
        return makeHomeSections(
            recents: recents,
            recentsArt: recents.map { cover($0.artworkToken, $0.artworkKind) },
            added: added,
            addedArt: added.map { cover($0.artworkToken, .album) },
            playlists: playlists,
            playlistArt: playlists.map { cover($0.displayArtworkToken, .playlist) }
        )
    }

    private func makeHomeSections(
        recents: [ResolvedRecent],
        recentsArt: [UIImage],
        added: [Album],
        addedArt: [UIImage],
        playlists: [Playlist],
        playlistArt: [UIImage]
    ) -> [CPListSection] {
        var sections: [CPListSection] = []
        if !recents.isEmpty, !recentsArt.isEmpty {
            sections.append(CPListSection(items: [makeRecentsImageRow(tiles: recents, images: recentsArt)]))
        }
        if !added.isEmpty, let row = makeRecentAlbumsImageRow(
            title: "Recently Added",
            albums: added,
            images: addedArt
        ) {
            sections.append(CPListSection(items: [row]))
        }
        if !playlists.isEmpty {
            sections.append(CPListSection(items: [makePlaylistImageRow(playlists: playlists, images: playlistArt)]))
        }
        return sections
    }

    private func recentsHomeTiles() -> [ResolvedRecent] {
        var tiles = resolvedRecents()
        if tiles.isEmpty {
            RecentQueueStore.shared.reload()
            tiles = RecentQueueStore.shared.entries.map { entry in
                ResolvedRecent(
                    kind: entry.kind,
                    compoundRemoteId: entry.compoundRemoteId,
                    title: entry.title,
                    subtitle: entry.subtitle,
                    artworkToken: entry.artworkToken
                )
            }
        }
        if tiles.count < homeGridCap {
            tiles += randomFillTiles(
                excluding: Set(tiles.map(\.id)),
                count: homeGridCap - tiles.count
            )
        }
        return Array(tiles.prefix(homeGridCap))
    }

    private func homePlaylists() -> [Playlist] {
        guard let account = catalogAccount(),
              let playlists = try? catalogRepository().fetchPlaylists(account: account)
        else { return [] }
        return Array(playlists.prefix(homeStripCap))
    }

    func makeRecentsTemplate() -> CPListTemplate {
        let template = CPListTemplate(title: nil, sections: recentsSections())
        template.tabTitle = "Recents"
        template.tabImage = CarPlayArtwork.symbol("clock.fill")
        return template
    }

    func recentsSections() -> [CPListSection] {
        let items = recentsItems()
        let rows = items.isEmpty ? [emptyItem()] : items
        return [CPListSection(items: rows)]
    }

    /// List tab (allowed in the tab bar). iOS 26 audio CarPlay cannot push
    /// `CPSearchTemplate`, so recent terms open a results list instead.
    /// Do not set `assistantCellConfiguration`: CarPlay then requires
    /// `INPlayMediaIntent` (`audio.playAudio`) and kills the app if it's missing.
    func makeSearchTabTemplate() -> CPListTemplate {
        var items: [CPListItem] = []
        let recents = (UserDefaults.standard.array(forKey: "search.recentTerms") as? [String]) ?? []
        for term in recents.prefix(8) {
            let item = CPListItem(
                text: term,
                detailText: "Recent search",
                image: CarPlayArtwork.symbol("clock")
            )
            item.handler = { [weak self] _, completion in
                // Finish the row selection before pushing. Pushing from inside the
                // handler crashes CarPlay on iOS 26.
                completion()
                DispatchQueue.main.async {
                    self?.onSearchQuery?(term)
                }
            }
            items.append(item)
        }

        let template = CPListTemplate(title: nil, sections: [CPListSection(items: items)])
        template.tabTitle = "Search"
        template.tabImage = CarPlayArtwork.symbol("magnifyingglass")
        template.emptyViewTitleVariants = ["Search"]
        template.emptyViewSubtitleVariants = ["Recent searches appear here"]
        return template
    }

    func makeLibraryTemplate() -> CPListTemplate {
        let categories: [(LibraryCategory, String)] = [
            (.playlists, "Playlists"),
            (.artists, "Artists"),
            (.albums, "Albums"),
            (.favorites, "Favorites"),
            (.downloads, "Downloads"),
            (.podcasts, "Podcasts")
        ]
        let search = CPListItem(
            text: "Search",
            detailText: "Songs, albums, artists, playlists",
            image: CarPlayArtwork.symbol("magnifyingglass")
        )
        search.handler = { [weak self] _, completion in
            self?.onOpenSearch?()
            completion()
        }
        let items: [CPListItem] = [search, makeShuffleAllItem()] + categories.map { category, title in
            let item = CPListItem(
                text: title,
                detailText: nil,
                image: CarPlayArtwork.symbol(category.systemImage)
            )
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    self?.pushLibraryCategory(category)
                    completion()
                }
            }
            return item
        }
        let template = CPListTemplate(title: nil, sections: [CPListSection(items: items)])
        template.tabTitle = "Library"
        template.tabImage = CarPlayArtwork.symbol("square.stack.fill")
        return template
    }

    // MARK: - Home

    /// SwiftData is on disk before `VerodromeKit.initialize()` finishes. Home paints
    /// from this so the recents / added / playlist columns exist on the first frame.
    private func catalogRepository() -> LibraryRepository {
        VerodromeKit.shared.repository() ?? LibraryRepository(storage: PersistentStorage.shared)
    }

    private func catalogAccount() -> Account? {
        if let account = try? VerodromeKit.shared.activeAccount() {
            return account
        }
        guard let key = AccountStore.shared.activeAccountKey() else { return nil }
        return try? catalogRepository().fetchAccount(key: key)
    }

    private func makeShuffleAllItem() -> CPListItem {
        let shuffle = CPListItem(
            text: "Shuffle All",
            detailText: "Play the library",
            image: CarPlayArtwork.symbol("shuffle")
        )
        shuffle.handler = { [weak self] _, completion in
            Task { @MainActor in
                await self?.shuffleAll()
                completion()
            }
        }
        return shuffle
    }

    private func playHomeTile(_ tile: ResolvedRecent) {
        switch tile.kind {
        case .album:
            playAlbum(compoundRemoteId: tile.compoundRemoteId)
        case .playlist:
            playPlaylist(compoundRemoteId: tile.compoundRemoteId)
        }
    }

    private func randomFillTiles(excluding: Set<String>, count: Int) -> [ResolvedRecent] {
        guard count > 0 else { return [] }
        var pool: [ResolvedRecent] = []
        var seen = excluding
        func append(_ tile: ResolvedRecent) {
            guard seen.insert(tile.id).inserted else { return }
            pool.append(tile)
        }
        if let account = catalogAccount(),
           let playlists = try? catalogRepository().fetchPlaylists(account: account) {
            for playlist in playlists {
                append(ResolvedRecent(playlist: playlist))
            }
        }
        for album in newestAlbums() {
            append(ResolvedRecent(album: album))
        }
        if pool.count < count {
            for album in allAlbums().prefix(80) {
                append(ResolvedRecent(album: album))
            }
        }
        return Array(pool.shuffled().prefix(count))
    }

    private func makeRecentAlbumsImageRow(
        title: String,
        albums: [Album],
        images: [UIImage]
    ) -> CPListImageRowItem? {
        let slice = Array(albums.prefix(homeStripCap))
        guard !slice.isEmpty else { return nil }
        let ids = slice.map(\.compoundRemoteId)
        return makeImageRow(
            title: title,
            style: .strip,
            images: images,
            titles: slice.map(\.title),
            subtitles: slice.map { $0.artistName ?? $0.artist?.name },
            onSelect: { [weak self] index in
                if ids.indices.contains(index) {
                    self?.playAlbum(compoundRemoteId: ids[index])
                }
            },
            onSeeAll: { [weak self] in self?.pushAlbums(newestOnly: title == "Recently Added") }
        )
    }

    private func makeRecentsImageRow(tiles: [ResolvedRecent], images: [UIImage]) -> CPListImageRowItem {
        makeImageRow(
            title: "Recently Played",
            style: .grid,
            images: images,
            titles: tiles.map(\.title),
            subtitles: tiles.map(\.subtitle),
            onSelect: { [weak self] index in
                if tiles.indices.contains(index) {
                    self?.playHomeTile(tiles[index])
                }
            },
            onSeeAll: { [weak self] in self?.pushRecents() }
        )
    }

    private func makePlaylistImageRow(playlists: [Playlist], images: [UIImage]) -> CPListImageRowItem {
        let ids = playlists.map(\.compoundRemoteId)
        return makeImageRow(
            title: "Playlists",
            style: .strip,
            images: images,
            titles: playlists.map(\.name),
            subtitles: playlists.map { ResolvedRecent.artistLine(from: $0) },
            onSelect: { [weak self] index in
                if ids.indices.contains(index) {
                    self?.playPlaylist(compoundRemoteId: ids[index])
                }
            },
            onSeeAll: { [weak self] in self?.pushPlaylists() }
        )
    }

    private enum HomeRowStyle {
        /// Condensed elements wrapped over multiple lines: a 2-column grid of
        /// image-left / text-right tiles.
        case grid
        /// Row elements on a single line: large covers with the title and subtitle
        /// underneath, scrolling off the trailing edge.
        case strip
    }

    private func cap(for style: HomeRowStyle) -> Int {
        switch style {
        case .grid: homeGridCap
        case .strip: homeStripCap
        }
    }

    private func makeImageRow(
        title: String,
        style: HomeRowStyle,
        images: [UIImage],
        titles: [String],
        subtitles: [String?],
        onSelect: @escaping (Int) -> Void,
        onSeeAll: @escaping () -> Void
    ) -> CPListImageRowItem {
        let capped = min(images.count, cap(for: style))
        let tiles: [(image: UIImage, title: String, subtitle: String?)] = (0..<capped).map { index in
            let rawTitle = titles.indices.contains(index) ? titles[index] : nil
            let rawSubtitle = subtitles.indices.contains(index) ? subtitles[index] : nil
            return (
                images[index],
                Self.truncated(rawTitle) ?? " ",
                Self.truncated(rawSubtitle)
            )
        }
        let row: CPListImageRowItem
        if #available(iOS 26.0, *) {
            switch style {
            case .grid:
                let elements = tiles.map { tile in
                    CPListImageRowItemCondensedElement(
                        image: tile.image,
                        imageShape: .roundedRectangle,
                        title: tile.title,
                        subtitle: tile.subtitle,
                        accessorySymbolName: nil
                    )
                }
                row = CPListImageRowItem(text: title, condensedElements: elements, allowsMultipleLines: true)
            case .strip:
                let elements = tiles.map { tile in
                    CPListImageRowItemRowElement(
                        image: tile.image,
                        title: tile.title,
                        subtitle: tile.subtitle
                    )
                }
                row = CPListImageRowItem(text: title, elements: elements, allowsMultipleLines: false)
            }
        } else if #available(iOS 17.4, *) {
            row = CPListImageRowItem(
                text: title,
                images: tiles.map(\.image),
                imageTitles: tiles.map(\.title)
            )
        } else {
            row = CPListImageRowItem(text: title, images: tiles.map(\.image))
        }
        row.handler = { _, completion in
            onSeeAll()
            completion()
        }
        row.listImageRowHandler = { _, index, completion in
            onSelect(index)
            completion()
        }
        return row
    }

    // MARK: - Library drill-in

    private func pushLibraryCategory(_ category: LibraryCategory) {
        switch category {
        case .playlists: pushPlaylists()
        case .artists: pushArtists()
        case .albums: pushAlbums(newestOnly: false)
        case .favorites: pushFavorites()
        case .downloads: pushDownloads()
        case .podcasts: pushPodcasts()
        default: break
        }
    }

    func pushRecents() {
        pushList(title: "Recents", items: recentsItems())
    }

    func pushPlaylists() {
        guard let account = try? VerodromeKit.shared.activeAccount(),
              let playlists = try? VerodromeKit.shared.repository()?.fetchPlaylists(account: account) else {
            pushEmpty(title: "Playlists")
            return
        }
        let items: [CPListItem] = playlists.prefix(itemCap).map { playlist in
            let item = CPListItem(text: playlist.name, detailText: "\(playlist.songCount) songs")
            let playlistID = playlist.compoundRemoteId
            let token = playlist.displayArtworkToken
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    self?.playPlaylist(compoundRemoteId: playlistID)
                    completion()
                }
            }
            Task { item.setImage(await CarPlayArtwork.load(token: token, kind: .playlist)) }
            return item
        }
        pushList(title: "Playlists", items: Array(items))
    }

    func pushAlbums(newestOnly: Bool) {
        let albums = newestOnly ? newestAlbums() : allAlbums()
        guard !albums.isEmpty else {
            pushEmpty(title: newestOnly ? "Recently Added" : "Albums")
            return
        }
        pushList(title: newestOnly ? "Recently Added" : "Albums", items: albumItems(albums))
    }

    func pushArtists() {
        guard let account = try? VerodromeKit.shared.activeAccount(),
              let artists = try? VerodromeKit.shared.repository()?.fetchArtists(account: account) else {
            pushEmpty(title: "Artists")
            return
        }
        let items: [CPListItem] = artists.prefix(itemCap).map { artist in
            let item = CPListItem(text: artist.name, detailText: "\(artist.albumCount) albums")
            let artistID = artist.compoundRemoteId
            let token = artist.artworkToken
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    self?.playArtist(compoundRemoteId: artistID)
                    completion()
                }
            }
            Task { item.setImage(await CarPlayArtwork.load(token: token, kind: .artist)) }
            return item
        }
        pushList(title: "Artists", items: Array(items))
    }

    func pushFavorites() {
        guard let account = try? VerodromeKit.shared.activeAccount(),
              let songs = try? VerodromeKit.shared.repository()?.fetchSongs(account: account, favoritesOnly: true) else {
            pushEmpty(title: "Favorites")
            return
        }
        pushList(title: "Favorites", items: songItems(songs, among: songs))
    }

    func pushDownloads() {
        guard let account = try? VerodromeKit.shared.activeAccount(),
              let songs = try? VerodromeKit.shared.repository()?.fetchSongs(account: account, cachedOnly: false) else {
            pushEmpty(title: "Downloads")
            return
        }
        let downloads = songs.filter(\.isDownloadedLocally)
        pushList(title: "Downloads", items: songItems(downloads, among: downloads))
    }

    func pushPodcasts() {
        guard let account = try? VerodromeKit.shared.activeAccount(),
              let podcasts = try? VerodromeKit.shared.repository()?.fetchPodcasts(account: account) else {
            pushEmpty(title: "Podcasts")
            return
        }
        let items: [CPListItem] = podcasts.prefix(itemCap).map { podcast in
            let item = CPListItem(text: podcast.title, detailText: podcast.author)
            let podcastID = podcast.compoundRemoteId
            let token = podcast.artworkToken
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    self?.playPodcast(compoundRemoteId: podcastID)
                    completion()
                }
            }
            Task { item.setImage(await CarPlayArtwork.load(token: token, kind: .podcast)) }
            return item
        }
        pushList(title: "Podcasts", items: Array(items))
    }

    func pushQueue() {
        let items = makeQueueItems()
        let template = listTemplate(
            title: "Queue",
            items: items.isEmpty ? [emptyItem()] : items,
            showsNowPlayingButton: false
        )
        queueTemplate = template
        guard let interfaceController else {
            CarPlayLog.error("pushList(Queue) dropped: no interface controller")
            return
        }
        let depth = interfaceController.templates.count
        interfaceController.pushTemplate(template, animated: true) { success, error in
            guard !success else { return }
            CarPlayLog.error(
                "pushList(Queue) failed at depth \(depth): \(error?.localizedDescription ?? "unknown error")"
            )
        }
    }

    func refreshQueueIfPresented() {
        guard let queueTemplate,
              let interfaceController,
              interfaceController.templates.contains(where: { $0 === queueTemplate })
        else { return }
        let items = makeQueueItems()
        queueTemplate.updateSections([CPListSection(items: items.isEmpty ? [emptyItem()] : items)])
    }

    /// Non-smart playlists for the playing song. Membership is the trailing circle.
    func pushPlaylistMembership() {
        if let playlistMembershipTemplate,
           let interfaceController,
           interfaceController.templates.contains(where: { $0 === playlistMembershipTemplate }) {
            refreshPlaylistMembershipIfPresented()
            return
        }
        let items = makePlaylistMembershipItems()
        let template = listTemplate(
            title: "Playlists",
            items: items,
            showsNowPlayingButton: false
        )
        template.emptyViewTitleVariants = ["Playlists"]
        template.emptyViewSubtitleVariants = ["No playlists you can edit"]
        playlistMembershipTemplate = template
        guard let interfaceController else {
            CarPlayLog.error("pushList(Playlists) dropped: no interface controller")
            return
        }
        let depth = interfaceController.templates.count
        interfaceController.pushTemplate(template, animated: true) { success, error in
            guard !success else { return }
            CarPlayLog.error(
                "pushList(Playlists) failed at depth \(depth): \(error?.localizedDescription ?? "unknown error")"
            )
        }
    }

    func refreshPlaylistMembershipIfPresented() {
        guard let playlistMembershipTemplate,
              let interfaceController,
              interfaceController.templates.contains(where: { $0 === playlistMembershipTemplate })
        else { return }
        playlistMembershipTemplate.updateSections([
            CPListSection(items: makePlaylistMembershipItems())
        ])
    }

    private func makePlaylistMembershipItems() -> [CPListItem] {
        guard let songId = currentSongRemoteId() else {
            return [emptyItem()]
        }
        let playlists = editablePlaylists()
        guard !playlists.isEmpty else {
            let item = CPListItem(text: "No playlists you can edit", detailText: nil)
            item.handler = { _, completion in completion() }
            return [item]
        }
        let membership = PlaylistMembershipIndex.shared
        return Array(playlists.prefix(CPListTemplate.maximumItemCount)).map { playlist in
            let isMember = membership.isMember(songId: songId, playlistId: playlist.remoteId)
            let name = playlist.name
            let count = playlist.songCount
            let playlistID = playlist.compoundRemoteId
            let item = CPListItem(text: name, detailText: "\(count) songs")
            item.setAccessoryImage(CarPlayArtwork.playlistMembershipAccessory(isMember: isMember))
            item.handler = { [weak self] _, completion in
                completion()
                DispatchQueue.main.async {
                    Task { await self?.togglePlaylistMembership(compoundRemoteId: playlistID, songId: songId) }
                }
            }
            return item
        }
    }

    private func editablePlaylists() -> [Playlist] {
        guard let account = catalogAccount() else { return [] }
        let rejected = LibraryActions.shared.playlistsRejectedByServer
        let playlists = (try? catalogRepository().fetchPlaylists(account: account)) ?? []
        return playlists.filter {
            $0.isEditable && !$0.isSmart && !rejected.contains($0.remoteId)
        }
    }

    private func currentSongRemoteId() -> String? {
        guard let item = VerodromeKit.shared.player?.currentItem, item.kind == .song else { return nil }
        return item.playableId
    }

    private func togglePlaylistMembership(compoundRemoteId: String, songId: String) async {
        guard !playlistToggleInFlight.contains(compoundRemoteId) else { return }
        guard let account = catalogAccount(),
              let playlist = try? catalogRepository().fetchPlaylist(compoundRemoteId: compoundRemoteId),
              let song = try? catalogRepository().resolveSong(remoteId: songId, account: account)
        else { return }

        playlistToggleInFlight.insert(compoundRemoteId)
        defer { playlistToggleInFlight.remove(compoundRemoteId) }

        let membership = PlaylistMembershipIndex.shared
        let playlistRemoteId = playlist.remoteId
        let isMember = membership.isMember(songId: songId, playlistId: playlistRemoteId)
        membership.setMembership(songId: songId, playlistId: playlistRemoteId, isMember: !isMember)
        refreshPlaylistMembershipIfPresented()
        do {
            if isMember {
                try await LibraryActions.shared.removeSong(song, from: playlist)
            } else {
                try await LibraryActions.shared.addSongs([song], to: playlist)
            }
        } catch {
            membership.setMembership(songId: songId, playlistId: playlistRemoteId, isMember: isMember)
            _ = LibraryActions.shared.notePlaylistEditRejected(playlist, error: error)
            refreshPlaylistMembershipIfPresented()
        }
    }

    private func makeQueueItems() -> [CPListItem] {
        guard let player = VerodromeKit.shared.player, !player.queue.isEmpty else { return [] }
        let current = player.currentIndex
        return player.queue.prefix(itemCap).enumerated().map { index, queueItem in
            let item = CPListItem(text: queueItem.title, detailText: queueItem.artistName)
            item.isPlaying = index == current
            item.handler = { _, completion in
                Task { @MainActor in
                    VerodromeKit.shared.player?.jump(to: index)
                    completion()
                }
            }
            return item
        }
    }

    func pushPlayingAlbumOrPlaylist() {
        if case .playlist(let name) = VerodromeKit.shared.player?.queueOrigin,
           let account = try? VerodromeKit.shared.activeAccount(),
           let playlists = try? VerodromeKit.shared.repository()?.fetchPlaylists(account: account),
           let playlist = playlists.first(where: { $0.name == name }) {
            let songs = playlist.items.sorted { $0.order < $1.order }.compactMap(\.song)
            pushList(title: playlist.name, items: songItems(songs, among: songs))
            return
        }
        guard let song = currentSong(), let album = song.album else { return }
        let songs = album.songs.sorted { ($0.disc ?? 0, $0.track ?? 0) < ($1.disc ?? 0, $1.track ?? 0) }
        pushList(title: album.title, items: songItems(songs, among: songs))
    }

    private func currentSong() -> Song? {
        guard let playableId = VerodromeKit.shared.player?.currentItem?.playableId,
              VerodromeKit.shared.player?.currentItem?.kind == .song,
              let account = try? VerodromeKit.shared.activeAccount(),
              let repo = VerodromeKit.shared.repository() else { return nil }
        return try? repo.resolveSong(remoteId: playableId, account: account)
    }

    // MARK: - Playback

    func playPlaylist(compoundRemoteId: String) {
        guard let playlist = try? VerodromeKit.shared.repository()?.fetchPlaylist(compoundRemoteId: compoundRemoteId) else {
            return
        }
        let songs = playlist.items.sorted { $0.order < $1.order }.compactMap(\.song)
        RecentQueueStore.shared.record(playlist: playlist)
        play(songs.map(QueueItem.from), shuffle: .off, origin: .playlist(playlist.name))
    }

    func playAlbum(compoundRemoteId: String) {
        guard let album = try? VerodromeKit.shared.repository()?.fetchAlbum(compoundRemoteId: compoundRemoteId) else {
            return
        }
        let songs = album.songs.sorted { ($0.track ?? 0) < ($1.track ?? 0) }
        RecentQueueStore.shared.record(album: album)
        play(
            songs.map { QueueItem.from($0, albumArtworkId: album.artworkToken) },
            shuffle: .off,
            origin: .album(album.title)
        )
    }

    func playArtist(compoundRemoteId: String) {
        guard let account = try? VerodromeKit.shared.activeAccount(),
              let songs = try? VerodromeKit.shared.repository()?.fetchSongs(account: account) else { return }
        let artistSongs = songs.filter {
            $0.artist?.compoundRemoteId == compoundRemoteId
                || $0.album?.artist?.compoundRemoteId == compoundRemoteId
        }
        let name = artistSongs.first?.artistName
            ?? artistSongs.first?.album?.artist?.name
        play(
            artistSongs.map(QueueItem.from),
            origin: name.map { .artist($0) }
        )
    }

    func playSong(compoundRemoteId: String, among songs: [Song]) {
        let items = songs.map(QueueItem.from)
        let index = songs.firstIndex(where: { $0.compoundRemoteId == compoundRemoteId }) ?? 0
        let seed = items.indices.contains(index) ? items[index] : items.first
        play(items, startAt: index, origin: seed.map { .song($0.title) })
    }

    /// Songs matching `query`, capped at the list template limit. Titles and artist
    /// names are copied off the models so the list does not fault SwiftData later.
    func songSearchItems(query: String) -> [CPListItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 1, let account = catalogAccount() else { return [] }
        let songs = (try? catalogRepository().searchSongs(account: account, query: query)) ?? []
        let slice = Array(songs.prefix(CPListTemplate.maximumItemCount))
        let queue = slice.map(QueueItem.from)
        return slice.enumerated().map { index, song in
            let title = song.title
            let artist = song.artistName
            let item = CPListItem(text: title, detailText: artist)
            item.handler = { [weak self] _, completion in
                completion()
                Task { @MainActor in
                    self?.play(queue, startAt: index, origin: .song(title))
                }
            }
            return item
        }
    }

    func playPodcast(compoundRemoteId: String) {
        guard let account = try? VerodromeKit.shared.activeAccount(),
              let podcast = try? VerodromeKit.shared.repository()?.fetchPodcast(compoundRemoteId: compoundRemoteId),
              let episodes = try? VerodromeKit.shared.repository()?.fetchPodcastEpisodes(account: account, podcast: podcast)
        else { return }
        let ordered = episodes.sorted {
            ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast)
        }
        play(ordered.map(QueueItem.from))
    }

    func play(_ items: [QueueItem], startAt index: Int = 0, shuffle: ShuffleMode? = nil, origin: QueueOrigin? = nil) {
        guard !items.isEmpty else { return }
        // Show Now Playing up front. `player.play` only returns once the first item is
        // buffered, so awaiting it leaves the tap looking like it did nothing on a cold
        // cache — and leaves Now Playing unreachable entirely if the load stalls.
        // Seed the info center from the tapped item so the template has a title, artist
        // and duration to draw before the player has resolved anything; the real payload
        // (and artwork) lands as soon as playback starts.
        let seed = items.indices.contains(index) ? items[index] : items[0]
        VerodromeKit.shared.nowPlayingHandler.update(
            item: seed,
            isPlaying: true,
            elapsed: 0,
            duration: seed.duration
        )
        onDidStartPlayback?()
        Task {
            await VerodromeKit.shared.player?.play(
                items: items,
                startAt: index,
                shuffle: shuffle,
                origin: origin
            )
        }
    }

    func shuffleAll() async {
        if let provider = VerodromeKit.shared.activeLibrarySyncer as? (any RandomSongProviding) {
            let session = ShuffleAllSession(
                provider: provider,
                resolver: LocalLibrarySongResolver(
                    accountKey: AccountStore.shared.activeAccountKey()?.storageKey
                ),
                ingestor: VerodromeKit.shared.activeLibraryIngester
            )
            if let items = try? await session.next(count: nil), !items.isEmpty {
                play(items, startAt: 0, shuffle: .off)
                return
            }
        }
        guard let account = try? VerodromeKit.shared.activeAccount(),
              let songs = try? VerodromeKit.shared.repository()?.fetchSongs(account: account),
              !songs.isEmpty else { return }
        play(Array(songs.shuffled().prefix(itemCap)).map(QueueItem.from), shuffle: .off)
    }

    // MARK: - Fetch helpers

    private func newestAlbums() -> [Album] {
        (try? catalogRepository().fetchAlbums(newestIndexPositive: true)) ?? []
    }

    private func allAlbums() -> [Album] {
        guard let account = catalogAccount() else { return [] }
        return (try? catalogRepository().fetchAlbums(account: account)) ?? []
    }

    private func recentsItems() -> [CPListItem] {
        resolvedRecents().map { item in
            let row = CPListItem(text: item.title, detailText: item.subtitle)
            let id = item.compoundRemoteId
            let token = item.artworkToken
            let kind = item.kind
            row.handler = { [weak self] _, completion in
                Task { @MainActor in
                    switch kind {
                    case .album:
                        self?.playAlbum(compoundRemoteId: id)
                    case .playlist:
                        self?.playPlaylist(compoundRemoteId: id)
                    }
                    completion()
                }
            }
            Task { row.setImage(await CarPlayArtwork.load(token: token, kind: item.artworkKind)) }
            return row
        }
    }

    private func resolvedRecents() -> [ResolvedRecent] {
        RecentQueueStore.shared.reload()
        let repo = catalogRepository()
        var items: [ResolvedRecent] = []
        items.reserveCapacity(min(RecentQueueStore.limit, RecentQueueStore.shared.entries.count))
        for entry in RecentQueueStore.shared.entries {
            switch entry.kind {
            case .album:
                guard let album = try? repo.fetchAlbum(compoundRemoteId: entry.compoundRemoteId) else {
                    continue
                }
                items.append(ResolvedRecent(album: album))
            case .playlist:
                guard let playlist = try? repo.fetchPlaylist(compoundRemoteId: entry.compoundRemoteId) else {
                    continue
                }
                items.append(ResolvedRecent(playlist: playlist))
            }
        }
        return items
    }

    private func albumItems(_ albums: [Album]) -> [CPListItem] {
        albums.prefix(itemCap).map { album in
            let item = CPListItem(
                text: album.title,
                detailText: album.artistName ?? album.artist?.name
            )
            let albumID = album.compoundRemoteId
            let token = album.artworkToken
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    self?.playAlbum(compoundRemoteId: albumID)
                    completion()
                }
            }
            Task { item.setImage(await CarPlayArtwork.load(token: token, kind: .album)) }
            return item
        }
    }

    private func songItems(_ songs: [Song], among all: [Song]) -> [CPListItem] {
        guard !songs.isEmpty else {
            return [emptyItem()]
        }
        return songs.prefix(itemCap).map { song in
            let item = CPListItem(
                text: song.title,
                detailText: song.artistName ?? song.artist?.name
            )
            let songID = song.compoundRemoteId
            let token = song.displayArtworkToken
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    self?.playSong(compoundRemoteId: songID, among: all)
                    completion()
                }
            }
            Task { item.setImage(await CarPlayArtwork.load(token: token, kind: .album)) }
            return item
        }
    }

    // MARK: - Lists

    private func listTemplate(title: String, items: [CPListItem], showsNowPlayingButton: Bool = true) -> CPListTemplate {
        let rows = items.isEmpty ? [emptyItem()] : items
        let template = CPListTemplate(title: title, sections: [CPListSection(items: rows)])
        // Queue is pushed on top of Now Playing, so the back button already returns
        // to the player. A trailing Now Playing control would be a second exit.
        guard showsNowPlayingButton else { return template }
        return withNowPlayingButton(template)
    }

    private static func truncated(_ text: String?, limit: Int = 24) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)) + "…"
    }

    /// Only pushed templates get this: they own a real navigation bar. Tab roots are
    /// drawn under the tab strip; the Now Playing control there is drawn by CarPlay
    /// itself while audio is playing (≤4 tabs).
    @discardableResult
    private func withNowPlayingButton(_ template: CPListTemplate) -> CPListTemplate {
        let button = CPBarButton(image: CarPlayArtwork.barSymbol("waveform")) { [weak self] _ in
            self?.onOpenNowPlaying?()
        }
        button.buttonStyle = .rounded
        template.trailingNavigationBarButtons = [button]
        return template
    }

    func pushList(title: String, items: [CPListItem], showsNowPlayingButton: Bool = true) {
        let template = listTemplate(title: title, items: items, showsNowPlayingButton: showsNowPlayingButton)
        guard let interfaceController else {
            CarPlayLog.error("pushList(\(title)) dropped: no interface controller")
            return
        }
        let depth = interfaceController.templates.count
        interfaceController.pushTemplate(template, animated: true) { success, error in
            guard !success else { return }
            CarPlayLog.error(
                "pushList(\(title)) failed at depth \(depth): \(error?.localizedDescription ?? "unknown error")"
            )
        }
    }

    private func pushEmpty(title: String) {
        pushList(title: title, items: [emptyItem()])
    }

    private func emptyItem() -> CPListItem {
        let item = CPListItem(text: "Nothing here yet", detailText: nil)
        item.handler = { _, completion in completion() }
        return item
    }
}

private struct ResolvedRecent {
    let kind: RecentQueueKind
    let compoundRemoteId: String
    let title: String
    let subtitle: String?
    let artworkToken: String?

    var id: String { "\(kind.rawValue)|\(compoundRemoteId)" }

    var artworkKind: ArtworkKind {
        switch kind {
        case .album: .album
        case .playlist: .playlist
        }
    }

    init(
        kind: RecentQueueKind,
        compoundRemoteId: String,
        title: String,
        subtitle: String?,
        artworkToken: String?
    ) {
        self.kind = kind
        self.compoundRemoteId = compoundRemoteId
        self.title = title
        self.subtitle = subtitle
        self.artworkToken = artworkToken
    }

    init(album: Album) {
        self.init(
            kind: .album,
            compoundRemoteId: album.compoundRemoteId,
            title: album.title,
            subtitle: album.artistName ?? album.artist?.name,
            artworkToken: album.artworkToken
        )
    }

    init(playlist: Playlist) {
        self.init(
            kind: .playlist,
            compoundRemoteId: playlist.compoundRemoteId,
            title: playlist.name,
            subtitle: Self.artistLine(from: playlist),
            artworkToken: playlist.displayArtworkToken
        )
    }

    static func artistLine(from playlist: Playlist) -> String? {
        var names: [String] = []
        var seen = Set<String>()
        for item in playlist.items.sorted(by: { $0.order < $1.order }) {
            let name = (item.song?.artistName ?? item.song?.artist?.name)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { continue }
            let key = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(key).inserted else { continue }
            names.append(name)
            if names.count == 3 { break }
        }
        guard !names.isEmpty else { return nil }
        return names.joined(separator: ", ")
    }
}
