import SwiftUI
import UIKit
import VerodromeKit

/// A row that the indexed table can render. Section keys are precomputed at map time
/// so `String.sectionInitial` (an ICU `folding` call) doesn't re-run on every regroup.
protocol LibraryRow: Identifiable, Sendable, Hashable where ID == String {
    var sectionKey: String { get }
    var title: String { get }
    var subtitle: String { get }
    var artworkToken: String? { get }
    var symbol: String { get }
    var trailingText: String? { get }
    /// A 0–5 star rating drawn in place of `trailingText`, so the filled stars can carry
    /// the tint colour instead of being flattened into a plain string.
    var trailingRating: Int? { get }
    /// Player identity, for rows that represent something playable. Distinct from
    /// `id`, which is the compound library id and never matches a queue item.
    var playableId: String? { get }
    /// Song remote ids belonging to this row (albums). Empty for artists/genres/…
    /// Used to overlay live download state from `DownloadCenter` without refetching.
    var songRemoteIds: [String] { get }
    /// Tracks already on disk when the snapshot was built.
    var downloadedSongIds: Set<String> { get }
    /// Server track count when known — denominator for partial vs full downloads.
    var trackTotal: Int { get }
}

extension LibraryRow {
    var trailingRating: Int? { nil }
    var playableId: String? { nil }
    var songRemoteIds: [String] { [] }
    var downloadedSongIds: Set<String> { [] }
    var trackTotal: Int { 0 }
}

struct LibraryRowSection<Item: LibraryRow>: Identifiable, Sendable, Hashable {
    let letter: String
    let items: [Item]
    var id: String { letter }

    init(letter: String, items: [Item]) {
        self.letter = letter
        self.items = items
    }
}

/// Concrete row for Artists, Albums, Playlists, Genres and any simple library list.
struct LibraryRowSnapshot: LibraryRow {
    let id: String
    let sectionKey: String
    let title: String
    let subtitle: String
    let artworkToken: String?
    let symbol: String
    let trailingText: String?
    let trailingRating: Int?
    let playableId: String?
    let songRemoteIds: [String]
    let downloadedSongIds: Set<String>
    let trackTotal: Int

    init(
        id: String,
        sectionKey: String,
        title: String,
        subtitle: String,
        artworkToken: String?,
        symbol: String = "music.note",
        trailingText: String? = nil,
        trailingRating: Int? = nil,
        playableId: String? = nil,
        songRemoteIds: [String] = [],
        downloadedSongIds: Set<String> = [],
        trackTotal: Int = 0
    ) {
        self.id = id
        self.sectionKey = sectionKey
        self.title = title
        self.subtitle = subtitle
        self.artworkToken = artworkToken
        self.symbol = symbol
        self.trailingText = trailingText
        self.trailingRating = trailingRating
        self.playableId = playableId
        self.songRemoteIds = songRemoteIds
        self.downloadedSongIds = downloadedSongIds
        self.trackTotal = trackTotal
    }
}

/// Fast alphabet-indexed list backed by UITableView. Handles 10k+ rows.
/// Rows cannot host `NavigationLink`; use `onSelect` and drive navigation from SwiftUI
/// via `navigationDestination(item:)`.
struct IndexedEntityTableView<Item: LibraryRow>: UIViewControllerRepresentable {
    let sections: [LibraryRowSection<Item>]
    var playingId: String?
    /// Set while `sections` holds only the first screenful of a two-phase load.
    var isPartial: Bool = false
    /// False when the rows are ordered by something other than title, which makes
    /// letter headers and the A–Z scrubber meaningless.
    var isSectioned: Bool = true
    /// Bumps when `DownloadCenter` changes so album download badges reconfigure live.
    var downloadRevision: Int = 0
    var onSelect: (Item, [Item]) -> Void
    var onAddToQueue: ((Item) -> Void)?
    var onRequestActions: ((String) -> Void)?
    /// Scrolls away above the first row, so chrome that belongs to the list can leave
    /// with the large title instead of holding height on a screen full of rows.
    var header: AnyView?
    /// Distance scrolled past the top of the content, safe-area inset already removed.
    var onScroll: ((CGFloat) -> Void)?

    init(
        sections: [LibraryRowSection<Item>],
        playingId: String? = nil,
        isPartial: Bool = false,
        isSectioned: Bool = true,
        downloadRevision: Int = 0,
        onSelect: @escaping (Item, [Item]) -> Void,
        onAddToQueue: ((Item) -> Void)? = nil,
        onRequestActions: ((String) -> Void)? = nil,
        header: AnyView? = nil,
        onScroll: ((CGFloat) -> Void)? = nil
    ) {
        self.sections = sections
        self.playingId = playingId
        self.isPartial = isPartial
        self.isSectioned = isSectioned
        self.downloadRevision = downloadRevision
        self.onSelect = onSelect
        self.onAddToQueue = onAddToQueue
        self.onRequestActions = onRequestActions
        self.header = header
        self.onScroll = onScroll
    }

    func makeUIViewController(context: Context) -> IndexedEntityTableController<Item> {
        let controller = IndexedEntityTableController<Item>()
        controller.onSelect = onSelect
        controller.onAddToQueue = onAddToQueue
        controller.onRequestActions = onRequestActions
        controller.onScroll = onScroll
        return controller
    }

    func updateUIViewController(_ controller: IndexedEntityTableController<Item>, context: Context) {
        controller.onSelect = onSelect
        controller.onAddToQueue = onAddToQueue
        controller.onRequestActions = onRequestActions
        controller.onScroll = onScroll
        controller.downloadRevision = downloadRevision
        controller.setHeader(header)
        controller.apply(
            sections: sections,
            playingId: playingId,
            isPartial: isPartial,
            isSectioned: isSectioned
        )
    }
}

@MainActor
final class IndexedEntityTableController<Item: LibraryRow>: UIViewController, UITableViewDataSource, UITableViewDelegate, UITableViewDataSourcePrefetching {
    var onSelect: ((Item, [Item]) -> Void)?
    var onAddToQueue: ((Item) -> Void)?
    var onRequestActions: ((String) -> Void)?
    var onScroll: ((CGFloat) -> Void)?
    var downloadRevision = 0

    private let tableView = UITableView(frame: .zero, style: .plain)
    private var sections: [LibraryRowSection<Item>] = []
    private var playingId: String?
    private var isPartial = false
    private var isSectioned = true
    private var flatItems: [Item] = []
    private var appliedFingerprint = ""
    private var appliedDownloadRevision = 0
    private var prefetchTasks: [IndexPath: Task<Void, Never>] = [:]
    private var headerHost: UIHostingController<AnyView>?
    private var headerWidth: CGFloat = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.prefetchDataSource = self
        tableView.rowHeight = 60
        tableView.register(EntityTableCell.self, forCellReuseIdentifier: EntityTableCell.reuseID)
        tableView.sectionIndexColor = .secondaryLabel
        tableView.sectionIndexBackgroundColor = .clear
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

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

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        sizeHeaderToFit()
    }

    /// Installs (or updates) the SwiftUI view that scrolls above the first row.
    /// `tableHeaderView` is frame-laid-out, so the hosting view has to be measured by
    /// hand whenever its content or the table's width changes.
    func setHeader(_ header: AnyView?) {
        guard let header else {
            guard let host = headerHost else { return }
            tableView.tableHeaderView = nil
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
            headerHost = nil
            headerWidth = 0
            return
        }

        if let host = headerHost {
            host.rootView = header
            // New content can be a different height even at the same width.
            headerWidth = 0
            sizeHeaderToFit()
            return
        }

        let host = UIHostingController(rootView: header)
        host.view.backgroundColor = .clear
        // The header sits inside the scroll view; letting it claim the safe area would
        // pad it by the nav bar's inset on every layout pass.
        host.safeAreaRegions = []
        addChild(host)
        host.didMove(toParent: self)
        headerHost = host
        tableView.tableHeaderView = host.view
        headerWidth = 0
        sizeHeaderToFit()
    }

    private func sizeHeaderToFit() {
        guard let host = headerHost, let headerView = tableView.tableHeaderView else { return }
        let width = tableView.bounds.width
        guard width > 0 else { return }
        let height = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        guard width != headerWidth || abs(headerView.frame.height - height) > 0.5 else { return }
        headerWidth = width
        headerView.frame = CGRect(x: 0, y: 0, width: width, height: height)
        // Reassigning is what makes the table adopt the new header height.
        tableView.tableHeaderView = headerView
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        onScroll?(scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
    }

    /// Rows that asked for art before cold-launch login finished never get `willDisplay` again.
    @objc private func retryVisibleArtwork() {
        for case let cell as EntityTableCell in tableView.visibleCells {
            guard let indexPath = tableView.indexPath(for: cell),
                  let item = item(at: indexPath) else { continue }
            cell.beginArtworkLoadIfNeeded(
                token: item.artworkToken,
                symbol: item.symbol,
                priority: .userInitiated
            )
        }
    }

    func apply(
        sections: [LibraryRowSection<Item>],
        playingId: String?,
        isPartial: Bool,
        isSectioned: Bool
    ) {
        // `isSectioned` belongs in the fingerprint: it changes whether headers render at
        // all, which needs a reload even if the rows themselves are untouched.
        let fingerprint = "\(sections.count)|\(sections.first?.items.first?.id ?? "")|\(sections.last?.items.last?.id ?? "")|\(sections.reduce(0) { $0 + $1.items.count })|\(isSectioned)"
        let playingChanged = self.playingId != playingId
        let partialChanged = self.isPartial != isPartial
        self.playingId = playingId
        self.isPartial = isPartial
        self.isSectioned = isSectioned

        if fingerprint != appliedFingerprint {
            appliedFingerprint = fingerprint
            appliedDownloadRevision = downloadRevision
            self.sections = sections
            flatItems = sections.flatMap(\.items)
            // Padding is reserved per section even where the header itself is empty, so
            // it has to come off with the headers or short lists get unexplained gaps.
            tableView.sectionHeaderTopPadding = showsLetterSections ? 4 : 0
            cancelAllPrefetchTasks()
            tableView.reloadData()
            return
        }
        // A head page that already held every row leaves the content identical, so
        // only the scrubber needs to catch up.
        if partialChanged {
            tableView.reloadSectionIndexTitles()
        }
        if playingChanged {
            for case let cell as EntityTableCell in tableView.visibleCells {
                guard let indexPath = tableView.indexPath(for: cell),
                      let item = item(at: indexPath) else { continue }
                cell.setPlaying(isPlaying(item))
            }
        }
        if appliedDownloadRevision != downloadRevision {
            appliedDownloadRevision = downloadRevision
            for case let cell as EntityTableCell in tableView.visibleCells {
                guard let indexPath = tableView.indexPath(for: cell),
                      let item = item(at: indexPath) else { continue }
                cell.setDownloadStatus(Self.downloadStatus(for: item))
            }
        }
    }

    private static func downloadStatus(for item: Item) -> DownloadStatus {
        guard !item.songRemoteIds.isEmpty || item.trackTotal > 0 else { return .none }
        return SongsDownloadSummary(
            songRemoteIds: item.songRemoteIds,
            downloadedIds: item.downloadedSongIds,
            trackTotal: item.trackTotal,
            center: DownloadCenter.shared
        ).status
    }

    private func isPlaying(_ item: Item) -> Bool {
        guard let playingId, let rowId = item.playableId else { return false }
        return rowId == playingId
    }

    private func cancelAllPrefetchTasks() {
        for (_, task) in prefetchTasks { task.cancel() }
        prefetchTasks.removeAll()
    }

    private func item(at indexPath: IndexPath) -> Item? {
        guard sections.indices.contains(indexPath.section),
              sections[indexPath.section].items.indices.contains(indexPath.row) else { return nil }
        return sections[indexPath.section].items[indexPath.row]
    }

    /// Letter grouping only earns its keep on a list too long to scan in one flick.
    /// Below this, both the headers and the A–Z scrubber are clutter.
    private static var letterSectionRowThreshold: Int { 100 }

    private var showsLetterSections: Bool {
        isSectioned && sections.count > 1 && flatItems.count >= Self.letterSectionRowThreshold
    }

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].items.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard showsLetterSections else { return nil }
        return sections[section].letter
    }

    func sectionIndexTitles(for tableView: UITableView) -> [String]? {
        // A head page holds only the leading letters, so wait for the full list rather
        // than showing a scrubber that grows from two entries to the whole alphabet.
        // Headers don't need the same wait: the head page is a prefix, so the headers it
        // shows are the ones that stay.
        guard showsLetterSections, !isPartial else { return nil }
        return sections.map(\.letter)
    }

    func tableView(_ tableView: UITableView, sectionForSectionIndexTitle title: String, at index: Int) -> Int {
        index
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: EntityTableCell.reuseID, for: indexPath) as! EntityTableCell
        let item = sections[indexPath.section].items[indexPath.row]
        cell.configure(
            title: item.title,
            subtitle: item.subtitle,
            trailingText: item.trailingText,
            trailingRating: item.trailingRating,
            artworkToken: item.artworkToken,
            symbol: item.symbol,
            isPlaying: isPlaying(item),
            downloadStatus: Self.downloadStatus(for: item)
        )
        return cell
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard let entityCell = cell as? EntityTableCell,
              let item = item(at: indexPath) else { return }
        entityCell.beginArtworkLoadIfNeeded(token: item.artworkToken, symbol: item.symbol, priority: .userInitiated)
    }

    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        (cell as? EntityTableCell)?.cancelArtworkLoad()
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = sections[indexPath.section].items[indexPath.row]
        onSelect?(item, flatItems)
    }

    func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            guard prefetchTasks[indexPath] == nil,
                  let item = item(at: indexPath),
                  let token = item.artworkToken, !token.isEmpty,
                  ArtworkImageCache.shared.image(for: token, size: ArtworkPixelSize.thumbnail) == nil
            else { continue }
            prefetchTasks[indexPath] = Task(priority: .utility) {
                defer { Task { @MainActor in self.prefetchTasks[indexPath] = nil } }
                _ = await VisibleArtworkLoader.load(
                    token: token,
                    size: ArtworkPixelSize.thumbnail,
                    priority: .utility
                )
            }
        }
    }

    func tableView(_ tableView: UITableView, cancelPrefetchingForRowsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            prefetchTasks[indexPath]?.cancel()
            prefetchTasks[indexPath] = nil
        }
    }

    func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard onAddToQueue != nil || onRequestActions != nil,
              let item = item(at: indexPath) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            var actions: [UIAction] = []
            if let onAddToQueue = self?.onAddToQueue {
                actions.append(UIAction(
                    title: "Add to Queue",
                    image: UIImage(systemName: "text.append")
                ) { _ in onAddToQueue(item) })
            }
            if let onRequestActions = self?.onRequestActions {
                actions.append(UIAction(title: "Actions…", image: UIImage(systemName: "ellipsis.circle")) { _ in
                    onRequestActions(item.id)
                })
            }
            return UIMenu(children: actions)
        }
    }
}

/// Cancel-friendly image fetch for list thumbnails (no global FIFO queue).
enum VisibleArtworkLoader {
    static func load(
        token: String,
        size: Int,
        priority: TaskPriority
    ) async -> UIImage? {
        _ = priority
        if let cached = ArtworkImageCache.shared.image(for: token, size: size) {
            return cached
        }
        if Task.isCancelled { return nil }
        guard let image = await ArtworkResolver.shared.loadImage(
            for: token,
            kind: .album,
            size: size
        ) else { return nil }
        if Task.isCancelled { return nil }
        ArtworkImageCache.shared.store(image, for: token, size: size)
        return image
    }
}

final class EntityTableCell: UITableViewCell {
    static let reuseID = "EntityTableCell"

    private let artworkView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let trailingLabel = UILabel()
    private let playingView = UIImageView(image: UIImage(systemName: "waveform"))
    private let downloadView = UIImageView()
    private let downloadSpinner = UIActivityIndicatorView(style: .medium)
    private var artworkToken: String?
    private var artworkTask: Task<Void, Never>?
    private var downloadWidthConstraint: NSLayoutConstraint?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkView.contentMode = .scaleAspectFill
        artworkView.clipsToBounds = true
        artworkView.layer.cornerRadius = 8
        artworkView.backgroundColor = .secondarySystemFill

        let subtitleSize = UIFont.preferredFont(forTextStyle: .subheadline).pointSize
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.numberOfLines = 1
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 1
        trailingLabel.font = .monospacedDigitSystemFont(ofSize: subtitleSize, weight: .regular)
        trailingLabel.textColor = .secondaryLabel
        trailingLabel.setContentHuggingPriority(.required, for: .horizontal)
        trailingLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        playingView.tintColor = .tintColor
        playingView.isHidden = true
        playingView.contentMode = .scaleAspectFit
        playingView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        playingView.accessibilityLabel = "Now playing"

        downloadView.contentMode = .scaleAspectFit
        downloadView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        downloadView.isHidden = true
        downloadSpinner.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
        downloadSpinner.hidesWhenStopped = true

        let downloadContainer = UIView()
        downloadContainer.addSubview(downloadView)
        downloadContainer.addSubview(downloadSpinner)
        downloadView.translatesAutoresizingMaskIntoConstraints = false
        downloadSpinner.translatesAutoresizingMaskIntoConstraints = false
        let downloadWidth = downloadContainer.widthAnchor.constraint(equalToConstant: 0)
        downloadWidthConstraint = downloadWidth
        NSLayoutConstraint.activate([
            downloadWidth,
            downloadContainer.heightAnchor.constraint(equalToConstant: 14),
            downloadView.centerXAnchor.constraint(equalTo: downloadContainer.centerXAnchor),
            downloadView.centerYAnchor.constraint(equalTo: downloadContainer.centerYAnchor),
            downloadView.widthAnchor.constraint(equalToConstant: 14),
            downloadView.heightAnchor.constraint(equalToConstant: 14),
            downloadSpinner.centerXAnchor.constraint(equalTo: downloadContainer.centerXAnchor),
            downloadSpinner.centerYAnchor.constraint(equalTo: downloadContainer.centerYAnchor)
        ])

        let titleRow = UIStackView(arrangedSubviews: [playingView, titleLabel])
        titleRow.axis = .horizontal
        titleRow.spacing = 5
        titleRow.alignment = .center

        let subtitleRow = UIStackView(arrangedSubviews: [downloadContainer, subtitleLabel])
        subtitleRow.axis = .horizontal
        subtitleRow.spacing = 5
        subtitleRow.alignment = .center

        let textStack = UIStackView(arrangedSubviews: [titleRow, subtitleRow])
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let hStack = UIStackView(arrangedSubviews: [artworkView, textStack, spacer, trailingLabel])
        hStack.translatesAutoresizingMaskIntoConstraints = false
        hStack.axis = .horizontal
        hStack.spacing = 12
        hStack.alignment = .center
        contentView.addSubview(hStack)

        NSLayoutConstraint.activate([
            artworkView.widthAnchor.constraint(equalToConstant: 44),
            artworkView.heightAnchor.constraint(equalToConstant: 44),
            playingView.widthAnchor.constraint(equalToConstant: 16),
            playingView.heightAnchor.constraint(equalToConstant: 16),
            hStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            hStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            hStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            hStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8)
        ])
    }

    required init?(coder: NSCoder) { nil }

    /// Filled stars use the theme accent so they stay consistent even when a parent
    /// screen rebinds the navigation tint to artwork colors.
    private func ratingStars(_ rating: Int) -> NSAttributedString {
        let filled = max(0, min(5, rating))
        let font = trailingLabel.font ?? .preferredFont(forTextStyle: .subheadline)
        let accent = ThemeManager.shared?.accentUIColor ?? .tintColor
        let stars = NSMutableAttributedString(
            string: String(repeating: "★", count: filled),
            attributes: [.font: font, .foregroundColor: accent]
        )
        stars.append(NSAttributedString(
            string: String(repeating: "☆", count: 5 - filled),
            attributes: [.font: font, .foregroundColor: UIColor.tertiaryLabel]
        ))
        return stars
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelArtworkLoad()
        artworkToken = nil
        artworkView.image = nil
        setPlaying(false)
        setDownloadStatus(.none)
        trailingLabel.attributedText = nil
        trailingLabel.isHidden = false
    }

    func configure(
        title: String,
        subtitle: String,
        trailingText: String?,
        trailingRating: Int?,
        artworkToken: String?,
        symbol: String,
        isPlaying: Bool,
        downloadStatus: DownloadStatus = .none
    ) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
        if let trailingRating {
            trailingLabel.attributedText = ratingStars(trailingRating)
            trailingLabel.isHidden = false
        } else {
            // Assigning `text` after `attributedText` leaves the old attributes behind on
            // a reused cell, so the attributed value has to be cleared first.
            trailingLabel.attributedText = nil
            trailingLabel.text = trailingText
            trailingLabel.isHidden = trailingText == nil
        }
        setPlaying(isPlaying)
        setDownloadStatus(downloadStatus)
        self.artworkToken = artworkToken
        // Any cached size beats a grey box: coming back from a detail screen or the player,
        // the only render in memory is a larger one. `beginArtworkLoadIfNeeded` still
        // fetches the thumbnail, since it only skips on an exact-size hit.
        if let token = artworkToken,
           let cached = ArtworkImageCache.shared.bestAvailableImage(for: token, size: ArtworkPixelSize.thumbnail) {
            artworkView.contentMode = .scaleAspectFill
            artworkView.tintColor = nil
            artworkView.image = cached.image
        } else if artworkToken == nil || artworkToken?.isEmpty == true {
            artworkView.image = UIImage(systemName: symbol)
            artworkView.tintColor = .secondaryLabel
            artworkView.contentMode = .center
        } else {
            artworkView.image = nil
            artworkView.backgroundColor = .secondarySystemFill
        }
    }

    func setDownloadStatus(_ status: DownloadStatus) {
        switch status {
        case .none:
            downloadSpinner.stopAnimating()
            downloadView.isHidden = true
            downloadView.image = nil
            downloadWidthConstraint?.constant = 0
        case .pending, .downloading:
            downloadView.isHidden = true
            downloadView.image = nil
            downloadWidthConstraint?.constant = 14
            downloadSpinner.startAnimating()
        case .partial:
            downloadSpinner.stopAnimating()
            downloadWidthConstraint?.constant = 14
            downloadView.isHidden = false
            downloadView.tintColor = .tintColor
            downloadView.image = UIImage(systemName: "arrow.down.circle")
            downloadView.accessibilityLabel = "Partially downloaded"
        case .cached:
            downloadSpinner.stopAnimating()
            downloadWidthConstraint?.constant = 14
            downloadView.isHidden = false
            // Same accent hue as downloaded, dialed back so prefetch reads softer.
            downloadView.tintColor = .tintColor.withAlphaComponent(0.6)
            downloadView.image = UIImage(systemName: "music.note.square.stack")
            downloadView.accessibilityLabel = "Cached"
        case .downloaded:
            downloadSpinner.stopAnimating()
            downloadWidthConstraint?.constant = 14
            downloadView.isHidden = false
            downloadView.tintColor = .tintColor
            downloadView.image = UIImage(systemName: "arrow.down.circle.fill")
            downloadView.accessibilityLabel = "Downloaded"
        case .failed:
            downloadSpinner.stopAnimating()
            downloadWidthConstraint?.constant = 14
            downloadView.isHidden = false
            downloadView.tintColor = .systemOrange
            downloadView.image = UIImage(systemName: "exclamationmark.circle")
            downloadView.accessibilityLabel = "Download failed"
        }
    }

    func setPlaying(_ isPlaying: Bool) {
        // Re-adding the effect on every reconfigure restarts the animation, so
        // only touch it when the state actually flips.
        guard playingView.isHidden == isPlaying else { return }
        playingView.isHidden = !isPlaying
        if isPlaying {
            playingView.addSymbolEffect(.variableColor.iterative, options: .repeating, animated: false)
        } else {
            playingView.removeAllSymbolEffects()
        }
    }

    func beginArtworkLoadIfNeeded(token: String?, symbol: String, priority: TaskPriority) {
        guard let token, !token.isEmpty else { return }
        // Keep an in-flight load (including one waiting on cold-launch auth).
        if artworkTask != nil, artworkToken == token { return }
        if artworkView.image != nil,
           ArtworkImageCache.shared.image(for: token, size: ArtworkPixelSize.thumbnail) != nil {
            return
        }
        cancelArtworkLoad()
        artworkToken = token
        artworkTask = Task(priority: priority) { [weak self] in
            guard let self else { return }
            let image = await VisibleArtworkLoader.load(
                token: token,
                size: ArtworkPixelSize.thumbnail,
                priority: priority
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.artworkToken == token else { return }
                self.artworkTask = nil
                if let image {
                    self.artworkView.contentMode = .scaleAspectFill
                    self.artworkView.tintColor = nil
                    self.artworkView.image = image
                }
            }
        }
    }

    func cancelArtworkLoad() {
        artworkTask?.cancel()
        artworkTask = nil
    }
}
