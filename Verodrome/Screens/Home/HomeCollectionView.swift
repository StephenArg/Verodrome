import SwiftUI
import UIKit
import VerodromeKit

/// Identifies one tile within one section.
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

/// Home's carousels, rendered by a single `UICollectionView`.
///
/// Every section is one orthogonally-scrolling row of the same collection view, which is
/// how Amperfy's `HomeVC` does it. The whole screen therefore has one scroll view and one
/// layout system, and only the handful of tiles actually on screen exist as views.
struct HomeCollectionView: UIViewControllerRepresentable {
    let sections: [HomeSection]
    let tiles: [HomeSection: [HomeTileItem]]
    var onSelectTile: (HomeSection, HomeTileItem) -> Void
    var onPlayAlbum: (_ compoundId: String, _ remoteId: String) -> Void
    var onSeeAll: (HomeSection) -> Void
    var onRefresh: @MainActor () async -> Void

    func makeUIViewController(context: Context) -> HomeCollectionViewController {
        let controller = HomeCollectionViewController()
        controller.onSelectTile = onSelectTile
        controller.onPlayAlbum = onPlayAlbum
        controller.onSeeAll = onSeeAll
        controller.onRefresh = onRefresh
        return controller
    }

    func updateUIViewController(_ controller: HomeCollectionViewController, context: Context) {
        controller.onSelectTile = onSelectTile
        controller.onPlayAlbum = onPlayAlbum
        controller.onSeeAll = onSeeAll
        controller.onRefresh = onRefresh
        controller.apply(sections: sections, tiles: tiles)
    }
}

@MainActor
final class HomeCollectionViewController: UICollectionViewController {
    static let tileWidth: CGFloat = 160

    var onSelectTile: ((HomeSection, HomeTileItem) -> Void)?
    var onPlayAlbum: ((_ compoundId: String, _ remoteId: String) -> Void)?
    var onSeeAll: ((HomeSection) -> Void)?
    var onRefresh: (@MainActor () async -> Void)?

    private var dataSource: UICollectionViewDiffableDataSource<HomeSection, HomeEntry>!
    private var sections: [HomeSection] = []
    private var tiles: [HomeSection: [HomeTileItem]] = [:]

    init() {
        super.init(collectionViewLayout: Self.createLayout())
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.backgroundColor = .systemBackground
        collectionView.contentInsetAdjustmentBehavior = .scrollableAxes
        collectionView.alwaysBounceVertical = true
        collectionView.register(
            HomeTileCell.self,
            forCellWithReuseIdentifier: HomeTileCell.reuseID
        )
        collectionView.register(
            HomeSectionHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: HomeSectionHeaderView.reuseID
        )

        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
        collectionView.refreshControl = refreshControl

        // Tile height is absolute, so Dynamic Type changes have to re-run the section
        // provider rather than being picked up by self-sizing.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (controller: Self, _: UITraitCollection) in
            controller.collectionView.collectionViewLayout.invalidateLayout()
        }

        configureDataSource()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(retryVisibleArtwork),
            name: .backendAuthenticated,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Visible tiles that raced ahead of cold-launch login stay on placeholders otherwise.
    @objc private func retryVisibleArtwork() {
        for case let cell as HomeTileCell in collectionView.visibleCells {
            cell.loadArtworkIfNeeded()
        }
    }

    private static func createLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { _, environment in
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
    }

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<HomeSection, HomeEntry>(
            collectionView: collectionView
        ) { collectionView, indexPath, entry in
            guard let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: HomeTileCell.reuseID,
                for: indexPath
            ) as? HomeTileCell else {
                return UICollectionViewCell()
            }
            cell.configure(with: entry.tile, width: Self.tileWidth)
            return cell
        }

        dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
            guard kind == UICollectionView.elementKindSectionHeader,
                  let self,
                  let header = collectionView.dequeueReusableSupplementaryView(
                      ofKind: kind,
                      withReuseIdentifier: HomeSectionHeaderView.reuseID,
                      for: indexPath
                  ) as? HomeSectionHeaderView,
                  indexPath.section < self.sections.count
            else { return nil }

            let section = self.sections[indexPath.section]
            header.title = section.title
            let hasTiles = !(self.tiles[section] ?? []).isEmpty
            header.showsSeeAll = hasTiles
            header.onSeeAll = { [weak self] in self?.onSeeAll?(section) }
            return header
        }
    }

    func apply(sections: [HomeSection], tiles: [HomeSection: [HomeTileItem]]) {
        // Skip empty carousels so their headers don't sit over a blank row.
        let visibleSections = sections.filter { !(tiles[$0] ?? []).isEmpty }
        guard self.sections != visibleSections || self.tiles != tiles else { return }
        self.sections = visibleSections
        self.tiles = tiles

        var snapshot = NSDiffableDataSourceSnapshot<HomeSection, HomeEntry>()
        snapshot.appendSections(visibleSections)
        for section in visibleSections {
            let entries = (tiles[section] ?? []).map { HomeEntry(section: section, tile: $0) }
            snapshot.appendItems(entries, toSection: section)
        }
        // `animatingDifferences: false` on the main queue applies synchronously, and this
        // layout has one orthogonal scroll view per section — so this call is a plausible
        // home for main-thread stalls and is worth timing separately from the fetch.
        let token = PerfTrace.begin("Home.applySnapshot")
        dataSource.apply(snapshot, animatingDifferences: false)
        PerfTrace.end(
            token,
            details: "sections=\(visibleSections.count) items=\(snapshot.numberOfItems)"
        )
    }

    @objc private func handleRefresh() {
        Task { @MainActor in
            await onRefresh?()
            collectionView.refreshControl?.endRefreshing()
        }
    }

    /// Artwork starts loading only once a cell is actually about to be seen, and is
    /// cancelled the moment it leaves. That is what keeps a swipe from queueing a hundred
    /// decodes for tiles the user never looks at.
    override func collectionView(
        _ collectionView: UICollectionView,
        willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        (cell as? HomeTileCell)?.loadArtworkIfNeeded()
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        didEndDisplaying cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        (cell as? HomeTileCell)?.cancelArtworkLoad()
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        didSelectItemAt indexPath: IndexPath
    ) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let entry = dataSource.itemIdentifier(for: indexPath) else { return }
        onSelectTile?(entry.section, entry.tile)
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let entry = dataSource.itemIdentifier(for: indexPath),
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

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: seeAllButton.leadingAnchor,
                constant: -8
            ),
            seeAllButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
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

        contentView.addSubview(artworkView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(subtitleLabel)

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

            subtitleLabel.topAnchor.constraint(
                equalTo: titleLabel.bottomAnchor,
                constant: Self.subtitleSpacing
            ),
            subtitleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: artworkView.trailingAnchor),
            subtitleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        updateTitleHeight()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (cell: Self, _: UITraitCollection) in
            cell.updateTitleHeight()
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
    }

    func configure(with tile: HomeTileItem, width: CGFloat) {
        cancelArtworkLoad()
        artworkWidthConstraint.constant = width
        titleLabel.text = tile.title
        subtitleLabel.text = tile.subtitle
        symbol = tile.symbol
        artworkToken = tile.artworkToken
        accessibilityLabel = tile.subtitle.isEmpty ? tile.title : "\(tile.title), \(tile.subtitle)"

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
