import SwiftUI
import UIKit
import VerodromeKit

/// Identifies one tile within one carousel section.
///
/// A diffable data source requires item identifiers to be unique across the *whole*
/// snapshot, and the same album legitimately appears in more than one carousel (Recently
/// Added and Random Albums, say). Pairing the section with the tile keeps identifiers
/// unique while staying stable across reloads, so unchanged tiles are left alone instead
/// of being torn down and rebuilt.
private struct HomeEntry: Hashable {
    let section: HomeSection
    let tile: HomeTileItem
}

private enum HomeBoardSection: Hashable {
    case stats
    case carousel(HomeSection)
}

private enum HomeBoardItem: Hashable {
    case stats
    case tile(HomeEntry)
}

struct HomeStatsBarState: Equatable {
    var albumCount: Int
    var songCount: Int
    var isCountProvisional: Bool
    var isShuffleBusy: Bool
    var isShuffleDisabled: Bool
}

/// Library sync status pinned to the top of Home. Nil hides the bar.
struct HomeSyncStatus: Equatable {
    var progressText: String
    var fraction: Double?
}

/// Home's carousels, rendered by a single `UICollectionView`.
///
/// Every section is one orthogonally-scrolling row of the same collection view, which is
/// how Amperfy's `HomeVC` does it. The whole screen therefore has one scroll view and one
/// layout system, and only the handful of tiles actually on screen exist as views.
struct HomeCollectionView: UIViewControllerRepresentable, Equatable {
    let sections: [HomeSection]
    let tiles: [HomeSection: [HomeTileItem]]
    let stats: HomeStatsBarState
    var syncStatus: HomeSyncStatus?
    var onSelectTile: (HomeSection, HomeTileItem) -> Void
    var onPlayAlbum: (_ compoundId: String, _ remoteId: String) -> Void
    var onSeeAll: (HomeSection) -> Void
    var onShuffle: () -> Void
    var onRefresh: @MainActor () async -> Void

    static func == (lhs: HomeCollectionView, rhs: HomeCollectionView) -> Bool {
        lhs.sections == rhs.sections
            && lhs.tiles == rhs.tiles
            && lhs.stats == rhs.stats
            && lhs.syncStatus == rhs.syncStatus
    }

    func makeUIViewController(context: Context) -> HomeCollectionViewController {
        let controller = HomeCollectionViewController()
        controller.onSelectTile = onSelectTile
        controller.onPlayAlbum = onPlayAlbum
        controller.onSeeAll = onSeeAll
        controller.onShuffle = onShuffle
        controller.onRefresh = onRefresh
        controller.setSyncStatus(syncStatus)
        return controller
    }

    func updateUIViewController(_ controller: HomeCollectionViewController, context: Context) {
        controller.onSelectTile = onSelectTile
        controller.onPlayAlbum = onPlayAlbum
        controller.onSeeAll = onSeeAll
        controller.onShuffle = onShuffle
        controller.onRefresh = onRefresh
        controller.apply(sections: sections, tiles: tiles, stats: stats)
        controller.setSyncStatus(syncStatus)
    }
}

@MainActor
final class HomeCollectionViewController: UIViewController, UICollectionViewDelegate {
    static let tileWidth: CGFloat = 160

    var onSelectTile: ((HomeSection, HomeTileItem) -> Void)?
    var onPlayAlbum: ((_ compoundId: String, _ remoteId: String) -> Void)?
    var onSeeAll: ((HomeSection) -> Void)?
    var onShuffle: (() -> Void)?
    var onRefresh: (@MainActor () async -> Void)?

    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<HomeBoardSection, HomeBoardItem>!
    private var sections: [HomeSection] = []
    private var tiles: [HomeSection: [HomeTileItem]] = [:]
    private var stats = HomeStatsBarState(
        albumCount: 0,
        songCount: 0,
        isCountProvisional: true,
        isShuffleBusy: false,
        isShuffleDisabled: true
    )
    private var isRefreshing = false
    private var pendingApply: PendingHomeApply?
    private var didNormalizeInitialOffset = false
    /// Overlay spinner hosted on the navigation bar so it sits on the large title
    /// instead of opening a gap above the stats bar. `UIRefreshControl` can't live
    /// in the collection view — orthogonal layout passes reset its transform.
    private let refreshIndicator = UIActivityIndicatorView(style: .medium)
    private var refreshIndicatorConstraints: [NSLayoutConstraint] = []
    private var hasStartedPullSpin = false
    private var isDismissingRefresh = false
    private let refreshPullThreshold: CGFloat = 64
    /// Pinned under the navigation bar. The collection view is edge-pinned and owns
    /// the large-title inset itself, so this bar adds its height to `contentInset`
    /// instead of sitting in a SwiftUI safe-area inset the scroll view never sees.
    private var syncBannerHost: UIHostingController<LibrarySyncHomeBanner>?
    private var displayedSyncStatus: HomeSyncStatus?
    private var isUpdatingSyncBannerInset = false

    private struct PendingHomeApply {
        let visibleSections: [HomeSection]
        let tiles: [HomeSection: [HomeTileItem]]
        let stats: HomeStatsBarState
        let needsSectionApply: Bool
        let needsStatsApply: Bool
    }

    init() {
        // Compositional layout is installed in `viewDidLoad` once the data source exists.
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.delegate = self
        collectionView.backgroundColor = .systemBackground
        // Match library lists: plain UIViewController + edge-pinned scroll view lets the
        // navigation large title own inset adjustment instead of UICollectionViewController
        // fighting it on the first scroll.
        collectionView.contentInsetAdjustmentBehavior = .automatic
        collectionView.alwaysBounceVertical = true
        collectionView.register(
            HomeStatsCell.self,
            forCellWithReuseIdentifier: HomeStatsCell.reuseID
        )
        collectionView.register(
            HomeTileCell.self,
            forCellWithReuseIdentifier: HomeTileCell.reuseID
        )
        collectionView.register(
            HomeSectionHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: HomeSectionHeaderView.reuseID
        )

        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        refreshIndicator.translatesAutoresizingMaskIntoConstraints = false
        refreshIndicator.hidesWhenStopped = false
        refreshIndicator.alpha = 0
        refreshIndicator.isUserInteractionEnabled = false
        refreshIndicator.color = .secondaryLabel
        view.clipsToBounds = false

        // Tile height is absolute, so Dynamic Type changes have to re-run the section
        // provider rather than being picked up by self-sizing.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (controller: Self, _: UITraitCollection) in
            controller.collectionView.collectionViewLayout.invalidateLayout()
        }

        configureDataSource()
        collectionView.setCollectionViewLayout(createLayout(), animated: false)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(retryVisibleArtwork),
            name: .backendAuthenticated,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        refreshIndicator.removeFromSuperview()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        attachRefreshIndicatorToTitle()
        updateSyncBannerInset()
        guard !didNormalizeInitialOffset, !isRefreshing else { return }
        didNormalizeInitialOffset = true
        normalizeScrollPosition(animated: false)
    }

    func setSyncStatus(_ status: HomeSyncStatus?) {
        guard status != displayedSyncStatus else { return }
        let textChanged = displayedSyncStatus?.progressText != status?.progressText
        let visibilityChanged = (displayedSyncStatus != nil) != (status != nil)
        displayedSyncStatus = status
        let host = ensureSyncBannerHost()
        if let status {
            host.rootView = LibrarySyncHomeBanner(
                progressText: status.progressText,
                fraction: status.fraction
            )
            host.view.isHidden = false
        } else {
            host.view.isHidden = true
        }
        // Percent ticks only refresh the bar. Relayout when the caption can change height.
        guard visibilityChanged || textChanged else { return }
        host.view.invalidateIntrinsicContentSize()
        view.layoutIfNeeded()
        updateSyncBannerInset()
    }

    private func ensureSyncBannerHost() -> UIHostingController<LibrarySyncHomeBanner> {
        if let syncBannerHost { return syncBannerHost }
        let host = UIHostingController(
            rootView: LibrarySyncHomeBanner(progressText: "", fraction: nil)
        )
        host.safeAreaRegions = []
        host.sizingOptions = .intrinsicContentSize
        host.view.backgroundColor = .systemBackground
        host.view.isHidden = true
        // Let drags that start on the bar scroll the board underneath.
        host.view.isUserInteractionEnabled = false
        host.view.translatesAutoresizingMaskIntoConstraints = false
        syncBannerHost = host
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
        return host
    }

    private func updateSyncBannerInset() {
        guard !isUpdatingSyncBannerInset else { return }
        let height = syncBannerHeight()
        guard abs(collectionView.contentInset.top - height) > 0.5 else { return }
        isUpdatingSyncBannerInset = true
        defer { isUpdatingSyncBannerInset = false }
        let wasAtTop = collectionView.contentOffset.y <= -collectionView.adjustedContentInset.top + 1
        collectionView.contentInset.top = height
        guard wasAtTop else { return }
        collectionView.setContentOffset(
            CGPoint(x: 0, y: -collectionView.adjustedContentInset.top),
            animated: false
        )
    }

    private func syncBannerHeight() -> CGFloat {
        guard let host = syncBannerHost, !host.view.isHidden else { return 0 }
        if host.view.bounds.height > 0.5, host.view.bounds.width > 0.5 {
            return host.view.bounds.height
        }
        guard view.bounds.width > 0.5 else { return 0 }
        return host.sizeThatFits(
            in: CGSize(width: view.bounds.width, height: UIView.layoutFittingExpandedSize.height)
        ).height
    }

    /// Pins the spinner to the large-title band of the navigation bar so it paints
    /// over the title rather than between the title and the stats bar.
    private func attachRefreshIndicatorToTitle() {
        let host: UIView = enclosingNavigationBar() ?? view
        if refreshIndicator.superview !== host {
            NSLayoutConstraint.deactivate(refreshIndicatorConstraints)
            refreshIndicatorConstraints = []
            refreshIndicator.removeFromSuperview()
            host.addSubview(refreshIndicator)
        }
        guard refreshIndicatorConstraints.isEmpty else { return }

        if host is UINavigationBar {
            refreshIndicatorConstraints = [
                refreshIndicator.centerXAnchor.constraint(equalTo: host.centerXAnchor),
                refreshIndicator.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -40)
            ]
        } else {
            refreshIndicatorConstraints = [
                refreshIndicator.centerXAnchor.constraint(equalTo: host.centerXAnchor),
                refreshIndicator.centerYAnchor.constraint(
                    equalTo: host.safeAreaLayoutGuide.topAnchor,
                    constant: -36
                )
            ]
        }
        NSLayoutConstraint.activate(refreshIndicatorConstraints)
    }

    private func enclosingNavigationBar() -> UINavigationBar? {
        var controller: UIViewController? = self
        while let current = controller {
            if let bar = current.navigationController?.navigationBar { return bar }
            if let bar = (current as? UINavigationController)?.navigationBar { return bar }
            controller = current.parent
        }
        var responder: UIResponder? = self
        while let current = responder {
            if let nav = current as? UINavigationController { return nav.navigationBar }
            responder = current.next
        }
        return nil
    }

    /// Visible tiles that raced ahead of cold-launch login stay on placeholders otherwise.
    @objc private func retryVisibleArtwork() {
        for case let cell as HomeTileCell in collectionView.visibleCells {
            cell.loadArtworkIfNeeded()
        }
    }

    private func createLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            guard let self else { return nil }
            let ids = self.dataSource.snapshot().sectionIdentifiers
            guard sectionIndex < ids.count else { return nil }
            switch ids[sectionIndex] {
            case .stats:
                return Self.makeStatsSection(environment: environment)
            case .carousel:
                return Self.makeCarouselSection(environment: environment)
            }
        }
    }

    private static func makeStatsSection(
        environment: NSCollectionLayoutEnvironment
    ) -> NSCollectionLayoutSection {
        let height = HomeStatsBarView.barHeight(for: environment.traitCollection)
        let item = NSCollectionLayoutItem(
            layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .absolute(height)
            )
        )
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .absolute(height)
            ),
            subitems: [item]
        )
        return NSCollectionLayoutSection(group: group)
    }

    private static func makeCarouselSection(
        environment: NSCollectionLayoutEnvironment
    ) -> NSCollectionLayoutSection {
        let item = NSCollectionLayoutItem(
            layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .fractionalHeight(1.0)
            )
        )
        // Absolute height, deliberately not `.estimated`. A tile's height is fully
        // determined by its own constraints, so there is nothing for self-sizing to
        // discover — and an orthogonally-scrolling section needs its entire content
        // size up front, so an estimate made UIKit instantiate and Auto Layout-measure
        // *every* tile in the section on the main thread each time a snapshot was
        // applied. `HomeTileCell.height(for:)` is the same arithmetic, done once.
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: NSCollectionLayoutSize(
                widthDimension: .absolute(tileWidth),
                heightDimension: .absolute(HomeTileCell.height(for: environment.traitCollection))
            ),
            subitems: [item]
        )

        let section = NSCollectionLayoutSection(group: group)
        // Native orthogonal scrolling: no nested scroll views to fight over layout.
        section.orthogonalScrollingBehavior = .continuous
        section.interGroupSpacing = 16
        section.contentInsets = NSDirectionalEdgeInsets(
            top: 8,
            leading: 16,
            bottom: 24,
            trailing: 16
        )

        let header = NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .estimated(44)
            ),
            elementKind: UICollectionView.elementKindSectionHeader,
            alignment: .top
        )
        section.boundarySupplementaryItems = [header]
        return section
    }

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<HomeBoardSection, HomeBoardItem>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, item in
            guard let self else { return UICollectionViewCell() }
            switch item {
            case .stats:
                guard let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: HomeStatsCell.reuseID,
                    for: indexPath
                ) as? HomeStatsCell else {
                    return UICollectionViewCell()
                }
                cell.configure(
                    albumCount: self.stats.albumCount,
                    songCount: self.stats.songCount,
                    isCountProvisional: self.stats.isCountProvisional,
                    isShuffleBusy: self.stats.isShuffleBusy,
                    isShuffleDisabled: self.stats.isShuffleDisabled,
                    onShuffle: { [weak self] in self?.onShuffle?() }
                )
                return cell
            case .tile(let entry):
                guard let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: HomeTileCell.reuseID,
                    for: indexPath
                ) as? HomeTileCell else {
                    return UICollectionViewCell()
                }
                cell.configure(with: entry.tile, width: Self.tileWidth)
                return cell
            }
        }

        dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
            guard kind == UICollectionView.elementKindSectionHeader,
                  let self,
                  let header = collectionView.dequeueReusableSupplementaryView(
                      ofKind: kind,
                      withReuseIdentifier: HomeSectionHeaderView.reuseID,
                      for: indexPath
                  ) as? HomeSectionHeaderView
            else { return nil }

            let ids = self.dataSource.snapshot().sectionIdentifiers
            guard indexPath.section < ids.count,
                  case .carousel(let section) = ids[indexPath.section]
            else { return nil }

            header.title = section.title
            let hasTiles = !(self.tiles[section] ?? []).isEmpty
            header.showsSeeAll = hasTiles
            header.onSeeAll = { [weak self] in self?.onSeeAll?(section) }
            return header
        }
    }

    func apply(
        sections: [HomeSection],
        tiles: [HomeSection: [HomeTileItem]],
        stats: HomeStatsBarState
    ) {
        // Skip empty carousels so their headers don't sit over a blank row.
        let visibleSections = sections.filter { !(tiles[$0] ?? []).isEmpty }
        let sectionsChanged = self.sections != visibleSections || self.tiles != tiles
        let statsChanged = self.stats != stats
        guard sectionsChanged || statsChanged else { return }

        if isRefreshing {
            let needsSection = (pendingApply?.needsSectionApply ?? false) || sectionsChanged
            let needsStats = (pendingApply?.needsStatsApply ?? false) || statsChanged
            pendingApply = PendingHomeApply(
                visibleSections: visibleSections,
                tiles: tiles,
                stats: stats,
                needsSectionApply: needsSection,
                needsStatsApply: needsStats
            )
            self.sections = visibleSections
            self.tiles = tiles
            self.stats = stats
            return
        }

        commitApply(
            visibleSections: visibleSections,
            tiles: tiles,
            stats: stats,
            sectionsChanged: sectionsChanged,
            statsChanged: statsChanged
        )
    }

    private func commitApply(
        visibleSections: [HomeSection],
        tiles: [HomeSection: [HomeTileItem]],
        stats: HomeStatsBarState,
        sectionsChanged: Bool,
        statsChanged: Bool
    ) {
        self.sections = visibleSections
        self.tiles = tiles
        self.stats = stats

        if sectionsChanged {
            var snapshot = NSDiffableDataSourceSnapshot<HomeBoardSection, HomeBoardItem>()
            // Stats rides in the scroll view so it collapses with the large title.
            snapshot.appendSections([.stats])
            snapshot.appendItems([.stats], toSection: .stats)
            for section in visibleSections {
                let board = HomeBoardSection.carousel(section)
                snapshot.appendSections([board])
                let entries = (tiles[section] ?? []).map {
                    HomeBoardItem.tile(HomeEntry(section: section, tile: $0))
                }
                snapshot.appendItems(entries, toSection: board)
            }
            let token = PerfTrace.begin("Home.applySnapshot")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dataSource.apply(snapshot, animatingDifferences: false)
            CATransaction.commit()
            PerfTrace.end(
                token,
                details: "sections=\(visibleSections.count) items=\(snapshot.numberOfItems)"
            )
        } else if statsChanged {
            if collectionView.visibleCells.contains(where: { $0 is HomeStatsCell }) {
                refreshVisibleStatsCell()
            } else {
                var snapshot = dataSource.snapshot()
                snapshot.reconfigureItems([.stats])
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                dataSource.apply(snapshot, animatingDifferences: false)
                CATransaction.commit()
            }
        }
    }

    private func refreshVisibleStatsCell() {
        for case let cell as HomeStatsCell in collectionView.visibleCells {
            cell.configure(
                albumCount: stats.albumCount,
                songCount: stats.songCount,
                isCountProvisional: stats.isCountProvisional,
                isShuffleBusy: stats.isShuffleBusy,
                isShuffleDisabled: stats.isShuffleDisabled,
                onShuffle: { [weak self] in self?.onShuffle?() }
            )
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateRefreshIndicator(for: scrollView)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if isRefreshing { return }
        if pullDistance(in: scrollView) >= refreshPullThreshold {
            startRefresh()
            return
        }
        guard !decelerate else { return }
        normalizeScrollPosition(animated: true)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard !isRefreshing else { return }
        normalizeScrollPosition(animated: true)
    }

    private func pullDistance(in scrollView: UIScrollView) -> CGFloat {
        -(scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
    }

    private func updateRefreshIndicator(for scrollView: UIScrollView) {
        if isDismissingRefresh { return }
        if isRefreshing {
            refreshIndicator.alpha = 1
            return
        }
        let pulled = pullDistance(in: scrollView)
        let progress = min(max(pulled / refreshPullThreshold, 0), 1)
        refreshIndicator.alpha = progress
        if pulled > 12 {
            if !hasStartedPullSpin {
                hasStartedPullSpin = true
                refreshIndicator.startAnimating()
            }
        } else if pulled <= 0 {
            hasStartedPullSpin = false
            refreshIndicator.stopAnimating()
            refreshIndicator.alpha = 0
        }
    }

    private func startRefresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        hasStartedPullSpin = true
        refreshIndicator.alpha = 1
        if !refreshIndicator.isAnimating {
            refreshIndicator.startAnimating()
        }
        attachRefreshIndicatorToTitle()

        Task { @MainActor [weak self] in
            await self?.onRefresh?()
            self?.finishRefresh()
        }
    }

    private func finishRefresh() {
        isDismissingRefresh = true

        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
            self.refreshIndicator.alpha = 0
        } completion: { _ in
            self.refreshIndicator.stopAnimating()
            self.hasStartedPullSpin = false
            self.isDismissingRefresh = false
            self.isRefreshing = false
            if let pending = self.pendingApply {
                self.pendingApply = nil
                self.commitApply(
                    visibleSections: pending.visibleSections,
                    tiles: pending.tiles,
                    stats: pending.stats,
                    sectionsChanged: pending.needsSectionApply,
                    statsChanged: pending.needsStatsApply
                )
            }
            self.normalizeScrollPosition(animated: true)
        }
    }

    private func normalizeScrollPosition(animated: Bool) {
        let topOffset = -collectionView.adjustedContentInset.top
        let offsetY = collectionView.contentOffset.y
        guard offsetY < topOffset + 1 else { return }
        guard abs(offsetY - topOffset) > 0.5 else { return }
        collectionView.setContentOffset(CGPoint(x: 0, y: topOffset), animated: animated)
    }

    /// Artwork starts loading only once a cell is actually about to be seen, and is
    /// cancelled the moment it leaves. That is what keeps a swipe from queueing a hundred
    /// decodes for tiles the user never looks at.
    func collectionView(
        _ collectionView: UICollectionView,
        willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        (cell as? HomeTileCell)?.loadArtworkIfNeeded()
    }

    func collectionView(
        _ collectionView: UICollectionView,
        didEndDisplaying cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        (cell as? HomeTileCell)?.cancelArtworkLoad()
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard case .tile(let entry) = dataSource.itemIdentifier(for: indexPath) else { return }
        onSelectTile?(entry.section, entry.tile)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard case .tile(let entry) = dataSource.itemIdentifier(for: indexPath),
              let compoundId = entry.tile.albumCompoundId,
              let remoteId = entry.tile.albumRemoteId
        else { return nil }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(title: "Play", image: UIImage(systemName: "play.fill")) { _ in
                    self?.onPlayAlbum?(compoundId, remoteId)
                }
            ])
        }
    }
}

// MARK: - Stats bar (UIKit — fixed height, no SwiftUI hosting)

@MainActor
final class HomeStatsBarView: UIView {
    static let verticalPadding: CGFloat = 6
    static let buttonVerticalPadding: CGFloat = 7
    static let buttonHorizontalPadding: CGFloat = 14

    static func barHeight(for traits: UITraitCollection) -> CGFloat {
        let font = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits)
        let buttonHeight = font.lineHeight + buttonVerticalPadding * 2
        return verticalPadding * 2 + max(font.lineHeight, buttonHeight)
    }

    private let countLabel = UILabel()
    private let shuffleButton = UIButton(type: .system)
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let shuffleIconView = UIImageView()
    private let shuffleTitleLabel = UILabel()
    private var onShuffle: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = .preferredFont(forTextStyle: .subheadline)
        countLabel.adjustsFontForContentSizeCategory = true
        countLabel.textColor = .secondaryLabel

        shuffleButton.translatesAutoresizingMaskIntoConstraints = false
        shuffleButton.backgroundColor = .secondarySystemFill
        shuffleButton.layer.cornerRadius = 16
        shuffleButton.clipsToBounds = true
        shuffleButton.addTarget(self, action: #selector(shuffleTapped), for: .touchUpInside)

        shuffleIconView.translatesAutoresizingMaskIntoConstraints = false
        shuffleIconView.image = UIImage(systemName: "shuffle")
        shuffleIconView.tintColor = .label
        shuffleIconView.contentMode = .scaleAspectFit

        shuffleTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        shuffleTitleLabel.text = "Shuffle"
        shuffleTitleLabel.font = .preferredFont(forTextStyle: .subheadline).semibold
        shuffleTitleLabel.adjustsFontForContentSizeCategory = true
        shuffleTitleLabel.textColor = .label

        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.hidesWhenStopped = true

        shuffleButton.addSubview(shuffleIconView)
        shuffleButton.addSubview(shuffleTitleLabel)
        shuffleButton.addSubview(activityIndicator)

        addSubview(countLabel)
        addSubview(shuffleButton)

        NSLayoutConstraint.activate([
            countLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: shuffleButton.leadingAnchor,
                constant: -12
            ),

            shuffleButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            shuffleButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            shuffleButton.heightAnchor.constraint(
                greaterThanOrEqualToConstant: shuffleTitleLabel.font.lineHeight + Self.buttonVerticalPadding * 2
            ),

            shuffleIconView.leadingAnchor.constraint(equalTo: shuffleButton.leadingAnchor, constant: Self.buttonHorizontalPadding),
            shuffleIconView.centerYAnchor.constraint(equalTo: shuffleButton.centerYAnchor),
            shuffleIconView.widthAnchor.constraint(equalToConstant: 16),
            shuffleIconView.heightAnchor.constraint(equalToConstant: 16),

            shuffleTitleLabel.leadingAnchor.constraint(equalTo: shuffleIconView.trailingAnchor, constant: 6),
            shuffleTitleLabel.trailingAnchor.constraint(equalTo: shuffleButton.trailingAnchor, constant: -Self.buttonHorizontalPadding),
            shuffleTitleLabel.centerYAnchor.constraint(equalTo: shuffleButton.centerYAnchor),

            activityIndicator.centerXAnchor.constraint(equalTo: shuffleIconView.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: shuffleIconView.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(
        albumCount: Int,
        songCount: Int,
        isCountProvisional: Bool,
        isShuffleBusy: Bool,
        isShuffleDisabled: Bool,
        onShuffle: @escaping () -> Void
    ) {
        self.onShuffle = onShuffle
        let albumText = "\(albumCount.formatted()) \(albumCount == 1 ? "Album" : "Albums")"
        let songText = "\(songCount.formatted()) \(songCount == 1 ? "Song" : "Songs")"
        countLabel.text = "\(albumText) · \(songText)"
        countLabel.alpha = isCountProvisional ? 0.85 : 1
        countLabel.accessibilityLabel = isCountProvisional ? "Counting library" : countLabel.text

        shuffleButton.isEnabled = !isShuffleBusy && !isShuffleDisabled
        shuffleButton.alpha = isShuffleDisabled ? 0.35 : 1
        shuffleIconView.isHidden = isShuffleBusy
        shuffleTitleLabel.isHidden = isShuffleBusy
        if isShuffleBusy {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }
    }

    @objc private func shuffleTapped() {
        onShuffle?()
    }
}

@MainActor
final class HomeStatsCell: UICollectionViewCell {
    static let reuseID = "HomeStatsCell"

    private let barView = HomeStatsBarView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        barView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(barView)
        NSLayoutConstraint.activate([
            barView.topAnchor.constraint(equalTo: contentView.topAnchor),
            barView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            barView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            barView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(
        albumCount: Int,
        songCount: Int,
        isCountProvisional: Bool,
        isShuffleBusy: Bool,
        isShuffleDisabled: Bool,
        onShuffle: @escaping () -> Void
    ) {
        barView.configure(
            albumCount: albumCount,
            songCount: songCount,
            isCountProvisional: isCountProvisional,
            isShuffleBusy: isShuffleBusy,
            isShuffleDisabled: isShuffleDisabled,
            onShuffle: onShuffle
        )
    }
}

// MARK: - Section header

@MainActor
final class HomeSectionHeaderView: UICollectionReusableView {
    static let reuseID = "HomeSectionHeaderView"

    var onSeeAll: (() -> Void)?

    var title: String? {
        get { titleLabel.text }
        set { titleLabel.text = newValue }
    }

    var showsSeeAll: Bool {
        get { !seeAllButton.isHidden }
        set { seeAllButton.isHidden = !newValue }
    }

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.preferredFont(forTextStyle: .title2).bold
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        return label
    }()

    private let seeAllButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("See All", for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        return button
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(titleLabel)
        addSubview(seeAllButton)
        seeAllButton.addTarget(self, action: #selector(seeAllTapped), for: .touchUpInside)

        // No extra horizontal padding here: the section's contentInsets already inset
        // headers (`supplementariesFollowContentInsets` defaults to true), so matching
        // that inset again would push the title past the left edge of the tiles.
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: seeAllButton.leadingAnchor,
                constant: -8
            ),
            seeAllButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            seeAllButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func prepareForReuse() {
        super.prepareForReuse()
        onSeeAll = nil
    }

    @objc private func seeAllTapped() {
        onSeeAll?()
    }
}

// MARK: - Tile cell

@MainActor
final class HomeTileCell: UICollectionViewCell {
    static let reuseID = "HomeTileCell"

    private let artworkView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let explicitBadge = ExplicitBadgeView()
    private let subtitleRow = UIStackView()
    private var symbol = "music.note"
    private var artworkToken: String?
    private var artworkTask: Task<Void, Never>?
    private var artworkWidthConstraint: NSLayoutConstraint!
    private var titleHeightConstraint: NSLayoutConstraint!

    /// Vertical spacing between the artwork, title and subtitle.
    private static let titleSpacing: CGFloat = 8
    private static let subtitleSpacing: CGFloat = 2

    static func titleFont(for traits: UITraitCollection) -> UIFont {
        UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits).semibold
    }

    /// Two reserved title lines, so a one-line title beside a two-line one doesn't leave
    /// the row ragged.
    static func titleHeight(for traits: UITraitCollection) -> CGFloat {
        ceil(titleFont(for: traits).lineHeight * 2)
    }

    /// The single source of truth for tile height, shared with the section layout so the
    /// two can't disagree. Square artwork, two title lines, one subtitle line.
    static func height(for traits: UITraitCollection) -> CGFloat {
        let subtitle = UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: traits)
        return HomeCollectionViewController.tileWidth
            + titleSpacing
            + titleHeight(for: traits)
            + subtitleSpacing
            + ceil(subtitle.lineHeight)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkView.contentMode = .scaleAspectFill
        artworkView.clipsToBounds = true
        artworkView.layer.cornerRadius = VerodromeTheme.cornerRadius
        artworkView.backgroundColor = .secondarySystemFill

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = Self.titleFont(for: traitCollection)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 1
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        explicitBadge.isHidden = true
        subtitleRow.axis = .horizontal
        subtitleRow.spacing = 5
        subtitleRow.alignment = .center
        subtitleRow.translatesAutoresizingMaskIntoConstraints = false
        subtitleRow.addArrangedSubview(explicitBadge)
        subtitleRow.addArrangedSubview(subtitleLabel)

        contentView.addSubview(artworkView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(subtitleRow)

        artworkWidthConstraint = artworkView.widthAnchor.constraint(
            equalToConstant: HomeCollectionViewController.tileWidth
        )
        titleHeightConstraint = titleLabel.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            artworkView.topAnchor.constraint(equalTo: contentView.topAnchor),
            artworkView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            artworkWidthConstraint,
            artworkView.heightAnchor.constraint(equalTo: artworkView.widthAnchor),

            titleLabel.topAnchor.constraint(
                equalTo: artworkView.bottomAnchor,
                constant: Self.titleSpacing
            ),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: artworkView.trailingAnchor),
            titleHeightConstraint,

            subtitleRow.topAnchor.constraint(
                equalTo: titleLabel.bottomAnchor,
                constant: Self.subtitleSpacing
            ),
            subtitleRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            subtitleRow.trailingAnchor.constraint(equalTo: artworkView.trailingAnchor),
            subtitleRow.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        updateTitleHeight()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (cell: Self, _: UITraitCollection) in
            cell.updateTitleHeight()
            cell.explicitBadge.applyBorderColor()
        }

        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { nil }

    private func updateTitleHeight() {
        titleLabel.font = Self.titleFont(for: traitCollection)
        titleHeightConstraint.constant = Self.titleHeight(for: traitCollection)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelArtworkLoad()
        artworkToken = nil
        artworkView.image = nil
        titleLabel.text = nil
        subtitleLabel.text = nil
        explicitBadge.isHidden = true
    }

    func configure(with tile: HomeTileItem, width: CGFloat) {
        cancelArtworkLoad()
        artworkWidthConstraint.constant = width
        titleLabel.text = tile.title
        subtitleLabel.text = tile.subtitle
        explicitBadge.isHidden = !tile.isExplicit
        explicitBadge.applyBorderColor()
        symbol = tile.symbol
        artworkToken = tile.artworkToken
        if tile.isExplicit {
            accessibilityLabel = tile.subtitle.isEmpty
                ? "\(tile.title), Explicit"
                : "\(tile.title), Explicit, \(tile.subtitle)"
        } else {
            accessibilityLabel = tile.subtitle.isEmpty ? tile.title : "\(tile.title), \(tile.subtitle)"
        }

        // Synchronous cache probe, so a tile scrolling back in shows its art in the same
        // frame instead of flashing a placeholder. Any cached size counts —
        // `loadArtworkIfNeeded` still fetches the tile size on an inexact hit.
        if let token = tile.artworkToken, !token.isEmpty,
           let cached = ArtworkImageCache.shared.bestAvailableImage(
               for: token,
               size: ArtworkPixelSize.homeTile
           ) {
            show(image: cached.image)
        } else {
            showPlaceholder()
        }
    }

    func loadArtworkIfNeeded() {
        guard artworkTask == nil, let token = artworkToken, !token.isEmpty else { return }
        if let cached = ArtworkImageCache.shared.image(
            for: token,
            size: ArtworkPixelSize.homeTile
        ) {
            show(image: cached)
            return
        }

        artworkTask = Task(priority: .userInitiated) { [weak self] in
            let image = await VisibleArtworkLoader.load(
                token: token,
                size: ArtworkPixelSize.homeTile,
                priority: .userInitiated
            )
            guard !Task.isCancelled, let self, self.artworkToken == token else { return }
            self.artworkTask = nil
            guard let image else { return }
            self.show(image: image)
        }
    }

    func cancelArtworkLoad() {
        artworkTask?.cancel()
        artworkTask = nil
    }

    private func show(image: UIImage) {
        artworkView.contentMode = .scaleAspectFill
        artworkView.tintColor = nil
        artworkView.image = image
    }

    private func showPlaceholder() {
        artworkView.contentMode = .center
        artworkView.tintColor = .secondaryLabel
        artworkView.image = UIImage(systemName: symbol)
    }
}

private extension UIFont {
    var bold: UIFont { withTraits(.traitBold) }

    var semibold: UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.semibold]
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }

    private func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
