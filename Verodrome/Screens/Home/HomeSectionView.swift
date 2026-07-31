import SwiftUI
import VerodromeKit

struct HomeSectionView: View {
    let section: HomeSection
    let tiles: [HomeTileItem]
    var onAlbumPlay: (_ compoundId: String, _ remoteId: String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(section.title)
                    .font(.title2.bold())
                Spacer()
                if !tiles.isEmpty {
                    NavigationLink("See All") { destinationList }
                        .font(.subheadline)
                }
            }
            .padding(.horizontal)

            if tiles.isEmpty {
                Text(emptyMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    // Eager HStack: sections are capped at ~20 tiles. LazyHStack was
                    // recycling tiles during vertical Home scroll and re-running artwork tasks.
                    HStack(spacing: 16) {
                        ForEach(tiles) { tile in
                            tileLink(tile)
                                .onAppear {
                                    HomeScrollProbe.tileAppeared(section: section, tileId: tile.id)
                                }
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        .onAppear {
            HomeScrollProbe.sectionAppeared(section: section, tileCount: tiles.count)
        }
        .onDisappear {
            HomeScrollProbe.sectionDisappeared(section: section)
        }
    }

    @ViewBuilder
    private func tileLink(_ tile: HomeTileItem) -> some View {
        let cell = AlbumGridCell(
            title: tile.title,
            subtitle: tile.subtitle,
            artworkURL: tile.artworkToken,
            symbol: tile.symbol
        )
        .frame(width: 148)

        switch section {
        case .recentlyPlayed, .recentlyAdded, .favorites, .randomAlbums:
            NavigationLink {
                AlbumDetailView(albumID: tile.id)
            } label: {
                cell
            }
            .buttonStyle(.plain)
            .contextMenu {
                if let compound = tile.albumCompoundId, let remote = tile.albumRemoteId {
                    Button("Play") { onAlbumPlay(compound, remote) }
                }
            }
        case .playlists:
            NavigationLink {
                PlaylistDetailView(playlistID: tile.id)
            } label: { cell }
            .buttonStyle(.plain)
        case .podcasts:
            NavigationLink {
                PodcastDetailView(podcastID: tile.id)
            } label: { cell }
            .buttonStyle(.plain)
        case .radios:
            cell
        case .genres:
            NavigationLink {
                GenreDetailView(genreID: tile.id)
            } label: { cell }
            .buttonStyle(.plain)
        }
    }

    private var emptyMessage: String {
        switch section {
        case .recentlyPlayed: "Play some music to see recently played albums."
        case .recentlyAdded: "Newest albums will appear after sync."
        case .favorites: "Star albums on your server to see them here."
        case .playlists: "No playlists yet."
        case .podcasts: "No podcasts yet."
        case .radios: "No radio stations yet."
        case .genres: "No genres yet."
        case .randomAlbums: "Albums will appear after your library syncs."
        }
    }

    @ViewBuilder
    private var destinationList: some View {
        switch section {
        case .favorites: FavoritesView()
        case .playlists: PlaylistsView()
        case .podcasts: PodcastsView()
        case .radios: RadiosView()
        case .genres: GenresView()
        case .recentlyPlayed, .recentlyAdded, .randomAlbums:
            AlbumsView()
        }
    }
}

/// Batches Home scroll recycling events so we can correlate lag with section/tile churn.
enum HomeScrollProbe {
    private static let lock = NSLock()
    private static var sectionAppear = 0
    private static var sectionDisappear = 0
    private static var tileAppear = 0
    private static var lastSection = ""
    private static var flushScheduled = false
    private static var windowStart = CFAbsoluteTimeGetCurrent()

    static func sectionAppeared(section: HomeSection, tileCount: Int) {
        PerfTrace.event(
            "Home.section.appear",
            details: "\(section.rawValue) tiles=\(tileCount)"
        )
        lock.lock()
        sectionAppear += 1
        lastSection = section.rawValue
        scheduleFlushLocked()
        lock.unlock()
    }

    static func sectionDisappeared(section: HomeSection) {
        PerfTrace.event("Home.section.disappear", details: section.rawValue)
        lock.lock()
        sectionDisappear += 1
        lastSection = section.rawValue
        scheduleFlushLocked()
        lock.unlock()
    }

    static func tileAppeared(section: HomeSection, tileId: String) {
        lock.lock()
        tileAppear += 1
        lastSection = section.rawValue
        scheduleFlushLocked()
        lock.unlock()
        _ = tileId
    }

    private static func scheduleFlushLocked() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            flush()
        }
    }

    private static func flush() {
        lock.lock()
        let sa = sectionAppear
        let sd = sectionDisappear
        let ta = tileAppear
        let last = lastSection
        let elapsed = Int(((CFAbsoluteTimeGetCurrent() - windowStart) * 1000).rounded())
        sectionAppear = 0
        sectionDisappear = 0
        tileAppear = 0
        flushScheduled = false
        windowStart = CFAbsoluteTimeGetCurrent()
        lock.unlock()
        guard sa + sd + ta > 0 else { return }
        PerfTrace.event(
            "Home.scroll.window",
            details: "sectionAppear=\(sa) sectionDisappear=\(sd) tileAppear=\(ta) last=\(last) window=\(elapsed)ms"
        )
    }
}
