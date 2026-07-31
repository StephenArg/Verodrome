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

    init(
        id: String,
        sectionKey: String,
        title: String,
        subtitle: String,
        artworkToken: String?,
        symbol: String = "music.note",
        trailingText: String? = nil
    ) {
        self.id = id
        self.sectionKey = sectionKey
        self.title = title
        self.subtitle = subtitle
        self.artworkToken = artworkToken
        self.symbol = symbol
        self.trailingText = trailingText
    }
}

/// Fast alphabet-indexed list backed by UITableView. Handles 10k+ rows.
/// Rows cannot host `NavigationLink`; use `onSelect` and drive navigation from SwiftUI
/// via `navigationDestination(item:)`.
struct IndexedEntityTableView<Item: LibraryRow>: UIViewControllerRepresentable {
    let sections: [LibraryRowSection<Item>]
    var playingId: String?
    var onSelect: (Item, [Item]) -> Void
    var onPlayNext: ((Item) -> Void)?
    var onRequestActions: ((String) -> Void)?

    init(
        sections: [LibraryRowSection<Item>],
        playingId: String? = nil,
        onSelect: @escaping (Item, [Item]) -> Void,
        onPlayNext: ((Item) -> Void)? = nil,
        onRequestActions: ((String) -> Void)? = nil
    ) {
        self.sections = sections
        self.playingId = playingId
        self.onSelect = onSelect
        self.onPlayNext = onPlayNext
        self.onRequestActions = onRequestActions
    }

    func makeUIViewController(context: Context) -> IndexedEntityTableController<Item> {
        let controller = IndexedEntityTableController<Item>()
        controller.onSelect = onSelect
        controller.onPlayNext = onPlayNext
        controller.onRequestActions = onRequestActions
        return controller
    }

    func updateUIViewController(_ controller: IndexedEntityTableController<Item>, context: Context) {
        controller.onSelect = onSelect
        controller.onPlayNext = onPlayNext
        controller.onRequestActions = onRequestActions
        controller.apply(sections: sections, playingId: playingId)
    }
}

@MainActor
final class IndexedEntityTableController<Item: LibraryRow>: UIViewController, UITableViewDataSource, UITableViewDelegate, UITableViewDataSourcePrefetching {
    var onSelect: ((Item, [Item]) -> Void)?
    var onPlayNext: ((Item) -> Void)?
    var onRequestActions: ((String) -> Void)?

    private let tableView = UITableView(frame: .zero, style: .plain)
    private var sections: [LibraryRowSection<Item>] = []
    private var playingId: String?
    private var flatItems: [Item] = []
    private var appliedFingerprint = ""
    private var prefetchTasks: [IndexPath: Task<Void, Never>] = [:]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.prefetchDataSource = self
        tableView.rowHeight = 60
        tableView.sectionHeaderTopPadding = 4
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
    }

    func apply(sections: [LibraryRowSection<Item>], playingId: String?) {
        let fingerprint = "\(sections.count)|\(sections.first?.items.first?.id ?? "")|\(sections.last?.items.last?.id ?? "")|\(sections.reduce(0) { $0 + $1.items.count })"
        let playingChanged = self.playingId != playingId
        self.playingId = playingId

        if fingerprint != appliedFingerprint {
            appliedFingerprint = fingerprint
            self.sections = sections
            flatItems = sections.flatMap(\.items)
            cancelAllPrefetchTasks()
            tableView.reloadData()
        } else if playingChanged {
            for case let cell as EntityTableCell in tableView.visibleCells {
                guard let indexPath = tableView.indexPath(for: cell) else { continue }
                let item = sections[indexPath.section].items[indexPath.row]
                cell.setPlaying(item.id == playingId)
            }
        }
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

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].items.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].letter
    }

    func sectionIndexTitles(for tableView: UITableView) -> [String]? {
        guard sections.count > 1 else { return nil }
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
            artworkToken: item.artworkToken,
            symbol: item.symbol,
            isPlaying: item.id == playingId
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
        guard onPlayNext != nil || onRequestActions != nil,
              let item = item(at: indexPath) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            var actions: [UIAction] = []
            if let onPlayNext = self?.onPlayNext {
                actions.append(UIAction(
                    title: "Play Next",
                    image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward")
                ) { _ in onPlayNext(item) })
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
    private var artworkToken: String?
    private var artworkTask: Task<Void, Never>?

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
        playingView.tintColor = .tintColor
        playingView.isHidden = true
        playingView.contentMode = .scaleAspectFit

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let trailingStack = UIStackView(arrangedSubviews: [playingView, trailingLabel])
        trailingStack.axis = .horizontal
        trailingStack.spacing = 8
        trailingStack.alignment = .center
        trailingStack.setContentHuggingPriority(.required, for: .horizontal)
        trailingStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let hStack = UIStackView(arrangedSubviews: [artworkView, textStack, spacer, trailingStack])
        hStack.translatesAutoresizingMaskIntoConstraints = false
        hStack.axis = .horizontal
        hStack.spacing = 12
        hStack.alignment = .center
        contentView.addSubview(hStack)

        NSLayoutConstraint.activate([
            artworkView.widthAnchor.constraint(equalToConstant: 44),
            artworkView.heightAnchor.constraint(equalToConstant: 44),
            playingView.widthAnchor.constraint(equalToConstant: 18),
            playingView.heightAnchor.constraint(equalToConstant: 18),
            hStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            hStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            hStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            hStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelArtworkLoad()
        artworkToken = nil
        artworkView.image = nil
        playingView.isHidden = true
        trailingLabel.isHidden = false
    }

    func configure(title: String, subtitle: String, trailingText: String?, artworkToken: String?, symbol: String, isPlaying: Bool) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
        trailingLabel.text = trailingText
        trailingLabel.isHidden = trailingText == nil
        setPlaying(isPlaying)
        self.artworkToken = artworkToken
        if let token = artworkToken,
           let cached = ArtworkImageCache.shared.image(for: token, size: ArtworkPixelSize.thumbnail) {
            artworkView.contentMode = .scaleAspectFill
            artworkView.tintColor = nil
            artworkView.image = cached
        } else if artworkToken == nil || artworkToken?.isEmpty == true {
            artworkView.image = UIImage(systemName: symbol)
            artworkView.tintColor = .secondaryLabel
            artworkView.contentMode = .center
        } else {
            artworkView.image = nil
            artworkView.backgroundColor = .secondarySystemFill
        }
    }

    func setPlaying(_ isPlaying: Bool) {
        playingView.isHidden = !isPlaying
        if isPlaying { trailingLabel.isHidden = true }
    }

    func beginArtworkLoadIfNeeded(token: String?, symbol: String, priority: TaskPriority) {
        guard let token, !token.isEmpty else { return }
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
