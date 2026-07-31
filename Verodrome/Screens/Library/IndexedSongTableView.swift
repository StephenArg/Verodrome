import SwiftUI
import UIKit
import SwiftData
import VerodromeKit

/// Sendable row payload for large song lists (no SwiftData model retained).
struct LibrarySongRowSnapshot: Identifiable, Sendable, Hashable {
    let id: String
    let remoteId: String
    let title: String
    let sortTitle: String
    let artistName: String
    let albumTitle: String
    let artworkToken: String?
    let duration: TimeInterval
    let durationText: String

    init(song: Song) {
        id = song.compoundRemoteId
        remoteId = song.remoteId
        title = song.title
        sortTitle = song.sortTitle.isEmpty ? song.title : song.sortTitle
        artistName = song.artistName ?? "Unknown Artist"
        albumTitle = song.albumTitle ?? "Unknown Album"
        artworkToken = song.artworkToken
        duration = song.playDuration
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        durationText = String(format: "%d:%02d", minutes, seconds)
    }

    var queueItem: QueueItem {
        QueueItem(
            playableId: remoteId,
            kind: .song,
            title: title,
            artistName: artistName,
            albumName: albumTitle,
            duration: duration,
            artworkId: artworkToken
        )
    }

    var subtitle: String { "\(artistName) · \(albumTitle)" }
}

struct SongLetterSection: Identifiable, Sendable, Hashable {
    let letter: String
    let items: [LibrarySongRowSnapshot]
    var id: String { letter }
}

/// Fast alphabet-indexed song list backed by UITableView (handles 10k+ rows).
struct IndexedSongTableView: UIViewControllerRepresentable {
    let sections: [SongLetterSection]
    var playingRemoteId: String?
    var onSelect: (LibrarySongRowSnapshot, [LibrarySongRowSnapshot]) -> Void
    var onPlayNext: (LibrarySongRowSnapshot) -> Void
    var onRequestActions: (String) -> Void

    func makeUIViewController(context: Context) -> IndexedSongTableController {
        let controller = IndexedSongTableController()
        controller.onSelect = onSelect
        controller.onPlayNext = onPlayNext
        controller.onRequestActions = onRequestActions
        return controller
    }

    func updateUIViewController(_ controller: IndexedSongTableController, context: Context) {
        controller.onSelect = onSelect
        controller.onPlayNext = onPlayNext
        controller.onRequestActions = onRequestActions
        controller.apply(sections: sections, playingRemoteId: playingRemoteId)
    }
}

@MainActor
final class IndexedSongTableController: UIViewController, UITableViewDataSource, UITableViewDelegate, UITableViewDataSourcePrefetching {
    var onSelect: ((LibrarySongRowSnapshot, [LibrarySongRowSnapshot]) -> Void)?
    var onPlayNext: ((LibrarySongRowSnapshot) -> Void)?
    var onRequestActions: ((String) -> Void)?

    private let tableView = UITableView(frame: .zero, style: .plain)
    private var sections: [SongLetterSection] = []
    private var playingRemoteId: String?
    private var flatItems: [LibrarySongRowSnapshot] = []
    private var appliedFingerprint = ""
    /// Low-priority warm loads for rows about to appear; cancelled when prefetch is cancelled.
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
        tableView.register(SongTableCell.self, forCellReuseIdentifier: SongTableCell.reuseID)
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

    func apply(sections: [SongLetterSection], playingRemoteId: String?) {
        let fingerprint = "\(sections.count)|\(sections.first?.items.first?.id ?? "")|\(sections.last?.items.last?.id ?? "")|\(sections.reduce(0) { $0 + $1.items.count })"
        let playingChanged = self.playingRemoteId != playingRemoteId
        self.playingRemoteId = playingRemoteId

        if fingerprint != appliedFingerprint {
            let token = PerfTrace.begin("Songs.tableApply", details: "sections=\(sections.count)")
            appliedFingerprint = fingerprint
            self.sections = sections
            flatItems = sections.flatMap(\.items)
            cancelAllPrefetchTasks()
            tableView.reloadData()
            PerfTrace.end(token, details: "rows=\(flatItems.count)")
        } else if playingChanged {
            for case let cell as SongTableCell in tableView.visibleCells {
                guard let indexPath = tableView.indexPath(for: cell) else { continue }
                let item = sections[indexPath.section].items[indexPath.row]
                cell.setPlaying(item.remoteId == playingRemoteId)
            }
        }
    }

    private func cancelAllPrefetchTasks() {
        for (_, task) in prefetchTasks { task.cancel() }
        prefetchTasks.removeAll()
    }

    private func item(at indexPath: IndexPath) -> LibrarySongRowSnapshot? {
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
        let cell = tableView.dequeueReusableCell(withIdentifier: SongTableCell.reuseID, for: indexPath) as! SongTableCell
        let item = sections[indexPath.section].items[indexPath.row]
        // Text + cached art only — network load starts in willDisplay.
        cell.configure(with: item, isPlaying: item.remoteId == playingRemoteId)
        return cell
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard let songCell = cell as? SongTableCell,
              let item = item(at: indexPath) else { return }
        songCell.beginArtworkLoadIfNeeded(token: item.artworkToken, priority: .userInitiated)
    }

    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        (cell as? SongTableCell)?.cancelArtworkLoad()
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
        let item = sections[indexPath.section].items[indexPath.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(
                    title: "Play Next",
                    image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward")
                ) { _ in
                    self?.onPlayNext?(item)
                },
                UIAction(title: "Song Actions…", image: UIImage(systemName: "ellipsis.circle")) { _ in
                    self?.onRequestActions?(item.id)
                }
            ])
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

private final class SongTableCell: UITableViewCell {
    static let reuseID = "SongTableCell"

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

        // Flexible spacer so duration/play icon stay right-aligned across all rows.
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
            // Clear the section-index scrubber; all durations share this same edge.
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

    func configure(with item: LibrarySongRowSnapshot, isPlaying: Bool) {
        titleLabel.text = item.title
        subtitleLabel.text = item.subtitle
        trailingLabel.text = item.durationText
        setPlaying(isPlaying)
        artworkToken = item.artworkToken
        // Instant cache only — defer network until willDisplay.
        if let token = item.artworkToken,
           let cached = ArtworkImageCache.shared.image(for: token, size: ArtworkPixelSize.thumbnail) {
            artworkView.contentMode = .scaleAspectFill
            artworkView.tintColor = nil
            artworkView.image = cached
        } else if item.artworkToken == nil || item.artworkToken?.isEmpty == true {
            artworkView.image = UIImage(systemName: "music.note")
            artworkView.tintColor = .secondaryLabel
            artworkView.contentMode = .center
        } else {
            artworkView.image = nil
            artworkView.backgroundColor = .secondarySystemFill
        }
    }

    func setPlaying(_ isPlaying: Bool) {
        playingView.isHidden = !isPlaying
        trailingLabel.isHidden = isPlaying
    }

    func beginArtworkLoadIfNeeded(token: String?, priority: TaskPriority) {
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
